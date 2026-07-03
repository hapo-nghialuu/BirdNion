import XCTest
@testable import BirdNion

final class QuotaServicePollingTests: XCTestCase {
    @MainActor
    func testRefreshHandlesThrowingProvider() async {
        let happy = StubProvider(id: "h", displayName: "H",
                                 status: ProviderStatus(id: "h", displayName: "H",
                                                       windows: [
                                                         QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90),
                                                         QuotaWindow(label: "Tuần", usedPct: 20, remainingPct: 80)
                                                       ], lastUpdated: Date(), error: nil))
        let bad = ThrowingProvider(id: "b", displayName: "B")
        let svc = QuotaService(providers: [happy, bad], interval: 0.1)
        await svc.refresh()
        await svc.refresh()
        XCTAssertEqual(svc.statuses.count, 2)
        let happyStatus = svc.statuses.first { $0.id == "h" }
        XCTAssertEqual(happyStatus?.windows.count, 2)
        let badStatus = svc.statuses.first { $0.id == "b" }
        XCTAssertNotNil(badStatus?.error)
    }

    @MainActor
    func testRefreshKeepsPreviousGoodStatusWhenProviderReturnsError() async {
        let provider = GoodThenErrorProvider(id: "claude", displayName: "Claude")
        let svc = QuotaService(providers: [provider], interval: 0.1)

        await svc.refresh()
        XCTAssertEqual(svc.statuses.first?.windows.first?.remainingPct, 80)

        await svc.refresh(forceProviderIDs: ["claude"])

        let status = svc.statuses.first
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.first?.remainingPct, 80)
        XCTAssertEqual(svc.displayStatuses.first?.windows.first?.remainingPct, 80)
    }

    @MainActor
    func testForcedRefreshBypassesProviderInterval() async {
        let provider = CountingProvider(id: "codex", displayName: "Codex")
        let svc = QuotaService(providers: [provider], interval: 3_600)

        await svc.refresh()
        XCTAssertEqual(provider.fetchCount, 1)

        await svc.refresh()
        XCTAssertEqual(provider.fetchCount, 1)

        await svc.refresh(forceProviderIDs: ["codex"])
        XCTAssertEqual(provider.fetchCount, 2)
    }
}

final class QuotaWarnConfigTests: XCTestCase {
    private let p = "test-prov-\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: QuotaWarnConfig.overrideKey(p, "session"))
        UserDefaults.standard.removeObject(forKey: QuotaWarnConfig.level1Key)
        UserDefaults.standard.removeObject(forKey: QuotaWarnConfig.level2Key)
        super.tearDown()
    }

    func testWindowKey() {
        XCTAssertEqual(QuotaWarnConfig.windowKey("Tuần"), "weekly")
        XCTAssertEqual(QuotaWarnConfig.windowKey("5 giờ"), "session")
    }

    func testGlobalDefaults() {
        XCTAssertEqual(QuotaWarnConfig.globalThresholds, [50, 20])
    }

    func testOverrideTakesPrecedence() {
        QuotaWarnConfig.setOverride(provider: p, window: "session", thresholds: [40, 15])
        XCTAssertTrue(QuotaWarnConfig.hasOverride(provider: p, window: "session"))
        XCTAssertEqual(QuotaWarnConfig.thresholds(provider: p, window: "session"), [40, 15])
        // Clearing falls back to global.
        QuotaWarnConfig.setOverride(provider: p, window: "session", thresholds: nil)
        XCTAssertFalse(QuotaWarnConfig.hasOverride(provider: p, window: "session"))
        XCTAssertEqual(QuotaWarnConfig.thresholds(provider: p, window: "session"), [50, 20])
    }

    func testCrossingFiresOnceThenReArms() {
        let thresholds = [50, 20]
        // Drop 90 -> 45 crosses 50 only.
        XCTAssertEqual(QuotaWarnConfig.crossings(previous: 90, current: 45, thresholds: thresholds, fired: []), [50])
        // Already fired 50, drop further to 18 crosses 20.
        XCTAssertEqual(QuotaWarnConfig.crossings(previous: 45, current: 18, thresholds: thresholds, fired: [50]), [20])
        // No re-fire while staying low.
        XCTAssertEqual(QuotaWarnConfig.crossings(previous: 18, current: 15, thresholds: thresholds, fired: [50, 20]), [])
        // Upward movement never fires.
        XCTAssertEqual(QuotaWarnConfig.crossings(previous: 15, current: 60, thresholds: thresholds, fired: []), [])
    }
}

private final class StubProvider: QuotaProvider {
    let id: String
    let displayName: String
    let status: ProviderStatus
    init(id: String, displayName: String, status: ProviderStatus) {
        self.id = id; self.displayName = displayName; self.status = status
    }
    func fetch() async throws -> ProviderStatus { status }
}

private final class ThrowingProvider: QuotaProvider {
    let id: String
    let displayName: String
    init(id: String, displayName: String) { self.id = id; self.displayName = displayName }
    func fetch() async throws -> ProviderStatus {
        throw NSError(domain: "test", code: 1)
    }
}

private final class CountingProvider: QuotaProvider {
    let id: String
    let displayName: String
    private(set) var fetchCount = 0

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    func fetch() async throws -> ProviderStatus {
        fetchCount += 1
        let count = fetchCount
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [QuotaWindow(label: "5 giờ", usedPct: count, remainingPct: 100 - count)],
            lastUpdated: Date())
    }
}

private final class GoodThenErrorProvider: QuotaProvider {
    let id: String
    let displayName: String
    private var fetchCount = 0

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    func fetch() async throws -> ProviderStatus {
        fetchCount += 1
        if fetchCount == 1 {
            return ProviderStatus(
                id: id,
                displayName: displayName,
                windows: [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)],
                lastUpdated: Date())
        }
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: "\(displayName): timeout")
    }
}
