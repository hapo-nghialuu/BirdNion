import Foundation
import Darwin

/// One Codex login the app knows about.
/// - `system` is the default `~/.codex` login written by `codex login` in a
///   terminal. It is read-only here and never overwritten by switching.
/// - Managed accounts each live in their own `CODEX_HOME` under Application
///   Support, so adding/switching never touches the system login.
struct CodexAccount: Identifiable, Equatable {
    let id: String          // "system" or a UUID string
    let email: String?
    let isSystem: Bool
    let homePath: String?   // nil for the system account (uses ~/.codex)
}

/// Manages Codex multi-account state the CodexBar way: separate `CODEX_HOME`
/// directories per managed account, with the active one driving which
/// `auth.json` the provider reads. The system `~/.codex` stays untouched.
enum CodexAccountStore {
    static let activeKey = "activeCodexAccount"
    private static let maxMetadataBytes = 2 * 1024 * 1024
    private static let metadataMutationLock = NSLock()
    private static let accountOperationFence = AccountOperationFence()

    /// Short per-account state transitions only. Login and filesystem work
    /// always happen after this lock is released.
    final class AccountOperationFence {
        private struct State {
            var reauthCount = 0
            var removalInProgress = false
            var exclusiveMutationInProgress = false
        }

        private let lock = NSLock()
        private var states: [String: State] = [:]

        func beginReauthentication(id: String) throws {
            lock.lock()
            defer { lock.unlock() }
            var state = states[id] ?? State()
            guard state.reauthCount == 0,
                  !state.removalInProgress,
                  !state.exclusiveMutationInProgress
            else {
                throw AccountError.persistenceFailed
            }
            state.reauthCount += 1
            states[id] = state
        }

        func finishReauthentication(id: String) {
            lock.lock()
            defer { lock.unlock() }
            if var state = states[id] {
                state.reauthCount = max(0, state.reauthCount - 1)
                if state.reauthCount == 0,
                   !state.removalInProgress,
                   !state.exclusiveMutationInProgress {
                    states.removeValue(forKey: id)
                } else {
                    states[id] = state
                }
            }
        }

        func performRemoval<T>(id: String, operation: () throws -> T) throws -> T {
            try performRemoval(ids: [id], operation: operation)
        }

        func performRemoval<T>(ids: [String], operation: () throws -> T) throws -> T {
            let uniqueIDs = Array(Set(ids)).sorted()
            lock.lock()
            for id in uniqueIDs {
                let state = states[id] ?? State()
                guard !state.exclusiveMutationInProgress,
                      !state.removalInProgress,
                      state.reauthCount == 0
                else {
                    lock.unlock()
                    throw AccountError.persistenceFailed
                }
            }
            for id in uniqueIDs {
                var state = states[id] ?? State()
                state.removalInProgress = true
                states[id] = state
            }
            lock.unlock()
            defer {
                lock.lock()
                for id in uniqueIDs {
                    guard var latest = states[id] else { continue }
                    latest.removalInProgress = false
                    if latest.reauthCount == 0, !latest.exclusiveMutationInProgress {
                        states.removeValue(forKey: id)
                    } else {
                        states[id] = latest
                    }
                }
                lock.unlock()
            }
            return try operation()
        }

        func performExclusiveMutation<T>(ids: [String], operation: () throws -> T) throws -> T {
            let uniqueIDs = Array(Set(ids)).sorted()
            lock.lock()
            for id in uniqueIDs {
                let state = states[id] ?? State()
                guard state.reauthCount == 0,
                      !state.removalInProgress,
                      !state.exclusiveMutationInProgress
                else {
                    lock.unlock()
                    throw AccountError.persistenceFailed
                }
            }
            for id in uniqueIDs {
                var state = states[id] ?? State()
                state.exclusiveMutationInProgress = true
                states[id] = state
            }
            lock.unlock()
            defer {
                lock.lock()
                for id in uniqueIDs {
                    guard var state = states[id] else { continue }
                    state.exclusiveMutationInProgress = false
                    if state.reauthCount == 0, !state.removalInProgress {
                        states.removeValue(forKey: id)
                    } else {
                        states[id] = state
                    }
                }
                lock.unlock()
            }
            return try operation()
        }
    }

    /// Immutable account identity used by one provider fetch. The descriptor
    /// binding is captured with the id/URL and held across every provider await.
    struct ActiveSelection: Equatable {
        let id: String
        let authURL: URL
        let authBinding: CodexAuthStore.CredentialFileBinding?

        init(id: String, authURL: URL) {
            self.id = id
            self.authURL = authURL
            if id == "system" {
                self.authBinding = try? CodexAuthStore.bindSystemCredential(at: authURL)
            } else {
                self.authBinding = try? CodexAuthStore.bindCredentialFile(
                    at: authURL,
                    role: "managed:\(id):auth.json")
            }
        }

        init(
            id: String,
            authURL: URL,
            authBinding: CodexAuthStore.CredentialFileBinding?
        ) {
            self.id = id
            self.authURL = authURL
            self.authBinding = authBinding
        }

        static func == (lhs: ActiveSelection, rhs: ActiveSelection) -> Bool {
            lhs.id == rhs.id && lhs.authURL == rhs.authURL
        }
    }

    enum AccountError: LocalizedError {
        case codexNotFound
        case loginFailed
        case noSystemLogin
        case persistenceFailed
        var errorDescription: String? {
            switch self {
            case .codexNotFound: "Không tìm thấy lệnh `codex`. Cài Codex CLI trước."
            case .loginFailed: "Đăng nhập không hoàn tất."
            case .noSystemLogin: "Chưa có đăng nhập hệ thống (~/.codex) để chuyển thành managed."
            case .persistenceFailed: "Không thể lưu thay đổi tài khoản an toàn."
            }
        }
    }

    // MARK: - Paths

    static func systemAuthURL(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configured = CodexAuthStore.authFileURL(env: env)
        guard systemAuthPathIsDisjoint(
            configured, managedAccountsRoot: accountsRootDir())
        else { return disabledSystemAuthURL() }
        return configured
    }

