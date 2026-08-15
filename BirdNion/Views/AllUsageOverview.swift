import SwiftUI

// MARK: - Combined usage model

/// One calendar day of combined Claude Code CLI + Codex + Grok usage. Kept
/// per-source so the stacked chart and hover detail can split the bar by origin.
struct CombinedDailyUsage: Equatable, Identifiable {
    let date: Date   // startOfDay in local tz
    let claudeUSD: Double
    let claudeTokens: Int
    let codexUSD: Double
    let codexTokens: Int
    let grokUSD: Double
    let grokTokens: Int
    /// Per-model split for this day (all sources, token-sorted). Feeds the
    /// chart hover / heatmap pinned-day breakdown so "Claude" isn't a single
    /// opaque line. Defaulted so call sites without model data still compile.
    var models: [CombinedModelCost] = []

    var usd: Double { claudeUSD + codexUSD + grokUSD }
    var tokens: Int { claudeTokens + codexTokens + grokTokens }
    var isActive: Bool { usd > 0 || tokens > 0 }
    var id: Date { date }

    init(date: Date,
         claudeUSD: Double, claudeTokens: Int,
         codexUSD: Double, codexTokens: Int,
         grokUSD: Double = 0, grokTokens: Int = 0,
         models: [CombinedModelCost] = []) {
        self.date = date
        self.claudeUSD = claudeUSD
        self.claudeTokens = claudeTokens
        self.codexUSD = codexUSD
        self.codexTokens = codexTokens
        self.grokUSD = grokUSD
        self.grokTokens = grokTokens
        self.models = models
    }
}

/// One model's summed cost across the combined window, tagged with its source
/// so the row can carry the provider brand colour.
struct CombinedModelCost: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    /// "claude" | "codex" | "grok" — drives the brand dot/bar colour.
    let source: String
    var id: String { "\(source):\(name)" }
}

/// Cross-provider aggregation of the Claude Code CLI and Codex local usage
/// reports. Pure value type + pure `build` so the merge/streak math is
/// unit-testable without any file I/O.
struct CombinedUsageReport: Equatable {
    /// Calendar-today totals, taken from the daily buckets — NOT from
    /// `CodexUsageReport.todayUSD`, which is the most recent *active* day.
    let todayUSD: Double
    let todayTokens: Int
    /// Strict 30-day totals (sum of each source's own last30 fields, so the
    /// All tab always matches the per-provider tabs).
    let last30USD: Double
    let last30Tokens: Int
    /// Full-window (120d) totals for the heatmap header.
    let totalUSD: Double
    let totalTokens: Int
    /// Contiguous daily buckets, oldest → newest, ending today.
    let daily: [CombinedDailyUsage]
    /// Top models by summed tokens across the window, both sources merged.
    /// Approximate: each scanner only records the top 5 models per day.
    let topModels: [CombinedModelCost]
    let peakDayUSD: Double
    let peakDayDate: Date?
    /// Window total divided by the number of active days.
    let avgPerActiveDayUSD: Double
    let activeDays: Int
    /// Consecutive active days counted back from the most recent activity;
    /// an inactive "today" doesn't break the streak (the day isn't over yet).
    let streakDays: Int
    /// Data Confidence Pass metadata per source, gated by the same
    /// `includeX` flags as everything else above — nil when the source is
    /// disabled OR its scan hasn't landed yet (both cases render no badge;
    /// only a landed, enabled report carries real confidence, which may
    /// itself classify as `included == false` for a source with no data at
    /// all). See `SourceConfidenceState.classify`.
    let claudeConfidence: CostHistoryStore.UsageScanConfidence?
    let codexConfidence: CostHistoryStore.UsageScanConfidence?
    let grokConfidence: CostHistoryStore.UsageScanConfidence?

    var isEmpty: Bool { activeDays == 0 }

    static func build(claude: ClaudeUsageReport?,
                      codex: CodexUsageReport?,
                      grok: GrokUsageReport? = nil,
                      includeClaude: Bool = true,
                      includeCodex: Bool = true,
                      includeGrok: Bool = true,
                      calendar: Calendar = .current,
                      now: Date = Date(),
                      windowDays: Int = 120) -> CombinedUsageReport {
        let startOfToday = calendar.startOfDay(for: now)
        let includedClaude = includeClaude ? claude : nil
        let includedCodex = includeCodex ? codex : nil
        let includedGrok = includeGrok ? grok : nil

        // Re-normalize sources onto startOfDay keys before merging —
        // Claude's older buckets were built with -86 400 s steps, which can
        // drift one hour off across a DST transition. Per-day model splits
        // are collected in the same pass for the day-detail breakdown.
        let claudeDays = dayTotals(from: includedClaude?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let codexDays = dayTotals(from: includedCodex?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)
        let grokDays = dayTotals(from: includedGrok?.daily.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        } ?? [], calendar: calendar)

        var daily: [CombinedDailyUsage] = []
        daily.reserveCapacity(windowDays)
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let c = claudeDays.totals[day] ?? (0, 0)
            let x = codexDays.totals[day] ?? (0, 0)
            let g = grokDays.totals[day] ?? (0, 0)
            daily.append(CombinedDailyUsage(
                date: day,
                claudeUSD: c.usd, claudeTokens: c.tokens,
                codexUSD: x.usd, codexTokens: x.tokens,
                grokUSD: g.usd, grokTokens: g.tokens,
                models: mergedModelCosts(
                    claude: claudeDays.models[day] ?? [:],
                    codex: codexDays.models[day] ?? [:],
                    grok: grokDays.models[day] ?? [:])))
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
            // Skip an inactive today; any older gap ends the streak.
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
                grok: foldModels(grokDays.models)).prefix(6))

        return CombinedUsageReport(
            todayUSD: today?.usd ?? 0,
            todayTokens: today?.tokens ?? 0,
            last30USD: (includedClaude?.last30USD ?? 0)
                + (includedCodex?.last30USD ?? 0)
                + (includedGrok?.last30USD ?? 0),
            last30Tokens: (includedClaude?.last30Tokens ?? 0)
                + (includedCodex?.last30Tokens ?? 0)
                + (includedGrok?.last30Tokens ?? 0),
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
            grokConfidence: includedGrok?.scanConfidence)
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
            for m in row.models {
                var mv = byModel[m.0] ?? (0, 0)
                mv.usd += m.1
                mv.tokens += m.2
                byModel[m.0] = mv
            }
            index.models[day] = byModel
        }
        return index
    }

    private static func foldModels(
        _ byDay: [Date: [String: (usd: Double, tokens: Int)]]
    ) -> [String: (usd: Double, tokens: Int)] {
        var out: [String: (usd: Double, tokens: Int)] = [:]
        for byModel in byDay.values {
            for (name, m) in byModel {
                var v = out[name] ?? (0, 0)
                v.usd += m.usd
                v.tokens += m.tokens
                out[name] = v
            }
        }
        return out
    }

    /// Folds per-source model accumulators into one token-sorted list, dropping
    /// zero rows. Shared by the per-day split and the window-wide top models.
    private static func mergedModelCosts(
        claude: [String: (usd: Double, tokens: Int)],
        codex: [String: (usd: Double, tokens: Int)],
        grok: [String: (usd: Double, tokens: Int)] = [:]
    ) -> [CombinedModelCost] {
        var merged: [CombinedModelCost] = claude.map {
            CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "claude")
        }
        merged += codex.map {
            CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "codex")
        }
        merged += grok.map {
            CombinedModelCost(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens, source: "grok")
        }
        merged.removeAll { $0.usd <= 0 && $0.tokens <= 0 }
        merged.sort {
            $0.tokens == $1.tokens ? $0.usd > $1.usd : $0.tokens > $1.tokens
        }
        return merged
    }
}

