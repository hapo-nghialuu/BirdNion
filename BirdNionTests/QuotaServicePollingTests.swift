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
    func testCredentialErrorClearsPreviousGoodStatus() async {
        // A 401 means the shown numbers can't be trusted (key revoked/rotated),
        // so the stale good snapshot must be replaced by the error — unlike a
        // transient timeout, which preserves the last-good reading.
        let provider = GoodThenUnauthorizedProvider(id: "minimax", displayName: "MiniMax")
        let svc = QuotaService(providers: [provider], interval: 0.1)

        await svc.refresh()
        XCTAssertEqual(svc.statuses.first?.windows.first?.remainingPct, 80)

        await svc.refresh(forceProviderIDs: ["minimax"])

        let status = svc.statuses.first
        XCTAssertNotNil(status?.error)
        XCTAssertTrue(status?.windows.isEmpty ?? false)
        XCTAssertTrue(svc.displayStatuses.first?.windows.isEmpty ?? false)
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

    @MainActor
    func testConcurrentRefreshCoalescesAndMergesLateForcedProviderIDs() async {
        let gate = GatedProvider(id: "slow", displayName: "Slow")
        let lateForced = CountingProvider(id: "late", displayName: "Late")
        let svc = QuotaService(providers: [gate, lateForced], interval: 3_600)

        let first = Task { @MainActor in
            await svc.refresh()
        }
        await gate.waitUntilFirstFetchStarts()

        let second = Task { @MainActor in
            await svc.refresh(forceProviderIDs: ["late"])
        }
        for _ in 0..<100 where !svc.refreshCoordinatorState().pending {
            await Task.yield()
        }
        let pending = svc.refreshCoordinatorState()
        XCTAssertTrue(pending.running)
        XCTAssertTrue(pending.pending)
        XCTAssertEqual(pending.forcedProviderIDs, ["late"])

        await gate.releaseFirstFetch()
        await first.value
        await second.value

        XCTAssertEqual(lateForced.fetchCount, 2)
        let gateFetchCount = await gate.fetchCount()
        let maximumConcurrentFetches = await gate.maximumConcurrentFetches()
        XCTAssertEqual(gateFetchCount, 1)
        XCTAssertEqual(maximumConcurrentFetches, 1)
        XCTAssertFalse(svc.refreshCoordinatorState().running)
    }

    @MainActor
    func testRemovedProviderCleansNotificationsAndFailureState() {
        var removedIDs: [String] = []
        var legacyCleanupIDs: [String] = []
        let provider = CountingProvider(id: "removed", displayName: "Removed")
        let svc = QuotaService(
            providers: [provider],
            interval: 60,
            failureNotificationPost: { _, _, _ in },
            failureNotificationRemove: { removedIDs.append($0) },
            legacyFailureNotificationCleanup: { legacyCleanupIDs.append($0) })

        svc.evaluateFailureEpisode(id: "removed", displayName: "Removed", error: "timeout")
        XCTAssertNotNil(svc.failureEpisodeState(for: "removed"))

        svc.setProviders([])

        XCTAssertEqual(removedIDs, ["provider.failure.removed"])
        XCTAssertEqual(legacyCleanupIDs, ["removed", "removed"])
        XCTAssertNil(svc.failureEpisodeState(for: "removed"))
    }

    @MainActor
    func testInFlightResultForRemovedProviderIsIgnored() async {
        var legacyCleanupIDs: [String] = []
        var postedIDs: [String] = []
        let provider = GatedProvider(
            id: "removed",
            displayName: "Removed",
            error: "timeout")
        let svc = QuotaService(
            providers: [provider],
            interval: 60,
            failureNotificationPost: { id, _, _ in postedIDs.append(id) },
            failureNotificationRemove: { _ in },
            legacyFailureNotificationCleanup: { legacyCleanupIDs.append($0) })

        svc.evaluateFailureEpisode(id: "removed", displayName: "Removed", error: "timeout")
        let refresh = Task { @MainActor in await svc.refresh() }
        await provider.waitUntilFirstFetchStarts()
        svc.setProviders([])
        await provider.releaseFirstFetch()
        await refresh.value

        XCTAssertTrue(postedIDs.isEmpty)
        XCTAssertNil(svc.failureEpisodeState(for: "removed"))
        XCTAssertEqual(legacyCleanupIDs, ["removed", "removed"])
        XCTAssertTrue(svc.statuses.isEmpty)
    }

    @MainActor
    func testInFlightResultForSameIDReplacementIsIgnored() async {
        var postedIDs: [String] = []
        let original = GatedProvider(
            id: "replaced",
            displayName: "Original",
            error: "timeout")
        let replacement = StubProvider(
            id: "replaced",
            displayName: "Replacement",
            status: ProviderStatus(
                id: "replaced",
                displayName: "Replacement",
                windows: [],
                lastUpdated: Date()))
        let svc = QuotaService(
            providers: [original],
            interval: 60,
            failureNotificationPost: { id, _, _ in postedIDs.append(id) },
            failureNotificationRemove: { _ in },
            legacyFailureNotificationCleanup: { _ in })

        let refresh = Task { @MainActor in await svc.refresh() }
        await original.waitUntilFirstFetchStarts()
        svc.setProviders([replacement])
        await original.releaseFirstFetch()
        await refresh.value

        XCTAssertTrue(postedIDs.isEmpty)
        XCTAssertNil(svc.failureEpisodeState(for: "replaced"))
        XCTAssertTrue(svc.statuses.isEmpty)
    }

    @MainActor
    func testStartSweepsAllHistoricalFailureNotificationsOnce() {
        var sweepCount = 0
        let svc = QuotaService(
            providers: [],
            interval: 0,
            allFailureNotificationCleanup: { sweepCount += 1 })

        svc.start()
        svc.start()
        svc.stop()

        XCTAssertEqual(sweepCount, 1)
    }

    // MARK: - Failure-transition episodes (R3)

    @MainActor
    func testFailureEpisodeUsesStableIDAndConfirmedRecovery() {
        var postedIDs: [String] = []
        var removedIDs: [String] = []
        var legacyCleanupIDs: [String] = []
        var now = Date(timeIntervalSince1970: 1_000)
        let svc = QuotaService(
            providers: [],
            interval: 0.1,
            failureNotificationPost: { id, _, _ in postedIDs.append(id) },
            failureNotificationRemove: { removedIDs.append($0) },
            legacyFailureNotificationCleanup: { legacyCleanupIDs.append($0) },
            failureNotificationNow: { now })

        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "HTTP 401")
        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "HTTP 401")
        var st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.consecutive, 2)
        XCTAssertEqual(st?.notified, false)   // not before the 3rd

        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "HTTP 401")
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.consecutive, 3)
        XCTAssertEqual(st?.notified, true)    // fired at the 3rd
        XCTAssertEqual(st?.episodeSeq, 1)
        XCTAssertEqual(postedIDs, ["provider.failure.p"])
        XCTAssertEqual(legacyCleanupIDs, ["p"])

        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "HTTP 401")
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.notified, true)    // no re-fire on the 4th
        XCTAssertEqual(st?.episodeSeq, 1)     // same episode, same seq

        // One success is not enough to recover or remove the alert.
        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: nil)
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.consecutive, 0)
        XCTAssertEqual(st?.consecutiveSuccesses, 1)
        XCTAssertEqual(st?.active, true)
        XCTAssertEqual(st?.notified, true)
        XCTAssertTrue(removedIDs.isEmpty)

        // The second consecutive success confirms recovery and removes both
        // pending and delivered copies through the notifier seam.
        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: nil)
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.consecutiveSuccesses, 0)
        XCTAssertEqual(st?.active, false)
        XCTAssertEqual(st?.notified, false)
        XCTAssertEqual(st?.episodeSeq, 1)
        XCTAssertEqual(removedIDs, ["provider.failure.p"])

        // A new episode inside the cooldown is tracked but suppressed.
        for _ in 0..<3 {
            svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "timeout sau 12s")
        }
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.active, true)
        XCTAssertEqual(st?.notified, false)
        XCTAssertEqual(postedIDs, ["provider.failure.p"])

        // Continued failure after cooldown re-posts with the same stable ID.
        now.addTimeInterval(601)
        svc.evaluateFailureEpisode(id: "p", displayName: "P", error: "timeout sau 12s")
        st = svc.failureEpisodeState(for: "p")
        XCTAssertEqual(st?.notified, true)
        XCTAssertEqual(st?.episodeSeq, 2)
        XCTAssertEqual(postedIDs, ["provider.failure.p", "provider.failure.p"])
    }

    @MainActor
    func testHealthyObservationsRemoveOrphanNotificationAfterRestart() {
        var removedIDs: [String] = []
        var legacyCleanupIDs: [String] = []
        let svc = QuotaService(
            providers: [],
            interval: 0.1,
            failureNotificationPost: { _, _, _ in },
            failureNotificationRemove: { removedIDs.append($0) },
            legacyFailureNotificationCleanup: { legacyCleanupIDs.append($0) })

        svc.evaluateFailureEpisode(id: "codex", displayName: "Codex", error: nil)
        XCTAssertTrue(removedIDs.isEmpty)
        XCTAssertEqual(legacyCleanupIDs, ["codex"])

        svc.evaluateFailureEpisode(id: "codex", displayName: "Codex", error: nil)
        XCTAssertEqual(removedIDs, ["provider.failure.codex"])

        svc.evaluateFailureEpisode(id: "codex", displayName: "Codex", error: nil)
        XCTAssertEqual(removedIDs, ["provider.failure.codex"])
        XCTAssertEqual(legacyCleanupIDs, ["codex"])
    }

    @MainActor
    func testProviderFailureNotificationsDefaultRemainsEnabled() {
        UserDefaults.standard.removeObject(forKey: "providerFailureNotificationsEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "providerFailureNotificationsEnabled") }

        let settings = SettingsStore()
        XCTAssertTrue(settings.providerFailureNotificationsEnabled)
        XCTAssertTrue(QuotaService.failureNotificationsEnabled)
    }

    /// Disabled flag: the counter still tracks, but `notified` stays false
    /// (nothing posted, episodeSeq unchanged).
    @MainActor
    func testFailureEpisodeRespectsDisabledFlag() {
        UserDefaults.standard.set(false, forKey: "providerFailureNotificationsEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "providerFailureNotificationsEnabled") }

        let svc = QuotaService(providers: [], interval: 0.1)
        for _ in 0..<4 {
            svc.evaluateFailureEpisode(id: "q", displayName: "Q", error: "HTTP 500")
        }
        let st = svc.failureEpisodeState(for: "q")
        XCTAssertEqual(st?.consecutive, 4)
        XCTAssertEqual(st?.notified, false)
        XCTAssertEqual(st?.episodeSeq, 0)
    }

    /// R3.5: the counter counts even while the published status keeps a
    /// preserved stale GOOD snapshot (the awaited fetch result drives it).
    @MainActor
    func testFailureCounterRunsDespitePreservedStaleSnapshot() async {
        let provider = GoodThenErrorProvider(id: "claude", displayName: "Claude")
        let svc = QuotaService(providers: [provider], interval: 0.1)

        await svc.refresh()                                    // fetch 1: good
        XCTAssertEqual(svc.failureEpisodeState(for: "claude")?.consecutive, 0)

        await svc.refresh(forceProviderIDs: ["claude"])        // fetch 2: error, snapshot preserved
        // Published status still shows the good snapshot…
        XCTAssertNil(svc.statuses.first?.error)
        // …but the failure counter advanced from the awaited result.
        XCTAssertEqual(svc.failureEpisodeState(for: "claude")?.consecutive, 1)

        await svc.refresh(forceProviderIDs: ["claude"])        // fetch 3: error
        await svc.refresh(forceProviderIDs: ["claude"])        // fetch 4: error → threshold
        let st = svc.failureEpisodeState(for: "claude")
        XCTAssertEqual(st?.consecutive, 3)
        XCTAssertEqual(st?.notified, true)
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

private final class GatedProvider: QuotaProvider {
    let id: String
    let displayName: String
    private let gate = FetchGate()
    private let error: String?

    init(id: String, displayName: String, error: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.error = error
    }

    func fetch() async throws -> ProviderStatus {
        let count = await gate.beginFetch()
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: error == nil
                ? [QuotaWindow(label: "5 giờ", usedPct: count, remainingPct: 100 - count)]
                : [],
            lastUpdated: Date(),
            error: error)
    }

    func waitUntilFirstFetchStarts() async {
        await gate.waitUntilFirstFetchStarts()
    }

    func releaseFirstFetch() async {
        await gate.releaseFirstFetch()
    }

    func fetchCount() async -> Int {
        await gate.fetchCount
    }

    func maximumConcurrentFetches() async -> Int {
        await gate.maximumConcurrentFetches
    }
}

final class OrderedAsyncOperationQueueTests: XCTestCase {
    @MainActor
    func testLaterRemoveWaitsForDelayedPostOperation() async {
        let queue = OrderedAsyncOperationQueue()
        let gate = AsyncTestGate()
        var events: [String] = []

        queue.enqueue {
            await gate.wait()
            events.append("post")
        }
        queue.enqueue {
            events.append("remove")
        }

        await Task.yield()
        XCTAssertTrue(events.isEmpty)
        await gate.release()
        await queue.drain()

        XCTAssertEqual(events, ["post", "remove"])
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FetchGate {
    private(set) var fetchCount = 0
    private(set) var maximumConcurrentFetches = 0
    private var activeFetches = 0
    private var firstFetchStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstFetchRelease: CheckedContinuation<Void, Never>?

    func beginFetch() async -> Int {
        fetchCount += 1
        activeFetches += 1
        maximumConcurrentFetches = max(maximumConcurrentFetches, activeFetches)
        if fetchCount == 1 {
            let waiters = firstFetchStartedWaiters
            firstFetchStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstFetchRelease = $0 }
        }
        activeFetches -= 1
        return fetchCount
    }

    func waitUntilFirstFetchStarts() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { firstFetchStartedWaiters.append($0) }
    }

    func releaseFirstFetch() {
        firstFetchRelease?.resume()
        firstFetchRelease = nil
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

/// First fetch succeeds, every later fetch returns an HTTP 401. Used to prove
/// a credential error clears the preserved stale snapshot instead of masking a
/// revoked/rotated key behind the last-good numbers.
private final class GoodThenUnauthorizedProvider: QuotaProvider {
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
            error: "HTTP 401")
    }
}
