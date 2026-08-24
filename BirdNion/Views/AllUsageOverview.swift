import SwiftUI

// MARK: - Combined usage model

/// One calendar day of combined Claude Code CLI + Codex + Grok + Kiro + OMP + Pi usage.
/// Kept per-source so the stacked chart and hover detail can split the bar by origin.
struct CombinedDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date   // startOfDay in local tz
    let claudeUSD: Double
    let claudeTokens: Int
    let codexUSD: Double
    let codexTokens: Int
    let grokUSD: Double
    let grokTokens: Int
    let kiroUSD: Double
    let kiroTokens: Int
    let ompUSD: Double
    let ompTokens: Int
    let piUSD: Double
    let piTokens: Int
    /// Per-model split for this day (all sources, token-sorted).
    var models: [CombinedModelCost] = []

    var usd: Double { claudeUSD + codexUSD + grokUSD + kiroUSD + ompUSD + piUSD }
    var tokens: Int { claudeTokens + codexTokens + grokTokens + kiroTokens + ompTokens + piTokens }
    var isActive: Bool { usd > 0 || tokens > 0 }
    var id: Date { date }

    init(
        date: Date,
        claudeUSD: Double, claudeTokens: Int,
        codexUSD: Double, codexTokens: Int,
        grokUSD: Double = 0, grokTokens: Int = 0,
        kiroUSD: Double = 0, kiroTokens: Int = 0,
        ompUSD: Double = 0, ompTokens: Int = 0,
        piUSD: Double = 0, piTokens: Int = 0,
        models: [CombinedModelCost] = []
    ) {
        self.date = date
        self.claudeUSD = claudeUSD
        self.claudeTokens = claudeTokens
        self.codexUSD = codexUSD
        self.codexTokens = codexTokens
        self.grokUSD = grokUSD
        self.grokTokens = grokTokens
        self.kiroUSD = kiroUSD
        self.kiroTokens = kiroTokens
        self.ompUSD = ompUSD
        self.ompTokens = ompTokens
        self.piUSD = piUSD
        self.piTokens = piTokens
        self.models = models
    }
}

/// One model's summed cost across the combined window, tagged with its source.
struct CombinedModelCost: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    /// "claude" | "codex" | "grok" | "kiro" | "omp" | "pi"
    let source: String
    var id: String { "\(source):\(name)" }
}

