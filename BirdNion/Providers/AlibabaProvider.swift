import Foundation

// MARK: - AlibabaRegion

/// Alibaba Coding Plan region. Persisted in UserDefaults; the picker in ProvidersPane
/// binds the same key.
enum AlibabaRegion: String, CaseIterable, Identifiable {
    case international = "intl"
    case chinaMainland = "cn"

    static let defaultsKey = "alibabaRegion"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .international: "International (Singapore)"
        case .chinaMainland: "China Mainland (Beijing)"
        }
    }

    static var current: AlibabaRegion {
        AlibabaRegion(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "intl") ?? .international
    }

    var gatewayBase: String {
        switch self {
        case .international: "https://bailian-singapore-cs.alibabacloud.com"
        case .chinaMainland: "https://bailian-cs.console.aliyun.com"
        }
    }
    var consoleRPCAction: String {
        switch self {
        case .international: "IntlBroadScopeAspnGateway"
        case .chinaMainland: "BroadScopeAspnGateway"
        }
    }
    var consoleDomain: String {
        switch self {
        case .international: "modelstudio.console.alibabacloud.com"
        case .chinaMainland: "bailian.console.aliyun.com"
        }
    }
    var consoleSite: String {
        switch self {
        case .international: "MODELSTUDIO_ALIBABACLOUD"
        case .chinaMainland: "BAILIAN_ALIYUN"
        }
    }
    var commodityCode: String {
        switch self {
        case .international: "sfm_codingplan_public_intl"
        case .chinaMainland: "sfm_codingplan_public_cn"
        }
    }
    var currentRegionID: String {
        switch self {
        case .international: "ap-southeast-1"
        case .chinaMainland: "cn-beijing"
        }
    }
    var dashboardURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }
    }
    var consoleRefererURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model")!
        }
    }
    var rpcProduct: String { "sfm_bailian" }
    var rpcAPIName: String { "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2" }
    var cookieDomain: String {
        switch self {
        case .international: "alibabacloud.com"
        case .chinaMainland: "aliyun.com"
        }
    }
    var consoleRPCURL: URL {
        var c = URLComponents(string: gatewayBase)!
        c.path = "/data/api.json"
        c.queryItems = [
            URLQueryItem(name: "action", value: consoleRPCAction),
            URLQueryItem(name: "product", value: rpcProduct),
            URLQueryItem(name: "api", value: rpcAPIName),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return c.url!
    }
}

/// Alibaba (Qwen / Bailian) provider — fetches both Coding Plan and Token Plan quotas.
///
/// **Coding Plan** (region-aware via AlibabaRegion):
///   International: POST https://bailian-singapore-cs.alibabacloud.com/data/api.json
///   China: POST https://bailian-cs.console.aliyun.com/data/api.json
///   Produces windows: "5 giờ", "Tuần", "Tháng"
///
/// **Token Plan**:
///   POST https://bailian.console.aliyun.com/data/api.json
///     ?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=
///   Produces one window: "Token Plan"
///
/// sec_token resolution order (best-effort):
///   1. Cookie `sec_token`
///   2. Regex from dashboard HTML
///   3. GET /tool/user/info.json
final class AlibabaProvider: QuotaProvider {
    let id = "alibaba"
    let displayName = "Alibaba / Qwen"

    // MARK: - Token Plan constants

    private enum TokenPlanRegion {
        static let cookieDomain = "aliyun.com"
        static let gatewayBase = "https://bailian.console.aliyun.com"
        static let currentRegionID = "cn-beijing"
        static let bssService = "BssOpenAPI-V3"
        static let action = "GetSubscriptionSummary"
        static let productCode = "sfm_tokenplanteams_dp_cn"

        static var quotaURL: URL {
            var c = URLComponents(string: gatewayBase)!
            c.path = "/data/api.json"
            c.queryItems = [
                URLQueryItem(name: "action", value: action),
                URLQueryItem(name: "product", value: bssService),
                URLQueryItem(name: "_tag", value: ""),
            ]
            return c.url!
        }

        static var dashboardURL: URL {
            URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        }
    }

