import Foundation

/// DeepSeek balance provider.
///
/// Endpoint: `GET https://api.deepseek.com/user/balance`
/// Auth: `Authorization: Bearer <key>` (key prefix `sk-...`).
///
/// Response envelope:
/// ```json
/// { "is_available": true,
///   "balance_infos": [ { "currency": "USD", "total_balance": "12.34", ... } ] }
/// ```
/// DeepSeek is a prepaid balance, not a rate-limited quota — there is no
/// percentage to show. We surface the balance as `creditsRemaining` and a
/// subtitle window; the menu-bar chip stays blank (no %).
final class DeepSeekProvider: QuotaProvider {
    let id = "deepseek"
    let displayName = "DeepSeek"

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    // Usage-history enrichment (matches upstream CodexBar): the same API key is
    // accepted on the platform host for per-month token/cost summaries.
    static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    func fetch() async throws -> ProviderStatus {
        // Env override first (DEEPSEEK_API_KEY), then config storage.
        let envToken = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (envToken?.isEmpty == false ? envToken : nil) ?? BirdNionConfigStore.apiKey(provider: id)
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình token")
        }
        let accountLabel = override() ?? String(token.prefix(8))

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        // Optional usage-history enrichment: fires in parallel with the balance
        // call and joins within a short grace so the slower platform host can
        // neither delay nor fail the balance row (upstream optionalSummaryJoinGrace).
        let summaryTask = Task { try await Self.fetchUsageSummary(session: session, apiKey: token) }
        defer { summaryTask.cancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return failure("Response không phải HTTP") }
        guard (200..<300).contains(http.statusCode) else { return failure("HTTP \(http.statusCode)") }
        var status = parse(data, accountLabel: accountLabel)
        if status.error == nil,
           let summary = await Self.boundedJoin(summaryTask, grace: .seconds(2)) {
            status = parse(data, accountLabel: accountLabel, summary: summary)
        }
        return status
    }

    func parse(_ data: Data, accountLabel: String, summary: UsageSummary? = nil) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(BalanceResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        // Prefer the USD-funded entry when multiple currencies are present.
        guard let info = root.balanceInfos.first(where: { $0.currency == "USD" }) ?? root.balanceInfos.first else {
            return failure("Không có thông tin số dư")
        }
        let amount = Double(info.totalBalance) ?? 0
        let symbol = info.currency == "CNY" ? "¥" : "$"
        // Balance-only provider: a single full-width window carries the figure
        // as a subtitle. When the balance runs out we flag it red (usedPct=100).
        let lowBalance = amount <= 0
        let subtitle: String
        if lowBalance {
            subtitle = "Hết số dư — cần nạp thêm"
        } else if let toppedUp = info.toppedUpBalance, let granted = info.grantedBalance {
            subtitle = "\(symbol)\(info.totalBalance) · Trả: \(symbol)\(toppedUp) · Tặng: \(symbol)\(granted)"
        } else {
            subtitle = "\(symbol)\(info.totalBalance)"
        }
        let window = QuotaWindow(
            label: "Số dư",
            usedPct: lowBalance ? 100 : 0,
            remainingPct: lowBalance ? 0 : 100,
            subtitle: subtitle)
        var windows = [window]
        if let summary {
            windows += Self.usageWindows(summary)
        }
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: amount)
    }

    /// Usage-history rows rendered under the balance window. `isSupplementary`
    /// keeps them out of the menu-bar headline — they carry no quota pressure.
    private static func usageWindows(_ s: UsageSummary) -> [QuotaWindow] {
        let symbol = s.currency == "CNY" ? "¥" : "$"
        var windows: [QuotaWindow] = []
        var todayParts = ["\(formatTokens(s.todayTokens)) tokens"]
        if let cost = s.todayCost { todayParts.append(String(format: "%@%.2f", symbol, cost)) }
        if s.todayRequests > 0 { todayParts.append("\(s.todayRequests) req") }
        windows.append(QuotaWindow(
            label: "Hôm nay", usedPct: 0, remainingPct: 100,
            subtitle: todayParts.joined(separator: " · "), isSupplementary: true))
        var monthParts = ["\(formatTokens(s.monthTokens)) tokens"]
        if let cost = s.monthCost { monthParts.append(String(format: "%@%.2f", symbol, cost)) }
        if s.monthRequests > 0 { monthParts.append("\(s.monthRequests) req") }
        if let top = s.topModel { monthParts.append(top) }
        windows.append(QuotaWindow(
            label: "Tháng này", usedPct: 0, remainingPct: 100,
            subtitle: monthParts.joined(separator: " · "), isSupplementary: true))
        return windows
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - Usage-history enrichment (platform.deepseek.com)

    /// Calendar for the billing-month parameter — upstream pins UTC so the
    /// month boundary matches DeepSeek's accounting.
    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    static func fetchUsageSummary(session: URLSession, apiKey: String,
                                  now: Date = Date()) async throws -> UsageSummary {
        let calendar = apiCalendar
        let components = calendar.dateComponents([.month, .year], from: now)
        guard let month = components.month, let year = components.year else {
            throw SummaryError.parse
        }
        async let amountData = usageData(session: session, url: usageAmountURL,
                                         apiKey: apiKey, month: month, year: year)
        async let costData = usageData(session: session, url: usageCostURL,
                                       apiKey: apiKey, month: month, year: year)
        return try UsageSummary.parse(amountData: try await amountData,
                                      costData: try await costData,
                                      now: now, calendar: calendar)
    }

    private static func usageData(session: URLSession, url: URL, apiKey: String,
                                  month: Int, year: Int) async throws -> Data {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SummaryError.parse
        }
        comp.queryItems = [
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "year", value: "\(year)"),
        ]
        guard let url = comp.url else { throw SummaryError.parse }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SummaryError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// Awaits `task` up to `grace`; nil on timeout or failure. Mirrors upstream
    /// `completedOptionalUsageSummary` — the balance row must never stall or
    /// error out because the optional summary is slow/broken.
    private static func boundedJoin<T>(_ task: Task<T, Error>, grace: Duration) async -> T? {
        let winner = await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await task.value }
            group.addTask {
                try? await Task.sleep(for: grace)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next()
        }
        task.cancel()
        return winner ?? nil
    }

    /// Aggregated usage for the current billing month + today, trimmed from
    /// upstream's `DeepSeekUsageSummary` to the fields BirdNion renders.
    struct UsageSummary: Equatable {
        let todayTokens: Int
        let monthTokens: Int
        let todayCost: Double?
        let monthCost: Double?
        let todayRequests: Int
        let monthRequests: Int
        let topModel: String?
        let currency: String

        /// Categories summed as token usage; `REQUEST` counts separately.
        /// Mirrors upstream's DeepSeekUsageCategory.
        private static let requestType = "REQUEST"
        private static let tokenTypes: Set<String> =
            ["PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN"]

        static func parse(amountData: Data, costData: Data,
                          now: Date, calendar: Calendar) throws -> UsageSummary {
            let amount = try JSONDecoder().decode(AmountPayload.self, from: amountData)
            let cost = try JSONDecoder().decode(CostPayload.self, from: costData)
            if let code = amount.code, code != 0 { throw SummaryError.api(code) }
            if let code = cost.code, code != 0 { throw SummaryError.api(code) }
            if let biz = amount.data?.bizCode, biz != 0 { throw SummaryError.api(biz) }
            if let biz = cost.data?.bizCode, biz != 0 { throw SummaryError.api(biz) }
            guard let amountBiz = amount.data?.bizData else { throw SummaryError.parse }

            let currency = cost.data?.bizData?.first?.currency ?? "CNY"
            let todayString = dayString(now, calendar: calendar)
            var comps = calendar.dateComponents([.year, .month], from: now)
            comps.day = 1
            let startOfMonth = calendar.date(from: comps) ?? now

            var todayTokens = 0, todayRequests = 0
            var todayCost: Double?
            var monthTokens = 0, monthRequests = 0
            var monthCost: Double?

            // Per-day amounts: date → [token sum, request count]
            var amountDays: [String: (tokens: Int, requests: Int)] = [:]
            for day in amountBiz.days ?? [] {
                guard let date = day.date else { continue }
                var tokens = 0, requests = 0
                for model in day.data ?? [] {
                    for item in model.usage ?? [] {
                        let type = (item.type ?? "").uppercased()
                        if type == requestType {
                            requests += intAmount(item.amount)
                        } else if tokenTypes.contains(type) {
                            tokens += intAmount(item.amount)
                        }
                    }
                }
                amountDays[date] = (tokens, requests)
            }
            var costDays: [String: Double] = [:]
            for day in cost.data?.bizData?.first?.days ?? [] {
                guard let date = day.date else { continue }
                var dayCost = 0.0
                for model in day.data ?? [] {
                    for item in model.usage ?? [] {
                        if tokenTypes.contains((item.type ?? "").uppercased()) {
                            dayCost += doubleAmount(item.amount)
                        }
                    }
                }
                costDays[date] = dayCost
            }

            for (date, amounts) in amountDays {
                if date == todayString {
                    todayTokens = amounts.tokens
                    todayRequests = amounts.requests
                }
                guard let parsed = parseDay(date, calendar: calendar),
                      parsed >= startOfMonth, parsed <= now else { continue }
                monthTokens += amounts.tokens
                monthRequests += amounts.requests
            }
            for (date, dayCost) in costDays {
                if date == todayString { todayCost = (todayCost ?? 0) + dayCost }
                guard let parsed = parseDay(date, calendar: calendar),
                      parsed >= startOfMonth, parsed <= now else { continue }
                monthCost = (monthCost ?? 0) + dayCost
            }

            // Top model from the month-total amounts (upstream buildBreakdowns).
            var modelTokens: [String: Int] = [:]
            for model in amountBiz.total ?? [] {
                guard let name = model.model else { continue }
                var total = 0
                for item in model.usage ?? [] {
                    if tokenTypes.contains((item.type ?? "").uppercased()) {
                        total += intAmount(item.amount)
                    }
                }
                if total > 0 { modelTokens[name] = total }
            }
            let topModel = modelTokens.max {
                $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
            }?.key

            return UsageSummary(
                todayTokens: todayTokens, monthTokens: monthTokens,
                todayCost: todayCost, monthCost: monthCost,
                todayRequests: todayRequests, monthRequests: monthRequests,
                topModel: topModel, currency: currency)
        }

        private static func intAmount(_ value: String?) -> Int {
            guard let value else { return 0 }
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        private static func doubleAmount(_ value: String?) -> Double {
            guard let value else { return 0 }
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        private static func dayString(_ date: Date, calendar: Calendar) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = c.year, let m = c.month, let d = c.day else { return "" }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        private static func parseDay(_ text: String, calendar: Calendar) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: text)
        }

        // Response envelopes (platform.deepseek.com wraps payload in
        // code/data.biz_code/data.biz_data — all fields optional, tolerant decode).
        private struct AmountPayload: Decodable {
            let code: Int?
            let data: AmountData?
        }
        private struct AmountData: Decodable {
            let bizCode: Int?
            let bizData: AmountBizData?
            enum CodingKeys: String, CodingKey {
                case bizCode = "biz_code"; case bizData = "biz_data"
            }
        }
        private struct AmountBizData: Decodable {
            let total: [ModelUsage]?
            let days: [DayUsage]?
        }
        private struct CostPayload: Decodable {
            let code: Int?
            let data: CostData?
        }
        private struct CostData: Decodable {
            let bizCode: Int?
            let bizData: [CostBizData]?
            enum CodingKeys: String, CodingKey {
                case bizCode = "biz_code"; case bizData = "biz_data"
            }
        }
        private struct CostBizData: Decodable {
            let total: [CostModelUsage]?
            let days: [CostDayUsage]?
            let currency: String?
        }
        private struct ModelUsage: Decodable {
            let model: String?
            let usage: [UsageItem]?
        }
        private struct DayUsage: Decodable {
            let date: String?
            let data: [ModelUsage]?
        }
        private struct UsageItem: Decodable {
            let type: String?
            let amount: String?
        }
        private struct CostModelUsage: Decodable {
            let model: String?
            let usage: [UsageItem]?
        }
        private struct CostDayUsage: Decodable {
            let date: String?
            let data: [CostModelUsage]?
        }
    }

    private enum SummaryError: Error {
        case http(Int), api(Int), parse
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    private struct BalanceResponse: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]
        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }
    private struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String?
        let toppedUpBalance: String?
        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }
}
