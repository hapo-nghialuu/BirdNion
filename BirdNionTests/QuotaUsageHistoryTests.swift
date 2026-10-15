import XCTest
@testable import BirdNion

final class QuotaUsageHistoryTests: XCTestCase {

    /// Burn 10%/day, 30% remaining → ~3 days of runway.
    func testRunwayDaysFromLinearBurn() {
        let now = Date()
        let samples = (0..<7).map { i in
            QuotaUsageSample(
                at: now.addingTimeInterval(TimeInterval(i - 6) * 86400),
                remainingPct: 90 - i * 10)
        }
        let runway = QuotaUsageHistory.runwayDays(samples: samples, now: now)
        XCTAssertNotNil(runway)
        XCTAssertEqual(runway!, 3.0, accuracy: 0.01)
    }

    /// Too few samples / too short a span → no forecast.
    func testRunwayDaysRequiresMinimumSpan() {
        let now = Date()
        let samples = [
            QuotaUsageSample(at: now.addingTimeInterval(-3600), remainingPct: 90),
            QuotaUsageSample(at: now, remainingPct: 85),
        ]
        XCTAssertNil(QuotaUsageHistory.runwayDays(samples: samples, now: now))
    }

    /// Samples older than the 7-day window are ignored.
    func testRunwayDaysIgnoresStaleSamples() {
        let now = Date()
        let samples = [
            QuotaUsageSample(at: now.addingTimeInterval(-30 * 86400), remainingPct: 90),
            QuotaUsageSample(at: now.addingTimeInterval(-20 * 86400), remainingPct: 50),
        ]
        XCTAssertNil(QuotaUsageHistory.runwayDays(samples: samples, now: now))
    }

    /// A flat or increasing remaining % means no depletion → no forecast.
    func testRunwayDaysNilWhenNotBurning() {
        let now = Date()
        let samples = [
            QuotaUsageSample(at: now.addingTimeInterval(-86400), remainingPct: 50),
            QuotaUsageSample(at: now, remainingPct: 50),
        ]
        XCTAssertNil(QuotaUsageHistory.runwayDays(samples: samples, now: now))
    }

    /// A refill (remaining % going up) restarts the slope — only the run
    /// after it counts, so the burn isn't diluted by the jump.
    func testRunwayDaysUsesRunAfterLatestRefill() {
        let now = Date()
        let samples = [
            QuotaUsageSample(at: now.addingTimeInterval(-4 * 86400), remainingPct: 90),
            QuotaUsageSample(at: now.addingTimeInterval(-3 * 86400), remainingPct: 10),
            QuotaUsageSample(at: now.addingTimeInterval(-2 * 86400), remainingPct: 100),
            QuotaUsageSample(at: now, remainingPct: 60),
        ]
        let runway = QuotaUsageHistory.runwayDays(samples: samples, now: now)
        XCTAssertNotNil(runway)
        // 40% over 2 days → 20%/day; 60% left → 3 days.
        XCTAssertEqual(runway!, 3.0, accuracy: 0.01)
    }
}

private struct StubSpendReport: SpendReport {
    let spendDays: [(date: Date, usd: Double)]
}

@MainActor
final class BudgetAlertsTests: XCTestCase {
    private let touchedKeys = [
        BudgetAlerts.enabledKey, "monthlyBudgetUSD", "claudeBudgetUSD",
        "codexBudgetUSD", "birdnion.budgetPeriod",
    ]
    private var posted: [String] = []
    private var deliver = true
    private var savedPoster: (@MainActor (String, String, String) async -> Bool)!

    override func setUp() async throws {
        BudgetAlerts.reset()
        savedPoster = BudgetAlerts.poster
        posted = []
        deliver = true
        BudgetAlerts.poster = { [unowned self] id, _, _ in
            posted.append(id)
            return deliver
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: BudgetAlerts.enabledKey)
        defaults.set("week", forKey: "birdnion.budgetPeriod")
        defaults.set(100.0, forKey: "monthlyBudgetUSD")
        defaults.set(0.0, forKey: "claudeBudgetUSD")
        defaults.set(0.0, forKey: "codexBudgetUSD")
    }

    override func tearDown() async throws {
        BudgetAlerts.poster = savedPoster
        BudgetAlerts.reset()
        for key in touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("budgetAlert.fired.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// A source that last scanned in the previous week must not carry that
    /// spend into the new week's combined total.
    func testCombinedTotalIgnoresPreviousPeriodSpend() async {
        let calendar = Calendar.current
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: Date())!
        BudgetAlerts.record(
            source: .claude,
            report: StubSpendReport(spendDays: [(calendar.startOfDay(for: lastWeek), 80)]),
            now: lastWeek)
        BudgetAlerts.record(
            source: .codex,
            report: StubSpendReport(spendDays: [(calendar.startOfDay(for: Date()), 25)]))
        await settle()
        XCTAssertEqual(posted, [])
    }

    func testCombinedTotalAlertsOncePerPeriod() async {
        let today = Calendar.current.startOfDay(for: Date())
        let report = StubSpendReport(spendDays: [(today, 120)])
        BudgetAlerts.record(source: .claude, report: report)
        await settle()
        BudgetAlerts.record(source: .claude, report: report)
        await settle()
        XCTAssertEqual(posted.count, 1)
    }

    /// An undelivered alert (e.g. notifications denied) isn't marked fired,
    /// so a later scan retries it.
    func testUndeliveredAlertRetriesOnNextScan() async {
        let today = Calendar.current.startOfDay(for: Date())
        let report = StubSpendReport(spendDays: [(today, 120)])
        deliver = false
        BudgetAlerts.record(source: .claude, report: report)
        await settle()
        deliver = true
        BudgetAlerts.record(source: .claude, report: report)
        await settle()
        XCTAssertEqual(posted.count, 2)
        let key = BudgetAlerts.firedKey(
            scope: "total", periodKey: BudgetAlerts.currentPeriod().key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }
}