    private static func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BirdNion", isDirectory: true)
    }

    private static func accountsRootDir() -> URL {
        supportDir().appendingPathComponent("codex-accounts", isDirectory: true)
    }

    /// The CLI-owned home and BirdNion's managed-account tree must never
    /// contain one another. Resolving symlinks closes the common alias where
    /// `CODEX_HOME` points at one managed account and both roles become the
    /// same credential file.
    static func systemAuthPathIsDisjoint(
        _ systemAuthURL: URL,
        managedAccountsRoot: URL
    ) -> Bool {
        let systemHome = systemAuthURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let managedRoot = managedAccountsRoot
            .standardizedFileURL.resolvingSymlinksInPath()
        if path(systemHome, contains: managedRoot, caseSensitive: true)
            || path(managedRoot, contains: systemHome, caseSensitive: true) {
            return false
        }

        let overlapsIgnoringCase = path(
            systemHome, contains: managedRoot, caseSensitive: false)
            || path(managedRoot, contains: systemHome, caseSensitive: false)
        guard overlapsIgnoringCase else { return true }

        // A nonexistent suffix keeps its caller-provided casing after symlink
        // resolution. Only treat that spelling as distinct when both backing
        // volumes explicitly confirm case-sensitive names; uncertainty fails closed.
        return volumeSupportsCaseSensitiveNames(at: systemHome) == true
            && volumeSupportsCaseSensitiveNames(at: managedRoot) == true
    }

    private static func path(
        _ parent: URL,
        contains child: URL,
        caseSensitive: Bool
    ) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard parentComponents.count <= childComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { components in
            let (parentComponent, childComponent) = components
            return caseSensitive
                ? parentComponent == childComponent
                : parentComponent.caseInsensitiveCompare(childComponent) == .orderedSame
        }
    }

    private static func volumeSupportsCaseSensitiveNames(at url: URL) -> Bool? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        guard let values = try? candidate.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        else { return nil }
        return values.volumeSupportsCaseSensitiveNames
    }

    /// Read-only callers receive a deterministic nonexistent path when the
    /// configured system home aliases app-managed storage. Every mutating
    /// caller additionally uses `validatedSystemAuthURL()` and fails closed.
    private static func disabledSystemAuthURL() -> URL {
        supportDir()
            .appendingPathComponent("codex-system-auth-disabled", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private static func validatedSystemAuthURL(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let configured = CodexAuthStore.authFileURL(env: env)
        guard systemAuthPathIsDisjoint(
            configured, managedAccountsRoot: accountsRootDir())
        else { throw AccountError.persistenceFailed }
        return configured
    }

    private static func metadataURL() -> URL {
        supportDir().appendingPathComponent("codex-accounts.json")
    }

    static func homeDir(forAccount id: String) -> URL {
        accountsRootDir().appendingPathComponent(id, isDirectory: true)
    }

    private static func fileInfo(at url: URL) throws -> stat? {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path])
    }

    /// Validate each mutable directory entry itself rather than following it.
    /// `createIfMissing` is used only for new managed homes; existing symlink
    /// roots are rejected even when their target is a directory.
    private struct ValidatedAccountsRoot {
        let url: URL
        let identity: CodexAuthStore.FileIdentity
    }

    private struct ValidatedManagedHome {
        let url: URL
        let rootIdentity: CodexAuthStore.FileIdentity
        let identity: CodexAuthStore.FileIdentity
    }

    private static func validatedAccountsRoot(
        createIfMissing: Bool
    ) throws -> ValidatedAccountsRoot? {
        let support = supportDir()
        if try fileInfo(at: support) == nil, createIfMissing {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true)
        }
        guard let supportInfo = try fileInfo(at: support) else { return nil }
        guard supportInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AccountError.persistenceFailed
        }

        let root = accountsRootDir()
        if try fileInfo(at: root) == nil, createIfMissing {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false)
        }
        guard let rootInfo = try fileInfo(at: root) else { return nil }
        guard rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AccountError.persistenceFailed
        }
        return ValidatedAccountsRoot(
            url: root,
            identity: CodexAuthStore.FileIdentity(rootInfo))
    }

    /// Derive the home from the UUID, reject root/home links, and (for
    /// deletion) reject special files anywhere below it before staging.
    private static func validatedManagedHome(
        id: String,
        inspectContents: Bool = false
    ) throws -> ValidatedManagedHome? {
        guard UUID(uuidString: id) != nil else { throw AccountError.persistenceFailed }
        guard let root = try validatedAccountsRoot(createIfMissing: false) else { return nil }
        let home = root.url.appendingPathComponent(id, isDirectory: true)
        guard let homeInfo = try fileInfo(at: home) else { return nil }
        guard homeInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              home.deletingLastPathComponent().standardizedFileURL == root.url.standardizedFileURL,
              home.resolvingSymlinksInPath().standardizedFileURL
                .deletingLastPathComponent() == root.url.resolvingSymlinksInPath().standardizedFileURL
        else { throw AccountError.persistenceFailed }
        let validated = ValidatedManagedHome(
            url: home,
            rootIdentity: root.identity,
            identity: CodexAuthStore.FileIdentity(homeInfo))
        guard inspectContents else { return validated }
        try validateManagedHomeContents(at: home)
        return validated
    }

    /// Pre-flight for deletion: every entry below a managed home must be a
    /// regular file, a directory, or a symlink. Symlinks are allowed because
    /// the Codex CLI plants them under `tmp/arg0` and removal unlinks them
    /// without ever following one (`AT_SYMLINK_NOFOLLOW` / `O_NOFOLLOW`);
    /// the enumerator likewise does not descend into them. Sockets, fifos and
    /// device nodes never belong in a credential home, so those still fail
    /// closed rather than being deleted.
    static func validateManagedHomeContents(at home: URL) throws {
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: home,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            })
        else { throw AccountError.persistenceFailed }
        for case let item as URL in enumerator {
            guard let info = try fileInfo(at: item) else {
                throw AccountError.persistenceFailed
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR)
                || kind == mode_t(S_IFLNK)
            else {
                throw AccountError.persistenceFailed
            }
        }
        guard !traversalFailed else { throw AccountError.persistenceFailed }
    }

    private static func safeManagedHome(id: String) -> URL? {
        do { return try validatedManagedHome(id: id)?.url }
        catch { return nil }
    }

    private static func boundSystemCredential() throws
        -> (url: URL, binding: CodexAuthStore.CredentialFileBinding)
    {
        let url = try validatedSystemAuthURL()
        return (url, try CodexAuthStore.bindSystemCredential(at: url))
    }

    private static func boundManagedCredential(
        id: String,
        inspectContents: Bool = false
    ) throws -> (home: URL, binding: CodexAuthStore.CredentialFileBinding)? {
        guard let home = try validatedManagedHome(
            id: id, inspectContents: inspectContents)
        else { return nil }
        let authURL = home.url.appendingPathComponent("auth.json")
        let binding = try CodexAuthStore.bindManagedCredential(
            accountsRoot: accountsRootDir(),
            accountID: id,
            authURL: authURL,
            expectedAccountsRootIdentity: home.rootIdentity,
            expectedAccountIdentity: home.identity)
        guard binding.isLive else { throw AccountError.persistenceFailed }
        return (home.url, binding)
    }

    // MARK: - Active selection

    static func activeID() -> String {
        UserDefaults.standard.string(forKey: activeKey) ?? "system"
    }

    static func setActive(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        // QuotaService swaps in this account's cached snapshot (instant), then
        // refreshes — see its `.birdnionCodexAccountChanged` observer.
        notifyAccountChanged()
    }

    private static func notifyAccountChanged() {
        NotificationCenter.default.post(name: .birdnionCodexAccountChanged, object: nil)
    }

    /// Credential mutations that can change the provider's current auth file
    /// emit before and after the synchronous filesystem work. The first pulse
    /// invalidates any in-flight result for the old bytes; the second queues a
    /// refresh against the identity that actually reached disk.
    static func performRemovalIdentityBoundary(
        removedID: String,
        activeID: String,
        cliSwitchedID: String?,
        purgeSnapshot: (String) throws -> Void = {
            guard CodexAccountSnapshotStore.shared.removeSnapshot(forAccount: $0) else {
                throw AccountError.persistenceFailed
            }
        },
        mutation: () throws -> Void
    ) rethrows {
        let affectsCurrentIdentity = activeID == removedID || cliSwitchedID == removedID
        guard affectsCurrentIdentity else {
            try mutation()
            return
        }
        try purgeSnapshot(activeID)
        notifyAccountChanged()
        defer { notifyAccountChanged() }
        try mutation()
    }

    /// Orders the destructive parts of managed-account removal. A failed CLI
    /// restore stops before credentials or metadata move; any later failure
    /// invokes the caller's rollback while the original error propagates to
    /// the UI instead of reporting a false success.
    static func performManagedRemovalSteps(
        requiresCLIRestore: Bool,
        restoreCLI: () throws -> Void,
        stageCredentialHome: () throws -> Void,
        persistRemoval: () throws -> Void,
        deleteStagedHome: () throws -> Void,
        rollback: () -> Void
    ) throws {
        if requiresCLIRestore { try restoreCLI() }
        do {
            try stageCredentialHome()
            try persistRemoval()
        } catch {
            rollback()
            throw error
        }
        // Metadata removal is the commit point. Recursive deletion may fail
        // after deleting only part of the staged tree; rolling that partial
        // tree back would resurrect a broken account. Surface cleanup failure
        // while leaving the account removed and the tombstone recoverable.
        try deleteStagedHome()
    }

    /// Resolve the active account id and auth file as one immutable value.
    /// Only an explicit system selection may route to the system credential.
    /// A broken/stale managed selection remains managed but unavailable so a
    /// provider poll cannot silently rotate or report the system identity.
    static func activeSelection() -> ActiveSelection {
        activeSelection(id: activeID(), loadManagedAccounts: managedAccountsForMutation)
    }

    static func activeSelection(
        id: String,
        loadManagedAccounts: () throws -> [CodexAccount]
    ) -> ActiveSelection {
        if id == "system" {
            let authURL = systemAuthURL()
            return ActiveSelection(
                id: "system",
                authURL: authURL,
                authBinding: try? CodexAuthStore.bindSystemCredential(at: authURL))
        }
        do {
            guard try loadManagedAccounts().contains(where: { $0.id == id }),
                  let managed = try boundManagedCredential(id: id)
            else { throw AccountError.persistenceFailed }
            return ActiveSelection(
                id: id,
                authURL: managed.home.appendingPathComponent("auth.json"),
                authBinding: managed.binding)
        } catch {
            return ActiveSelection(
                id: id,
                authURL: unavailableActiveAuthURL(),
                authBinding: nil)
        }
    }

    /// The auth.json the provider should read for the active account.
    static func activeAuthURL() -> URL {
        activeSelection().authURL
    }

    private static func unavailableActiveAuthURL() -> URL {
        supportDir()
            .appendingPathComponent("codex-active-auth-unavailable", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    // MARK: - Listing

    private struct Stored: Codable { var accounts: [Entry] }
    private struct Entry: Codable { var id: String; var email: String?; var homePath: String }

    enum MetadataMutation {
        case add(CodexAccount)
        case remove(String)
        case replace(CodexAccount)
    }

    /// Every app-owned metadata write goes through this short critical
    /// section. Long login awaits happen before it; the commit then reloads
    /// the latest document and applies only its add/remove/replace delta, so
    /// overlapping account operations cannot overwrite or resurrect entries.
    @discardableResult
    static func commitMetadataMutation(
        _ mutation: MetadataMutation,
        load: () throws -> [CodexAccount],
        persist: ([CodexAccount]) throws -> Void
    ) throws -> Bool {
        metadataMutationLock.lock()
        defer { metadataMutationLock.unlock() }
        var latest = try load()
        let changed: Bool
        switch mutation {
        case let .add(account):
            guard !latest.contains(where: { $0.id == account.id }) else {
                throw AccountError.persistenceFailed
            }
            latest.append(account)
            changed = true
        case let .remove(id):
            let previousCount = latest.count
            latest.removeAll { $0.id == id }
            changed = latest.count != previousCount
        case let .replace(account):
            guard let index = latest.firstIndex(where: { $0.id == account.id }) else {
                return false
            }
            changed = latest[index] != account
            latest[index] = account
        }
        if changed { try persist(latest) }
        return changed
    }

    @discardableResult
    private static func commitMetadataMutation(
        _ mutation: MetadataMutation
    ) throws -> Bool {
        try commitMetadataMutation(
            mutation,
            load: managedAccountsForMutation,
            persist: persistUnlocked)
    }

    static func managedAccounts() -> [CodexAccount] {
        do {
            return accounts(from: try loadStored() ?? Stored(accounts: []))
        } catch {
            return []
        }
    }

    /// Mutation callers distinguish genuinely missing metadata from an
    /// existing malformed/link/special/oversized object. Only the former may
    /// start from an empty list; every other condition fails closed.
    private static func managedAccountsForMutation() throws -> [CodexAccount] {
        accounts(from: try loadStored() ?? Stored(accounts: []))
    }

    private static func loadStored() throws -> Stored? {
        guard let data = try CodexAuthStore.readPrivateFile(
            metadataURL(), maximumBytes: maxMetadataBytes)
        else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard validateStoredLocations(stored) else { throw AccountError.persistenceFailed }
        return stored
    }

    private static func accounts(from stored: Stored) -> [CodexAccount] {
        return stored.accounts.map {
            CodexAccount(id: $0.id, email: $0.email, isSystem: false, homePath: $0.homePath)
        }
    }

    /// Persisted paths are display metadata, never deletion authority. Every
    /// managed id must be a UUID and its path must equal the one derived under
    /// BirdNion's account root; duplicates are rejected as ambiguous state.
    private static func validateStoredLocations(_ stored: Stored) -> Bool {
        var ids = Set<String>()
        return stored.accounts.allSatisfy { entry in
            ids.insert(entry.id).inserted
                && isManagedHomePath(
                    id: entry.id,
                    homePath: entry.homePath,
                    accountsRoot: accountsRootDir())
        }
    }

    static func isManagedHomePath(id: String, homePath: String, accountsRoot: URL) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        let expected = accountsRoot
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL.path
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL.path == expected
    }

    /// `preferManagedID`: pass `cliSwitchedID()` so that, after a CLI switch,
    /// the managed account installed at `~/.codex` is listed instead of the
    /// system row (which at that point is just a byte-for-byte mirror of it —
    /// listing the mirror would hide the row carrying the selection marker
    /// and the "In CLI" badge).
    static func allAccounts(preferManagedID: String? = nil) -> [CodexAccount] {
        visibleAccounts(system: CodexAccount(id: "system", email: emailOf(url: systemAuthURL()),
                                             isSystem: true, homePath: nil),
                        managed: managedAccounts(),
                        preferManagedID: preferManagedID)
    }

    static func visibleAccounts(system: CodexAccount, managed: [CodexAccount],
                                preferManagedID: String? = nil) -> [CodexAccount] {
        if system.email == nil, !managed.isEmpty { return managed }
        return reconcile(system: system, managed: managed, preferManagedID: preferManagedID)
    }

    static func fallbackActiveID(afterRemoving removedID: String, from accounts: [CodexAccount]) -> String {
        accounts.first(where: { $0.id != removedID })?.id ?? "system"
    }

    private static func selectedFallback(afterRemoving removedID: String) -> String {
        fallbackActiveID(afterRemoving: removedID, from: allAccounts())
    }

    private static func removedSystemAuthBackupURL(
        for authURL: URL,
        now: Date = Date()
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return authURL.deletingLastPathComponent()
            .appendingPathComponent("auth.json.birdnion-removed-\(stamp)")
    }

    private static func removeSystemLogin() throws {
        try accountOperationFence.performRemoval(id: "system") {
            let system = try boundSystemCredential()
            let fallback = selectedFallback(afterRemoving: "system")
            let existingAuth = try CodexAuthStore.readPrivateFile(system.binding)
            CodexAuthStore.invalidateCredential(binding: system.binding)
            if existingAuth != nil {
                var backupName = removedSystemAuthBackupURL(
                    for: system.url).lastPathComponent
                if try !CodexAuthStore.movePrivateFile(
                    system.binding, toSiblingName: backupName)
                {
                    backupName = "auth.json.birdnion-removed-\(UUID().uuidString)"
                    guard try CodexAuthStore.movePrivateFile(
                        system.binding, toSiblingName: backupName)
                    else { throw AccountError.persistenceFailed }
                }
            }
            setCLISwitchedID(nil)
            if activeID() == "system" { setActive(fallback) }
        }
    }

    static func remove(account: CodexAccount, from visibleAccounts: [CodexAccount]) throws {
        if account.isSystem {
            try removeSystemLogin()
        } else {
            try remove(id: account.id, visibleAccounts: visibleAccounts)
        }
    }

    /// Pure reconciliation: hide a managed account whose email matches an
    /// already-listed one (e.g. the system login) so the same identity isn't
    /// shown twice. Accounts with an unknown email are always kept.
    /// When `preferManagedID` names a managed account whose email mirrors the
    /// system login, the managed row wins and the system mirror is hidden.
    static func reconcile(system: CodexAccount, managed: [CodexAccount],
                          preferManagedID: String? = nil) -> [CodexAccount] {
        if let preferred = managed.first(where: { $0.id == preferManagedID }),
           let preferredEmail = preferred.email?.lowercased(),
           preferredEmail == system.email?.lowercased() {
            var seenEmails: Set<String> = [preferredEmail]
            let rest = managed.filter { account in
                guard account.id != preferred.id else { return false }
                guard let email = account.email?.lowercased() else { return true }
                return seenEmails.insert(email).inserted
            }
            return [preferred] + rest
        }
        var seenEmails = Set<String>()
        if let email = system.email?.lowercased() { seenEmails.insert(email) }
        let deduped = managed.filter { account in
            guard let email = account.email?.lowercased() else { return true }
            return seenEmails.insert(email).inserted
        }
        return [system] + deduped
    }

    /// Copies the current system `~/.codex` login into a new managed home so it
    /// survives even if the user later re-logs-in the system account. Mirrors
    /// CodexBar's account promotion. Throws when no system login exists.
    @discardableResult
    static func promoteSystem() throws -> CodexAccount {
        try accountOperationFence.performExclusiveMutation(ids: ["system"]) {
            let system = try boundSystemCredential()
            let expectation = try CodexAuthStore.captureFileExpectation(
                binding: system.binding)
            return try promoteSystemUnfenced(
                systemBinding: system.binding,
                expectation: expectation)
        }
    }

    private static func promoteSystemUnfenced(
        systemBinding: CodexAuthStore.CredentialFileBinding,
        expectation: CodexAuthStore.FileExpectation
    ) throws -> CodexAccount {
        // Fail before creating a credential home when metadata is corrupt.
        _ = try managedAccountsForMutation()
        guard let sourceData = expectation.data else {
            throw AccountError.noSystemLogin
        }
        guard let sourceCredentials = try? CodexAuthStore.parse(sourceData) else {
            throw AccountError.persistenceFailed
        }
        let id = UUID().uuidString
        guard let root = try validatedAccountsRoot(createIfMissing: true) else {
            throw AccountError.persistenceFailed
        }
        let home = root.url.appendingPathComponent(id, isDirectory: true)
        let destination = try CodexAuthStore.createManagedCredentialBinding(
            accountsRoot: root.url,
            accountID: id,
            expectedAccountsRootIdentity: root.identity)
        do {
            guard try CodexAuthStore.replacePrivateFileIfUnchanged(
                sourceData, to: destination, replacing: nil),
                  CodexAuthStore.documentIsCurrent(
                    binding: systemBinding,
                    expectedData: sourceData,
                    expectedRevision: expectation.revision)
            else {
                throw AccountError.noSystemLogin
            }
        } catch {
            try? destination.removeContainingDirectory()
            throw error
        }
        let account = CodexAccount(
            id: id,
            email: CodexAuthStore.emailFromIDToken(sourceCredentials.idToken),
                                   isSystem: false, homePath: home.path)
        do {
            try commitMetadataMutation(.add(account))
        } catch {
            try? destination.removeContainingDirectory()
            throw error
        }
        return account
    }

    private static func emailOf(url: URL) -> String? {
        guard let credentials = try? CodexAuthStore.load(url: url) else { return nil }
        return CodexAuthStore.emailFromIDToken(credentials.idToken)
    }

    private static func emailOf(
        binding: CodexAuthStore.CredentialFileBinding
    ) -> String? {
        guard let credentials = try? CodexAuthStore.loadDocument(binding: binding).credentials
        else { return nil }
        return CodexAuthStore.emailFromIDToken(credentials.idToken)
    }

    private static func persistUnlocked(_ accounts: [CodexAccount]) throws {
        let entries = accounts.compactMap { account -> Entry? in
            guard let home = account.homePath else { return nil }
            return Entry(id: account.id, email: account.email, homePath: home)
        }
        do {
            // Validate any existing credential-routing document before an
            // atomic replacement. Corruption must never be treated as an
            // empty account list by a subsequent mutation.
            _ = try loadStored()
            try FileManager.default.createDirectory(
                at: supportDir(), withIntermediateDirectories: true)
            let stored = Stored(accounts: entries)
            guard validateStoredLocations(stored) else { throw AccountError.persistenceFailed }
            let data = try JSONEncoder().encode(stored)
            guard data.count <= maxMetadataBytes else { throw AccountError.persistenceFailed }
            try CodexAuthStore.writePrivateFile(
                data, to: metadataURL(), maximumBytes: maxMetadataBytes)
        } catch {
            throw AccountError.persistenceFailed
        }
    }

    // MARK: - Add / re-auth / remove

    /// Creates a fresh managed home and runs `codex login` scoped to it. Blocks
    /// (off-main) until the browser login finishes, then records the account.
    static func addAccount() async throws -> CodexAccount {
        // Strict preflight avoids launching login when metadata is already
        // corrupt. The post-login commit reloads instead of using this view.
        _ = try managedAccountsForMutation()
        let id = UUID().uuidString
        guard let root = try validatedAccountsRoot(createIfMissing: true) else {
            throw AccountError.persistenceFailed
        }
        let home = root.url.appendingPathComponent(id, isDirectory: true)
        let binding = try CodexAuthStore.createManagedCredentialBinding(
            accountsRoot: root.url,
            accountID: id,
            expectedAccountsRootIdentity: root.identity)

        let result = await runLogin(binding: binding)
        let authExists = (try? CodexAuthStore.readPrivateFile(binding)) != nil
        guard result == .success, binding.isLive, authExists else {
            if binding.isLive { try? binding.removeContainingDirectory() }
            if result == .codexNotFound { throw AccountError.codexNotFound }
            throw AccountError.loginFailed
        }
        let account = CodexAccount(id: id, email: emailOf(binding: binding),
                                   isSystem: false, homePath: home.path)
        do {
            try commitMetadataMutation(.add(account))
        } catch {
            if binding.isLive { try? binding.removeContainingDirectory() }
            throw error
        }
        return account
    }

    /// Re-runs `codex login` for an existing account's home (or the system home).
    static func reauth(id: String) async throws {
        try await reauthBound(id: id) { binding in
            let result = await runLogin(binding: binding)
            guard result == .success else {
                throw result == .codexNotFound ? AccountError.codexNotFound : AccountError.loginFailed
            }
        }
    }

    static func reauth(
        id: String,
        login: (String) async throws -> Void
    ) async throws {
        try await reauthBound(id: id) { binding in
            // Test/in-process callers receive the same descriptor path used by
            // the production child, never a swappable managed-home pathname.
            try await login(binding.directoryDescriptorPath)
        }
    }

    private static func reauthBound(
        id: String,
        login: (CodexAuthStore.CredentialFileBinding) async throws -> Void
    ) async throws {
        try accountOperationFence.beginReauthentication(id: id)
        defer { accountOperationFence.finishReauthentication(id: id) }
        let mirrorsSystemCredential = id == "system" || cliSwitchedID() == id
        let system = mirrorsSystemCredential ? try boundSystemCredential() : nil
        let installedSystemDocument: CodexAuthStore.LoadedDocument?
        if id != "system", cliSwitchedID() == id {
            installedSystemDocument = system.flatMap {
                try? CodexAuthStore.loadDocument(binding: $0.binding)
            }
        } else {
            installedSystemDocument = nil
        }
        let home: URL
        let binding: CodexAuthStore.CredentialFileBinding
        if id == "system" {
            guard let system else { throw AccountError.persistenceFailed }
            home = system.url.deletingLastPathComponent()
            binding = system.binding
        } else if try managedAccountsForMutation().contains(where: { $0.id == id }),
                  let managed = try boundManagedCredential(id: id) {
            home = managed.home
            binding = managed.binding
        } else {
            throw AccountError.loginFailed
        }
        CodexAuthStore.invalidateCredential(binding: binding)
        guard CodexAccountSnapshotStore.shared.removeSnapshot(forAccount: id) else {
            throw AccountError.persistenceFailed
        }
        notifyAccountChanged()
        defer { notifyAccountChanged() }
        try await login(binding)
        guard binding.isLive,
              (try? CodexAuthStore.readPrivateFile(binding)) != nil
        else { throw AccountError.loginFailed }
        if id != "system" {
            guard let current = try boundManagedCredential(id: id),
                  current.binding.representsSameEntry(as: binding)
            else { throw AccountError.loginFailed }
            let email = emailOf(binding: binding)
            let refreshedAccount = CodexAccount(
                id: id, email: email, isSystem: false, homePath: home.path)
            try commitMetadataMutation(.replace(refreshedAccount))
            if cliSwitchedID() == id {
                try accountOperationFence.performExclusiveMutation(ids: ["system"]) {
                    guard cliSwitchedID() == id else { return }
                    guard let installedSystemDocument, let system else {
                        clearCLITrackingIfCurrent(id)
                        return
                    }
                    do {
                        let copied = try CodexAuthStore.copyCredentialIfDestinationUnchanged(
                            from: binding,
                            to: system.binding,
                            expectedDestinationData: installedSystemDocument.rawData,
                            expectedDestinationRevision: installedSystemDocument.revision)
                        if !copied { clearCLITrackingIfCurrent(id) }
                    } catch {
                        clearCLITrackingIfCurrent(id)
                        throw error
                    }
                }
            }
        }
    }

    static func remove(id: String) throws {
        try remove(id: id, visibleAccounts: allAccounts())
    }

    private static func remove(id: String, visibleAccounts: [CodexAccount]) throws {
        guard id != "system" else { return }
        try accountOperationFence.performRemoval(ids: [id, "system"]) {
            let fallback = fallbackActiveID(afterRemoving: id, from: visibleAccounts)
            let selectedID = activeID()
            let installedCLIAccountID = cliSwitchedID()
            let accounts = try managedAccountsForMutation()
            let account = accounts.first { $0.id == id }
            let managed = account == nil
                ? nil
                : try boundManagedCredential(id: id, inspectContents: true)
            if let managed {
                CodexAuthStore.invalidateCredential(binding: managed.binding)
            }
            try performRemovalIdentityBoundary(
                removedID: id,
                activeID: selectedID,
                cliSwitchedID: installedCLIAccountID
            ) {
                let stagedName = managed.map { _ in
                    ".birdnion-delete-\(UUID().uuidString)"
                }
                var didStageHome = false
                try performManagedRemovalSteps(
                    requiresCLIRestore: installedCLIAccountID == id,
                    restoreCLI: { try restoreSystemCLIUnfenced() },
                    stageCredentialHome: {
                        if let managed, let stagedName {
                            try managed.binding.stageContainingDirectory(as: stagedName)
                            didStageHome = true
                        }
                    },
                    persistRemoval: {
                        try commitMetadataMutation(.remove(id))
                        if selectedID == id {
                            UserDefaults.standard.set(fallback, forKey: activeKey)
                        }
                    },
                    deleteStagedHome: {
                        if didStageHome, let managed, let stagedName {
                            try managed.binding.removeContainingDirectory(
                                detachedName: stagedName)
                            didStageHome = false
                        }
                    },
                    rollback: {
                        if didStageHome, let managed, let stagedName {
                            try? managed.binding.restoreContainingDirectory(
                                from: stagedName)
                        }
                    })
            }
        }
    }

    // MARK: - codex login

    private static let binaryCacheLock = NSLock()
    private static var cachedBinary: (path: String?, resolvedAt: Date)?
    private static let binaryCacheTTL: TimeInterval = 60

    /// Path to the `codex` executable, if installed.
    ///
    /// Resolution spawns one `codex --version` per candidate path, so the
    /// result is memoized: `ProvidersPane.detectOnboardingSource` calls this
    /// from a SwiftUI body, and probing on every view update stalled the main
    /// thread for seconds. The TTL still picks up a `codex` installed while
    /// the app is running.
    static func codexBinary() -> String? {
        binaryCacheLock.lock()
        defer { binaryCacheLock.unlock() }
        if let cached = cachedBinary,
           Date().timeIntervalSince(cached.resolvedAt) < binaryCacheTTL {
            return cached.path
        }
        let resolved = resolveCodexBinary()
        cachedBinary = (resolved, Date())
        return resolved
    }

    private static func resolveCodexBinary() -> String? {
        for candidate in orderedCodexBinaryCandidates() where isUsableCodexBinary(candidate) {
            return candidate
        }
        if let shellPath = shellResolvedCodexBinary(), isUsableCodexBinary(shellPath) {
            return shellPath
        }
        return nil
    }

    /// `Process.waitUntilExit()` pumps the current run loop while it waits. On
    /// the main thread that re-enters SwiftUI's update cycle mid-body and
    /// crashes AttributeGraph with a null dereference, so wait on the
    /// termination handler instead. The timeout keeps a wedged `codex` from
    /// freezing the UI outright.
    /// Internal for testing.
    static func runAndWait(_ process: Process, timeout: TimeInterval = 5) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    static func orderedCodexBinaryCandidates(home: String = NSHomeDirectory(),
                                             architecture: String = currentArchitecture()) -> [String] {
        let brewCandidates = architecture == "x86_64"
            ? ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
            : ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let homeCandidates = [
            "\(home)/.codex/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.cargo/bin/codex",
        ]
        return uniqueStrings(brewCandidates + homeCandidates + nvmCodexCandidates(home: home) + ["/usr/bin/codex"])
    }

    static func loginSearchPath(binaryPath: String?,
                                inheritedPath: String? = ProcessInfo.processInfo.environment["PATH"],
                                home: String = NSHomeDirectory()) -> String {
        var paths: [String] = []
        if let binaryPath {
            paths.append(URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path)
        }
        paths += [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.codex/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin",
        ]
        paths += nvmCodexCandidates(home: home).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        if let inheritedPath, !inheritedPath.isEmpty {
            paths += inheritedPath.split(separator: ":").map(String.init)
        }
        paths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return uniqueStrings(paths).joined(separator: ":")
    }

    static func firstAbsolutePath(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("/") }
    }

    private static func currentArchitecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            !value.isEmpty && seen.insert(value).inserted
        }
    }

    private static func nvmCodexCandidates(home: String) -> [String] {
        let root = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return versions
            .map { $0.appendingPathComponent("bin/codex").path }
            .sorted(by: >)
    }

    private static func shellResolvedCodexBinary() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": loginSearchPath(binaryPath: nil),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard runAndWait(process) else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return firstAbsolutePath(from: String(data: data, encoding: .utf8) ?? "")
    }

    static func loginEnvironment(homePath: String?, binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let homePath { env["CODEX_HOME"] = homePath }
        env["PATH"] = loginSearchPath(binaryPath: binaryPath, inheritedPath: env["PATH"])
        if env["BROWSER"] == nil || env["BROWSER"]?.isEmpty == true {
            env["BROWSER"] = "/usr/bin/open"
        }
        return env
    }

    /// Environment for commands that must target the CLI-owned system login.
    /// An inherited CODEX_HOME that aliases BirdNion-managed storage disables
    /// the command instead of bypassing the path-role gate.
    static func systemCLIEnvironment(binaryPath: String) -> [String: String]? {
        guard let authURL = try? validatedSystemAuthURL() else { return nil }
        return loginEnvironment(
            homePath: authURL.deletingLastPathComponent().path,
            binaryPath: binaryPath)
    }

    private static func isUsableCodexBinary(_ path: String) -> Bool {
        guard let environment = systemCLIEnvironment(binaryPath: path) else {
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return runAndWait(process)
    }

    /// Runs `codex login` with its cwd installed from the bound directory FD.
    /// macOS cannot traverse `/dev/fd/<dir>/auth.json`, so CODEX_HOME is `.`;
    /// the child cwd itself holds the vnode even if the lexical home is swapped.
    private enum LoginResult: Equatable { case success, codexNotFound, failed }

    private static func runLogin(
        binding: CodexAuthStore.CredentialFileBinding
    ) async -> LoginResult {
        return await Task.detached(priority: .userInitiated) {
            guard let binary = codexBinary() else { return .codexNotFound }
            return runDescriptorBoundProcess(
                executable: binary,
                arguments: ["login"],
                binding: binding)
                ? .success
                : .failed
        }.value
    }

    /// Synchronous test seam and production primitive for a child that must
    /// keep using one bound home even if its lexical account entry is replaced.
    static func runDescriptorBoundProcess(
        executable: String,
        arguments: [String],
        binding: CodexAuthStore.CredentialFileBinding
    ) -> Bool {
        guard binding.isLive else { return false }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addfchdir_np(
            &actions, binding.directoryDescriptor) == 0
        else { return false }

        let argumentStorage: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for case let pointer? in argumentStorage { free(pointer) } }
        var argv = argumentStorage

        let environment = loginEnvironment(
            homePath: ".", binaryPath: executable)
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let environmentStorage: [UnsafeMutablePointer<CChar>?] =
            environmentStrings.map { strdup($0) } + [nil]
        defer { for case let pointer? in environmentStorage { free(pointer) } }
        var envp = environmentStorage

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid, executable, &actions, nil, &argv, &envp)
        guard spawnResult == 0 else { return false }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return false }
        }
        let exitedNormally = status & 0x7f == 0
        let exitCode = (status >> 8) & 0xff
        return exitedNormally && exitCode == 0 && binding.isLive
    }

    // MARK: - CLI switch (install a managed account into ~/.codex)

    /// UserDefaults key tracking which managed account is currently installed
    /// at `~/.codex/auth.json`. Absent/`nil` means the CLI still holds the
    /// original/system login.
    static let cliSwitchedKey = "codexCLISwitchedAccount"

    enum CLISwitchError: LocalizedError {
        case accountNotFound
        var errorDescription: String? {
            switch self {
            case .accountNotFound: "Không tìm thấy tài khoản đã chọn."
            }
        }
    }

    static func cliSwitchedID() -> String? {
        UserDefaults.standard.string(forKey: cliSwitchedKey)
    }

    private static func setCLISwitchedID(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: cliSwitchedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cliSwitchedKey)
        }
    }

    private static func clearCLITrackingIfCurrent(_ id: String) {
        guard cliSwitchedID() == id else { return }
        setCLISwitchedID(nil)
        notifyAccountChanged()
    }

    private static func verifiedCopyMaintainingCLITracking(
        installedID: String,
        from source: CodexAuthStore.CredentialFileBinding,
        to destination: CodexAuthStore.CredentialFileBinding,
        onlyIfSourceNewer: Bool = false
    ) throws -> Bool {
        do {
            switch try CodexAuthStore.copyCredentialIfSameIdentity(
                from: source,
                to: destination,
                onlyIfSourceNewer: onlyIfSourceNewer)
            {
            case .copied:
                return true
            case .unchanged, .notNewer:
                return false
            case .identityMismatch, .unavailable:
                clearCLITrackingIfCurrent(installedID)
                return false
            }
        } catch {
            clearCLITrackingIfCurrent(installedID)
            throw error
        }
    }

    /// One-time pristine backup of the original `~/.codex/auth.json`, written
    /// only on the very first CLI overwrite.
    static func systemBackupURL() -> URL {
        systemBackupURL(for: systemAuthURL())
    }

    private static func systemBackupURL(for systemAuthURL: URL) -> URL {
        systemAuthURL.deletingLastPathComponent()
            .appendingPathComponent("auth.json.birdnion-orig")
    }

    // MARK: Pure decisions (no file I/O — unit-testable)

    /// `true` when the CLI file is strictly newer than the managed copy (or
    /// the managed copy is missing), so a sync-back is warranted. Copying an
    /// equal-or-older file is skipped, making repeated reconciles idempotent.
    static func shouldSyncBack(cliModifiedAt: Date?, managedModifiedAt: Date?) -> Bool {
        guard let cli = cliModifiedAt else { return false }
        guard let managed = managedModifiedAt else { return true }
        return cli > managed
    }

    /// `true` when the original system login's email isn't already among the
    /// managed accounts, meaning it must be promoted before being overwritten.
    static func needsPromoteBeforeOverwrite(systemEmail: String?, managedEmails: [String]) -> Bool {
        guard let systemEmail else { return true }
        let lowered = Set(managedEmails.map { $0.lowercased() })
        return !lowered.contains(systemEmail.lowercased())
    }

    /// Drives the Switch button's disabled state: for a managed account, the
    /// selection must equal the tracked CLI id; for the system account,
    /// nothing must currently be switched in.
    static func isAlreadyCLIIdentity(selectedID: String, trackedID: String?) -> Bool {
        selectedID == "system" ? trackedID == nil : selectedID == trackedID
    }

    // MARK: File-mutating wrappers (atomic 0600 via CodexAuthStore)

    /// Installs the managed account `id`'s login into `~/.codex/auth.json`.
    /// On the first overwrite (tracked id is nil), backs up the original
    /// system login once and promotes it to a managed account if its email
    /// isn't already managed, per the canonical promote-before-overwrite rule.
    static func switchCLI(to id: String) throws {
        try accountOperationFence.performExclusiveMutation(ids: [id, "system"]) {
            guard !isAlreadyCLIIdentity(selectedID: id, trackedID: cliSwitchedID()) else { return }
            try switchCLIUnfenced(to: id)
        }
    }

    private static func switchCLIUnfenced(to id: String) throws {
        let system = try boundSystemCredential()
        let systemExpectation = try CodexAuthStore.captureFileExpectation(
            binding: system.binding)
        let backup = systemBackupURL(for: system.url)
        let backupBinding = try system.binding.sibling(
            fileName: backup.lastPathComponent,
            role: "system:auth-backup")
        let managedAccounts = try managedAccountsForMutation()
        guard managedAccounts.contains(where: { $0.id == id }),
              let managed = try boundManagedCredential(id: id)
        else {
            throw CLISwitchError.accountNotFound
        }

        // No original system login to preserve (e.g. a machine that only
        // ever used app-managed accounts, never `codex login` in a
        // terminal) — nothing to back up or promote, just install.
        let hasSystemLogin = systemExpectation.data != nil
        if hasSystemLogin, cliSwitchedID() == nil {
            if try CodexAuthStore.readPrivateFile(backupBinding) == nil {
                guard let originalData = systemExpectation.data,
                      try CodexAuthStore.replacePrivateFileIfUnchanged(
                        originalData, to: backupBinding, replacing: nil)
                else {
                    throw AccountError.noSystemLogin
                }
            }
            let systemEmail = systemExpectation.data
                .flatMap { try? CodexAuthStore.parse($0) }
                .flatMap { CodexAuthStore.emailFromIDToken($0.idToken) }
            let managedEmails = managedAccounts.compactMap(\.email)
            if needsPromoteBeforeOverwrite(systemEmail: systemEmail, managedEmails: managedEmails) {
                _ = try? promoteSystemUnfenced(
                    systemBinding: system.binding,
                    expectation: systemExpectation)
            }
        }

        guard try CodexAuthStore.copyCredential(
            from: managed.binding,
            to: system.binding,
            ifDestinationMatches: systemExpectation)
        else {
            throw AccountError.loginFailed
        }
        setCLISwitchedID(id)
    }

    /// Restores `~/.codex/auth.json` from the pristine backup and clears the
    /// tracked id. No-op when no switch has ever happened (no backup exists).
    static func restoreSystemCLI() throws {
        try accountOperationFence.performExclusiveMutation(ids: ["system"]) {
            try restoreSystemCLIUnfenced()
        }
    }

    /// Mirrors an app-refreshed managed token into the still-tracked CLI
    /// copy. The account id, metadata path, and system identity are all
    /// revalidated under the same per-account fence before any overwrite.
    @discardableResult
    static func syncRefreshedCredentialToCLI(
        accountID id: String,
        sourceBinding: CodexAuthStore.CredentialFileBinding
    ) -> Bool {
        guard id != "system", cliSwitchedID() == id else { return false }
        do {
            return try accountOperationFence.performExclusiveMutation(ids: [id, "system"]) {
                let system = try boundSystemCredential()
                guard cliSwitchedID() == id,
                      let accounts = try? managedAccountsForMutation(),
                      accounts.contains(where: { $0.id == id }),
                      let managed = try boundManagedCredential(id: id),
                      managed.binding.representsSameEntry(as: sourceBinding),
                      sourceBinding.isLive
                else {
                    clearCLITrackingIfCurrent(id)
                    return false
                }
                return try verifiedCopyMaintainingCLITracking(
                    installedID: id,
                    from: sourceBinding,
                    to: system.binding)
            }
        } catch {
            // Another fenced operation owns this identity; it will either
            // install its own bytes or invalidate this refresh snapshot.
            return false
        }
    }

    private static func restoreSystemCLIUnfenced() throws {
        let system = try boundSystemCredential()
        let backup = systemBackupURL(for: system.url)
        let backupBinding = try system.binding.sibling(
            fileName: backup.lastPathComponent,
            role: "system:auth-backup")
        guard try CodexAuthStore.readPrivateFile(backupBinding) != nil else {
            throw AccountError.noSystemLogin
        }
        guard try CodexAuthStore.copyCredential(
            from: backupBinding, to: system.binding)
        else {
            throw AccountError.noSystemLogin
        }
        setCLISwitchedID(nil)
    }

    /// Copies `~/.codex/auth.json` back into the tracked managed account's
    /// home when the CLI has rotated its token since the last sync, so the
    /// managed copy never goes stale. Best-effort: any failure is swallowed.
    @discardableResult
    static func reconcileCLISyncBack() -> Bool {
        guard let id = cliSwitchedID(), id != "system" else { return false }
        do {
            return try accountOperationFence.performExclusiveMutation(ids: [id, "system"]) {
                let system = try boundSystemCredential()
                guard cliSwitchedID() == id else { return false }
                guard let accounts = try? managedAccountsForMutation(),
                      accounts.contains(where: { $0.id == id }),
                      let managed = try boundManagedCredential(id: id)
                else {
                    clearCLITrackingIfCurrent(id)
                    return false
                }
                switch try CodexAuthStore.reconcileCredentialPair(
                    first: system.binding,
                    second: managed.binding)
                {
                case .copiedFirstToSecond, .copiedSecondToFirst:
                    return true
                case .unchanged:
                    return false
                case .identityMismatch, .ambiguous, .unavailable:
                    clearCLITrackingIfCurrent(id)
                    return false
                }
            }
        } catch {
            return false
        }
    }
}

