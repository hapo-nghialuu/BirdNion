import Foundation
import Security

/// Claude (Anthropic) subscription usage provider.
///
/// Auth: reads the OAuth token Claude Code stores in the macOS Keychain under
/// service `Claude Code-credentials` (JSON: `{ "claudeAiOauth": { "accessToken",
/// "rateLimitTier", "subscriptionType", ... } }`). Because that item belongs to
/// the Claude Code app, the first read triggers a macOS Keychain access prompt —
/// the user must click "Always Allow" once.
///
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
/// Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`.
/// Response: `{ five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage }`
/// where each window's `utilization` is a percent already used (0..100).
/// `extra_usage` is `{ is_enabled, monthly_limit, used_credits, utilization, currency }`.
final class ClaudeProvider: QuotaProvider {
    let id = "claude"
    let displayName = "Claude"

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
    static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    /// Token reader, injectable so tests don't touch the real Keychain.
    private let tokenProvider: () -> String?
    /// Status-page reader. Isolated from the main fetcher so unit tests can
    /// inject a fake without hitting status.anthropic.com.
    private let statusProvider: () async -> OpenAIServiceStatus?

    init(session: URLSession = .shared,
         tokenProvider: @escaping () -> String? = { ClaudeProvider.readKeychainToken() },
         statusProvider: @escaping () async -> OpenAIServiceStatus? = ClaudeProvider.fetchServiceStatus) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.statusProvider = statusProvider
    }

    private func override() -> String? {
        ProvidersStore.load().providers.first(where: { $0.id == self.id })?.accountLabel
    }

    func fetch() async throws -> ProviderStatus {
        guard let token = tokenProvider(), !token.isEmpty else {
            return failure("Chưa đăng nhập Claude — đăng nhập bằng Claude Code")
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        switch http.statusCode {
        case 200..<300:
            let base = parse(data, accountLabel: override())
            // Service status is best-effort, like Codex's statusProbe.
            let status = await statusProvider()
            return ProviderStatus(
                id: base.id,
                displayName: base.displayName,
                windows: base.windows,
                lastUpdated: base.lastUpdated,
                error: base.error,
                accountLabel: base.accountLabel,
                planType: base.planType,
                creditsRemaining: base.creditsRemaining,
                version: base.version,
                serviceStatus: status?.description,
                serviceStatusLevel: status?.indicator,
                accountID: base.accountID,
                planName: base.planName,
                resetCreditsAvailable: base.resetCreditsAvailable)
        case 401, 403:
            return failure("Token Claude hết hạn — đăng nhập lại bằng Claude Code")
        default:
            return failure("HTTP \(http.statusCode)")
        }
    }

    func parse(_ data: Data, accountLabel: String?) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        var windows: [QuotaWindow] = []
        if let five = root.fiveHour, let pct = five.utilization {
            windows.append(Self.window(label: "5 giờ", utilization: pct,
                                       resetsAt: five.resetsAt, seconds: 5 * 3600))
        }
        if let week = root.sevenDay, let pct = week.utilization {
            windows.append(Self.window(label: "Tuần", utilization: pct,
                                       resetsAt: week.resetsAt, seconds: 7 * 24 * 3600))
        }
        if let opus = root.sevenDayOpus, let pct = opus.utilization {
            windows.append(Self.window(label: "Opus", utilization: pct,
                                       resetsAt: opus.resetsAt, seconds: 7 * 24 * 3600))
        }
        if let sonnet = root.sevenDaySonnet, let pct = sonnet.utilization {
            windows.append(Self.window(label: "Sonnet", utilization: pct,
                                       resetsAt: sonnet.resetsAt, seconds: 7 * 24 * 3600))
        }
        guard !windows.isEmpty else { return failure("Claude chưa có dữ liệu quota") }

        // Plan + account email come from the same Keychain blob the token is read from.
        let credentials = KeychainRoot.decode(keychainData: Self.readKeychainData())
        let planName = ClaudePlan.label(forSubscriptionType: credentials?.subscriptionType,
                                        rateLimitTier: credentials?.rateLimitTier)

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel ?? credentials?.email,
            creditsRemaining: Self.spendRemaining(extraUsage: root.extraUsage),
            planName: planName)
    }

    /// If `extra_usage` is enabled and has a monthly_limit + used_credits,
    /// return the remaining balance. nil when not enabled or limits are absent.
    /// We surface it via `creditsRemaining` so the existing UI cell shows it.
    private static func spendRemaining(extraUsage: ExtraUsage?) -> Double? {
        guard let e = extraUsage, e.isEnabled == true,
              let limit = e.monthlyLimit, let used = e.usedCredits else { return nil }
        return max(0, limit - used)
    }

    /// `utilization` is a percent already used (0..100).
    private static func window(label: String, utilization: Double,
                               resetsAt: String?, seconds: Int) -> QuotaWindow {
        let used = max(0, min(100, Int(utilization.rounded())))
        return QuotaWindow(
            label: label,
            usedPct: used,
            remainingPct: 100 - used,
            resetDate: parseISO8601(resetsAt),
            windowSeconds: seconds)
    }

    static func parseISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - Keychain

    /// Reads `claudeAiOauth.accessToken` from the Claude Code keychain item.
    /// Returns nil if absent or access is denied. May trigger a macOS prompt.
    static func readKeychainToken() -> String? {
        return tokenFromKeychainJSON(readKeychainData() ?? Data())
    }

    /// Reads the raw keychain blob so the plan + email can be surfaced without
    /// paying the prompt cost twice. Returns nil if access is denied.
    private static func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    /// Parses the keychain JSON blob → access token. Exposed for tests.
    static func tokenFromKeychainJSON(_ data: Data) -> String? {
        guard let creds = KeychainRoot.decode(keychainData: data) else { return nil }
        let token = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    // MARK: - Service status (status.anthropic.com)

    /// Best-effort fetch of Anthropic's public status. Mirrors Codex's
    /// `OpenAIServiceStatus` pattern: short timeout, never throws, returns nil
    /// on any failure so the main quota fetch isn't blocked by a flaky 3rd
    /// party endpoint.
    static func fetchServiceStatus() async -> OpenAIServiceStatus? {
        guard let url = URL(string: "https://status.anthropic.com/api/v2/summary.json") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            return nil
        }
        struct Payload: Decodable {
            struct Status: Decodable { let indicator: String?; let description: String? }
            let status: Status?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              let s = p.status
        else { return nil }
        return OpenAIServiceStatus(indicator: s.indicator ?? "unknown",
                                   description: s.description ?? "Unknown")
    }

    // MARK: - Models

    /// Decoded shape of the Claude Code Keychain JSON. We keep this internal
    /// to ClaudeProvider because the OAuth token + plan both come from the
    /// same blob and have no other consumers.
    struct KeychainRoot: Decodable {
        let claudeAiOauth: OAuth?
        struct OAuth: Decodable {
            let accessToken: String?
            let rateLimitTier: String?
            let subscriptionType: String?
            let email: String?

            enum CodingKeys: String, CodingKey {
                case accessToken
                case rateLimitTier
                case subscriptionType
                case email
            }
        }

        /// Convenience init that swallows decode failures and returns nil —
        /// the keychain JSON is a Claude-Code-owned contract and we don't
        /// want one missing optional field to crash the quota fetch.
        static func decode(keychainData: Data?) -> OAuth? {
            guard let data = keychainData, !data.isEmpty else { return nil }
            guard let root = try? JSONDecoder().decode(KeychainRoot.self, from: data) else { return nil }
            return root.claudeAiOauth
        }
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
        }
    }
    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    private struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
        }
    }

    private struct StatusSummary: Decodable {
        struct Status: Decodable { let indicator: String?; let description: String? }
        let status: Status?
    }
}

/// Plan mapping mirroring CodexBar's `ClaudePlan`. We only need a human label
/// (`"Max"` / `"Pro"` / etc.) so we don't expose the full enum.
enum ClaudePlan {
    static func label(forSubscriptionType sub: String?, rateLimitTier tier: String?) -> String? {
        if let t = tier?.lowercased(), t.contains("max") { return "Max" }
        if let t = tier?.lowercased(), t.contains("ultra") { return "Ultra" }
        if let s = sub?.lowercased() {
            if s.contains("max") { return "Max" }
            if s.contains("ultra") { return "Ultra" }
            if s.contains("pro") { return "Pro" }
            if s.contains("team") { return "Team" }
            if s.contains("enterprise") { return "Enterprise" }
        }
        return nil
    }
}