/// Cross-provider aggregation of the local usage reports across all 6 sources.
struct CombinedUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    let totalUSD: Double
    let totalTokens: Int
    let daily: [CombinedDailyUsage]
    let topModels: [CombinedModelCost]
    let peakDayUSD: Double
    let peakDayDate: Date?
    let avgPerActiveDayUSD: Double
    let activeDays: Int
    let streakDays: Int
    let claudeConfidence: CostHistoryStore.UsageScanConfidence?
    let codexConfidence: CostHistoryStore.UsageScanConfidence?
    let grokConfidence: CostHistoryStore.UsageScanConfidence?
    let kiroConfidence: CostHistoryStore.UsageScanConfidence?
    let ompConfidence: CostHistoryStore.UsageScanConfidence?
    let piConfidence: CostHistoryStore.UsageScanConfidence?
    var isEmpty: Bool { activeDays == 0 }
    var hasIncludedCostSource: Bool {
        [claudeConfidence, codexConfidence, grokConfidence,
         kiroConfidence, ompConfidence, piConfidence]
            .contains { $0?.included == true }
    }
    /// Sources actually contributing to this report (seeded history counts too).
    /// Drives the "· N agent" hero subtitle so it never reads 0 while cost shows.
    var includedSourceCount: Int {
        [claudeConfidence, codexConfidence, grokConfidence,
         kiroConfidence, ompConfidence, piConfidence]
            .filter { $0?.included == true }.count
    }

    init(
        todayUSD: Double,
        todayTokens: Int,
        last30USD: Double,
        last30Tokens: Int,
        totalUSD: Double,
        totalTokens: Int,
        daily: [CombinedDailyUsage],
        topModels: [CombinedModelCost],
        peakDayUSD: Double,
        peakDayDate: Date?,
        avgPerActiveDayUSD: Double,
        activeDays: Int,
        streakDays: Int,
        claudeConfidence: CostHistoryStore.UsageScanConfidence? = nil,
        codexConfidence: CostHistoryStore.UsageScanConfidence? = nil,
        grokConfidence: CostHistoryStore.UsageScanConfidence? = nil,
        kiroConfidence: CostHistoryStore.UsageScanConfidence? = nil,
        ompConfidence: CostHistoryStore.UsageScanConfidence? = nil,
        piConfidence: CostHistoryStore.UsageScanConfidence? = nil
    ) {
        self.todayUSD = todayUSD
        self.todayTokens = todayTokens
        self.last30USD = last30USD
        self.last30Tokens = last30Tokens
        self.totalUSD = totalUSD
        self.totalTokens = totalTokens
        self.daily = daily
        self.topModels = topModels
        self.peakDayUSD = peakDayUSD
        self.peakDayDate = peakDayDate
        self.avgPerActiveDayUSD = avgPerActiveDayUSD
        self.activeDays = activeDays
        self.streakDays = streakDays
        self.claudeConfidence = claudeConfidence
        self.codexConfidence = codexConfidence
        self.grokConfidence = grokConfidence
        self.kiroConfidence = kiroConfidence
        self.ompConfidence = ompConfidence
        self.piConfidence = piConfidence
    }

    static func build(
        claude: ClaudeUsageReport?,
        codex: CodexUsageReport?,
        grok: GrokUsageReport? = nil,
        kiro: KiroUsageReport? = nil,
        omp: OMPUsageReport? = nil,
        pi: PiUsageReport? = nil,
        includeClaude: Bool = true,
        includeCodex: Bool = true,
        includeGrok: Bool = true,
        includeKiro: Bool = true,
        includeOMP: Bool = true,
        includePi: Bool = true,
        calendar: Calendar = .current,
        now: Date = Date(),
        windowDays: Int = 120
    ) -> CombinedUsageReport {
        let startOfToday = calendar.startOfDay(for: now)
        let includedClaude = includeClaude ? claude : nil
        let includedCodex = includeCodex ? codex : nil
        let includedGrok = includeGrok ? grok : nil
        let includedKiro = includeKiro ? kiro : nil
        let includedOMP = includeOMP ? omp : nil
        let includedPi = includePi ? pi : nil

        let claudeDays = dayTotals(from: includedClaude?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let codexDays = dayTotals(from: includedCodex?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let grokDays = dayTotals(from: includedGrok?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let kiroDays = dayTotals(from: includedKiro?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let ompDays = dayTotals(from: includedOMP?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let piDays = dayTotals(from: includedPi?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)

        var daily: [CombinedDailyUsage] = []
        daily.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let c = claudeDays.totals[day] ?? (0, 0)
            let x = codexDays.totals[day] ?? (0, 0)
            let g = grokDays.totals[day] ?? (0, 0)
            let k = kiroDays.totals[day] ?? (0, 0)
            let o = ompDays.totals[day] ?? (0, 0)
            let p = piDays.totals[day] ?? (0, 0)
            daily.append(CombinedDailyUsage(
                date: day,
                claudeUSD: c.usd, claudeTokens: c.tokens,
                codexUSD: x.usd, codexTokens: x.tokens,
                grokUSD: g.usd, grokTokens: g.tokens,
                kiroUSD: k.usd, kiroTokens: k.tokens,
                ompUSD: o.usd, ompTokens: o.tokens,
                piUSD: p.usd, piTokens: p.tokens,
                models: mergedModelCosts(
                    claude: claudeDays.models[day] ?? [:],
                    codex: codexDays.models[day] ?? [:],
                    grok: grokDays.models[day] ?? [:],
                    kiro: kiroDays.models[day] ?? [:],
                    omp: ompDays.models[day] ?? [:],
                    pi: piDays.models[day] ?? [:])))
        }

        let today = daily.last
        let totalUSD = daily.reduce(0) { $0 + $1.usd }
        let totalTokens = daily.reduce(0) { $0 + $1.tokens }
        let active = daily.filter(\.isActive)
        let peak = daily.max { $0.usd < $1.usd }
        let peakUSD = peak?.usd ?? 0

        var streak = 0
        var remaining = daily.reversed().makeIterator()
        if var current = remaining.next() {
            if !current.isActive, let previous = remaining.next() { current = previous }
            while current.isActive {
                streak += 1
                guard let previous = remaining.next() else { break }
                current = previous
            }
        }

        let topModels = Array(
            mergedModelCosts(
                claude: foldModels(claudeDays.models),
                codex: foldModels(codexDays.models),
                grok: foldModels(grokDays.models),
                kiro: foldModels(kiroDays.models),
                omp: foldModels(ompDays.models),
                pi: foldModels(piDays.models)).prefix(6))

        let cUSD = includedClaude?.last30USD ?? 0
        let xUSD = includedCodex?.last30USD ?? 0
        let gUSD = includedGrok?.last30USD ?? 0
        let kUSD = includedKiro?.last30USD ?? 0
        let oUSD = includedOMP?.last30USD ?? 0
        let pUSD = includedPi?.last30USD ?? 0
        let last30USD = cUSD + xUSD + gUSD + kUSD + oUSD + pUSD

        let cTokens = includedClaude?.last30Tokens ?? 0
        let xTokens = includedCodex?.last30Tokens ?? 0
        let gTokens = includedGrok?.last30Tokens ?? 0
        let kTokens = includedKiro?.last30Tokens ?? 0
        let oTokens = includedOMP?.last30Tokens ?? 0
        let pTokens = includedPi?.last30Tokens ?? 0
        let last30Tokens = cTokens + xTokens + gTokens + kTokens + oTokens + pTokens

        return CombinedUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: last30USD,
            last30Tokens: last30Tokens,
            totalUSD: totalUSD,
            totalTokens: totalTokens,
            daily: daily,
            topModels: topModels,
            peakDayUSD: peakUSD,
            peakDayDate: peakUSD > 0 ? peak?.date : nil,
            avgPerActiveDayUSD: active.isEmpty ? 0 : totalUSD / Double(active.count),
            activeDays: active.count,
            streakDays: streak,
            claudeConfidence: includedClaude?.scanConfidence,
            codexConfidence: includedCodex?.scanConfidence,
            grokConfidence: includedGrok?.scanConfidence,
            kiroConfidence: includedKiro?.scanConfidence,
            ompConfidence: includedOMP?.scanConfidence,
            piConfidence: includedPi?.scanConfidence)
    }

    private struct DayIndex {
        var totals: [Date: (usd: Double, tokens: Int)] = [:]
        var models: [Date: [String: (usd: Double, tokens: Int)]] = [:]
    }

    private static func dayTotals(
        from rows: [(date: Date, usd: Double, tokens: Int, models: [(String, Double, Int)])],
        calendar: Calendar
    ) -> DayIndex {
        var index = DayIndex()
        for row in rows {
            let day = calendar.startOfDay(for: row.date)
            var v = index.totals[day] ?? (0, 0)
            v.usd += row.usd
            v.tokens += row.tokens
            index.totals[day] = v

            var byModel = index.models[day] ?? [:]
            for (name, usd, tokens) in row.models {
                var m = byModel[name] ?? (0, 0)
                m.usd += usd
                m.tokens += tokens
                byModel[name] = m
            }
            index.models[day] = byModel
        }
        return index
    }

    private static func mergedModelCosts(
        claude: [String: (usd: Double, tokens: Int)],
        codex: [String: (usd: Double, tokens: Int)],
        grok: [String: (usd: Double, tokens: Int)] = [:],
        kiro: [String: (usd: Double, tokens: Int)] = [:],
        omp: [String: (usd: Double, tokens: Int)] = [:],
        pi: [String: (usd: Double, tokens: Int)] = [:]
    ) -> [CombinedModelCost] {
        var items: [CombinedModelCost] = []
        items.append(contentsOf: claude.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "claude") })
        items.append(contentsOf: codex.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "codex") })
        items.append(contentsOf: grok.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "grok") })
        items.append(contentsOf: kiro.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "kiro") })
        items.append(contentsOf: omp.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "omp") })
        items.append(contentsOf: pi.map { CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "pi") })
        items.sort {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.usd > $1.usd
        }
        return items
    }

    private static func foldModels(_ perDay: [Date: [String: (usd: Double, tokens: Int)]]) -> [String: (usd: Double, tokens: Int)] {
        var totals: [String: (usd: Double, tokens: Int)] = [:]
        for (_, dayModels) in perDay {
            for (name, pair) in dayModels {
                var acc = totals[name] ?? (0, 0)
                acc.usd += pair.usd
                acc.tokens += pair.tokens
                totals[name] = acc
            }
        }
        return totals
    }
}

// MARK: - Combined totals

struct CombinedWindowTotals: Equatable {
    let usd: Double
    let tokens: Int
    let claudeUSD: Double
    let claudeTokens: Int
    let codexUSD: Double
    let codexTokens: Int
    let grokUSD: Double
    let grokTokens: Int
    let kiroUSD: Double
    let kiroTokens: Int
    let ompUSD: Double
    let ompTokens: Int
    let piUSD: Double
    let piTokens: Int
}

extension CombinedUsageReport {
    func totals(lastDays days: Int) -> CombinedWindowTotals {
        let window = daily.suffix(days)
        return CombinedWindowTotals(
            usd: window.reduce(0) { $0 + $1.usd },
            tokens: window.reduce(0) { $0 + $1.tokens },
            claudeUSD: window.reduce(0) { $0 + $1.claudeUSD },
            claudeTokens: window.reduce(0) { $0 + $1.claudeTokens },
            codexUSD: window.reduce(0) { $0 + $1.codexUSD },
            codexTokens: window.reduce(0) { $0 + $1.codexTokens },
            grokUSD: window.reduce(0) { $0 + $1.grokUSD },
            grokTokens: window.reduce(0) { $0 + $1.grokTokens },
            kiroUSD: window.reduce(0) { $0 + $1.kiroUSD },
            kiroTokens: window.reduce(0) { $0 + $1.kiroTokens },
            ompUSD: window.reduce(0) { $0 + $1.ompUSD },
            ompTokens: window.reduce(0) { $0 + $1.ompTokens },
            piUSD: window.reduce(0) { $0 + $1.piUSD },
            piTokens: window.reduce(0) { $0 + $1.piTokens })
    }

