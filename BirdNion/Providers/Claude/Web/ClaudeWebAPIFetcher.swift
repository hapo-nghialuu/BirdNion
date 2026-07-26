import Foundation

// MARK: - ClaudeWebUsageData

/// Usage data fetched directly from claude.ai API endpoints using a browser session cookie.
struct ClaudeWebUsageData: Sendable {
    let sessionPercentUsed: Double
    let sessionResetsAt: Date?
    let weeklyPercentUsed: Double?
    let weeklyResetsAt: Date?
    let opusPercentUsed: Double?
    let extraRateWindows: [NamedRateWindow]
    let extraUsageCost: ProviderCostSnapshot?
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
}

// MARK: - ClaudeWebAPIFetcher

/// Fetches Claude usage data from the claude.ai internal API using browser session cookies.
///
/// API endpoints used:
/// - `GET https://claude.ai/api/organizations`                          → pick org with chat capability
/// - `GET https://claude.ai/api/organizations/{id}/usage`               → session/weekly/opus + extra windows
/// - `GET https://claude.ai/api/account`                                → email + loginMethod
/// - `GET https://claude.ai/api/organizations/{id}/overage_spend_limit` → extraUsageCost (best-effort)
///
/// No CodexBarCore import — SweetCookieKit is accessed via ClaudeWebCookieReader only.
enum ClaudeWebAPIFetcher {

    private static let baseURL = "https://claude.ai/api"

    // MARK: - Fetch errors

    enum FetchError: LocalizedError, Sendable {
        case noSessionKeyFound
        case notSupportedOnThisPlatform
        case invalidResponse
        case unauthorized
        case serverError(statusCode: Int)
        case noOrganization

        var errorDescription: String? {
            switch self {
            case .noSessionKeyFound:
                "Không tìm thấy session cookie claude.ai trong trình duyệt."
            case .notSupportedOnThisPlatform:
                "Chỉ hỗ trợ macOS."
            case .invalidResponse:
                "Phản hồi không hợp lệ từ claude.ai API."
            case .unauthorized:
                "Phiên đăng nhập hết hạn — vui lòng đăng nhập lại claude.ai."
            case let .serverError(code):
                "Claude API lỗi HTTP \(code)."
            case .noOrganization:
                "Không tìm thấy tổ chức Claude cho tài khoản này."
            }
        }
    }

    // MARK: - Public entry points

    /// Auto cookie path: reads sessionKey from browsers via ClaudeWebCookieReader.
    static func fetchUsage(session: URLSession = .shared) async throws -> ClaudeWebUsageData {
        #if !os(macOS)
        throw FetchError.notSupportedOnThisPlatform
        #else
        guard let info = try ClaudeWebCookieReader.sessionKeyInfo(allowAuto: true) else {
            throw FetchError.noSessionKeyFound
        }
        return try await fetchUsage(sessionKeyInfo: info, session: session)
        #endif
    }

    /// Manual cookie path: caller supplies a Cookie header string.
    static func fetchUsage(cookieHeader: String, session: URLSession = .shared) async throws -> ClaudeWebUsageData {
        guard let info = ClaudeWebCookieReader.sessionKeyInfo(cookieHeader: cookieHeader) else {
            throw FetchError.noSessionKeyFound
        }
        return try await fetchUsage(sessionKeyInfo: info, session: session)
    }

    // MARK: - Testing hook

    /// Parses a usage API JSON payload without making network calls or reading cookies.
    /// Use in unit tests with canned JSON data.
    static func _parseUsageResponseForTesting(_ data: Data) throws -> ClaudeWebUsageData {
        try parseUsageResponse(data)
    }

    // MARK: - Core fetch

