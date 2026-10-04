import Foundation

/// Report shape `BudgetAlerts` consumes — every typed cost report conforms
/// with a one-line `spendDays` mapping over its `daily` buckets.
protocol SpendReport {
    var spendDays: [(date: Date, usd: Double)] { get }
}

/// Budget alerts: notify once per period when a cost source's spend in the
/// configured budget period (Settings → Budget: week = calendar week starting
/// Monday, month = calendar month) crosses its per-source budget, or the
/// combined spend crosses the overall budget. Opt-in via
/// `budgetAlertsEnabled` (Settings → Budget), matching the existing
/// warning-notification opt-in pattern.
@MainActor
enum BudgetAlerts {
    static let enabledKey = "budgetAlertsEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Per-source budget UserDefaults keys (mirroring SettingsStore).
    private static func budgetKey(for source: CostHistoryStore.Source) -> String? {
        switch source {
        case .claude: "claudeBudgetUSD"
        case .codex: "codexBudgetUSD"
        case .grok: "grokBudgetUSD"
        case .kiro: "kiroBudgetUSD"
        case .omp: "ompBudgetUSD"
        case .pi: "piBudgetUSD"
        default: nil
        }
    }

    /// Latest per-source spend in the current period — feeds the overall
    /// (`monthlyBudgetUSD`) check as the sum across sources.
    private static var periodSpend: [CostHistoryStore.Source: Double] = [:]

    /// Called from `UsageReportCoordinator` when a fresh scan lands.
    static func record(source: CostHistoryStore.Source, report: SpendReport, now: Date = Date()) {
        guard enabled else { return }
        let (periodStart, periodKey) = currentPeriod(now: now)
        let spend = report.spendDays.reduce(0) { total, day in
            day.date >= periodStart && day.date <= now ? total + max(0, day.usd) : total
        }
        periodSpend[source] = spend
        let budgetPeriod = budgetPeriodSetting

        if let key = budgetKey(for: source) {
            let budget = UserDefaults.standard.double(forKey: key)
            if budget > 0, spend > budget {
                fireOnce(scope: source.rawValue, periodKey: periodKey) {
                    (displayName(for: source), spend, budget, budgetPeriod)
                }
            }
        }

        let totalBudget = UserDefaults.standard.double(forKey: "monthlyBudgetUSD")
        let total = periodSpend.values.reduce(0, +)
        if totalBudget > 0, total > totalBudget {
            fireOnce(scope: "total", periodKey: periodKey) {
                ("Tất cả nguồn", total, totalBudget, budgetPeriod)
            }
        }
    }

    /// Test hook — clear accumulated per-source period spend.
    static func reset() { periodSpend = [:] }

    // MARK: - Period helpers

    /// Configured period — "birdnion.budgetPeriod" UserDefaults key
    /// (mirroring `SettingsStore.budgetPeriod`; no shared store instance).
    static var budgetPeriodSetting: BudgetPeriod {
        BudgetPeriod(
            rawValue: UserDefaults.standard.string(forKey: "birdnion.budgetPeriod") ?? "")
            ?? .week
    }

    /// (start-of-period, dedupe key) for the configured period —
    /// "2026-W40" or "2026-10". Mirrors `BudgetForecast`'s week
    /// (Monday-start) / month (calendar) logic.
    static func currentPeriod(now: Date = Date()) -> (start: Date, key: String) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        switch budgetPeriodSetting {
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
            return (start, "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)")
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
            let comps = calendar.dateComponents([.year, .month], from: start)
            return (start, "\(comps.year ?? 0)-\(comps.month ?? 0)")
        }
    }

    /// Fires the notification at most once per scope per period — the fired
    /// marker persists in UserDefaults so an app relaunch can't re-fire.
    private static func fireOnce(
        scope: String, periodKey: String,
        payload: () -> (name: String, spend: Double, budget: Double, period: BudgetPeriod)
    ) {
        let key = "budgetAlert.fired.\(scope).\(periodKey)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let (name, spend, budget, period) = payload()
        let vi = L10n.languageCode(
            UserDefaults.standard.string(forKey: "appLanguage")) == "vi"
        let periodText = period == .week ? (vi ? "tuần" : "the week") : (vi ? "tháng" : "the month")
        QuotaNotifier.post(
            id: "budgetAlert.\(scope).\(periodKey)",
            title: vi ? "Vượt ngân sách" : "Budget exceeded",
            body: vi
                ? "\(name) đã chi \(formatUSD(spend)) trong \(periodText) — vượt ngân sách \(formatUSD(budget))"
                : "\(name) spent \(formatUSD(spend)) in \(periodText) — over the \(formatUSD(budget)) budget")
    }

    private static func displayName(for source: CostHistoryStore.Source) -> String {
        source.rawValue == "omp" ? "Oh My Pi" : source.rawValue.capitalized
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

// MARK: - Report conformances

extension ClaudeUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension CodexUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension GrokUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension KiroUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension OMPUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension PiUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}

extension DevinCLIUsageReport: SpendReport {
    var spendDays: [(date: Date, usd: Double)] { daily.map { ($0.date, $0.usd) } }
}