// MARK: - Codex 5h-window auto-prime

/// Opt-in scheduled "prime" of the Codex 5-hour rate-limit window: sends one
/// trivial, harmless `codex exec` request at a user-chosen time each day so
/// the window's reset cycle starts predictably (the window only begins
/// counting from the first request). Targets whichever login is currently
/// installed at `~/.codex/auth.json` — the same identity `CodexAccountStore`
/// manages above. Settings are the three `SettingsStore` keys
/// `codexAutoPrimeEnabled`/`codexAutoPrimeMinutes`/`codexAutoPrimeLastRun`.
enum CodexQuotaPrimer {
    private static let enabledKey = "codexAutoPrimeEnabled"
    private static let minutesKey = "codexAutoPrimeMinutes"
    private static let lastRunKey = "codexAutoPrimeLastRun"

    // MARK: Pure decision (no I/O, no ambient Date())

    /// `true` only when: enabled, the 5h window is idle (not yet used today),
    /// the scheduled time has arrived or passed, and no prime has happened
    /// yet on this calendar day. The same rule serves both "prime on time"
    /// and "catch-up after a missed/asleep schedule" — whichever tick first
    /// satisfies "past scheduled + not primed today" fires the prime.
    static func shouldPrime(now: Date,
                            lastRun: Double,
                            scheduledMinutes: Int,
                            windowUsedPct: Int?,
                            enabled: Bool) -> Bool {
        guard enabled else { return false }
        if let usedPct = windowUsedPct, usedPct > 0 { return false }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= scheduledMinutes else { return false }
        if lastRun > 0, calendar.isDate(Date(timeIntervalSince1970: lastRun), inSameDayAs: now) {
            return false
        }
        return true
    }

