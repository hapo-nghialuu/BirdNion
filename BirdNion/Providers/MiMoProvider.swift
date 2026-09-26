import Foundation

/// Xiaomi MiMo quota provider.
///
/// Authenticates via browser session cookies scraped automatically from the user's browser.
/// Required cookies: `api-platform_serviceToken` + `userId` (set by platform.xiaomimimo.com).
///
/// Endpoints (all GET, base: https://platform.xiaomimimo.com/api/v1):
///   /balance         — cash/gift balance
///   /tokenPlan/detail — current plan code + period end
///   /tokenPlan/usage  — monthly token used / limit / percent
///
/// Balance response shape:
/// ```json
/// { "code": 0, "data": { "balance": "12.50", "currency": "CNY",
///                         "cashBalance": "10.00", "giftBalance": "2.50" } }
/// ```
///
/// TokenPlan detail shape:
/// ```json
/// { "code": 0, "data": { "planCode": "pro", "currentPeriodEnd": "2025-08-01 00:00:00",
///                         "expired": false } }
/// ```
///
/// TokenPlan usage shape:
/// ```json
/// { "code": 0, "data": { "monthUsage": {
///     "percent": 0.45,
///     "items": [ { "name": "...", "used": 450000, "limit": 1000000, "percent": 0.45 } ]
/// } } }
/// ```
final class MiMoProvider: QuotaProvider {
    let id = "mimo"
    let displayName = "Xiaomi MiMo"

    // Domains the session cookies belong to.
    static let cookieDomain = "platform.xiaomimimo.com"
    static let cookieDomainFallback = "xiaomimimo.com"

    private static let apiBase = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    private static let requestTimeout: TimeInterval = 15
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// Required cookie names that must both be present for a valid session.
    private static let requiredCookies: Set<String> = [
        "api-platform_serviceToken",
        "userId",
    ]
    /// Additional known cookies included in the header when present.
    private static let optionalCookies: Set<String> = [
        "api-platform_ph",
        "api-platform_slh",
    ]
    private static var knownCookies: Set<String> { requiredCookies.union(optionalCookies) }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        // MiMo splits its session across two hosts: `api-platform_serviceToken`
        // lives on `platform.xiaomimimo.com` while `userId` lives on the apex
        // `.xiaomimimo.com`. Merge BOTH domains' cookies — querying only the
        // sub-domain misses `userId` and the session looks "not found".
        var accessIssue: ProviderCookieReader.AccessIssue?
        let headers = [
            ProviderCookieReader.resolvedCookieHeader(
                providerID: id, domain: Self.cookieDomain,
                accessIssue: &accessIssue),
            ProviderCookieReader.resolvedCookieHeader(
                providerID: id, domain: Self.cookieDomainFallback,
                accessIssue: &accessIssue),
        ].compactMap { $0 }.filter { !$0.isEmpty }
        let rawHeader = headers.joined(separator: "; ")

        guard !rawHeader.isEmpty else {
            return failure(accessIssue?.message ?? "Chưa đăng nhập MiMo trên trình duyệt")
        }

        // Validate and filter to only MiMo-relevant cookies.
        guard let cookieHeader = Self.normalizedCookieHeader(from: rawHeader) else {
            return failure("Không tìm thấy session cookie của MiMo (cần api-platform_serviceToken + userId)")
        }

        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "mimo"

        // Fetch balance (required) and plan detail + usage (optional) concurrently.
        async let balanceTask = fetchEndpoint(path: "balance", cookieHeader: cookieHeader)
        async let detailTask = fetchEndpointOptional(path: "tokenPlan/detail", cookieHeader: cookieHeader)
        async let usageTask = fetchEndpointOptional(path: "tokenPlan/usage", cookieHeader: cookieHeader)

        let balanceData: Data
        do {
            balanceData = try await balanceTask
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }

        let detailData = await detailTask
        let usageData = await usageTask

