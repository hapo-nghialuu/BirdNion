import XCTest
@testable import BirdNion

/// Two-phase contract for `CodexProvider.statuses(interaction:)`: the core
/// quota emission must publish as soon as the usage call resolves — while the
/// side probes (version/status/reset-credits/web) are still in flight — and a
/// second emission carries the enrichment once they settle.
final class CodexProviderTwoPhaseTests: XCTestCase {

    // MARK: - Probes + collection helpers

    /// Gate a probe's completion until the test releases it — proves ordering
    /// without relying on sleeps or wall-clock races.
    private final class ProbeGate: @unchecked Sendable {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if open {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            let pending = waiters
            waiters = []
            open = true
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private actor EmissionBox {
        private(set) var list: [ProviderStatus] = []
        func add(_ status: ProviderStatus) { list.append(status) }
    }

    /// Poll the box until `count` emissions arrive or the timeout lapses.
    private func awaitEmissions(_ box: EmissionBox, count: Int,
                                timeout: TimeInterval = 2) async -> [ProviderStatus] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let list = await box.list
            if list.count >= count { return list }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await box.list
    }

    private func collect(_ stream: AsyncStream<ProviderStatus>,
                         into box: EmissionBox) -> Task<Void, Never> {
        Task { for await status in stream { await box.add(status) } }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-2phase-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func writeAuth(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
    }

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }

    private let usageJSON = """
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"used_percent":42,"reset_at":1750000000,"limit_window_seconds":18000},
      "secondary_window":{"used_percent":8,"reset_at":1750500000,"limit_window_seconds":604800}},
     "credits":{"balance":12.5,"has_credits":true,"unlimited":false}}
    """.data(using: .utf8)!

    /// Route usage + reset-credits endpoints like the existing happy-path test.
    private func stubUsageAndReset() {
        StubURLProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.hasSuffix("/wham/usage") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.usageJSON)
            }
            if url.hasSuffix("/wham/rate-limit-reset-credits") {
                let body = #"{"credits":[],"available_count":3}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            XCTFail("unexpected URL: \(url)")
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
    }

    // MARK: - Tests

    /// AC-01 oracle: emission 0 (core) publishes while version/status probes
    /// are still gated; emission 1 then fills enrichment fields.
    func testOAuthCoreEmissionArrivesBeforeExtrasSettle() async throws {
        let url = tempURL()
        try writeAuth(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        stubUsageAndReset()
        defer { StubURLProtocol.reset() }

        let gate = ProbeGate()
        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            authURL: url,
            statusProbe: {
                await gate.wait()
                return OpenAIServiceStatus(indicator: "none", description: "All Systems Operational")
            },
            versionProbe: {
                await gate.wait()
                return "codex-cli 9.9.9"
            },
            cliUsageProbe: { nil })

        let box = EmissionBox()
        let collector = collect(provider.statuses(interaction: .background), into: box)

        // Core must arrive WITHOUT releasing the probes — this is the
        // counterexample oracle: if emission 0 awaited the probes, this poll
        // would time out with an empty box.
        let first = await awaitEmissions(box, count: 1)
        XCTAssertEqual(first.count, 1)
        let core = try XCTUnwrap(first.first)
        XCTAssertNil(core.error)
        XCTAssertEqual(core.windows.count, 2)
        XCTAssertEqual(core.windows.first?.label, "5 giờ")
        XCTAssertEqual(core.planType, "Plus")
        XCTAssertEqual(core.sourceLabel, "OAuth")
        XCTAssertEqual(core.creditsRemaining, 12.5)
        XCTAssertNil(core.version)
        XCTAssertNil(core.serviceStatus)
        XCTAssertNil(core.resetCreditsAvailable)
        XCTAssertNil(core.codexWeb)

        gate.release()
        let all = await awaitEmissions(box, count: 2)
        XCTAssertEqual(all.count, 2)
        let extras = try XCTUnwrap(all.last)
        XCTAssertNil(extras.error)
        XCTAssertEqual(extras.version, "codex-cli 9.9.9")
        XCTAssertEqual(extras.serviceStatus, "All Systems Operational")
        XCTAssertEqual(extras.resetCreditsAvailable, 3)
        // Core fields ride through the enrichment emission.
        XCTAssertEqual(extras.windows.count, 2)
        XCTAssertEqual(extras.sourceLabel, "OAuth")

        collector.cancel()
    }

