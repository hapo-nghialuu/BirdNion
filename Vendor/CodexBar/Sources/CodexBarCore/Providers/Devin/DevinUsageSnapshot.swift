import CoreFoundation
import Foundation

public enum DevinUsageError: LocalizedError, Sendable {
    case noSession
    case missingOrganization
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSession:
            "No Devin browser session found. Please log in to app.devin.ai or paste a Bearer token."
        case .missingOrganization:
            "No Devin organization was found. Open an app.devin.ai/org/... page " +
                "or set the organization in Devin settings."
        case .invalidCredentials:
            "Devin session token is invalid or expired."
        case let .apiError(message):
            "Devin API error: \(message)"
        case let .parseFailed(message):
            "Could not parse Devin usage: \(message)"
        }
    }
}

public struct DevinQuotaWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Exact ACU amounts when the payload carries them (`used`/`limit` or
    /// `remaining`/`limit`); nil for percent-only sources.
    public let used: Double?
    public let remaining: Double?
    public let limit: Double?

    public init(
        usedPercent: Double,
        resetsAt: Date? = nil,
        used: Double? = nil,
        remaining: Double? = nil,
        limit: Double? = nil)
    {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.used = used
        self.remaining = remaining
        self.limit = limit
    }
}

/// One day of metered usage from `GET …/billing/usage/daily-usage`.
/// `amount` is denominated in ACUs for ACU/quota plans.
public struct DevinDailyUsage: Sendable, Equatable {
    public let date: Date
    public let amount: Double
    public let cumulative: Double

    public init(date: Date, amount: Double, cumulative: Double) {
        self.date = date
        self.amount = amount
        self.cumulative = cumulative
    }
}

/// Per-product usage totals ("sessions" / "reviews" / "automations" / …)
/// from the same `daily-usage` payload.
public struct DevinProductUsage: Sendable, Equatable {
    public let view: String
    public let total: Double
    public let days: [DevinDailyUsage]

    public init(view: String, total: Double, days: [DevinDailyUsage]) {
        self.view = view
        self.total = total
        self.days = days
    }
}

/// Billing-cycle daily usage series (merged `current` + `previous` cycles
/// when the API says a previous cycle exists).
public struct DevinUsageHistory: Sendable, Equatable {
    public let days: [DevinDailyUsage]
    public let products: [DevinProductUsage]
    public let cycleStart: Date?
    public let cycleEnd: Date?
    public let total: Double

    public init(
        days: [DevinDailyUsage],
        products: [DevinProductUsage],
        cycleStart: Date?,
        cycleEnd: Date?,
        total: Double)
    {
        self.days = days
        self.products = products
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
        self.total = total
    }
}

public struct DevinUsageSnapshot: Sendable, Equatable {
    public let daily: DevinQuotaWindow?
    public let weekly: DevinQuotaWindow?
    public let planName: String?
    public let organization: String?
    public let updatedAt: Date
    /// Per-day metered usage for the current (and previous) billing cycle.
    /// nil when the `billing/usage/daily-usage` probe failed or the plan
    /// does not expose it — quota windows still render without it.
    public let usageHistory: DevinUsageHistory?
    /// `overage_balance` — prepaid on-demand dollars left once the included
    /// quota is exhausted. nil when the payload does not carry it.
    public let overageBalance: Double?

