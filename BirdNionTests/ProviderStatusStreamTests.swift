import XCTest
@testable import BirdNion

/// Contract tests for the two-phase `statuses(interaction:)` stream:
/// emission 0 = core, emissions ≥ 1 = enrichment. The consumer used here
/// mirrors what `ProviderScheduler` lanes do: publish emission 0 as-is,
/// drop enrichment emissions that carry an error, merge the rest via
/// `withEnrichment(from:)`.
final class ProviderStatusStreamTests: XCTestCase {

    // MARK: - Stub providers

    private final class StubWrappedProvider: QuotaProvider {
        let id = "stub"
        let displayName = "Stub"
        let result: ProviderStatus
        init(result: ProviderStatus) { self.result = result }
        func fetch() async throws -> ProviderStatus { result }
    }

    private final class StubThrowingProvider: QuotaProvider {
        let id = "throwing"
        let displayName = "Throwing"
        struct Boom: Error, CustomStringConvertible {
            var description: String { "simulated fetch failure" }
        }
        func fetch() async throws -> ProviderStatus { throw Boom() }
    }

    /// Emits a held-back core + enrichment pair: the extras continuation is
    /// captured so the test can prove emission 0 arrives before extras resolve.
    private final class StubStreamProvider: QuotaProvider {
        let id = "stream"
        let displayName = "Stream"
        var extrasGate: CheckedContinuation<Void, Never>?
        var coreStatus: ProviderStatus
        var extrasStatus: ProviderStatus
        init(core: ProviderStatus, extras: ProviderStatus) {
            coreStatus = core
            extrasStatus = extras
        }
        func fetch() async throws -> ProviderStatus { coreStatus }
        func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus> {
            AsyncStream { continuation in
                let task = Task {
                    continuation.yield(self.coreStatus)
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        self.extrasGate = c
                    }
                    continuation.yield(self.extrasStatus)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func releaseExtras() { extrasGate?.resume() }
    }

    /// Contract violator: emits an error on an enrichment emission.
    private final class StubViolatingProvider: QuotaProvider {
        let id = "violating"
        let displayName = "Violating"
        func fetch() async throws -> ProviderStatus { core }
        var core: ProviderStatus {
            ProviderStatus(id: id, displayName: displayName,
                           windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
                           lastUpdated: Date())
        }
        func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus> {
            AsyncStream { continuation in
                continuation.yield(core)
                continuation.yield(ProviderStatus(
                    id: id, displayName: displayName, windows: [],
                    lastUpdated: Date(), error: "extras exploded"))
                continuation.finish()
            }
        }
    }

    // MARK: - Test consumer (mirrors lane publish rules)

    /// Collects a stream the way a lane does: emission 0 publishes raw;
    /// later emissions are dropped when they carry an error, else merged via
    /// `withEnrichment`. Stops after the stream finishes.
    private func consume(_ provider: QuotaProvider,
                         interaction: ProviderInteraction = .background
    ) async -> [ProviderStatus] {
        var published: [ProviderStatus] = []
        var index = 0
        for await status in provider.statuses(interaction: interaction) {
            guard ProviderStatusEmissionPolicy.isPublishable(
                emissionIndex: index, status: status) else {
                index += 1
                continue
            }
            if index == 0 {
                published.append(status)
            } else if let last = published.last {
                published[published.count - 1] = last.withEnrichment(from: status)
            }
            index += 1
        }
        return published
    }

    // MARK: - AC-01: core publishes before enrichment

    func testDefaultWrapperYieldsSingleCoreEmission() async {
        let status = ProviderStatus(
            id: "stub", displayName: "Stub",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 25, remainingPct: 75)],
            lastUpdated: Date(), planType: "pro")
        let emissions = await consume(StubWrappedProvider(result: status))
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.windows.count, 1)
        XCTAssertEqual(emissions.first?.planType, "pro")
        XCTAssertNil(emissions.first?.error)
    }

    func testDefaultWrapperMapsThrowToErrorStatus() async {
        let emissions = await consume(StubThrowingProvider())
        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(emissions.first?.windows.isEmpty ?? false)
        XCTAssertEqual(emissions.first?.error, "simulated fetch failure")
    }

    func testCoreEmissionArrivesBeforeEnrichmentResolves() async throws {
        let core = ProviderStatus(
            id: "stream", displayName: "Stream",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 30, remainingPct: 70)],
            lastUpdated: Date())
        let extras = ProviderStatus(
            id: "stream", displayName: "Stream", windows: [], lastUpdated: Date(),
            version: "9.9.9", serviceStatus: "All Systems Operational")
        let provider = StubStreamProvider(core: core, extras: extras)

        let stream = provider.statuses(interaction: .background)
        var iterator = stream.makeAsyncIterator()

        // Emission 0 must resolve while the extras gate is still closed —
        // if the consumer had to await the whole stream this next() would hang.
        let first = await iterator.next()
        XCTAssertEqual(first?.windows.count, 1)
        XCTAssertNil(first?.version)

        provider.releaseExtras()
        let second = await iterator.next()
        XCTAssertEqual(second?.version, "9.9.9")
        XCTAssertEqual(second?.serviceStatus, "All Systems Operational")
        let third = await iterator.next()
        XCTAssertNil(third)
    }

    // MARK: - AC-05: error-carrying enrichment is dropped

    func testEnrichmentEmissionWithErrorIsDropped() async {
        XCTAssertTrue(ProviderStatusEmissionPolicy.isPublishable(
            emissionIndex: 0,
            status: ProviderStatus(id: "x", displayName: "X", windows: [],
                                   lastUpdated: Date(), error: "boom")))
        XCTAssertFalse(ProviderStatusEmissionPolicy.isPublishable(
            emissionIndex: 1,
            status: ProviderStatus(id: "x", displayName: "X", windows: [],
                                   lastUpdated: Date(), error: "extras boom")))

        let published = await consume(StubViolatingProvider())
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.windows.count, 1)
        XCTAssertNil(published.first?.error)
    }

    // MARK: - merge helper

    func testWithEnrichmentMergesFieldsWithoutTouchingCore() {
        let core = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 40, remainingPct: 60)],
            lastUpdated: Date(timeIntervalSince1970: 1000),
            accountLabel: "me@example.com", planType: "plus",
            sourceLabel: "OAuth")
        let extras = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [],
            lastUpdated: Date(timeIntervalSince1970: 2000),
            error: "must never propagate", accountLabel: "wrong",
            planType: "wrong", version: "codex-cli 1.0",
            serviceStatus: "Degraded", resetCreditsAvailable: 3,
            sourceLabel: "wrong")

        let merged = core.withEnrichment(from: extras)
        XCTAssertEqual(merged.version, "codex-cli 1.0")
        XCTAssertEqual(merged.serviceStatus, "Degraded")
        XCTAssertEqual(merged.resetCreditsAvailable, 3)
        XCTAssertEqual(merged.lastUpdated, Date(timeIntervalSince1970: 2000))
        // Core fields survive verbatim:
        XCTAssertEqual(merged.windows.count, 1)
        XCTAssertNil(merged.error)
        XCTAssertEqual(merged.accountLabel, "me@example.com")
        XCTAssertEqual(merged.planType, "plus")
        XCTAssertEqual(merged.sourceLabel, "OAuth")
    }

    func testWithEnrichmentNilFieldsKeepExistingValues() {
        let core = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
            lastUpdated: Date(), version: "old-version",
            serviceStatus: "Operational")
        let emptyExtras = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [], lastUpdated: Date())
        let merged = core.withEnrichment(from: emptyExtras)
        XCTAssertEqual(merged.version, "old-version")
        XCTAssertEqual(merged.serviceStatus, "Operational")
    }

    // MARK: - cancellation

    func testCancellationEndsStream() async {
        let provider = StubStreamProvider(
            core: ProviderStatus(
                id: "stream", displayName: "Stream",
                windows: [QuotaWindow(label: "5 giờ", usedPct: 1, remainingPct: 99)],
                lastUpdated: Date()),
            extras: ProviderStatus(
                id: "stream", displayName: "Stream", windows: [],
                lastUpdated: Date(), version: "1.0"))

        let task = Task { await self.consume(provider) }
        // Give the stream a moment to emit its core, then cancel while the
        // extras gate is still closed — the consumer must terminate.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let published = await task.value
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.windows.count, 1)
    }
}