    func topModels(lastDays days: Int, limit: Int = 6) -> (models: [CombinedModelCost], windowTokens: Int) {
        let n = max(days, 1)
        let window = Array(daily.suffix(n))
        var usdByKey: [String: Double] = [:]
        var tokensByKey: [String: Int] = [:]
        var metaByKey: [String: (name: String, source: String)] = [:]
        var windowTokens = 0
        for day in window {
            windowTokens += day.tokens
            for m in day.models {
                let key = "\(m.source):\(m.name)"
                if metaByKey[key] == nil {
                    metaByKey[key] = (m.name, m.source)
                }
                usdByKey[key, default: 0] += m.usd
                tokensByKey[key, default: 0] += m.tokens
            }
        }
        var models: [CombinedModelCost] = []
        models.reserveCapacity(metaByKey.count)
        for (key, meta) in metaByKey {
            let usd = usdByKey[key] ?? 0
            let tokens = tokensByKey[key] ?? 0
            if usd <= 0 && tokens <= 0 { continue }
            models.append(CombinedModelCost(
                name: meta.name, usd: usd, tokens: tokens, source: meta.source))
        }
        models.sort {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.usd > $1.usd
        }
        if models.count > limit {
            models = Array(models.prefix(limit))
        }
        return (models, max(windowTokens, 1))
    }
}

// MARK: - Budget Forecast

enum BudgetForecastStatus: Equatable {
    case onTrack
    case forecastOver
    case alreadyOver
}

typealias MonthlyForecastStatus = BudgetForecastStatus

enum CombinedUsageSource: Equatable {
    case total, claude, codex, grok, kiro, omp, pi
}

struct BudgetForecast: Equatable {
    let periodToDateUSD: Double
    let daysElapsed: Int
    let daysInPeriod: Int
    let dailyAverageUSD: Double
    let projectedTotalUSD: Double
    let budgetUSD: Double?
    let status: BudgetForecastStatus?
    let period: BudgetPeriod

    var monthToDateUSD: Double { periodToDateUSD }
    var daysInMonth: Int { daysInPeriod }
    var daysRemainingInMonth: Int { max(0, daysInPeriod - daysElapsed) }
    var remainingBudgetUSD: Double? { budgetUSD.map { $0 - periodToDateUSD } }
    var daysRemainingInPeriod: Int { max(0, daysInPeriod - daysElapsed) }
    var progressFraction: Double? {
        guard let budgetUSD, budgetUSD > 0 else { return nil }
        return periodToDateUSD / budgetUSD
    }

    static func build(
        daily: [CombinedDailyUsage],
        budgetUSD: Double?,
        period: BudgetPeriod = .week,
        source: CombinedUsageSource = .total,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetForecast {
        var calendar = calendar
        if period == .week {
            calendar.firstWeekday = 2
            calendar.minimumDaysInFirstWeek = 4
        }
        let startOfToday = calendar.startOfDay(for: now)
        let periodStart: Date
        let daysInPeriod: Int

        switch period {
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                periodStart = calendar.startOfDay(for: interval.start)
            } else {
                periodStart = startOfToday
            }
            daysInPeriod = 7
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: now) {
                periodStart = calendar.startOfDay(for: interval.start)
                let range = calendar.range(of: .day, in: .month, for: now)
                daysInPeriod = range?.count ?? 30
            } else {
                periodStart = startOfToday
                daysInPeriod = 30
            }
        }

        let periodToDateUSD = daily
            .filter { day in
                let d = calendar.startOfDay(for: day.date)
                return d >= periodStart && d <= startOfToday
            }
            .reduce(0) { total, day in
                let value = usdValue(day, source: source)
                guard value.isFinite, value >= 0 else { return total }
                return total + value
            }

        let dayOffset = calendar.dateComponents([.day], from: periodStart, to: startOfToday).day ?? 0
        let daysElapsed = max(1, min(daysInPeriod, dayOffset + 1))
        let dailyAverageUSD = periodToDateUSD / Double(daysElapsed)
        let projectedTotalUSD = dailyAverageUSD * Double(daysInPeriod)

        let normalizedBudget: Double? = {
            guard let budgetUSD, budgetUSD.isFinite, budgetUSD > 0 else { return nil }
            return budgetUSD
        }()
        let status: BudgetForecastStatus? = normalizedBudget.map { budget in
            if periodToDateUSD > budget { return .alreadyOver }
            if projectedTotalUSD > budget { return .forecastOver }
            return .onTrack
        }

        return BudgetForecast(
            periodToDateUSD: periodToDateUSD,
            daysElapsed: daysElapsed,
            daysInPeriod: daysInPeriod,
            dailyAverageUSD: dailyAverageUSD,
            projectedTotalUSD: projectedTotalUSD,
            budgetUSD: normalizedBudget,
            status: status,
            period: period)
    }

    private static func usdValue(_ day: CombinedDailyUsage, source: CombinedUsageSource) -> Double {
        switch source {
        case .total: return day.usd
        case .claude: return day.claudeUSD
        case .codex: return day.codexUSD
        case .grok: return day.grokUSD
        case .kiro: return day.kiroUSD
        case .omp: return day.ompUSD
        case .pi: return day.piUSD
        }
    }
}

typealias MonthlyForecast = BudgetForecast

// MARK: - All tab root

struct AllUsageOverview: View {
    @EnvironmentObject var settings: SettingsStore

    let claude: ClaudeUsageReport?
    let codex: CodexUsageReport?
    let grok: GrokUsageReport?
    let kiro: KiroUsageReport?
    let omp: OMPUsageReport?
    let pi: PiUsageReport?
    let visibleAgentRecords: [InstalledAgentRecord]
    let allAgentRecords: [InstalledAgentRecord]
    let providerStatuses: [ProviderStatus]
    let onOpenAgentDetail: (InstalledAgentRecord, String?) -> Void
    let onOpenActivity: () -> Void
    /// Hover mở panel transient (rời chuột đóng) — click mới ghim.
    let onHoverAgentDetail: (InstalledAgentRecord) -> Void
    let onHoverActivity: () -> Void
    let onHoverEnd: () -> Void
    var claudeEnabled: Bool = true
    var codexEnabled: Bool = true
    var grokEnabled: Bool = true
    var kiroEnabled: Bool = true

    init(
        claude: ClaudeUsageReport?,
        codex: CodexUsageReport?,
        grok: GrokUsageReport?,
        kiro: KiroUsageReport? = nil,
        omp: OMPUsageReport? = nil,
        pi: PiUsageReport? = nil,
        visibleAgentRecords: [InstalledAgentRecord] = [],
        allAgentRecords: [InstalledAgentRecord] = [],
        providerStatuses: [ProviderStatus] = [],
        onOpenAgentDetail: @escaping (InstalledAgentRecord, String?) -> Void = { _, _ in },
        onOpenActivity: @escaping () -> Void = {},
        onHoverAgentDetail: @escaping (InstalledAgentRecord) -> Void = { _ in },
        onHoverActivity: @escaping () -> Void = {},
        onHoverEnd: @escaping () -> Void = {},
        claudeEnabled: Bool = true,
        codexEnabled: Bool = true,
        grokEnabled: Bool = true,
        kiroEnabled: Bool = true
    ) {
        self.claude = claude
        self.codex = codex
        self.grok = grok
        self.kiro = kiro
        self.omp = omp
        self.pi = pi
        self.visibleAgentRecords = visibleAgentRecords
        self.allAgentRecords = allAgentRecords
        self.providerStatuses = providerStatuses
        self.onOpenAgentDetail = onOpenAgentDetail
        self.onOpenActivity = onOpenActivity
        self.onHoverAgentDetail = onHoverAgentDetail
        self.onHoverActivity = onHoverActivity
        self.onHoverEnd = onHoverEnd
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
        self.grokEnabled = grokEnabled
        self.kiroEnabled = kiroEnabled
    }

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private var pendingSources: [String] {
        var pending: [String] = []
        if claudeEnabled, claude == nil { pending.append("Claude") }
        if codexEnabled, codex == nil { pending.append("Codex") }
        if grokEnabled, grok == nil { pending.append("Grok") }
        if kiroEnabled, kiro == nil { pending.append("Kiro") }
        if allAgentRecords.contains(where: { $0.id == .omp }), omp == nil { pending.append("Oh My Pi") }
        if allAgentRecords.contains(where: { $0.id == .pi }), pi == nil { pending.append("Pi") }
        return pending
    }

