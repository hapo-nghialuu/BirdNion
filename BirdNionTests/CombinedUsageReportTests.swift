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
                              last30USD: Double = 0, last30Tokens: Int = 0) -> ClaudeUsageReport {
        ClaudeUsageReport(todayUSD: 0, todayTokens: 0,
                          last30USD: last30USD, last30Tokens: last30Tokens,
                          daily: daily, topModel: nil)
    }

    private func codexReport(daily: [CodexDailyUsage],
                             todayUSD: Double = 0, todayTokens: Int = 0,
                             last30USD: Double = 0, last30Tokens: Int = 0) -> CodexUsageReport {
        CodexUsageReport(todayUSD: todayUSD, todayTokens: todayTokens,
                         last30USD: last30USD, last30Tokens: last30Tokens,
                         daily: daily, topModel: nil)
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

        XCTAssertEqual(r.daily.count, 90)
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
        XCTAssertEqual(empty.daily.count, 90)
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
}
