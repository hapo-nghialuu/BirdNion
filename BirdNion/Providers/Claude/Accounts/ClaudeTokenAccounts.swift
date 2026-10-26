import Foundation
import Darwin
import AppKit
import CryptoKit

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

// MARK: - Claude Code CLI accounts (CLAUDE_CONFIG_DIR per account)

/// One Claude Code login the app knows about. `system` is the default
/// `~/.claude` login; every managed account owns its own `CLAUDE_CONFIG_DIR`,
/// so Claude Code itself logs in, stores and refreshes that account's token
/// (in a Keychain item suffixed with a hash of the dir). BirdNion never copies
/// or stores the token — switching only changes which dir is active.
struct ClaudeCLIAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String              // "system" or a UUID string
    var email: String?
    var orgName: String?
    var subscriptionType: String?
    var loggedIn: Bool

    var isSystem: Bool { id == ClaudeCLIAccountStore.systemID }
}

enum ClaudeCLIAccountStore {
    static let systemID = "system"
    static let activeKey = "claudeCLIActiveAccountID"

    /// Managed account dirs live next to BirdNion's config (no spaces in the
    /// path, so the dir also works pasted into a shell).
    static func baseURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/birdnion", isDirectory: true)
    }

    static func accountsDirURL() -> URL {
        baseURL().appendingPathComponent("claude-accounts", isDirectory: true)
    }

    static func configDir(for id: String) -> String? {
        guard id != systemID else { return nil }
        return accountsDirURL().appendingPathComponent(id, isDirectory: true).path
    }

    private static func listURL() -> URL {
        baseURL().appendingPathComponent("claude-cli-accounts.json")
    }

    /// Read by the `claude` shell wrapper on every launch: holds the active
    /// managed dir, or is empty for the default `~/.claude` login.
    static func activeDirFileURL() -> URL {
        baseURL().appendingPathComponent("claude-active-dir")
    }

    // MARK: Active account

    static func activeID() -> String {
        // Unit tests run inside the app's defaults domain; keep them on the
        // default login whatever account the developer has selected.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return systemID }
        let id = UserDefaults.standard.string(forKey: activeKey) ?? systemID
        guard id == systemID || FileManager.default.fileExists(atPath: configDir(for: id) ?? "") else {
            return systemID
        }
        return id
    }

    /// The `CLAUDE_CONFIG_DIR` of the active managed account, nil for system.
    static func activeConfigDir() -> String? {
        configDir(for: activeID())
    }

    /// Keychain service Claude Code uses for a config dir: the plain name for
    /// the default dir, else suffixed with the first 8 hex chars of
    /// sha256(NFC path) — Claude Code 2.1.x's own rule.
    static func keychainService(forConfigDir dir: String?) -> String {
        let base = "Claude Code-credentials"
        guard let dir, !dir.isEmpty else { return base }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(base)-\(hex.prefix(8))"
    }

    static func setActive(_ id: String) throws {
        let line = configDir(for: id) ?? ""
        try FileManager.default.createDirectory(at: baseURL(), withIntermediateDirectories: true)
        try Data((line.isEmpty ? "" : line + "\n").utf8).write(to: activeDirFileURL(), options: .atomic)
        UserDefaults.standard.set(id, forKey: activeKey)
        NotificationCenter.default.post(name: .birdnionClaudeAccountChanged, object: nil)
    }

    // MARK: Account list

    static func allAccounts() -> [ClaudeCLIAccount] {
        var managed: [ClaudeCLIAccount] = []
        if let data = try? Data(contentsOf: listURL()),
           let decoded = try? JSONDecoder().decode([ClaudeCLIAccount].self, from: data) {
            managed = decoded.filter { !$0.isSystem }
        }
        let system = cachedSystemAccount ?? ClaudeCLIAccount(
            id: systemID, email: nil, orgName: nil, subscriptionType: nil, loggedIn: true)
        return [system] + managed
    }

    private static var cachedSystemAccount: ClaudeCLIAccount?

    private static func saveManaged(_ accounts: [ClaudeCLIAccount]) throws {
        try FileManager.default.createDirectory(at: baseURL(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts.filter { !$0.isSystem }).write(to: listURL(), options: .atomic)
    }

    /// Creates an empty config dir for a new account and returns its id. The
    /// login itself happens in Terminal through Anthropic's own flow.
    static func createManagedAccount() throws -> String {
        let id = UUID().uuidString.lowercased()
        guard let dir = configDir(for: id) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        linkSharedConfig(into: dir)
        var managed = allAccounts().filter { !$0.isSystem }
        managed.append(ClaudeCLIAccount(id: id, email: nil, orgName: nil, subscriptionType: nil, loggedIn: false))
        try saveManaged(managed)
        return id
    }

    /// Logs the account out in Claude Code (revokes its token and drops its
    /// Keychain item), then deletes its config dir. Falls back to the system
    /// login when the removed account was active.
    static func removeManagedAccount(_ id: String) async throws {
        guard id != systemID, let dir = configDir(for: id) else { return }
        if let binary = ClaudeCLIResolver.resolvedBinaryPath() {
            _ = try? await ClaudeCLISession.runDirectProcess(
                binary: binary, arguments: ["auth", "logout"], timeout: 15,
                environment: ClaudeCLISession.launchEnvironment(configDir: dir))
        }
        if activeID() == id { try setActive(systemID) }
        try? FileManager.default.removeItem(atPath: dir)
        try saveManaged(allAccounts().filter { !$0.isSystem && $0.id != id })
    }

    /// Settings, hooks, plugins, skills… stay shared with `~/.claude` through
    /// symlinks (only the login, history and `.claude.json` are per account),
    /// so switching accounts never looks like a fresh Claude Code install.
    /// Idempotent: existing entries in the account dir are left alone.
    static let sharedConfigItems = [
        "settings.json", "CLAUDE.md", "agents", "commands", "skills", "plugins",
        "hooks", "output-styles", "keybindings.json", "statusline.sh",
    ]

    static func linkSharedConfig(into dir: String) {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        for item in sharedConfigItems {
            let target = source.appendingPathComponent(item)
            let link = URL(fileURLWithPath: dir).appendingPathComponent(item)
            guard fm.fileExists(atPath: target.path),
                  (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil,
                  !fm.fileExists(atPath: link.path)
            else { continue }
            try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    /// Name of a non-Anthropic backend configured in `~/.claude/settings.json`
    /// (proxy host, or "API key"), nil for the official subscription login.
    /// While one is set, switching the Claude login has no effect.
    static func customBackendName() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let env = json["env"] as? [String: Any] ?? [:]
        if let base = env["ANTHROPIC_BASE_URL"] as? String,
           let host = URL(string: base)?.host, !host.isEmpty,
           !host.hasSuffix("anthropic.com") {
            return host
        }
        if json["apiKeyHelper"] != nil || env["ANTHROPIC_API_KEY"] != nil || env["ANTHROPIC_AUTH_TOKEN"] != nil {
            return "API key"
        }
        return nil
    }

    /// Asked once, on the first switch while the shell wrapper is missing.
    static let terminalPromptDismissedKey = "claudeCLITerminalPromptDismissed"

    // MARK: Identity (claude auth status)

    private struct AuthStatus: Decodable {
        let loggedIn: Bool
        let email: String?
        let orgName: String?
        let subscriptionType: String?
    }

    /// Re-reads every account's login identity via `claude auth status --json`
    /// run against its own config dir, and persists what changed.
    @discardableResult
    static func refreshIdentities() async -> [ClaudeCLIAccount] {
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath() else { return allAccounts() }
        var updated: [ClaudeCLIAccount] = []
        for var account in allAccounts() {
            if let dir = configDir(for: account.id) { linkSharedConfig(into: dir) }
            if let status = await authStatus(binary: binary, configDir: configDir(for: account.id)) {
                account.loggedIn = status.loggedIn
                if status.loggedIn {
                    account.email = status.email ?? account.email
                    account.orgName = status.orgName ?? account.orgName
                    account.subscriptionType = status.subscriptionType ?? account.subscriptionType
                }
            }
            updated.append(account)
        }
        if let system = updated.first(where: \.isSystem) { cachedSystemAccount = system }
        try? saveManaged(updated)
        return updated
    }

    private static func authStatus(binary: String, configDir: String?) async -> AuthStatus? {
        var env = ClaudeCLISession.launchEnvironment(configDir: configDir)
        if configDir == nil { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        guard let output = try? await ClaudeCLISession.runDirectProcess(
            binary: binary, arguments: ["auth", "status", "--json"], timeout: 10, environment: env),
            let start = output.firstIndex(of: "{"),
            let data = String(output[start...]).data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(AuthStatus.self, from: data)
    }

    // MARK: Terminal login + shell wrapper

    /// Opens Terminal on a throwaway `.command` script that runs
    /// `claude auth login` against the account's config dir. A `.command`
    /// file opens in Terminal without needing Automation permission.
    static func openLoginInTerminal(id: String) throws {
        guard let dir = configDir(for: id) else { return }
        let binary = ClaudeCLIResolver.resolvedBinaryPath() ?? "claude"
        let script = """
        #!/bin/zsh
        export CLAUDE_CONFIG_DIR=\(shellQuoted(dir))
        \(shellQuoted(binary)) auth login
        echo
        echo "BirdNion: login xong — quay lại BirdNion, có thể đóng cửa sổ này."
        """
        let url = URL(fileURLWithPath: dir).appendingPathComponent("birdnion-login.command")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static let shellRCMarker = "# >>> BirdNion Claude account >>>"

    /// zsh/bash function that points every new `claude` launch at the account
    /// selected in BirdNion. It only sets the variable for that one command,
    /// so the shell's own environment is never changed.
    static var shellSnippet: String {
        """
        \(shellRCMarker)
        claude() {
          local d; d="$(cat "$HOME/.config/birdnion/claude-active-dir" 2>/dev/null)"
          if [ -n "$d" ]; then CLAUDE_CONFIG_DIR="$d" command claude "$@"; else command claude "$@"; fi
        }
        # <<< BirdNion Claude account <<<
        """
    }

    static func zshrcURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zshrc")
    }

    static func isShellWrapperInstalled() -> Bool {
        guard let text = try? String(contentsOf: zshrcURL(), encoding: .utf8) else { return false }
        return text.contains(shellRCMarker)
    }

    static func installShellWrapper() throws {
        guard !isShellWrapperInstalled() else { return }
        let url = zshrcURL()
        // Append in place (never an atomic replace): ~/.zshrc is often a
        // symlink into a dotfiles repo and must stay one.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + shellSnippet + "\n").utf8))
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
