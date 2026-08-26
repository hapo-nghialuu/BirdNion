#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// OAuth credentials Codex CLI stores in `~/.codex/auth.json`.
///
/// Ported (trimmed) from CodexBar's `CodexOAuthCredentials`. We only keep the
/// fields needed to call the usage API and refresh an expired token. Secrets in
/// here must never be logged.
struct CodexCredentials: Equatable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?
    let lastRefresh: Date?

    /// Codex CLI refreshes proactively roughly every 8 days; mirror that so a
    /// stale `access_token` gets rotated before the usage call would 401.
    var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

enum CodexAuthError: Error, Equatable {
    /// auth.json does not exist — the user has never run `codex login`.
    case notFound
    /// File exists but has neither OAuth tokens nor an API key.
    case missingTokens
    case decodeFailed
}

/// Reads/writes `~/.codex/auth.json`. Honours `CODEX_HOME` like the Codex CLI.
enum CodexAuthStore {
    /// Shared upper bound for small private JSON documents (auth, account
    /// metadata, snapshots, and status cache). It prevents a sparse or growing
    /// file from forcing an unbounded allocation on a provider refresh.
    static let maxPrivateJSONBytes = 8 * 1024 * 1024
    private static let ioLock = NSLock()
    private static var credentialRevisions: [String: UInt64] = [:]
    private static var credentialRoleRevisions: [String: UInt64] = [:]

    /// A descriptor-bound credential entry. The directory chain remains open
    /// across provider awaits, and every parent -> child link is revalidated
    /// before a credential is read, written, or reported current.
    final class CredentialFileBinding: @unchecked Sendable {
        fileprivate final class DirectoryAnchor: @unchecked Sendable {
            struct Link {
                let parentIndex: Int
                let childIndex: Int
                let name: String
                let identity: FileIdentity
            }

            let descriptors: [Int32]
            let links: [Link]
            let identity: FileIdentity

            init(descriptors: [Int32], links: [Link]) throws {
                guard let descriptor = descriptors.last else {
                    throw posixError("/", code: EINVAL)
                }
                var info = stat()
                guard fstat(descriptor, &info) == 0 else {
                    throw posixError("/dev/fd/\(descriptor)")
                }
                self.descriptors = descriptors
                self.links = links
                self.identity = FileIdentity(info)
            }

            deinit {
                for descriptor in descriptors.reversed() { close(descriptor) }
            }

            var directoryDescriptor: Int32 { descriptors[descriptors.count - 1] }

            var isLive: Bool {
                for link in links {
                    var linked = stat()
                    let result = link.name.withCString {
                        fstatat(
                            descriptors[link.parentIndex], $0, &linked,
                            AT_SYMLINK_NOFOLLOW)
                    }
                    guard result == 0,
                          linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                          FileIdentity(linked) == link.identity
                    else { return false }

                    var opened = stat()
                    guard fstat(descriptors[link.childIndex], &opened) == 0,
                          FileIdentity(opened) == link.identity
                    else { return false }
                }
                return true
            }
        }

        fileprivate let anchor: DirectoryAnchor
        let fileName: String
        let role: String
        let displayURL: URL

        fileprivate init(
            anchor: DirectoryAnchor,
            fileName: String,
            role: String,
            displayURL: URL
        ) throws {
            guard Self.isSafeEntryName(fileName) else {
                throw posixError(displayURL.path, code: EINVAL)
            }
            self.anchor = anchor
            self.fileName = fileName
            self.role = role
            self.displayURL = displayURL
        }

        var isLive: Bool { anchor.isLive }
        var directoryDescriptor: Int32 { anchor.directoryDescriptor }
        var directoryDescriptorPath: String { "/dev/fd/\(directoryDescriptor)" }

        fileprivate var stableKey: String {
            "\(anchor.identity.device):\(anchor.identity.inode):\(fileName):\(role)"
        }

        func representsSameEntry(as other: CredentialFileBinding) -> Bool {
            stableKey == other.stableKey
        }

        func sibling(fileName: String, role: String? = nil) throws -> CredentialFileBinding {
            try CredentialFileBinding(
                anchor: anchor,
                fileName: fileName,
                role: role ?? self.role,
                displayURL: displayURL.deletingLastPathComponent()
                    .appendingPathComponent(fileName))
        }

        func stageContainingDirectory(as siblingName: String) throws {
            try CodexAuthStore.renameContainingDirectory(
                binding: self, from: nil, to: siblingName)
        }

        func restoreContainingDirectory(from siblingName: String) throws {
            try CodexAuthStore.renameContainingDirectory(
                binding: self, from: siblingName, to: nil)
        }

        func removeContainingDirectory(detachedName: String? = nil) throws {
            try CodexAuthStore.removeContainingDirectory(
                binding: self, detachedName: detachedName)
        }