    private static let requestTimeout: TimeInterval = 20
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "alibaba"

        // Resolve cookies for both plans independently (best-effort).
        let codingCookie = ProviderCookieReader.resolvedCookieHeader(
            providerID: id, domain: AlibabaRegion.current.cookieDomain)
        let tokenCookie = ProviderCookieReader.resolvedCookieHeader(
            providerID: id, domain: TokenPlanRegion.cookieDomain)

        guard (codingCookie != nil && !(codingCookie!.isEmpty)) ||
              (tokenCookie != nil && !(tokenCookie!.isEmpty))
        else {
            return failure("Chưa đăng nhập Alibaba / Qwen trên trình duyệt")
        }

        var windows: [QuotaWindow] = []
        var lastError: String?

        // --- Coding Plan ---
        if let cookie = codingCookie, !cookie.isEmpty {
            do {
                let codingWindows = try await fetchCodingPlan(cookieHeader: cookie)
                windows.append(contentsOf: codingWindows)
            } catch {
                lastError = "Coding Plan: \(error.localizedDescription)"
            }
        }

        // --- Token Plan ---
        if let cookie = tokenCookie, !cookie.isEmpty {
            do {
                let tokenData = try await fetchTokenPlanData(cookieHeader: cookie)
                if let w = parseTokenPlanWindow(data: tokenData) {
                    windows.append(w)
                }
            } catch {
                if lastError == nil { lastError = "Token Plan: \(error.localizedDescription)" }
            }
        }