    /// The CLI-RPC path (fallback / .cli source) emits the same two phases:
    /// core from the RPC payload, then version/status/web enrichment.
    func testCLIPathEmitsCoreThenExtras() async {
        let gate = ProbeGate()
        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)],
            planType: "pro", credits: 3, email: "cli@example.com")
        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            authURL: tempURL(),
            source: .cli,
            statusProbe: {
                await gate.wait()
                return OpenAIServiceStatus(indicator: "minor", description: "Degraded")
            },
            versionProbe: {
                await gate.wait()
                return "codex-cli 1.2.3"
            },
            cliUsageProbe: { cli })
        defer { StubURLProtocol.reset() }

        let box = EmissionBox()
        let collector = collect(provider.statuses(interaction: .background), into: box)

        let first = await awaitEmissions(box, count: 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.sourceLabel, "CLI")
        XCTAssertEqual(first.first?.accountLabel, "cli@example.com")
        XCTAssertNil(first.first?.version)
        XCTAssertNil(first.first?.serviceStatus)

        gate.release()
        let all = await awaitEmissions(box, count: 2)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.version, "codex-cli 1.2.3")
        XCTAssertEqual(all.last?.serviceStatus, "Degraded")
        XCTAssertEqual(all.last?.serviceStatusLevel, "minor")
        // The CLI path has no reset-credits endpoint.
        XCTAssertNil(all.last?.resetCreditsAvailable)

        collector.cancel()
    }

    /// A failed probe leaves its enrichment field nil — and emission 1 must
    /// never carry `error` (ProviderStatusEmissionPolicy would drop it anyway;
    /// assert at the source so the contract is explicit).
    func testExtrasEmissionNeverCarriesErrorOnProbeFailure() async throws {
        let url = tempURL()
        try writeAuth(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StubURLProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.hasSuffix("/wham/usage") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.usageJSON)
            }
            // Reset-credits endpoint fails hard — the field must come out nil.
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            authURL: url,
            statusProbe: { nil },          // probe "failed" (nil)
            versionProbe: { nil },         // probe "failed" (nil)
            cliUsageProbe: { nil })

        let box = EmissionBox()
        let collector = collect(provider.statuses(interaction: .background), into: box)
        let all = await awaitEmissions(box, count: 2)
        XCTAssertEqual(all.count, 2)
        let extras = try XCTUnwrap(all.last)
        XCTAssertNil(extras.error)
        XCTAssertNil(extras.version)
        XCTAssertNil(extras.serviceStatus)
        XCTAssertNil(extras.resetCreditsAvailable)
        collector.cancel()
    }

    /// `fetch()` (self-test path) returns the LAST emission — the enriched
    /// status — preserving the pre-stream single-shot contract.
    func testFetchReturnsEnrichedLastEmission() async throws {
        let url = tempURL()
        try writeAuth(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        stubUsageAndReset()
        defer { StubURLProtocol.reset() }

        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            authURL: url,
            statusProbe: { OpenAIServiceStatus(indicator: "none", description: "OK") },
            versionProbe: { "codex-cli 8.8.8" },
            cliUsageProbe: { nil })

        let status = try await provider.fetch()
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.count, 2)
        XCTAssertEqual(status.version, "codex-cli 8.8.8")
        XCTAssertEqual(status.serviceStatus, "OK")
        XCTAssertEqual(status.resetCreditsAvailable, 3)
    }

    /// Failure paths stay single-emission: an OAuth 500 in `.oauth` mode
    /// produces exactly one error emission (no extras tail).
    func testFailurePathEmitsSingleError() async throws {
        let url = tempURL()
        try writeAuth(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let provider = CodexProvider(
            session: URLSession(configuration: makeStubConfig()),
            authURL: url,
            source: .oauth,
            statusProbe: { nil },
            versionProbe: { nil },
            cliUsageProbe: { nil })

        var emissions: [ProviderStatus] = []
        for await status in provider.statuses(interaction: .background) {
            emissions.append(status)
        }
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.error, "HTTP 500")
    }
}