    private static func fetchUsage(
        sessionKeyInfo info: SessionKeyInfo,
        session: URLSession) async throws -> ClaudeWebUsageData
    {
        // Use a tracker to pick up any Set-Cookie rotation during the session.
        let tracker = SessionKeyTracker(initial: info.key)

        let org = try await fetchOrganizationInfo(tracker: tracker, session: session)
        var data = try await fetchUsageData(orgId: org.id, tracker: tracker, session: session)

        // Parallel best-effort fetches — failures do not abort the main result.
        async let accountInfoAsync = fetchAccountInfo(orgId: org.id, tracker: tracker, session: session)
        async let overageAsync = fetchOverageSpendLimit(orgId: org.id, tracker: tracker, session: session)
        let accountInfo = await accountInfoAsync
        let overage = await overageAsync

        // Merge account info.
        let email = accountInfo?.email
        let loginMethodRaw = accountInfo?.loginMethod

        // Determine organization name: prefer account membership name, fall back to org from /organizations.
        let orgName = accountInfo?.organizationName ?? org.name

        // Resolve loginMethod label.
        let loginMethod = loginMethodRaw ?? ClaudePlanLabeler.webLoginMethod(organization: orgName)

        // Merge extra usage cost from usage body; prefer overage_spend_limit endpoint.
        let finalCost = overage ?? data.extraUsageCost

        return ClaudeWebUsageData(
            sessionPercentUsed: data.sessionPercentUsed,
            sessionResetsAt: data.sessionResetsAt,
            weeklyPercentUsed: data.weeklyPercentUsed,
            weeklyResetsAt: data.weeklyResetsAt,
            opusPercentUsed: data.opusPercentUsed,
            extraRateWindows: data.extraRateWindows,
            extraUsageCost: finalCost,
            accountEmail: email,
            accountOrganization: orgName,
            loginMethod: loginMethod)
    }

    // MARK: - Organizations

    private struct OrganizationInfo {
        let id: String
        let name: String?
    }

    private static func fetchOrganizationInfo(
        tracker: SessionKeyTracker,
        session: URLSession) async throws -> OrganizationInfo
    {
        let url = URL(string: "\(baseURL)/organizations")!
        let request = makeRequest(url: url, tracker: tracker)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        tracker.observe(response: http)
        switch http.statusCode {
        case 200: return try parseOrganizationResponse(data)
        case 401, 403: throw FetchError.unauthorized
        default: throw FetchError.serverError(statusCode: http.statusCode)
        }
    }

    private static func parseOrganizationResponse(_ data: Data) throws -> OrganizationInfo {
        guard let orgs = try? JSONDecoder().decode([OrgResponse].self, from: data) else {
            throw FetchError.invalidResponse
        }
        guard let selected = orgs.first(where: { $0.hasChatCapability })
            ?? orgs.first(where: { !$0.isApiOnly })
            ?? orgs.first
        else {
            throw FetchError.noOrganization
        }
        let name = selected.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OrganizationInfo(id: selected.uuid, name: name?.isEmpty == false ? name : nil)
    }

    private struct OrgResponse: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?

