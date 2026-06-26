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
    /// Legacy `token_plan/remains` host. Kept for reference only — the
    /// provider now uses `codingPlanURL` exclusively.
    var apiHost: String {
        switch self {
        case .io:  "api.minimax.io"
        case .com: "api.minimaxi.com"
        }
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
        // `~/.birdnion/settings.json`. No more Keychain fallback — the
        // 2026-06-25 storage refactor consolidated all secrets into the
        // single config file.
        let token = BirdNionConfigStore.minimaxToken()
        guard let token, !token.isEmpty else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Chưa cấu hình token")
        }
        let accountLabel = Self.deriveAccountLabel(override: override(), token: token)

        var req = URLRequest(url: Self.endpoint(region: .current))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "Response không phải HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            return ProviderStatus(id: id, displayName: displayName, windows: [],
                                  lastUpdated: Date(),
                                  error: "HTTP \(http.statusCode)")
        }
        return parse(data, accountLabel: accountLabel)
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
        return ProviderStatus(id: id, displayName: displayName,
                              windows: windows,
                              lastUpdated: Date(),
                              error: nil,
                              accountLabel: accountLabel,
                              planName: root.planDisplayName)
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

        /// First non-empty candidate, trimmed. nil if none set.
        var planDisplayName: String? {
            for raw in [current_subscribe_title, plan_name, combo_title, current_plan_title] {
                if let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !v.isEmpty { return v }
            }
            return nil
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