import Foundation

/// Z.ai / GLM API host region. Global is `api.z.ai`; mainland China is
/// `open.bigmodel.cn`. Persisted in UserDefaults; the picker in ProvidersPane
/// binds the same key.
enum ZaiRegion: String, CaseIterable, Identifiable {
    case global
    case cn

    static let defaultsKey = "zaiRegion"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .global: "Global (api.z.ai)"
        case .cn:     "BigModel CN (open.bigmodel.cn)"
        }
    }
    var baseHost: String {
        switch self {
        case .global: "api.z.ai"
        case .cn:     "open.bigmodel.cn"
        }
    }
    static var current: ZaiRegion {
        ZaiRegion(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "global") ?? .global
    }
}

/// Z.ai / GLM coding-plan quota provider.
///
/// Endpoint: `GET https://<host>/api/monitor/usage/quota/limit`
/// Auth: `Authorization: Bearer <key>`.
///
/// Response: `{ code, success, data: { limits: [ { type, unit, number,
/// percentage, remaining, next_reset_time } ], plan_name } }`. Each limit
/// entry maps to one `QuotaWindow` (percentage is the % already used).
final class ZaiProvider: QuotaProvider {
    let id = "zai"
    let displayName = "z.ai"

    static func endpoint(region: ZaiRegion = .current) -> URL {
        URL(string: "https://\(region.baseHost)/api/monitor/usage/quota/limit")!
    }

