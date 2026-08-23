import XCTest
@testable import BirdNion

final class WeeklyActivityBucketBuilderTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_700_000_000) // Fixed deterministic epoch
    }

    func testBuildReturnsExactlyFiftyTwoChronologicalWeeks() {
        let doc = CostHistoryStore.Document(version: 1, sources: [:], scannedAt: [:])
        let window = WeeklyActivityBucketBuilder.build(
            document: doc,
            sources: [.claude],
            now: now,
            calendar: calendar,
            weekCount: 52
        )
        XCTAssertEqual(window.weeks.count, 52)
        for i in 1..<window.weeks.count {
            XCTAssertTrue(window.weeks[i].startDate > window.weeks[i - 1].startDate)
        }
    }

    func testMissingWeekRemainsNoEvidenceWhileZeroDayIsEvidence() {
        let doc = CostHistoryStore.Document(
            version: 1,
            sources: [
                "claude": [
                    "2023-11-14": .init(usd: 0, tokens: 0, models: [])
                ]
            ],
            scannedAt: [:]
        )
        let window = WeeklyActivityBucketBuilder.build(
            document: doc,
            sources: [.claude],
            now: now,
            calendar: calendar,
            weekCount: 52
        )
        let withEvidence = window.weeks.filter(\.hasEvidence)
        XCTAssertEqual(withEvidence.count, 1)
        XCTAssertEqual(withEvidence.first?.usd, 0)
        XCTAssertEqual(withEvidence.first?.activeDays, 0)
    }

    func testOutOfWindowEvidenceIsExcluded() {
        let doc = CostHistoryStore.Document(
            version: 1,
            sources: [
                "claude": [
                    "2010-01-01": .init(usd: 50, tokens: 1000, models: [])
                ]
            ],
            scannedAt: [:]
        )
        let window = WeeklyActivityBucketBuilder.build(
            document: doc,
            sources: [.claude],
            now: now,
            calendar: calendar,
            weekCount: 52
        )
        XCTAssertFalse(window.hasData)
        XCTAssertEqual(window.totalUSD, 0)
    }

    func testSnapshotAggregatesMappedSourcesAndCountsActiveDays() {
        let doc = CostHistoryStore.Document(
            version: 1,
            sources: [
                "claude": [
                    "2023-11-14": .init(usd: 10, tokens: 500, models: [])
                ],
                "codex": [
                    "2023-11-14": .init(usd: 5, tokens: 200, models: []),
                    "2023-11-15": .init(usd: 2, tokens: 100, models: [])
                ]
            ],
            scannedAt: [:]
        )
        let snapshot = WeeklyActivityBucketBuilder.buildSnapshot(
            document: doc,
            agentIDs: [.claude, .codex],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.overall.totalUSD, 17)
        XCTAssertEqual(snapshot.byAgent[.claude]?.totalUSD, 10)
        XCTAssertEqual(snapshot.byAgent[.codex]?.totalUSD, 7)
    }
}
