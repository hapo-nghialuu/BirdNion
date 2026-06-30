import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Errors

enum AntigravityOAuthError: LocalizedError {
    case missingCredentials
    case timeout
    case codeMissing
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case quotaFetchFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Antigravity OAuth client chưa được cấu hình. Cài Antigravity.app hoặc set ANTIGRAVITY_OAUTH_CLIENT_ID và ANTIGRAVITY_OAUTH_CLIENT_SECRET."
        case .timeout:
            return "Antigravity OAuth: timeout chờ callback từ browser."
        case .codeMissing:
            return "Antigravity OAuth: không nhận được authorization code."
        case .tokenExchangeFailed(let msg):
            return "Antigravity OAuth: đổi token thất bại – \(msg)"
        case .refreshFailed(let msg):
            return "Antigravity OAuth: refresh token thất bại – \(msg)"
        case .quotaFetchFailed(let msg):
            return "Antigravity OAuth: lấy quota thất bại – \(msg)"
        case .parseFailed(let msg):
            return "Antigravity OAuth: parse thất bại – \(msg)"
        }
    }
}

// MARK: - AntigravityOAuthStore

/// Multi-account OAuth credential store for Antigravity (Google OAuth).
/// Persists to `~/.config/birdnion/antigravity-oauth.json`.
/// Thread-safety: NSLock guards all file I/O.
struct AntigravityOAuthStore {

    // MARK: - Stored types

    struct Account: Codable, Equatable {
        var label: String
        var email: String?
        var refreshToken: String
    }

    struct Store: Codable {
        var clientId: String?
        var clientSecret: String?
        var activeLabel: String?
        var accounts: [Account]

        init(clientId: String? = nil, clientSecret: String? = nil, activeLabel: String? = nil, accounts: [Account] = []) {
            self.clientId = clientId
            self.clientSecret = clientSecret
            self.activeLabel = activeLabel
            self.accounts = accounts
        }
    }

    // MARK: - File location

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/birdnion", isDirectory: true)
            .appendingPathComponent("antigravity-oauth.json")
    }

    // MARK: - Client ID/secret resolution

    /// OAuth client embedded in an installed Antigravity.app, extracted once.
    /// This is how CodexBar avoids making users register their own client —
    /// it borrows Antigravity's. nil when the app isn't installed.
    private static let discoveredClient: (id: String, secret: String)? = discoverClientFromInstalledApp()

    /// Resolves client ID: file → env → installed Antigravity.app. nil when missing.
    static func resolvedClientID(store: Store) -> String? {
        if let v = store.clientId?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        return discoveredClient?.id
    }

    /// Resolves client secret: file → env → installed Antigravity.app. nil when missing.
    static func resolvedClientSecret(store: Store) -> String? {
        if let v = store.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        return discoveredClient?.secret
    }

    /// Scans installed Antigravity.app bundles for the embedded Google OAuth
    /// client: `…apps.googleusercontent.com` (id) + `GOCSPX-…` (secret), read
    /// from its language_server binary / main.js. Mirrors CodexBar.
    private static func discoverClientFromInstalledApp() -> (id: String, secret: String)? {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let relPaths = [
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
        ]
        var bundles: [URL] = []
        for root in roots {
            bundles.append(root.appendingPathComponent("Antigravity.app", isDirectory: true))
            let apps = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for app in apps where app.pathExtension == "app" {
                let bid = Bundle(url: app)?.bundleIdentifier
                if bid == "com.google.antigravity" || bid == "com.google.antigravity-ide" {
                    bundles.append(app)
                }
            }
        }
        for bundle in bundles {
            for rel in relPaths {
                let url = bundle.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { continue }
                // Lossy UTF-8 decode keeps ASCII id/secret intact even in binaries.
                let text = String(decoding: data, as: UTF8.self)
                if let id = firstMatch(#"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: text),
                   let secret = firstMatch(#"GOCSPX-[A-Za-z0-9_-]{28}"#, in: text) {
                    return (id, secret)
                }
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Load / Save

    private static let lock = NSLock()

    static func load() -> Store {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let store = try? JSONDecoder().decode(Store.self, from: data)
            else {
                return Store()
            }
            return store
        }
    }

    // MARK: - Mutable operations (mutate a loaded Store value)

    static func addAccount(to store: inout Store, label: String, refreshToken: String, email: String?) {
        // Replace existing account with same label if present
        if let idx = store.accounts.firstIndex(where: { $0.label == label }) {
            store.accounts[idx] = Account(label: label, email: email, refreshToken: refreshToken)
        } else {
            store.accounts.append(Account(label: label, email: email, refreshToken: refreshToken))
        }
        if store.activeLabel == nil {
            store.activeLabel = label
        }
    }

    static func removeAccount(from store: inout Store, label: String) {
        store.accounts.removeAll { $0.label == label }
        if store.activeLabel == label {
            store.activeLabel = store.accounts.first?.label
        }
    }

    static func setActive(in store: inout Store, label: String) {
        guard store.accounts.contains(where: { $0.label == label }) else { return }
        store.activeLabel = label
    }

    /// Returns the currently active account, or the first account if activeLabel is unset.
    static func activeAccount(in store: Store) -> Account? {
        if let label = store.activeLabel {
            return store.accounts.first { $0.label == label }
        }
        return store.accounts.first
    }

    static func save(_ store: Store) throws {
        try lock.withLock {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: fileURL, options: [.atomic])
            // Restrict file permissions to owner-read/write only
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path)
        }
    }
}

