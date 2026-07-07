import Foundation
import Security

// Native Claude OAuth credential resolution. Replaces CodexBarCore's
// ClaudeOAuthCredentialsStore for the BirdNion Claude path. Resolution order
// mirrors CodexBar (minus the keychain-fingerprint/cooldown machinery, which is
// intentionally dropped — see plan):
//
//   1. Environment token  (BIRDNION_/CODEXBAR_CLAUDE_OAUTH_TOKEN)
//   2. ~/.claude/.credentials.json  (Claude Code's own credentials file)
//   3. macOS Keychain item "Claude Code-credentials" (Security framework)
//
// When the resolved credential is expired and carries a refresh token, we run a
// best-effort refresh-token grant in memory (never persisted — Claude Code stays
// the source of truth for its keychain item, so we don't risk rotating its
// refresh token out from under it). If the refresh fails (e.g. the token already
// rotated), the caller falls through to a 401 and surfaces "re-authenticate".

/// Decoded Claude OAuth credentials. Mirrors CodexBarCore's
/// `ClaudeOAuthCredentials` plus the `email` BirdNion surfaces as the account
/// label. The JSON shape (keychain item + credentials.json) is
/// `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt(ms), scopes,
/// rateLimitTier, subscriptionType, email } }`.
struct ClaudeOAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]
    let rateLimitTier: String?
    let subscriptionType: String?
    let email: String?

    init(accessToken: String,
         refreshToken: String?,
         expiresAt: Date?,
         scopes: [String] = [],
         rateLimitTier: String? = nil,
         subscriptionType: String? = nil,
         email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
        self.email = email
    }

    var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }

    /// Parses the `claudeAiOauth` JSON blob. Returns nil on any decode failure
    /// or an empty access token (the blob is a Claude-Code-owned contract; one
    /// missing optional must not crash the fetch).
    static func parse(data: Data) -> ClaudeOAuthCredentials? {
        guard !data.isEmpty,
              let root = try? JSONDecoder().decode(Root.self, from: data),
              let oauth = root.claudeAiOauth else { return nil }
        let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            rateLimitTier: oauth.rateLimitTier,
            subscriptionType: oauth.subscriptionType,
            email: oauth.email)
    }

    private struct Root: Decodable { let claudeAiOauth: OAuth? }
    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?
        let subscriptionType: String?
        let email: String?
    }
}

/// Resolves + refreshes Claude OAuth credentials.
enum ClaudeOAuthStore {
    static let keychainService = "Claude Code-credentials"
    static let credentialsRelativePath = ".claude/.credentials.json"
    static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let refreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    // BirdNion-first env keys, with CodexBar's keys kept for users migrating.
    static let envTokenKeys = ["BIRDNION_CLAUDE_OAUTH_TOKEN", "CODEXBAR_CLAUDE_OAUTH_TOKEN"]
    static let envScopesKeys = ["BIRDNION_CLAUDE_OAUTH_SCOPES", "CODEXBAR_CLAUDE_OAUTH_SCOPES"]
    static let envClientIDKeys = ["BIRDNION_CLAUDE_OAUTH_CLIENT_ID", "CODEXBAR_CLAUDE_OAUTH_CLIENT_ID"]

    private static func clientID(_ env: [String: String]) -> String {
        for key in envClientIDKeys {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return defaultClientID
    }

    // MARK: - Resolution

    /// Resolves credentials without refreshing. `allowKeychainPrompt == false`
    /// (or prompt mode `.never`) restricts to env + file so a background fetch
    /// never triggers a Keychain access prompt.
    static func loadCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool) -> ClaudeOAuthCredentials? {
        if let fromEnv = loadFromEnvironment(environment) { return fromEnv }
        if let fromFile = loadFromFile(environment: environment) { return fromFile }
        guard allowKeychainPrompt else { return nil }
        if let data = readKeychainData(), let creds = ClaudeOAuthCredentials.parse(data: data) {
            return creds
        }
        return nil
    }

