import XCTest
@testable import BirdNion
import CodexBarCore

/// Tests for `CodexCostScanner`, which delegates the actual log scan to
/// CodexBarCore's `CostUsageFetcher` and owns only the snapshot → summary
/// mapping and the history-window setting. Kept in its own file so the
/// `import CodexBarCore` (needed for `CostUsageTokenSnapshot`) doesn't clash
/// with BirdNion's own Codex types in `CodexProviderTests`.
final class CodexCostScannerTests: XCTestCase {
    func testMapsSnapshot() {
        // "session" totals are today's; "last30Days" totals span the window.
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 110,
            sessionCostUSD: 0.5,
            last30DaysTokens: 1050,
            last30DaysCostUSD: 4.25,
            daily: [],
            updatedAt: Date())
        let s = CodexCostScanner.map(snap)
        XCTAssertEqual(s.todayTokens, 110)
        XCTAssertEqual(s.todayUSD, 0.5)
        XCTAssertEqual(s.last30Tokens, 1050)
        XCTAssertEqual(s.last30USD, 4.25)
        XCTAssertFalse(s.isEmpty)
    }

    func testMapsNilTotalsToZero() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil,
            daily: [], updatedAt: Date())
        let s = CodexCostScanner.map(snap)
        XCTAssertEqual(s.todayTokens, 0)
        XCTAssertEqual(s.last30Tokens, 0)
        XCTAssertTrue(s.isEmpty)
    }

    func testHistoryDaysDefaultsAndClamps() {
        let key = CodexCostScanner.historyDaysKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 30)   // unset → default
        UserDefaults.standard.set(500, forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 365)  // clamped high
        UserDefaults.standard.set(-5, forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 1)    // clamped low
    }

    // MARK: - Full report (chart)

    private static func dayString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// `mapReport` builds a contiguous chartWindowDays series (heatmap window), reads
    /// "today" from the most recent active day, sums the strict-30-day totals
    /// from the trailing buckets, sorts per-day models by cost, and picks the
    /// highest-cost top model — matching CodexBar.
    func testMapsReportDaily() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let snap = CostUsageTokenSnapshot(
            sessionTokens: 999, sessionCostUSD: 9.99,   // session is ignored by the report
            last30DaysTokens: 314_000_000,
            last30DaysCostUSD: 311.01,
            daily: [
                .init(date: Self.dayString(yesterday),
                      inputTokens: nil, outputTokens: nil, totalTokens: 4_000_000,
                      costUSD: 6.71, modelsUsed: ["gpt-5.5"],
                      modelBreakdowns: [.init(modelName: "gpt-5.5", costUSD: 6.71, totalTokens: 4_000_000)]),
                .init(date: Self.dayString(today),
                      inputTokens: nil, outputTokens: nil, totalTokens: 5_000_000,
                      costUSD: 3.20, modelsUsed: ["gpt-5.5", "o3"],
                      modelBreakdowns: [
                          .init(modelName: "o3", costUSD: 1.20, totalTokens: 2_000_000),
                          .init(modelName: "gpt-5.5", costUSD: 2.00, totalTokens: 3_000_000),
                      ]),
            ],
            updatedAt: now)

        let r = CodexCostScanner.mapReport(snap, now: now)

        XCTAssertEqual(r.daily.count, CodexCostScanner.chartWindowDays)
        XCTAssertFalse(r.isEmpty)
        // Strict 30-day totals are summed from the trailing daily buckets
        // (the snapshot's own last30 fields span the 90-day fetch window).
        XCTAssertEqual(r.last30Tokens, 9_000_000)
        XCTAssertEqual(r.last30USD, 9.91, accuracy: 0.001)
        // "Today" = the most recent active day (today's bucket), not the session.
        XCTAssertEqual(r.todayTokens, 5_000_000)
        XCTAssertEqual(r.todayUSD, 3.20, accuracy: 0.001)
        // Newest bucket is today; its per-model rows are sorted by cost desc.
        let last = r.daily.last!
        XCTAssertEqual(last.tokens, 5_000_000)
        XCTAssertEqual(last.models.count, 2)
        XCTAssertEqual(last.models.first?.name, "gpt-5.5")  // $2.00 > $1.20
        // Top model across the window by summed cost: gpt-5.5 (6.71+2.00) > o3 (1.20).
        XCTAssertEqual(r.topModel, "gpt-5.5")
    }

    /// Totals are summed from the daily buckets even when the snapshot omits
    /// its own window fields; no models → nil topModel.
    func testMapsReportFallbackTokens() {
        let now = Date()
        let snap = CostUsageTokenSnapshot(
            sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil,
            daily: [
                .init(date: Self.dayString(now),
                      inputTokens: nil, outputTokens: nil, totalTokens: 1_234,
                      costUSD: 1.0, modelsUsed: nil, modelBreakdowns: nil),
            ],
            updatedAt: now)

        let r = CodexCostScanner.mapReport(snap, now: now)
        XCTAssertEqual(r.daily.count, CodexCostScanner.chartWindowDays)
        XCTAssertEqual(r.last30Tokens, 1_234)   // summed from daily buckets
        XCTAssertEqual(r.last30USD, 1.0, accuracy: 0.001)
        XCTAssertNil(r.topModel)                // no model breakdowns logged
    }
}
