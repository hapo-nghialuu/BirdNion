import Foundation

/// MiniMax API host region. "io" is the global host, "com" the mainland China
/// host. Persisted in UserDefaults under `defaultsKey` (bound by SettingsStore
/// and read directly by `MiniMaxProvider`, which has no SettingsStore handle).
enum MiniMaxRegion: String, CaseIterable, Identifiable {
    case io
    case com

    static let defaultsKey = "minimaxRegion"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .io:  "Global (platform.minimax.io)"
        case .com: "Trung Quốc (platform.minimaxi.com)"
        }
    }
    /// API host for the `coding_plan/remains` endpoint (matches CodexBar).
    /// The legacy `api.minimax.<tld>` host is no longer reliable — the .com
    /// TLD does not resolve.
    var platformHost: String {
        switch self {
        case .io:  "platform.minimax.io"
        case .com: "platform.minimaxi.com"
        }
    }
    /// API host for API-token remains endpoints.
    var apiHost: String {
        switch self {
        case .io:  "api.minimax.io"
        case .com: "api.minimaxi.com"
        }
    }
    var tokenPlanRemainsURL: URL {
        URL(string: "https://\(apiHost)/v1/token_plan/remains")!
    }
    var apiCodingPlanRemainsURL: URL {
        URL(string: "https://\(apiHost)/v1/api/openplatform/coding_plan/remains")!
    }
    /// Token Plan / coding-plan management page for this region.
    var dashboardURL: URL {
        URL(string: "https://\(platformHost)/user-center/payment/coding-plan?cycle_type=3")!
    }

    static var current: MiniMaxRegion {
        MiniMaxRegion(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "io") ?? .io
    }
}

/// MiniMax Token Plan quota provider.
///
/// Endpoint: `GET https://api.minimax.io/v1/token_plan/remains`
/// Auth: `Authorization: Bearer <key>` (verified 2026-06-23 against the live
///   endpoint; raw token without `Bearer ` returns `status_code: 1004`).
///
/// Response envelope (verified live):
/// ```json
/// {
///   "base_resp": { "status_code": 0, "status_msg": "success" },
///   "model_remains": [
///     {
///       "model_name": "general",
///       "current_interval_remaining_percent": 69,
///       "current_weekly_remaining_percent": 96,
///       ...
///     },
///     {
///       "model_name": "video",
///       "current_interval_remaining_percent": 100,
///       "current_weekly_remaining_percent": 100,
///       ...
///     }
///   ]
/// }
/// ```
///
/// Multi-model handling: each model becomes its own pair of windows
/// (interval + weekly). This makes the breakdown visible per-model
/// instead of collapsing everything into one "min across models" number.
/// Models in `excludedModels` are filtered out (e.g. "video" — MiniMax
/// returns a separate quota bucket for video generation that BOSS does
/// not want surfaced in the popover).
final class MiniMaxProvider: QuotaProvider {
    /// Coding Plan endpoint for the user's selected region. Mirrors CodexBar's
    /// `platform.<tld>/v1/api/openplatform/coding_plan/remains` — this is the
    /// canonical endpoint and is the only one that returns the plan name
    /// (`current_subscribe_title` / `plan_name`).
    static func endpoint(region: MiniMaxRegion = .current) -> URL {
        URL(string: "https://\(region.platformHost)/v1/api/openplatform/coding_plan/remains")!
    }

    /// API-token fetch candidates. Global keeps the current platform endpoint
    /// first because it is known to return plan metadata there. Mainland China
    /// uses the API host first; `platform.minimaxi.com/.../remains` returns 404.
    static func apiTokenEndpoints(region: MiniMaxRegion = .current) -> [URL] {
        switch region {
        case .io:
            return deduplicated([
                endpoint(region: region),
                region.tokenPlanRemainsURL,
                region.apiCodingPlanRemainsURL
            ])
        case .com:
            return deduplicated([
                region.tokenPlanRemainsURL,
                region.apiCodingPlanRemainsURL,
                endpoint(region: region)
            ])
        }
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted {
            result.append(url)
        }
        return result
    }

    /// Models to filter out of the popover (case-insensitive).
    /// MiniMax returns separate quota buckets per capability; "video"
    /// is tracked but BOSS doesn't surface it.
    static let excludedModels: Set<String> = ["video"]

