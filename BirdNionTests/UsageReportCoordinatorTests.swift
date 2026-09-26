import XCTest
@testable import BirdNion

/// Task-06 coverage: `UsageReportCoordinator` single-flight + TTL behavior.
/// Stub scan closures count invocations; no real filesystem scanning.
final class UsageReportCoordinatorTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ key: String) { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1 }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
    }

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private static func report(usd: Double = 1.5) -> ClaudeUsageReport {
        ClaudeUsageReport(todayUSD: usd, todayTokens: 10, last30USD: 3,
                          last30Tokens: 30, daily: [], topModel: nil)
    }

    private static func codexReport(usd: Double = 2.5) -> CodexUsageReport {
        CodexUsageReport(todayUSD: usd, todayTokens: 20, last30USD: 6,
                         last30Tokens: 60, daily: [], topModel: nil)
    }

    private static func makeScans(
        counter: Counter,
        claude: (@Sendable () async -> ClaudeUsageReport?)? = nil,
        clock: FakeClock? = nil
    ) -> UsageReportCoordinator.Scans {
        let scans = UsageReportCoordinator.Scans(
            claude: { counter.bump("claude")
                if let claude { return await claude() }
                return report()
            },
            codex: { counter.bump("codex"); return codexReport() },
            grok: { counter.bump("grok"); return nil },
            kiro: { counter.bump("kiro"); return nil },
            omp: { counter.bump("omp"); return nil },
            pi: { counter.bump("pi"); return nil },
            devin: { counter.bump("devin"); return nil },
            seededClaude: { nil }, seededCodex: { nil }, seededGrok: { nil },
            seededKiro: { nil }, seededOMP: { nil }, seededPi: { nil },
            seededDevin: { nil },
            claudeSummary: { nil }, codexSummary: { nil },
            now: { clock?.now() ?? Date() })
        return scans
    }

    /// Five concurrent callers must share exactly one scan and all receive
    /// the same report.
    func testConcurrentCallersShareOneScan() async {
        let counter = Counter()
        let scans = Self.makeScans(counter: counter, claude: {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return Self.report(usd: 4.2)
        })
        let coordinator = UsageReportCoordinator(scans: scans)

        let results = await withTaskGroup(of: ClaudeUsageReport?.self) { group in
            for _ in 0..<5 {
                group.addTask { await coordinator.claudeReport() }
            }
            var out: [ClaudeUsageReport?] = []
            for await r in group { out.append(r) }
            return out
        }

        XCTAssertEqual(counter.count("claude"), 1, "single-flight: one scan for 5 callers")
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0 == Self.report(usd: 4.2) })
    }

    /// A caller arriving mid-scan joins the same in-flight task — no second
    /// scan is spawned.
    func testLateCallerJoinsInFlightScan() async {
        let counter = Counter()
        let scans = Self.makeScans(counter: counter, claude: {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return Self.report()
        })
        let coordinator = UsageReportCoordinator(scans: scans)

        async let first = coordinator.claudeReport()
        try? await Task.sleep(nanoseconds: 50_000_000)   // let the scan start
        async let second = coordinator.claudeReport()
        let (a, b) = await (first, second)

        XCTAssertEqual(counter.count("claude"), 1)
        XCTAssertEqual(a, b)
    }

    /// Within the TTL the cached value is served — no rescan.
    func testCacheHitWithinTTLSkipsScan() async {
        let counter = Counter()
        let clock = FakeClock()
        let scans = Self.makeScans(counter: counter, clock: clock)
        let coordinator = UsageReportCoordinator(scans: scans)

        _ = await coordinator.claudeReport()
        clock.advance(299)
        _ = await coordinator.claudeReport()
        XCTAssertEqual(counter.count("claude"), 1)
    }

    /// After TTL expiry the next call rescans.
    func testPostTTLCallRescans() async {
        let counter = Counter()
        let clock = FakeClock()
        let scans = Self.makeScans(counter: counter, clock: clock)
        let coordinator = UsageReportCoordinator(scans: scans)

        _ = await coordinator.claudeReport()
        clock.advance(301)   // past the 300s coordinator TTL
        _ = await coordinator.claudeReport()
        XCTAssertEqual(counter.count("claude"), 2)
    }

    /// A nil (failed) scan must not be cached — the next caller retries.
    func testFailedScanIsNotCached() async {
        let counter = Counter()
        let flag = Counter()
        let scans = Self.makeScans(counter: counter, claude: {
            // First call fails (nil), second succeeds.
            if flag.count("failed") == 0 {
                flag.bump("failed")
                return nil
            }
            return Self.report()
        })
        let coordinator = UsageReportCoordinator(scans: scans)

        let first = await coordinator.claudeReport()
        let second = await coordinator.claudeReport()
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.count("claude"), 2)
    }

    /// Different sources keep independent lanes — a Codex call does not share
    /// or block the Claude scan.
    func testDifferentSourcesScanIndependently() async {
        let counter = Counter()
        let scans = Self.makeScans(counter: counter)
        let coordinator = UsageReportCoordinator(scans: scans)

        async let claude = coordinator.claudeReport()
        async let codex = coordinator.codexReport()
        let (c, x) = await (claude, codex)

        XCTAssertNotNil(c)
        XCTAssertNotNil(x)
        XCTAssertEqual(counter.count("claude"), 1)
        XCTAssertEqual(counter.count("codex"), 1)
    }

    /// `invalidateAll()` drops cached entries → next call rescans.
    func testInvalidateAllForcesRescan() async {
        let counter = Counter()
        let scans = Self.makeScans(counter: counter)
        let coordinator = UsageReportCoordinator(scans: scans)

        _ = await coordinator.claudeReport()
        await coordinator.invalidateAll()
        _ = await coordinator.claudeReport()
        XCTAssertEqual(counter.count("claude"), 2)
    }

    /// Call-site seam probe: production callers read `UsageReportCoordinator
    /// .shared` — installing a stub proves rewired paths hit the coordinator.
    func testSharedSeamRoutesThroughInjectedStub() async {
        let counter = Counter()
        let scans = Self.makeScans(counter: counter)
        let stub = UsageReportCoordinator(scans: scans)
        await MainActor.run {
            UsageReportCoordinator.installForTesting(stub)
        }
        defer {
            Task { @MainActor in
                UsageReportCoordinator.installForTesting(UsageReportCoordinator())
            }
        }
        _ = await UsageReportCoordinator.shared.claudeReport()
        XCTAssertEqual(counter.count("claude"), 1)
    }
}
