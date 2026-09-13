import Foundation

/// CommandCode quota provider.
///
/// Authenticates via the better-auth session cookie set by commandcode.ai.
/// Cookie is scraped automatically from the user's browser via ProviderCookieReader.
///
/// Endpoints:
///   GET https://api.commandcode.ai/internal/billing/credits
///   GET https://api.commandcode.ai/internal/billing/subscriptions
///
/// Credits response shape:
/// ```json
/// { "credits": {
///     "monthlyCredits": 25.0,
///     "purchasedCredits": 0.0,
///     "premiumMonthlyCredits": 0.0,
///     "opensourceMonthlyCredits": 0.0
///   }
/// }
/// ```
///
/// Subscriptions response shape:
/// ```json
/// { "success": true, "data": { "planId": "individual-pro", "status": "active",
///                               "currentPeriodEnd": "2025-08-01T00:00:00.000Z" } }
/// ```
/// `data` is null for the free tier.
final class CommandCodeProvider: QuotaProvider {
    let id = "commandcode"
    let displayName = "Command Code"

    // Cookie domain that better-auth sets the session cookie for.
    static let cookieDomain = "commandcode.ai"

    /// Cookie names emitted by better-auth (HTTPS production and dev).
    /// Ported from CommandCodeCookieHeader.supportedSessionCookieNames.
    private static let supportedSessionCookieNames = [
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]

    private static let apiBase = URL(string: "https://api.commandcode.ai")!
    private static let creditsPath = "/internal/billing/credits"
    private static let subscriptionsPath = "/internal/billing/subscriptions"
    private static let webOrigin = "https://commandcode.ai"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let requestTimeout: TimeInterval = 15

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - QuotaProvider

    func fetch() async throws -> ProviderStatus {
        guard let rawHeader = ProviderCookieReader.resolvedCookieHeader(providerID: id, domain: Self.cookieDomain),
              !rawHeader.isEmpty
        else {
            return failure("Chưa đăng nhập CommandCode trên trình duyệt")
        }

        guard let cookieHeader = Self.filteredCookieHeader(from: rawHeader) else {
            return failure("Không tìm thấy cookie đăng nhập Command Code")
        }

        let accountLabel = BirdNionConfigStore.accountLabel(provider: id) ?? "commandcode"

        // Fetch credits (required) + subscriptions (optional enrichment) concurrently.
        async let creditsData = fetchEndpoint(path: Self.creditsPath, cookieHeader: cookieHeader)
        async let subData = fetchEndpointOptional(path: Self.subscriptionsPath, cookieHeader: cookieHeader)

        let credits: Data
        do {
            credits = try await creditsData
        } catch {
            return failure("Network: \(error.localizedDescription)")
        }

        let subscriptionData = await subData

        return parse(
            creditsData: credits,
            subscriptionData: subscriptionData,
            accountLabel: accountLabel)
    }

    // MARK: - Parsing (internal for testing)

    /// Parse credits + optional subscription data into a ProviderStatus.
    /// Exposed as `static` so unit tests can call it without network I/O.
    static func _parseForTesting(creditsData: Data, subscriptionData: Data?) -> ProviderStatus {
        let provider = CommandCodeProvider()
        return provider.parse(
            creditsData: creditsData,
            subscriptionData: subscriptionData,
            accountLabel: "test")
    }

    // MARK: - Private parsing

    private func parse(
        creditsData: Data,
        subscriptionData: Data?,
        accountLabel: String
    ) -> ProviderStatus {
        // --- credits ---
        guard let creditsRoot = try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any],
              let creditsObj = creditsRoot["credits"] as? [String: Any]
        else {
            return failure("Response thiếu trường credits")
        }
        guard let monthly = Self.double(from: creditsObj["monthlyCredits"]) else {
            return failure("Thiếu monthlyCredits")
        }
        let purchased = Self.double(from: creditsObj["purchasedCredits"]) ?? 0
        let premium = Self.double(from: creditsObj["premiumMonthlyCredits"]) ?? 0
        // The grant total ships in this very payload. The plan catalog only
        // fills in for responses that omit it — keying the denominator on a
        // hardcoded plan list means any plan the list has not heard of
        // (`individual-goat`, seen in production) silently loses its chart.
        let grantedTotal = Self.double(from: creditsObj["monthlyCreditsGranted"])
            .flatMap { $0 > 0 ? $0 : nil }

        // --- subscriptions (optional) ---
        var planName: String? = nil
        var monthlyTotal: Double? = nil
        var periodEnd: Date? = nil

        if let subData = subscriptionData,
           let subRoot = try? JSONSerialization.jsonObject(with: subData) as? [String: Any],
           let success = subRoot["success"] as? Bool, success,
           let dataValue = subRoot["data"],
           !(dataValue is NSNull),
           let dataDict = dataValue as? [String: Any],
           let planID = dataDict["planId"] as? String, !planID.isEmpty
        {
            // Match planID against catalog.
            if let plan = Self.plan(forID: planID) {
                planName = plan.displayName
                monthlyTotal = plan.monthlyCreditsUSD
            }
            let status = (dataDict["status"] as? String) ?? "unknown"
            if status.lowercased() == "active" {
                periodEnd = Self.parseDate(from: dataDict["currentPeriodEnd"])
            }
        }

        // --- windows vs balance ---
        //
        // A window carries a percentage, so one may only be built when the plan
        // total is known — that is the denominator. `/credits` reports the
        // REMAINING dollars and nothing else, so without a plan there is no
        // percentage to compute.
        //
        // Everything without a denominator is a balance, not a quota, and goes
        // to `creditsRemaining` (the popover's CREDITS row). Upstream publishes
        // these as a 100%-remaining window instead ("surface 100% so the bar
        // renders empty"), which paints a full green bar, a "used 0%" line and
        // a 100% headline over a number nobody measured — the balance was the
        // only real figure on screen. Deliberate divergence.
        var windows: [QuotaWindow] = []
        var spendableBalance: Double = 0

