import XCTest
@testable import BirdNion

/// Task-05 coverage for the Claude staged auto plan: planner stage shape,
/// OAuth‖Web race semantics (first trusted wins, OAuth tie-break, loser-Web
/// extras reuse, CLI fallback), the background starvation guard, and the
/// provider's core→enrichment emission order. Everything runs through the
/// `ClaudeUsageOrchestrator.Fetchers` seam — no network, Keychain, or PTY.
final class ClaudeRacePlanTests: XCTestCase {

    // MARK: - Recorder

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _counts: [String: Int] = [:]
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
        func mark(_ event: String) { lock.lock(); defer { lock.unlock() }; _events.append(event) }
        func bump(_ key: String) { lock.lock(); defer { lock.unlock() }; _counts[key, default: 0] += 1 }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return _counts[key] ?? 0 }
    }

    /// Virtual clock for the starvation-guard test: `advance` moves the time
    /// the orchestrator sees without slowing the test down.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    // MARK: - Fixtures

    private static func trustedOAuth() -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300,
                                resetsAt: nil, resetDescription: nil),
            secondary: nil, opus: nil)
    }

    private static func untrusted() -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(primary: nil, secondary: nil, opus: nil)
    }

    private static func webData(cost: ProviderCostSnapshot? = nil) -> ClaudeWebUsageData {
        ClaudeWebUsageData(
            sessionPercentUsed: 55, sessionResetsAt: nil,
            weeklyPercentUsed: nil, weeklyResetsAt: nil,
            opusPercentUsed: nil, extraRateWindows: [],
            extraUsageCost: cost,
            accountEmail: "web@example.com",
            accountOrganization: nil, loginMethod: "Claude Max")
    }

    private static func cliData() -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 30, weeklyPercentLeft: nil, opusPercentLeft: nil,
            identity: .init(accountEmail: nil, accountOrganization: nil,
                            loginMethod: nil),
            primaryResetDescription: nil, secondaryResetDescription: nil,
            opusResetDescription: nil, rawText: "stub")
    }

    /// Cancellation-cooperative sleep used by stub fetchers.
    private static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Fetchers preset for the `.auto` plan with every source available;
    /// per-source behavior is supplied per test.
    private static func makeFetchers(
        recorder: Recorder,
        oauth: (@Sendable () async throws -> ClaudeUsageSnapshot)? = nil,
        web: (@Sendable () async throws -> ClaudeWebUsageData)? = nil,
        cli: (@Sendable () async throws -> ClaudeStatusSnapshot)? = nil,
        clock: FakeClock? = nil
    ) -> ClaudeUsageOrchestrator.Fetchers {
        var f = ClaudeUsageOrchestrator.Fetchers.live
        f.readDataSource = { .auto }
        // `.manual` + a cookie ⇒ web session plausibly available.
        f.readCookieSource = { .manual }
        f.readManualCookie = { "sessionKey=sk-ant-test" }
        f.hasCLI = { true }
        f.autoWebSessionSuppressed = { false }
        if let clock { f.now = { clock.now() } }
        f.oauth = { _, _ in
            recorder.bump("oauth")
            recorder.mark("oauth.start")
            do {
                let value = try await oauth?() ?? trustedOAuth()
                recorder.mark("oauth.done")
                return value
            } catch {
                recorder.mark("oauth.err")
                throw error
            }
        }
        f.web = { _, _, _ in
            recorder.bump("web")
            recorder.mark("web.start")
            do {
                let value = try await web?() ?? webData()
                recorder.mark("web.done")
                return value
            } catch {
                recorder.mark("web.err")
                throw error
            }
        }
        f.cli = { _, _, _ in
            recorder.bump("cli")
            recorder.mark("cli.start")
            return try await cli?() ?? cliData()
        }
        return f
    }

    // MARK: - Planner stages

    func testAutoPlanEmitsRaceStageThenCLIStage() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: true,
            hasWebSession: true, hasCLI: true, hasOAuthCredentials: true))
        XCTAssertEqual(plan.executionStages, [
            .race([
                ClaudeFetchPlanStep(dataSource: .oauth,
                                    inclusionReason: .appAutoPreferredOAuth,
                                    isPlausiblyAvailable: true),
                ClaudeFetchPlanStep(dataSource: .web,
                                    inclusionReason: .appAutoFallbackWeb,
                                    isPlausiblyAvailable: true),
            ]),
            .single(ClaudeFetchPlanStep(dataSource: .cli,
                                        inclusionReason: .appAutoFallbackCLI,
                                        isPlausiblyAvailable: true)),
        ])
        XCTAssertEqual(plan.orderLabel, "oauth‖web→cli")
        XCTAssertTrue(plan.debugLines().contains("planner_order=oauth‖web→cli"))
    }

    func testAutoPlanFiltersUnavailableHTTPSources() {
        // No web session → race carries OAuth only.
        let noWeb = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: true, hasOAuthCredentials: true))
        XCTAssertEqual(noWeb.executionStages.map { $0.steps.map(\.dataSource) },
                       [[.oauth], [.cli]])

        // No OAuth credentials → race carries Web only.
        let noOAuth = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: true,
            hasWebSession: true, hasCLI: true, hasOAuthCredentials: false))
        XCTAssertEqual(noOAuth.executionStages.map { $0.steps.map(\.dataSource) },
                       [[.web], [.cli]])
        XCTAssertEqual(noOAuth.orderLabel, "web→cli")

        // Neither HTTP source → CLI stage alone.
        let cliOnly = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: true, hasOAuthCredentials: false))
        XCTAssertEqual(cliOnly.executionStages.map { $0.steps.map(\.dataSource) }, [[.cli]])

        // Nothing at all → empty plan, isNoSourceAvailable.
        let none = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: false, hasOAuthCredentials: false))
        XCTAssertTrue(none.executionStages.isEmpty)
        XCTAssertTrue(none.isNoSourceAvailable)
    }

    func testPinnedSourcesStaySingleStage() {
        for source in [ClaudeUsageDataSource.api, .oauth, .web, .cli] {
            let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
                selectedDataSource: source, webExtrasEnabled: true,
                hasWebSession: true, hasCLI: true, hasOAuthCredentials: true))
            XCTAssertEqual(plan.executionStages, [
                .single(ClaudeFetchPlanStep(
                    dataSource: source,
                    inclusionReason: .explicitSourceSelection,
                    isPlausiblyAvailable: plan.orderedSteps[0].isPlausiblyAvailable)),
            ])
        }
    }

    // MARK: - Race semantics

    /// Spec case: Web trusted at ~0.2s, OAuth trusted only at ~30s. The core
    /// must resolve from the Web result without awaiting OAuth — and CLI must
    /// never run. Also proves both sources started concurrently (counterexample
    /// coverage: OAuth awaited before Web starts would leave no web.start).
    func testRaceResolvesFromFirstTrustedWebWithoutWaitingForOAuth() async throws {
        let recorder = Recorder()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: {
                try await Self.sleep(30)
                return Self.trustedOAuth()
            },
            web: {
                try await Self.sleep(0.2)
                return Self.webData()
            })
        let start = Date()
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.sourceLabel, "web")
        XCTAssertLessThan(elapsed, 15, "core must not wait for the 30s OAuth")
        XCTAssertEqual(recorder.count("cli"), 0)

        let events = recorder.events
        let webDone = events.firstIndex(of: "web.done")
        let oauthStart = events.firstIndex(of: "oauth.start")
        let webStart = events.firstIndex(of: "web.start")
        XCTAssertNotNil(webDone); XCTAssertNotNil(oauthStart); XCTAssertNotNil(webStart)
        if let webDone, let oauthStart, let webStart {
            XCTAssertGreaterThan(webDone, oauthStart)
            XCTAssertGreaterThan(webDone, webStart)
        }
    }

    /// OAuth resolves trusted inside the tie-break grace after Web → OAuth
    /// outranks Web when both resolve.
    func testOAuthWinsTieBreakInsideGrace() async throws {
        let recorder = Recorder()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: {
                try await Self.sleep(0.2)
                return Self.trustedOAuth()
            },
            web: {
                try await Self.sleep(0.05)
                return Self.webData()
            })
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "oauth")
        XCTAssertEqual(recorder.count("cli"), 0)
    }

    /// Both HTTP sources fail → the CLI stage runs exactly once.
    func testBothHTTPFailuresInvokeCLIExactlyOnce() async throws {
        let recorder = Recorder()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: { throw ClaudeUsageError.oauthFailed("no token") },
            web: { throw ClaudeUsageError.parseFailed("no cookies") })
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "cli")
        XCTAssertEqual(recorder.count("cli"), 1)
        XCTAssertEqual(recorder.count("oauth"), 1)
        XCTAssertEqual(recorder.count("web"), 1)
    }

    /// OAuth wins fast; the losing Web result lands inside the extras window →
    /// it feeds `applyWebExtras` (cost merged into the OAuth snapshot) with no
    /// second scrape.
    func testLosingWebResultFeedsExtrasWithoutRescrape() async throws {
        let recorder = Recorder()
        let webCost = ProviderCostSnapshot(
            used: 12.5, limit: 50, currencyCode: "USD", updatedAt: Date())
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: {
                try await Self.sleep(0.05)
                return Self.trustedOAuth()   // no providerCost
            },
            web: {
                try await Self.sleep(0.3)
                return Self.webData(cost: webCost)
            })
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "oauth")
        XCTAssertEqual(result.snapshot.providerCost, webCost)
        XCTAssertEqual(recorder.count("web"), 1)
        XCTAssertEqual(recorder.count("cli"), 0)
    }

    /// Untrusted OAuth data + failed Web → CLI fallback still engages.
    func testUntrustedOAuthFallsThroughToCLI() async throws {
        let recorder = Recorder()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: { Self.untrusted() },
            web: { throw ClaudeUsageError.parseFailed("unauthorized") })
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "cli")
        XCTAssertEqual(recorder.count("cli"), 1)
    }

    /// CLI starvation guard (F-09): HTTP sources burn ~55s of the 60s core
    /// budget before failing → the CLI stage is skipped rather than spawning a
    /// PTY probe that cannot fit.
    func testCLIStarvationGuardSkipsDoomedProbe() async {
        let recorder = Recorder()
        let clock = FakeClock()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: { clock.advance(55); throw ClaudeUsageError.oauthFailed("x") },
            web: { throw ClaudeUsageError.parseFailed("y") },
            clock: clock)
        do {
            _ = try await ClaudeUsageOrchestrator.loadLatestUsage(
                allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
            XCTFail("all sources failed — must throw")
        } catch { }
        XCTAssertEqual(recorder.count("cli"), 0)
    }

    /// Manual interaction keeps the full CLI path even with a nearly spent
    /// budget — the starvation guard is background-only.
    func testManualInteractionStillRunsCLIStage() async throws {
        let recorder = Recorder()
        let clock = FakeClock()
        let fetchers = Self.makeFetchers(
            recorder: recorder,
            oauth: { clock.advance(115); throw ClaudeUsageError.oauthFailed("x") },
            web: { throw ClaudeUsageError.parseFailed("y") },
            clock: clock)
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .userInitiated, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "cli")
        XCTAssertEqual(recorder.count("cli"), 1)
    }

    /// Web disabled (cookie source `.off`) → race carries OAuth only, no web
    /// extras scrape is attempted.
    func testWebOffLeavesOAuthOnlyRace() async throws {
        let recorder = Recorder()
        var fetchers = Self.makeFetchers(recorder: recorder)
        fetchers.readCookieSource = { .off }
        fetchers.readManualCookie = { nil }
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "oauth")
        XCTAssertEqual(recorder.count("web"), 0)
        XCTAssertEqual(recorder.count("cli"), 0)
    }

    /// Pinned `.web` runs the single web step — OAuth and CLI never start.
    func testPinnedWebNeverTouchesOAuthOrCLI() async throws {
        let recorder = Recorder()
        var fetchers = Self.makeFetchers(recorder: recorder)
        fetchers.readDataSource = { .web }
        let result = try await ClaudeUsageOrchestrator.loadLatestUsage(
            allowKeychainPrompt: false, interaction: .background, fetchers: fetchers)
        XCTAssertEqual(result.sourceLabel, "web")
        XCTAssertEqual(recorder.count("oauth"), 0)
        XCTAssertEqual(recorder.count("cli"), 0)
    }

    // MARK: - Provider two-phase emission

    /// Core emission carries quota windows before the statuspage probe / CLI
    /// version settle; the enrichment emission carries no `error`.
    func testProviderEmitsCoreThenEnrichment() async throws {
        let recorder = Recorder()
        // Web resolves slightly later so OAuth wins deterministically.
        let fetchers = Self.makeFetchers(recorder: recorder, web: {
            try await Self.sleep(0.3)
            return Self.webData()
        })

        let key = "statusChecksEnabled"
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)   // skip real statuspage probe
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let provider = ClaudeProvider(fetchers: fetchers)
        var emissions: [ProviderStatus] = []
        for await status in provider.statuses(interaction: .background) {
            emissions.append(status)
        }

        XCTAssertEqual(emissions.count, 2)
        let core = emissions[0]
        XCTAssertNil(core.error)
        XCTAssertFalse(core.windows.isEmpty)
        XCTAssertEqual(core.sourceLabel, "oauth")
        XCTAssertNil(core.version, "version rides the enrichment emission")
        XCTAssertNil(core.serviceStatus)
        let enriched = emissions[1]
        XCTAssertNil(enriched.error)
    }
}
