import Foundation
import Darwin

struct FirstLiveCheckpoint: Codable, Equatable {
    let attemptId: String
    let providerId: String
    let source: String
    let setupSavedAtMs: Int64
    let probeStartedAtMs: Int64
    let freshResultReceivedAtMs: Int64
    let liveRenderedAtMs: Int64
    let appVersion: String
    let platform: String

    static let supportedProviderIds: Set<String> = ["claude", "codex", "grok"]
    static let allowedSourcesByProvider: [String: Set<String>] = [
        "claude": ["Claude Code", "Claude CLI", "Claude Code / CLI"],
        "codex": ["Codex login", "Codex CLI", "Codex login / CLI"],
        "grok": ["Grok login", "Grok sessions", "Grok login / sessions"],
    ]
    private static let maxFutureSkewMilliseconds: Int64 = 5 * 60 * 1_000

    var verifiedAt: Date {
        Date(timeIntervalSince1970: Double(liveRenderedAtMs) / 1_000)
    }

    var durationMilliseconds: Int64 {
        max(0, liveRenderedAtMs - probeStartedAtMs)
    }

    var isValid: Bool {
        Self.isAllowedAttemptId(attemptId)
            && Self.supportedProviderIds.contains(providerId)
            && Self.allowedSourcesByProvider[providerId]?.contains(source) == true
            && setupSavedAtMs > 0
            && setupSavedAtMs <= probeStartedAtMs
            && probeStartedAtMs <= freshResultReceivedAtMs
            && freshResultReceivedAtMs <= liveRenderedAtMs
            && liveRenderedAtMs <= Self.latestAcceptedTimestampMilliseconds
            && appVersion == Self.safeAppVersion(appVersion)
            && (platform == "macos" || platform == "linux")
    }

    private static func isAllowedAttemptId(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression) != nil
    }

    static func safeAppVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              trimmed.utf8.count <= 64,
              trimmed.range(
                  of: #"^[0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9][A-Za-z0-9.-]{0,31})?$"#,
                  options: .regularExpression) != nil,
              trimmed.lowercased() != "unknown"
        else { return nil }
        return trimmed
    }

    private static var latestAcceptedTimestampMilliseconds: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            + maxFutureSkewMilliseconds
    }
}

struct FirstLiveAttempt: Equatable {
    let attemptId: String
    let providerId: String
    let source: String
    let setupSavedAtMs: Int64
    let probeStartedAtMs: Int64
    let appVersion: String
    let platform: String

