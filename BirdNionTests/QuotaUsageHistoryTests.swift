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
}
