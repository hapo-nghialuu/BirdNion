import Foundation

/// TryAPI wallet/usage provider.
///
/// Endpoint: `GET https://tryapi.tryai.chat/v1/usage`
/// Auth: `Authorization: Bearer <sk-...>` (env `TRYAPI_API_KEY` or config).
///
/// Unrestricted wallet response:
/// ```json
/// {
///   "balance": 290.6, "remaining": 290.6, "unit": "USD",
///   "isValid": true, "mode": "unrestricted",
///   "usage": {
///     "today": {"requests":0,"cost":0,"actual_cost":0,...},
///     "total": {"requests":89,"cost":8.85,"actual_cost":10.14,...}
///   }
/// }
/// ```
/// Optional `mode: "quota_limited"` may include `subscription` day/week/month
/// USD limits — surfaced as Ngày/Tuần/Tháng windows when finite.
final class TryAPIProvider: QuotaProvider {
    let id = "tryapi"
    let displayName = "TryAPI"

    static let endpoint = URL(string: "https://tryapi.tryai.chat/v1/usage")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func override() -> String? {
        BirdNionConfigStore.accountLabel(provider: id)
    }

    func fetch() async throws -> ProviderStatus {
        let envToken = ProcessInfo.processInfo.environment["TRYAPI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (envToken?.isEmpty == false ? envToken : nil)
            ?? BirdNionConfigStore.apiKey(provider: id)
        guard let token, !token.isEmpty else {
            return failure("Chưa cấu hình token")
        }
        let accountLabel = override() ?? String(token.prefix(8))

        var req = URLRequest(url: Self.endpoint)
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
        guard let http = response as? HTTPURLResponse else {
            return failure("Response không phải HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            return failure("HTTP \(http.statusCode)")
        }
        return parse(data, accountLabel: accountLabel)
    }

    /// Pure payload → status mapping (unit-tested, no network).
    func parse(_ data: Data, accountLabel: String) -> ProviderStatus {
        guard let root = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return failure("Response thiếu trường")
        }
        if root.isValid == false {
            return failure("API key không hợp lệ")
        }

        let totalUsage = root.usage?.total
        let used = totalUsage?.actualCost ?? totalUsage?.cost ?? 0
        let remaining = root.remaining ?? root.balance ?? 0
        let total = used + remaining
        let usedPct = total > 0
            ? max(0, min(100, Int((used / total * 100).rounded())))
            : 0

        var windows: [QuotaWindow] = [
            QuotaWindow(
                label: "Số dư",
                usedPct: usedPct,
                remainingPct: 100 - usedPct,
                subtitle: String(format: "$%.2f / $%.2f", used, total))
        ]

        if let today = root.usage?.today {
            let todayCost = today.actualCost ?? today.cost ?? 0
            let todayRequests = today.requests ?? 0
            if todayCost > 0 || todayRequests > 0 {
                let subtitle: String
                if todayRequests > 0 {
                    subtitle = String(format: "$%.2f · %d req", todayCost, todayRequests)
                } else {
                    subtitle = String(format: "$%.2f", todayCost)
                }
                windows.append(QuotaWindow(
                    label: "Hôm nay",
                    usedPct: 0,
                    remainingPct: 100,
                    subtitle: subtitle))
            }
        }

        if (root.mode ?? "").lowercased() == "quota_limited",
           let sub = root.subscription {
            if let w = subscriptionWindow(
                label: "Ngày",
                used: sub.dailyUsageUsd,
                limit: sub.dailyLimitUsd) {
                windows.append(w)
            }
            if let w = subscriptionWindow(
                label: "Tuần",
                used: sub.weeklyUsageUsd,
                limit: sub.weeklyLimitUsd) {
                windows.append(w)
            }
            if let w = subscriptionWindow(
                label: "Tháng",
                used: sub.monthlyUsageUsd,
                limit: sub.monthlyLimitUsd) {
                windows.append(w)
            }
        }

        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            accountLabel: accountLabel,
            creditsRemaining: remaining,
            planName: root.planName)
    }

    private func subscriptionWindow(
        label: String,
        used: Double?,
        limit: Double?
    ) -> QuotaWindow? {
        guard let limit, limit > 0, limit.isFinite else { return nil }
        let spent = max(0, used ?? 0)
        let usedPct = max(0, min(100, Int((spent / limit * 100).rounded())))
        return QuotaWindow(
            label: label,
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: String(format: "$%.2f / $%.2f", spent, limit))
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: message)
    }

    private struct UsageResponse: Decodable {
        let balance: Double?
        let remaining: Double?
        let unit: String?
        let planName: String?
        let isValid: Bool?
        let mode: String?
        let usage: UsageBucket?
        let subscription: Subscription?

        struct UsageBucket: Decodable {
            let today: UsageTotals?
            let total: UsageTotals?
        }

        struct UsageTotals: Decodable {
            let cost: Double?
            let actualCost: Double?
            let requests: Int?

            enum CodingKeys: String, CodingKey {
                case cost
                case actualCost = "actual_cost"
                case requests
            }
        }

        struct Subscription: Decodable {
            let dailyUsageUsd: Double?
            let dailyLimitUsd: Double?
            let weeklyUsageUsd: Double?
            let weeklyLimitUsd: Double?
            let monthlyUsageUsd: Double?
            let monthlyLimitUsd: Double?

            enum CodingKeys: String, CodingKey {
                case dailyUsageUsd = "daily_usage_usd"
                case dailyLimitUsd = "daily_limit_usd"
                case weeklyUsageUsd = "weekly_usage_usd"
                case weeklyLimitUsd = "weekly_limit_usd"
                case monthlyUsageUsd = "monthly_usage_usd"
                case monthlyLimitUsd = "monthly_limit_usd"
            }
        }
    }
}