    /// Look up the user-set accountLabel override from the BirdNion config.
    /// One file read per fetch — cheap given the 120s poll interval.
    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    /// Combine user override with token-derived default. Override wins if
    /// non-empty; otherwise the first 8 characters of the token serve as a
    /// zero-config identifier (e.g. "sk-cp-dEwaSdME").
    static func deriveAccountLabel(override: String?, token: String) -> String {
        if let o = override, !o.isEmpty { return o }
        return String(token.prefix(8))
    }

    let id = "minimax"
    let displayName = "MiniMax"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderStatus {
        // Token resolution order (matches CodexBar): env vars
        // (`MINIMAX_CODING_API_KEY` / `MINIMAX_API_KEY`) → entry in
        // `~/.config/birdnion/settings.json`. No more Keychain fallback — the
        // 2026-06-25 storage refactor consolidated all secrets into the
        // single config file.
        let token = BirdNionConfigStore.minimaxToken()
        if let token, !token.isEmpty {
            return await fetchWithAPIToken(token)
        }
        // No API token → try cookie/web fallback (best-effort).
        return await fetchWithCookie()
    }

    // MARK: - API token path

    private func fetchWithAPIToken(_ token: String) async -> ProviderStatus {
        let accountLabel = Self.deriveAccountLabel(override: override(), token: token)
        let region = MiniMaxRegion.current
        let endpoints = Self.apiTokenEndpoints(region: region)
        var lastError: String?
        var credentialError: String?

        for (index, endpoint) in endpoints.enumerated() {
            let isLast = index == endpoints.count - 1
            let attempt = await fetchAPITokenData(token: token, url: endpoint)
            if let data = attempt.data {
                let status = parse(data, accountLabel: accountLabel)
                if let error = status.error {
                    if Self.isCredentialError(error) {
                        credentialError = error
                    }
                    if Self.shouldTryNextAPIEndpoint(afterParseError: error), !isLast {
                        lastError = error
                        continue
                    }
                }
                return status
            }

            if let error = attempt.error {
                lastError = error
                if Self.isCredentialError(error) {
                    credentialError = error
                }
                if !attempt.shouldTryNext || isLast {
                    return ProviderStatus(id: id, displayName: displayName, windows: [],
                                          lastUpdated: Date(),
                                          error: credentialError ?? error)
                }
            }
        }

        return ProviderStatus(id: id, displayName: displayName, windows: [],
                              lastUpdated: Date(),
                              error: credentialError ?? lastError ?? "Không lấy được quota")
    }

    private struct APIAttempt {
        let data: Data?
        let error: String?
        let shouldTryNext: Bool
    }

