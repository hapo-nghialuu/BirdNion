import Foundation

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

    enum AccountError: LocalizedError {
        case codexNotFound
        case loginFailed
        var errorDescription: String? {
            switch self {
            case .codexNotFound: "Không tìm thấy lệnh `codex`. Cài Codex CLI trước."
            case .loginFailed: "Đăng nhập không hoàn tất."
            }
        }
    }

    // MARK: - Paths

    static func systemAuthURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    private static func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AIStatusbar", isDirectory: true)
    }

    private static func accountsRootDir() -> URL {
        supportDir().appendingPathComponent("codex-accounts", isDirectory: true)
    }

    private static func metadataURL() -> URL {
        supportDir().appendingPathComponent("codex-accounts.json")
    }

    static func homeDir(forAccount id: String) -> URL {
        accountsRootDir().appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Active selection

    static func activeID() -> String {
        UserDefaults.standard.string(forKey: activeKey) ?? "system"
    }

    static func setActive(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
    }

    /// The auth.json the provider should read for the active account.
    static func activeAuthURL() -> URL {
        let id = activeID()
        if id == "system" { return systemAuthURL() }
        if let account = managedAccounts().first(where: { $0.id == id }),
           let home = account.homePath {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return systemAuthURL() // active account vanished → fall back to system
    }

    // MARK: - Listing

    private struct Stored: Codable { var accounts: [Entry] }
    private struct Entry: Codable { var id: String; var email: String?; var homePath: String }

    static func managedAccounts() -> [CodexAccount] {
        guard let data = try? Data(contentsOf: metadataURL()),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.accounts.map {
            CodexAccount(id: $0.id, email: $0.email, isSystem: false, homePath: $0.homePath)
        }
    }

    static func allAccounts() -> [CodexAccount] {
        let system = CodexAccount(id: "system", email: emailOf(url: systemAuthURL()),
                                  isSystem: true, homePath: nil)
        return [system] + managedAccounts()
    }

    private static func emailOf(url: URL) -> String? {
        guard let credentials = try? CodexAuthStore.load(url: url) else { return nil }
        return CodexAuthStore.emailFromIDToken(credentials.idToken)
    }

    private static func persist(_ accounts: [CodexAccount]) {
        let entries = accounts.compactMap { account -> Entry? in
            guard let home = account.homePath else { return nil }
            return Entry(id: account.id, email: account.email, homePath: home)
        }
        try? FileManager.default.createDirectory(at: supportDir(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(accounts: entries)) {
            try? data.write(to: metadataURL())
        }
    }

    // MARK: - Add / re-auth / remove

    /// Creates a fresh managed home and runs `codex login` scoped to it. Blocks
    /// (off-main) until the browser login finishes, then records the account.
    static func addAccount() async throws -> CodexAccount {
        let id = UUID().uuidString
        let home = homeDir(forAccount: id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let ok = await runLogin(homePath: home.path)
        let authURL = home.appendingPathComponent("auth.json")
        guard ok, FileManager.default.fileExists(atPath: authURL.path) else {
            try? FileManager.default.removeItem(at: home)
            throw AccountError.loginFailed
        }
        let account = CodexAccount(id: id, email: emailOf(url: authURL),
                                   isSystem: false, homePath: home.path)
        persist(managedAccounts() + [account])
        return account
    }

    /// Re-runs `codex login` for an existing account's home (or the system home).
    static func reauth(id: String) async throws {
        let homePath: String
        if id == "system" {
            homePath = systemAuthURL().deletingLastPathComponent().path
        } else if let account = managedAccounts().first(where: { $0.id == id }), let home = account.homePath {
            homePath = home
        } else {
            throw AccountError.loginFailed
        }
        guard await runLogin(homePath: homePath) else { throw AccountError.loginFailed }
        // Refresh the cached email for managed accounts.
        if id != "system" {
            var accounts = managedAccounts()
            if let i = accounts.firstIndex(where: { $0.id == id }), let home = accounts[i].homePath {
                let email = emailOf(url: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
                accounts[i] = CodexAccount(id: id, email: email, isSystem: false, homePath: home)
                persist(accounts)
            }
        }
    }

    static func remove(id: String) {
        guard id != "system" else { return }
        if let account = managedAccounts().first(where: { $0.id == id }), let home = account.homePath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: home))
        }
        persist(managedAccounts().filter { $0.id != id })
        if activeID() == id { setActive("system") }
    }

    // MARK: - codex login

    /// Path to the `codex` executable, if installed.
    static func codexBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.codex/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `codex login` with `CODEX_HOME` pointed at `homePath`. Returns true
    /// if the process exits cleanly. The CLI opens a browser; this awaits its
    /// completion off the main thread.
    private static func runLogin(homePath: String) async -> Bool {
        guard let binary = codexBinary() else { return false }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["login"]
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = homePath
            process.environment = env
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
    }
}
