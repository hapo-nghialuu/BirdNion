import XCTest
@testable import BirdNion

/// Pure-decision tests for `WeeklyDigest`: suppression rules, rolling-7-day
/// windows, deterministic top source/model, budget/forecast reuse, and
/// cadence gating. No I/O — reports are hand-built fixtures, mirroring
/// `CombinedUsageReportTests`'s helper style.
final class WeeklyDigestTests: XCTestCase {
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
                              confidence: CostHistoryStore.UsageScanConfidence = .unavailable
    ) -> ClaudeUsageReport {
        ClaudeUsageReport(todayUSD: 0, todayTokens: 0, last30USD: 0, last30Tokens: 0,
                          daily: daily, topModel: nil, scanConfidence: confidence)
    }

    private func codexReport(daily: [CodexDailyUsage],
                             confidence: CostHistoryStore.UsageScanConfidence = .unavailable
    ) -> CodexUsageReport {
        CodexUsageReport(todayUSD: 0, todayTokens: 0, last30USD: 0, last30Tokens: 0,
                         daily: daily, topModel: nil, scanConfidence: confidence)
    }

    private func liveConfidence() -> CostHistoryStore.UsageScanConfidence {
        CostHistoryStore.UsageScanConfidence(included: true, live: true, scannedAt: now)
    }

    private func historyOnlyConfidence() -> CostHistoryStore.UsageScanConfidence {
        CostHistoryStore.UsageScanConfidence(included: true, live: false, scannedAt: now)
    }

    // MARK: - Suppression (contract #3 / #4)

    func testSuppressesWhenNoSourceIsLive() {
        // Activity is real, but the only source is history-only this cycle.
        let claude = claudeReport(
            daily: (0...6).map { claudeDay(-$0, usd: 1, tokens: 100) },
            confidence: historyOnlyConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertFalse(evaluation.shouldSend)
        XCTAssertTrue(evaluation.body.isEmpty)
    }

    func testSuppressesWhenActivityIsZeroEvenIfLive() {
        let claude = claudeReport(daily: [], confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertFalse(evaluation.shouldSend)
    }

    func testSendsWithCaveatWhenOneSourceIsLiveAndAnotherIsHistoryOnly() {
        let claude = claudeReport(
            daily: (0...6).map { claudeDay(-$0, usd: 2, tokens: 200) },
            confidence: liveConfidence())
        let codex = codexReport(
            daily: (0...6).map { codexDay(-$0, usd: 1, tokens: 100) },
            confidence: historyOnlyConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertTrue(evaluation.shouldSend)
        XCTAssertEqual(evaluation.nonLiveSources, [.codex])
        XCTAssertTrue(evaluation.body.contains("Codex"))
    }

    func testUnavailableEnabledSourceAppearsInCaveat() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 2, tokens: 200)],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertTrue(evaluation.shouldSend)
        XCTAssertEqual(evaluation.nonLiveSources, [.codex])
        XCTAssertTrue(evaluation.body.contains("Codex"))
    }

    // MARK: - Change percent (contract #7 / #9)

    func testChangePercentIsNilWhenPriorWeekIsZero() {
        let claude = claudeReport(
            daily: (0...6).map { claudeDay(-$0, usd: 5, tokens: 500) },
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertNil(evaluation.changePercent)
        XCTAssertTrue(evaluation.shouldSend)
    }

    func testChangePercentComparesAgainstPriorWeek() {
        var days: [ClaudeDailyUsage] = []
        for offset in 7...13 { days.append(claudeDay(-offset, usd: 1, tokens: 100)) }  // prior week: $7
        for offset in 0...6 { days.append(claudeDay(-offset, usd: 2, tokens: 200)) }   // current week: $14
        let claude = claudeReport(daily: days, confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertEqual(evaluation.priorUSD, 7, accuracy: 0.001)
        XCTAssertEqual(evaluation.currentUSD, 14, accuracy: 0.001)
        XCTAssertEqual(evaluation.changePercent ?? -999, 100, accuracy: 0.001)
    }

    // MARK: - Deterministic top source / model (contract #9)

    func testTopSourceIsDeterministicOnTieBreak() {
        // Equal tokens and USD across claude/codex — the id name (ascending)
        // breaks the tie, so "claude" always wins over "codex".
        let claude = claudeReport(daily: [claudeDay(-1, usd: 1, tokens: 100)], confidence: liveConfidence())
        let codex = codexReport(daily: [codexDay(-1, usd: 1, tokens: 100)], confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertEqual(evaluation.topSource, .claude)
    }

    func testTopModelIsDeterministicByTokensThenUSD() {
        let claude = claudeReport(
            daily: [claudeDay(-1, usd: 1, tokens: 50,
                              models: [ClaudeDailyModel(name: "model-a", usd: 1, tokens: 50)])],
            confidence: liveConfidence())
        let codex = codexReport(
            daily: [codexDay(-1, usd: 5, tokens: 200,
                             models: [CodexDailyModel(name: "model-b", usd: 5, tokens: 200)])],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertEqual(evaluation.topModel?.name, "model-b")
        XCTAssertEqual(evaluation.topModel?.source, "codex")
    }

    func testTopModelUsesSourceAsFinalTieBreak() {
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 1, tokens: 50,
                              models: [ClaudeDailyModel(name: "same", usd: 1, tokens: 50)])],
            confidence: liveConfidence())
        let codex = codexReport(
            daily: [codexDay(0, usd: 1, tokens: 50,
                             models: [CodexDailyModel(name: "same", usd: 1, tokens: 50)])],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar)

        XCTAssertEqual(evaluation.topModel?.source, "claude")
    }

    // MARK: - Budget / forecast reuse (contract #7 / #8)

    func testForecastReflectsAlreadyOverBudget() {
        // Today is part of both the rolling digest and month-to-date forecast.
        let claude = claudeReport(
            daily: [claudeDay(0, usd: 500, tokens: 1000)],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: 10, now: now, calendar: calendar, language: "en")

        XCTAssertTrue(evaluation.shouldSend)
        XCTAssertEqual(evaluation.forecast.status, .alreadyOver)
        XCTAssertEqual(evaluation.forecast.budgetUSD, 10)
        XCTAssertTrue(evaluation.body.contains("Already over budget"))
    }

    func testForecastHidesBudgetWhenNotConfigured() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 1, tokens: 10)], confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, now: now, calendar: calendar, language: "en")

        XCTAssertNil(evaluation.forecast.budgetUSD)
        XCTAssertNil(evaluation.forecast.status)
        XCTAssertTrue(evaluation.shouldSend)
        XCTAssertFalse(evaluation.body.contains("Monthly forecast"))
    }

    // MARK: - Cadence (contract #6)

    func testIsDueWhenNeverEvaluated() {
        XCTAssertTrue(WeeklyDigest.isDue(now: now, lastEvaluatedAt: nil))
    }

    func testIsNotDueBeforeSevenDays() {
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 3600)
        XCTAssertFalse(WeeklyDigest.isDue(now: now, lastEvaluatedAt: sixDaysAgo))
    }

    func testIsDueAfterSevenDays() {
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 3600)
        XCTAssertTrue(WeeklyDigest.isDue(now: now, lastEvaluatedAt: eightDaysAgo))
    }

    // MARK: - Sanitize label (contract #7 privacy)

    func testSanitizeLabelStripsControlCharactersAndClampsLength() {
        let raw = "model\nnamewith\tcontrol" + String(repeating: "x", count: 60)
        let sanitized = WeeklyDigest.sanitizeLabel(raw, maxLength: 20)

        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\t"))
        XCTAssertEqual(sanitized.count, 21)  // 20 chars + ellipsis
        XCTAssertTrue(sanitized.hasSuffix("…"))
    }
}