    static func begin(
        providerId: String,
        detectedSource: String,
        setupSavedAt: Date = Date(),
        probeStartedAt: Date = Date(),
        attemptId: UUID = UUID(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        platform: String = "macos"
    ) -> FirstLiveAttempt? {
        guard FirstLiveCheckpoint.supportedProviderIds.contains(providerId),
              let appVersion = FirstLiveCheckpoint.safeAppVersion(appVersion)
        else { return nil }
        let setupMs = milliseconds(setupSavedAt)
        let probeMs = max(setupMs, milliseconds(probeStartedAt))
        return FirstLiveAttempt(
            attemptId: attemptId.uuidString.lowercased(),
            providerId: providerId,
            source: safeSource(providerId: providerId, detectedSource: detectedSource),
            setupSavedAtMs: setupMs,
            probeStartedAtMs: probeMs,
            appVersion: appVersion,
            platform: platform)
    }

    func completed(
        freshResultReceivedAt: Date = Date(),
        liveRenderedAt: Date = Date()
    ) -> FirstLiveCheckpoint {
        let freshMs = max(probeStartedAtMs, Self.milliseconds(freshResultReceivedAt))
        let renderedMs = max(freshMs, Self.milliseconds(liveRenderedAt))
        return FirstLiveCheckpoint(
            attemptId: attemptId,
            providerId: providerId,
            source: source,
            setupSavedAtMs: setupSavedAtMs,
            probeStartedAtMs: probeStartedAtMs,
            freshResultReceivedAtMs: freshMs,
            liveRenderedAtMs: renderedMs,
            appVersion: appVersion,
            platform: platform)
    }

    private static func safeSource(providerId: String, detectedSource: String) -> String {
        if FirstLiveCheckpoint.allowedSourcesByProvider[providerId]?.contains(detectedSource) == true {
            return detectedSource
        }
        switch providerId {
        case "claude": return "Claude Code / CLI"
        case "codex": return "Codex login / CLI"
        default: return "Grok login / sessions"
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

protocol FirstLiveCheckpointDefaults: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func synchronize() -> Bool
}

extension UserDefaults: FirstLiveCheckpointDefaults {}

enum FirstLiveCheckpointStore {
    enum SaveOutcome: Equatable {
        case committed
        case rejected
        case indeterminate
    }

    static let defaultsKey = "birdnion.firstLiveCheckpoints.v1"
    private static let recoveryKey = "\(defaultsKey).recovery"
    private static let maxStoredBytes = 64 * 1024
    private static let maxRecoveryBytes = maxStoredBytes * 2
    private static let maxFileJournalBytes = maxStoredBytes * 3
    private static let maxFileCommitMarkerBytes = 64
    private static let processLock = NSLock()

    private struct RecoveryMarker: Codable {
        let version: Int
        let hadPreviousValue: Bool
        let previousData: Data?
    }

    private enum StoredCheckpoints {
        case missing
        case valid([String: FirstLiveCheckpoint])
        case corrupt
    }

    private enum StoredRecovery {
        case missing
        case valid(RecoveryMarker, encodedData: Data)
        case corrupt
    }

    private enum StoredFile {
        case missing(canMutate: Bool)
        case valid(
            [String: FirstLiveCheckpoint],
            encodedData: Data,
            canMutate: Bool)
        case corrupt
    }

    private struct FileRecoveryJournal: Codable {
        let version: Int
        let transactionId: String
        let previousData: Data?
        let candidateData: Data
    }

    /// One bound parent and one sibling lock cover the whole recovery/read/
    /// install transaction. File operations below use these bindings only;
    /// `isLive` is the sole lexical route re-check.
    private final class FileTransaction {
        let main: CodexAuthStore.CredentialFileBinding
        let pending: CodexAuthStore.CredentialFileBinding
        let commit: CodexAuthStore.CredentialFileBinding
        private let parentURL: URL
        private let parentIdentity: CodexAuthStore.FileIdentity
        private var lockDescriptor: Int32 = -1

        init(url: URL) throws {
            main = try CodexAuthStore.bindCredentialFile(
                at: url,
                role: "first-live:main")
            pending = try main.sibling(
                fileName: ".\(main.fileName).pending",
                role: "first-live:pending")
            commit = try main.sibling(
                fileName: ".\(main.fileName).commit",
                role: "first-live:commit")
            parentURL = url.deletingLastPathComponent().standardizedFileURL
            var parentInfo = stat()
            guard parentURL.path.withCString({ lstat($0, &parentInfo) }) == 0,
                  parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else { throw Self.error(parentURL.path) }
            parentIdentity = CodexAuthStore.FileIdentity(parentInfo)

            let lockName = ".\(main.fileName).lock"
            let descriptor = lockName.withCString {
                openat(
                    main.directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600))
            }
            guard descriptor >= 0 else { throw Self.error(url.path) }
            do {
                var opened = stat()
                guard fstat(descriptor, &opened) == 0,
                      opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      opened.st_nlink == 1,
                      fchmod(descriptor, mode_t(0o600)) == 0,
                      birdNionFlock(descriptor, LOCK_EX) == 0
                else { throw Self.error(url.path) }
                var linked = stat()
                let linkedResult = lockName.withCString {
                    fstatat(
                        main.directoryDescriptor,
                        $0,
                        &linked,
                        AT_SYMLINK_NOFOLLOW)
                }
                guard linkedResult == 0,
                      linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      linked.st_nlink == 1,
                      linked.st_dev == opened.st_dev,
                      linked.st_ino == opened.st_ino,
                      isLive
                else { throw Self.error(url.path, code: ESTALE) }
                lockDescriptor = descriptor
            } catch {
                _ = birdNionFlock(descriptor, LOCK_UN)
                close(descriptor)
                throw error
            }
        }

        deinit {
            guard lockDescriptor >= 0 else { return }
            _ = birdNionFlock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }

        var directoryDescriptor: Int32 { main.directoryDescriptor }

        var isLive: Bool {
            guard main.isLive else { return false }
            var current = stat()
            guard parentURL.path.withCString({ lstat($0, &current) }) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else { return false }
            return CodexAuthStore.FileIdentity(current) == parentIdentity
        }

        private static func error(
            _ path: String,
            code: Int32 = errno
        ) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path])
        }
    }

    private enum StoredFileJournal {
        case missing
        case orphanCommit
        case pending(FileRecoveryJournal)
        case committed(FileRecoveryJournal)
        case corrupt
    }

    static func storageURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("BirdNion", isDirectory: true)
            .appendingPathComponent("first-live-checkpoints-v1.json")
    }

    static func load() -> [String: FirstLiveCheckpoint] {
        serialized {
            loadFileLocked(url: storageURL(), legacyDefaults: UserDefaults.standard)
        }
    }

    static func load(url: URL) -> [String: FirstLiveCheckpoint] {
        serialized { loadFileLocked(url: url, legacyDefaults: nil) }
    }

    static func load(
        defaults: FirstLiveCheckpointDefaults
    ) -> [String: FirstLiveCheckpoint] {
        serialized { loadDefaultsLocked(defaults: defaults) }
    }

    private static func loadDefaultsLocked(
        defaults: FirstLiveCheckpointDefaults
    ) -> [String: FirstLiveCheckpoint] {
        switch readRecovery(stored: defaults.object(forKey: recoveryKey)) {
        case .valid(let marker, let encodedData):
            let checkpoints = recoveredCheckpoints(from: marker)
            _ = restore(marker, encodedData: encodedData, defaults: defaults)
            return checkpoints
        case .corrupt:
            return [:]
        case .missing:
            break
        }
        switch read(stored: defaults.object(forKey: defaultsKey)) {
        case .valid(let checkpoints): return checkpoints
        case .missing, .corrupt: return [:]
        }
    }

    private static func read(stored: Any?) -> StoredCheckpoints {
        guard let stored else { return .missing }
        guard let data = stored as? Data,
              data.count <= maxStoredBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let entries = object as? [String: Any],
              entries.count <= FirstLiveCheckpoint.supportedProviderIds.count,
              Set(entries.keys).isSubset(of: FirstLiveCheckpoint.supportedProviderIds)
        else { return .corrupt }
        let decoder = JSONDecoder()
        let checkpoints = entries.reduce(into: [String: FirstLiveCheckpoint]()) { result, entry in
            guard JSONSerialization.isValidJSONObject(entry.value),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry.value),
                  let checkpoint = try? decoder.decode(FirstLiveCheckpoint.self, from: entryData),
                  entry.key == checkpoint.providerId,
                  checkpoint.isValid
            else { return }
            result[entry.key] = checkpoint
        }
        return .valid(checkpoints)
    }

    private static func readRecovery(stored: Any?) -> StoredRecovery {
        guard let stored else { return .missing }
        guard let data = stored as? Data,
              data.count <= maxRecoveryBytes,
              let marker = try? JSONDecoder().decode(RecoveryMarker.self, from: data),
              marker.version == 1,
              marker.hadPreviousValue == (marker.previousData != nil)
        else { return .corrupt }
        if let previousData = marker.previousData {
            guard previousData.count <= maxStoredBytes,
                  case .valid = read(stored: previousData)
            else { return .corrupt }
        }
        return .valid(marker, encodedData: data)
    }

    private static func recoveredCheckpoints(
        from marker: RecoveryMarker
    ) -> [String: FirstLiveCheckpoint] {
        guard let previousData = marker.previousData,
              case .valid(let checkpoints) = read(stored: previousData)
        else { return [:] }
        return checkpoints
    }

    private static func restore(
        _ marker: RecoveryMarker,
        encodedData: Data,
        defaults: FirstLiveCheckpointDefaults
    ) -> Bool {
        guard writeAndConfirm(marker.previousData, forKey: defaultsKey, defaults: defaults) else {
            return false
        }
        return clearRecovery(encodedData: encodedData, defaults: defaults)
    }

    private static func clearRecovery(
        encodedData: Data,
        defaults: FirstLiveCheckpointDefaults
    ) -> Bool {
        defaults.set(nil, forKey: recoveryKey)
        let didSynchronize = defaults.synchronize()
        let isAbsent = defaults.object(forKey: recoveryKey) == nil
        guard didSynchronize, isAbsent else {
            // Re-establish the quarantine for adapters when possible. Save
            // outcome is never downgraded after the candidate itself received
            // a positive durability/readback acknowledgment.
            defaults.set(encodedData, forKey: recoveryKey)
            _ = defaults.synchronize()
            return false
        }
        return true
    }

    private static func writeAndConfirm(
        _ data: Data?,
        forKey key: String,
        defaults: FirstLiveCheckpointDefaults
    ) -> Bool {
        defaults.set(data, forKey: key)
        let didSynchronize = defaults.synchronize()
        let readback = defaults.object(forKey: key)
        let matches = data.map { readback as? Data == $0 } ?? (readback == nil)
        return didSynchronize && matches
    }

    @discardableResult
    static func save(_ checkpoint: FirstLiveCheckpoint) -> SaveOutcome {
        serialized {
            saveFileLocked(
                checkpoint,
                url: storageURL(),
                legacyDefaults: UserDefaults.standard,
                beforeMainCommit: {},
                commitSlotDirectorySync: { true })
        }
    }

    @discardableResult
    static func save(_ checkpoint: FirstLiveCheckpoint, url: URL) -> SaveOutcome {
        serialized {
            saveFileLocked(
                checkpoint,
                url: url,
                legacyDefaults: nil,
                beforeMainCommit: {},
                commitSlotDirectorySync: { true })
        }
    }