/// Per-source totals over a trailing calendar-day window — feeds the period
/// picker on the combined chart card.
struct CombinedWindowTotals: Equatable {
    let usd: Double
    let tokens: Int
    let claudeUSD: Double
    let claudeTokens: Int
    let codexUSD: Double
    let codexTokens: Int
    let grokUSD: Double
    let grokTokens: Int
}

extension CombinedUsageReport {
    /// Sums the trailing `days` buckets (clamped to the available window).
    /// For 30 days this matches the per-provider tabs exactly: scanners
    /// bucket by the same local calendar days these buckets were built from.
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
            grokTokens: window.reduce(0) { $0 + $1.grokTokens })
    }

    /// Top models over the chart period (`1` = calendar today only).
    /// Does not touch heatmap stats — only folds `daily` model splits.
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

// MARK: - Phase 2: monthly budget forecast (pure)

/// Where month-to-date spend sits relative to a configured budget.
/// `alreadyOver` takes precedence over `forecastOver` — a month that has
/// already overshot is reported as over, not merely "on track to overshoot".
enum MonthlyForecastStatus: Equatable {
    case onTrack
    case forecastOver
    case alreadyOver
}

/// Linear month-to-date spend projection for the All-tab budget card.
/// Day-granularity (`CostHistoryStore` only has day-resolution buckets),
/// unlike `WindowPace`'s sub-day precision for quota windows. Pure value
/// type + pure `build`, no SwiftUI/file-I/O dependency — takes `now` and
/// `calendar` explicitly so every calendar edge case is deterministic.
struct MonthlyForecast: Equatable {
    let monthToDateUSD: Double
    /// 1...`daysInMonth` — "today" always counts as elapsed.
    let daysElapsed: Int
    /// Calendar-aware length of the current month (28/29/30/31).
    let daysInMonth: Int
    let dailyAverageUSD: Double
    let projectedTotalUSD: Double
    /// Normalized: `nil` when the configured budget is missing, zero,
    /// negative, or non-finite — the card hides itself in that state.
    let budgetUSD: Double?
    /// `nil` exactly when `budgetUSD` is `nil`.
    let status: MonthlyForecastStatus?

    var remainingBudgetUSD: Double? { budgetUSD.map { $0 - monthToDateUSD } }
    /// Full calendar days left after today until month-end (0 on the last day).
    var daysRemainingInMonth: Int { max(0, daysInMonth - daysElapsed) }
    /// Month-to-date spend as a fraction of budget (can exceed 1 when over).
    /// `nil` when no budget is configured.
    var progressFraction: Double? {
        guard let budgetUSD, budgetUSD > 0 else { return nil }
        return monthToDateUSD / budgetUSD
    }

    static func build(daily: [CombinedDailyUsage],
                      budgetUSD: Double?,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> MonthlyForecast {
        // Same year AND month — `toGranularity: .month` compares era/year/
        // month together, so a bucket from last December never leaks into
        // a January month-to-date sum even though both are "December" or
        // "January" by month-number alone across a year boundary.
        // "Month-to-date" is strictly through local today: a same-month
        // bucket dated after today (a caller passing malformed/preview data)
        // is excluded rather than inflating a projection that hasn't
        // happened yet. A non-finite (NaN/Infinity) or negative day `usd`
        // is ignored rather than poisoning the whole sum to NaN or letting
        // a bad negative value quietly shrink real spend.
        let startOfToday = calendar.startOfDay(for: now)
        let monthToDateUSD = daily
            .filter {
                calendar.isDate($0.date, equalTo: now, toGranularity: .month)
                    && $0.date <= startOfToday
                    && $0.usd.isFinite && $0.usd >= 0
            }
            .reduce(0) { $0 + $1.usd }

        let daysElapsed = max(1, calendar.component(.day, from: now))
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dailyAverageUSD = monthToDateUSD / Double(daysElapsed)
        let projectedTotalUSD = dailyAverageUSD * Double(daysInMonth)

        let normalizedBudget: Double? = {
            guard let budgetUSD, budgetUSD.isFinite, budgetUSD > 0 else { return nil }
            return budgetUSD
        }()
        let status: MonthlyForecastStatus? = normalizedBudget.map { budget in
            if monthToDateUSD > budget { return .alreadyOver }
            if projectedTotalUSD > budget { return .forecastOver }
            return .onTrack
        }

        return MonthlyForecast(
            monthToDateUSD: monthToDateUSD,
            daysElapsed: daysElapsed,
            daysInMonth: daysInMonth,
            dailyAverageUSD: dailyAverageUSD,
            projectedTotalUSD: projectedTotalUSD,
            budgetUSD: normalizedBudget,
            status: status)
    }
}

// MARK: - All tab root

/// Body of the "All" pseudo-provider tab: combined totals + stacked 30-day
/// chart, 120-day heatmap, and the merged top-models list. Sources that are
/// disabled or still scanning simply contribute nothing (nil report).
struct AllUsageOverview: View {
    @EnvironmentObject var settings: SettingsStore