    // MARK: Executor

    /// Spawns a trivial, read-only, non-interactive `codex exec` against the
    /// currently installed `~/.codex` login (no `CODEX_HOME` override) — just
    /// enough to start the 5h clock. Never uses a dangerous bypass flag.
    /// Missing binary is a silent no-op (no stamp, no crash, returns `false`).
    /// Best-effort: any spawn failure is swallowed and still stamps `lastRun`
    /// so a broken `codex` install doesn't retry every refresh cycle for the
    /// rest of the day. Never logs token/credential/response content.
    /// Returns `true` only when the process actually ran and exited cleanly
    /// (`terminationStatus == 0`) — the wiring layer uses this to decide
    /// whether to surface the "primed" notification.
    @discardableResult
    static func prime(now: Date) async -> Bool {
        guard let binary = CodexAccountStore.codexBinary(),
              let environment = CodexAccountStore.systemCLIEnvironment(binaryPath: binary)
        else { return false }
        let succeeded = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"]
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRunKey)
        return succeeded
    }

    // MARK: Wiring entry (called once per codex refresh cycle)

    /// Reads the current settings + the codex 5h window's `usedPct`, decides
    /// via `shouldPrime`, and awaits `prime()` when true. No-op (including no
    /// UserDefaults read side effects beyond the three keys) when disabled.
    /// Returns `true` only when a prime was attempted AND succeeded, so the
    /// caller (`QuotaService`) can post the optional "primed HH:mm" notification.
    @discardableResult
    static func tick(windowUsedPct: Int?, now: Date) async -> Bool {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: enabledKey)
        guard enabled else { return false }
        let scheduledMinutes = defaults.object(forKey: minutesKey) as? Int ?? 535
        let lastRun = defaults.double(forKey: lastRunKey)
        guard shouldPrime(now: now, lastRun: lastRun, scheduledMinutes: scheduledMinutes,
                          windowUsedPct: windowUsedPct, enabled: enabled)
        else { return false }
        return await prime(now: now)
    }
}
