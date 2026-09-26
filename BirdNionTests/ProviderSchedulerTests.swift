import XCTest
@testable import BirdNion

/// Lane/scheduler contract tests: single-flight, force follow-up, per-lane
/// independence, deadlines, stale-generation drops, extras merge.
@MainActor
final class ProviderSchedulerTests: XCTestCase {

    // MARK: - Stub provider

    /// Emits a scripted list of statuses per fetch. `delay` sleeps before each
    /// emission; `hang` suspends forever (until cancelled by the deadline).
    private final class StubProvider: QuotaProvider {
        let id: String
        let displayName: String
        var fetchCount = 0
        var interactions: [ProviderInteraction] = []
        /// Emission lists consumed one per fetch; last list repeats when the
        /// queue runs dry.
        var script: [[ProviderStatus]] = []
        var delayPerEmission: TimeInterval = 0
        var hang = false

        init(id: String) {
            self.id = id
            self.displayName = id
        }

        func fetch() async throws -> ProviderStatus {
            ProviderStatus(id: id, displayName: displayName,
                           windows: [], lastUpdated: Date())
        }

        func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus> {
            AsyncStream { continuation in
                let task = Task { @MainActor [weak self] in
                    guard let self else { continuation.finish(); return }
                    self.fetchCount += 1
                    self.interactions.append(interaction)
                    if self.hang {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        continuation.finish()
                        return
                    }
                    let emissions = self.script.isEmpty
                        ? [self.okStatus()] : self.script.removeFirst()
                    for status in emissions {
                        if Task.isCancelled { break }
                        if self.delayPerEmission > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(self.delayPerEmission * 1e9))
                        }
                        if Task.isCancelled { break }
                        continuation.yield(status)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func okStatus() -> ProviderStatus {
            ProviderStatus(
                id: id, displayName: displayName,
                windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
                lastUpdated: Date())
        }

        func errStatus(_ msg: String = "boom") -> ProviderStatus {
            ProviderStatus(id: id, displayName: displayName,
                           windows: [], lastUpdated: Date(), error: msg)
        }
    }

    /// Mutable collector so the publish hook can accumulate results the test
    /// asserts on afterwards.
    private final class PublishedBox {
        var items: [ProviderStatus] = []
    }
    private var schedulerBox: PublishedBox?

    private func makeScheduler(
        _ providers: [StubProvider],
        env: ProviderScheduler.Environment = ProviderScheduler.Environment()
    ) -> ProviderScheduler {
        let box = PublishedBox()
        var hooks = ProviderLane.Hooks()
        hooks.publish = { box.items.append($0) }
        let scheduler = ProviderScheduler(env: env, hooks: hooks)
        scheduler.configure(providers: providers)
        schedulerBox = box
        return scheduler
    }

    private var published: [ProviderStatus] { schedulerBox?.items ?? [] }

    // MARK: - AC-03: single-flight per lane

    func testConcurrentKicksRunOneFetchPerLane() async {
        let stub = StubProvider(id: "a")
        stub.delayPerEmission = 0.05
        let scheduler = makeScheduler([stub])

        async let t1: Void = scheduler.refreshAll(forceProviderIDs: [], globalInterval: 120)
        async let t2: Void = scheduler.refreshAll(forceProviderIDs: ["a"], globalInterval: 120)
        let lane = try! XCTUnwrap(scheduler.lane(for: "a"))
        let extra = lane.kick(force: true, interaction: .userInitiated)

        await t1; await t2; await extra.value
        XCTAssertEqual(stub.fetchCount, 1)
    }

    // MARK: - AC-02: lanes are independent

    func testForcedLaneCompletesWhileOtherLaneHangs() async {
        let slow = StubProvider(id: "slow")
        slow.hang = true
        let fast = StubProvider(id: "fast")
        var env = ProviderScheduler.Environment()
        env.coreDeadlineOverride = 0.3
        let scheduler = makeScheduler([slow, fast], env: env)

        let refreshTask = Task {
            await scheduler.refreshAll(forceProviderIDs: ["fast"], globalInterval: 120)
        }
        await refreshTask.value

        XCTAssertEqual(fast.fetchCount, 1)
        XCTAssertTrue(published.contains { $0.id == "fast" && $0.error == nil })
        // The hanging lane was never kicked (not due-forced), or if kicked by
        // a later tick it resolves via timeout — either way it didn't block.
    }

    func testTickDoesNotWaitAcrossLanes() async {
        let hanging = StubProvider(id: "hanging")
        hanging.hang = true
        let fast = StubProvider(id: "fast")
        var env = ProviderScheduler.Environment()
        env.coreDeadlineOverride = 0.2
        let scheduler = makeScheduler([hanging, fast], env: env)

        await scheduler.tick(globalInterval: 120)

        XCTAssertEqual(fast.fetchCount, 1)
        XCTAssertTrue(published.contains { $0.id == "fast" && $0.error == nil })
        // hanging hit its deadline → timeout status, lane unblocked
        let hangingStatus = published.last(where: { $0.id == "hanging" })
        XCTAssertEqual(hangingStatus?.error?.contains("Timeout"), true)
        XCTAssertFalse(scheduler.isRefreshing)
        XCTAssertTrue(scheduler.fetchingIDs.isEmpty)
    }

    // MARK: - AC-09: core deadline

    func testCoreDeadlinePublishesTimeoutAndUnblocks() async {
        let stub = StubProvider(id: "dead")
        stub.hang = true
        var env = ProviderScheduler.Environment()
        env.coreDeadlineOverride = 0.05
        let scheduler = makeScheduler([stub], env: env)

        await scheduler.refreshAll(forceProviderIDs: ["dead"], globalInterval: 120)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.error?.contains("Timeout"), true)
        XCTAssertTrue(published.first?.windows.isEmpty ?? false)
    }