        // Rolling caps, when the account is subject to them. These are real
        // quotas with their own denominators, independent of the monthly grant.
        if let limits = creditsRoot["windowLimits"] as? [String: Any],
           (limits["limited"] as? Bool) != false
        {
            if let window = Self.windowLimitQuota(
                limits["fiveHour"], label: "5 giờ", windowSeconds: 5 * 3600)
            {
                windows.append(window)
            }
            if let window = Self.windowLimitQuota(
                limits["weekly"], label: "Tuần", windowSeconds: 7 * 24 * 3600)
            {
                windows.append(window)
            }
        }

        if let total = grantedTotal ?? monthlyTotal, total > 0 {
            let used = max(0, min(total, total - monthly))
            let usedPct = Int((used / total * 100).rounded())
            let remainingPct = 100 - usedPct
            let subtitle = "\(Self.usd(monthly)) / \(Self.usd(total))"
            windows.append(QuotaWindow(
                label: "Tháng",
                usedPct: usedPct,
                remainingPct: remainingPct,
                subtitle: subtitle,
                resetDate: periodEnd,
                windowSeconds: 30 * 24 * 3600))
        } else if monthly > 0 {
            spendableBalance += monthly
        }

        // Top-ups never have an allowance to divide by, so they are a balance
        // even when the monthly plan IS known.
        spendableBalance += max(0, purchased) + max(0, premium)

        if windows.isEmpty, spendableBalance <= 0 {
            return failure("Không có dữ liệu credits")
        }

        // Cost snapshot — used = spent this month, limit = plan total (if known).
        let cost: ProviderCostSnapshot? = (grantedTotal ?? monthlyTotal).map { total in
            let used = max(0, total - monthly)
            return ProviderCostSnapshot(
                used: used,
                limit: total,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: periodEnd,
                updatedAt: Date())
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: spendableBalance > 0 ? spendableBalance : nil,
            planName: planName,
            cost: cost)
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }

    // MARK: - Cookie filtering

    /// Build the `Cookie:` header for the API. CommandCode validates the whole
    /// cookie set (like CodexBar's SessionInfo.cookieHeader), so we forward ALL
    /// cookies — but only when a session cookie is present. The session name
    /// varies by deployment (better-auth default, or a custom
    /// `__Secure-commandcode_prod_.session_token` prefix), so we accept any
    /// cookie whose name contains "session_token".
    static func filteredCookieHeader(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bare token: no `=` sign — wrap under the production session name.
        if !trimmed.contains("=") {
            return "__Secure-commandcode_prod_.session_token=\(trimmed)"
        }

        // Keep ALL cookies, but only proceed when a session cookie is present.
        var pairs: [String] = []
        var hasSession = false
        for chunk in trimmed.split(separator: ";") {
            let t = chunk.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            pairs.append("\(name)=\(value)")
            let lower = name.lowercased()
            if lower.contains("session_token")
                || supportedSessionCookieNames.contains(where: { $0.lowercased() == lower }) {
                hasSession = true
            }
        }
        guard hasSession, !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    // MARK: - Networking helpers

    private func fetchEndpoint(path: String, cookieHeader: String) async throws -> Data {
        let url = Self.apiBase.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Self.requestTimeout
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
        req.setValue("\(Self.webOrigin)/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Same as `fetchEndpoint` but swallows all errors — returns nil on any failure.
    private func fetchEndpointOptional(path: String, cookieHeader: String) async -> Data? {
        try? await fetchEndpoint(path: path, cookieHeader: cookieHeader)
    }

    // MARK: - Value coercion

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
                  d.isFinite
            else { return nil }
            return d
        default:
            return nil
        }
    }

    private static func parseDate(from value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: trimmed) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static func usd(_ value: Double) -> String {
        UsageFormatter.usdString(value)
    }

    /// One `windowLimits` entry → a quota window. `cap` is the denominator and
    /// `resetAt` is epoch milliseconds. nil when the entry carries no usable
    /// cap, so a partial payload drops one row rather than charting a zero.
    private static func windowLimitQuota(
        _ value: Any?, label: String, windowSeconds: Int
    ) -> QuotaWindow? {
        guard let dict = value as? [String: Any],
              let cap = double(from: dict["cap"]), cap > 0,
              let rawUsed = double(from: dict["used"])
        else { return nil }
        let used = max(0, min(cap, rawUsed))
        let usedPct = Int((used / cap * 100).rounded())
        let resetDate = double(from: dict["resetAt"])
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        return QuotaWindow(
            label: label,
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: "\(usd(cap - used)) / \(usd(cap))",
            resetDate: resetDate,
            windowSeconds: windowSeconds)
    }

    // MARK: - Embedded plan catalog (hand-ported from CommandCodePlanCatalog)

    struct Plan {
        let id: String
        let displayName: String
        let monthlyCreditsUSD: Double
    }

    private static let plans: [Plan] = [
        Plan(id: "individual-go",    displayName: "Go",    monthlyCreditsUSD: 10),
        Plan(id: "individual-pro",   displayName: "Pro",   monthlyCreditsUSD: 30),
        Plan(id: "individual-max",   displayName: "Max",   monthlyCreditsUSD: 150),
        Plan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300),
        Plan(id: "individual-goat",  displayName: "Goat",  monthlyCreditsUSD: 70),
    ]

    private static func plan(forID planID: String) -> Plan? {
        let normalized = planID.lowercased()
        return plans.first { $0.id == normalized }
    }
}