    private var anyReportReady: Bool {
        claude != nil || codex != nil || grok != nil || kiro != nil || omp != nil || pi != nil
    }

    var body: some View {
        if !anyReportReady {
            VStack(alignment: .leading, spacing: 9) { LoadingQuotaSkeleton() }
                .popoverContentInset()
                .padding(.vertical, 16)
        } else {
            let report = CombinedUsageReport.build(
                claude: claude,
                codex: codex,
                grok: grok,
                kiro: kiro,
                omp: omp,
                pi: pi,
                includeClaude: claudeEnabled,
                includeCodex: codexEnabled,
                includeGrok: grokEnabled,
                includeKiro: kiroEnabled,
                includeOMP: omp != nil || allAgentRecords.contains(where: { $0.id == .omp }),
                includePi: pi != nil || allAgentRecords.contains(where: { $0.id == .pi }))
            let rows = costRows(daily: report.daily)

            AllAgentsOverview(
                report: report,
                pendingSources: pendingSources,
                visibleRecords: visibleAgentRecords,
                aggregateAgentCount: report.includedSourceCount,
                quotaRows: quotaRows,
                costRows: rows,
                configuredRows: configuredRows(costRows: rows),
                onOpenAgent: { id, tab in
                    guard let record = allAgentRecords.first(where: { $0.id == id }) ?? visibleAgentRecords.first(where: { $0.id == id }) else { return }
                    onOpenAgentDetail(record, tab)
                },
                onOpenActivity: onOpenActivity,
                onHoverAgent: { id in
                    guard let record = allAgentRecords.first(where: { $0.id == id }) ?? visibleAgentRecords.first(where: { $0.id == id }) else { return }
                    onHoverAgentDetail(record)
                },
                onHoverActivity: onHoverActivity,
                onHoverEnd: onHoverEnd
            )
        }
    }

    private var quotaRows: [AgentQuotaRow] {
        visibleAgentRecords.compactMap { record -> AgentQuotaRow? in
            guard record.capabilities.contains(.quota) else { return nil }
            guard let status = providerStatus(for: record),
                  let window = ProviderStatusSummary.lowestWindow(status)
            else { return nil }
            return AgentQuotaRow(
                record: record,
                providerName: status.displayName,
                windowLabel: window.label,
                remainingPct: window.remainingPct)
        }
    }

    /// Cost by ăn theo đúng cửa sổ chart (key AppStorage chung với period chips):
    /// tổng per-source tính lại từ `report.daily` thay vì đóng cứng last30.
    @AppStorage("popover.allChartDays") private var allChartDays = 30

