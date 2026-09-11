import Foundation

/// Persists the last successful `ProviderStatus` per account so switching
/// accounts shows the previous numbers immediately (instead of a blank card)
/// and survives across relaunches. Mirrors CodexBar's per-account usage
/// snapshot store.
///
/// Shared by every provider that has more than one account; each gets its own
/// file and its own key space (Codex uses account ids, Antigravity uses account
/// labels). Best-effort: any read/write failure is swallowed — this is a UX
/// nicety, not a source of truth.
final class AccountSnapshotStore: @unchecked Sendable {
    /// Keyed by `CodexAccountStore` account id ("system" or a managed UUID).
    static let codex = AccountSnapshotStore(fileName: "codex-account-snapshots.json")

    /// Keyed by `AntigravityOAuth` account label. Fetching another account costs
    /// a fresh `agy` spawn, so the popover renders these cached snapshots rather
    /// than polling every account on every cycle.
    static let antigravity = AccountSnapshotStore(
        fileName: "antigravity-account-snapshots.json")
    private static let maxStoredBytes = 2 * 1024 * 1024

    private let lock = NSLock()
    private var loaded = false
    private var cache: [String: ProviderStatus] = [:]
    private let fileURL: URL

    /// `fileURL` is injectable for tests; production derives it from `fileName`.
    init(fileURL: URL? = nil, fileName: String = "codex-account-snapshots.json") {
        self.fileURL = fileURL ?? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return base
                .appendingPathComponent("BirdNion", isDirectory: true)
                .appendingPathComponent(fileName)
        }()
    }

    /// Last snapshot for `id`, or nil when none has been stored.
    func snapshot(forAccount id: String) -> ProviderStatus? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return cache[id]
    }

    /// Returns a snapshot only while it is recent enough to be presented as
    /// live quota. The persisted value remains available for a later refresh,
    /// but a failed poll can never make old percentages look current forever.
    func freshSnapshot(
        forAccount id: String,
        now: Date = Date(),
        maxAge: TimeInterval
    ) -> ProviderStatus? {
        guard let snapshot = snapshot(forAccount: id),
              now.timeIntervalSince(snapshot.lastUpdated) < maxAge
        else { return nil }
        return snapshot
    }

    /// Store a successful status for `id` and persist to disk. Error statuses
    /// are ignored so a transient failure never overwrites good cached data.
    func save(_ status: ProviderStatus, forAccount id: String) {
        guard status.error == nil, !status.windows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        cache[id] = status
        _ = persist()
    }

    /// Credential mutation invalidates the previous successful snapshot even
    /// when the logical account id stays the same (for example re-auth from
    /// Alice to Bob). Removing it before the mutation's first notification
    /// prevents an observer from immediately re-applying stale quota.
    @discardableResult
    func removeSnapshot(forAccount id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let previous = cache.removeValue(forKey: id) else { return true }
        guard persist() else {
            cache[id] = previous
            return false
        }
        return true
    }

    // MARK: - Disk

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? CodexAuthStore.readPrivateFile(
                  fileURL, maximumBytes: Self.maxStoredBytes),
              let decoded = try? JSONDecoder().decode([String: ProviderStatus].self, from: data)
        else { return }
        cache = decoded
    }

    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(cache)
            guard data.count <= Self.maxStoredBytes else { return false }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CodexAuthStore.writePrivateFile(
                data, to: fileURL, maximumBytes: Self.maxStoredBytes)
            return true
        } catch {
            return false
        }
    }
}

extension AccountSnapshotStore {
    /// Snapshot for the account Codex is currently fetching. Codex-only: it
    /// resolves the id through `CodexAccountStore`.
    func currentCodexSnapshot() -> ProviderStatus? {
        snapshot(forAccount: CodexAccountStore.activeSelection().id)
    }
}
