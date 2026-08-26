import Foundation
import Darwin

// Native multi-account store for Claude, mirroring the Claude slice of
// CodexBarCore's TokenAccounts. Stores a list of accounts (each carries a token
// — a web sessionKey or an Admin API key — plus a label and the linked
// organization) and which one is active. Persisted as JSON at
// ~/Library/Application Support/BirdNion/claude-accounts.json with 0600 perms.
// OAuth stays single-account (driven by the system Keychain), so this store
// only governs the web/admin sources + the account switcher UI.

/// One stored Claude account.
struct ClaudeTokenAccount: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    /// Web sessionKey (`sk-ant-…`) or Admin API key, depending on `kind`.
    let token: String
    let kind: Kind
    let addedAt: Date
    var lastUsed: Date?
    /// Account email / login the token resolves to (filled after first fetch).
    var externalIdentifier: String?
    /// Anthropic organization UUID this token belongs to.
    var organizationID: String?

    enum Kind: String, Codable, Sendable {
        case web      // claude.ai sessionKey cookie
        case admin    // Anthropic Admin API key
    }

    init(id: UUID = UUID(),
         label: String,
         token: String,
         kind: Kind,
         addedAt: Date = Date(),
         lastUsed: Date? = nil,
         externalIdentifier: String? = nil,
         organizationID: String? = nil) {
        self.id = id
        self.label = label
        self.token = token
        self.kind = kind
        self.addedAt = addedAt
        self.lastUsed = lastUsed
        self.externalIdentifier = externalIdentifier
        self.organizationID = organizationID
    }

    /// Best display name: explicit label → external identifier → kind.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let ext = externalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !ext.isEmpty {
            return ext
        }
        return kind == .admin ? "Admin key" : "Web session"
    }
}

/// The persisted account list + which one is active.
struct ClaudeTokenAccountData: Codable, Equatable, Sendable {
    var version: Int
    var accounts: [ClaudeTokenAccount]
    var activeIndex: Int

    init(version: Int = 1, accounts: [ClaudeTokenAccount] = [], activeIndex: Int = 0) {
        self.version = version
        self.accounts = accounts
        self.activeIndex = activeIndex
    }

    /// Active index clamped to a valid range (0 when empty).
    func clampedActiveIndex() -> Int {
        guard !accounts.isEmpty else { return 0 }
        return min(max(activeIndex, 0), accounts.count - 1)
    }

    var active: ClaudeTokenAccount? {
        guard !accounts.isEmpty else { return nil }
        return accounts[clampedActiveIndex()]
    }
}

/// File-backed CRUD for the Claude account list.
enum ClaudeTokenAccountStore {
    static let maxStoredBytes = 1 * 1024 * 1024

    enum MutationError: LocalizedError, Equatable {
        case persistenceFailed

        var errorDescription: String? {
            "Không thể lưu thay đổi tài khoản Claude."
        }
    }

    static func defaultURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("BirdNion/claude-accounts.json")
    }

    static func load(url: URL = defaultURL()) -> ClaudeTokenAccountData {
        do {
            guard let data = try readBoundedData(url: url) else {
                return ClaudeTokenAccountData()
            }
            return try JSONDecoder().decode(ClaudeTokenAccountData.self, from: data)
        } catch {
            return ClaudeTokenAccountData()
        }
    }

    /// Mutations may initialize a genuinely missing store, but must never
    /// reinterpret an unreadable or malformed existing credential file as an
    /// empty account list. Doing so would let the next write erase accounts.
    private static func loadForMutation(
        url: URL
    ) -> Result<ClaudeTokenAccountData, MutationError> {
        do {
            guard let data = try readBoundedData(url: url) else {
                return .success(ClaudeTokenAccountData())
            }
            return .success(try JSONDecoder().decode(ClaudeTokenAccountData.self, from: data))
        } catch {
            return .failure(.persistenceFailed)
        }
    }

    /// Open the exact filesystem object without following links, reject
    /// non-regular files before reading, and cap allocation. This keeps a
    /// dangling symlink, FIFO, directory, or oversized existing credential
    /// store from being reinterpreted as a genuinely missing empty store.
    private static func readBoundedData(url: URL) throws -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0,
              info.st_size <= maxStoredBytes,
              let data = try handle.read(upToCount: maxStoredBytes + 1),
              data.count <= maxStoredBytes
        else { throw MutationError.persistenceFailed }
        return data
    }

    @discardableResult
    static func save(_ data: ClaudeTokenAccountData, url: URL = defaultURL()) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let blob = try encoder.encode(data)
            guard blob.count <= maxStoredBytes else { return false }
            // Reuse the app's staged O_EXCL + fchmod(0600) + fsync + atomic
            // rename writer. Permission failure is a persistence failure, not
            // a best-effort warning for a file containing credentials.
            try CodexAuthStore.writePrivateFile(blob, to: url)
            NotificationCenter.default.post(name: .birdnionClaudeAccountChanged, object: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Mutations

    @discardableResult
    static func add(
        _ account: ClaudeTokenAccount,
        url: URL = defaultURL()
    ) -> Result<ClaudeTokenAccountData, MutationError> {
        guard case .success(var data) = loadForMutation(url: url) else {
            return .failure(.persistenceFailed)
        }
        data.accounts.append(account)
        data.activeIndex = data.accounts.count - 1   // newly added becomes active
        guard save(data, url: url) else { return .failure(.persistenceFailed) }
        return .success(data)
    }

    @discardableResult
    static func remove(
        id: UUID,
        url: URL = defaultURL()
    ) -> Result<ClaudeTokenAccountData, MutationError> {
        guard case .success(var data) = loadForMutation(url: url) else {
            return .failure(.persistenceFailed)
        }
        guard let idx = data.accounts.firstIndex(where: { $0.id == id }) else {
            return .success(data)
        }
        data.accounts.remove(at: idx)
        if data.activeIndex >= data.accounts.count { data.activeIndex = max(0, data.accounts.count - 1) }
        guard save(data, url: url) else { return .failure(.persistenceFailed) }
        return .success(data)
    }

    @discardableResult
    static func setActive(
        id: UUID,
        url: URL = defaultURL()
    ) -> Result<ClaudeTokenAccountData, MutationError> {
        guard case .success(var data) = loadForMutation(url: url) else {
            return .failure(.persistenceFailed)
        }
        guard let idx = data.accounts.firstIndex(where: { $0.id == id }) else {
            return .success(data)
        }
        data.activeIndex = idx
        data.accounts[idx].lastUsed = Date()
        guard save(data, url: url) else { return .failure(.persistenceFailed) }
        return .success(data)
    }

    static func active(url: URL = defaultURL()) -> ClaudeTokenAccount? {
        load(url: url).active
    }
}