        var normalizedCaps: Set<String> { Set((capabilities ?? []).map { $0.lowercased() }) }
        var hasChatCapability: Bool { normalizedCaps.contains("chat") }
        var isApiOnly: Bool {
            let c = normalizedCaps
            return !c.isEmpty && c == ["api"]
        }
    }

    // MARK: - Usage data

    private struct RawUsageData {
        let sessionPercentUsed: Double
        let sessionResetsAt: Date?
        let weeklyPercentUsed: Double?
        let weeklyResetsAt: Date?
        let opusPercentUsed: Double?
        let extraRateWindows: [NamedRateWindow]
        let extraUsageCost: ProviderCostSnapshot?
    }

    private static func fetchUsageData(
        orgId: String,
        tracker: SessionKeyTracker,
        session: URLSession) async throws -> RawUsageData
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage")!
        let request = makeRequest(url: url, tracker: tracker)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        tracker.observe(response: http)
        switch http.statusCode {
        case 200: return try parseUsageData(from: data)
        case 401, 403: throw FetchError.unauthorized
        default: throw FetchError.serverError(statusCode: http.statusCode)
        }
    }

    private static func parseUsageData(from data: Data) throws -> RawUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }

        // five_hour = session window (null on enterprise/credit accounts → treat as 0%)
        var sessionPercent: Double = 0
        var sessionResets: Date?
        if let fiveHour = json["five_hour"] as? [String: Any] {
            sessionPercent = percentValue(from: fiveHour["utilization"]) ?? 0
            sessionResets = (fiveHour["resets_at"] as? String).flatMap(parseISO8601Date)
        }

        // seven_day = weekly window
        var weeklyPercent: Double?
        var weeklyResets: Date?
        if let sevenDay = json["seven_day"] as? [String: Any] {
            weeklyPercent = percentValue(from: sevenDay["utilization"])
            weeklyResets = (sevenDay["resets_at"] as? String).flatMap(parseISO8601Date)
        }
        // 2026 schema: some accounts no longer return a flat `seven_day` —
        // weekly limits live only in the `limits` array. Use the account-wide
        // ("All models") weekly entry as the main weekly window in that case.
        if weeklyPercent == nil,
           let allModels = ClaudeWebExtraRateWindowParser.allModelsWeeklyLimit(from: json) {
            weeklyPercent = allModels.percent
            weeklyResets = allModels.resetsAt
        }

        // seven_day_sonnet preferred over seven_day_opus
        var opusPercent: Double?
        if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
            opusPercent = percentValue(from: sonnet["utilization"])
        } else if let opus = json["seven_day_opus"] as? [String: Any] {
            opusPercent = percentValue(from: opus["utilization"])
        }

        let extraWindows = ClaudeWebExtraRateWindowParser.parse(from: json).windows
        let extraCost = parseExtraUsageCost(json["extra_usage"])

        return RawUsageData(
            sessionPercentUsed: sessionPercent,
            sessionResetsAt: sessionResets,
            weeklyPercentUsed: weeklyPercent,
            weeklyResetsAt: weeklyResets,
            opusPercentUsed: opusPercent,
            extraRateWindows: extraWindows,
            extraUsageCost: extraCost)
    }

    /// Public parse entry point for unit tests (canned JSON, no network).
    /// Test entry point — parses a canned usage JSON payload (no network).
    static func parseUsageForTesting(_ data: Data) throws -> ClaudeWebUsageData {
        try parseUsageResponse(data)
    }

    private static func parseUsageResponse(_ data: Data) throws -> ClaudeWebUsageData {
        let raw = try parseUsageData(from: data)
        return ClaudeWebUsageData(
            sessionPercentUsed: raw.sessionPercentUsed,
            sessionResetsAt: raw.sessionResetsAt,
            weeklyPercentUsed: raw.weeklyPercentUsed,
            weeklyResetsAt: raw.weeklyResetsAt,
            opusPercentUsed: raw.opusPercentUsed,
            extraRateWindows: raw.extraRateWindows,
            extraUsageCost: raw.extraUsageCost,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
    }

    // MARK: - Account info

    private struct AccountInfo {
        let email: String?
        let organizationName: String?
        let loginMethod: String?
    }

    private static func fetchAccountInfo(
        orgId: String,
        tracker: SessionKeyTracker,
        session: URLSession) async -> AccountInfo?
    {
        let url = URL(string: "\(baseURL)/account")!
        let request = makeRequest(url: url, tracker: tracker)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            tracker.observe(response: http)
            return parseAccountInfo(data, orgId: orgId)
        } catch {
            return nil
        }
    }

    private struct AccountResponse: Decodable {
        let emailAddress: String?
        let memberships: [Membership]?

        enum CodingKeys: String, CodingKey {
            case emailAddress = "email_address"
            case memberships
        }

        struct Membership: Decodable {
            let organization: Org

            struct Org: Decodable {
                let uuid: String?
                let name: String?
                let rateLimitTier: String?
                let billingType: String?

                enum CodingKeys: String, CodingKey {
                    case uuid, name
                    case rateLimitTier = "rate_limit_tier"
                    case billingType = "billing_type"
                }
            }
        }
    }

    private static func parseAccountInfo(_ data: Data, orgId: String?) -> AccountInfo? {
        guard let decoded = try? JSONDecoder().decode(AccountResponse.self, from: data) else { return nil }
        let email = decoded.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pick membership matching orgId, fall back to first.
        let membership: AccountResponse.Membership?
        if let orgId, let match = decoded.memberships?.first(where: { $0.organization.uuid == orgId }) {
            membership = match
        } else {
            membership = decoded.memberships?.first
        }

        let orgName = membership?.organization.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = membership?.organization.rateLimitTier
        let billing = membership?.organization.billingType

        // Derive login method label from tier/billing hints (mirrors CodexBar's ClaudePlan.webLoginMethod).
        let loginMethod = ClaudePlanLabeler.label(subscriptionType: billing, rateLimitTier: tier)
            .map { "Claude \($0)" } ?? "Claude account"

        return AccountInfo(
            email: email?.isEmpty == false ? email : nil,
            organizationName: orgName?.isEmpty == false ? orgName : nil,
            loginMethod: loginMethod)
    }

    // MARK: - Overage spend limit (best-effort)

    private static func fetchOverageSpendLimit(
        orgId: String,
        tracker: SessionKeyTracker,
        session: URLSession) async -> ProviderCostSnapshot?
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/overage_spend_limit")!
        let request = makeRequest(url: url, tracker: tracker)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            tracker.observe(response: http)
            return parseOverageSpendLimit(data)
        } catch {
            return nil
        }
    }

    private struct OverageResponse: Decodable {
        let monthlyCreditLimit: Double?
        let currency: String?
        let usedCredits: Double?
        let isEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case monthlyCreditLimit = "monthly_credit_limit"
            case currency
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    private static func parseOverageSpendLimit(_ data: Data) -> ProviderCostSnapshot? {
        guard let decoded = try? JSONDecoder().decode(OverageResponse.self, from: data),
              decoded.isEnabled == true,
              let used = decoded.usedCredits,
              let limit = decoded.monthlyCreditLimit,
              let currency = decoded.currency,
              !currency.isEmpty
        else { return nil }

        // API returns values in cents; divide by 100 for display dollars.
        return ProviderCostSnapshot(
            used: used / 100.0,
            limit: limit / 100.0,
            currencyCode: currency,
            period: "Monthly cap",
            resetsAt: nil,
            updatedAt: Date())
    }

    // MARK: - extra_usage embedded in usage response

    private static func parseExtraUsageCost(_ value: Any?) -> ProviderCostSnapshot? {
        guard let dict = value as? [String: Any],
              let used = doubleValue(dict["used_credits"]),
              let limit = doubleValue(dict["monthly_limit"] ?? dict["monthly_credit_limit"]),
              limit > 0
        else { return nil }
        let currency = (dict["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderCostSnapshot(
            used: used / 100.0,
            limit: limit / 100.0,
            currencyCode: currency?.isEmpty == false ? currency! : "USD",
            period: "Monthly cap",
            resetsAt: nil,
            updatedAt: Date())
    }

    // MARK: - Shared helpers

    private static func makeRequest(url: URL, tracker: SessionKeyTracker) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(tracker.sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        return req
    }

    private static func percentValue(from value: Any?) -> Double? {
        switch value {
        case let i as Int: Double(i)
        case let d as Double: d
        default: nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let i as Int: Double(i)
        case let d as Double: d
        case let s as String: Double(s)
        default: nil
        }
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: string) { return date }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: string)
    }
}

