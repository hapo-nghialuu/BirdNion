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
        return parse(data, accountLabel: accountLabel)
    }

    func parse(_ data: Data, accountLabel: String) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        // Z.ai returns HTTP 200 even on logical errors; check the envelope.
        guard root.success, root.code == 200, let limits = root.data?.limits, !limits.isEmpty else {
            return failure(root.msg.isEmpty ? "Không có dữ liệu quota" : root.msg)
        }
        // Separate TOKENS_LIMIT entries: longer window = primary "Tokens",
        // shorter window = session (e.g. "5 giờ"). Sort by window length desc.
        let tokenLimits = limits.filter { $0.type == "TOKENS_LIMIT" }
            .sorted { Self.windowMinutes(unit: $0.unit, number: $0.number) > Self.windowMinutes(unit: $1.unit, number: $1.number) }
        let isPrimaryTokens: (LimitRaw) -> Bool = { e in
            guard e.type == "TOKENS_LIMIT" else { return false }
            return e === tokenLimits.first
        }
        let windows: [QuotaWindow] = limits.map { e in
            let usedInt = Int(Self.computedUsedPercent(e).rounded())
            let clampedUsed = max(0, min(100, usedInt))
            let resetDate = e.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            let windowSecs = Self.windowSeconds(unit: e.unit, number: e.number)
            return QuotaWindow(
                label: Self.label(type: e.type, unit: e.unit, number: e.number, isPrimaryTokens: isPrimaryTokens(e)),
                usedPct: clampedUsed,
                remainingPct: 100 - clampedUsed,
                resetDate: resetDate,
                windowSeconds: windowSecs,
                allowance: Self.allowance(for: e))
        }
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
    /// - TOKENS_LIMIT short window (session, e.g. 5h)   → "5 giờ" / time label
    /// - TIME_LIMIT minutes number=1                    → "MCP"
    /// - TIME_LIMIT other                               → "Monthly" or time label
    static func label(type: String, unit: Int, number: Int, isPrimaryTokens: Bool = true) -> String {
        if type == "TOKENS_LIMIT" {
            if isPrimaryTokens { return "Tokens" }
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

    /// Native token counts for TOKENS_LIMIT entries when the payload carries
    /// the limit field (`usage`). TIME_LIMIT entries and percent-only payloads
    /// stay nil — the unit of their raw values isn't exposed.
    private static func allowance(for e: LimitRaw) -> QuotaAllowance? {
        guard e.type == "TOKENS_LIMIT", let limit = e.usage, limit > 0 else { return nil }
        let usedRaw: Int? = e.remaining.map { limit - $0 }.flatMap { fromRem in
            e.currentValue.map { max(fromRem, $0) } ?? fromRem
        } ?? e.currentValue
        return QuotaAllowance(
            used: usedRaw.map { Double(max(0, min(limit, $0))) },
            remaining: e.remaining.map(Double.init),
            limit: Double(limit),
            unit: .tokens)
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
            ].compactMap { $0 }.compactMap { $0 }
            let trimmed = candidates.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        enum CodingKeys: String, CodingKey {
            case limits
            case planName = "plan_name"
            case plan
            case planType = "plan_type"
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
        }
        enum CodingKeys: String, CodingKey {
            case type, unit, number, percentage, usage, remaining
            case currentValue = "current_value"
            case nextResetTime = "next_reset_time"
        }
    }
}