    /// Resolves credentials and, if expired with a refresh token, attempts an
    /// in-memory refresh-token grant. Never persists the refreshed token.
    static func loadWithAutoRefresh(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool) async -> ClaudeOAuthCredentials? {
        guard let creds = loadCredentials(environment: environment, allowKeychainPrompt: allowKeychainPrompt)
        else { return nil }
        guard creds.isExpired, let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            return creds
        }
        if let refreshed = try? await refresh(
            refreshToken: refreshToken, existing: creds, session: session, environment: environment) {
            return refreshed
        }
        // Refresh failed (token already rotated, network, invalid_grant) — return
        // the expired credential so the usage fetch surfaces a 401/re-auth hint.
        return creds
    }

    // MARK: - Sources

    private static func loadFromEnvironment(_ env: [String: String]) -> ClaudeOAuthCredentials? {
        for key in envTokenKeys {
            guard let token = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
            else { continue }
            let scopes: [String] = {
                for sk in envScopesKeys {
                    if let raw = env[sk] {
                        let parsed = raw.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !parsed.isEmpty { return parsed }
                    }
                }
                return ["user:profile"]
            }()
            // Env tokens are treated as non-expiring (the user supplied them
            // directly and we have no refresh token for them).
            return ClaudeOAuthCredentials(
                accessToken: token, refreshToken: nil, expiresAt: .distantFuture, scopes: scopes)
        }
        return nil
    }

    private static func loadFromFile(environment: [String: String]) -> ClaudeOAuthCredentials? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: home).appendingPathComponent(credentialsRelativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeOAuthCredentials.parse(data: data)
    }

    /// Reads the raw `Claude Code-credentials` keychain blob via Security
    /// framework. May trigger a macOS access prompt the first time.
    /// The Advanced-pane debug toggle (key shared with CodexBarCore's
    /// KeychainAccessGate) suppresses the read entirely — callers then fall
    /// back to the CLI credentials file.
    static func readKeychainData() -> Data? {
        guard !UserDefaults.standard.bool(forKey: "debugDisableKeychainAccess") else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    // MARK: - Refresh grant

    private struct TokenRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    enum RefreshError: LocalizedError {
        case http(Int)
        case decode

        var errorDescription: String? {
            switch self {
            case let .http(code): "Claude OAuth refresh HTTP \(code) — chạy `claude` để đăng nhập lại."
            case .decode: "Claude OAuth refresh: phản hồi không hợp lệ."
            }
        }
    }

    /// POST refresh_token grant against platform.claude.com. Returns refreshed
    /// credentials carrying the new access token (and rotated refresh token if
    /// the server returned one). In-memory only — not persisted.
    static func refresh(
        refreshToken: String,
        existing: ClaudeOAuthCredentials,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ClaudeOAuthCredentials {
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID(environment)),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RefreshError.http(code) }
        guard let token = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data) else {
            throw RefreshError.decode
        }
        return ClaudeOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: Date(timeIntervalSinceNow: TimeInterval(token.expiresIn)),
            scopes: existing.scopes,
            rateLimitTier: existing.rateLimitTier,
            subscriptionType: existing.subscriptionType,
            email: existing.email)
    }
}

// MARK: - OAuth usage API