// MARK: - SessionKeyTracker

/// Thread-safe tracker that picks up sessionKey rotations from Set-Cookie headers
/// during a single fetch session. Simple NSLock-based; no disk persistence.
private final class SessionKeyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionKey: String

    init(initial: String) {
        _sessionKey = initial
    }

    var sessionKey: String {
        lock.lock(); defer { lock.unlock() }
        return _sessionKey
    }

    /// Inspect response headers for a rotated sessionKey cookie.
    func observe(response: HTTPURLResponse) {
        guard response.statusCode == 200 else { return }
        if let renewed = Self.extractSessionKey(from: response.allHeaderFields) {
            lock.lock(); _sessionKey = renewed; lock.unlock()
        }
    }

    private static func extractSessionKey(from headers: [AnyHashable: Any]) -> String? {
        // allHeaderFields may expose Set-Cookie as a single string or an array.
        guard let raw = headers.first(where: {
            String(describing: $0.key).caseInsensitiveCompare("Set-Cookie") == .orderedSame
        })?.value else { return nil }

        let values: [String]
        if let arr = raw as? [String] {
            values = arr
        } else if let arr = raw as? [Any] {
            values = arr.map { String(describing: $0) }
        } else {
            values = [String(describing: raw)]
        }

        let pattern = #"(?i)(?:^|[,\r\n])\s*sessionKey=([^;,\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var latest: String?
        for header in values {
            let range = NSRange(header.startIndex..<header.endIndex, in: header)
            for match in regex.matches(in: header, range: range) {
                guard match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: header)
                else { continue }
                let value = String(header[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("sk-ant-") { latest = value }
            }
        }
        return latest
    }
}

// MARK: - ClaudeWebExtraRateWindowParser (ported from CodexBar — private helper)

private enum ClaudeWebExtraRateWindowParser {
    private static let definitions: [(id: String, title: String, keys: [String])] = [
        (
            id: "claude-routines",
            title: "Daily Routines",
            keys: [
                "seven_day_routines",
                "seven_day_claude_routines",
                "claude_routines",
                "routines",
                "routine",
                "seven_day_cowork",
                "cowork",
            ]
        ),
    ]