    let claude: ClaudeUsageReport?
    let codex: CodexUsageReport?
    let grok: GrokUsageReport?
    /// Which sources are enabled in Settings — a disabled source's nil
    /// report means "not applicable", not "still scanning".
    var claudeEnabled: Bool = true
    var codexEnabled: Bool = true
    var grokEnabled: Bool = true

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    /// Enabled sources whose scan hasn't landed yet.
    private var pendingSources: [String] {
        var pending: [String] = []
        if claudeEnabled, claude == nil { pending.append("Claude") }
        if codexEnabled, codex == nil { pending.append("Codex") }
        if grokEnabled, grok == nil { pending.append("Grok") }
        return pending
    }

    private var anyReportReady: Bool {
        claude != nil || codex != nil || grok != nil
    }

    var body: some View {
        if !anyReportReady {
            // All enabled scans still in flight — same skeleton the provider card uses.
            VStack(alignment: .leading, spacing: 9) { LoadingQuotaSkeleton() }
                .popoverContentInset()
                .padding(.vertical, 16)
        } else {
            // Render whatever already landed; other sources fold in when
            // their scan finishes (the hint below says which are still running).
            let report = CombinedUsageReport.build(
                claude: claude,
                codex: codex,
                grok: grok,
                includeClaude: claudeEnabled,
                includeCodex: codexEnabled,
                includeGrok: grokEnabled)
            if !pendingSources.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VocabbyTheme.blue)
                        .frame(width: 10, height: 10)
                    Text((vi ? "Đang quét " : "Scanning ")
                         + pendingSources.joined(separator: ", ") + "…")
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .popoverContentInset()
            }
            // Design order: chart/share → confidence → budget → heatmap → models.
            // Confidence + budget stay visible even on a zero-spend month
            // (freshness describes the scan; budget card hides itself when
            // monthlyBudgetUSD is unset).
            if report.isEmpty {
                // No top hairline — ProviderTabs already draws the section rule.
                Text(vi ? "Chưa có dữ liệu sử dụng trong 120 ngày qua."
                        : "No usage recorded in the last 120 days.")
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .popoverContentInset()
                    .padding(.vertical, 16)
            } else {
                CombinedChartCard(report: report, claudeHourly: claude?.hourly ?? [])
            }
            SourceConfidenceBadgeRow(report: report)
            BudgetForecastCard(report: report)
            if !report.isEmpty {
                // Heatmap stays fixed 120d — not tied to chart period chips.
                CombinedHeatmapCard(report: report)
                // Top models follow chart period (24h / 7d / 30d / 90d / 120d).
                CombinedTopModelsCard(report: report)
            }
        }
    }
}

// MARK: - Data Confidence badges (per-source)

/// Classified confidence state for the All-tab per-source badge — pure,
/// derived from `CostHistoryStore.UsageScanConfidence` with no SwiftUI
/// dependency so it's directly unit-testable.
enum SourceConfidenceState: Equatable {
    case live
    case historyOnly
    case unavailable

    static func classify(_ confidence: CostHistoryStore.UsageScanConfidence) -> SourceConfidenceState {
        guard confidence.included else { return .unavailable }
        return confidence.live ? .live : .historyOnly
    }

    /// `AppLocalizer` key for the badge's short state tag — design uses
    /// uppercase mono `LIVE` / `LỊCH SỬ` (see `confidence.state.*`).
    var localizationKey: String {
        switch self {
        case .live: return "confidence.state.live"
        case .historyOnly: return "confidence.state.historyOnly"
        case .unavailable: return "confidence.state.unavailable"
        }
    }
}

/// Pure freshness text for a scan timestamp. `nil` when there has never been
/// a successful live scan for the source — a `cost-history.json` written
/// before the Data Confidence Pass decodes with no timestamp at all, and a
/// brand-new source that only just started history-only never had one
/// either. Deterministic: takes `now` explicitly instead of reading the
/// wall clock, so it's unit-testable.
enum SourceConfidenceFormat {
    static func freshnessLabel(scannedAt: Date?, now: Date = Date(), preference: String? = nil) -> String? {
        scannedAt.map { L10n.relativeUpdated(from: $0, now: now, preference: preference) }
    }

    /// Dense, locale-neutral timestamp for tests / fixed-width rows.
    static func compactFreshnessLabel(scannedAt: Date?, now: Date = Date()) -> String? {
        guard let scannedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(scannedAt)))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    /// Design-style freshness after the LIVE / LỊCH SỬ tag: "vừa xong",
    /// "2 phút", "3 giờ" — no "trước" suffix so the row stays dense.
    static func badgeFreshnessLabel(scannedAt: Date?,
                                    now: Date = Date(),
                                    preference: String? = nil) -> String? {
        guard let scannedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(scannedAt)))
        if seconds < 60 { return L10n.t("confidence.fresh.justNow", preference) }
        if seconds < 3_600 {
            return L10n.f("confidence.fresh.minutes", preference, seconds / 60)
        }
        if seconds < 86_400 {
            return L10n.f("confidence.fresh.hours", preference, seconds / 3_600)
        }
        return L10n.f("confidence.fresh.days", preference, seconds / 86_400)
    }
}

/// Compact per-source Data Confidence row: one badge per source that is both
/// enabled AND has a landed report (`CombinedUsageReport.build` already nils
/// a disabled or still-pending source's confidence, so both collapse to "no
/// badge" here — a pending source keeps relying on the "Scanning…" hint
/// above instead of showing a misleading "unavailable" badge). Rendered even
/// when the combined report has no active days: freshness describes the
/// scan, not whether it found spend. Provider names become logos and freshness
/// is abbreviated so all landed sources stay on one fixed-width popover row.
struct SourceConfidenceBadgeRow: View {
    @EnvironmentObject var settings: SettingsStore
    let report: CombinedUsageReport

    private var language: String { settings.appLanguage }