        return parse(
            balanceData: balanceData,
            detailData: detailData,
            usageData: usageData,
            accountLabel: accountLabel)
    }

    // MARK: - Parse (internal for testing)

    /// Exposed for unit tests — no network I/O.
    static func _parseForTesting(
        balanceData: Data,
        detailData: Data?,
        usageData: Data?
    ) -> ProviderStatus {
        let provider = MiMoProvider()
        return provider.parse(
            balanceData: balanceData,
            detailData: detailData,
            usageData: usageData,
            accountLabel: "test")
    }

    // MARK: - Private parsing

    private func parse(
        balanceData: Data,
        detailData: Data?,
        usageData: Data?,
        accountLabel: String
    ) -> ProviderStatus {
        // --- balance ---
        guard let balResult = Self.parseBalance(from: balanceData) else {
            return failure("Không thể đọc dữ liệu số dư MiMo")
        }

        // --- plan detail (optional) ---
        let planDetail = detailData.flatMap { Self.parsePlanDetail(from: $0) }

        // --- token usage (optional) ---
        let tokenUsage = usageData.flatMap { Self.parseTokenUsage(from: $0) }

        var windows: [QuotaWindow] = []

        // Balance window — always present when fetch succeeds.
        let currencySymbol = balResult.currency == "CNY" ? "¥" : "$"
        var balSubtitle = "\(currencySymbol)\(String(format: "%.2f", balResult.balance))"
        if let cash = balResult.cashBalance, let gift = balResult.giftBalance {
            balSubtitle += " (Trả: \(currencySymbol)\(String(format: "%.2f", cash)) / Tặng: \(currencySymbol)\(String(format: "%.2f", gift)))"
        }
        windows.append(QuotaWindow(
            label: "Số dư",
            usedPct: 0,
            remainingPct: 100,
            subtitle: balSubtitle))

        // Token plan window — present when both detail and usage are available.
        if let usage = tokenUsage, usage.limit > 0 {
            let usedPct = Int((usage.percent * 100).rounded()).clamped(to: 0...100)
            let remainingPct = 100 - usedPct
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let usedStr = formatter.string(from: NSNumber(value: usage.used)) ?? "\(usage.used)"
            let limitStr = formatter.string(from: NSNumber(value: usage.limit)) ?? "\(usage.limit)"
            let subtitle = "\(usedStr) / \(limitStr) tokens"

            windows.append(QuotaWindow(
                label: "Token Plan",
                usedPct: usedPct,
                remainingPct: remainingPct,
                subtitle: subtitle,
                resetDate: planDetail?.periodEnd,
                windowSeconds: 30 * 24 * 3600))
        }

        let planName = planDetail?.planCode.map { $0.capitalized }

        // Cost snapshot — balance as "used" relative to itself (informational only).
        let cost = ProviderCostSnapshot(
            used: balResult.balance,
            limit: balResult.balance,
            currencyCode: balResult.currency,
            period: "Balance",
            resetsAt: planDetail?.periodEnd,
            updatedAt: Date())

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            planName: planName,
            cost: cost)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - Networking helpers

    private func fetchEndpoint(path: String, cookieHeader: String) async throws -> Data {
        let url = Self.apiBase.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("UTC+07:00", forHTTPHeaderField: "x-timeZone")
        req.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        req.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            return data
        case 300..<400:
            throw URLError(.userAuthenticationRequired)
        case 401, 403:
            throw URLError(.userAuthenticationRequired)
        default:
            throw URLError(.badServerResponse)
        }
    }

    private func fetchEndpointOptional(path: String, cookieHeader: String) async -> Data? {
        try? await fetchEndpoint(path: path, cookieHeader: cookieHeader)
    }

    // MARK: - JSON parsing helpers

    private struct BalanceResult {
        let balance: Double
        let currency: String
        let cashBalance: Double?
        let giftBalance: Double?
    }

    private static func parseBalance(from data: Data) -> BalanceResult? {
        struct Response: Decodable {
            let code: Int
            let data: Payload?
            struct Payload: Decodable {
                let balance: String
                let currency: String
                let cashBalance: String?
                let giftBalance: String?
            }
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              r.code == 0,
              let payload = r.data,
              let balance = Double(payload.balance),
              !payload.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return BalanceResult(
            balance: balance,
            currency: payload.currency.trimmingCharacters(in: .whitespacesAndNewlines),
            cashBalance: payload.cashBalance.flatMap(Double.init),
            giftBalance: payload.giftBalance.flatMap(Double.init))
    }

    private struct PlanDetailResult {
        let planCode: String?
        let periodEnd: Date?
        let expired: Bool
    }

    private static func parsePlanDetail(from data: Data) -> PlanDetailResult? {
        struct Response: Decodable {
            let code: Int
            let data: Payload?
            struct Payload: Decodable {
                let planCode: String?
                let currentPeriodEnd: String?
                let expired: Bool
            }
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              r.code == 0,
              let payload = r.data
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let periodEnd = payload.currentPeriodEnd.flatMap { formatter.date(from: $0) }

        return PlanDetailResult(
            planCode: payload.planCode,
            periodEnd: periodEnd,
            expired: payload.expired)
    }

    private struct TokenUsageResult {
        let used: Int
        let limit: Int
        let percent: Double
    }

    private static func parseTokenUsage(from data: Data) -> TokenUsageResult? {
        struct Response: Decodable {
            let code: Int
            let data: Payload?
            struct Payload: Decodable {
                let monthUsage: MonthUsage?
                struct MonthUsage: Decodable {
                    let percent: Double
                    let items: [Item]
                    struct Item: Decodable {
                        let used: Int
                        let limit: Int
                        let percent: Double
                    }
                }
            }
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              r.code == 0,
              let monthUsage = r.data?.monthUsage,
              let item = monthUsage.items.first
        else { return nil }

        return TokenUsageResult(used: item.used, limit: item.limit, percent: item.percent)
    }

    // MARK: - Cookie header normalization

    /// Filters the raw scraped cookie header to only include MiMo-relevant cookies.
    /// Returns nil if the two required cookies are not present.
    static func normalizedCookieHeader(from raw: String) -> String? {
        var byName: [String: String] = [:]
        for chunk in raw.split(separator: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty, knownCookies.contains(name) else { continue }
            byName[name] = value
        }
        guard requiredCookies.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let value = byName[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }
}

// MARK: - Comparable clamping helper (avoids importing stdlib extras)

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