    static func parse(from json: [String: Any]) -> (windows: [NamedRateWindow], sourceKeys: [String: String]) {
        var windows: [NamedRateWindow] = []
        var sourceKeys: [String: String] = [:]
        windows.reserveCapacity(Self.definitions.count)

        for def in Self.definitions {
            if let found = firstUsageWindow(in: json, keys: def.keys) {
                let raw = found.window
                guard let utilization = percentValue(from: raw["utilization"]) else { continue }
                let resetsAt = (raw["resets_at"] as? String).flatMap(parseISO8601Date)
                windows.append(namedWindow(id: def.id, title: def.title, usedPercent: utilization, resetsAt: resetsAt))
                sourceKeys[def.id] = found.sourceKey
                continue
            }
            // Key present but null payload → preserve bar at 0% so the UI section stays visible.
            if let key = firstUsageKey(in: json, keys: def.keys) {
                windows.append(namedWindow(id: def.id, title: def.title, usedPercent: 0, resetsAt: nil))
                sourceKeys[def.id] = key
            }
        }
        windows.append(contentsOf: scopedWeeklyLimitWindows(from: json))
        return (windows, sourceKeys)
    }

    // MARK: Model-scoped weekly limits (`limits` array, ClaudeScopedWeeklyLimitMapper port)

    /// One decoded entry of the `limits` array:
    /// `{kind, group, percent, resets_at, scope: {model: {id, display_name}}}`.
    private struct WeeklyLimit {
        let percent: Double?
        let resetsAt: Date?
        let modelID: String?
        let modelName: String?
    }

    private static func weeklyLimits(from json: [String: Any]) -> [WeeklyLimit] {
        guard let limits = json["limits"] as? [[String: Any]] else { return [] }
        // `is_active` is intentionally not a filter: CodexBar observed
        // enforceable scoped limits that report false.
        return limits.compactMap { entry in
            guard (entry["group"] as? String) == "weekly",
                  (entry["kind"] as? String) == "weekly_scoped" else { return nil }
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            return WeeklyLimit(
                percent: percentValue(from: entry["percent"]),
                resetsAt: (entry["resets_at"] as? String).flatMap(parseISO8601Date),
                modelID: model?["id"] as? String,
                modelName: model?["display_name"] as? String)
        }
    }

    /// Per-model weekly bars ("Sonnet only", "Opus only", …). The account-wide
    /// "All models" entry is excluded here — it feeds the main weekly window.
    private static func scopedWeeklyLimitWindows(from json: [String: Any]) -> [NamedRateWindow] {
        var seenIDs: Set<String> = []
        return weeklyLimits(from: json).compactMap { limit in
            guard let percent = limit.percent, percent.isFinite,
                  let modelName = nonEmpty(limit.modelName),
                  !isAllModelsScope(modelID: limit.modelID, modelName: modelName)
            else { return nil }
            let idSlug = slug(nonEmpty(limit.modelID) ?? modelName)
            guard !idSlug.isEmpty, seenIDs.insert("claude-weekly-scoped-\(idSlug)").inserted else { return nil }
            return NamedRateWindow(
                id: "claude-weekly-scoped-\(idSlug)",
                title: "\(modelName) only",
                window: RateWindow(
                    usedPercent: percent,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: limit.resetsAt,
                    resetDescription: nil))
        }
    }

    /// The account-wide weekly entry, when present ("All models" scope or no
    /// model scope at all).
    static func allModelsWeeklyLimit(from json: [String: Any]) -> (percent: Double, resetsAt: Date?)? {
        for limit in weeklyLimits(from: json) {
            guard let percent = limit.percent, percent.isFinite else { continue }
            let name = nonEmpty(limit.modelName)
            if name == nil || isAllModelsScope(modelID: limit.modelID, modelName: name ?? "") {
                return (percent, limit.resetsAt)
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isAllModelsScope(modelID: String?, modelName: String) -> Bool {
        if slug(modelName) == "all-models" { return true }
        guard let modelID = nonEmpty(modelID) else { return false }
        let idSlug = slug(modelID)
        return idSlug == "all-models" || idSlug.hasSuffix("-all-models")
    }

    private static func namedWindow(id: String, title: String, usedPercent: Double, resetsAt: Date?) -> NamedRateWindow {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                resetDescription: nil))
    }

    private static func firstUsageWindow(
        in json: [String: Any],
        keys: [String]) -> (window: [String: Any], sourceKey: String)?
    {
        for key in keys {
            if let window = json[key] as? [String: Any] { return (window, key) }
        }
        return nil
    }

    private static func firstUsageKey(in json: [String: Any], keys: [String]) -> String? {
        keys.first { json.keys.contains($0) }
    }

    private static func percentValue(from value: Any?) -> Double? {
        switch value {
        case let i as Int: Double(i)
        case let d as Double: d
        default: nil
        }
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: string) { return date }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: string)
    }
}
