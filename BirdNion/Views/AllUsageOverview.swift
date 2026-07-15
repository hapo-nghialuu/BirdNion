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
    /// Full-window (90d) totals for the heatmap header.
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

    var isEmpty: Bool { activeDays == 0 }

    static func build(claude: ClaudeUsageReport?,
                      codex: CodexUsageReport?,
                      grok: GrokUsageReport? = nil,
                      includeClaude: Bool = true,
                      includeCodex: Bool = true,
                      includeGrok: Bool = true,
                      calendar: Calendar = .current,
                      now: Date = Date(),
                      windowDays: Int = 90) -> CombinedUsageReport {
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
            streakDays: streak)
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
}

// MARK: - All tab root

/// Body of the "All" pseudo-provider tab: combined totals + stacked 30-day
/// chart, 90-day heatmap, and the merged top-models list. Sources that are
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
                .vocabbyCard()
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
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            if report.isEmpty {
                Text(vi ? "Chưa có dữ liệu sử dụng trong 90 ngày qua."
                        : "No usage recorded in the last 90 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vocabbyCard()
            } else {
                CombinedChartCard(report: report, claudeHourly: claude?.hourly ?? [])
                CombinedHeatmapCard(report: report)
                if !report.topModels.isEmpty {
                    CombinedTopModelsCard(report: report)
                }
            }
        }
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
    @State private var hoveredHour: ClaudeHourlyUsage?
    /// Selected chart window in days (1 = the 24 h hourly view); persisted
    /// so the popover re-opens on the period the user last chose.
    @AppStorage("popover.allChartDays") private var periodDays = 30

    private static let periods = [1, 7, 30, 90]

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var is24h: Bool { periodDays == 1 }
    private var windowDaily: [CombinedDailyUsage] { Array(report.daily.suffix(periodDays)) }
    private var windowTotals: CombinedWindowTotals { report.totals(lastDays: periodDays) }
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

    private var detailDay: CombinedDailyUsage? {
        hoveredDay ?? windowDaily.last(where: \.isActive)
    }

    private func periodLabel(_ days: Int) -> String {
        days == 1 ? "24h" : "\(days) \(vi ? "ngày" : "days")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: vi ? "Hôm nay" : "Today",
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: periodLabel(periodDays),
                    amount: is24h
                        ? claude24USD + codexTodayUSD + grokTodayUSD
                        : windowTotals.usd,
                    tokens: is24h
                        ? claude24Tokens + codexTodayTokens + grokTodayTokens
                        : windowTotals.tokens,
                    alignTrailing: true)
            }
            periodPicker
            Group {
                if is24h {
                    hourChart
                } else {
                    barChart
                }
            }
            .frame(height: 56)
            // Legend doubles as the per-source split for the chosen period
            // (token volume — same metric as the stacked bars).
            HStack(spacing: 12) {
                legendDot(color: VocabbyTheme.chartClaude,
                          label: "Claude \(AllUsageFormat.tokensShort(is24h ? claude24Tokens : windowTotals.claudeTokens))")
                legendDot(color: VocabbyTheme.chartCodex,
                          label: (is24h ? (vi ? "Codex (hôm nay) " : "Codex (today) ") : "Codex ")
                              + AllUsageFormat.tokensShort(is24h ? codexTodayTokens : windowTotals.codexTokens))
                legendDot(color: VocabbyTheme.chartGrok,
                          label: (is24h ? (vi ? "Grok (hôm nay) " : "Grok (today) ") : "Grok ")
                              + AllUsageFormat.tokensShort(is24h ? grokTodayTokens : windowTotals.grokTokens))
            }
            if is24h {
                if let hovered = hoveredHour {
                    Text("\(hourLabel(hovered.date)) · \(AllUsageFormat.tokens(hovered.tokens)) · \(AllUsageFormat.usd(hovered.usd))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.secondary)
                }
                Text(vi ? "Cột giờ chỉ gồm Claude — log Codex/Grok chỉ ghi theo ngày."
                        : "Hour bars are Claude-only — Codex/Grok logs have day resolution.")
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let detail = detailDay {
                    detailRows(detail)
                }
                Text((vi ? "Ước tính \(periodDays) ngày" : "Est. \(periodDays)-day total")
                     + ": \(AllUsageFormat.tokens(windowTotals.tokens))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
                Text(vi ? "Ước tính từ log cục bộ của Claude Code CLI, Codex và Grok."
                        : "Estimated from local Claude Code CLI, Codex, and Grok logs.")
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            Text(AllUsageFormat.usd(amount))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            Text(AllUsageFormat.tokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    /// Compact 7/30/90-day window switcher (CodeBurn-style pills).
    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(Self.periods, id: \.self) { days in
                let active = periodDays == days
                Button {
                    periodDays = days
                    hoveredDay = nil   // stale hover may fall outside the new window
                    hoveredHour = nil
                } label: {
                    Text(periodLabel(days))
                        .font(.system(size: 9, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? VocabbyTheme.blue : VocabbyTheme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(active ? VocabbyTheme.selectedSurface : VocabbyTheme.segment)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(active ? VocabbyTheme.blue.opacity(0.35)
                                                    : VocabbyTheme.border,
                                             lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
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
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredDay?.id == day.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
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
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
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
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            DaySourceModelRows(day: detail)
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

    var body: some View {
        if day.claudeUSD > 0 || day.claudeTokens > 0 {
            sourceRow(color: VocabbyTheme.chartClaude, label: "Claude",
                      usd: day.claudeUSD, tokens: day.claudeTokens)
            modelRows("claude")
        }
        if day.codexUSD > 0 || day.codexTokens > 0 {
            sourceRow(color: VocabbyTheme.chartCodex, label: "Codex",
                      usd: day.codexUSD, tokens: day.codexTokens)
            modelRows("codex")
        }
        if day.grokUSD > 0 || day.grokTokens > 0 {
            sourceRow(color: VocabbyTheme.chartGrok, label: "Grok",
                      usd: day.grokUSD, tokens: day.grokTokens)
            modelRows("grok")
        }
    }

    /// One indented line per model under its source row. Scanner daily
    /// buckets cap at the top 5 models/day, so the list stays short.
    @ViewBuilder
    private func modelRows(_ source: String) -> some View {
        ForEach(day.models.filter { $0.source == source }) { m in
            HStack(spacing: 8) {
                Text(AllUsageFormat.shortName(m.name))
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(AllUsageFormat.tokensShort(m.tokens)) · \(AllUsageFormat.usd(m.usd))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .padding(.leading, 14)
        }
    }

    private func sourceRow(color: Color, label: String, usd: Double, tokens: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(VocabbyTheme.secondary)
            Spacer(minLength: 8)
            Text("\(AllUsageFormat.tokensShort(tokens)) · \(AllUsageFormat.usd(usd))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }
}

// MARK: - Heatmap card

/// GitHub-style contribution grid over the 90-day window: columns are weeks
/// (Monday-first), rows are weekdays, cell intensity follows the day's USD.
/// Peak / average / streak stats sit to the right of the grid to keep the
/// popover short.
struct CombinedHeatmapCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    /// Day pinned by clicking a cell — shows the per-source breakdown below
    /// the grid. Click the same cell again to dismiss.
    @State private var selectedDay: CombinedDailyUsage?

    private static let cellSize: CGFloat = 11
    private static let cellGap: CGFloat = 2

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var maxUSD: Double { max(report.daily.map(\.usd).max() ?? 0, 0.01) }
    private var today: Date? { report.daily.last?.date }

    /// Week columns, padded with nil at both ends so every column has 7 rows.
    private var weeks: [[CombinedDailyUsage?]] {
        var cells: [CombinedDailyUsage?] = []
        if let first = report.daily.first {
            let weekday = Calendar.current.component(.weekday, from: first.date) // 1 = Sun
            let mondayIndex = (weekday + 5) % 7
            cells.append(contentsOf: Array(repeating: nil, count: mondayIndex))
        }
        cells.append(contentsOf: report.daily.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(vi ? "Hoạt động 90 ngày" : "90-day activity")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .tracking(0.3)
                Spacer(minLength: 8)
                Text("\(AllUsageFormat.usd(report.totalUSD)) · \(report.activeDays) \(vi ? "ngày active" : "active days")")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            // Stats sit right next to the grid (leading-aligned) instead of
            // being pinned to the trailing edge — the leftover width of the
            // fixed 420pt popover row collects at the right border, which
            // reads better than a hole in the middle of the card.
            HStack(alignment: .top, spacing: 10) {
                weekdayLabels
                grid
                statsColumn
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            if let day = selectedDay {
                dayDetail(day)
            }
        }
        .vocabbyCard()
    }

    /// Per-source breakdown for the clicked cell — same layout as the chart
    /// card's hover detail.
    @ViewBuilder
    private func dayDetail(_ day: CombinedDailyUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(L10n.dayMonth(day.date, preference: settings.appLanguage)) · \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            DaySourceModelRows(day: day)
            if !day.isActive {
                Text(vi ? "Không có hoạt động." : "No activity.")
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: Self.cellGap) {
            ForEach(0..<7, id: \.self) { row in
                Text(label(forRow: row))
                    .font(.system(size: 8))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .frame(height: Self.cellSize)
            }
        }
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
            // Active-but-$0 days (tokens only) still get the lightest heat
            // level so they don't read as idle.
            let fraction = day.isActive ? max(day.usd / maxUSD, 0.05) : 0
            let isSelected = selectedDay?.id == day.id
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(VocabbyTheme.heatColor(fraction: fraction))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .overlay(
                    // Selection ring wins over the today ring.
                    isSelected
                        ? RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(VocabbyTheme.primary, lineWidth: 1.5)
                        : (day.date == today
                            ? RoundedRectangle(cornerRadius: 2, style: .continuous)
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

    private var statsColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            stat(label: vi ? "Ngày cao nhất" : "Peak day",
                 value: report.peakDayDate.map {
                     "\(AllUsageFormat.usd(report.peakDayUSD)) · \(L10n.dayMonth($0, preference: settings.appLanguage))"
                 } ?? "—")
            stat(label: vi ? "TB/ngày active" : "Avg active day",
                 value: AllUsageFormat.usd(report.avgPerActiveDayUSD))
            stat(label: "Streak",
                 value: "\(report.streakDays) \(vi ? "ngày" : "days")")
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
        }
    }
}

// MARK: - Top models card

/// Merged top-models list (both sources), each row carrying its provider's
/// brand colour and a token-share bar — mirrors CodeBurn's Models block.
struct CombinedTopModelsCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    /// Bars show each model's share of the WINDOW token total (not of the
    /// largest model, which would always render the top row at 100%).
    private var totalTokens: Double { max(Double(report.totalTokens), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vi ? "Model dùng nhiều (90 ngày)" : "Top models (90 days)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            ForEach(report.topModels) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: model))
                            .frame(width: 6, height: 6)
                        Text(AllUsageFormat.shortName(model.name))
                            .font(.system(size: 10))
                            .foregroundStyle(VocabbyTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(AllUsageFormat.tokensShort(model.tokens)) · \(AllUsageFormat.usd(model.usd))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(VocabbyTheme.track)
                            .frame(height: 3)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(color(for: model))
                                .frame(width: max(2, geo.size.width * CGFloat(Double(model.tokens) / totalTokens)),
                                       height: 3)
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .vocabbyCard()
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