    private func costRows(daily: [CombinedDailyUsage]) -> [AgentCostRow] {
        let window = Array(daily.suffix(max(allChartDays, 1)))
        func sums(_ usd: (CombinedDailyUsage) -> Double,
                  _ tokens: (CombinedDailyUsage) -> Int) -> (usd: Double, tokens: Int) {
            (window.reduce(0) { $0 + usd($1) }, window.reduce(0) { $0 + tokens($1) })
        }
        return visibleAgentRecords.compactMap { record in
            guard record.capabilities.contains(.localCost) else { return nil }
            switch record.id {
            case .claude:
                guard let claude else { return nil }
                let s = sums({ $0.claudeUSD }, { $0.claudeTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: claude.todayUSD, tokens: s.tokens, topModel: claude.topModel)
            case .codex:
                guard let codex else { return nil }
                let s = sums({ $0.codexUSD }, { $0.codexTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: codex.todayUSD, tokens: s.tokens, topModel: codex.topModel)
            case .grok:
                guard let grok else { return nil }
                let s = sums({ $0.grokUSD }, { $0.grokTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: grok.todayUSD, tokens: s.tokens, topModel: grok.topModel)
            case .kiro:
                guard let kiro else { return nil }
                let s = sums({ $0.kiroUSD }, { $0.kiroTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: kiro.todayUSD, tokens: s.tokens, topModel: kiro.topModel)
            case .omp:
                guard let omp else { return nil }
                let s = sums({ $0.ompUSD }, { $0.ompTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: omp.todayUSD, tokens: s.tokens, topModel: omp.topModel)
            case .pi:
                guard let pi else { return nil }
                let s = sums({ $0.piUSD }, { $0.piTokens })
                return AgentCostRow(record: record, periodUSD: s.usd, todayUSD: pi.todayUSD, tokens: s.tokens, topModel: pi.topModel)
            default:
                return nil
            }
        }
    }

    private func configuredRows(costRows: [AgentCostRow]) -> [AgentConfiguredRow] {
        let costIDs = Set(costRows.map(\.id))
        let quotaIDs = Set(quotaRows.map(\.id))
        return visibleAgentRecords.filter { record in
            record.capabilities.contains(.nativeConfig) && !costIDs.contains(record.id) && !quotaIDs.contains(record.id)
        }.map { record in
            AgentConfiguredRow(
                record: record,
                detail: vi ? "Chỉ có config" : "Config only",
                evidence: record.evidence.first?.token ?? "")
        }
    }

    private func providerStatus(for record: InstalledAgentRecord) -> ProviderStatus? {
        providerStatuses.first { s in
            record.providerIDs.contains(s.id) || s.id == record.id.rawValue
        }
    }
}

// MARK: - Confidence Badge Row

enum SourceConfidenceState: String, Equatable {
    case live, historyOnly, unavailable

    static func classify(_ confidence: CostHistoryStore.UsageScanConfidence?) -> SourceConfidenceState {
        guard let confidence, confidence.included else { return .unavailable }
        return confidence.live ? .live : .historyOnly
    }
}

enum SourceConfidenceFormat {
    static func freshnessLabel(scannedAt: Date?, now: Date = Date(), preference: String? = nil) -> String? {
        guard let scannedAt else { return nil }
        let vi = L10n.languageCode(preference) == "vi"
        let seconds = max(0, Int(now.timeIntervalSince(scannedAt)))
        let minutes = seconds / 60
        let hours = seconds / 3600
        let days = seconds / 86400
        if days > 0 { return vi ? "\(days) ngày trước" : (days == 1 ? "1 day ago" : "\(days) days ago") }
        if hours > 0 { return vi ? "\(hours) giờ trước" : (hours == 1 ? "1 hour ago" : "\(hours) hours ago") }
        if minutes > 0 { return vi ? "\(minutes) phút trước" : (minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago") }
        if seconds >= 10 { return vi ? "\(seconds) giây trước" : "\(seconds) seconds ago" }
        return vi ? "vừa xong" : "just updated"
    }

    static func compactFreshnessLabel(scannedAt: Date?, now: Date = Date()) -> String? {
        guard let scannedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(scannedAt)))
        let minutes = seconds / 60
        let hours = seconds / 3600
        let days = seconds / 86400
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}

enum CombinedHeatmapIntensity: Equatable {
    case zero, level1, level2, level3, level4

    static func fraction(tokens: Int, maxTokens: Int, isActive: Bool) -> Double {
        guard isActive else { return 0 }
        guard maxTokens > 0 else { return 0.05 }
        if tokens <= 0 { return 0.05 }
        return Double(tokens) / Double(maxTokens)
    }

    static func classify(tokens: Int, maxTokens: Int) -> CombinedHeatmapIntensity {
        if tokens <= 0 || maxTokens <= 0 { return .zero }
        let fraction = Double(tokens) / Double(maxTokens)
        if fraction <= 0.25 { return .level1 }
        if fraction <= 0.50 { return .level2 }
        if fraction <= 0.75 { return .level3 }
        return .level4
    }
}

// MARK: - Budget Forecast Card

struct BudgetForecastCard: View {
    @EnvironmentObject var settings: SettingsStore
    let report: CombinedUsageReport

    private var language: String? { settings.appLanguage }
    private var vi: Bool { L10n.languageCode(language) == "vi" }

    private var forecast: BudgetForecast {
        BudgetForecast.build(
            daily: report.daily,
            budgetUSD: settings.monthlyBudgetUSD,
            period: settings.budgetPeriod)
    }

    var body: some View {
        if settings.monthlyBudgetUSD > 0, !report.hasIncludedCostSource {
            unavailableState
        } else if let budgetUSD = forecast.budgetUSD, let status = forecast.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text((settings.budgetPeriod == .week ? (vi ? "NGÂN SÁCH TUẦN" : "WEEKLY BUDGET") : (vi ? "NGÂN SÁCH THÁNG" : "MONTHLY BUDGET")).uppercased())
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Spacer(minLength: 8)
                    Text(statusLabel(status))
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                        .tracking(0.3)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AllUsageFormat.usd(forecast.periodToDateUSD))
                            .font(.plexMono(24, weight: .bold))
                            .foregroundStyle(VocabbyTheme.primary)
                            .tracking(-0.8)
                        Text("/ \(AllUsageFormat.usd(budgetUSD))")
                            .font(.plexMono(14, weight: .medium))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                    Spacer(minLength: 8)
                    Text((vi ? "dự phóng " : "projected ") + AllUsageFormat.usd(forecast.projectedTotalUSD))
                        .font(.plexMono(12, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                        .multilineTextAlignment(.trailing)
                }

                progressBar(status: status)

                Text(remainingText(budgetUSD: budgetUSD))
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(statusColor(status).opacity(0.9))
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            .popoverContentInset()
            .padding(.vertical, 14)
            .overlay(alignment: .top) { PopoverInsetHairline() }
        }
        // Chưa đặt ngân sách → không render gì (yêu cầu 2026-08-23);
        // thiết lập budget nằm trong Settings → Cài chung.
    }

    private var unavailableState: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text((settings.budgetPeriod == .week
                      ? (vi ? "NGÂN SÁCH TUẦN" : "WEEKLY BUDGET")
                      : (vi ? "NGÂN SÁCH THÁNG" : "MONTHLY BUDGET")).uppercased())
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(L10n.t("budget.perProvider.noData", language))
                    .font(.plexSans(12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 8)
        }
        .popoverContentInset()
        .padding(.vertical, 12)
        .overlay(alignment: .top) { PopoverInsetHairline() }
    }

    private func progressBar(status: BudgetForecastStatus) -> some View {
        let fraction = min(1, max(0, forecast.progressFraction ?? 0))
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(VocabbyTheme.track)
                .frame(height: 5)
            GeometryReader { geo in
                Rectangle()
                    .fill(statusColor(status))
                    .frame(width: geo.size.width * fraction, height: 5)
            }
            .frame(height: 5)
        }
    }

    private func statusLabel(_ status: BudgetForecastStatus) -> String {
        switch status {
        case .onTrack: L10n.t("budget.onTrack", language)
        case .forecastOver: vi ? "Dự phóng vượt" : "Forecast over"
        case .alreadyOver: vi ? "Đã vượt ngân sách" : "Over budget"
        }
    }

    private func statusColor(_ status: BudgetForecastStatus) -> Color {
        switch status {
        case .onTrack: VocabbyTheme.success
        case .forecastOver: Color(red: 0.56, green: 0.37, blue: 0.07) // #8F5F12
        case .alreadyOver: VocabbyTheme.critical
        }
    }

    private func remainingText(budgetUSD: Double) -> String {
        let remaining = forecast.remainingBudgetUSD ?? (budgetUSD - forecast.periodToDateUSD)
        let daysLeft = forecast.daysRemainingInPeriod
        let periodName = settings.budgetPeriod == .week ? (vi ? "hết tuần" : "left in week") : (vi ? "hết tháng" : "left in month")
        if remaining >= 0 {
            return vi
                ? "Còn lại \(AllUsageFormat.usd(remaining)) · \(daysLeft) ngày nữa \(periodName)"
                : "\(AllUsageFormat.usd(remaining)) remaining · \(daysLeft) days \(periodName)"
        }
        return vi
            ? "Vượt \(AllUsageFormat.usd(-remaining)) so với ngân sách"
            : "Over budget by \(AllUsageFormat.usd(-remaining))"
    }
}

// MARK: - Provider Budget Card

struct ProviderBudgetCard: View {
    @EnvironmentObject var settings: SettingsStore
    let providerId: String
    let providerName: String
    let color: Color
    let budgetUSD: Double
    let confidence: CostHistoryStore.UsageScanConfidence?
    let daily: [CombinedDailyUsage]
    let source: CombinedUsageSource

    private var language: String? { settings.appLanguage }
    private var vi: Bool { L10n.languageCode(language) == "vi" }

    private var forecast: BudgetForecast {
        BudgetForecast.build(
            daily: daily,
            budgetUSD: budgetUSD,
            period: settings.budgetPeriod,
            source: source)
    }

    var body: some View {
        // Chưa đặt ngân sách → card ẩn hoàn toàn. Nhánh "noData" chỉ dành cho
        // trường hợp ĐÃ đặt budget nhưng nguồn chi phí không có dữ liệu
        // (trust rule — không hiện on-track giả).
        if budgetUSD > 0, SourceConfidenceState.classify(confidence) == .unavailable {
            VStack(alignment: .leading, spacing: 4) {
                Text((settings.budgetPeriod == .week
                      ? (vi ? "NGÂN SÁCH TUẦN" : "WEEKLY BUDGET")
                      : (vi ? "NGÂN SÁCH THÁNG" : "MONTHLY BUDGET")).uppercased())
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(L10n.t("budget.perProvider.noData", language))
                    .font(.plexSans(12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            .popoverContentInset()
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { PopoverInsetHairline() }
        } else if let status = forecast.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text((settings.budgetPeriod == .week ? (vi ? "NGÂN SÁCH TUẦN" : "WEEKLY BUDGET") : (vi ? "NGÂN SÁCH THÁNG" : "MONTHLY BUDGET")).uppercased())
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Spacer(minLength: 8)
                    Text(statusLabel(status))
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                        .tracking(0.3)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AllUsageFormat.usd(forecast.periodToDateUSD))
                            .font(.plexMono(24, weight: .bold))
                            .foregroundStyle(VocabbyTheme.primary)
                            .tracking(-0.8)
                        Text("/ \(AllUsageFormat.usd(budgetUSD))")
                            .font(.plexMono(14, weight: .medium))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                    Spacer(minLength: 8)
                    Text((vi ? "dự phóng " : "projected ") + AllUsageFormat.usd(forecast.projectedTotalUSD))
                        .font(.plexMono(12, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                        .multilineTextAlignment(.trailing)
                }

                progressBar(status: status)

                Text(remainingText(budgetUSD: budgetUSD))
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(statusColor(status).opacity(0.9))
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            .popoverContentInset()
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { PopoverInsetHairline() }
        }
    }

    private func progressBar(status: BudgetForecastStatus) -> some View {
        let fraction = min(1, max(0, forecast.progressFraction ?? 0))
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(VocabbyTheme.track)
                .frame(height: 5)
            GeometryReader { geo in
                Rectangle()
                    .fill(statusColor(status))
                    .frame(width: geo.size.width * fraction, height: 5)
            }
            .frame(height: 5)
        }
    }

    private func statusLabel(_ status: BudgetForecastStatus) -> String {
        switch status {
        case .onTrack: L10n.t("budget.onTrack", language)
        case .forecastOver: vi ? "Dự phóng vượt" : "Forecast over"
        case .alreadyOver: vi ? "Đã vượt ngân sách" : "Over budget"
        }
    }

    private func statusColor(_ status: BudgetForecastStatus) -> Color {
        switch status {
        case .onTrack: VocabbyTheme.success
        case .forecastOver: Color(red: 0.56, green: 0.37, blue: 0.07)
        case .alreadyOver: VocabbyTheme.critical
        }
    }

    private func remainingText(budgetUSD: Double) -> String {
        let remaining = forecast.remainingBudgetUSD ?? (budgetUSD - forecast.periodToDateUSD)
        let daysLeft = forecast.daysRemainingInPeriod
        let periodName = settings.budgetPeriod == .week ? (vi ? "hết tuần" : "left in week") : (vi ? "hết tháng" : "left in month")
        if remaining >= 0 {
            return vi
                ? "Còn lại \(AllUsageFormat.usd(remaining)) · \(daysLeft) ngày nữa \(periodName)"
                : "\(AllUsageFormat.usd(remaining)) remaining · \(daysLeft) days \(periodName)"
        }
        return vi
            ? "Vượt \(AllUsageFormat.usd(-remaining)) so với ngân sách"
            : "Over budget by \(AllUsageFormat.usd(-remaining))"
    }
}
// MARK: - Combined Chart Card

struct CombinedChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    let claudeHourly: [ClaudeHourlyUsage]
    var summaryAgentCount: Int? = nil
    var onOpenActivity: (() -> Void)? = nil
    /// Hover stats row → panel Hoạt động transient; rời chuột → đóng.
    var onHoverActivity: (() -> Void)? = nil
    var onHoverEnd: (() -> Void)? = nil

    @State private var hoveredDay: CombinedDailyUsage?
    @State private var pinnedDay: CombinedDailyUsage?
    @State private var hoveredHour: ClaudeHourlyUsage?
    @AppStorage("popover.allChartDays") private var periodDays = 30

    private static let periods = [1, 7, 30, 90, 120]

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var is24h: Bool { periodDays == 1 }
    private var periodWindowDays: Int { min(max(periodDays, 1), max(report.daily.count, 1)) }
    private var windowDaily: [CombinedDailyUsage] { Array(report.daily.suffix(periodWindowDays)) }
    private var windowTotals: CombinedWindowTotals { report.totals(lastDays: periodWindowDays) }
    private var maxBarTokens: Int { max(windowDaily.map(\.tokens).max() ?? 0, 1) }

    private var claude24USD: Double { claudeHourly.reduce(0) { $0 + $1.usd } }
    private var claude24Tokens: Int { claudeHourly.reduce(0) { $0 + $1.tokens } }
    private var codexTodayUSD: Double { report.daily.last?.codexUSD ?? 0 }
    private var codexTodayTokens: Int { report.daily.last?.codexTokens ?? 0 }
    private var grokTodayUSD: Double { report.daily.last?.grokUSD ?? 0 }
    private var grokTodayTokens: Int { report.daily.last?.grokTokens ?? 0 }
    private var kiroTodayUSD: Double { report.daily.last?.kiroUSD ?? 0 }
    private var kiroTodayTokens: Int { report.daily.last?.kiroTokens ?? 0 }
    private var ompTodayUSD: Double { report.daily.last?.ompUSD ?? 0 }
    private var ompTodayTokens: Int { report.daily.last?.ompTokens ?? 0 }
    private var piTodayUSD: Double { report.daily.last?.piUSD ?? 0 }
    private var piTodayTokens: Int { report.daily.last?.piTokens ?? 0 }

    private func periodLabel(_ days: Int) -> String {
        days == 1 ? "24h" : "\(days) \(vi ? "ngày" : "days")"
    }

    private func periodShortLabel(_ days: Int) -> String {
        switch days {
        case 1: return "24h"
        case 7: return "7d"
        case 30: return "30d"
        case 90: return "90d"
        case 120: return "120d"
        default: return "\(days)d"
        }
    }

    private var periodTotalUSD: Double {
        is24h
            ? claude24USD + codexTodayUSD + grokTodayUSD + kiroTodayUSD + ompTodayUSD + piTodayUSD
            : windowTotals.usd
    }

    private var periodTotalTokens: Int {
        is24h
            ? claude24Tokens + codexTodayTokens + grokTodayTokens + kiroTodayTokens + ompTodayTokens + piTodayTokens
            : windowTotals.tokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            costHero
                .popoverContentInset()
            Group {
                if is24h {
                    hourChart
                } else {
                    barChart
                }
            }
            .frame(height: 68)
            .popoverContentInset()
            .popoverInkRuleBottom()
            if !is24h {
                chartAxisLabels
                    .popoverContentInset()
            }
            if summaryAgentCount != nil {
                compactStatsRow
                    .popoverContentInset()
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        // Panel ngày đóng (nút × / chuyển surface) → bỏ highlight bar đã ghim.
        .onReceive(NotificationCenter.default.publisher(for: .birdnionDayDetailClosed)) { _ in
            pinnedDay = nil
        }
    }

    private var costHero: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text((vi ? "Tổng chi phí " : "Total cost ") + periodLabel(periodDays))
                    .plexEyebrow(size: 10, color: VocabbyTheme.secondary, tracking: 0.2)
                    .lineLimit(1)
                Text(AllUsageFormat.usd(periodTotalUSD))
                    .font(.plexMono(32, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .tracking(-1)
                    .lineLimit(1)
                Text(summaryAgentCount.map {
                    AllUsageFormat.tokens(periodTotalTokens) + " · \($0) agent"
                } ?? AllUsageFormat.tokens(periodTotalTokens))
                    .font(.plexMono(11))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                periodPicker
                VStack(alignment: .trailing, spacing: 2) {
                    Text(vi ? "Hôm nay" : "Today")
                        .plexEyebrow(size: 9, color: VocabbyTheme.tertiary)
                    Text(AllUsageFormat.usd(report.todayUSD))
                        .font(.plexMono(13, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .lineLimit(1)
                    Text(AllUsageFormat.tokensShort(report.todayTokens))
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(Self.periods, id: \.self) { days in
                let active = periodDays == days
                Button {
                    periodDays = days
                    hoveredDay = nil
                    pinnedDay = nil
                    hoveredHour = nil
                    // Đổi cửa sổ thời gian → ngày ghim không còn thuộc window, đóng panel.
                    NotificationCenter.default.post(name: .birdnionCloseDayDetail, object: nil)
                } label: {
                    Text(periodShortLabel(days))
                        .font(.plexMono(9, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
                        .frame(width: 30, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .fill(active ? VocabbyTheme.primary : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: windowDaily.count > 45 ? 1 : 2) {
                ForEach(windowDaily) { day in
                    let hasTokens = day.tokens > 0
                    let fraction = hasTokens ? CGFloat(Double(day.tokens) / Double(maxBarTokens)) : 0
                    let barHeight = max(geo.size.height * fraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            if hasTokens {
                                let claudeHeight = barHeight * CGFloat(Double(day.claudeTokens) / Double(day.tokens))
                                let codexHeight = barHeight * CGFloat(Double(day.codexTokens) / Double(day.tokens))
                                let grokHeight = barHeight * CGFloat(Double(day.grokTokens) / Double(day.tokens))
                                let kiroHeight = barHeight * CGFloat(Double(day.kiroTokens) / Double(day.tokens))
                                let ompHeight = barHeight * CGFloat(Double(day.ompTokens) / Double(day.tokens))
                                let piHeight = max(0, barHeight - claudeHeight - codexHeight - grokHeight - kiroHeight - ompHeight)
                                Rectangle().fill(VocabbyTheme.chartClaude).frame(height: claudeHeight)
                                Rectangle().fill(VocabbyTheme.chartCodex).frame(height: codexHeight)
                                Rectangle().fill(VocabbyTheme.chartGrok).frame(height: grokHeight)
                                Rectangle().fill(VocabbyTheme.chartKiro).frame(height: kiroHeight)
                                Rectangle().fill(VocabbyTheme.chartOMP).frame(height: ompHeight)
                                Rectangle().fill(VocabbyTheme.chartPi).frame(height: piHeight)
                            } else {
                                Rectangle().fill(VocabbyTheme.hairline).frame(height: 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // Hover mở panel cạnh popover (transient); rời chuột thì
                        // coordinator tự đóng sau debounce nếu chưa ghim.
                        if inside {
                            hoveredDay = day
                            NotificationCenter.default.post(
                                name: .birdnionOpenDayDetail, object: nil,
                                userInfo: ["day": day, "pinned": false,
                                           "windowUSD": periodTotalUSD,
                                           "windowLabel": periodShortLabel(periodDays)])
                        } else if hoveredDay?.id == day.id {
                            hoveredDay = nil
                            NotificationCenter.default.post(
                                name: .birdnionCloseDayDetailTransient, object: nil)
                        }
                    }
                    .onTapGesture {
                        // Click = ghim panel; chỉ nút × trong panel mới đóng được.
                        pinnedDay = day
                        NotificationCenter.default.post(
                            name: .birdnionOpenDayDetail, object: nil,
                            userInfo: ["day": day, "pinned": true,
                                       "windowUSD": periodTotalUSD,
                                       "windowLabel": periodShortLabel(periodDays)])
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))")
                }
            }
        }
    }

    private var hourChart: some View {
        GeometryReader { _ in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(claudeHourly.enumerated()), id: \.offset) { _, hour in
                    Rectangle()
                        .fill(VocabbyTheme.chartClaude)
                        .frame(height: max(3, CGFloat(hour.tokens) / CGFloat(maxBarTokens) * 68))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var chartAxisLabels: some View {
        HStack {
            if let first = windowDaily.first {
                Text(dayLabel(first.date))
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            Spacer(minLength: 8)
            if let last = windowDaily.last {
                Text(dayLabel(last.date))
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private var compactStatsRow: some View {
        let active = windowDaily.filter(\.isActive)
        let peak = windowDaily.map(\.usd).max() ?? 0
        let average = active.isEmpty ? 0 : windowDaily.reduce(0) { $0 + $1.usd } / Double(active.count)
        var streak = 0
        var index = windowDaily.count - 1
        if index >= 0, !windowDaily[index].isActive { index -= 1 }
        while index >= 0, windowDaily[index].isActive {
            streak += 1
            index -= 1
        }
        // Four equal columns with hairline dividers (same pattern as the
        // Activity panel footer) — inline label+value pairs wrapped mid-number
        // at 420px, so each stat gets its own column with lineLimit(1).
        return Button {
            onOpenActivity?()
        } label: {
            HStack(spacing: 0) {
                statColumn(vi ? "CAO NHẤT" : "PEAK", AllUsageFormat.usdWhole(peak))
                statDivider
                statColumn(vi ? "TB/NGÀY" : "AVG/DAY", AllUsageFormat.usdWhole(average))
                statDivider
                statColumn("STREAK", "\(streak) " + (vi ? "ngày" : "days"))
                statDivider
                statColumn(vi ? "NGÀY ACTIVE" : "ACTIVE DAYS", "\(active.count)/\(windowDaily.count)")
                Text("›")
                    .font(.plexMono(12))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { onHoverActivity?() } else { onHoverEnd?() }
        }
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
            Text(value)
                .font(.plexMono(13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statDivider: some View {
        VocabbyTheme.hairline
            .frame(width: 1)
            .padding(.vertical, 3)
            .padding(.trailing, 10)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

}

/// Side-panel drill-down for one chart day — hover shows it transiently,
/// click pins it (then only the × button closes it). Full breakdown:
/// hero (weekday + big $ + share of window) → per-agent split → per-model list.
struct DayDetailPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let day: CombinedDailyUsage
    let pinned: Bool
    /// Tổng USD của cửa sổ chart đang xem — cho dòng "chiếm X% của kỳ".
    var windowUSD: Double = 0
    var windowLabel: String = ""

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private struct AgentSlice: Identifiable {
        let id: String
        let name: String
        let color: Color
        let usd: Double
        let tokens: Int
    }

    private var slices: [AgentSlice] {
        [
            AgentSlice(id: "claude", name: "Claude Code", color: VocabbyTheme.chartClaude,
                       usd: day.claudeUSD, tokens: day.claudeTokens),
            AgentSlice(id: "codex", name: "Codex CLI", color: VocabbyTheme.chartCodex,
                       usd: day.codexUSD, tokens: day.codexTokens),
            AgentSlice(id: "grok", name: "Grok CLI", color: VocabbyTheme.chartGrok,
                       usd: day.grokUSD, tokens: day.grokTokens),
            AgentSlice(id: "kiro", name: "Kiro", color: VocabbyTheme.chartKiro,
                       usd: day.kiroUSD, tokens: day.kiroTokens),
            AgentSlice(id: "omp", name: "Oh My Pi", color: VocabbyTheme.chartOMP,
                       usd: day.ompUSD, tokens: day.ompTokens),
            AgentSlice(id: "pi", name: "Pi Agent", color: VocabbyTheme.chartPi,
                       usd: day.piUSD, tokens: day.piTokens),
        ]
        .filter { $0.usd > 0 || $0.tokens > 0 }
        .sorted { $0.usd > $1.usd }
    }

    private var models: [CombinedModelCost] { day.models.sorted { $0.usd > $1.usd } }
    private static let maxModelRows = 10

    private func pct(_ usd: Double, of total: Double) -> Int {
        total > 0 ? Int((usd / total * 100).rounded()) : 0
    }

    private var weekdayLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day.date).uppercased()
    }

    var body: some View {
        // Height auto theo nội dung — panel NSHostingController fit đúng
        // chiều cao view, không scroll; model list đã cap 10 + "+N" nên
        // chiều cao luôn nằm trong màn hình.
        VStack(alignment: .leading, spacing: 0) {
            header
            // Chrome rule top: đậm hơn hairline, full-bleed (quy ước 2026-08-24).
            VocabbyTheme.chromeRule.frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                agentSection
                if !models.isEmpty {
                    VocabbyTheme.hairline.frame(height: 1)
                    modelSection
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: 340)
        .background(VocabbyTheme.background)
        // Bo góc 3pt cứng ở tầng SwiftUI — window nền clear nên đây là hình
        // dạng thật của panel, không bị corner mask hệ thống lấn.
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(weekdayLabel) · \(L10n.dayMonth(day.date, preference: settings.appLanguage).uppercased())")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .tracking(0.6)
                Spacer(minLength: 8)
                if pinned {
                    // Nút đóng theo ngôn ngữ Instrument: ô vuông viền hairline
                    // như các nút icon 26×26 ở header popover.
                    Button {
                        NotificationCenter.default.post(name: .birdnionCloseDayDetail, object: nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.secondary)
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                                    .stroke(VocabbyTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(vi ? "Đóng" : "Close")
                } else {
                    Text(vi ? "CLICK ĐỂ GHIM" : "CLICK TO PIN")
                        .font(.plexMono(8, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .tracking(0.5)
                }
            }
            Text(AllUsageFormat.usd(day.usd))
                .font(.plexMono(26, weight: .bold))
                .foregroundStyle(VocabbyTheme.primary)
                .tracking(-0.9)
            HStack(spacing: 6) {
                Text(AllUsageFormat.tokens(day.tokens))
                    .font(.plexMono(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                if windowUSD > 0, !windowLabel.isEmpty {
                    Text("·")
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(vi
                         ? "\(pct(day.usd, of: windowUSD))% của \(windowLabel)"
                         : "\(pct(day.usd, of: windowUSD))% of \(windowLabel)")
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vi ? "THEO AGENT" : "BY AGENT")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .tracking(0.9)
            // Thanh phân bố chia theo chi phí trong ngày (312 = 340 - inset 2×14).
            if day.usd > 0 {
                ZStack(alignment: .leading) {
                    VocabbyTheme.track
                    HStack(spacing: 0) {
                        ForEach(slices) { slice in
                            Rectangle()
                                .fill(slice.color)
                                .frame(width: max(1, CGFloat(slice.usd / day.usd) * 312))
                        }
                    }
                }
                .frame(height: 5)
                .clipped()
            }
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    Rectangle().fill(slice.color).frame(width: 3, height: 12)
                    Text(slice.name)
                        .font(.plexSans(12, weight: .medium))
                        .foregroundStyle(VocabbyTheme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(pct(slice.usd, of: day.usd))%")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Text(AllUsageFormat.tokensAndUSD(slice.tokens, slice.usd))
                        .font(.plexMono(11, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.secondary)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 12)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((vi ? "MODEL" : "MODELS") + " (\(models.count))")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .tracking(0.9)
            let maxUSD = max(models.first?.usd ?? 0, 0.0001)
            ForEach(Array(models.prefix(Self.maxModelRows))) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(sliceColor(m.source))
                            .frame(width: 6, height: 6)
                        Text(AllUsageFormat.shortName(m.name))
                            .font(.plexSans(11))
                            .foregroundStyle(VocabbyTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(AllUsageFormat.tokensAndUSD(m.tokens, m.usd))
                            .font(.plexMono(10))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    // Mini bar so sánh giữa các model trong ngày.
                    VocabbyTheme.track
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(sliceColor(m.source))
                                .frame(width: max(2, CGFloat(m.usd / maxUSD) * 312), height: 3)
                        }
                }
                .padding(.vertical, 2)
            }
            let rest = models.dropFirst(Self.maxModelRows)
            if !rest.isEmpty {
                HStack(spacing: 8) {
                    Rectangle().fill(VocabbyTheme.track).frame(width: 6, height: 6)
                    Text(vi ? "+\(rest.count) model khác" : "+\(rest.count) more models")
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    Spacer(minLength: 8)
                    Text(AllUsageFormat.tokensAndUSD(
                        rest.reduce(0) { $0 + $1.tokens },
                        rest.reduce(0) { $0 + $1.usd }))
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func sliceColor(_ source: String) -> Color {
        switch source {
        case "claude": return VocabbyTheme.chartClaude
        case "codex": return VocabbyTheme.chartCodex
        case "grok": return VocabbyTheme.chartGrok
        case "kiro": return VocabbyTheme.chartKiro
        case "omp": return VocabbyTheme.chartOMP
        case "pi": return VocabbyTheme.chartPi
        default: return VocabbyTheme.chartCodex
        }
    }
}

// MARK: - 120d Heatmap Card

struct CombinedHeatmapCard: View {
    @EnvironmentObject var settings: SettingsStore
    let report: CombinedUsageReport

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(vi ? "LỊCH SỬ HOẠT ĐỘNG 120 NGÀY" : "120-DAY ACTIVITY HISTORY")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text("\(report.activeDays) \(vi ? "ngày active" : "active days")")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }

            // Grid of 120 daily cells
            let days = report.daily
            let maxTokens = max(days.map(\.tokens).max() ?? 1, 1)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 20), spacing: 2) {
                ForEach(days) { day in
                    let fraction = day.tokens > 0 ? Double(day.tokens) / Double(maxTokens) : 0
                    Rectangle()
                        .fill(colorForFraction(fraction))
                        .frame(height: 8)
                }
            }
        }
        .popoverContentInset()
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { PopoverInsetHairline() }
    }

    private func colorForFraction(_ f: Double) -> Color {
        if f <= 0 { return VocabbyTheme.track }
        if f <= 0.25 { return Color(red: 0.84, green: 0.87, blue: 0.95) }
        if f <= 0.50 { return Color(red: 0.66, green: 0.74, blue: 0.91) }
        if f <= 0.75 { return Color(red: 0.43, green: 0.55, blue: 0.86) }
        return Color(red: 0.12, green: 0.31, blue: 0.85)
    }
}

// MARK: - Top Models Card

struct CombinedTopModelsCard: View {
    @EnvironmentObject var settings: SettingsStore
    let report: CombinedUsageReport
    @AppStorage("popover.allChartDays") private var periodDays = 30

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        let (models, _) = report.topModels(lastDays: periodDays)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(vi ? "MODEL HÀNG ĐẦU" : "TOP MODELS")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)

                ForEach(models) { model in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sourceColor(model.source))
                            .frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.plexSans(12))
                            .foregroundStyle(VocabbyTheme.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(AllUsageFormat.tokens(model.tokens))
                            .font(.plexMono(10))
                            .foregroundStyle(VocabbyTheme.tertiary)
                        Text(AllUsageFormat.usd(model.usd))
                            .font(.plexMono(11, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            .popoverContentInset()
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { PopoverInsetHairline() }
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "claude": VocabbyTheme.chartClaude
        case "codex": VocabbyTheme.chartCodex
        case "grok": VocabbyTheme.chartGrok
        case "kiro": VocabbyTheme.chartKiro
        case "omp": VocabbyTheme.chartOMP
        case "pi": VocabbyTheme.chartPi
        default: VocabbyTheme.tertiary
        }
    }
}

// MARK: - Formatting Helpers

enum AllUsageFormat {
    static func usd(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        if amount >= 1000 {
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
        } else {
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
        }
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    /// Whole-dollar variant for tight stat strips ("$425", "$1,208") where
    /// cents would force mid-number wrapping.
    static func usdWhole(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.0f", amount)
    }

    static func tokens(_ count: Int) -> String {
        if count <= 0 { return "0 tokens" }
        if count >= 1_000_000_000 {
            return String(format: "%.1fB tokens", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk tokens", Double(count) / 1_000)
        }
        return "\(count) tokens"
    }

    static func tokensShort(_ count: Int) -> String {
        if count <= 0 { return "0" }
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000
            if m.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fM", m)
            }
            return String(format: "%.1fM", m)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func tokensAndUSD(_ tokens: Int, _ usd: Double) -> String {
        "\(self.tokens(tokens)) · \(self.usd(usd))"
    }

    static func shortName(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            return String(model.dropFirst(7))
        }
        return model
    }
}