    // MARK: - force follow-up

    func testForceFollowUpAfterFailedInflight() async {
        let stub = StubProvider(id: "flaky")
        stub.script = [[stub.errStatus()], [stub.okStatus()]]
        stub.delayPerEmission = 0.05
        var env = ProviderScheduler.Environment()
        env.coreDeadlineOverride = 5
        let scheduler = makeScheduler([stub], env: env)
        let lane = try! XCTUnwrap(scheduler.lane(for: "flaky"))

        let first = lane.kick(force: false, interaction: .background)
        // Force lands while the background fetch is still running.
        let forced = lane.kick(force: true, interaction: .userInitiated)
        await first.value
        await forced.value

        XCTAssertEqual(stub.fetchCount, 2)
        XCTAssertEqual(stub.interactions.last, .userInitiated)
    }

    func testForceSatisfiedBySuccessfulInflight() async {
        let stub = StubProvider(id: "ok")
        stub.delayPerEmission = 0.05
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "ok"))

        let first = lane.kick(force: false, interaction: .background)
        let forced = lane.kick(force: true, interaction: .userInitiated)
        await first.value
        await forced.value

        // In-flight background fetch succeeded → the queued force is satisfied.
        XCTAssertEqual(stub.fetchCount, 1)
    }

    // MARK: - stale generation

    func testStaleGenerationEmissionsDropped() async {
        let stub = StubProvider(id: "gen")
        stub.delayPerEmission = 0.1
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "gen"))

        let task = lane.kick(force: true, interaction: .userInitiated)
        // Invalidate while the emission is still sleeping.
        try? await Task.sleep(nanoseconds: 30_000_000)
        lane.invalidateContext()
        await task.value

        XCTAssertTrue(published.isEmpty)
        XCTAssertNil(lane.currentStatus)
    }

    // MARK: - extras merge

    func testExtrasEmissionMergesOntoCore() async {
        let stub = StubProvider(id: "two")
        stub.script = [[
            stub.okStatus(),
            ProviderStatus(id: "two", displayName: "two", windows: [],
                           lastUpdated: Date(), version: "2.0",
                           serviceStatus: "Operational"),
        ]]
        let scheduler = makeScheduler([stub])
        await scheduler.refreshAll(forceProviderIDs: ["two"], globalInterval: 120)

        XCTAssertEqual(published.count, 2)
        let merged = published.last
        XCTAssertEqual(merged?.windows.count, 1)
        XCTAssertEqual(merged?.version, "2.0")
        XCTAssertEqual(merged?.serviceStatus, "Operational")
    }

    func testExtrasAfterErrorCoreDropped() async {
        let stub = StubProvider(id: "bad")
        stub.script = [[
            stub.errStatus("core failed"),
            ProviderStatus(id: "bad", displayName: "bad", windows: [],
                           lastUpdated: Date(), version: "9.9"),
        ]]
        let scheduler = makeScheduler([stub])
        await scheduler.refreshAll(forceProviderIDs: ["bad"], globalInterval: 120)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.error, "core failed")
        XCTAssertNil(published.first?.version)
    }

    // MARK: - AC-06: fetchingIDs / isRefreshing

    func testFetchingIDsTracksInFlightLanes() async {
        let stub = StubProvider(id: "track")
        stub.delayPerEmission = 0.15
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "track"))

        let task = lane.kick(force: false, interaction: .background)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(scheduler.fetchingIDs, ["track"])
        XCTAssertTrue(scheduler.isRefreshing)
        await task.value
        XCTAssertTrue(scheduler.fetchingIDs.isEmpty)
        XCTAssertFalse(scheduler.isRefreshing)
    }

    // MARK: - batch settle hook

    func testBatchSettledFiresEvenWhenNothingDue() async {
        let stub = StubProvider(id: "settled")
        let scheduler = makeScheduler([stub])
        var settled = 0
        scheduler.onBatchSettled = { settled += 1 }

        await scheduler.tick(globalInterval: 120)
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(stub.fetchCount, 1)

        // Second tick: lane not due (interval 120s) → still settles.
        await scheduler.tick(globalInterval: 120)
        XCTAssertEqual(settled, 2)
        XCTAssertEqual(stub.fetchCount, 1)
    }

    // MARK: - backoff

    func testFailedLaneBacksOffUntilInterval() async {
        let stub = StubProvider(id: "backoff")
        stub.script = [[stub.errStatus()]]
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "backoff"))

        await scheduler.tick(globalInterval: 100)
        XCTAssertEqual(stub.fetchCount, 1)
        // One failure → multiplier 1 → due again after 100s (not before).
        XCTAssertFalse(lane.isDue(
            now: lane.lastFetchedAt!.addingTimeInterval(50),
            globalInterval: 100))
        XCTAssertTrue(lane.isDue(
            now: lane.lastFetchedAt!.addingTimeInterval(101),
            globalInterval: 100))
    }

    func testAdaptiveBackoffGrowsWithFailures() async {
        let stub = StubProvider(id: "grow")
        stub.script = [[stub.errStatus()], [stub.errStatus()], [stub.errStatus()]]
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "grow"))

        // Background (non-forced) kicks accumulate the streak — a forced kick
        // would reset it first, matching the old pass semantics.
        for _ in 0..<3 {
            await lane.kick(force: false, interaction: .background).value
        }
        XCTAssertEqual(lane.adaptiveFailureCount, 3)
        // 3 failures → multiplier 4 → effective interval = 400s.
        XCTAssertFalse(lane.isDue(
            now: lane.lastFetchedAt!.addingTimeInterval(350),
            globalInterval: 100))
        XCTAssertTrue(lane.isDue(
            now: lane.lastFetchedAt!.addingTimeInterval(401),
            globalInterval: 100))
    }

    // MARK: - transient error preserves last good

    func testTransientErrorPreservesLastGoodSnapshot() async {
        let stub = StubProvider(id: "preserve")
        stub.script = [
            [stub.okStatus()],
            [stub.errStatus("Timeout: provider did not respond within 60s")],
        ]
        let scheduler = makeScheduler([stub])
        let lane = try! XCTUnwrap(scheduler.lane(for: "preserve"))

        await scheduler.refreshAll(forceProviderIDs: ["preserve"], globalInterval: 120)
        await scheduler.refreshAll(forceProviderIDs: ["preserve"], globalInterval: 120)

        // The card still shows the good snapshot + a stale warning is set.
        XCTAssertEqual(lane.currentStatus?.windows.count, 1)
        XCTAssertNil(lane.currentStatus?.error)
        XCTAssertNotNil(lane.staleWarning)
        // Exactly two published: the good status (error path preserves in place).
        XCTAssertEqual(published.count, 1)
    }
}