// MARK: - AntigravityOAuthLogin

/// Loopback OAuth 2.0 + PKCE login flow for Antigravity / Google accounts.
/// Opens the system browser, starts a local HTTP listener, receives the auth code,
/// exchanges it for tokens, then closes the listener.
enum AntigravityOAuthLogin {

    // Google OAuth scopes matching Gemini CLI / Antigravity auth
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "openid",
        "email",
        "profile",
    ]

    private static let authBaseURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let loginTimeoutSeconds: TimeInterval = 120

    // MARK: - Public entry point

    /// Performs the full loopback OAuth login flow.
    /// - Returns: (refreshToken, email?) — email extracted best-effort from id_token JWT.
    /// - Throws: `AntigravityOAuthError` on any failure.
    static func login(clientID: String, clientSecret: String) async throws -> (refreshToken: String, email: String?) {
        // 1. PKCE
        let (verifier, challenge) = generatePKCE()

        // 2. Start loopback listener on a random available port
        let (listener, port) = try await startLoopbackListener()
        let redirectURI = "http://127.0.0.1:\(port)"

        // 3. Build & open auth URL
        let authURL = buildAuthURL(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: challenge,
            scopes: scopes)
        await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // 4. Wait for callback (with timeout)
        let code = try await receiveCode(listener: listener, port: port)

        // 5. Exchange code → tokens
        let tokens = try await exchangeCode(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            codeVerifier: verifier)

        return (tokens.refreshToken, tokens.email)
    }

    // MARK: - PKCE

    private static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }

    // MARK: - Loopback listener

    private static func startLoopbackListener() async throws -> (NWListener, Int) {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                // Port 0 → OS assigns a random available port
                let listener = try NWListener(using: params, on: 0)

                var portCaptured = false
                listener.newConnectionHandler = { _ in } // Set later after we have the listener

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard !portCaptured else { return }
                        portCaptured = true
                        if let port = listener.port?.rawValue {
                            continuation.resume(returning: (listener, Int(port)))
                        } else {
                            continuation.resume(throwing: AntigravityOAuthError.tokenExchangeFailed("Không lấy được port từ listener"))
                        }
                    case .failed(let error):
                        if !portCaptured {
                            portCaptured = true
                            continuation.resume(throwing: error)
                        }
                    default:
                        break
                    }
                }

                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Auth URL builder

    private static func buildAuthURL(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        scopes: [String]
    ) -> URL {
        var comps = URLComponents(string: authBaseURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    // MARK: - Receive code from loopback

    private static func receiveCode(listener: NWListener, port: Int) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.loginTimeoutSeconds * 1_000_000_000))
                throw AntigravityOAuthError.timeout
            }

            // Connection acceptance task
            group.addTask {
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    var settled = false
                    listener.newConnectionHandler = { connection in
                        guard !settled else {
                            connection.cancel()
                            return
                        }
                        connection.start(queue: .global(qos: .userInitiated))
                        // Receive HTTP GET request
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                            defer {
                                settled = true
                                listener.cancel()
                            }
                            if let error {
                                cont.resume(throwing: error)
                                return
                            }
                            guard let data, let request = String(data: data, encoding: .utf8) else {
                                cont.resume(throwing: AntigravityOAuthError.codeMissing)
                                return
                            }
                            // Send success response before parsing so the browser closes cleanly
                            let message = L10n.t("oauth.closeTab")
                            let body = "<html><body><p>\(message)</p></body></html>"
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                            let responseData = Data(response.utf8)
                            connection.send(content: responseData, completion: .contentProcessed { _ in
                                connection.cancel()
                            })

                            // Extract code from GET line: "GET /?code=...&... HTTP/1.1"
                            if let code = extractCode(fromRequest: request) {
                                cont.resume(returning: code)
                            } else {
                                cont.resume(throwing: AntigravityOAuthError.codeMissing)
                            }
                        }
                    }
                }
            }

            // Return whichever finishes first; cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func extractCode(fromRequest request: String) -> String? {
        // First line: "GET /?code=4/0A...&scope=... HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1]
        var comps = URLComponents()
        comps.query = path.components(separatedBy: "?").dropFirst().joined(separator: "?")
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    // MARK: - Token exchange

    private struct TokenResponse {
        let refreshToken: String
        let idToken: String?
        var email: String? { AntigravityOAuthLogin.emailFromIDToken(idToken) }
    }

    private static func exchangeCode(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> TokenResponse {
        guard let url = URL(string: tokenURL) else {
            throw AntigravityOAuthError.tokenExchangeFailed("Invalid token URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        req.httpBody = comps.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.tokenExchangeFailed("Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AntigravityOAuthError.tokenExchangeFailed(body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = json["refresh_token"] as? String
        else {
            throw AntigravityOAuthError.tokenExchangeFailed("Không có refresh_token trong response")
        }
        let idToken = json["id_token"] as? String
        return TokenResponse(refreshToken: refreshToken, idToken: idToken)
    }

    // MARK: - JWT email extraction

    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let token = idToken else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = payload.count % 4
        if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String
        else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - AntigravityRemoteUsage

/// Fetches remote quota windows from `cloudcode-pa.googleapis.com` using
/// an Antigravity/Google OAuth refresh token. Mirrors the GeminiProvider flow.
enum AntigravityRemoteUsage {

    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let timeout: TimeInterval = 15

    // MARK: - Response models (private)

    private struct QuotaBucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private struct CodeAssistResponse: Decodable {
        let currentTier: TierInfo?
        let planInfo: PlanInfo?
    }

    private struct TierInfo: Decodable {
        let id: String?
        let name: String?
    }

    private struct PlanInfo: Decodable {
        let planType: String?
    }

    // MARK: - Public API

    /// Fetches quota windows for the given refresh token.
    /// - Returns: Array of `QuotaWindow` (0–100 pct, contract-matching).
    /// - Throws: `AntigravityOAuthError` on failure.
    static func fetch(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> [QuotaWindow] {
        let accessToken = try await refreshAccessToken(
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret)
        return try await fetchQuotaWindows(accessToken: accessToken)
    }

    /// Fetches quota windows + plan name (best-effort).
    static func fetchDetailed(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> (windows: [QuotaWindow], planName: String?) {
        let accessToken = try await refreshAccessToken(
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret)
        async let windowsTask = fetchQuotaWindows(accessToken: accessToken)
        async let planTask = fetchPlanName(accessToken: accessToken)
        let windows = try await windowsTask
        let plan = await planTask
        return (windows, plan)
    }

    // MARK: - Token refresh

    static func refreshAccessToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> String {
        guard let url = URL(string: tokenURL) else {
            throw AntigravityOAuthError.refreshFailed("Invalid token URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        req.httpBody = comps.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AntigravityOAuthError.refreshFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String
        else {
            throw AntigravityOAuthError.refreshFailed("Không parse được access_token")
        }
        return token
    }

    // MARK: - Quota fetch

    private static func fetchQuotaWindows(accessToken: String) async throws -> [QuotaWindow] {
        guard let url = URL(string: quotaEndpoint) else {
            throw AntigravityOAuthError.quotaFetchFailed("Invalid quota URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.quotaFetchFailed("Non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw AntigravityOAuthError.refreshFailed("Access token hết hạn (401)")
        default:
            throw AntigravityOAuthError.quotaFetchFailed("HTTP \(http.statusCode)")
        }

        let quotaResponse = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let buckets = quotaResponse.buckets, !buckets.isEmpty else {
            throw AntigravityOAuthError.parseFailed("Không có quota buckets trong response")
        }

        return mapBucketsToWindows(buckets)
    }

    // MARK: - Plan name (best-effort, non-throwing)

    private static func fetchPlanName(accessToken: String) async -> String? {
        guard let url = URL(string: loadCodeAssistEndpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"metadata\":{\"ideType\":\"ANTIGRAVITY\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}}".utf8)
        req.timeoutInterval = timeout

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let caResponse = try? JSONDecoder().decode(CodeAssistResponse.self, from: data)
        else { return nil }

        if let planType = caResponse.planInfo?.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !planType.isEmpty {
            return planType
        }

        switch caResponse.currentTier?.id?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "standard-tier": return "Paid"
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        default: return caResponse.currentTier?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    // MARK: - Bucket → QuotaWindow mapping

    /// Groups buckets by modelId, keeps minimum remainingFraction per model, then
    /// maps to QuotaWindow using the same Pro/Flash/Flash Lite tier logic as GeminiProvider.
    private static func mapBucketsToWindows(_ buckets: [QuotaBucket]) -> [QuotaWindow] {
        // Deduplicate: minimum remainingFraction per modelId
        var map: [String: (fraction: Double, resetTime: String?)] = [:]
        for b in buckets {
            guard let mid = b.modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty else { continue }
            guard let frac = b.remainingFraction else { continue }
            if let existing = map[mid] {
                if frac < existing.fraction { map[mid] = (frac, b.resetTime) }
            } else {
                map[mid] = (frac, b.resetTime)
            }
        }

        // Tier grouping (flash-lite must be checked before flash)
        var proMin: (Double, String?)? = nil
        var flashMin: (Double, String?)? = nil
        var flashLiteMin: (Double, String?)? = nil
        var others: [(label: String, fraction: Double, resetTime: String?)] = []

        for (mid, info) in map {
            let lower = mid.lowercased()
            if lower.contains("flash-lite") || lower.contains("flash_lite") {
                if flashLiteMin == nil || info.fraction < flashLiteMin!.0 { flashLiteMin = (info.fraction, info.resetTime) }
            } else if lower.contains("flash") {
                if flashMin == nil || info.fraction < flashMin!.0 { flashMin = (info.fraction, info.resetTime) }
            } else if lower.contains("pro") {
                if proMin == nil || info.fraction < proMin!.0 { proMin = (info.fraction, info.resetTime) }
            } else {
                others.append((label: humanizeModelID(mid), fraction: info.fraction, resetTime: info.resetTime))
            }
        }

        var windows: [QuotaWindow] = []

        for (label, entry) in [("Pro", proMin), ("Flash", flashMin), ("Flash Lite", flashLiteMin)] {
            guard let (frac, resetTime) = entry else { continue }
            windows.append(makeWindow(label: label, fraction: frac, resetTime: resetTime))
        }

        // Append non-grouped models, sorted by label
        for other in others.sorted(by: { $0.label < $1.label }) {
            windows.append(makeWindow(label: other.label, fraction: other.fraction, resetTime: other.resetTime))
        }

        return windows
    }

    private static func makeWindow(label: String, fraction: Double, resetTime: String?) -> QuotaWindow {
        let usedPct = max(0, min(100, Int((1.0 - fraction) * 100)))
        let remainingPct = 100 - usedPct
        let resetDate = resetTime.flatMap(parseISO8601)
        let subtitle = resetDate.flatMap(formatCountdown)
        return QuotaWindow(
            label: label,
            usedPct: usedPct,
            remainingPct: remainingPct,
            subtitle: subtitle,
            resetDate: resetDate,
            windowSeconds: 86400) // Google quota windows are 24h
    }

    // MARK: - Helpers

    private static func humanizeModelID(_ id: String) -> String {
        id.split(separator: "-")
            .map { String($0).prefix(1).uppercased() + String($0).dropFirst() }
            .joined(separator: " ")
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func formatCountdown(_ resetDate: Date) -> String? {
        let interval = resetDate.timeIntervalSinceNow
        guard interval > 0 else { return "Sắp reset" }
        let h = Int(interval / 3600)
        let m = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        return h > 0 ? "Reset trong \(h)h \(m)m" : "Reset trong \(m)m"
    }
}

// MARK: - String helpers (file-private)

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
