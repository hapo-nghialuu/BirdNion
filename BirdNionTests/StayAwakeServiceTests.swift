import XCTest
@testable import BirdNion

final class StayAwakeServiceTests: XCTestCase {

    @MainActor
    func testShouldHoldAssertionRequiresEnabledAndFreshActivity() {
        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let stale = now.addingTimeInterval(-(StayAwakeConfig.activityFreshness + 60))

        XCTAssertTrue(StayAwakeService.shouldHoldAssertion(
            latestActivityAt: fresh, now: now, enabled: true,
            freshness: StayAwakeConfig.activityFreshness))
        XCTAssertFalse(StayAwakeService.shouldHoldAssertion(
            latestActivityAt: fresh, now: now, enabled: false,
            freshness: StayAwakeConfig.activityFreshness))
        XCTAssertFalse(StayAwakeService.shouldHoldAssertion(
            latestActivityAt: stale, now: now, enabled: true,
            freshness: StayAwakeConfig.activityFreshness))
        XCTAssertFalse(StayAwakeService.shouldHoldAssertion(
            latestActivityAt: nil, now: now, enabled: true,
            freshness: StayAwakeConfig.activityFreshness))
    }

    func testLatestActivityFindsNewestFileAcrossRoots() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootA = dir.appendingPathComponent("a", isDirectory: true)
        let rootB = dir.appendingPathComponent("b/nested", isDirectory: true)
        let missing = dir.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let old = rootA.appendingPathComponent("old.jsonl")
        let new = rootB.appendingPathComponent("new.jsonl")
        try Data().write(to: old)
        try Data().write(to: new)
        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: new.path)

        let latest = StayAwakeService.latestActivity(in: [rootA, missing, rootB])
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest!.timeIntervalSince1970, newDate.timeIntervalSince1970, accuracy: 1)
    }

    func testLatestActivityIgnoresEmptyAndMissingRoots() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(StayAwakeService.latestActivity(
            in: [dir, dir.appendingPathComponent("nope")]))
    }

    @MainActor
    func testTickReleasesAssertionWhenDisabled() {
        var enabled = true
        let service = StayAwakeService(
            rootsProvider: { [] },
            enabled: { enabled })
        // Even with no roots, a disabled toggle must release/never acquire.
        service.tick()
        enabled = false
        service.tick()
        XCTAssertFalse(service.isHoldingAssertion)
    }
}