    private func fetchAPITokenData(token: String, url: URL) async -> APIAttempt {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("BirdNion", forHTTPHeaderField: "MM-API-Source")
        req.timeoutInterval = 15

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            guard let h = r as? HTTPURLResponse else {
                return APIAttempt(data: nil, error: "Response không phải HTTP", shouldTryNext: false)
            }
            data = d
            httpResponse = h
        } catch {
            return APIAttempt(data: nil,
                              error: "Network: \(error.localizedDescription)",
                              shouldTryNext: true)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return APIAttempt(data: nil,
                              error: "HTTP \(httpResponse.statusCode)",
                              shouldTryNext: Self.shouldTryNextAPIEndpoint(statusCode: httpResponse.statusCode))
        }
        return APIAttempt(data: data, error: nil, shouldTryNext: false)
    }

    private static func shouldTryNextAPIEndpoint(statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403 || statusCode == 404 || statusCode == 405
    }

    private static func shouldTryNextAPIEndpoint(afterParseError error: String) -> Bool {
        let normalized = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("response thiếu trường")
            || normalized.contains("invalid api key")
            || normalized.contains("invalid credentials")
    }

    private static func isCredentialError(_ error: String) -> Bool {
        let normalized = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("invalid api key")
            || normalized.contains("invalid credentials")
            || normalized == "http 401"
            || normalized == "http 403"
    }

    // MARK: - Cookie / web fallback path

    /// Called when no API token is configured. Tries to read a session cookie
    /// from the user's browser for `platform.minimax.io` (global) then
    /// `platform.minimaxi.com` (China). On success, hits the same
    /// `coding_plan/remains` JSON endpoint with the cookie header.
    /// Returns an error status when neither domain yields a usable cookie.
    private func fetchWithCookie() async -> ProviderStatus {
        let region = MiniMaxRegion.current
        // Prefer the region-specific domain first, then try the other one as
        // fallback so users don't have to change the region picker just to get
        // cookie auth working.
        let domains: [String]
        switch region {
        case .io:  domains = ["platform.minimax.io", "platform.minimaxi.com"]
        case .com: domains = ["platform.minimaxi.com", "platform.minimax.io"]
        }

        guard let cookieHeader = domains.lazy.compactMap({ [self] in
            ProviderCookieReader.resolvedCookieHeader(providerID: self.id, domain: $0)
        }).first else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Chưa cấu hình token và không tìm thấy cookie trình duyệt")
        }

        var req = URLRequest(url: Self.endpoint(region: region))
        req.httpMethod = "GET"
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://\(region.platformHost)", forHTTPHeaderField: "Origin")
        req.timeoutInterval = 15

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            guard let h = r as? HTTPURLResponse else {
                return ProviderStatus(id: id, displayName: displayName, windows: [],
                                      lastUpdated: Date(), error: "Response không phải HTTP")
            }
            data = d
            httpResponse = h
        } catch {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Network (cookie): \(error.localizedDescription)")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "HTTP \(httpResponse.statusCode) (cookie)")
        }
        // Parse the same JSON envelope as the API token path.
        // accountLabel is not derived from a token, so use override or a
        // generic placeholder.
        let label = override() ?? "cookie"
        return parse(data, accountLabel: label)
    }

    func parse(_ data: Data, accountLabel: String) -> ProviderStatus {
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(RemainsResponse.self, from: data) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response thiếu trường")
        }
        // MiniMax returns HTTP 200 even for auth/permission failures; the
        // real status lives in `base_resp.status_code`. 0 == success.
        if root.base_resp.status_code != 0 {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: root.base_resp.status_msg)
        }
        guard !root.model_remains.isEmpty else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Không có model nào trong response")
        }
        // 1 model → compact labels ("5 giờ" / "Tuần")
        // ≥2 models → disambiguate with model name prefix ("general 5h" / etc.)
        let visible = root.model_remains.filter { !Self.excludedModels.contains($0.model_name.lowercased()) }
        guard !visible.isEmpty else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Tất cả model đều nằm trong danh sách loại trừ")
        }
        let multiple = visible.count > 1
        var windows: [QuotaWindow] = []
        // `resetDate` comes from the API's absolute window-end timestamps,
        // `end_time` (interval) and `weekly_end_time` (weekly). Both are
        // MILLISECOND epoch values — verified live 2026-06-26: `end_time`
        // resolved to ~1.8h from now, matching `remains_time/1000`. Using
        // the absolute end beats the `*_remains_time` durations because it
        // doesn't drift with fetch latency. Missing/zero fields fall back
        // to `lastUpdated + windowSeconds` in `WindowRow.resetText`.
        func resetDate(fromEpochMs ms: Int?) -> Date? {
            guard let ms, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        for m in visible {
            let prefix = multiple ? "\(m.model_name) " : ""
            let intervalReset = resetDate(fromEpochMs: m.end_time)
            let weeklyReset = resetDate(fromEpochMs: m.weekly_end_time)
            windows.append(QuotaWindow(
                label: "\(prefix)5 giờ",
                usedPct: 100 - m.current_interval_remaining_percent,
                remainingPct: m.current_interval_remaining_percent,
                resetDate: intervalReset,
                windowSeconds: 5 * 3600))
            windows.append(QuotaWindow(
                label: "\(prefix)Tuần",
                usedPct: 100 - m.current_weekly_remaining_percent,
                remainingPct: m.current_weekly_remaining_percent,
                resetDate: weeklyReset,
                windowSeconds: 7 * 24 * 3600))
        }

        // Best-effort: subscription expiry / renewal window
        // `current_subscribe_end_time_ts` and `renewal_trigger_time_ts` are
        // epoch-ms values that appear in some combo/subscription responses.
        // When present, surface a pseudo-window so the user sees the date.
        if let expiresMs = root.current_subscribe_end_time_ts, expiresMs > 0 {
            let expiresDate = Date(timeIntervalSince1970: TimeInterval(expiresMs) / 1000)
            let renewsDate = root.renewal_trigger_time_ts.flatMap { ms -> Date? in
                guard ms > 0 else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }
            // Show "Gia hạn" if a renewal date is known, otherwise "Hết hạn".
            let subLabel = renewsDate != nil ? "Gia hạn" : "Hết hạn"
            let resetDate = renewsDate ?? expiresDate
            // Percent is not meaningful for subscription expiry — show 100%
            // remaining until expired (sentinel so the bar doesn't look alarming).
            windows.append(QuotaWindow(
                label: subLabel,
                usedPct: 0,
                remainingPct: 100,
                resetDate: resetDate,
                windowSeconds: 30 * 24 * 3600))
        }

        // Best-effort: points/credit balance exposed as a ProviderCostSnapshot.
        // `points_balance` / `point_balance` / `credits_balance` — whichever
        // the API returns first. Treated as a raw balance with no limit when
        // no limit field is present (limit defaults to same value → 0 used).
        let cost: ProviderCostSnapshot? = {
            guard let balance = root.pointsBalance, balance > 0 else { return nil }
            return ProviderCostSnapshot(
                used: 0,
                limit: balance,
                currencyCode: "pts",
                period: nil,
                resetsAt: nil,
                nextRegenAmount: nil,
                personalUsed: nil,
                updatedAt: Date())
        }()

        return ProviderStatus(id: id, displayName: displayName,
                              windows: windows,
                              lastUpdated: Date(),
                              error: nil,
                              accountLabel: accountLabel,
                              planName: root.planDisplayName,
                              cost: cost)
    }

    private struct RemainsResponse: Decodable {
        let base_resp: BaseResp
        let model_remains: [ModelRemain]
        // Plan display name comes from one of these (the API may swap
        // between payloads). `current_subscribe_title` is the most common.
        let current_subscribe_title: String?
        let plan_name: String?
        let combo_title: String?
        let current_plan_title: String?
        // Best-effort subscription dates (epoch-ms). Present in some
        // combo/subscription-plan responses but not the standard API response.
        let current_subscribe_end_time_ts: Int?
        let renewal_trigger_time_ts: Int?
        // Best-effort points/credit balance. Field name varies by API version;
        // decoded manually so we can check all known aliases.
        let points_balance: Double?
        let point_balance: Double?
        let credits_balance: Double?
        let credit_balance: Double?

        /// First non-empty plan name candidate, trimmed. nil if none set.
        var planDisplayName: String? {
            for raw in [current_subscribe_title, plan_name, combo_title, current_plan_title] {
                if let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !v.isEmpty { return v }
            }
            return nil
        }

        /// First non-nil, positive balance across all known field names.
        var pointsBalance: Double? {
            for v in [points_balance, point_balance, credits_balance, credit_balance] {
                if let b = v, b > 0 { return b }
            }
            return nil
        }

        private enum CodingKeys: String, CodingKey {
            case base_resp
            case model_remains
            case current_subscribe_title
            case plan_name
            case combo_title
            case current_plan_title
            case current_subscribe_end_time_ts
            case renewal_trigger_time_ts
            case points_balance
            case point_balance
            case credits_balance
            case credit_balance
        }
    }
    private struct BaseResp: Decodable {
        let status_code: Int
        let status_msg: String
    }
    private struct ModelRemain: Decodable {
        let model_name: String
        let current_interval_total_count: Int
        let current_interval_usage_count: Int
        let current_interval_remaining_percent: Int
        let current_weekly_total_count: Int
        let current_weekly_usage_count: Int
        let current_weekly_remaining_percent: Int
        /// Absolute millisecond-epoch timestamp when the current 5h
        /// interval window ends. `WindowRow` falls back to
        /// `lastUpdated + windowSeconds` when missing/zero.
        let end_time: Int?
        /// Absolute millisecond-epoch timestamp when the weekly window ends.
        let weekly_end_time: Int?
    }
}