        if windows.isEmpty {
            return failure(lastError ?? "Không lấy được dữ liệu quota")
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            planName: nil)
    }

    // MARK: - Coding Plan

    private func fetchCodingPlan(cookieHeader: String) async throws -> [QuotaWindow] {
        let secToken = await resolveCodingPlanSECToken(cookieHeader: cookieHeader)
        let body = Self.codingPlanRequestBody(secToken: secToken)

        var req = URLRequest(url: AlibabaRegion.current.consoleRPCURL)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(AlibabaRegion.current.gatewayBase, forHTTPHeaderField: "Origin")
        req.setValue(AlibabaRegion.current.consoleRefererURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader)
            ?? Self.extractCookieValue(name: "csrf", from: cookieHeader)
        {
            req.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            req.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        return parseCodingPlanWindows(data: data)
    }

    /// Resolve sec_token for Coding Plan:
    /// 1. cookie sec_token
    /// 2. dashboard HTML regex
    /// 3. /tool/user/info.json
    private func resolveCodingPlanSECToken(cookieHeader: String) async -> String? {
        // 1. From cookie directly.
        if let t = Self.extractCookieValue(name: "sec_token", from: cookieHeader), !t.isEmpty {
            return t
        }

        // 2. From dashboard HTML.
        var dashReq = URLRequest(url: AlibabaRegion.current.dashboardURL)
        dashReq.httpMethod = "GET"
        dashReq.timeoutInterval = 10
        dashReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        dashReq.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        dashReq.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")

        if let (data, resp) = try? await session.data(for: dashReq),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let html = String(data: data, encoding: .utf8),
           let t = Self.extractSECTokenFromHTML(html), !t.isEmpty
        {
            return t
        }

        // 3. From /tool/user/info.json.
        let userInfoURL = URL(string: AlibabaRegion.current.gatewayBase)!
            .appendingPathComponent("tool/user/info.json")
        var infoReq = URLRequest(url: userInfoURL)
        infoReq.httpMethod = "GET"
        infoReq.timeoutInterval = 10
        infoReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        infoReq.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        infoReq.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        infoReq.setValue(AlibabaRegion.current.gatewayBase + "/", forHTTPHeaderField: "Referer")

        if let (data, resp) = try? await session.data(for: infoReq),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let raw = try? JSONSerialization.jsonObject(with: data, options: []),
           let t = Self.findFirstString(forKeys: ["secToken", "sec_token"], in: raw),
           !t.isEmpty
        {
            return t
        }

        return nil
    }

    private static func codingPlanRequestBody(secToken: String?) -> Data {
        let traceID = UUID().uuidString.lowercased()
        let cornerstoneParam: [String: Any] = [
            "feTraceId": traceID,
            "feURL": AlibabaRegion.current.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": AlibabaRegion.current.consoleDomain,
            "consoleSite": AlibabaRegion.current.consoleSite,
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US",
        ]
        let paramsObject: [String: Any] = [
            "Api": AlibabaRegion.current.rpcAPIName,
            "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": AlibabaRegion.current.commodityCode,
                    "onlyLatestOne": true,
                ],
                "cornerstoneParam": cornerstoneParam,
            ],
        ]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject, options: []),
              let paramsStr = String(data: paramsData, encoding: .utf8)
        else { return Data() }

        var c = URLComponents()
        var items = [
            URLQueryItem(name: "params", value: paramsStr),
            URLQueryItem(name: "region", value: AlibabaRegion.current.currentRegionID),
        ]
        if let t = secToken, !t.isEmpty {
            items.append(URLQueryItem(name: "sec_token", value: t))
        }
        c.queryItems = items
        return Data((c.percentEncodedQuery ?? "").utf8)
    }

    /// Parse coding plan response into windows "5 giờ", "Tuần", "Tháng".
    private func parseCodingPlanWindows(data: Data) -> [QuotaWindow] {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return [] }

        let expanded = Self.expandedJSON(raw)
        guard let dict = expanded as? [String: Any] else { return [] }

        // Find quota dict containing per5Hour/perWeek/perBillMonth keys.
        let quotaKeys = [
            "per5HourUsedQuota", "per5HourTotalQuota",
            "perWeekUsedQuota", "perWeekTotalQuota",
            "perBillMonthUsedQuota", "perBillMonthTotalQuota",
        ]
        guard let quota = Self.findFirstDictionary(matchingAnyKey: quotaKeys, in: dict) else { return [] }

        var windows: [QuotaWindow] = []

        // 5-hour window.
        if let total = Self.anyInt(forKeys: ["per5HourTotalQuota", "perFiveHourTotalQuota"], in: quota),
           total > 0
        {
            let used = Self.anyInt(forKeys: ["per5HourUsedQuota", "perFiveHourUsedQuota"], in: quota) ?? 0
            let usedPct = Int((Double(used) / Double(total) * 100).rounded()).clamped(to: 0...100)
            let resetDate = Self.anyDate(forKeys: ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], in: quota)
            windows.append(QuotaWindow(
                label: "5 giờ",
                usedPct: usedPct,
                remainingPct: 100 - usedPct,
                subtitle: "\(Self.fmt(Double(total - used))) / \(Self.fmt(Double(total))) requests còn lại",
                resetDate: resetDate,
                windowSeconds: 5 * 3600,
                allowance: QuotaAllowance(
                    used: Double(used), remaining: Double(total - used),
                    limit: Double(total), unit: .requests)))
        }

        // Weekly window.
        if let total = Self.anyInt(forKeys: ["perWeekTotalQuota"], in: quota), total > 0 {
            let used = Self.anyInt(forKeys: ["perWeekUsedQuota"], in: quota) ?? 0
            let usedPct = Int((Double(used) / Double(total) * 100).rounded()).clamped(to: 0...100)
            let resetDate = Self.anyDate(forKeys: ["perWeekQuotaNextRefreshTime"], in: quota)
            windows.append(QuotaWindow(
                label: "Tuần",
                usedPct: usedPct,
                remainingPct: 100 - usedPct,
                subtitle: "\(Self.fmt(Double(total - used))) / \(Self.fmt(Double(total))) requests còn lại",
                resetDate: resetDate,
                windowSeconds: 7 * 24 * 3600,
                allowance: QuotaAllowance(
                    used: Double(used), remaining: Double(total - used),
                    limit: Double(total), unit: .requests)))
        }

        // Monthly window.
        if let total = Self.anyInt(forKeys: ["perBillMonthTotalQuota", "perMonthTotalQuota"], in: quota), total > 0 {
            let used = Self.anyInt(forKeys: ["perBillMonthUsedQuota", "perMonthUsedQuota"], in: quota) ?? 0
            let usedPct = Int((Double(used) / Double(total) * 100).rounded()).clamped(to: 0...100)
            let resetDate = Self.anyDate(forKeys: ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], in: quota)
            windows.append(QuotaWindow(
                label: "Tháng",
                usedPct: usedPct,
                remainingPct: 100 - usedPct,
                subtitle: "\(Self.fmt(Double(total - used))) / \(Self.fmt(Double(total))) requests còn lại",
                resetDate: resetDate,
                windowSeconds: 30 * 24 * 3600,
                allowance: QuotaAllowance(
                    used: Double(used), remaining: Double(total - used),
                    limit: Double(total), unit: .requests)))
        }

        return windows
    }

    // MARK: - Token Plan

    private func fetchTokenPlanData(cookieHeader: String) async throws -> Data {
        // Try to resolve sec_token from cookie (Token Plan uses aliyun.com cookies).
        let secToken = Self.extractCookieValue(name: "sec_token", from: cookieHeader)

        let body = Self.tokenPlanRequestBody(secToken: secToken)
        var req = URLRequest(url: TokenPlanRegion.quotaURL)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(TokenPlanRegion.gatewayBase, forHTTPHeaderField: "Origin")
        req.setValue(TokenPlanRegion.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader)
            ?? Self.extractCookieValue(name: "csrf", from: cookieHeader)
        {
            req.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            req.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private static func tokenPlanRequestBody(secToken: String?) -> Data {
        let params = try? JSONSerialization.data(
            withJSONObject: ["ProductCode": TokenPlanRegion.productCode], options: [])
        let paramsStr = params.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var c = URLComponents()
        var items = [
            URLQueryItem(name: "product", value: TokenPlanRegion.bssService),
            URLQueryItem(name: "action", value: TokenPlanRegion.action),
            URLQueryItem(name: "params", value: paramsStr),
            URLQueryItem(name: "region", value: TokenPlanRegion.currentRegionID),
        ]
        if let t = secToken, !t.isEmpty {
            items.append(URLQueryItem(name: "sec_token", value: t))
        }
        c.queryItems = items
        return Data((c.percentEncodedQuery ?? "").utf8)
    }

    private func parseTokenPlanWindow(data: Data) -> QuotaWindow? {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }

        if let text = String(data: data, encoding: .utf8)?.lowercased(),
           text.contains("<html") { return nil }

        let dict = (raw as? [String: Any]) ?? [:]
        let summary = Self.findSummary(in: dict) ?? dict

        let total = Self.anyDouble(forKeys: Self.totalQuotaKeys, in: summary)
        let remaining = Self.anyDouble(forKeys: Self.remainingQuotaKeys, in: summary)
        let usedRaw = Self.anyDouble(forKeys: Self.usedQuotaKeys, in: summary)
        let used: Double? = usedRaw ?? total.flatMap { t in remaining.map { max(0, t - $0) } }
        let resetsAt = Self.anyDate(forKeys: Self.resetDateKeys, in: summary)

        guard let total, total > 0, let used else { return nil }

        let usedPct = Int((used / total * 100).rounded()).clamped(to: 0...100)
        let rem = remaining ?? max(0, total - used)

        return QuotaWindow(
            label: "Token Plan",
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: "\(Self.fmt(rem)) / \(Self.fmt(total)) credits còn lại",
            resetDate: resetsAt,
            windowSeconds: 30 * 24 * 3600,
            allowance: QuotaAllowance(
                used: used, remaining: rem, limit: total, unit: .credits))
    }

    // MARK: - Helpers

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - Static parsing helpers (Token Plan field keys)

    private static let usedQuotaKeys = [
        "usedQuota", "used_quota", "usedCredits", "usage", "used",
        "consumeAmount", "UsedValue", "ConsumedValue",
    ]
    private static let totalQuotaKeys = [
        "totalQuota", "total_quota", "totalCredits", "quota", "amount",
        "TotalValue", "monthlyTotalQuota",
    ]
    private static let remainingQuotaKeys = [
        "remainingQuota", "remainQuota", "remainingCredits", "balance",
        "TotalSurplusValue", "SurplusValue",
    ]
    private static let resetDateKeys = [
        "nextRefreshTime", "resetTime", "periodEndTime", "billCycleEndTime",
        "expireTime", "endTime", "NearestExpireDate",
    ]

    private static func findSummary(in value: Any) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in ["Data", "data", "successResponse", "success_response"] {
            if let nested = dict[key] as? [String: Any],
               (totalQuotaKeys + usedQuotaKeys + remainingQuotaKeys).contains(where: { nested[$0] != nil })
            {
                return nested
            }
        }
        for v in dict.values {
            if let nested = findSummary(in: v) { return nested }
        }
        return nil
    }

    private static func anyDouble(forKeys keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let v = parseDouble(dict[key]) { return v }
        }
        return nil
    }

    private static func anyInt(forKeys keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys {
            if let v = dict[key] {
                if let i = v as? Int { return i }
                if let d = parseDouble(v) { return Int(d) }
            }
        }
        return nil
    }

    private static func anyDate(forKeys keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys {
            if let d = parseDate(dict[key]) { return d }
        }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        switch raw {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int: return Double(n)
        case let n as NSNumber: let d = n.doubleValue; return d.isFinite ? d : nil
        case let s as String:
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                           .replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        default: return nil
        }
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let n = parseDouble(raw) {
            if n > 1_000_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
            if n > 1_000_000_000 { return Date(timeIntervalSince1970: n) }
        }
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoFmt = ISO8601DateFormatter()
        if let d = isoFmt.date(from: trimmed) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    private static func extractCookieValue(name: String, from header: String) -> String? {
        header.split(separator: ";").compactMap { chunk -> (String, String)? in
            let t = chunk.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            return (String(t[..<eq]).trimmingCharacters(in: .whitespaces),
                    String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }.first { $0.0 == name }?.1
    }

    private static func fmt(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = value.rounded() == value ? 0 : 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    // MARK: - JSON deep-search helpers

    private static func findFirstDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        for key in keys {
            if let nested = dict[key] as? [String: Any] { return nested }
        }
        for v in dict.values {
            if let nested = findFirstDictionary(forKeys: keys, in: v) { return nested }
        }
        return nil
    }

    private static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for v in dict.values {
                if let nested = findFirstDictionary(matchingAnyKey: keys, in: v) { return nested }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let nested = findFirstDictionary(matchingAnyKey: keys, in: item) { return nested }
            }
        }
        return nil
    }

    private static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let s = dict[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            for v in dict.values {
                if let found = findFirstString(forKeys: keys, in: v) { return found }
            }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let found = findFirstString(forKeys: keys, in: item) { return found }
            }
        }
        return nil
    }

    private static func expandedJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { expandedJSON($0) }
        }
        if let arr = value as? [Any] {
            return arr.map { expandedJSON($0) }
        }
        if let s = value as? String,
           let data = s.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data, options: []),
           nested is [String: Any] || nested is [Any]
        {
            return expandedJSON(nested)
        }
        return value
    }

    // MARK: - SEC token extraction from HTML

    private static func extractSECTokenFromHTML(_ html: String) -> String? {
        let patterns = [
            #"SEC_TOKEN\s*:\s*\"([^\"]+)\""#,
            #"SEC_TOKEN\s*:\s*'([^']+)'"#,
            #"secToken\s*:\s*\"([^\"]+)\""#,
            #"sec_token\s*:\s*\"([^\"]+)\""#,
            #"sec_token\s*:\s*'([^']+)'"#,
            #"\"SEC_TOKEN\"\s*:\s*\"([^\"]+)\""#,
            #"\"sec_token\"\s*:\s*\"([^\"]+)\""#,
            #""secToken"\s*:\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            if let token = matchFirstGroup(pattern: pattern, in: html), !token.isEmpty { return token }
        }
        return nil
    }

    private static func matchFirstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let vr = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = text[vr].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