/// Fetches + maps the Claude OAuth usage endpoint. Native port of CodexBarCore's
/// ClaudeOAuthUsageFetcher + mapOAuthUsage. Produces a native ClaudeUsageSnapshot.
enum ClaudeOAuthUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    /// Resolves credentials then fetches + maps the usage payload.
    static func loadSnapshot(session: URLSession = .shared,
                             allowKeychainPrompt: Bool) async throws -> ClaudeUsageSnapshot {
        guard let creds = await ClaudeOAuthStore.loadWithAutoRefresh(
                  session: session, allowKeychainPrompt: allowKeychainPrompt),
              !creds.accessToken.isEmpty else {
            throw ClaudeUsageError.oauthFailed("Chưa đăng nhập Claude — đăng nhập bằng Claude Code")
        }
        let usage = try await fetchUsage(accessToken: creds.accessToken, session: session)
        return mapOAuthUsage(usage, credentials: creds)
    }

    static func fetchUsage(accessToken: String, session: URLSession = .shared) async throws -> OAuthUsageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClaudeUsageError.oauthFailed("Network: \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return try decode(data)
        case 401, 403:
            throw ClaudeUsageError.oauthFailed("Token Claude hết hạn — đăng nhập lại bằng Claude Code")
        default:
            throw ClaudeUsageError.oauthFailed("HTTP \(code)")
        }
    }

    static func decode(_ data: Data) throws -> OAuthUsageResponse {
        do { return try JSONDecoder().decode(OAuthUsageResponse.self, from: data) }
        catch { throw ClaudeUsageError.parseFailed("oauth usage: \(error.localizedDescription)") }
    }

    /// Maps the decoded payload into a native snapshot. Mirrors CodexBar's
    /// mapOAuthUsage, but keeps Opus as its own window and surfaces Sonnet as a
    /// named extra window (BirdNion historically showed both) plus Daily Routines.
    static func mapOAuthUsage(_ usage: OAuthUsageResponse,
                              credentials: ClaudeOAuthCredentials) -> ClaudeUsageSnapshot {
        func makeWindow(_ w: OAuthUsageWindow?, minutes: Int?) -> RateWindow? {
            guard let w, let util = w.utilization else { return nil }
            return RateWindow(usedPercent: util, windowMinutes: minutes,
                              resetsAt: parseISO8601(w.resetsAt), resetDescription: nil)
        }

        let loginMethod = ClaudePlanLabeler.oauthLoginMethod(subscriptionType: credentials.subscriptionType)
        let primary = makeWindow(usage.fiveHour, minutes: 5 * 60)
            ?? makeWindow(usage.sevenDay, minutes: 7 * 24 * 60)
            ?? makeWindow(usage.sevenDayOAuthApps, minutes: 7 * 24 * 60)
        let treatAsSpendLimit = primary == nil && usage.extraUsage?.isEnabled == true
        let providerCost = extraUsageCost(usage.extraUsage, treatAsSpendLimit: treatAsSpendLimit)

        var extra: [NamedRateWindow] = []
        if let sonnet = makeWindow(usage.sevenDaySonnet, minutes: 7 * 24 * 60) {
            extra.append(NamedRateWindow(id: "claude-sonnet", title: "Sonnet", window: sonnet))
        }
        extra.append(contentsOf: routineWindows(usage))

        guard let primary else {
            // No usage windows — surface the spend-limit as the primary bar.
            if let spend = spendLimitWindow(from: providerCost, extraUsage: usage.extraUsage) {
                return ClaudeUsageSnapshot(
                    primary: spend, primaryWindowKind: .spendLimit, secondary: nil, opus: nil,
                    extraRateWindows: extra, providerCost: providerCost,
                    accountEmail: credentials.email, loginMethod: loginMethod)
            }
            // Degenerate: empty windows, just carry cost/identity.
            return ClaudeUsageSnapshot(
                primary: RateWindow(usedPercent: 0, windowMinutes: 5 * 60, resetsAt: nil, resetDescription: nil),
                secondary: nil, opus: nil, extraRateWindows: extra, providerCost: providerCost,
                accountEmail: credentials.email, loginMethod: loginMethod)
        }

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: makeWindow(usage.sevenDay, minutes: 7 * 24 * 60),
            opus: makeWindow(usage.sevenDayOpus, minutes: 7 * 24 * 60),
            extraRateWindows: extra,
            providerCost: providerCost,
            accountEmail: credentials.email,
            loginMethod: loginMethod)
    }

    private static func routineWindows(_ usage: OAuthUsageResponse) -> [NamedRateWindow] {
        guard usage.sevenDayRoutines != nil || usage.sevenDayRoutinesSourceKey != nil else { return [] }
        let util = usage.sevenDayRoutines?.utilization ?? 0
        let resetDate = parseISO8601(usage.sevenDayRoutines?.resetsAt)
        return [NamedRateWindow(
            id: "claude-routines", title: "Daily Routines",
            window: RateWindow(usedPercent: util, windowMinutes: 7 * 24 * 60,
                               resetsAt: resetDate, resetDescription: nil),
            usageKnown: usage.sevenDayRoutines?.utilization != nil)]
    }

    private static func extraUsageCost(_ extra: OAuthExtraUsage?, treatAsSpendLimit: Bool) -> ProviderCostSnapshot? {
        guard let extra, extra.isEnabled == true,
              let used = extra.usedCredits, let limit = extra.monthlyLimit else { return nil }
        let currency = extra.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (currency?.isEmpty ?? true) ? "USD" : currency!
        // Claude's OAuth API returns cents (minor units) — convert to dollars.
        return ProviderCostSnapshot(
            used: used / 100.0, limit: limit / 100.0, currencyCode: code,
            period: treatAsSpendLimit ? "Spend limit" : "Monthly cap", updatedAt: Date())
    }

    private static func spendLimitWindow(from cost: ProviderCostSnapshot?, extraUsage: OAuthExtraUsage?) -> RateWindow? {
        guard let cost, cost.limit > 0 else { return nil }
        let pct = extraUsage?.utilization ?? (cost.used / cost.limit) * 100
        let used = UsageFormatter.usdString(cost.used)
        let limit = UsageFormatter.usdString(cost.limit)
        return RateWindow(usedPercent: min(100, max(0, pct)), windowMinutes: nil,
                          resetsAt: cost.resetsAt, resetDescription: "\(cost.period ?? "Spend limit"): \(used) / \(limit)")
    }

    static func parseISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Decoded OAuth usage payload. Dynamic keys so unknown/renamed routine keys
/// still parse. Mirrors CodexBar's OAuthUsageResponse.
struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOAuthApps: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayRoutines: OAuthUsageWindow?
    let sevenDayRoutinesSourceKey: String?
    let extraUsage: OAuthExtraUsage?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func window(_ keys: [String]) -> OAuthUsageWindow? {
            for k in keys {
                if let key = DynamicKey(stringValue: k),
                   let v = try? c.decodeIfPresent(OAuthUsageWindow.self, forKey: key) { return v }
            }
            return nil
        }
        fiveHour = window(["five_hour"])
        sevenDay = window(["seven_day"])
        sevenDayOAuthApps = window(["seven_day_oauth_apps"])
        sevenDayOpus = window(["seven_day_opus"])
        sevenDaySonnet = window(["seven_day_sonnet"])
        let routineKeys = ["seven_day_routines", "seven_day_claude_routines", "claude_routines",
                           "routines", "routine", "seven_day_cowork", "cowork"]
        var routine: OAuthUsageWindow?
        var routineKey: String?
        for k in routineKeys {
            guard let key = DynamicKey(stringValue: k), c.contains(key) else { continue }
            if let v = try? c.decodeIfPresent(OAuthUsageWindow.self, forKey: key) {
                routine = v; routineKey = k; break
            }
            if routineKey == nil { routineKey = k }
        }
        sevenDayRoutines = routine
        sevenDayRoutinesSourceKey = routineKey
        if let key = DynamicKey(stringValue: "extra_usage") {
            extraUsage = try? c.decodeIfPresent(OAuthExtraUsage.self, forKey: key)
        } else {
            extraUsage = nil
        }
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

struct OAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct OAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}
