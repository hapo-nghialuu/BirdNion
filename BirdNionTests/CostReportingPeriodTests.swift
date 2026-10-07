import XCTest
@testable import BirdNion

final class CostReportingPeriodTests: XCTestCase {

    private func day(_ date: Date, usd: Double) -> CombinedDailyUsage {
        CombinedDailyUsage(
            date: date,
            claudeUSD: usd, claudeTokens: 0,
            codexUSD: 0, codexTokens: 0)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    // Fixed periods slice the trailing N days.
    func testFixedPeriodSlicesTrailingDays() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let daily = Array((0..<10).map {
            day(cal.date(byAdding: .day, value: -$0, to: now)!, usd: 1)
        }.reversed())

        XCTAssertEqual(CostReportingPeriod.week.slice(daily, calendar: cal, now: now).count, 7)
        XCTAssertEqual(CostReportingPeriod.day.slice(daily, calendar: cal, now: now).count, 1)
        XCTAssertEqual(CostReportingPeriod.month.slice(daily, calendar: cal, now: now).count, 10)
    }

    // Month-to-date keeps only days inside the current calendar month.
    func testMonthToDateKeepsCurrentMonth() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let inMonth = [
            day(cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, usd: 1),
            day(cal.date(from: DateComponents(year: 2026, month: 10, day: 4))!, usd: 2),
        ]
        let outMonth = day(cal.date(from: DateComponents(year: 2026, month: 9, day: 30))!, usd: 9)
        let sliced = CostReportingPeriod.monthToDate.slice([outMonth] + inMonth,
                                                           calendar: cal, now: now)
        XCTAssertEqual(sliced.count, 2)
        XCTAssertEqual(sliced.reduce(0) { $0 + $1.usd }, 3)
    }

    // All-history keeps every day.
    func testAllHistoryKeepsEverything() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let daily = (0..<200).map {
            day(cal.date(byAdding: .day, value: -$0, to: now)!, usd: 1)
        }
        XCTAssertEqual(CostReportingPeriod.allHistory.slice(daily, calendar: cal, now: now).count, 200)
    }

    // Legacy popover.allChartDays day-counts map onto fixed periods.
    func testLegacyDayCountMigration() {
        XCTAssertEqual(CostReportingPeriod(legacyDays: 1), .day)
        XCTAssertEqual(CostReportingPeriod(legacyDays: 7), .week)
        XCTAssertEqual(CostReportingPeriod(legacyDays: 30), .month)
        XCTAssertEqual(CostReportingPeriod(legacyDays: 90), .quarter)
        XCTAssertEqual(CostReportingPeriod(legacyDays: 120), .season)
        XCTAssertNil(CostReportingPeriod(legacyDays: 0))
    }
}
