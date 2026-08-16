import XCTest
@testable import BirdNion

/// Pure-merge tests for `CombinedUsageReport.build` (the All tab's data
/// layer): calendar-day merging across sources, today-from-bucket semantics,
/// streak/peak/average math, and cross-source model merging.
final class CombinedUsageReportTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var now = Date()
    private lazy var startOfToday = calendar.startOfDay(for: now)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: startOfToday)!
    }

    private func claudeDay(_ offset: Int, usd: Double, tokens: Int,
                           models: [ClaudeDailyModel] = []) -> ClaudeDailyUsage {
        ClaudeDailyUsage(date: day(offset), usd: usd, tokens: tokens, models: models)
    }

    private func codexDay(_ offset: Int, usd: Double, tokens: Int,
                          models: [CodexDailyModel] = []) -> CodexDailyUsage {
        CodexDailyUsage(date: day(offset), usd: usd, tokens: tokens, models: models)
    }

    private func claudeReport(daily: [ClaudeDailyUsage],
                              last30USD: Double = 0, last30Tokens: Int = 0,
                              confidence: CostHistoryStore.UsageScanConfidence = .unavailable
    ) -> ClaudeUsageReport {
        ClaudeUsageReport(todayUSD: 0, todayTokens: 0,
                          last30USD: last30USD, last30Tokens: last30Tokens,
                          daily: daily, topModel: nil, scanConfidence: confidence)
    }

    private func codexReport(daily: [CodexDailyUsage],
                             todayUSD: Double = 0, todayTokens: Int = 0,
                             last30USD: Double = 0, last30Tokens: Int = 0,
                             confidence: CostHistoryStore.UsageScanConfidence = .unavailable
    ) -> CodexUsageReport {
        CodexUsageReport(todayUSD: todayUSD, todayTokens: todayTokens,
                         last30USD: last30USD, last30Tokens: last30Tokens,
                         daily: daily, topModel: nil, scanConfidence: confidence)
    }

    func testMergesSourcesByCalendarDay() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 2.0, tokens: 100), claudeDay(-1, usd: 1.0, tokens: 50)],
            last30USD: 3.0, last30Tokens: 150)
        let codex = codexReport(
            daily: [codexDay(-1, usd: 4.0, tokens: 200)],
            last30USD: 4.0, last30Tokens: 200)

        let r = CombinedUsageReport.build(claude: claude, codex: codex,
                                          calendar: calendar, now: now)

        XCTAssertEqual(r.daily.count, 120)
        XCTAssertEqual(r.daily.last?.date, startOfToday)
        // Yesterday holds both sources, split per origin.
        let yesterday = r.daily[r.daily.count - 2]
        XCTAssertEqual(yesterday.claudeUSD, 1.0, accuracy: 0.001)
        XCTAssertEqual(yesterday.codexUSD, 4.0, accuracy: 0.001)
        XCTAssertEqual(yesterday.usd, 5.0, accuracy: 0.001)
        XCTAssertEqual(yesterday.tokens, 250)
        // 30-day totals = sum of each source's own last30 fields.
        XCTAssertEqual(r.last30USD, 7.0, accuracy: 0.001)
        XCTAssertEqual(r.last30Tokens, 350)
        XCTAssertEqual(r.activeDays, 2)
        XCTAssertFalse(r.isEmpty)
    }

    /// "Today" must come from today's calendar bucket — Codex's own
    /// `todayUSD` is the most recent *active* day, which may be older.
    func testTodayFromCalendarBucketNotCodexTodayField() {
        let codex = codexReport(
            daily: [codexDay(-3, usd: 9.0, tokens: 900)],
            todayUSD: 9.0, todayTokens: 900)   // "today" per Codex = 3 days ago

        let r = CombinedUsageReport.build(claude: nil, codex: codex,
                                          calendar: calendar, now: now)

        XCTAssertEqual(r.todayUSD, 0, accuracy: 0.001)
        XCTAssertEqual(r.todayTokens, 0)
        XCTAssertEqual(r.totalUSD, 9.0, accuracy: 0.001)
    }

    func testSingleSourceAndEmpty() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 1.5, tokens: 10)],
                                  last30USD: 1.5, last30Tokens: 10)
        let solo = CombinedUsageReport.build(claude: claude, codex: nil,
                                             calendar: calendar, now: now)
        XCTAssertEqual(solo.last30USD, 1.5, accuracy: 0.001)
        XCTAssertEqual(solo.todayUSD, 1.5, accuracy: 0.001)
        XCTAssertFalse(solo.isEmpty)

        let empty = CombinedUsageReport.build(claude: nil, codex: nil,
                                              calendar: calendar, now: now)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.daily.count, 120)
        XCTAssertEqual(empty.streakDays, 0)
    }

    /// An inactive today doesn't break the streak (the day isn't over);
    /// a gap before that does.
    func testStreakSkipsInactiveTodayOnly() {
        let claude = claudeReport(daily: [
            claudeDay(-1, usd: 1, tokens: 1),
            claudeDay(-2, usd: 1, tokens: 1),
        ])
        let r = CombinedUsageReport.build(claude: claude, codex: nil,
                                          calendar: calendar, now: now)
        XCTAssertEqual(r.streakDays, 2)

        let gapped = claudeReport(daily: [
            claudeDay(0, usd: 1, tokens: 1),
            claudeDay(-2, usd: 1, tokens: 1),   // gap at -1 ends the streak
        ])
        let g = CombinedUsageReport.build(claude: gapped, codex: nil,
                                          calendar: calendar, now: now)
        XCTAssertEqual(g.streakDays, 1)
    }

    func testPeakAndAveragePerActiveDay() {
        let claude = claudeReport(daily: [
            claudeDay(0, usd: 2, tokens: 1),
            claudeDay(-1, usd: 6, tokens: 1),
            claudeDay(-2, usd: 1, tokens: 1),
        ])
        let r = CombinedUsageReport.build(claude: claude, codex: nil,
                                          calendar: calendar, now: now)
        XCTAssertEqual(r.peakDayUSD, 6, accuracy: 0.001)
        XCTAssertEqual(r.peakDayDate, day(-1))
        XCTAssertEqual(r.avgPerActiveDayUSD, 3, accuracy: 0.001)   // 9 / 3 active days
        XCTAssertEqual(r.activeDays, 3)
    }

    /// The Claude scan buckets the trailing 24 h by clock hour (per-line
    /// timestamps) — feeds the "Last 24 hours" card.
    func testClaudeScanBuildsHourlyBuckets() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-3_600))       // 1 h ago
        let stale = iso.string(from: now.addingTimeInterval(-30 * 3_600))   // outside 24 h
        let line = { (ts: String, id: String) in
            """
            {"type":"assistant","timestamp":"\(ts)","requestId":"\(id)",\
            "message":{"id":"\(id)","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
            """
        }
        try [line(recent, "m1"), line(stale, "m2")].joined(separator: "\n")
            .write(to: root.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let report = try XCTUnwrap(ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("projects")], now: now))

        XCTAssertEqual(report.hourly.count, 24)
        XCTAssertEqual(report.hourly.reduce(0) { $0 + $1.tokens }, 150)   // recent only
        XCTAssertTrue(report.hourly.contains { $0.tokens == 150 })
    }

    /// Money gets thousands grouping; token counts get a B tier so 14465.0M
    /// reads as 14.5B.
    func testCurrencyAndTokenFormatting() {
        XCTAssertEqual(AllUsageFormat.usd(13236.4), "$13,236")
        XCTAssertEqual(AllUsageFormat.usd(11021.0), "$11,021")
        XCTAssertEqual(AllUsageFormat.usd(547.579), "$547.58")
        XCTAssertEqual(AllUsageFormat.usd(2.25), "$2.25")
        XCTAssertEqual(AllUsageFormat.tokens(14_465_000_000), "14.5B tokens")
        XCTAssertEqual(AllUsageFormat.tokens(26_200_000), "26.2M tokens")
        XCTAssertEqual(AllUsageFormat.tokensShort(9_463_000_000), "9.5B")
        XCTAssertEqual(AllUsageFormat.tokensShort(148_000_000), "148M")
    }

    /// Window totals sum only the trailing N calendar days, split per source
    /// — feeds the 7/30/90-day period picker on the All tab.
    func testWindowTotalsBySource() {
        let claude = claudeReport(daily: [
            claudeDay(0, usd: 2, tokens: 100),
            claudeDay(-8, usd: 5, tokens: 50),   // outside the 7-day window
        ])
        let codex = codexReport(daily: [codexDay(-1, usd: 3, tokens: 200)])
        let r = CombinedUsageReport.build(claude: claude, codex: codex,
                                          calendar: calendar, now: now)

        let week = r.totals(lastDays: 7)
        XCTAssertEqual(week.usd, 5, accuracy: 0.001)          // 2 + 3, -8d excluded
        XCTAssertEqual(week.claudeUSD, 2, accuracy: 0.001)
        XCTAssertEqual(week.codexUSD, 3, accuracy: 0.001)
        XCTAssertEqual(week.grokUSD, 0, accuracy: 0.001)
        XCTAssertEqual(week.tokens, 300)

        let quarter = r.totals(lastDays: 90)
        XCTAssertEqual(quarter.usd, 10, accuracy: 0.001)
        XCTAssertEqual(quarter.claudeTokens, 150)
        XCTAssertEqual(quarter.codexTokens, 200)
    }

    /// Grok is a third local-cost source on the All tab — merges by calendar day
    /// and contributes to last30 / topModels with source tag "grok".
    func testMergesGrokAsThirdSource() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 1, tokens: 10)],
            last30USD: 1, last30Tokens: 10)
        let codex = codexReport(
            daily: [codexDay(0, usd: 2, tokens: 20)],
            last30USD: 2, last30Tokens: 20)
        let grok = GrokUsageReport(
            todayUSD: 3, todayTokens: 30,
            last30USD: 3, last30Tokens: 30,
            daily: [GrokDailyUsage(
                date: day(0), usd: 3, tokens: 30,
                models: [GrokDailyModel(name: "grok-4.5", usd: 3, tokens: 30)])],
            topModel: "grok-4.5")

        let r = CombinedUsageReport.build(claude: claude, codex: codex, grok: grok,
                                          calendar: calendar, now: now)
        XCTAssertEqual(r.todayUSD, 6, accuracy: 0.001)
        XCTAssertEqual(r.todayTokens, 60)
        XCTAssertEqual(r.last30USD, 6, accuracy: 0.001)
        XCTAssertEqual(r.daily.last?.grokUSD ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(r.totals(lastDays: 7).grokUSD, 3, accuracy: 0.001)
        XCTAssertTrue(r.topModels.contains { $0.source == "grok" && $0.name == "grok-4.5" })
    }

    func testTokenOnlyUsageRemainsActive() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 0, tokens: 1234)],
            last30Tokens: 1234)

        let r = CombinedUsageReport.build(claude: claude, codex: nil,
                                          calendar: calendar, now: now)

        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.activeDays, 1)
        XCTAssertTrue(r.daily.last?.isActive == true)
        XCTAssertEqual(r.totalTokens, 1234)
    }
    func testUsageChartScalingUsesTokensNotCost() {
        let tokenHeavy = UsageChartScaling.fraction(value: 10_000, maximum: 10_000)
        let costHeavy = UsageChartScaling.fraction(value: 100, maximum: 10_000)

        XCTAssertEqual(tokenHeavy, 1, accuracy: 0.001)
        XCTAssertEqual(costHeavy, 0.01, accuracy: 0.001)
        XCTAssertGreaterThan(tokenHeavy, costHeavy)
    }

    /// The heatmap cell intensity takes tokens only — USD isn't even a
    /// parameter, so a day with high spend but low token volume can never
    /// out-shine a high-token/low-spend day.
    func testHeatmapIntensityScalesByTokensNotUSD() {
        let halfway = CombinedHeatmapIntensity.fraction(tokens: 500, maxTokens: 1_000, isActive: true)
        XCTAssertEqual(halfway, 0.5, accuracy: 0.0001)

        // Full-scale day.
        XCTAssertEqual(
            CombinedHeatmapIntensity.fraction(tokens: 1_000, maxTokens: 1_000, isActive: true),
            1, accuracy: 0.0001)

        // Inactive day is always 0, regardless of leftover token count.
        XCTAssertEqual(
            CombinedHeatmapIntensity.fraction(tokens: 999, maxTokens: 1_000, isActive: false), 0)

        // Active but token-less day (spend-only edge case) still gets the
        // visible floor instead of reading as idle.
        XCTAssertEqual(
            CombinedHeatmapIntensity.fraction(tokens: 0, maxTokens: 1_000, isActive: true),
            0.05, accuracy: 0.0001)
    }
    func testDisabledSourcesExcludePreviouslyLoadedReports() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 1, tokens: 10)],
            last30USD: 1, last30Tokens: 10)
        let codex = codexReport(
            daily: [codexDay(
                0,
                usd: 2,
                tokens: 20,
                models: [CodexDailyModel(name: "gpt-5.5", usd: 2, tokens: 20)])],
            last30USD: 2, last30Tokens: 20)
        let grok = GrokUsageReport(
            todayUSD: 3, todayTokens: 30,
            last30USD: 3, last30Tokens: 30,
            daily: [GrokDailyUsage(
                date: day(0), usd: 3, tokens: 30,
                models: [GrokDailyModel(name: "grok-4.5", usd: 3, tokens: 30)])],
            topModel: "grok-4.5")

        let r = CombinedUsageReport.build(
            claude: claude,
            codex: codex,
            grok: grok,
            includeClaude: false,
            includeCodex: true,
            includeGrok: false,
            calendar: calendar,
            now: now)

        XCTAssertEqual(r.todayUSD, 2, accuracy: 0.001)
        XCTAssertEqual(r.todayTokens, 20)
        XCTAssertEqual(r.last30USD, 2, accuracy: 0.001)
        XCTAssertEqual(r.last30Tokens, 20)
        XCTAssertEqual(r.topModels.map(\.source), ["codex"])
    }

    /// Models merge per source across days, sort by tokens, and keep their
    /// source tag for the brand colour.
    func testTopModelsMergeAcrossSourcesAndDays() {
        let claude = claudeReport(daily: [
            claudeDay(0, usd: 2, tokens: 20,
                      models: [ClaudeDailyModel(name: "claude-opus-4-8", usd: 2, tokens: 20)]),
            claudeDay(-1, usd: 3, tokens: 30,
                      models: [ClaudeDailyModel(name: "claude-opus-4-8", usd: 3, tokens: 30)]),
        ])
        let codex = codexReport(daily: [
            codexDay(0, usd: 8, tokens: 80,
                     models: [CodexDailyModel(name: "gpt-5.5", usd: 8, tokens: 80)]),
        ])

        let r = CombinedUsageReport.build(claude: claude, codex: codex,
                                          calendar: calendar, now: now)

        XCTAssertEqual(r.topModels.count, 2)
        XCTAssertEqual(r.topModels[0].name, "gpt-5.5")
        XCTAssertEqual(r.topModels[0].source, "codex")
        XCTAssertEqual(r.topModels[0].usd, 8, accuracy: 0.001)
        XCTAssertEqual(r.topModels[1].name, "claude-opus-4-8")
        XCTAssertEqual(r.topModels[1].source, "claude")
        XCTAssertEqual(r.topModels[1].usd, 5, accuracy: 0.001)   // 2 + 3 summed
        XCTAssertEqual(r.topModels[1].tokens, 50)
    }

    func testDailyBucketsCarryPerDayModelSplit() {
        let claude = claudeReport(daily: [
            claudeDay(0, usd: 3, tokens: 30, models: [
                ClaudeDailyModel(name: "claude-opus-4-8", usd: 2, tokens: 20),
                ClaudeDailyModel(name: "claude-sonnet-5", usd: 1, tokens: 10),
            ]),
            claudeDay(-1, usd: 4, tokens: 40,
                      models: [ClaudeDailyModel(name: "claude-opus-4-8", usd: 4, tokens: 40)]),
        ])
        let codex = codexReport(daily: [
            codexDay(0, usd: 8, tokens: 80,
                     models: [CodexDailyModel(name: "gpt-5.5", usd: 8, tokens: 80)]),
        ])

        let r = CombinedUsageReport.build(claude: claude, codex: codex,
                                          calendar: calendar, now: now)

        // Today: both sources, token-sorted (codex 80 > opus 20 > sonnet 10).
        let today = r.daily.last!
        XCTAssertEqual(today.models.map(\.name),
                       ["gpt-5.5", "claude-opus-4-8", "claude-sonnet-5"])
        XCTAssertEqual(today.models.map(\.source), ["codex", "claude", "claude"])
        XCTAssertEqual(today.models[1].usd, 2, accuracy: 0.001)
        // Yesterday: Claude only — the day's split stays per-day, not window-wide.
        let yesterday = r.daily[r.daily.count - 2]
        XCTAssertEqual(yesterday.models.map(\.name), ["claude-opus-4-8"])
        XCTAssertEqual(yesterday.models[0].usd, 4, accuracy: 0.001)
        // Idle days carry no model rows.
        XCTAssertTrue(r.daily[0].models.isEmpty)
    }

    // MARK: - Data Confidence Pass (per-source badge)

    func testSourceConfidenceStateClassifiesLiveHistoryAndUnavailable() {
        let live = CostHistoryStore.UsageScanConfidence(included: true, live: true, scannedAt: now)
        let historyOnly = CostHistoryStore.UsageScanConfidence(included: true, live: false, scannedAt: now)

        XCTAssertEqual(SourceConfidenceState.classify(live), .live)
        XCTAssertEqual(SourceConfidenceState.classify(historyOnly), .historyOnly)
        XCTAssertEqual(SourceConfidenceState.classify(.unavailable), .unavailable)
        // `included` is the gate: a malformed confidence with `live: true`
        // but `included: false` still classifies unavailable.
        let malformed = CostHistoryStore.UsageScanConfidence(included: false, live: true, scannedAt: now)
        XCTAssertEqual(SourceConfidenceState.classify(malformed), .unavailable)
    }

    /// Boundary values for each `L10n.relativeUpdated` tier, driven by an
    /// injected `now` so the assertion never depends on wall-clock timing.
    func testFreshnessLabelBoundariesAreDeterministic() {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(SourceConfidenceFormat.freshnessLabel(scannedAt: nil, now: fixedNow))

        XCTAssertEqual(
            SourceConfidenceFormat.freshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-2), now: fixedNow, preference: "en"),
            "just updated")
        XCTAssertEqual(
            SourceConfidenceFormat.freshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-30), now: fixedNow, preference: "en"),
            "30 seconds ago")
        XCTAssertEqual(
            SourceConfidenceFormat.freshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-125), now: fixedNow, preference: "en"),
            "2 minutes ago")
        XCTAssertEqual(
            SourceConfidenceFormat.freshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-3 * 3_600 - 60), now: fixedNow, preference: "en"),
            "3 hours ago")
        // Vietnamese table.
        XCTAssertEqual(
            SourceConfidenceFormat.freshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-125), now: fixedNow, preference: "vi"),
            "2 phút trước")
    }

    func testCompactFreshnessLabelKeepsConfidenceRowDense() {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(SourceConfidenceFormat.compactFreshnessLabel(scannedAt: nil, now: fixedNow))
        XCTAssertEqual(
            SourceConfidenceFormat.compactFreshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-30), now: fixedNow),
            "<1m")
        XCTAssertEqual(
            SourceConfidenceFormat.compactFreshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-125), now: fixedNow),
            "2m")
        XCTAssertEqual(
            SourceConfidenceFormat.compactFreshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-3 * 3_600), now: fixedNow),
            "3h")
        XCTAssertEqual(
            SourceConfidenceFormat.compactFreshnessLabel(
                scannedAt: fixedNow.addingTimeInterval(-3 * 86_400), now: fixedNow),
            "3d")
    }

    /// `CombinedUsageReport.build` gates confidence by the same `includeX`
    /// flags as the token/usd rollups: disabled and still-pending (nil
    /// report) sources both collapse to `nil` confidence, never a
    /// synthesized "unavailable" state.
    func testCombinedConfidenceNilWhenSourceDisabledOrPending() {
        let liveConfidence = CostHistoryStore.UsageScanConfidence(included: true, live: true, scannedAt: now)
        let claude = claudeReport(daily: [claudeDay(0, usd: 1, tokens: 10)], confidence: liveConfidence)

        let landed = CombinedUsageReport.build(claude: claude, codex: nil, calendar: calendar, now: now)
        XCTAssertEqual(landed.claudeConfidence, liveConfidence)

        let disabled = CombinedUsageReport.build(
            claude: claude, codex: nil, includeClaude: false, calendar: calendar, now: now)
        XCTAssertNil(disabled.claudeConfidence)

        let pending = CombinedUsageReport.build(claude: nil, codex: nil, calendar: calendar, now: now)
        XCTAssertNil(pending.claudeConfidence)
    }

    /// A landed report with `included == false` (the source has never
    /// produced any evidence) still surfaces that real state through the
    /// combined report — the badge row is responsible for hiding it from
    /// view, not the model layer.
    func testCombinedConfidenceSurfacesUnavailableStateWhenIncludedFalse() {
        let codex = codexReport(daily: [], confidence: .unavailable)
        let r = CombinedUsageReport.build(claude: nil, codex: codex, calendar: calendar, now: now)
        XCTAssertEqual(r.codexConfidence, .unavailable)
        XCTAssertEqual(r.codexConfidence.map(SourceConfidenceState.classify), .unavailable)
    }

    // MARK: - Phase 2: MonthlyForecast (pure)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comp = DateComponents()
        comp.year = year; comp.month = month; comp.day = day
        return calendar.date(from: comp)!
    }

    private func combinedDay(_ d: Date, usd: Double) -> CombinedDailyUsage {
        CombinedDailyUsage(date: d, claudeUSD: usd, claudeTokens: 0, codexUSD: 0, codexTokens: 0)
    }

    /// Day 1 of the month: `daysElapsed == 1` (no divide-by-zero), and the
    /// projection is simply that single day's spend scaled to the full month.
    func testMonthlyForecastDayOneOfMonth() {
        let now = date(2026, 3, 1)
        let f = MonthlyForecast.build(
            daily: [combinedDay(now, usd: 10)], budgetUSD: 100, now: now, calendar: calendar)
        XCTAssertEqual(f.daysElapsed, 1)
        XCTAssertEqual(f.daysInMonth, 31)
        XCTAssertEqual(f.monthToDateUSD, 10, accuracy: 0.001)
        XCTAssertEqual(f.projectedTotalUSD, 310, accuracy: 0.001)   // 10/1 * 31
    }

    /// 2028 is a leap year — February has 29 days.
    func testMonthlyForecastLeapFebruaryDaysInMonth() {
        let now = date(2028, 2, 15)
        let f = MonthlyForecast.build(daily: [], budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertEqual(f.daysInMonth, 29)
    }

    /// 2027 is not a leap year — February has 28 days.
    func testMonthlyForecastNonLeapFebruaryDaysInMonth() {
        let now = date(2027, 2, 15)
        let f = MonthlyForecast.build(daily: [], budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertEqual(f.daysInMonth, 28)
    }

    /// January is a 31-day month.
    func testMonthlyForecast31DayMonth() {
        let now = date(2026, 1, 20)
        let f = MonthlyForecast.build(daily: [], budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertEqual(f.daysInMonth, 31)
    }

    /// A bucket from the previous month, and one from the same month-number
    /// a year earlier, must both be excluded from month-to-date — only the
    /// exact (year, month) of `now` counts.
    func testMonthlyForecastExcludesPreviousMonthAndYear() {
        let now = date(2026, 3, 10)
        let daily = [
            combinedDay(date(2026, 2, 28), usd: 500),   // previous month, same year
            combinedDay(date(2025, 3, 10), usd: 500),   // same month-number, previous year
            combinedDay(date(2026, 3, 5), usd: 20),     // in-month
        ]
        let f = MonthlyForecast.build(daily: daily, budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertEqual(f.monthToDateUSD, 20, accuracy: 0.001)
    }

    /// A same-month bucket dated after today, a negative `usd`, and a NaN
    /// `usd` must each be dropped rather than inflating/poisoning/shrinking
    /// month-to-date — only the one genuinely valid past-or-today day counts.
    func testMonthlyForecastIgnoresFutureNegativeAndNonFiniteBucketsButKeepsValidOne() {
        let now = date(2026, 3, 10)
        let daily = [
            combinedDay(date(2026, 3, 5), usd: 20),          // valid: in-month, on/before today
            combinedDay(date(2026, 3, 15), usd: 1_000),      // future date (same month) — excluded
            combinedDay(date(2026, 3, 8), usd: -50),         // negative — ignored, not subtracted
            combinedDay(date(2026, 3, 9), usd: Double.nan),  // non-finite — must not poison the sum
        ]
        let f = MonthlyForecast.build(daily: daily, budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertFalse(f.monthToDateUSD.isNaN)
        XCTAssertEqual(f.monthToDateUSD, 20, accuracy: 0.001)
    }

    /// No budget configured: `budgetUSD`/`status`/`remainingBudgetUSD`/
    /// `progressFraction` all read as `nil` — the card hides itself.
    func testMonthlyForecastNoBudgetConfigured() {
        let now = date(2026, 3, 10)
        let f = MonthlyForecast.build(
            daily: [combinedDay(now, usd: 5)], budgetUSD: nil, now: now, calendar: calendar)
        XCTAssertNil(f.budgetUSD)
        XCTAssertNil(f.status)
        XCTAssertNil(f.remainingBudgetUSD)
        XCTAssertNil(f.progressFraction)
    }

    /// Zero, negative, and non-finite budgets all normalize to "not configured".
    func testMonthlyForecastInvalidOrNonpositiveBudgetNormalizesToNil() {
        let now = date(2026, 3, 10)
        for invalid in [0.0, -25.0, Double.nan, Double.infinity] {
            let f = MonthlyForecast.build(daily: [], budgetUSD: invalid, now: now, calendar: calendar)
            XCTAssertNil(f.budgetUSD, "budget \(invalid) should normalize to nil")
            XCTAssertNil(f.status)
        }
    }

    /// Month-to-date is still under budget, but the linear projection to
    /// month-end exceeds it → `.forecastOver`, not `.alreadyOver`.
    func testMonthlyForecastStatusForecastOverNotYetOver() {
        let now = date(2026, 3, 5)   // day 5 of a 31-day month
        let f = MonthlyForecast.build(
            daily: [combinedDay(now, usd: 50)], budgetUSD: 200, now: now, calendar: calendar)
        // dailyAverage = 50/5 = 10; projected = 10*31 = 310 > 200; MTD 50 < 200.
        XCTAssertEqual(f.status, .forecastOver)
        XCTAssertLessThan(f.monthToDateUSD, f.budgetUSD!)
        XCTAssertGreaterThan(f.projectedTotalUSD, f.budgetUSD!)
    }

    /// Month-to-date has already exceeded the budget — reported as
    /// `.alreadyOver` even though the projection is (necessarily) also over.
    func testMonthlyForecastStatusAlreadyOver() {
        let now = date(2026, 3, 5)
        let f = MonthlyForecast.build(
            daily: [combinedDay(now, usd: 300)], budgetUSD: 200, now: now, calendar: calendar)
        XCTAssertEqual(f.status, .alreadyOver)
        XCTAssertEqual(f.remainingBudgetUSD ?? 1, -100, accuracy: 0.001)
    }

    /// Zero spend this month with a budget configured is `.onTrack`, not an
    /// error state — projected/MTD are both exactly zero.
    func testMonthlyForecastZeroSpendMonth() {
        let now = date(2026, 3, 10)
        let daily = (1...10).map { combinedDay(date(2026, 3, $0), usd: 0) }
        let f = MonthlyForecast.build(daily: daily, budgetUSD: 100, now: now, calendar: calendar)
        XCTAssertEqual(f.monthToDateUSD, 0, accuracy: 0.001)
        XCTAssertEqual(f.projectedTotalUSD, 0, accuracy: 0.001)
        XCTAssertEqual(f.status, .onTrack)
    }

    // MARK: - Phase 3: MonthlyForecast per-source (pure)

    private func combinedDay(_ d: Date, claudeUSD: Double = 0, codexUSD: Double = 0, grokUSD: Double = 0) -> CombinedDailyUsage {
        CombinedDailyUsage(date: d, claudeUSD: claudeUSD, claudeTokens: 0,
                           codexUSD: codexUSD, codexTokens: 0, grokUSD: grokUSD, grokTokens: 0)
    }

    /// Per-source forecast (`.claude`) sums only `claudeUSD`, ignoring the
    /// same day's `codexUSD` entirely — a Codex budget never leaks into a
    /// Claude-only forecast and vice versa.
    func testMonthlyForecastPerSourceUsesOnlyThatSourcesUSD() {
        let now = date(2026, 3, 10)
        let daily = [combinedDay(date(2026, 3, 5), claudeUSD: 20, codexUSD: 100)]
        let claudeForecast = MonthlyForecast.build(daily: daily, budgetUSD: 50, source: .claude, now: now, calendar: calendar)
        let codexForecast = MonthlyForecast.build(daily: daily, budgetUSD: 50, source: .codex, now: now, calendar: calendar)
        XCTAssertEqual(claudeForecast.monthToDateUSD, 20, accuracy: 0.001)
        XCTAssertEqual(codexForecast.monthToDateUSD, 100, accuracy: 0.001)
    }

    /// A non-finite value in ANOTHER source's field must not poison or
    /// exclude this source's own valid value — each source's validity is
    /// judged independently, not via the combined `usd` getter (which would
    /// itself be NaN here).
    func testMonthlyForecastPerSourceIgnoresOtherSourcesInvalidValue() {
        let now = date(2026, 3, 10)
        let daily = [combinedDay(date(2026, 3, 5), claudeUSD: 20, codexUSD: Double.nan)]
        let claudeForecast = MonthlyForecast.build(daily: daily, budgetUSD: 50, source: .claude, now: now, calendar: calendar)
        XCTAssertFalse(claudeForecast.monthToDateUSD.isNaN)
        XCTAssertEqual(claudeForecast.monthToDateUSD, 20, accuracy: 0.001)
    }

    /// This source's own negative/non-finite value is excluded (contributes
    /// 0) — same rule as the combined `.total` case, scoped to one field.
    func testMonthlyForecastPerSourceExcludesOwnInvalidValue() {
        let now = date(2026, 3, 10)
        let daily = [
            combinedDay(date(2026, 3, 5), claudeUSD: 20),
            combinedDay(date(2026, 3, 6), claudeUSD: -5),
            combinedDay(date(2026, 3, 7), claudeUSD: Double.nan),
        ]
        let f = MonthlyForecast.build(daily: daily, budgetUSD: 50, source: .claude, now: now, calendar: calendar)
        XCTAssertEqual(f.monthToDateUSD, 20, accuracy: 0.001)
    }

    /// Omitting `source` preserves the pre-existing combined-budget
    /// behavior — the default must still sum every source.
    func testMonthlyForecastDefaultSourceIsTotal() {
        let now = date(2026, 3, 10)
        let daily = [combinedDay(date(2026, 3, 5), claudeUSD: 20, codexUSD: 30, grokUSD: 5)]
        let f = MonthlyForecast.build(daily: daily, budgetUSD: 100, now: now, calendar: calendar)
        XCTAssertEqual(f.monthToDateUSD, 55, accuracy: 0.001)
    }

    /// Independent per-source status: Codex over its own (small) budget
    /// while Claude, spending less but against a larger budget, stays on
    /// track — proves the two forecasts don't share state.
    func testMonthlyForecastPerSourceIndependentStatus() {
        let now = date(2026, 3, 5)
        let daily = [combinedDay(date(2026, 3, 5), claudeUSD: 10, codexUSD: 300)]
        let claudeForecast = MonthlyForecast.build(daily: daily, budgetUSD: 200, source: .claude, now: now, calendar: calendar)
        let codexForecast = MonthlyForecast.build(daily: daily, budgetUSD: 200, source: .codex, now: now, calendar: calendar)
        XCTAssertEqual(claudeForecast.status, .onTrack)
        XCTAssertEqual(codexForecast.status, .alreadyOver)
    }
}