    /// BigModel CN console balance endpoint (www host, not open.*). Global
    /// z.ai has no documented equivalent — CN region only.
    static let cnBalanceURL =
        URL(string: "https://www.bigmodel.cn/api/biz/account/query-customer-account-report")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    func fetch() async throws -> ProviderStatus {
        let token = BirdNionConfigStore.apiKey(provider: id)
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình token")
        }
        let accountLabel = override() ?? String(token.prefix(8))

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
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        guard (200..<300).contains(http.statusCode) else { return failure("HTTP \(http.statusCode)") }
        // BigModel CN-only: pay-as-you-go account balance lives on the www
        // console host (upstream verified 2026-08). Best-effort — a failed
        // balance lookup must never break quota display.
        var extraWindows: [QuotaWindow] = []
        if ZaiRegion.current == .cn,
           let balance = await fetchAccountBalance(token: token) {
            extraWindows.append(balance)
        }
        return parse(data, accountLabel: accountLabel, extraWindows: extraWindows)
    }

    func parse(_ data: Data, accountLabel: String, extraWindows: [QuotaWindow] = []) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        // Z.ai returns HTTP 200 even on logical errors; check the envelope.
        guard root.success, root.code == 200, let limits = root.data?.limits, !limits.isEmpty else {
            return failure(root.msg.isEmpty ? "Không có dữ liệu quota" : root.msg)
        }
        // Separate quota entries: TOKENS_LIMIT and CREDIT_LIMIT both carry the
        // coding-plan quota (upstream treats them identically); longer window =
        // primary "Tokens"/"Credits", shorter window = session (e.g. "5 giờ").
        let tokenLimits = limits.filter { $0.type == "TOKENS_LIMIT" || $0.type == "CREDIT_LIMIT" }
            .sorted { Self.windowMinutes(unit: $0.unit, number: $0.number) > Self.windowMinutes(unit: $1.unit, number: $1.number) }
        let isPrimaryTokens: (LimitRaw) -> Bool = { e in
            guard e.type == "TOKENS_LIMIT" || e.type == "CREDIT_LIMIT" else { return false }
            return e === tokenLimits.first
        }
        let windows: [QuotaWindow] = limits.map { e in
            let usedInt = Int(Self.computedUsedPercent(e).rounded())
            let clampedUsed = max(0, min(100, usedInt))
            // Upstream drops a 5h window's reset when it lands >5h ahead — a
            // 5-hour Coding Plan reset cannot be ten hours out (API quirk).
            let isFiveHour = e.type != "TIME_LIMIT"
                && Self.windowMinutes(unit: e.unit, number: e.number) == 300
            let resetDate = e.nextResetTime
                .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                .flatMap { d in
                    isFiveHour && d.timeIntervalSinceNow > (5 * 3600 + 60) ? nil : d
                }
            let windowSecs = Self.windowSeconds(unit: e.unit, number: e.number)
            return QuotaWindow(
                label: Self.label(type: e.type, unit: e.unit, number: e.number, isPrimaryTokens: isPrimaryTokens(e)),
                usedPct: clampedUsed,
                remainingPct: 100 - clampedUsed,
                subtitle: Self.usageDetailsSubtitle(for: e),
                resetDate: resetDate,
                windowSeconds: windowSecs,
                allowance: Self.allowance(for: e))
        } + extraWindows
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            planName: root.data?.planName)
    }

    /// Human label from the raw limit type/unit/number.
    /// unit codes (z.ai): 1=days, 3=hours, 5=minutes, 6=weeks.
    ///
    /// Classification:
    /// - TOKENS_LIMIT long window (isPrimaryTokens=true) → "Tokens"
    /// - CREDIT_LIMIT long window (isPrimaryTokens=true) → "Credits"
    /// - quota-type short window (session, e.g. 5h)     → "5 giờ" / time label
    /// - TIME_LIMIT minutes number=1                    → "MCP"
    /// - TIME_LIMIT other                               → "Monthly" or time label
    static func label(type: String, unit: Int, number: Int, isPrimaryTokens: Bool = true) -> String {
        if type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" {
            if isPrimaryTokens { return type == "CREDIT_LIMIT" ? "Credits" : "Tokens" }
            // Session/short window — show the duration
            return Self.unitLabel(unit: unit, number: number)
        }
        // TIME_LIMIT
        if unit == 5 && number == 1 { return "MCP" }      // MCP monthly marker (1 min placeholder)
        if unit == 1 && number >= 28 { return "Monthly" } // 28-31 day monthly window
        return Self.unitLabel(unit: unit, number: number)
    }

    /// Plain duration label for a unit/number pair.
    private static func unitLabel(unit: Int, number: Int) -> String {
        switch unit {
        case 3: return "\(number) giờ"
        case 1: return "\(number) ngày"
        case 5: return "\(number) phút"
        case 6: return number == 1 ? "Tuần" : "\(number) tuần"
        default: return "Giới hạn"
        }
    }

    /// Window length in minutes (used for sorting token limits long vs short).
    static func windowMinutes(unit: Int, number: Int) -> Int {
        guard number > 0 else { return 0 }
        switch unit {
        case 5: return number
        case 3: return number * 60
        case 1: return number * 24 * 60
        case 6: return number * 7 * 24 * 60
        default: return 0
        }
    }

    /// Window length in seconds for `QuotaWindow.windowSeconds`. nil when unknown.
    static func windowSeconds(unit: Int, number: Int) -> Int? {
        let mins = windowMinutes(unit: unit, number: number)
        return mins > 0 ? mins * 60 : nil
    }

    /// Port of CodexBar's `ZaiLimitEntry.computedUsedPercent`:
    /// Derives used% from usage(limit)/remaining/currentValue fields when available,
    /// falling back to the raw `percentage` field. Prevents spurious 100% when
    /// the API omits quota fields.
    private static func computedUsedPercent(_ e: LimitRaw) -> Double {
        guard let limit = e.usage, limit > 0 else {
            // No usage-limit field — fall back to API percentage directly
            return Double(e.percentage)
        }
        var usedRaw: Int?
        if let remaining = e.remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue = e.currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue = e.currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else {
            // Fallback: API percentage
            return Double(e.percentage)
        }
        let used = max(0, min(limit, usedRaw))
        return min(100, max(0, (Double(used) / Double(limit)) * 100))
    }

    /// Per-model MCP usage breakdown shipped inside a TIME_LIMIT entry
    /// (`usageDetails[].modelCode`/`usage`). Rendered as the window subtitle —
    /// upstream lists them as detail rows under "MCP quota".
    private static func usageDetailsSubtitle(for e: LimitRaw) -> String? {
        guard e.type == "TIME_LIMIT", let details = e.usageDetails, !details.isEmpty else {
            return nil
        }
        let parts = details.prefix(5).compactMap { d -> String? in
            guard let code = d.modelCode, !code.isEmpty else { return nil }
            return d.usage.map { "\(code) \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Native token counts for quota entries when the payload carries
    /// the limit field (`usage`). TIME_LIMIT entries and percent-only payloads
    /// stay nil — the unit of their raw values isn't exposed.
    private static func allowance(for e: LimitRaw) -> QuotaAllowance? {
        guard e.type == "TOKENS_LIMIT" || e.type == "CREDIT_LIMIT",
              let limit = e.usage, limit > 0 else { return nil }
        let usedRaw: Int? = e.remaining.map { limit - $0 }.flatMap { fromRem in
            e.currentValue.map { max(fromRem, $0) } ?? fromRem
        } ?? e.currentValue
        return QuotaAllowance(
            used: usedRaw.map { Double(max(0, min(limit, $0))) },
            remaining: e.remaining.map(Double.init),
            limit: Double(limit),
            unit: e.type == "CREDIT_LIMIT" ? .credits : .tokens)
    }

    /// BigModel CN pay-as-you-go balance (console host, not the open.* API
    /// host). Accepts `Bearer <key>` or the raw key. nil on any failure —
    /// callers treat it as optional enrichment, never as quota state.
    private func fetchAccountBalance(token: String) async -> QuotaWindow? {
        var req = URLRequest(url: Self.cnBalanceURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 5  // well below the fetch deadline
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONDecoder().decode(CNBalanceResponse.self, from: data),
              body.success == true, let d = body.data else { return nil }
        // Only real numeric values render — a null must not become "¥0.00".
        guard let value = d.availableBalance ?? d.balance else { return nil }
        var parts = [String(format: "¥%.2f", value)]
        if let recharged = d.rechargeAmount { parts.append(String(format: "nạp ¥%.2f", recharged)) }
        if let granted = d.giveAmount, granted > 0 { parts.append(String(format: "tặng ¥%.2f", granted)) }
        if let spent = d.totalSpendAmount { parts.append(String(format: "đã tiêu ¥%.2f", spent)) }
        return QuotaWindow(
            label: "Số dư", usedPct: 0, remainingPct: 100,
            subtitle: parts.joined(separator: " · "), isSupplementary: true)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    private struct QuotaResponse: Decodable {
        let code: Int
        let msg: String
        let success: Bool
        let data: QuotaData?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.code = (try? c.decode(Int.self, forKey: .code)) ?? 0
            self.msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
            self.success = (try? c.decode(Bool.self, forKey: .success)) ?? false
            self.data = try? c.decodeIfPresent(QuotaData.self, forKey: .data)
        }
        enum CodingKeys: String, CodingKey { case code, msg, success, data }
    }
    private struct QuotaData: Decodable {
        let limits: [LimitRaw]
        let planName: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.limits = (try? c.decodeIfPresent([LimitRaw].self, forKey: .limits)) ?? []
            let candidates = [
                try? c.decodeIfPresent(String.self, forKey: .planName),
                try? c.decodeIfPresent(String.self, forKey: .plan),
                try? c.decodeIfPresent(String.self, forKey: .planType),
                try? c.decodeIfPresent(String.self, forKey: .packageName),
                try? c.decodeIfPresent(String.self, forKey: .level),
            ].compactMap { $0 }.compactMap { $0 }
            let trimmed = candidates.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        enum CodingKeys: String, CodingKey {
            case limits
            case planName = "plan_name"
            case plan
            case planType = "plan_type"
            case packageName = "package_name"
            case level
        }
    }
    // NOTE: `LimitRaw` is a class (reference type) so that `===` identity comparison
    // works in the `isPrimaryTokens` closure used to distinguish the longest
    // TOKENS_LIMIT entry from shorter session windows.
    private final class LimitRaw: Decodable {
        let type: String
        let unit: Int
        let number: Int
        /// Raw API percentage (% already used). Used as fallback only.
        let percentage: Int
        /// Total limit (quota ceiling). Used with `remaining`/`currentValue` to
        /// compute accurate used% without risking spurious 100%.
        let usage: Int?
        /// Tokens/requests already consumed in this window.
        let currentValue: Int?
        /// Tokens/requests still available. Preferred over currentValue when both present.
        let remaining: Int?
        let nextResetTime: Int?
        /// Per-model breakdown inside TIME_LIMIT entries (upstream renders each
        /// as a detail row under "MCP quota").
        let usageDetails: [UsageDetail]?

        required init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = (try? c.decode(String.self, forKey: .type)) ?? ""
            self.unit = (try? c.decode(Int.self, forKey: .unit)) ?? 0
            self.number = (try? c.decode(Int.self, forKey: .number)) ?? 0
            self.percentage = (try? c.decode(Int.self, forKey: .percentage)) ?? 0
            self.usage = try? c.decodeIfPresent(Int.self, forKey: .usage)
            self.currentValue = try? c.decodeIfPresent(Int.self, forKey: .currentValue)
            self.remaining = try? c.decodeIfPresent(Int.self, forKey: .remaining)
            self.nextResetTime = try? c.decodeIfPresent(Int.self, forKey: .nextResetTime)
            self.usageDetails = try? c.decodeIfPresent([UsageDetail].self, forKey: .usageDetails)
        }
        enum CodingKeys: String, CodingKey {
            case type, unit, number, percentage, usage, remaining
            case currentValue = "current_value"
            case nextResetTime = "next_reset_time"
            case usageDetails = "usageDetails"
        }
    }
    private struct UsageDetail: Decodable {
        let modelCode: String?
        let usage: Int?
        enum CodingKeys: String, CodingKey {
            case modelCode = "modelCode"
            case usage
        }
    }
    private struct CNBalanceResponse: Decodable {
        let success: Bool?
        let data: CNBalanceData?
    }
    private struct CNBalanceData: Decodable {
        let availableBalance: Double?
        let balance: Double?
        let rechargeAmount: Double?
        let giveAmount: Double?
        let totalSpendAmount: Double?
    }
}