        private static func isSafeEntryName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/")
        }
    }

    struct CredentialRevision {
        fileprivate let binding: CredentialFileBinding
        fileprivate let entryRevision: UInt64
        fileprivate let roleRevision: UInt64
    }

    struct LoadedDocument {
        let credentials: CodexCredentials
        let rawData: Data
        let revision: CredentialRevision
        var binding: CredentialFileBinding { revision.binding }
    }

    struct FileExpectation {
        let data: Data?
        let revision: CredentialRevision
        var binding: CredentialFileBinding { revision.binding }
    }

    private struct PrivateFileSnapshot {
        let data: Data
        let modifiedAt: Date
    }

    struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            generation = info.st_gen
        }
    }

    enum VerifiedCopyResult: Equatable {
        case copied
        case unchanged
        case notNewer
        /// The two documents are different identities, or do not expose a
        /// stable identity that is safe to compare.
        case identityMismatch
        case unavailable
    }

    enum ReconcileResult: Equatable {
        case unchanged
        case copiedFirstToSecond
        case copiedSecondToFirst
        case identityMismatch
        case ambiguous
        case unavailable
    }

    static func authFileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL = if let codexHome, !codexHome.isEmpty {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return root.appendingPathComponent("auth.json")
    }

    static func bindCredentialFile(
        at url: URL,
        role: String? = nil
    ) throws -> CredentialFileBinding {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let anchor = try openDirectoryAnchor(at: parent)
        return try CredentialFileBinding(
            anchor: anchor,
            fileName: url.lastPathComponent,
            role: role ?? "path:\(url.standardizedFileURL.path)",
            displayURL: url)
    }

    static func bindSystemCredential(at url: URL) throws -> CredentialFileBinding {
        try bindCredentialFile(at: url, role: "system:auth.json")
    }

    /// Managed routing deliberately binds the accounts root first, then opens
    /// the UUID entry with `openat(O_DIRECTORY | O_NOFOLLOW)`. A later lexical
    /// replacement of that UUID cannot redirect this binding.
    static func bindManagedCredential(
        accountsRoot: URL,
        accountID: String,
        authURL: URL? = nil,
        expectedAccountsRootIdentity: FileIdentity? = nil,
        expectedAccountIdentity: FileIdentity? = nil
    ) throws -> CredentialFileBinding {
        guard UUID(uuidString: accountID) != nil else {
            throw posixError(accountsRoot.path, code: EINVAL)
        }
        let rootAnchor = try openManagedAccountsRoot(at: accountsRoot.standardizedFileURL)
        guard expectedAccountsRootIdentity == nil
                || rootAnchor.identity == expectedAccountsRootIdentity
        else { throw posixError(accountsRoot.path, code: ESTALE) }
        let accountAnchor = try appendDirectory(
            named: accountID,
            to: rootAnchor)
        guard expectedAccountIdentity == nil
                || accountAnchor.identity == expectedAccountIdentity
        else {
            throw posixError(
                accountsRoot.appendingPathComponent(accountID).path,
                code: ESTALE)
        }
        let displayURL = authURL ?? accountsRoot
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("auth.json")
        return try CredentialFileBinding(
            anchor: accountAnchor,
            fileName: "auth.json",
            role: "managed:\(accountID):auth.json",
            displayURL: displayURL)
    }

    /// Creates a managed UUID directory relative to the already-bound accounts
    /// root, then opens it without following links. Used by add/promotion so
    /// creation and the subsequent login share one stable directory identity.
    static func createManagedCredentialBinding(
        accountsRoot: URL,
        accountID: String,
        expectedAccountsRootIdentity: FileIdentity? = nil
    ) throws -> CredentialFileBinding {
        guard UUID(uuidString: accountID) != nil else {
            throw posixError(accountsRoot.path, code: EINVAL)
        }
        let rootAnchor = try openManagedAccountsRoot(at: accountsRoot.standardizedFileURL)
        guard expectedAccountsRootIdentity == nil
                || rootAnchor.identity == expectedAccountsRootIdentity
        else { throw posixError(accountsRoot.path, code: ESTALE) }
        let createResult = accountID.withCString {
            mkdirat(rootAnchor.directoryDescriptor, $0, mode_t(0o700))
        }
        guard createResult == 0 else {
            throw posixError(accountsRoot.appendingPathComponent(accountID).path)
        }
        do {
            let accountAnchor = try appendDirectory(named: accountID, to: rootAnchor)
            return try CredentialFileBinding(
                anchor: accountAnchor,
                fileName: "auth.json",
                role: "managed:\(accountID):auth.json",
                displayURL: accountsRoot
                    .appendingPathComponent(accountID, isDirectory: true)
                    .appendingPathComponent("auth.json"))
        } catch {
            _ = accountID.withCString { unlinkat(rootAnchor.directoryDescriptor, $0, AT_REMOVEDIR) }
            throw error
        }
    }

    private static func openDirectoryAnchor(
        at directory: URL
    ) throws -> CredentialFileBinding.DirectoryAnchor {
        var resolvedStorage = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard directory.path.withCString({ realpath($0, &resolvedStorage) }) != nil else {
            throw posixError(directory.path)
        }
        let resolvedPath = String(cString: resolvedStorage)
        let components = URL(fileURLWithPath: resolvedPath, isDirectory: true).pathComponents
        let rootDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw posixError("/") }
        var descriptors = [rootDescriptor]
        var links: [CredentialFileBinding.DirectoryAnchor.Link] = []
        do {
            for name in components.dropFirst() {
                let parentIndex = descriptors.count - 1
                let descriptor = name.withCString {
                    openat(
                        descriptors[parentIndex], $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else { throw posixError(resolvedPath) }
                descriptors.append(descriptor)
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                else { throw posixError(resolvedPath) }
                links.append(.init(
                    parentIndex: parentIndex,
                    childIndex: descriptors.count - 1,
                    name: name,
                    identity: FileIdentity(info)))
            }
            return try CredentialFileBinding.DirectoryAnchor(
                descriptors: descriptors,
                links: links)
        } catch {
            for descriptor in descriptors.reversed() { close(descriptor) }
            throw error
        }
    }

    /// Resolve and bind only the stable parent chain, then open the mutable
    /// app-owned accounts-root entry itself without following a replacement
    /// symlink. UUID homes are subsequently opened from this same root anchor.
    private static func openManagedAccountsRoot(
        at accountsRoot: URL
    ) throws -> CredentialFileBinding.DirectoryAnchor {
        let standardized = accountsRoot.standardizedFileURL
        let parent = try openDirectoryAnchor(at: standardized.deletingLastPathComponent())
        return try appendDirectory(named: standardized.lastPathComponent, to: parent)
    }

    private static func appendDirectory(
        named name: String,
        to parent: CredentialFileBinding.DirectoryAnchor
    ) throws -> CredentialFileBinding.DirectoryAnchor {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw posixError(name, code: EINVAL)
        }
        let descriptor = name.withCString {
            openat(
                parent.directoryDescriptor, $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(name) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            close(descriptor)
            throw posixError(name)
        }

        var descriptors: [Int32] = []
        var descriptorIsSeparate = true
        do {
            for oldDescriptor in parent.descriptors {
                let duplicate = fcntl(oldDescriptor, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else { throw posixError(name) }
                descriptors.append(duplicate)
            }
            descriptors.append(descriptor)
            descriptorIsSeparate = false
            var links = parent.links
            links.append(.init(
                parentIndex: descriptors.count - 2,
                childIndex: descriptors.count - 1,
                name: name,
                identity: FileIdentity(info)))
            return try CredentialFileBinding.DirectoryAnchor(
                descriptors: descriptors,
                links: links)
        } catch {
            if descriptorIsSeparate { close(descriptor) }
            for duplicate in descriptors.reversed() { close(duplicate) }
            throw error
        }
    }

    private static func renameContainingDirectory(
        binding: CredentialFileBinding,
        from detachedSourceName: String?,
        to detachedDestinationName: String?
    ) throws {
        guard let link = binding.anchor.links.last else {
            throw posixError(binding.displayURL.path, code: EINVAL)
        }
        let parentDescriptor = binding.anchor.descriptors[link.parentIndex]
        let sourceName = detachedSourceName ?? link.name
        let destinationName = detachedDestinationName ?? link.name
        guard sourceName != destinationName,
              !sourceName.contains("/"),
              !destinationName.contains("/")
        else { throw posixError(binding.displayURL.path, code: EINVAL) }

        var sourceInfo = stat()
        let statResult = sourceName.withCString {
            fstatat(parentDescriptor, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              FileIdentity(sourceInfo) == binding.anchor.identity
        else { throw posixError(binding.displayURL.path, code: ESTALE) }

        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    parentDescriptor, sourcePath,
                    parentDescriptor, destinationPath,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
            }
        }
        guard result == 0, fsync(parentDescriptor) == 0 else {
            throw posixError(binding.displayURL.path)
        }
        if detachedDestinationName == nil {
            guard binding.isLive else {
                throw posixError(binding.displayURL.path, code: ESTALE)
            }
        } else if binding.isLive {
            throw posixError(binding.displayURL.path, code: ESTALE)
        }
    }

    private static func removeContainingDirectory(
        binding: CredentialFileBinding,
        detachedName: String?
    ) throws {
        guard let link = binding.anchor.links.last else {
            throw posixError(binding.displayURL.path, code: EINVAL)
        }
        let parentDescriptor = binding.anchor.descriptors[link.parentIndex]
        let entryName = detachedName ?? link.name
        var entryInfo = stat()
        let result = entryName.withCString {
            fstatat(parentDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              entryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              FileIdentity(entryInfo) == binding.anchor.identity
        else { throw posixError(binding.displayURL.path, code: ESTALE) }

        try removeDirectoryContents(descriptor: binding.directoryDescriptor)
        let removeResult = entryName.withCString {
            unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard removeResult == 0, fsync(parentDescriptor) == 0 else {
            throw posixError(binding.displayURL.path)
        }
    }

    private static func removeDirectoryContents(descriptor: Int32) throws {
        let scanDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard scanDescriptor >= 0, let directory = fdopendir(scanDescriptor) else {
            if scanDescriptor >= 0 { close(scanDescriptor) }
            throw posixError("/dev/fd/\(descriptor)")
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            let statResult = name.withCString {
                fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { throw posixError(name) }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = name.withCString {
                    openat(
                        descriptor, $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw posixError(name) }
                do {
                    try removeDirectoryContents(descriptor: child)
                    close(child)
                } catch {
                    close(child)
                    throw error
                }
                guard name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw posixError(name)
                }
            } else {
                guard name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw posixError(name)
                }
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("/dev/fd/\(descriptor)") }
    }

    static func load(url: URL = authFileURL()) throws -> CodexCredentials {
        try loadDocument(url: url).credentials
    }

    static func loadDocument(url: URL = authFileURL()) throws -> LoadedDocument {
        let binding: CredentialFileBinding
        do {
            binding = try bindCredentialFile(at: url)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ENOENT) {
            throw CodexAuthError.notFound
        }
        return try loadDocument(binding: binding)
    }

    static func loadDocument(binding: CredentialFileBinding) throws -> LoadedDocument {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let data = try readPrivateFile(binding) else {
            throw CodexAuthError.notFound
        }
        return LoadedDocument(
            credentials: try parse(data),
            rawData: data,
            revision: revisionLocked(for: binding))
    }

    static func captureFileExpectation(url: URL) throws -> FileExpectation {
        let binding = try bindCredentialFile(at: url)
        return try captureFileExpectation(binding: binding)
    }

    static func captureFileExpectation(
        binding: CredentialFileBinding
    ) throws -> FileExpectation {
        ioLock.lock()
        defer { ioLock.unlock() }
        return FileExpectation(
            data: try readPrivateFile(binding),
            revision: revisionLocked(for: binding))
    }

    static func parse(_ data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.decodeFailed
        }

        // API-key mode: Codex stores a raw key instead of OAuth tokens.
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CodexCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CodexAuthError.missingTokens
        }
        guard let accessToken = string(tokens, "access_token", "accessToken"),
              !accessToken.isEmpty
        else {
            throw CodexAuthError.missingTokens
        }

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: string(tokens, "refresh_token", "refreshToken") ?? "",
            idToken: string(tokens, "id_token", "idToken"),
            accountId: string(tokens, "account_id", "accountId"),
            lastRefresh: parseDate(json["last_refresh"]))
    }

    /// Writes refreshed tokens back to auth.json, preserving any other keys the
    /// file holds. Uses a private (0600) staged file + atomic rename so a token
    /// is never world-readable and a crash can't leave a half-written file.
    static func save(_ credentials: CodexCredentials, url: URL = authFileURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let binding = try bindCredentialFile(at: url)
        ioLock.lock()
        defer { ioLock.unlock() }
        let existingData = try readPrivateFile(binding)
        let data = try encodedDocument(credentials, preserving: existingData)
        try writePrivateFile(data, to: binding)
        bumpRevisionLocked(for: binding)
    }

    /// Save a refresh result only while the auth bytes still equal the exact
    /// document that initiated that network request. Re-auth/remove of the
    /// same logical account changes or removes those bytes; in that case the
    /// stale refresh is skipped and cannot resurrect/overwrite credentials.
    /// Returns the newly written document + revision, or nil when the compare
    /// did not match.
    static func saveIfUnchanged(
        _ credentials: CodexCredentials,
        url: URL,
        expectedData: Data,
        expectedRevision: CredentialRevision
    ) throws -> LoadedDocument? {
        guard expectedRevision.binding.displayURL.standardizedFileURL
            == url.standardizedFileURL
        else { return nil }
        return try saveIfUnchanged(
            credentials,
            binding: expectedRevision.binding,
            expectedData: expectedData,
            expectedRevision: expectedRevision)
    }

    static func saveIfUnchanged(
        _ credentials: CodexCredentials,
        binding: CredentialFileBinding,
        expectedData: Data,
        expectedRevision: CredentialRevision
    ) throws -> LoadedDocument? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard expectedRevision.binding === binding,
              revisionIsCurrentLocked(expectedRevision),
              let current = try readPrivateFile(binding),
              current == expectedData
        else {
            return nil
        }
        let data = try encodedDocument(credentials, preserving: current)
        guard try replacePrivateFileIfUnchanged(
            data, to: binding, replacing: current)
        else { return nil }
        guard binding.isLive else { return nil }
        bumpRevisionLocked(for: binding)
        return LoadedDocument(
            credentials: credentials,
            rawData: data,
            revision: revisionLocked(for: binding))
    }

    static func documentIsCurrent(
        url: URL,
        expectedData: Data,
        expectedRevision: CredentialRevision
    ) -> Bool {
        guard expectedRevision.binding.displayURL.standardizedFileURL
            == url.standardizedFileURL
        else { return false }
        return documentIsCurrent(
            binding: expectedRevision.binding,
            expectedData: expectedData,
            expectedRevision: expectedRevision)
    }

    static func documentIsCurrent(
        binding: CredentialFileBinding,
        expectedData: Data,
        expectedRevision: CredentialRevision
    ) -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard expectedRevision.binding === binding,
              revisionIsCurrentLocked(expectedRevision),
              let current = try? readPrivateFile(binding)
        else { return false }
        return current == expectedData
    }

    /// Copies the exact current source bytes while holding the same lock used
    /// by refresh compare-and-save. This closes both sides of the CLI bridge:
    /// a switch cannot publish a stale managed token, and sync-back cannot
    /// overwrite a refresh that committed after its timestamp decision.
    @discardableResult
    static func copyCredential(
        from source: URL,
        to destination: URL,
        onlyIfSourceNewer: Bool = false
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return try copyCredential(
            from: bindCredentialFile(at: source),
            to: bindCredentialFile(at: destination),
            onlyIfSourceNewer: onlyIfSourceNewer)
    }

    @discardableResult
    static func copyCredential(
        from source: CredentialFileBinding,
        to destination: CredentialFileBinding,
        onlyIfSourceNewer: Bool = false
    ) throws -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard source.stableKey != destination.stableKey,
              let sourceSnapshot = try readPrivateFileSnapshot(source),
              (try? parse(sourceSnapshot.data)) != nil
        else { return false }
        let destinationSnapshot = try readPrivateFileSnapshot(destination)
        if onlyIfSourceNewer,
           let destinationSnapshot,
           sourceSnapshot.modifiedAt <= destinationSnapshot.modifiedAt
        {
            return false
        }

        guard try replacePrivateFileIfUnchanged(
            sourceSnapshot.data,
            to: destination,
            replacing: destinationSnapshot?.data)
        else { return false }
        // Invalidate refreshes that loaded either side before this successful
        // copy so a just-installed CLI credential cannot be made stale by an
        // older in-process refresh.
        bumpRevisionLocked(for: source)
        bumpRevisionLocked(for: destination)
        return true
    }

    /// Copies only when both documents prove they belong to the same Codex
    /// identity. This protects a tracked managed account from an unrelated
    /// `codex login` that replaced the system auth file outside BirdNion.
    static func copyCredentialIfSameIdentity(
        from source: URL,
        to destination: URL,
        onlyIfSourceNewer: Bool = false
    ) throws -> VerifiedCopyResult {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return try copyCredentialIfSameIdentity(
            from: bindCredentialFile(at: source),
            to: bindCredentialFile(at: destination),
            onlyIfSourceNewer: onlyIfSourceNewer)
    }

    static func copyCredentialIfSameIdentity(
        from source: CredentialFileBinding,
        to destination: CredentialFileBinding,
        onlyIfSourceNewer: Bool = false
    ) throws -> VerifiedCopyResult {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard source.stableKey != destination.stableKey,
              let sourceSnapshot = try readPrivateFileSnapshot(source),
              let destinationSnapshot = try readPrivateFileSnapshot(destination)
        else { return .unavailable }
        if sourceSnapshot.data == destinationSnapshot.data { return .unchanged }
        guard let sourceCredentials = try? parse(sourceSnapshot.data),
              let destinationCredentials = try? parse(destinationSnapshot.data),
              sameStableIdentity(sourceCredentials, destinationCredentials)
        else { return .identityMismatch }
        if onlyIfSourceNewer,
           sourceSnapshot.modifiedAt <= destinationSnapshot.modifiedAt {
            return .notNewer
        }

        guard try replacePrivateFileIfUnchanged(
            sourceSnapshot.data,
            to: destination,
            replacing: destinationSnapshot.data)
        else { return .unavailable }
        bumpRevisionLocked(for: source)
        bumpRevisionLocked(for: destination)
        return .copied
    }

    /// Reconciles a tracked managed/system pair in either direction. Identity
    /// is checked before choosing the newer document, so an external login to
    /// another account is never imported into the managed home or overwritten.
    static func reconcileCredentialPair(
        first: URL,
        second: URL
    ) throws -> ReconcileResult {
        try reconcileCredentialPair(
            first: bindCredentialFile(at: first),
            second: bindCredentialFile(at: second))
    }

    static func reconcileCredentialPair(
        first: CredentialFileBinding,
        second: CredentialFileBinding
    ) throws -> ReconcileResult {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard first.stableKey != second.stableKey,
              let firstSnapshot = try readPrivateFileSnapshot(first),
              let secondSnapshot = try readPrivateFileSnapshot(second)
        else { return .unavailable }
        if firstSnapshot.data == secondSnapshot.data { return .unchanged }
        guard let firstCredentials = try? parse(firstSnapshot.data),
              let secondCredentials = try? parse(secondSnapshot.data),
              sameStableIdentity(firstCredentials, secondCredentials)
        else { return .identityMismatch }

        let direction: ComparisonResult
        if let firstRefresh = firstCredentials.lastRefresh,
           let secondRefresh = secondCredentials.lastRefresh,
           firstRefresh != secondRefresh {
            direction = firstRefresh.compare(secondRefresh)
        } else if firstSnapshot.modifiedAt != secondSnapshot.modifiedAt {
            direction = firstSnapshot.modifiedAt.compare(secondSnapshot.modifiedAt)
        } else {
            return .ambiguous
        }

        let source: CredentialFileBinding = direction == .orderedDescending ? first : second
        let destination: CredentialFileBinding = direction == .orderedDescending ? second : first
        let data = direction == .orderedDescending ? firstSnapshot.data : secondSnapshot.data
        let destinationData = direction == .orderedDescending
            ? secondSnapshot.data
            : firstSnapshot.data
        guard try replacePrivateFileIfUnchanged(
            data,
            to: destination,
            replacing: destinationData)
        else { return .unavailable }
        bumpRevisionLocked(for: source)
        bumpRevisionLocked(for: destination)
        return direction == .orderedDescending ? .copiedFirstToSecond : .copiedSecondToFirst
    }

    /// Re-auth may intentionally change the logical account's identity. It
    /// can replace the tracked system mirror only if that destination still
    /// has the exact bytes/revision captured before the external login began.
    static func copyCredentialIfDestinationUnchanged(
        from source: URL,
        to destination: URL,
        expectedDestinationData: Data,
        expectedDestinationRevision: CredentialRevision
    ) throws -> Bool {
        guard expectedDestinationRevision.binding.displayURL.standardizedFileURL
            == destination.standardizedFileURL
        else { return false }
        return try copyCredentialIfDestinationUnchanged(
            from: bindCredentialFile(at: source),
            to: expectedDestinationRevision.binding,
            expectedDestinationData: expectedDestinationData,
            expectedDestinationRevision: expectedDestinationRevision)
    }

    static func copyCredentialIfDestinationUnchanged(
        from source: CredentialFileBinding,
        to destination: CredentialFileBinding,
        expectedDestinationData: Data,
        expectedDestinationRevision: CredentialRevision
    ) throws -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try copyCredentialLocked(
            from: source,
            to: destination,
            expectedDestination: FileExpectation(
                data: expectedDestinationData,
                revision: expectedDestinationRevision))
    }

    /// Installs a source credential only if the destination still matches a
    /// snapshot captured before a multi-step account transaction began. The
    /// expectation may represent an absent file.
    static func copyCredential(
        from source: URL,
        to destination: URL,
        ifDestinationMatches expectation: FileExpectation
    ) throws -> Bool {
        guard expectation.binding.displayURL.standardizedFileURL
            == destination.standardizedFileURL
        else { return false }
        return try copyCredential(
            from: bindCredentialFile(at: source),
            to: expectation.binding,
            ifDestinationMatches: expectation)
    }

    static func copyCredential(
        from source: CredentialFileBinding,
        to destination: CredentialFileBinding,
        ifDestinationMatches expectation: FileExpectation
    ) throws -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try copyCredentialLocked(
            from: source,
            to: destination,
            expectedDestination: expectation)
    }

    private static func copyCredentialLocked(
        from source: CredentialFileBinding,
        to destination: CredentialFileBinding,
        expectedDestination: FileExpectation
    ) throws -> Bool {
        guard source.stableKey != destination.stableKey,
              expectedDestination.binding === destination,
              revisionIsCurrentLocked(expectedDestination.revision),
              let sourceSnapshot = try readPrivateFileSnapshot(source),
              (try? parse(sourceSnapshot.data)) != nil,
              try readPrivateFile(destination) == expectedDestination.data
        else { return false }
        if sourceSnapshot.data == expectedDestination.data { return true }
        guard try replacePrivateFileIfUnchanged(
            sourceSnapshot.data,
            to: destination,
            replacing: expectedDestination.data)
        else { return false }
        bumpRevisionLocked(for: source)
        bumpRevisionLocked(for: destination)
        return true
    }

    /// Synchronous mutation fence shared with conditional refresh commits.
    /// Account reauth/remove calls this before touching auth bytes. Holding the
    /// same lock means either an older refresh commits fully first (and the
    /// mutation wins afterward), or the revision bump wins and rejects it.
    static func invalidateCredential(at url: URL) {
        let role = "path:\(url.standardizedFileURL.path)"
        ioLock.lock()
        defer { ioLock.unlock() }
        if let binding = try? bindCredentialFile(at: url, role: role) {
            bumpRevisionLocked(for: binding)
        } else {
            credentialRoleRevisions[role, default: 0] &+= 1
        }
    }

    static func invalidateCredential(binding: CredentialFileBinding) {
        ioLock.lock()
        defer { ioLock.unlock() }
        bumpRevisionLocked(for: binding)
    }

    private static func revisionLocked(
        for binding: CredentialFileBinding
    ) -> CredentialRevision {
        CredentialRevision(
            binding: binding,
            entryRevision: credentialRevisions[binding.stableKey, default: 0],
            roleRevision: credentialRoleRevisions[binding.role, default: 0])
    }

    private static func revisionIsCurrentLocked(_ revision: CredentialRevision) -> Bool {
        let binding = revision.binding
        return binding.isLive
            && credentialRevisions[binding.stableKey, default: 0] == revision.entryRevision
            && credentialRoleRevisions[binding.role, default: 0] == revision.roleRevision
    }

    private static func bumpRevisionLocked(for binding: CredentialFileBinding) {
        credentialRevisions[binding.stableKey, default: 0] &+= 1
        credentialRoleRevisions[binding.role, default: 0] &+= 1
    }

    private static func encodedDocument(
        _ credentials: CodexCredentials,
        preserving existingData: Data?
    ) throws -> Data {
        var json: [String: Any] = [:]
        if let existingData {
            guard let existing = try JSONSerialization.jsonObject(with: existingData) as? [String: Any]
            else { throw CodexAuthError.decodeFailed }
            json = existing
        }

        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let idToken = credentials.idToken { tokens["id_token"] = idToken }
        if let accountId = credentials.accountId { tokens["account_id"] = accountId }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        return try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys])
    }

    private static func sameStableIdentity(
        _ lhs: CodexCredentials,
        _ rhs: CodexCredentials
    ) -> Bool {
        let lhsAccount = lhs.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsAccount = rhs.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsAccount, !lhsAccount.isEmpty,
           let rhsAccount, !rhsAccount.isEmpty {
            return lhsAccount == rhsAccount
        }
        if let lhsEmail = emailFromIDToken(lhs.idToken)?.lowercased(),
           let rhsEmail = emailFromIDToken(rhs.idToken)?.lowercased() {
            return lhsEmail == rhsEmail
        }
        // API-key documents have no refresh/id/account identity fields. Exact
        // equality is the only safe proof available and reveals nothing.
        let lhsIsAPIKey = lhs.refreshToken.isEmpty && lhs.idToken == nil && lhs.accountId == nil
        let rhsIsAPIKey = rhs.refreshToken.isEmpty && rhs.idToken == nil && rhs.accountId == nil
        return lhsIsAPIKey && rhsIsAPIKey && lhs.accessToken == rhs.accessToken
    }

    // MARK: - Helpers

    /// Atomic private-file write (staged `O_EXCL` + `fchmod 0600` + `rename`).
    /// Exposed (not `private`) so `CodexAccountStore` can reuse it for CLI
    /// switch / restore / sync-back copies without duplicating the logic.
    static func writePrivateFile(
        _ data: Data,
        to url: URL,
        maximumBytes: Int = maxPrivateJSONBytes
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePrivateFile(
            data,
            to: bindCredentialFile(at: url),
            maximumBytes: maximumBytes)
    }

    static func writePrivateFile(
        _ data: Data,
        to binding: CredentialFileBinding,
        maximumBytes: Int = maxPrivateJSONBytes
    ) throws {
        _ = try readPrivateFile(binding, maximumBytes: maximumBytes)
        let staged = try stagePrivateFile(
            data, for: binding, maximumBytes: maximumBytes)
        do {
            guard binding.isLive else { throw posixError(binding.displayURL.path, code: ESTALE) }
            let result = renameWithFlags(
                binding: binding,
                sourceName: staged,
                destinationName: binding.fileName,
                flags: UInt32(RENAME_NOFOLLOW_ANY))
            guard result == 0 else { throw posixError(binding.displayURL.path) }
            guard fsync(binding.directoryDescriptor) == 0, binding.isLive else {
                throw posixError(binding.displayURL.path, code: ESTALE)
            }
        } catch {
            unlinkEntry(staged, from: binding)
            throw error
        }
    }

    /// Obstruction-free external-process compare-and-replace. `RENAME_SWAP`
    /// atomically captures the destination entry that existed at install time
    /// into the staged path. Only an exact displaced-byte match commits; a
    /// mismatch is swapped back without discarding the external writer's file.
    /// The hook exists solely for deterministic race regression tests.
    static func replacePrivateFileIfUnchanged(
        _ data: Data,
        to url: URL,
        replacing expectedData: Data?,
        maximumBytes: Int = maxPrivateJSONBytes,
        beforeCommit: () -> Void = {}
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try replacePrivateFileIfUnchanged(
            data,
            to: bindCredentialFile(at: url),
            replacing: expectedData,
            maximumBytes: maximumBytes,
            beforeCommit: beforeCommit)
    }

    static func replacePrivateFileIfUnchanged(
        _ data: Data,
        to binding: CredentialFileBinding,
        replacing expectedData: Data?,
        maximumBytes: Int = maxPrivateJSONBytes,
        beforeCommit: () -> Void = {}
    ) throws -> Bool {
        let current = try readPrivateFile(binding, maximumBytes: maximumBytes)
        guard current == expectedData else { return false }
        let staged = try stagePrivateFile(
            data, for: binding, maximumBytes: maximumBytes)
        let replacementIdentity = try entryIdentity(binding: binding, name: staged)
        var swapped = false
        do {
            beforeCommit()
            guard binding.isLive else {
                unlinkEntry(staged, from: binding)
                return false
            }
            if expectedData == nil {
                let result = renameWithFlags(
                    binding: binding,
                    sourceName: staged,
                    destinationName: binding.fileName,
                    flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
                if result == 0 {
                    guard binding.isLive else {
                        if (try? entryIdentity(
                            binding: binding, name: binding.fileName)) == replacementIdentity {
                            unlinkEntry(binding.fileName, from: binding)
                        }
                        return false
                    }
                    guard fsync(binding.directoryDescriptor) == 0 else {
                        throw posixError(binding.displayURL.path)
                    }
                    return binding.isLive
                }
                let code = errno
                unlinkEntry(staged, from: binding)
                if code == EEXIST || code == ENOTEMPTY { return false }
                throw posixError(binding.displayURL.path, code: code)
            }

            let result = renameWithFlags(
                binding: binding,
                sourceName: staged,
                destinationName: binding.fileName,
                flags: UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
            if result != 0 {
                let code = errno
                unlinkEntry(staged, from: binding)
                if code == ENOENT { return false }
                throw posixError(binding.displayURL.path, code: code)
            }
            swapped = true
            guard let displaced = try readPrivateFile(
                try binding.sibling(fileName: staged), maximumBytes: maximumBytes)
            else { throw posixError(staged, code: ENOENT) }
            guard displaced == expectedData, binding.isLive else {
                try restoreDisplacedPrivateFile(
                    binding: binding,
                    stagedName: staged,
                    expectedDestinationIdentity: replacementIdentity)
                return false
            }
            guard unlinkEntry(staged, from: binding) == 0,
                  fsync(binding.directoryDescriptor) == 0
            else { throw posixError(binding.displayURL.path) }
            return binding.isLive
        } catch {
            if swapped {
                _ = try entryIdentity(binding: binding, name: staged)
                try restoreDisplacedPrivateFile(
                    binding: binding,
                    stagedName: staged,
                    expectedDestinationIdentity: replacementIdentity)
            } else {
                unlinkEntry(staged, from: binding)
            }
            throw error
        }
    }

    private static func stagePrivateFile(
        _ data: Data,
        for binding: CredentialFileBinding,
        maximumBytes: Int
    ) throws -> String {
        guard data.count <= maximumBytes else {
            throw posixError(binding.displayURL.path, code: EFBIG)
        }
        guard binding.isLive else {
            throw posixError(binding.displayURL.path, code: ESTALE)
        }
        let staged = ".\(binding.fileName).birdnion-\(UUID().uuidString)"
        let descriptor = staged.withCString {
            openat(
                binding.directoryDescriptor, $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError(binding.displayURL.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError(binding.displayURL.path)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard binding.isLive else {
                unlinkEntry(staged, from: binding)
                throw posixError(binding.displayURL.path, code: ESTALE)
            }
            return staged
        } catch {
            try? handle.close()
            unlinkEntry(staged, from: binding)
            throw error
        }
    }

    /// A writer may replace the destination again while a mismatch is being
    /// rolled back. Each exchange preserves that newest entry in `staged`;
    /// retry until one exchange observes the exact entry we installed. No
    /// credential bytes are deleted on the bounded-contention failure path.
    private static func restoreDisplacedPrivateFile(
        binding: CredentialFileBinding,
        stagedName: String,
        expectedDestinationIdentity: FileIdentity
    ) throws {
        var expectedAtDestination = expectedDestinationIdentity
        for _ in 0..<64 {
            let candidate = try entryIdentity(binding: binding, name: stagedName)
            let result = renameWithFlags(
                binding: binding,
                sourceName: stagedName,
                destinationName: binding.fileName,
                flags: UInt32(RENAME_SWAP))
            if result != 0 {
                let code = errno
                if code == ENOENT {
                    let install = renameWithFlags(
                        binding: binding,
                        sourceName: stagedName,
                        destinationName: binding.fileName,
                        flags: UInt32(RENAME_EXCL))
                    if install == 0 {
                        _ = fsync(binding.directoryDescriptor)
                        return
                    }
                    if errno == EEXIST { continue }
                }
                throw posixError(binding.displayURL.path, code: code)
            }
            let displaced = try entryIdentity(binding: binding, name: stagedName)
            if displaced == expectedAtDestination {
                guard unlinkEntry(stagedName, from: binding) == 0,
                      fsync(binding.directoryDescriptor) == 0
                else { throw posixError(binding.displayURL.path) }
                return
            }
            expectedAtDestination = candidate
        }
        throw posixError(binding.displayURL.path, code: EBUSY)
    }

    private static func entryIdentity(
        binding: CredentialFileBinding,
        name: String
    ) throws -> FileIdentity {
        var info = stat()
        let result = name.withCString {
            fstatat(binding.directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw posixError(binding.displayURL.path) }
        return FileIdentity(info)
    }

    private static func renameWithFlags(
        binding: CredentialFileBinding,
        sourceName: String,
        destinationName: String,
        flags: UInt32
    ) -> Int32 {
        sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    binding.directoryDescriptor, sourcePath,
                    binding.directoryDescriptor, destinationPath,
                    flags)
            }
        }
    }

    /// Bounded, non-following descriptor read for private JSON state. Missing
    /// is the only condition represented by `nil`; every existing special,
    /// linked, unreadable, or oversized object is an error so mutation callers
    /// can fail closed instead of reinterpreting it as an empty document.
    static func readPrivateFile(
        _ url: URL,
        maximumBytes: Int = maxPrivateJSONBytes
    ) throws -> Data? {
        do {
            return try readPrivateFile(
                bindCredentialFile(at: url), maximumBytes: maximumBytes)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ENOENT) {
            return nil
        }
    }

    static func readPrivateFile(
        _ binding: CredentialFileBinding,
        maximumBytes: Int = maxPrivateJSONBytes
    ) throws -> Data? {
        try readPrivateFileSnapshot(binding, maximumBytes: maximumBytes)?.data
    }

    private static func readPrivateFileSnapshot(
        _ binding: CredentialFileBinding,
        maximumBytes: Int = maxPrivateJSONBytes
    ) throws -> PrivateFileSnapshot? {
        guard maximumBytes >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard binding.isLive else {
            throw posixError(binding.displayURL.path, code: ESTALE)
        }
        let descriptor = binding.fileName.withCString {
            openat(
                binding.directoryDescriptor, $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixError(binding.displayURL.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0,
              info.st_size <= maximumBytes,
              let data = try handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EFBIG),
                userInfo: [NSFilePathErrorKey: binding.displayURL.path])
        }
        guard binding.isLive else {
            throw posixError(binding.displayURL.path, code: ESTALE)
        }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return PrivateFileSnapshot(data: data, modifiedAt: modifiedAt)
    }

    @discardableResult
    private static func unlinkEntry(
        _ name: String,
        from binding: CredentialFileBinding,
        flags: Int32 = 0
    ) -> Int32 {
        name.withCString { unlinkat(binding.directoryDescriptor, $0, flags) }
    }

    /// Moves the bound credential entry to a sibling name without resolving
    /// its parent path again. Returns false only when the destination exists.
    static func movePrivateFile(
        _ binding: CredentialFileBinding,
        toSiblingName destinationName: String
    ) throws -> Bool {
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/"),
              binding.isLive
        else { throw posixError(binding.displayURL.path, code: ESTALE) }
        let result = renameWithFlags(
            binding: binding,
            sourceName: binding.fileName,
            destinationName: destinationName,
            flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
        if result != 0 {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { return false }
            throw posixError(binding.displayURL.path, code: code)
        }
        guard fsync(binding.directoryDescriptor) == 0, binding.isLive else {
            throw posixError(binding.displayURL.path, code: ESTALE)
        }
        return true
    }

    private static func posixError(_ path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path])
    }

    private static func string(_ dict: [String: Any], _ snake: String, _ camel: String) -> String? {
        if let v = dict[snake] as? String, !v.isEmpty { return v }
        if let v = dict[camel] as? String, !v.isEmpty { return v }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    /// Best-effort email extraction from the OAuth id_token (JWT) for a friendly
    /// account label. Returns nil on any decode problem — never throws.
    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let email = json["email"] as? String, !email.isEmpty { return email }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty
        {
            return email
        }
        return nil
    }
}

/// Refreshes an expired Codex access token using the stored refresh token.
/// Ported from CodexBar's `CodexTokenRefresher` (same OAuth client_id/endpoint).
enum CodexTokenRefresher {
    private static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    enum RefreshError: Error, Equatable {
        case noRefreshToken
        case failed(Int)
        case invalidResponse
    }

    static func refresh(
        _ credentials: CodexCredentials,
        session: URLSession = .shared) async throws -> CodexCredentials
    {
        guard !credentials.refreshToken.isEmpty else { throw RefreshError.noRefreshToken }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RefreshError.invalidResponse }
        guard http.statusCode == 200 else { throw RefreshError.failed(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse
        }

        return CodexCredentials(
            accessToken: json["access_token"] as? String ?? credentials.accessToken,
            refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
            idToken: json["id_token"] as? String ?? credentials.idToken,
            accountId: credentials.accountId,
            lastRefresh: Date())
    }
}