#if DEBUG
    static func saveForTesting(
        _ checkpoint: FirstLiveCheckpoint,
        url: URL,
        legacyDefaults: FirstLiveCheckpointDefaults,
        beforeMainCommit: @escaping () -> Void = {},
        afterMainCommit: @escaping () -> Void = {},
        commitSlotDirectorySync: @escaping () -> Bool = { true },
        afterCommitMarkerRead: @escaping () -> Void = {},
        commitMarkerInvalidationSync: @escaping () -> Bool = { true },
        beforeCommitMarkerInvalidation: @escaping () throws -> Void = {},
        beforeRollback: @escaping () throws -> Void = {}
    ) -> SaveOutcome {
        serialized {
            saveFileLocked(
                checkpoint,
                url: url,
                legacyDefaults: legacyDefaults,
                beforeMainCommit: beforeMainCommit,
                afterMainCommit: afterMainCommit,
                commitSlotDirectorySync: commitSlotDirectorySync,
                afterCommitMarkerRead: afterCommitMarkerRead,
                commitMarkerInvalidationSync: commitMarkerInvalidationSync,
                beforeCommitMarkerInvalidation: beforeCommitMarkerInvalidation,
                beforeRollback: beforeRollback)
        }
    }
#endif

    @discardableResult
    static func save(
        _ checkpoint: FirstLiveCheckpoint,
        defaults: FirstLiveCheckpointDefaults
    ) -> Bool {
        serialized { saveDefaultsLocked(checkpoint, defaults: defaults) }
    }

    private static func saveDefaultsLocked(
        _ checkpoint: FirstLiveCheckpoint,
        defaults: FirstLiveCheckpointDefaults
    ) -> Bool {
        let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        guard checkpoint.isValid, checkpoint.liveRenderedAtMs <= nowMs else { return false }
        switch readRecovery(stored: defaults.object(forKey: recoveryKey)) {
        case .valid(let marker, let encodedData):
            guard restore(marker, encodedData: encodedData, defaults: defaults) else {
                return false
            }
        case .corrupt:
            return false
        case .missing:
            break
        }
        let previousValue = defaults.object(forKey: defaultsKey)
        var checkpoints: [String: FirstLiveCheckpoint]
        let previousData: Data?
        switch read(stored: previousValue) {
        case .missing:
            checkpoints = [:]
            previousData = nil
        case .valid(let loaded):
            guard let data = previousValue as? Data else { return false }
            checkpoints = loaded
            previousData = data
        case .corrupt: return false
        }
        if let existing = checkpoints[checkpoint.providerId],
           existing.liveRenderedAtMs <= nowMs,
           !isNewer(checkpoint, than: existing) {
            return false
        }
        checkpoints[checkpoint.providerId] = checkpoint
        guard let data = try? JSONEncoder().encode(checkpoints) else { return false }
        let marker = RecoveryMarker(
            version: 1,
            hadPreviousValue: previousData != nil,
            previousData: previousData)
        guard let markerData = try? JSONEncoder().encode(marker),
              markerData.count <= maxRecoveryBytes
        else { return false }
        guard writeAndConfirm(markerData, forKey: recoveryKey, defaults: defaults) else {
            // The main value has not changed, so a best-effort marker cleanup
            // cannot expose an unacknowledged candidate.
            defaults.set(nil, forKey: recoveryKey)
            _ = defaults.synchronize()
            return false
        }
        guard writeAndConfirm(data, forKey: defaultsKey, defaults: defaults) else {
            _ = restore(marker, encodedData: markerData, defaults: defaults)
            return false
        }
        // The candidate itself has a positive durability/readback ack. Marker
        // cleanup uncertainty must not turn that committed candidate into a
        // reported failure that a later load could expose.
        _ = clearRecovery(encodedData: markerData, defaults: defaults)
        return true
    }

    private static func loadFileLocked(
        url: URL,
        legacyDefaults: FirstLiveCheckpointDefaults?
    ) -> [String: FirstLiveCheckpoint] {
        guard let transaction = try? openFileTransaction(at: url) else {
            return [:]
        }
        switch resolveFile(transaction: transaction) {
        case .valid(let checkpoints, _, _):
            return transaction.isLive ? checkpoints : [:]
        case .corrupt:
            return [:]
        case .missing(let canMutate):
            guard let legacyDefaults else { return [:] }
            let checkpoints = loadDefaultsLocked(defaults: legacyDefaults)
            guard canMutate,
                  !checkpoints.isEmpty,
                  let data = try? JSONEncoder().encode(checkpoints),
                  installFileTransaction(
                      data,
                      transaction: transaction,
                      replacing: nil,
                      beforeMainCommit: {},
                      afterMainCommit: {},
                      commitSlotDirectorySync: { true },
                      afterCommitMarkerRead: {},
                      commitMarkerInvalidationSync: { true },
                      beforeCommitMarkerInvalidation: {},
                      beforeRollback: {}) == .committed
            else { return checkpoints }
            clearLegacy(defaults: legacyDefaults)
            return checkpoints
        }
    }

    private static func saveFileLocked(
        _ checkpoint: FirstLiveCheckpoint,
        url: URL,
        legacyDefaults: FirstLiveCheckpointDefaults?,
        beforeMainCommit: () -> Void,
        afterMainCommit: () -> Void = {},
        commitSlotDirectorySync: () -> Bool,
        afterCommitMarkerRead: () -> Void = {},
        commitMarkerInvalidationSync: () -> Bool = { true },
        beforeCommitMarkerInvalidation: () throws -> Void = {},
        beforeRollback: () throws -> Void = {}
    ) -> SaveOutcome {
        let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        guard checkpoint.isValid, checkpoint.liveRenderedAtMs <= nowMs else {
            return .rejected
        }
        guard let transaction = try? openFileTransaction(at: url) else {
            return .rejected
        }
        var checkpoints: [String: FirstLiveCheckpoint]
        let expectedData: Data?
        switch resolveFile(transaction: transaction) {
        case .valid(let loaded, let data, let canMutate):
            guard canMutate else { return .rejected }
            checkpoints = loaded
            expectedData = data
        case .missing(let canMutate):
            guard canMutate else { return .rejected }
            checkpoints = legacyDefaults.map { loadDefaultsLocked(defaults: $0) } ?? [:]
            expectedData = nil
        case .corrupt:
            return .rejected
        }
        if let existing = checkpoints[checkpoint.providerId],
           existing.liveRenderedAtMs <= nowMs,
           !isNewer(checkpoint, than: existing) {
            return .rejected
        }
        checkpoints[checkpoint.providerId] = checkpoint
        guard let data = try? JSONEncoder().encode(checkpoints),
              data.count <= maxStoredBytes
        else { return .rejected }
        let outcome = installFileTransaction(
            data,
            transaction: transaction,
            replacing: expectedData,
            beforeMainCommit: beforeMainCommit,
            afterMainCommit: afterMainCommit,
            commitSlotDirectorySync: commitSlotDirectorySync,
            afterCommitMarkerRead: afterCommitMarkerRead,
            commitMarkerInvalidationSync: commitMarkerInvalidationSync,
            beforeCommitMarkerInvalidation: beforeCommitMarkerInvalidation,
            beforeRollback: beforeRollback)
        if outcome == .committed, let legacyDefaults {
            clearLegacy(defaults: legacyDefaults)
        }
        return outcome
    }

    private static func resolveFile(
        transaction: FileTransaction
    ) -> StoredFile {
        switch readFileJournal(transaction: transaction) {
        case .missing:
            return readMainFile(transaction: transaction, canMutate: transaction.isLive)
        case .orphanCommit:
            let cleaned = removePrivateFile(
                transaction.commit,
                transaction: transaction)
            return readMainFile(
                transaction: transaction,
                canMutate: cleaned && transaction.isLive)
        case .pending(let journal):
            let cleaned = reconcile(
                journal.previousData,
                transaction: transaction)
            return storedFile(from: journal.previousData, canMutate: cleaned)
        case .committed(let journal):
            let cleaned = reconcile(
                journal.candidateData,
                transaction: transaction)
            return storedFile(from: journal.candidateData, canMutate: cleaned)
        case .corrupt:
            return .corrupt
        }
    }

    private static func readMainFile(
        transaction: FileTransaction,
        canMutate: Bool
    ) -> StoredFile {
        do {
            guard let data = try readBoundFile(
                transaction.main,
                transaction: transaction,
                maximumBytes: maxStoredBytes)
            else { return .missing(canMutate: canMutate) }
            guard case .valid(let checkpoints) = read(stored: data),
                  transaction.isLive
            else {
                return .corrupt
            }
            return .valid(
                checkpoints,
                encodedData: data,
                canMutate: canMutate)
        } catch {
            return .corrupt
        }
    }

    private static func storedFile(
        from data: Data?,
        canMutate: Bool
    ) -> StoredFile {
        guard let data else { return .missing(canMutate: canMutate) }
        guard case .valid(let checkpoints) = read(stored: data) else {
            return .corrupt
        }
        return .valid(
            checkpoints,
            encodedData: data,
            canMutate: canMutate)
    }

    private static func openFileTransaction(at url: URL) throws -> FileTransaction {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOTDIR),
                    userInfo: [NSFilePathErrorKey: parent.path])
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        return try FileTransaction(url: url)
    }

    /// Bounded regular-file read on the already-bound parent. Unlike the
    /// credential helper, zero-byte commit slots are valid here.
    private static func readBoundFile(
        _ binding: CodexAuthStore.CredentialFileBinding,
        transaction: FileTransaction,
        maximumBytes: Int,
        requireLiveRoute: Bool = true
    ) throws -> Data? {
        guard maximumBytes >= 0,
              !requireLiveRoute || transaction.isLive
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
        }
        let descriptor = binding.fileName.withCString {
            Darwin.openat(
                transaction.directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes
        else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG)) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes,
              data.count == Int(info.st_size),
              !requireLiveRoute || transaction.isLive
        else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE)) }
        return data
    }

    private static func readFileJournal(
        transaction: FileTransaction
    ) -> StoredFileJournal {
        do {
            let pendingData = try readBoundFile(
                transaction.pending,
                transaction: transaction,
                maximumBytes: maxFileJournalBytes)
            let commitData = try readBoundFile(
                transaction.commit,
                transaction: transaction,
                maximumBytes: maxFileCommitMarkerBytes)
            guard let pendingData else {
                return commitData == nil ? .missing : .orphanCommit
            }
            guard pendingData.count <= maxFileJournalBytes,
                  let journal = try? JSONDecoder().decode(
                      FileRecoveryJournal.self,
                      from: pendingData),
                  journal.version == 1,
                  UUID(uuidString: journal.transactionId)?.uuidString.lowercased()
                    == journal.transactionId,
                  journal.candidateData.count <= maxStoredBytes,
                  case .valid = read(stored: journal.candidateData)
            else { return .corrupt }
            if let previousData = journal.previousData {
                guard previousData.count <= maxStoredBytes,
                      case .valid = read(stored: previousData)
                else { return .corrupt }
            }
            guard transaction.isLive else { return .corrupt }
            if commitData == commitMarker(for: journal) {
                let mainData = try readBoundFile(
                    transaction.main,
                    transaction: transaction,
                    maximumBytes: maxStoredBytes)
                return mainData == journal.candidateData
                    ? .committed(journal)
                    : .pending(journal)
            }
            return .pending(journal)
        } catch {
            return .corrupt
        }
    }

    /// The pending journal is durable before the main CAS. Therefore any
    /// conflict, throw, or unreadable main outcome can return false without
    /// making the candidate authoritative. Only an exact commit marker turns
    /// the candidate into a successful transaction.
    private static func installFileTransaction(
        _ data: Data,
        transaction: FileTransaction,
        replacing expectedData: Data?,
        beforeMainCommit: () -> Void,
        afterMainCommit: () -> Void,
        commitSlotDirectorySync: () -> Bool,
        afterCommitMarkerRead: () -> Void,
        commitMarkerInvalidationSync: () -> Bool,
        beforeCommitMarkerInvalidation: () throws -> Void,
        beforeRollback: () throws -> Void
    ) -> SaveOutcome {
        let journal = FileRecoveryJournal(
            version: 1,
            transactionId: UUID().uuidString.lowercased(),
            previousData: expectedData,
            candidateData: data)
        guard let journalData = try? JSONEncoder().encode(journal),
              journalData.count <= maxFileJournalBytes,
              transaction.isLive
        else { return .rejected }
        do {
            guard try CodexAuthStore.replacePrivateFileIfUnchanged(
                journalData,
                to: transaction.pending,
                replacing: nil,
                maximumBytes: maxFileJournalBytes),
                  try readBoundFile(
                      transaction.pending,
                      transaction: transaction,
                      maximumBytes: maxFileJournalBytes) == journalData
            else { return .rejected }
            guard prepareCommitSlot(
                transaction: transaction,
                didSynchronizeDirectory: commitSlotDirectorySync)
            else { return .rejected }
            guard try CodexAuthStore.replacePrivateFileIfUnchanged(
                data,
                to: transaction.main,
                replacing: expectedData,
                maximumBytes: maxStoredBytes,
                beforeCommit: beforeMainCommit),
                  try readBoundFile(
                      transaction.main,
                      transaction: transaction,
                      maximumBytes: maxStoredBytes) == data
            else { return .rejected }
            afterMainCommit()
            guard transaction.isLive else { return .rejected }
        } catch {
            return .rejected
        }
        return writeCommitMarker(
            transaction: transaction,
            marker: commitMarker(for: journal),
            previousData: expectedData,
            candidateData: data,
            afterRead: afterCommitMarkerRead,
            didSynchronizeInvalidation: commitMarkerInvalidationSync,
            beforeInvalidation: beforeCommitMarkerInvalidation,
            beforeRollback: beforeRollback)
    }

    private static func reconcile(
        _ data: Data?,
        transaction: FileTransaction
    ) -> Bool {
        guard transaction.isLive,
              makeMainFileMatch(data, transaction: transaction),
              removePrivateFile(
                  transaction.pending,
                  transaction: transaction),
              removePrivateFile(
                  transaction.commit,
                  transaction: transaction),
              transaction.isLive
        else { return false }
        return true
    }

    private static func makeMainFileMatch(
        _ data: Data?,
        transaction: FileTransaction
    ) -> Bool {
        do {
            guard transaction.isLive else { return false }
            let current = try readBoundFile(
                transaction.main,
                transaction: transaction,
                maximumBytes: maxStoredBytes)
            if current == data { return true }
            guard let data else {
                return removePrivateFile(
                    transaction.main,
                    transaction: transaction)
            }
            guard try CodexAuthStore.replacePrivateFileIfUnchanged(
                data,
                to: transaction.main,
                replacing: current,
                maximumBytes: maxStoredBytes)
            else { return false }
            return try readBoundFile(
                transaction.main,
                transaction: transaction,
                maximumBytes: maxStoredBytes) == data
                && transaction.isLive
        } catch {
            return false
        }
    }

    /// The empty slot is directory-durable before the main file can change.
    /// A crash before its fixed UUID content is file-durable therefore leaves
    /// an invalid marker and recovery chooses the exact previous bytes.
    private static func prepareCommitSlot(
        transaction: FileTransaction,
        didSynchronizeDirectory: () -> Bool
    ) -> Bool {
        guard transaction.isLive else { return false }
        let descriptor = transaction.commit.fileName.withCString {
            Darwin.openat(
                transaction.directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1,
                  Darwin.fchmod(descriptor, mode_t(0o600)) == 0
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try handle.synchronize()
            try handle.close()
            let directorySyncResult = Darwin.fsync(transaction.directoryDescriptor)
            let injectedSyncResult = didSynchronizeDirectory()
            let live = transaction.isLive
            let readback = try? readBoundFile(
                transaction.commit,
                transaction: transaction,
                maximumBytes: maxFileCommitMarkerBytes)
            guard directorySyncResult == 0,
                  injectedSyncResult,
                  live,
                  readback == Data()
            else { return false }
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    private static func writeCommitMarker(
        transaction: FileTransaction,
        marker: Data,
        previousData: Data?,
        candidateData: Data,
        afterRead: () -> Void,
        didSynchronizeInvalidation: () -> Bool,
        beforeInvalidation: () throws -> Void,
        beforeRollback: () throws -> Void
    ) -> SaveOutcome {
        guard marker.count <= maxFileCommitMarkerBytes,
              transaction.isLive
        else { return .rejected }
        let descriptor = transaction.commit.fileName.withCString {
            Darwin.openat(
                transaction.directoryDescriptor,
                $0,
                O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return .rejected }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1,
                  info.st_size == 0,
                  Darwin.fchmod(descriptor, mode_t(0o600)) == 0
            else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try handle.write(contentsOf: marker)
            try handle.synchronize()
            try handle.close()
            if commitMarkerIsExact(
                transaction.commit,
                transaction: transaction,
                expected: marker,
                afterRead: afterRead
            ) { return .committed }
        } catch {
            try? handle.close()
            if commitMarkerIsExact(
                transaction.commit,
                transaction: transaction,
                expected: marker
            ) { return .committed }
        }
        if invalidateCommitSlot(
            transaction: transaction,
            beforeInvalidation: beforeInvalidation,
            didSynchronize: didSynchronizeInvalidation
        ) { return .rejected }
        do {
            try beforeRollback()
        } catch {
            return .indeterminate
        }
        return rollbackMainFile(
            from: candidateData,
            to: previousData,
            transaction: transaction)
            ? .rejected
            : .indeterminate
    }

    private static func invalidateCommitSlot(
        transaction: FileTransaction,
        beforeInvalidation: () throws -> Void,
        didSynchronize: () -> Bool
    ) -> Bool {
        do {
            try beforeInvalidation()
        } catch {
            return false
        }
        let descriptor = transaction.commit.fileName.withCString {
            Darwin.openat(
                transaction.directoryDescriptor,
                $0,
                O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try handle.synchronize()
            try handle.close()
            guard didSynchronize() else { return false }
        } catch {
            try? handle.close()
            return false
        }
        var info = stat()
        let result = transaction.commit.fileName.withCString {
            Darwin.fstatat(
                transaction.directoryDescriptor,
                $0,
                &info,
                AT_SYMLINK_NOFOLLOW)
        }
        return result == 0
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && info.st_size == 0
    }

    /// Last-resort detached-route rollback. The process still owns the bound
    /// directory's flock, so restoring the exact journaled bytes is safe even
    /// when the lexical parent no longer names this directory. Journal
    /// recovery treats an exact commit marker as committed only while main
    /// also equals the candidate.
    private static func rollbackMainFile(
        from candidateData: Data,
        to previousData: Data?,
        transaction: FileTransaction
    ) -> Bool {
        do {
            let current = try readBoundFile(
                transaction.main,
                transaction: transaction,
                maximumBytes: maxStoredBytes,
                requireLiveRoute: false)
            if current == previousData { return true }
            guard current == candidateData else { return false }
            guard let previousData else {
                let result = transaction.main.fileName.withCString {
                    Darwin.unlinkat(transaction.directoryDescriptor, $0, 0)
                }
                guard result == 0,
                      Darwin.fsync(transaction.directoryDescriptor) == 0
                else { return false }
                return try readBoundFile(
                    transaction.main,
                    transaction: transaction,
                    maximumBytes: maxStoredBytes,
                    requireLiveRoute: false) == nil
            }
            let stagedName = ".\(transaction.main.fileName).rollback-\(UUID().uuidString)"
            guard writeBoundFile(
                previousData,
                named: stagedName,
                transaction: transaction)
            else { return false }
            defer {
                _ = stagedName.withCString {
                    Darwin.unlinkat(transaction.directoryDescriptor, $0, 0)
                }
            }
            let exchange = stagedName.withCString { stagedPath in
                transaction.main.fileName.withCString { mainPath in
                    Darwin.renameatx_np(
                        transaction.directoryDescriptor,
                        stagedPath,
                        transaction.directoryDescriptor,
                        mainPath,
                        UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
                }
            }
            guard exchange == 0 else { return false }
            let staged = try transaction.main.sibling(
                fileName: stagedName,
                role: "first-live:rollback-displaced")
            guard try readBoundFile(
                staged,
                transaction: transaction,
                maximumBytes: maxStoredBytes,
                requireLiveRoute: false) == candidateData
            else { return false }
            let removed = stagedName.withCString {
                Darwin.unlinkat(transaction.directoryDescriptor, $0, 0)
            }
            guard removed == 0,
                  Darwin.fsync(transaction.directoryDescriptor) == 0,
                  try readBoundFile(
                      transaction.main,
                      transaction: transaction,
                      maximumBytes: maxStoredBytes,
                      requireLiveRoute: false) == previousData
            else { return false }
            return true
        } catch {
            return false
        }
    }

    private static func writeBoundFile(
        _ data: Data,
        named name: String,
        transaction: FileTransaction
    ) -> Bool {
        guard data.count <= maxStoredBytes else { return false }
        let descriptor = name.withCString {
            Darwin.openat(
                transaction.directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1,
                  Darwin.fchmod(descriptor, mode_t(0o600)) == 0
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return true
        } catch {
            try? handle.close()
            _ = name.withCString {
                Darwin.unlinkat(transaction.directoryDescriptor, $0, 0)
            }
            return false
        }
    }

    private static func commitMarker(
        for journal: FileRecoveryJournal
    ) -> Data {
        Data(journal.transactionId.utf8)
    }

    private static func commitMarkerIsExact(
        _ binding: CodexAuthStore.CredentialFileBinding,
        transaction: FileTransaction,
        expected: Data,
        afterRead: () -> Void = {}
    ) -> Bool {
        guard transaction.isLive else { return false }
        let matches = (try? readBoundFile(
            binding,
            transaction: transaction,
            maximumBytes: maxFileCommitMarkerBytes)) == expected
        afterRead()
        return matches && transaction.isLive
    }

    private static func removePrivateFile(
        _ binding: CodexAuthStore.CredentialFileBinding,
        transaction: FileTransaction,
        requireLiveRoute: Bool = true
    ) -> Bool {
        if requireLiveRoute, !transaction.isLive { return false }
        let result = binding.fileName.withCString {
            Darwin.unlinkat(transaction.directoryDescriptor, $0, 0)
        }
        if result != 0, errno != ENOENT { return false }
        guard Darwin.fsync(transaction.directoryDescriptor) == 0 else {
            return false
        }
        var info = stat()
        let readback = binding.fileName.withCString {
            Darwin.fstatat(
                transaction.directoryDescriptor,
                $0,
                &info,
                AT_SYMLINK_NOFOLLOW)
        }
        guard readback != 0, errno == ENOENT else { return false }
        return !requireLiveRoute || transaction.isLive
    }

    private static func clearLegacy(defaults: FirstLiveCheckpointDefaults) {
        defaults.set(nil, forKey: defaultsKey)
        defaults.set(nil, forKey: recoveryKey)
        _ = defaults.synchronize()
    }

    private static func serialized<T>(_ body: () -> T) -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return body()
    }

    private static func isNewer(
        _ candidate: FirstLiveCheckpoint,
        than existing: FirstLiveCheckpoint
    ) -> Bool {
        if candidate.attemptId == existing.attemptId {
            return candidate.liveRenderedAtMs >= existing.liveRenderedAtMs
        }
        if candidate.setupSavedAtMs != existing.setupSavedAtMs {
            return candidate.setupSavedAtMs > existing.setupSavedAtMs
        }
        return candidate.probeStartedAtMs > existing.probeStartedAtMs
    }
}
