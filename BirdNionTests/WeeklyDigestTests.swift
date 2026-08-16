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

    private func grokDay(_ offset: Int, usd: Double, tokens: Int) -> GrokDailyUsage {
        GrokDailyUsage(date: day(offset), usd: usd, tokens: tokens, models: [])
    }

    private func grokReport(daily: [GrokDailyUsage],
                            confidence: CostHistoryStore.UsageScanConfidence = .unavailable
    ) -> GrokUsageReport {
        GrokUsageReport(todayUSD: 0, todayTokens: 0, last30USD: 0, last30Tokens: 0,
                        daily: daily, topModel: nil, scanConfidence: confidence)
    }

    /// Fixed calendar date — for forecast-status assertions that depend on
    /// `daysElapsed`/`daysInMonth` (e.g. `.forecastOver` vs `.onTrack`), the
    /// class's live `now`/`day(offset)` would make the expected status
    /// depend on which real-world day the suite happens to run on. Mirrors
    /// `CombinedUsageReportTests`'s `date(_:_:_:)` helper.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comp = DateComponents()
        comp.year = year; comp.month = month; comp.day = day
        return calendar.date(from: comp)!
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

    // MARK: - Per-provider budget risk (independent of the total budget)

    /// A configured, live-confidence Codex weekly budget that the linear
    /// forecast projects to exceed surfaces a risk line — even though the
    /// combined (total) budget stays unconfigured.
    /// Monday start-of-week + $50 spend → daysElapsed=1, projected 50*7=350 > 200.
    /// Dates are built with the same Monday-first GMT calendar passed to evaluate
    /// so week boundaries don't shift under local TZ / firstWeekday.
    func testPerProviderBudgetSurfacesForecastOverRiskLine() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2 // Monday
        var comp = DateComponents()
        comp.year = 2026; comp.month = 3; comp.day = 9 // Monday
        let fixedNow = cal.date(from: comp)!
        let claude = claudeReport(
            daily: [ClaudeDailyUsage(date: fixedNow, usd: 1, tokens: 10, models: [])],
            confidence: liveConfidence())
        let codex = codexReport(
            daily: [CodexDailyUsage(date: fixedNow, usd: 50, tokens: 10, models: [])],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, claudeBudgetUSD: nil, codexBudgetUSD: 200, grokBudgetUSD: nil,
            now: fixedNow, calendar: cal, language: "en")

        XCTAssertEqual(evaluation.providerBudgetRisks.count, 1)
        XCTAssertEqual(evaluation.providerBudgetRisks.first?.source, .codex)
        XCTAssertEqual(evaluation.providerBudgetRisks.first?.status, .forecastOver)
        XCTAssertEqual(evaluation.providerBudgetRisks.first?.projectedTotalUSD, 350)
        XCTAssertTrue(evaluation.body.contains("Codex"), evaluation.body)
        XCTAssertTrue(evaluation.body.contains("350"), evaluation.body)
        XCTAssertTrue(evaluation.body.contains("200"), evaluation.body)
    }

    /// Month-to-date already past a provider's own budget → `.alreadyOver`,
    /// worded distinctly from `.forecastOver` in the digest body.
    func testPerProviderBudgetSurfacesAlreadyOverRiskLine() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 500, tokens: 1000)], confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, claudeBudgetUSD: 10, codexBudgetUSD: nil, grokBudgetUSD: nil,
            now: now, calendar: calendar, language: "en")

        XCTAssertEqual(evaluation.providerBudgetRisks.first?.status, .alreadyOver)
        XCTAssertTrue(evaluation.body.contains("Claude"))
        XCTAssertTrue(evaluation.body.contains("already over budget"))
    }

    /// A provider on track against its own budget contributes no risk line
    /// — the digest only calls out risk, staying concise.
    func testPerProviderBudgetOnTrackProducesNoRiskLine() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 1, tokens: 10)], confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: nil, grok: nil,
            includeClaude: true, includeCodex: false, includeGrok: false,
            budgetUSD: nil, claudeBudgetUSD: 1_000, codexBudgetUSD: nil, grokBudgetUSD: nil,
            now: now, calendar: calendar, language: "en")

        XCTAssertTrue(evaluation.providerBudgetRisks.isEmpty)
    }

    /// Trust rule: a configured budget for a source whose confidence is
    /// `.unavailable` (never landed a scan) must never produce a risk line
    /// — an implicit zero must not be reported as "on track" or "over".
    func testPerProviderBudgetNeverRisksAnUnavailableSource() {
        let grok = grokReport(daily: [], confidence: .unavailable)

        let evaluation = WeeklyDigest.evaluate(
            claude: nil, codex: nil, grok: grok,
            includeClaude: false, includeCodex: false, includeGrok: true,
            budgetUSD: nil, claudeBudgetUSD: nil, codexBudgetUSD: nil, grokBudgetUSD: 10,
            now: now, calendar: calendar, language: "en")

        XCTAssertTrue(evaluation.providerBudgetRisks.isEmpty)
        XCTAssertFalse(evaluation.body.contains("Grok"))
    }

    /// History-only confidence (a landed scan that just isn't live this
    /// cycle) still calculates a risk line — only `.unavailable` is gated.
    func testPerProviderBudgetCalculatesForHistoryOnlyConfidence() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 1, tokens: 10)], confidence: liveConfidence())
        let codex = codexReport(daily: [codexDay(0, usd: 500, tokens: 10)], confidence: historyOnlyConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, claudeBudgetUSD: nil, codexBudgetUSD: 10, grokBudgetUSD: nil,
            now: now, calendar: calendar, language: "en")

        XCTAssertEqual(evaluation.providerBudgetRisks.first?.source, .codex)
        XCTAssertEqual(evaluation.providerBudgetRisks.first?.status, .alreadyOver)
    }

    /// Independent budgets/statuses: Claude already-over its own (small)
    /// budget while Codex, spending more but against a larger budget, stays
    /// on track and produces no line of its own. Pinned to day 5 of a
    /// 31-day month: codex dailyAvg 60/5=12, projected 12*31=372<1_000 →
    /// `.onTrack` regardless of real-world test-run date (day 1 with the
    /// live `now`/`day(offset)` helpers would have projected 60*31=1_860,
    /// wrongly forecast-over).
    func testPerProviderBudgetsAreIndependentAcrossSources() {
        let fixedNow = date(2026, 3, 5)
        let claude = claudeReport(
            daily: [ClaudeDailyUsage(date: fixedNow, usd: 50, tokens: 10, models: [])],
            confidence: liveConfidence())
        let codex = codexReport(
            daily: [CodexDailyUsage(date: fixedNow, usd: 60, tokens: 10, models: [])],
            confidence: liveConfidence())

        let evaluation = WeeklyDigest.evaluate(
            claude: claude, codex: codex, grok: nil,
            includeClaude: true, includeCodex: true, includeGrok: false,
            budgetUSD: nil, claudeBudgetUSD: 10, codexBudgetUSD: 1_000, grokBudgetUSD: nil,
            now: fixedNow, calendar: calendar, language: "en")

        XCTAssertEqual(evaluation.providerBudgetRisks.count, 1)
        XCTAssertEqual(evaluation.providerBudgetRisks.first?.source, .claude)
    }

    /// Blank/invalid/non-positive per-provider budgets normalize to "off" —
    /// same rule as the combined budget — and never produce a risk line.
    func testPerProviderBudgetInvalidOrOffProducesNoRiskLine() {
        let claude = claudeReport(daily: [claudeDay(0, usd: 500, tokens: 10)], confidence: liveConfidence())

        for invalid in [0.0, -25.0, Double.nan, Double.infinity] {
            let evaluation = WeeklyDigest.evaluate(
                claude: claude, codex: nil, grok: nil,
                includeClaude: true, includeCodex: false, includeGrok: false,
                budgetUSD: nil, claudeBudgetUSD: invalid, codexBudgetUSD: nil, grokBudgetUSD: nil,
                now: now, calendar: calendar, language: "en")
            XCTAssertTrue(evaluation.providerBudgetRisks.isEmpty, "budget \(invalid) should normalize to off")
        }
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
