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
    static func authFileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL = if let codexHome, !codexHome.isEmpty {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return root.appendingPathComponent("auth.json")
    }

    static func load(url: URL = authFileURL()) throws -> CodexCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAuthError.notFound
        }
        let data = try Data(contentsOf: url)
        return try parse(data)
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
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let idToken = credentials.idToken { tokens["id_token"] = idToken }
        if let accountId = credentials.accountId { tokens["account_id"] = accountId }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try writePrivateFile(data, to: url)
    }

    // MARK: - Helpers

    /// Atomic private-file write (staged `O_EXCL` + `fchmod 0600` + `rename`).
    /// Exposed (not `private`) so `CodexAccountStore` can reuse it for CLI
    /// switch / restore / sync-back copies without duplicating the logic.
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).birdnion-\(UUID().uuidString)")
        let fd = staged.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw posixError(staged.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, mode_t(0o600)) == 0 else { throw posixError(staged.path) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let result = staged.path.withCString { src in
                url.path.withCString { dst in rename(src, dst) }
            }
            guard result == 0 else { throw posixError(url.path) }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    private static func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
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