    public init(
        daily: DevinQuotaWindow?,
        weekly: DevinQuotaWindow?,
        planName: String?,
        organization: String?,
        updatedAt: Date,
        usageHistory: DevinUsageHistory? = nil,
        overageBalance: Double? = nil)
    {
        self.daily = daily
        self.weekly = weekly
        self.planName = planName
        self.organization = organization
        self.updatedAt = updatedAt
        self.usageHistory = usageHistory
        self.overageBalance = overageBalance
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.daily.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: 24 * 60,
                resetsAt: $0.resetsAt,
                resetDescription: "Daily")
        }
        let secondary = self.weekly.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: $0.resetsAt,
                resetDescription: "Weekly")
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .devin,
            accountEmail: nil,
            accountOrganization: self.organization,
            loginMethod: self.planName)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum DevinUsageParser {
    public static func parse(_ data: Data, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        return try self.parse(object, organization: organization, now: now)
    }

    public static func parse(_ object: Any, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let current = (object as? [String: Any]).map(self.currentQuotaWindows)
        let daily = current?.daily ?? self.findWindow(in: object, matching: self.isDailyKey)
        let weekly = current?.weekly ?? self.findWindow(in: object, matching: self.isWeeklyKey)
        guard daily != nil || weekly != nil else {
            throw DevinUsageError.parseFailed("Missing Devin quota windows.")
        }

        return DevinUsageSnapshot(
            daily: daily,
            weekly: weekly,
            planName: self.findPlanName(in: object),
            organization: self.displayOrganization(from: organization),
            updatedAt: now,
            overageBalance: self.findOverageBalance(in: object))
    }

    /// `overage_balance` sits at the payload root today, but keep the same
    /// deep-search tolerance the quota windows use in case it moves.
    private static func findOverageBalance(in object: Any) -> Double? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let lowered = key.lowercased()
                if lowered == "overage_balance" || lowered == "overagebalance" {
                    if let amount = self.double(value) { return amount }
                }
            }
            for value in dictionary.values {
                if let found = self.findOverageBalance(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = self.findOverageBalance(in: value) { return found }
            }
        }
        return nil
    }

    private static func currentQuotaWindows(_ dictionary: [String: Any])
        -> (daily: DevinQuotaWindow?, weekly: DevinQuotaWindow?)
    {
        let daily = self.currentQuotaWindow(
            percent: dictionary["daily_percentage"],
            resetsAt: dictionary["daily_reset_at"])
        let weekly = self.currentQuotaWindow(
            percent: dictionary["weekly_percentage"],
            resetsAt: dictionary["weekly_reset_at"])
        return (daily, weekly)
    }

    private static func currentQuotaWindow(percent: Any?, resetsAt: Any?) -> DevinQuotaWindow? {
        guard let usedPercent = self.double(percent) else { return nil }
        return DevinQuotaWindow(
            usedPercent: usedPercent <= 1 ? usedPercent * 100 : usedPercent,
            resetsAt: self.date(from: resetsAt))
    }

    private static func findWindow(in object: Any, matching keyMatches: (String) -> Bool) -> DevinQuotaWindow? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let window = self.window(from: value) {
                    return window
                }
            }
            for value in dictionary.values {
                if let found = self.findWindow(in: value, matching: keyMatches) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findWindow(in: value, matching: keyMatches) {
                    return found
                }
            }
        }

        return nil
    }

    private static func window(from object: Any) -> DevinQuotaWindow? {
        guard let dictionary = object as? [String: Any] else {
            guard let percent = self.percent(from: object) else { return nil }
            return DevinQuotaWindow(usedPercent: percent, resetsAt: nil)
        }

        if let percent = self.percent(from: dictionary) {
            let allowance = self.absoluteAllowance(in: dictionary)
            return DevinQuotaWindow(
                usedPercent: percent,
                resetsAt: self.findResetDate(in: dictionary),
                used: allowance.used,
                remaining: allowance.remaining,
                limit: allowance.limit)
        }

        if let nested = dictionary.values.lazy.compactMap({ self.window(from: $0) }).first {
            return nested
        }

        return nil
    }

    /// Raw `used`/`remaining`/`limit` readings from the payload, mirroring the
    /// key precedence `percent(from:)` uses. `available` doubles as a limit
    /// alias there — when it sourced the limit, a `remaining` read of the same
    /// key is dropped so the pair never reports identical values.
    private static func absoluteAllowance(
        in dictionary: [String: Any]
    ) -> (used: Double?, remaining: Double?, limit: Double?) {
        let used = self.firstKeyedDouble(
            in: dictionary, keys: ["used", "usage", "used_count", "usedCount", "consumed"])
        let limit = self.firstKeyedDouble(
            in: dictionary, keys: ["limit", "quota", "total", "max", "available"])
        let remaining = self.firstKeyedDouble(
            in: dictionary, keys: ["remaining", "left", "available"])
        let distinctRemaining = (remaining?.key == limit?.key) ? nil : remaining?.value
        return (used?.value, distinctRemaining, limit?.value)
    }

    private static func firstKeyedDouble(
        in dictionary: [String: Any], keys: [String]
    ) -> (key: String, value: Double)? {
        for key in keys {
            if let value = self.double(dictionary[key]) {
                return (key, value)
            }
        }
        return nil
    }

    private static func percent(from object: Any) -> Double? {
        if let number = self.double(object) {
            return number <= 1 ? number * 100 : number
        }
        guard let dictionary = object as? [String: Any] else { return nil }

        let directKeys = [
            "used_percent",
            "usedPercent",
            "usage_percent",
            "usagePercent",
            "percent_used",
            "percentUsed",
            "percent",
        ]
        for key in directKeys {
            if let value = self.double(dictionary[key]) {
                return value <= 1 ? value * 100 : value
            }
        }

        let remainingKeys = ["remaining_percent", "remainingPercent", "percent_remaining", "percentRemaining"]
        for key in remainingKeys {
            if let value = self.double(dictionary[key]) {
                let percent = value <= 1 ? value * 100 : value
                return 100 - percent
            }
        }

        let used = self.firstDouble(in: dictionary, keys: ["used", "usage", "used_count", "usedCount", "consumed"])
        let limit = self.firstDouble(in: dictionary, keys: ["limit", "quota", "total", "max", "available"])
        if let used, let limit, limit > 0 {
            return used / limit * 100
        }

        let remaining = self.firstDouble(in: dictionary, keys: ["remaining", "left", "available"])
        if let remaining, let limit, limit > 0 {
            return (limit - remaining) / limit * 100
        }

        return nil
    }

    private static func findPlanName(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"] {
                if let value = dictionary[key] as? String,
                   let cleaned = self.cleanDisplay(value)
                {
                    return cleaned
                }
            }
            for value in dictionary.values {
                if let found = self.findPlanName(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findPlanName(in: value) {
                    return found
                }
            }
        }

        return nil
    }

    private static func findResetDate(in dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains("reset") {
            if let date = self.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = value as? String {
            if let date = ISO8601DateFormatter().date(from: raw) {
                return date
            }
            if let number = Double(raw) {
                return self.date(from: number)
            }
        }
        if let number = self.double(value) {
            return self.date(from: number)
        }
        return nil
    }

    private static func date(from number: Double) -> Date? {
        guard number > 0 else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func firstDouble(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = self.double(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func isDailyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("daily") || key.contains("day"))
    }

    private static func isWeeklyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
    }

    private static func displayOrganization(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("org/") {
            return String(raw.dropFirst(4))
        }
        if raw.hasPrefix("organizations/") {
            return String(raw.dropFirst("organizations/".count))
        }
        return raw
    }

    private static func cleanDisplay(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.split(separator: "_").flatMap { $0.split(separator: "-") }.map { part in
            part.prefix(1).uppercased() + String(part.dropFirst())
        }.joined(separator: " ")
    }

    // MARK: - Daily usage (billing/usage/daily-usage)

    /// Parses one `billing/usage/daily-usage?cycle=…&view=all` payload:
    /// `{cycle_start, cycle_end, previous_cycle_available, total, days:
    /// [{date, amount, cumulative}], products: [{view, total, days: […]}]}`.
    /// Returns nil instead of throwing — the caller treats history as a
    /// best-effort overlay on top of the quota windows.
    public static func parseDailyUsage(_ data: Data) -> DevinUsageHistory? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return self.dailyUsageHistory(from: dictionary)
    }

    static func dailyUsageHistory(from dictionary: [String: Any]) -> DevinUsageHistory? {
        let days = self.usageDays(from: dictionary["days"])
        guard !days.isEmpty else { return nil }
        let products = (dictionary["products"] as? [[String: Any]] ?? []).compactMap { entry -> DevinProductUsage? in
            guard let view = entry["view"] as? String, !view.isEmpty else { return nil }
            return DevinProductUsage(
                view: view,
                total: self.double(entry["total"]) ?? 0,
                days: self.usageDays(from: entry["days"]))
        }
        return DevinUsageHistory(
            days: days,
            products: products,
            cycleStart: self.date(from: dictionary["cycle_start"]),
            cycleEnd: self.date(from: dictionary["cycle_end"]),
            total: self.double(dictionary["total"]) ?? days.reduce(0) { $0 + $1.amount })
    }

    /// `previous_cycle_available` is read by the fetcher to decide whether a
    /// second `cycle=previous` request is worthwhile.
    static func previousCycleAvailable(in dictionary: [String: Any]) -> Bool {
        (dictionary["previous_cycle_available"] as? Bool) == true
    }

    static func previousCycleAvailable(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return self.previousCycleAvailable(in: dictionary)
    }

    /// Merge two cycle payloads (previous then current) into one series:
    /// days deduplicated by date, product totals summed per view.
    public static func mergeCycles(
        previous: DevinUsageHistory?,
        current: DevinUsageHistory
    ) -> DevinUsageHistory {
        guard let previous else { return current }
        var daysByDate: [Date: DevinDailyUsage] = [:]
        for day in previous.days + current.days {
            daysByDate[day.date] = day
        }
        var productDays: [String: [Date: DevinDailyUsage]] = [:]
        var productTotals: [String: Double] = [:]
        var productOrder: [String] = []
        for product in previous.products + current.products {
            if productDays[product.view] == nil { productOrder.append(product.view) }
            productTotals[product.view, default: 0] += product.total
            var merged = productDays[product.view] ?? [:]
            for day in product.days { merged[day.date] = day }
            productDays[product.view] = merged
        }
        let products = productOrder.map { view in
            let days = (productDays[view] ?? [:]).values.sorted { $0.date < $1.date }
            return DevinProductUsage(
                view: view,
                total: productTotals[view] ?? 0,
                days: days)
        }
        return DevinUsageHistory(
            days: daysByDate.values.sorted { $0.date < $1.date },
            products: products,
            cycleStart: previous.cycleStart ?? current.cycleStart,
            cycleEnd: current.cycleEnd ?? previous.cycleEnd,
            total: previous.total + current.total)
    }

    private static func usageDays(from value: Any?) -> [DevinDailyUsage] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let raw = entry["date"] as? String,
                  let date = self.usageDayDate(from: raw)
            else { return nil }
            return DevinDailyUsage(
                date: date,
                amount: self.double(entry["amount"]) ?? 0,
                cumulative: self.double(entry["cumulative"]) ?? 0)
        }
    }

    private static func usageDayDate(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
