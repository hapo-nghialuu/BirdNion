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
        case noSystemLogin
        var errorDescription: String? {
            switch self {
            case .codexNotFound: "Không tìm thấy lệnh `codex`. Cài Codex CLI trước."
            case .loginFailed: "Đăng nhập không hoàn tất."
            case .noSystemLogin: "Chưa có đăng nhập hệ thống (~/.codex) để chuyển thành managed."
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
        return base.appendingPathComponent("BirdNion", isDirectory: true)
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
        // QuotaService swaps in this account's cached snapshot (instant), then
        // refreshes — see its `.birdnionCodexAccountChanged` observer.
        NotificationCenter.default.post(name: .birdnionCodexAccountChanged, object: nil)
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

    private static func removedSystemAuthBackupURL(now: Date = Date()) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return systemAuthURL().deletingLastPathComponent()
            .appendingPathComponent("auth.json.birdnion-removed-\(stamp)")
    }

    private static func removeSystemLogin() throws {
        let auth = systemAuthURL()
        let fallback = selectedFallback(afterRemoving: "system")
        if FileManager.default.fileExists(atPath: auth.path) {
            var backup = removedSystemAuthBackupURL()
            if FileManager.default.fileExists(atPath: backup.path) {
                backup = auth.deletingLastPathComponent()
                    .appendingPathComponent("auth.json.birdnion-removed-\(UUID().uuidString)")
            }
            try FileManager.default.moveItem(at: auth, to: backup)
        }
        setCLISwitchedID(nil)
        if activeID() == "system" { setActive(fallback) }
    }

    static func remove(account: CodexAccount, from visibleAccounts: [CodexAccount]) throws {
        if account.isSystem {
            try removeSystemLogin()
        } else {
            remove(id: account.id, visibleAccounts: visibleAccounts)
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
        let systemAuth = systemAuthURL()
        guard FileManager.default.fileExists(atPath: systemAuth.path) else {
            throw AccountError.noSystemLogin
        }
        let id = UUID().uuidString
        let home = homeDir(forAccount: id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dest = home.appendingPathComponent("auth.json")
        // Read + atomic 0600 write (not `copyItem`) so the managed copy's
        // permissions never depend on whatever the external `codex` CLI left
        // on the source file — every managed credential stays owner-only,
        // matching the contract every other write path in this file follows.
        let data = try Data(contentsOf: systemAuth)
        try CodexAuthStore.writePrivateFile(data, to: dest)
        let account = CodexAccount(id: id, email: emailOf(url: dest),
                                   isSystem: false, homePath: home.path)
        persist(managedAccounts() + [account])
        return account
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

        let result = await runLogin(homePath: home.path)
        let authURL = home.appendingPathComponent("auth.json")
        guard result == .success, FileManager.default.fileExists(atPath: authURL.path) else {
            try? FileManager.default.removeItem(at: home)
            if result == .codexNotFound { throw AccountError.codexNotFound }
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
        let result = await runLogin(homePath: homePath)
        guard result == .success else {
            throw result == .codexNotFound ? AccountError.codexNotFound : AccountError.loginFailed
        }
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
        remove(id: id, visibleAccounts: allAccounts())
    }

    private static func remove(id: String, visibleAccounts: [CodexAccount]) {
        guard id != "system" else { return }
        let fallback = fallbackActiveID(afterRemoving: id, from: visibleAccounts)
        if cliSwitchedID() == id {
            try? restoreSystemCLI()
            if cliSwitchedID() == id { setCLISwitchedID(nil) }
        }
        if let account = managedAccounts().first(where: { $0.id == id }), let home = account.homePath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: home))
        }
        persist(managedAccounts().filter { $0.id != id })
        if activeID() == id { setActive(fallback) }
    }

    // MARK: - codex login

    /// Path to the `codex` executable, if installed.
    static func codexBinary() -> String? {
        for candidate in orderedCodexBinaryCandidates() where isUsableCodexBinary(candidate) {
            return candidate
        }
        if let shellPath = shellResolvedCodexBinary(), isUsableCodexBinary(shellPath) {
            return shellPath
        }
        return nil
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
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
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

    private static func isUsableCodexBinary(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = loginEnvironment(homePath: nil, binaryPath: path)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs `codex login` with `CODEX_HOME` pointed at `homePath`. The CLI
    /// opens a browser; this awaits its completion off the main thread.
    private enum LoginResult: Equatable { case success, codexNotFound, failed }

    private static func runLogin(homePath: String) async -> LoginResult {
        return await Task.detached(priority: .userInitiated) {
            guard let binary = codexBinary() else { return .codexNotFound }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["login"]
            process.environment = loginEnvironment(homePath: homePath, binaryPath: binary)
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return .failed
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .success : .failed
        }.value
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

    /// One-time pristine backup of the original `~/.codex/auth.json`, written
    /// only on the very first CLI overwrite.
    static func systemBackupURL() -> URL {
        systemAuthURL().deletingLastPathComponent().appendingPathComponent("auth.json.birdnion-orig")
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        guard !isAlreadyCLIIdentity(selectedID: id, trackedID: cliSwitchedID()) else { return }
        guard let account = managedAccounts().first(where: { $0.id == id }),
              let home = account.homePath
        else {
            throw CLISwitchError.accountNotFound
        }
        let managedAuthURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")

        // No original system login to preserve (e.g. a machine that only
        // ever used app-managed accounts, never `codex login` in a
        // terminal) — nothing to back up or promote, just install.
        let hasSystemLogin = FileManager.default.fileExists(atPath: systemAuthURL().path)
        if hasSystemLogin, cliSwitchedID() == nil {
            if !FileManager.default.fileExists(atPath: systemBackupURL().path) {
                let original = try Data(contentsOf: systemAuthURL())
                try CodexAuthStore.writePrivateFile(original, to: systemBackupURL())
            }
            let systemEmail = emailOf(url: systemAuthURL())
            let managedEmails = managedAccounts().compactMap(\.email)
            if needsPromoteBeforeOverwrite(systemEmail: systemEmail, managedEmails: managedEmails) {
                _ = try? promoteSystem()
            }
        }

        let managedData = try Data(contentsOf: managedAuthURL)
        try FileManager.default.createDirectory(
            at: systemAuthURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try CodexAuthStore.writePrivateFile(managedData, to: systemAuthURL())
        setCLISwitchedID(id)
    }

    /// Restores `~/.codex/auth.json` from the pristine backup and clears the
    /// tracked id. No-op when no switch has ever happened (no backup exists).
    static func restoreSystemCLI() throws {
        let backup = systemBackupURL()
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        let data = try Data(contentsOf: backup)
        try CodexAuthStore.writePrivateFile(data, to: systemAuthURL())
        setCLISwitchedID(nil)
    }

    /// Copies `~/.codex/auth.json` back into the tracked managed account's
    /// home when the CLI has rotated its token since the last sync, so the
    /// managed copy never goes stale. Best-effort: any failure is swallowed.
    @discardableResult
    static func reconcileCLISyncBack() -> Bool {
        guard let id = cliSwitchedID(), id != "system" else { return false }
        guard let account = managedAccounts().first(where: { $0.id == id }),
              let home = account.homePath
        else { return false }
        let managedAuthURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let cliModified = modificationDate(of: systemAuthURL())
        let managedModified = modificationDate(of: managedAuthURL)
        guard shouldSyncBack(cliModifiedAt: cliModified, managedModifiedAt: managedModified) else { return false }
        guard let data = try? Data(contentsOf: systemAuthURL()) else { return false }
        do {
            try CodexAuthStore.writePrivateFile(data, to: managedAuthURL)
            return true
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
        guard let binary = CodexAccountStore.codexBinary() else { return false }
        let succeeded = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["exec", "-s", "read-only", "--skip-git-repo-check", "say ok"]
            process.environment = CodexAccountStore.loginEnvironment(homePath: nil, binaryPath: binary)
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