    private var entries: [(id: String, name: String, color: Color, confidence: CostHistoryStore.UsageScanConfidence)] {
        [
            ("claude", "Claude", VocabbyTheme.chartClaude, report.claudeConfidence),
            ("codex", "Codex", VocabbyTheme.chartCodex, report.codexConfidence),
            ("grok", "Grok", VocabbyTheme.chartGrok, report.grokConfidence),
        ].compactMap { id, name, color, confidence in
            confidence.map { (id, name, color, $0) }
        }
    }

    var body: some View {
        if !entries.isEmpty {
            // No top hairline; tight gap under share rows / chart.
            HStack(spacing: 8) { badges }
                .frame(maxWidth: .infinity, alignment: .leading)
                .popoverContentInset()
                .padding(.top, 2)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var badges: some View {
        ForEach(entries, id: \.id) { entry in
            badge(id: entry.id, name: entry.name, color: entry.color, confidence: entry.confidence)
        }
    }

    private func badge(id: String,
                       name: String,
                       color: Color,
                       confidence: CostHistoryStore.UsageScanConfidence) -> some View {
        let state = SourceConfidenceState.classify(confidence)
        let tag = L10n.t(state.localizationKey, language)
        let fullFreshness = SourceConfidenceFormat.freshnessLabel(
            scannedAt: confidence.scannedAt, preference: language)
        let badgeFresh = SourceConfidenceFormat.badgeFreshnessLabel(
            scannedAt: confidence.scannedAt, preference: language)
        let help = fullFreshness.map { L10n.f("confidence.badgeHelp", language, name, tag, $0) }
            ?? L10n.f("confidence.badgeHelpNoFreshness", language, name, tag)
        // Old compact badge: provider logo + LIVE/HISTORY + short freshness
        // (no text name — logos identify the source on the dense row).
        return HStack(spacing: 4) {
            ProviderLogoMark(id: id, tint: color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(tag)
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(stateColor(state))
                .tracking(0.4)
            if let badgeFresh {
                Text("·")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(badgeFresh.uppercased())
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(stateColor(state).opacity(0.85))
                    .tracking(0.3)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    private func stateColor(_ state: SourceConfidenceState) -> Color {
        switch state {
        case .live: return VocabbyTheme.success
        case .historyOnly: return VocabbyTheme.warningFill // design amber HISTORY
        case .unavailable: return VocabbyTheme.disabled
        }
    }
}

// MARK: - Phase 2: budget vs. forecast card

/// Month-to-date spend vs. a user-configured monthly budget, plus a linear
/// forecast to month-end (`MonthlyForecast`). Passive read-out only — no
/// notifications, no scheduler. Hidden entirely when no budget is
/// configured (`SettingsStore.monthlyBudgetUSD <= 0`); shown even when this
/// month's spend is zero, same as the confidence badge row above.
struct BudgetForecastCard: View {
    @EnvironmentObject var settings: SettingsStore
    let report: CombinedUsageReport

    private var language: String { settings.appLanguage }
    private var forecast: MonthlyForecast {
        MonthlyForecast.build(daily: report.daily, budgetUSD: settings.monthlyBudgetUSD)
    }

    var body: some View {
        if let budgetUSD = forecast.budgetUSD, let status = forecast.status {
            // Design: title + status on one row; big "$MTD / $budget" left,
            // "dự phóng $X" right; progress; "CÒN LẠI $Y · N NGÀY NỮA HẾT THÁNG".
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("budget.title", language))
                        .plexEyebrow(size: 9, color: VocabbyTheme.secondary, tracking: 0.3)
                    Spacer(minLength: 8)
                    Text(statusLabel(status))
                        .plexEyebrow(size: 9, color: statusColor(status), tracking: 0.4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AllUsageFormat.usd(forecast.monthToDateUSD))
                            .font(.plexMono(24, weight: .bold))
                            .foregroundStyle(VocabbyTheme.primary)
                        Text("/ \(AllUsageFormat.usd(budgetUSD))")
                            .font(.plexMono(14, weight: .medium))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(L10n.f("budget.projectedAmount", language,
                                AllUsageFormat.usd(forecast.projectedTotalUSD)))
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
            .padding(.vertical, 16)
            .popoverHairlineTop(VocabbyTheme.inkRule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(budgetUSD: budgetUSD, status: status))
        }
    }

    private func progressBar(status: MonthlyForecastStatus) -> some View {
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

    private func statusLabel(_ status: MonthlyForecastStatus) -> String {
        switch status {
        case .onTrack: L10n.t("budget.onTrack", language)
        case .forecastOver: L10n.t("budget.forecastOver", language)
        case .alreadyOver: L10n.t("budget.alreadyOver", language)
        }
    }

    private func statusColor(_ status: MonthlyForecastStatus) -> Color {
        switch status {
        case .onTrack: VocabbyTheme.success
        case .forecastOver: VocabbyTheme.yellow
        case .alreadyOver: VocabbyTheme.critical
        }
    }

    private func remainingText(budgetUSD: Double) -> String {
        let remaining = forecast.remainingBudgetUSD ?? (budgetUSD - forecast.monthToDateUSD)
        let daysLeft = forecast.daysRemainingInMonth
        if remaining >= 0 {
            return L10n.f("budget.remainingWithDays", language,
                          AllUsageFormat.usd(remaining), daysLeft)
        }
        return L10n.f("budget.overBy", language, AllUsageFormat.usd(-remaining))
    }

    private func accessibilityText(budgetUSD: Double, status: MonthlyForecastStatus) -> String {
        L10n.f("budget.a11y", language,
               AllUsageFormat.usd(forecast.monthToDateUSD),
               AllUsageFormat.usd(forecast.projectedTotalUSD),
               AllUsageFormat.usd(budgetUSD),
               statusLabel(status))
    }
}

// MARK: - Combined chart card (stacked bars)

/// Mirrors `CodexUsageChartCard`'s layout, but each bar is stacked from the
/// Claude + Codex portions of the day so the split is visible at a glance.
struct CombinedChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    /// Claude's trailing-24 h hour buckets — drives the "24h" period. Codex
    /// logs only have day resolution, so that period's bars are Claude-only.
    let claudeHourly: [ClaudeHourlyUsage]
    @State private var hoveredDay: CombinedDailyUsage?
    /// Day pinned by clicking a chart bar — the only thing that shows the
    /// per-source / model breakdown. Default is nil (hidden). Click the same
    /// bar again to clear; hover only highlights the bar (never opens detail).
    @State private var pinnedDay: CombinedDailyUsage?
    @State private var hoveredHour: ClaudeHourlyUsage?
    /// Selected chart window in days (1 = the 24 h hourly view); persisted
    /// so the popover re-opens on the period the user last chose. Shared with
    /// `CombinedTopModelsCard` (heatmap stays fixed 120d).
    @AppStorage("popover.allChartDays") private var periodDays = 30

    private static let periods = [1, 7, 30, 90, 120]

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var is24h: Bool { periodDays == 1 }
    /// Cap bar window at available daily history (120).
    private var periodWindowDays: Int { min(max(periodDays, 1), max(report.daily.count, 1)) }
    private var windowDaily: [CombinedDailyUsage] { Array(report.daily.suffix(periodWindowDays)) }
    private var windowTotals: CombinedWindowTotals { report.totals(lastDays: periodWindowDays) }
    /// Chart bars scale by tokens (not USD) so volume, not spend, drives height.
    private var maxBarTokens: Int { max(windowDaily.map(\.tokens).max() ?? 0, 1) }

    // 24h-period numbers: Claude summed over the hour buckets; Codex/Grok from
    // today's calendar bucket (their finest available resolution).
    private var claude24USD: Double { claudeHourly.reduce(0) { $0 + $1.usd } }
    private var claude24Tokens: Int { claudeHourly.reduce(0) { $0 + $1.tokens } }
    private var codexTodayUSD: Double { report.daily.last?.codexUSD ?? 0 }
    private var codexTodayTokens: Int { report.daily.last?.codexTokens ?? 0 }
    private var grokTodayUSD: Double { report.daily.last?.grokUSD ?? 0 }
    private var grokTodayTokens: Int { report.daily.last?.grokTokens ?? 0 }
    private var maxBarHourTokens: Int { max(claudeHourly.map(\.tokens).max() ?? 0, 1) }

    /// Breakdown under the chart — only the click-pinned day. No latest-day
    /// fallback and no hover: default is hidden until the user clicks a bar.
    private var detailDay: CombinedDailyUsage? { pinnedDay }

    private func periodLabel(_ days: Int) -> String {
        days == 1 ? "24h" : "\(days) \(vi ? "ngày" : "days")"
    }

    /// Compact chip labels for the top-right square period boxes.
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
            ? claude24USD + codexTodayUSD + grokTodayUSD
            : windowTotals.usd
    }

    private var periodTotalTokens: Int {
        is24h
            ? claude24Tokens + codexTodayTokens + grokTodayTokens
            : windowTotals.tokens
    }

    var body: some View {
        // Content inset per-block; body hairlines also inset 16pt.
        // No top hairline here — ProviderTabs already owns the edge-to-edge rule.
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
            // Claude / Codex / Grok share — always follows the period chips
            // (24h uses hour Claude + today Codex/Grok; multi-day uses window).
            sourceShareRows
            if is24h {
                if let hovered = hoveredHour {
                    Text("\(hourLabel(hovered.date)) · \(AllUsageFormat.tokens(hovered.tokens)) · \(AllUsageFormat.usd(hovered.usd))")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .popoverContentInset()
                }
                Text(vi ? "Cột giờ chỉ gồm Claude — log Codex/Grok chỉ ghi theo ngày."
                        : "Hour bars are Claude-only — Codex/Grok logs have day resolution.")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .popoverContentInset()
            } else if let detail = detailDay {
                // Click-pinned day only — hover never opens detail.
                detailRows(detail)
                    .popoverContentInset()
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Two-column cost hero:
    ///   left  — period label + big $ + tokens
    ///   right — period chips + TODAY stack
    /// Uses `.top` alignment (not firstTextBaseline) to avoid NSISEngine
    /// recursion on invalid baselines in the auto-sizing popover host.
    private var costHero: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text((vi ? "Tổng chi phí " : "Total cost ") + periodLabel(periodDays))
                    .plexEyebrow(size: 10, color: VocabbyTheme.secondary, tracking: 0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(AllUsageFormat.usd(periodTotalUSD))
                    .font(.plexMono(32, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .tracking(-1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(AllUsageFormat.tokens(periodTotalTokens))
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

    /// Start / end of the visible window under the bars (design axis labels).
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

    /// Per-source rows for the active period chip (24h / 7d / 30d / 90d / 120d).
    private var periodShareRows: [(name: String, usd: Double, tokens: Int, color: Color)] {
        let raw: [(String, Double, Int, Color)]
        if is24h {
            raw = [
                ("Claude", claude24USD, claude24Tokens, VocabbyTheme.chartClaude),
                ("Codex", codexTodayUSD, codexTodayTokens, VocabbyTheme.chartCodex),
                ("Grok", grokTodayUSD, grokTodayTokens, VocabbyTheme.chartGrok),
            ]
        } else {
            raw = [
                ("Claude", windowTotals.claudeUSD, windowTotals.claudeTokens, VocabbyTheme.chartClaude),
                ("Codex", windowTotals.codexUSD, windowTotals.codexTokens, VocabbyTheme.chartCodex),
                ("Grok", windowTotals.grokUSD, windowTotals.grokTokens, VocabbyTheme.chartGrok),
            ]
        }
        return raw
            .filter { $0.2 > 0 }
            .map { (name: $0.0, usd: $0.1, tokens: $0.2, color: $0.3) }
    }

    /// Per-source rows: color tick · name · "12.1B · 72%" · $amount.
    @ViewBuilder
    private var sourceShareRows: some View {
        let rows = periodShareRows
        let total = max(rows.reduce(0) { $0 + $1.tokens }, 1)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let share = Double(row.tokens) / Double(total)
                    HStack(spacing: 8) {
                        Rectangle().fill(row.color).frame(width: 3, height: 12)
                        Text(row.name)
                            .font(.plexSans(13, weight: .medium))
                            .foregroundStyle(VocabbyTheme.primary)
                        Spacer(minLength: 8)
                        Text("\(AllUsageFormat.tokensShort(row.tokens)) · \(String(format: "%.0f%%", share * 100))")
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.tertiary)
                        Text(AllUsageFormat.usd(row.usd))
                            .font(.plexMono(12, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    .popoverContentInset()
                    .padding(.vertical, 5)
                    if index < rows.count - 1 {
                        // Inset separator between share rows (body rule).
                        PopoverInsetHairline()
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Compact square period chips (24h / 7d / 30d / 90d) — top-right of the
    /// cost hero, not a full-width underline strip under the amount.
    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(Self.periods, id: \.self) { days in
                let active = periodDays == days
                Button {
                    periodDays = days
                    hoveredDay = nil   // stale hover may fall outside the new window
                    pinnedDay = nil    // clear pin — new window starts with detail hidden
                    hoveredHour = nil
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
                        .contentShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(periodLabel(days))
                .accessibilityLabel(periodLabel(days))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    /// Stacked bars over the selected window: Claude (top) → Codex → Grok
    /// (bottom); total height proportional to the day's combined tokens.
    private var barChart: some View {
        GeometryReader { geo in
            // 90 bars don't fit with the standard 2pt gap — tighten it.
            HStack(alignment: .bottom, spacing: windowDaily.count > 45 ? 1 : 2) {
                ForEach(windowDaily) { day in
                    let hasTokens = day.tokens > 0
                    let fraction = hasTokens ? CGFloat(Double(day.tokens) / Double(maxBarTokens)) : 0
                    let barHeight = max(geo.size.height * fraction, hasTokens ? 3 : 1)
                    let claudeHeight = hasTokens
                        ? barHeight * CGFloat(Double(day.claudeTokens) / Double(day.tokens)) : 0
                    let codexHeight = hasTokens
                        ? barHeight * CGFloat(Double(day.codexTokens) / Double(day.tokens)) : 0
                    let grokHeight = max(0, barHeight - claudeHeight - codexHeight)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            if hasTokens {
                                Rectangle().fill(VocabbyTheme.chartClaude)
                                    .frame(height: claudeHeight)
                                Rectangle().fill(VocabbyTheme.chartCodex)
                                    .frame(height: codexHeight)
                                Rectangle().fill(VocabbyTheme.chartGrok)
                                    .frame(height: grokHeight)
                            } else {
                                Rectangle()
                                    .fill(VocabbyTheme.selectedSurface.opacity(0.76))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .onTapGesture {
                        // Click = toggle pin only. Hover never opens detail.
                        if pinnedDay?.id == day.id {
                            pinnedDay = nil
                        } else {
                            pinnedDay = day
                        }
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))")
                }
            }
        }
    }

    /// 24 bars, one per clock hour (Claude-only — see the period footnote).
    private var hourChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(claudeHourly) { hour in
                    let hasTokens = hour.tokens > 0
                    let fraction = hasTokens
                        ? CGFloat(Double(hour.tokens) / Double(maxBarHourTokens)) : 0
                    let barHeight = max(geo.size.height * fraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(hasTokens
                                  ? VocabbyTheme.chartClaude
                                  : VocabbyTheme.selectedSurface.opacity(0.76))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredHour?.id == hour.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredHour = hour }
                        else if hoveredHour?.id == hour.id { hoveredHour = nil }
                    }
                    .help("\(hourLabel(hour.date)): \(AllUsageFormat.tokens(hour.tokens)) · \(AllUsageFormat.usd(hour.usd))")
                }
            }
        }
    }

    private func hourLabel(_ date: Date) -> String {
        Self.hourFormatter.string(from: date)
    }

    private static let hourFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:00"
        return df
    }()

    /// Focused-day read-out: combined line + one line per contributing source.
    @ViewBuilder
    private func detailRows(_ detail: CombinedDailyUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(dayLabel(detail.date)) · \(AllUsageFormat.tokens(detail.tokens)) · \(AllUsageFormat.usd(detail.usd))")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
            DaySourceModelRows(day: detail, vi: vi)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }
}

/// Source rows (Claude/Codex/Grok day totals) plus indented per-model sub-rows —
/// shared by the chart hover detail and the heatmap pinned-day detail so the
/// breakdown names the actual models instead of one opaque "Claude" line.
private struct DaySourceModelRows: View {
    let day: CombinedDailyUsage
    let vi: Bool

    /// Rows beyond this fold into one "+N more" summary line — three source
    /// headers × five models each made the breakdown taller than the chart.
    private static let maxRows = 6

    /// Source is carried by the dot colour (chart legend explains it), so the
    /// per-source header rows are gone and models from all sources merge into
    /// one cost-sorted list.
    var body: some View {
        let models = day.models.sorted { $0.usd > $1.usd }
        if models.isEmpty {
            // Older buckets without model detail: fall back to source totals.
            sourceFallbackRows
        } else {
            ForEach(Array(models.prefix(Self.maxRows))) { m in
                row(color: tint(m.source),
                    label: AllUsageFormat.shortName(m.name),
                    tokens: m.tokens, usd: m.usd)
            }
            let rest = models.dropFirst(Self.maxRows)
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
    }

    @ViewBuilder
    private var sourceFallbackRows: some View {
        if day.claudeUSD > 0 || day.claudeTokens > 0 {
            row(color: VocabbyTheme.chartClaude, label: "Claude",
                tokens: day.claudeTokens, usd: day.claudeUSD)
        }
        if day.codexUSD > 0 || day.codexTokens > 0 {
            row(color: VocabbyTheme.chartCodex, label: "Codex",
                tokens: day.codexTokens, usd: day.codexUSD)
        }
        if day.grokUSD > 0 || day.grokTokens > 0 {
            row(color: VocabbyTheme.chartGrok, label: "Grok",
                tokens: day.grokTokens, usd: day.grokUSD)
        }
    }

    private func tint(_ source: String) -> Color {
        switch source {
        case "claude": return VocabbyTheme.chartClaude
        case "codex": return VocabbyTheme.chartCodex
        default: return VocabbyTheme.chartGrok
        }
    }

    private func row(color: Color, label: String, tokens: Int, usd: Double) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.plexSans(10))
                .foregroundStyle(VocabbyTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(AllUsageFormat.tokensAndUSD(tokens, usd))
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }
}

// MARK: - Heatmap card

/// Pure heatmap-intensity math — token-only, no USD — so `CombinedHeatmapCard`
/// coloring is unit-testable without SwiftUI. USD keeps its place in the
/// header/help-tooltip/day-detail text; it never drives the cell color.
/// Active-but-$0 days (tokens only) still get the lightest heat level so
/// they don't read as idle.
enum CombinedHeatmapIntensity {
    static func fraction(tokens: Int, maxTokens: Int, isActive: Bool) -> Double {
        guard isActive else { return 0 }
        return max(UsageChartScaling.fraction(value: Double(tokens), maximum: Double(maxTokens)), 0.05)
    }
}

/// GitHub-style contribution grid: fixed cell size, week-count fills the
/// available width (not a hard-coded 120-day window). Columns are weeks
/// (Monday-first); intensity follows tokens (`CombinedHeatmapIntensity`).
struct CombinedHeatmapCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    /// Day pinned by clicking a cell — shows the per-source breakdown below
    /// the grid. Click the same cell again to dismiss.
    @State private var selectedDay: CombinedDailyUsage?
    /// Measured content width (after popover inset) — seeds week count.
    @State private var contentWidth: CGFloat = 388

    private static let cellSize: CGFloat = 11
    private static let cellGap: CGFloat = 2
    /// Mon/Wed/Fri/Sun label column + gap before the grid.
    private static let labelColumnWidth: CGFloat = 28

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var today: Date? { report.daily.last?.date }

    /// How many week columns fit at fixed cell size (no horizontal stretch).
    private var weekCount: Int {
        let gridWidth = max(contentWidth - Self.labelColumnWidth, Self.cellSize)
        // n * cell + (n - 1) * gap <= gridWidth  →  n <= (gridWidth + gap) / (cell + gap)
        let n = Int(floor((gridWidth + Self.cellGap) / (Self.cellSize + Self.cellGap)))
        return max(4, min(52, n))
    }

    /// Contiguous calendar days ending today that fill `weekCount` Monday-first columns.
    private var windowDays: [CombinedDailyUsage] {
        Self.heatmapWindow(from: report.daily, weekCount: weekCount)
    }

    private var maxTokens: Int { max(windowDays.map(\.tokens).max() ?? 0, 1) }

    /// Week columns, padded with nil so every column has 7 rows.
    private var weeks: [[CombinedDailyUsage?]] {
        var cells: [CombinedDailyUsage?] = []
        if let first = windowDays.first {
            let weekday = Calendar.current.component(.weekday, from: first.date) // 1 = Sun
            let mondayIndex = (weekday + 5) % 7
            cells.append(contentsOf: Array(repeating: nil, count: mondayIndex))
        }
        cells.append(contentsOf: windowDays.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    var body: some View {
        let days = windowDays
        let active = days.filter(\.isActive)
        let windowUSD = days.reduce(0) { $0 + $1.usd }
        let dayCount = days.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(vi ? "Hoạt động \(dayCount) ngày" : "\(dayCount)-day activity")
                    .plexEyebrow(size: 9, color: VocabbyTheme.secondary, tracking: 0.3)
                Spacer(minLength: 8)
                Text("\(AllUsageFormat.usd(windowUSD)) · \(active.count) \(vi ? "ngày active" : "active days")")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                grid
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HeatmapContentWidthKey.self,
                        value: geo.size.width)
                }
            )
            statsRow(for: days)
            if let day = selectedDay {
                dayDetail(day)
            }
        }
        .popoverContentInset()
        .padding(.vertical, 16)
        .popoverHairlineTop()
        .onPreferenceChange(HeatmapContentWidthKey.self) { width in
            if width > 1 { contentWidth = width }
        }
    }

    /// Build a Monday-aligned trailing window of calendar days that fills
    /// exactly `weekCount` columns, looking up spend from `source` (zeros
    /// for dates outside the scanned history).
    static func heatmapWindow(from source: [CombinedDailyUsage],
                              weekCount: Int,
                              calendar: Calendar = .current,
                              now: Date = Date()) -> [CombinedDailyUsage] {
        let weeks = max(1, weekCount)
        let startOfToday = source.last.map { calendar.startOfDay(for: $0.date) }
            ?? calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfToday) // 1 = Sun
        let mondayIndex = (weekday + 5) % 7 // 0 = Mon … 6 = Sun
        // Full weeks before today's week + days Mon…today in the last week.
        let dayCount = (weeks - 1) * 7 + mondayIndex + 1
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: startOfToday)
        else { return source }
        var byDate: [Date: CombinedDailyUsage] = [:]
        byDate.reserveCapacity(source.count)
        for d in source {
            byDate[calendar.startOfDay(for: d.date)] = d
        }
        var out: [CombinedDailyUsage] = []
        out.reserveCapacity(dayCount)
        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if let hit = byDate[day] {
                out.append(hit)
            } else {
                out.append(CombinedDailyUsage(
                    date: day,
                    claudeUSD: 0, claudeTokens: 0,
                    codexUSD: 0, codexTokens: 0,
                    grokUSD: 0, grokTokens: 0,
                    models: []))
            }
        }
        return out
    }

    /// Per-source breakdown for the clicked cell — same layout as the chart
    /// card's hover detail.
    @ViewBuilder
    private func dayDetail(_ day: CombinedDailyUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(L10n.dayMonth(day.date, preference: settings.appLanguage)) · \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
            DaySourceModelRows(day: day, vi: vi)
            if !day.isActive {
                Text(vi ? "Không có hoạt động." : "No activity.")
                    .font(.plexSans(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: Self.cellGap) {
            ForEach(0..<7, id: \.self) { row in
                Text(label(forRow: row))
                    .font(.plexMono(8))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .frame(height: Self.cellSize)
            }
        }
        .frame(width: Self.labelColumnWidth - 6, alignment: .trailing)
    }

    /// Mon/Wed/Fri/Sun row markers (even rows only, like GitHub's grid).
    private func label(forRow row: Int) -> String {
        guard row % 2 == 0 else { return "" }
        let vn = ["T2", "T4", "T6", "CN"]
        let en = ["Mon", "Wed", "Fri", "Sun"]
        return (vi ? vn : en)[row / 2]
    }

    private var grid: some View {
        HStack(spacing: Self.cellGap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        cell(week[row])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: CombinedDailyUsage?) -> some View {
        if let day {
            let fraction = CombinedHeatmapIntensity.fraction(
                tokens: day.tokens, maxTokens: maxTokens, isActive: day.isActive)
            let isSelected = selectedDay?.id == day.id
            Rectangle()
                .fill(VocabbyTheme.heatColor(fraction: fraction))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .overlay(
                    // Selection ring wins over the today ring.
                    isSelected
                        ? Rectangle()
                            .stroke(VocabbyTheme.primary, lineWidth: 1.5)
                        : (day.date == today
                            ? Rectangle()
                                .stroke(VocabbyTheme.blue, lineWidth: 1)
                            : nil)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    // Tap toggles the pinned day detail below the grid.
                    selectedDay = isSelected ? nil : day
                }
                .help("\(L10n.dayMonth(day.date, preference: settings.appLanguage)): \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                .accessibilityLabel(L10n.dayMonth(day.date, preference: settings.appLanguage))
                .accessibilityAddTraits(.isButton)
        } else {
            // Padding slot before the first day / after today.
            Color.clear
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
    }

    /// Peak / avg / streak for the *visible* window only.
    private func statsRow(for days: [CombinedDailyUsage]) -> some View {
        let active = days.filter(\.isActive)
        let peakUSD = days.map(\.usd).max() ?? 0
        let avgUSD = active.isEmpty ? 0 : days.reduce(0) { $0 + $1.usd } / Double(active.count)
        var streak = 0
        var i = days.count - 1
        if i >= 0, !days[i].isActive { i -= 1 }
        while i >= 0, days[i].isActive {
            streak += 1
            i -= 1
        }
        let peak = AllUsageFormat.usd(peakUSD)
        let avg = AllUsageFormat.usd(avgUSD)
        let streakText = "\(streak) \(vi ? "ngày" : "days")"
        return HStack(spacing: 0) {
            statChip(label: vi ? "Cao nhất" : "Peak", value: peak)
            Text("  ·  ")
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
            statChip(label: vi ? "TB/ngày" : "Avg/day", value: avg)
            Text("  ·  ")
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
            statChip(label: "Streak", value: streakText)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func statChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
        }
    }
}

private struct HeatmapContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Top models card

/// Merged top-models list (design single row + brand icon):
/// `■ name | 84pt bar | tokens · $`.
/// Window follows the All-tab chart period chips (`popover.allChartDays`);
/// heatmap is independent (always 120d).
struct CombinedTopModelsCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    /// Same key as `CombinedChartCard` so chips and this list stay in sync.
    @AppStorage("popover.allChartDays") private var periodDays = 30

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var periodWindowDays: Int { min(max(periodDays, 1), max(report.daily.count, 1)) }
    private var periodModels: (models: [CombinedModelCost], windowTokens: Int) {
        report.topModels(lastDays: periodWindowDays)
    }

    /// Design: fixed mid-column bar width (84px).
    private static let barWidth: CGFloat = 84
    /// Design: fixed trailing amount column width (84px).
    private static let amountWidth: CGFloat = 84

    private var title: String {
        if periodWindowDays <= 1 {
            return vi ? "Model dùng nhiều (24h)" : "Top models (24h)"
        }
        return vi
            ? "Model dùng nhiều (\(periodWindowDays) ngày)"
            : "Top models (\(periodWindowDays) days)"
    }

    var body: some View {
        let ranked = periodModels
        if ranked.models.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.plexMono(10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(VocabbyTheme.muted)
                    .textCase(.uppercase)
                    .padding(.bottom, 10)
                ForEach(ranked.models) { model in
                    let fraction = min(1, max(0, Double(model.tokens) / Double(ranked.windowTokens)))
                    let tint = color(for: model)
                    HStack(alignment: .center, spacing: 10) {
                        // Brand icon (source color) — restored at user request.
                        Rectangle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                        Text(AllUsageFormat.shortName(model.name))
                            .font(.plexSans(12))
                            .foregroundStyle(VocabbyTheme.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Fixed mid-column share bar (design 84×3).
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(VocabbyTheme.track)
                            Rectangle()
                                .fill(tint)
                                .frame(width: max(2, Self.barWidth * fraction))
                        }
                        .frame(width: Self.barWidth, height: 3)
                        Text(AllUsageFormat.tokensAndUSD(model.tokens, model.usd))
                            .font(.plexMono(10))
                            .foregroundStyle(VocabbyTheme.muted)
                            .lineLimit(1)
                            .frame(width: Self.amountWidth, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                }
            }
            .popoverContentInset()
            .padding(.top, 14)
            .padding(.bottom, 16)
            .popoverHairlineTop()
        }
    }

    private func color(for model: CombinedModelCost) -> Color {
        switch model.source {
        case "claude": return VocabbyTheme.chartClaude
        case "grok": return VocabbyTheme.chartGrok
        default: return VocabbyTheme.chartCodex
        }
    }
}

// MARK: - Shared formatting

/// Number formatting shared by every usage card (All tab + the per-provider
/// chart cards): thousands-grouped dollars ("$13,236", "$547.58") and
/// human-scale token counts with a B tier ("14.5B" instead of "14465.0M").
enum AllUsageFormat {
    /// Model-row readout: unpriced models (the cost scanner prices non-Claude
    /// models at $0) show tokens only — "$0.00" reads like real spend data
    /// that is simply wrong.
    static func tokensAndUSD(_ tokens: Int, _ usd: Double) -> String {
        usd < 0.005 ? tokensShort(tokens) : "\(tokensShort(tokens)) · \(self.usd(usd))"
    }

    /// US-style grouping regardless of app locale — matches the fixed "$"
    /// symbol the cards already use.
    private static let wholeUSD: NumberFormatter = makeFormatter(fractionDigits: 0)
    private static let centsUSD: NumberFormatter = makeFormatter(fractionDigits: 2)

    private static func makeFormatter(fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }

    static func usd(_ amount: Double) -> String {
        // Whole dollars once the cents stop mattering, always grouped.
        let formatter = amount >= 1000 ? wholeUSD : centsUSD
        let body = formatter.string(from: NSNumber(value: amount))
            ?? String(format: "%.2f", amount)
        return "$" + body
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) + " tokens" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) + " tokens" }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) + " tokens" }
        return "\(n) tokens"
    }

    static func tokensShort(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        let m = Double(n) / 1_000_000
        if n >= 10_000_000 { return String(format: "%.0fM", m) }
        if n >= 1_000_000 { return String(format: "%.1fM", m) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Trim very long model names (CodexBar parity with `shortModelName`).
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }
}
