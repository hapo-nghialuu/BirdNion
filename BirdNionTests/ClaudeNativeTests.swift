import XCTest
@testable import BirdNion

/// Native Claude provider tests — planner logic, OAuth usage mapping, Admin API
/// parsing, and cost-scan dedup. All pure / fixture-driven (no network, no real
/// Keychain or browser cookies), mirroring the CodexBar tests we ported from.
final class ClaudeNativeTests: XCTestCase {

    // MARK: - Source planner

    func testAutoPlanOrderAndAvailability() {
        let input = ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: false, hasOAuthCredentials: true)
        let plan = ClaudeSourcePlanner.resolve(input: input)
        // App-auto order is always OAuth → CLI → Web.
        XCTAssertEqual(plan.orderedSteps.map(\.dataSource), [.oauth, .cli, .web])
        // Only OAuth is available → it's the single execution step.
        XCTAssertEqual(plan.executionSteps.map(\.dataSource), [.oauth])
        XCTAssertEqual(plan.preferredStep?.dataSource, .oauth)
        XCTAssertFalse(plan.isNoSourceAvailable)
    }

    /// Regression: BirdNion shipped `.oauth` as the default while CodexBar
    /// defaults to `.auto`. `.oauth` pins the plan to a single step, so on
    /// macOS — where Claude Code keeps its OAuth token only in the Keychain and
    /// a background poll may not read it — every poll failed with
    /// "not configured" for an account that was signed in. `.auto` keeps the
    /// CLI/Web fallback that makes the failure recoverable.
    func testUnsetDataSourceDefaultsToAuto() {
        let suite = "birdnion.tests.claudeDataSource.unset"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(ClaudeUsageOrchestrator.readDataSource(userDefaults: defaults), .auto)
    }

    /// An unrecognized stored value must land on the mode WITH a fallback
    /// chain, never on a pinned single-step mode.
    func testUnrecognizedDataSourceFallsBackToAuto() {
        let suite = "birdnion.tests.claudeDataSource.garbage"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-a-source", forKey: "claudeUsageDataSource")

        XCTAssertEqual(ClaudeUsageOrchestrator.readDataSource(userDefaults: defaults), .auto)
    }

    /// The new default must not override a source the user actually chose.
    func testExplicitlyStoredDataSourceIsRespected() {
        let suite = "birdnion.tests.claudeDataSource.explicit"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for source in ClaudeUsageDataSource.allCases {
            defaults.set(source.rawValue, forKey: "claudeUsageDataSource")
            XCTAssertEqual(ClaudeUsageOrchestrator.readDataSource(userDefaults: defaults), source)
        }
    }

    /// The behavioral difference the default hinges on: `.auto` retries other
    /// sources after OAuth fails, a pinned mode has nothing to fall through to.
    func testAutoKeepsFallbackStepsWhileOAuthPinIsSingleStep() {
        let auto = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: true,
            hasWebSession: true, hasCLI: true, hasOAuthCredentials: true))
        XCTAssertEqual(auto.executionSteps.map(\.dataSource), [.oauth, .cli, .web])

        let pinned = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            selectedDataSource: .oauth, webExtrasEnabled: true,
            hasWebSession: true, hasCLI: true, hasOAuthCredentials: true))
        XCTAssertEqual(pinned.executionSteps.map(\.dataSource), [.oauth])
    }

    func testExplicitSourceIgnoresAvailability() {
        let input = ClaudeSourcePlanningInput(
            selectedDataSource: .web, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: false, hasOAuthCredentials: false)
        let plan = ClaudeSourcePlanner.resolve(input: input)
        // Explicit selection runs even when "unavailable" so the user sees the
        // real error instead of a silent skip.
        XCTAssertEqual(plan.executionSteps.map(\.dataSource), [.web])
    }

    func testWebCookieRetainsActiveOrganization() {
        let info = ClaudeWebCookieReader.sessionKeyInfo(
            cookieHeader: "sessionKey=sk-ant-test; lastActiveOrg=org-active; theme=light")

        XCTAssertEqual(info?.activeOrganizationID, "org-active")
        XCTAssertTrue(info?.cookieHeader.contains("lastActiveOrg=org-active") == true)
    }

    func testWebOrganizationSelectionPrefersActiveOrganization() throws {
        let json = """
        [
          {"uuid":"org-first","name":"Personal","capabilities":["chat"]},
          {"uuid":"org-active","name":"Team","capabilities":["chat"]}
        ]
        """.data(using: .utf8)!

        let selected = try ClaudeWebAPIFetcher._selectOrganizationIDForTesting(
            json, preferredOrganizationID: "org-active")
        XCTAssertEqual(selected, "org-active")
    }

    func testWebOrganizationSelectionSkipsActiveAPIOnlyOrganization() throws {
        let json = """
        [
          {"uuid":"org-api","name":"API","capabilities":["api"]},
          {"uuid":"org-chat","name":"Team","capabilities":["chat"]}
        ]
        """.data(using: .utf8)!

        let selected = try ClaudeWebAPIFetcher._selectOrganizationIDForTesting(
            json, preferredOrganizationID: "org-api")
        XCTAssertEqual(selected, "org-chat")
    }

    func testWebSessionRotationKeepsBrowserContext() {
        let rotated = ClaudeWebAPIFetcher._cookieHeaderAfterSessionRotationForTesting(
            "sessionKey=sk-ant-old; lastActiveOrg=org-active; cf_clearance=clear",
            renewedSessionKey: "sk-ant-new")

        XCTAssertTrue(rotated.contains("sessionKey=sk-ant-new"))
        XCTAssertFalse(rotated.contains("sessionKey=sk-ant-old"))
        XCTAssertTrue(rotated.contains("lastActiveOrg=org-active"))
        XCTAssertTrue(rotated.contains("cf_clearance=clear"))
    }

    func testWebFetchKeepsBrowserContextAfterSessionRotation() async throws {
        ClaudeWebURLProtocol.reset()
        defer { ClaudeWebURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeWebURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let usage = try await ClaudeWebAPIFetcher.fetchUsage(
            cookieHeader: "sessionKey=sk-ant-original; lastActiveOrg=org-active; cf_clearance=clear",
            session: session)

        XCTAssertEqual(usage.sessionPercentUsed, 12)
        let requests = ClaudeWebURLProtocol.requests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        let followups = requests.filter { $0.url?.path != "/api/organizations" }
        XCTAssertFalse(followups.isEmpty)
        for request in followups {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(cookie.contains("sessionKey=sk-ant-rotated"), request.url?.path ?? "")
            XCTAssertTrue(cookie.contains("lastActiveOrg=org-active"), request.url?.path ?? "")
            XCTAssertTrue(cookie.contains("cf_clearance=clear"), request.url?.path ?? "")
        }
    }

    // MARK: - Web usage: weekly from the `limits` array (2026 schema)

    func testWebUsageWeeklyFallsBackToAllModelsLimit() throws {
        // No flat `seven_day` — weekly lives only in `limits`. The account-wide
        // "All models" entry becomes the main weekly window; model-scoped
        // entries become "X only" extra bars.
        let json = """
        {"five_hour":{"utilization":12.0,"resets_at":"2026-07-26T18:00:00Z"},
         "seven_day_routines":{"utilization":3.0},
         "limits":[
           {"kind":"weekly_scoped","group":"weekly","percent":41.5,
            "resets_at":"2026-07-30T00:00:00Z",
            "scope":{"model":{"id":"all-models","display_name":"All models"}}},
           {"kind":"weekly_scoped","group":"weekly","percent":9.0,
            "scope":{"model":{"id":"claude-sonnet-4-5","display_name":"Sonnet"}}},
           {"kind":"weekly_scoped","group":"weekly","percent":null,
            "scope":{"model":{"id":"claude-haiku-4-5","display_name":"Haiku"}}}
         ]}
        """.data(using: .utf8)!
        let parsed = try ClaudeWebAPIFetcher.parseUsageForTesting(json)
        XCTAssertEqual(parsed.sessionPercentUsed, 12.0)
        XCTAssertEqual(parsed.weeklyPercentUsed, 41.5)
        XCTAssertNotNil(parsed.weeklyResetsAt)
        XCTAssertTrue(parsed.extraRateWindows.contains {
            $0.title == "Sonnet only" && $0.window.usedPercent == 9.0
        })
        // All-models feeds the main window, never an extra bar; null percents drop.
        XCTAssertFalse(parsed.extraRateWindows.contains { $0.title.contains("All models") })
        XCTAssertFalse(parsed.extraRateWindows.contains { $0.title.contains("Haiku") })
    }

    func testWebUsageSevenDayStillWinsOverLimits() throws {
        // Old schema intact: the flat seven_day takes precedence.
        let json = """
        {"five_hour":{"utilization":1.0},
         "seven_day":{"utilization":55.0,"resets_at":"2026-07-29T00:00:00Z"},
         "limits":[
           {"kind":"weekly_scoped","group":"weekly","percent":41.5,
            "scope":{"model":{"id":"all-models","display_name":"All models"}}}
         ]}
        """.data(using: .utf8)!
        let parsed = try ClaudeWebAPIFetcher.parseUsageForTesting(json)
        XCTAssertEqual(parsed.weeklyPercentUsed, 55.0)
    }

    // MARK: - CLI timeout + retry policy (CodexBar parity)

    func testDirectCLIUsageTimeoutClamp() {
        // 1/3 of the PTY budget, clamped to 6–8s — same as CodexBar.
        XCTAssertEqual(ClaudeUsageOrchestrator.directCLIUsageTimeout(for: 12), 6)
        XCTAssertEqual(ClaudeUsageOrchestrator.directCLIUsageTimeout(for: 24), 8)
        XCTAssertEqual(ClaudeUsageOrchestrator.directCLIUsageTimeout(for: 60), 8)
    }

    func testShouldRetryCLIProbePolicy() {
        XCTAssertTrue(ClaudeUsageOrchestrator.shouldRetryCLIProbe(after: ClaudeStatusProbeError.timedOut))
        XCTAssertTrue(ClaudeUsageOrchestrator.shouldRetryCLIProbe(
            after: ClaudeStatusProbeError.parseFailed("Claude CLI still loading usage panel")))
        XCTAssertFalse(ClaudeUsageOrchestrator.shouldRetryCLIProbe(
            after: ClaudeStatusProbeError.parseFailed("missing session data")))
    }

    func testShouldTryDirectCLIUsagePolicy() {
        XCTAssertTrue(ClaudeUsageOrchestrator.shouldTryDirectCLIUsage(after: ClaudeStatusProbeError.timedOut))
        XCTAssertTrue(ClaudeUsageOrchestrator.shouldTryDirectCLIUsage(
            after: ClaudeStatusProbeError.parseFailed("could not load usage data")))
        XCTAssertFalse(ClaudeUsageOrchestrator.shouldTryDirectCLIUsage(
            after: ClaudeStatusProbeError.parseFailed("missing session data")))
    }

    // MARK: - CLI quota-unsupported gate

    func testCLIQuotaUnsupportedGateRecordsAndClears() {
        ClaudeCLIQuotaUnsupportedGate.resetForTesting()
        defer { ClaudeCLIQuotaUnsupportedGate.resetForTesting() }
        XCTAssertNil(ClaudeCLIQuotaUnsupportedGate.blockedUntil())
        // The deterministic "no quota panel" parse failure arms the gate…
        XCTAssertTrue(ClaudeCLIQuotaUnsupportedGate.isQuotaUnsupportedError(
            ClaudeStatusProbeError.parseFailed("Missing Current session.")))
        XCTAssertFalse(ClaudeCLIQuotaUnsupportedGate.isQuotaUnsupportedError(
            ClaudeStatusProbeError.timedOut))
        ClaudeCLIQuotaUnsupportedGate.recordUnsupported()
        XCTAssertNotNil(ClaudeCLIQuotaUnsupportedGate.blockedUntil())
        // …and a later successful probe clears it.
        ClaudeCLIQuotaUnsupportedGate.recordSuccess()
        XCTAssertNil(ClaudeCLIQuotaUnsupportedGate.blockedUntil())
    }

    // MARK: - Rate-limit gate interaction bypass

    func testCLIRateLimitGateBypassesUserInitiated() {
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }
        ClaudeCLIRateLimitGate.recordRateLimit()
        // Background fetches respect the cooldown; user-initiated bypass it.
        XCTAssertNotNil(ClaudeCLIRateLimitGate.blockedUntil(interaction: .background))
        XCTAssertNil(ClaudeCLIRateLimitGate.blockedUntil(interaction: .userInitiated))
        ClaudeCLIRateLimitGate.recordSuccess()
        XCTAssertNil(ClaudeCLIRateLimitGate.blockedUntil(interaction: .background))
    }

    // MARK: - Keychain prompt gating

    func testAllowKeychainPromptMatrix() {
        // `.never` never prompts, `.always` always does, `.onlyOnUserAction`
        // only during a user-forced refresh — mirrors CodexBar.
        XCTAssertFalse(ClaudeProvider.allowKeychainPrompt(mode: .never, interaction: .background))
        XCTAssertFalse(ClaudeProvider.allowKeychainPrompt(mode: .never, interaction: .userInitiated))
        XCTAssertTrue(ClaudeProvider.allowKeychainPrompt(mode: .always, interaction: .background))
        XCTAssertTrue(ClaudeProvider.allowKeychainPrompt(mode: .always, interaction: .userInitiated))
        XCTAssertFalse(ClaudeProvider.allowKeychainPrompt(mode: .onlyOnUserAction, interaction: .background))
        XCTAssertTrue(ClaudeProvider.allowKeychainPrompt(mode: .onlyOnUserAction, interaction: .userInitiated))
    }

    // MARK: - OAuth usage mapping

    func testMapOAuthUsageWindowsCostRoutines() throws {
        let json = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-06-28T00:00:00Z"},
         "seven_day":{"utilization":10.0},
         "seven_day_opus":{"utilization":5.0},
         "seven_day_sonnet":{"utilization":7.0},
         "seven_day_routines":{"utilization":20.0},
         "extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":500,"currency":"USD"}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let creds = ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(usage, credentials: creds)

        XCTAssertEqual(snap.primary?.usedPercent, 42.0)
        XCTAssertEqual(snap.secondary?.usedPercent, 10.0)
        XCTAssertEqual(snap.opus?.usedPercent, 5.0)
        // extra_usage is in cents → dollars.
        XCTAssertEqual(snap.providerCost?.used, 5.0)
        XCTAssertEqual(snap.providerCost?.limit, 20.0)
        // Sonnet + Daily Routines surface as named extra windows.
        let titles = snap.extraRateWindows.map(\.title)
        XCTAssertTrue(titles.contains("Daily Routines"))
        XCTAssertTrue(titles.contains("Sonnet"))
    }

    func testMapOAuthSpendLimitWhenNoUsageWindows() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":250,"currency":"USD"}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(
            usage, credentials: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil))
        XCTAssertEqual(snap.primaryWindowKind, .spendLimit)
        XCTAssertEqual(snap.providerCost?.used, 2.5)
        XCTAssertEqual(snap.providerCost?.limit, 10.0)
    }

    func testOAuthMissingUtilizationDoesNotFabricatePrimaryOrRoutine() throws {
        let json = """
        {"five_hour":{"utilization":null},
         "seven_day":{"utilization":null},
         "seven_day_oauth_apps":{"utilization":null},
         "seven_day_routines":{"utilization":null}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(
            usage, credentials: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil))

        XCTAssertNil(snap.primary)
        XCTAssertTrue(snap.extraRateWindows.isEmpty)
        XCTAssertNil(snap.providerCost)
    }

    func testOAuthNumericZeroRemainsKnownUsage() throws {
        let json = """
        {"five_hour":{"utilization":0.0},
         "seven_day_routines":{"utilization":0.0}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(
            usage, credentials: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil))

        XCTAssertEqual(snap.primary?.usedPercent, 0)
        XCTAssertEqual(snap.extraRateWindows.first?.window.usedPercent, 0)
        XCTAssertTrue(snap.extraRateWindows.first?.usageKnown == true)
    }

    func testWebMissingNullAndWrongTypeSessionUsageIsUnknown() throws {
        let payloads = [
            "{}",
            #"{"five_hour":null}"#,
            #"{"five_hour":{"utilization":null}}"#,
            #"{"five_hour":{"utilization":"0"}}"#
        ]

        for payload in payloads {
            let parsed = try ClaudeWebAPIFetcher.parseUsageForTesting(Data(payload.utf8))
            XCTAssertNil(parsed.sessionPercentUsed, payload)
        }

        let zero = try ClaudeWebAPIFetcher.parseUsageForTesting(
            Data(#"{"five_hour":{"utilization":0}}"#.utf8))
        XCTAssertEqual(zero.sessionPercentUsed, 0)
    }

    func testMaterializeDropsUnknownExtrasAndCarriesSourceLabel() {
        let unknownRoutine = NamedRateWindow(
            id: "claude-routines",
            title: "Daily Routines",
            window: RateWindow(usedPercent: 0, windowMinutes: 7 * 24 * 60,
                               resetsAt: nil, resetDescription: nil),
            usageKnown: false)
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 2, windowMinutes: 5 * 60,
                                resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            extraRateWindows: [unknownRoutine])

        let status = ClaudeProvider.materialize(
            from: snapshot, override: nil, sourceLabel: "OAuth", status: nil,
            allowKeychainRead: false)

        XCTAssertEqual(status.sourceLabel, "OAuth")
        XCTAssertEqual(status.windows.first?.remainingPct, 98)
        XCTAssertFalse(status.windows.contains { $0.label == "Daily Routines" })
        XCTAssertEqual(status.webExtras?.extraRateWindows.count, 0)
    }

    func testMaterializeIncludesFableButNotOtherScopedWeeklies() {
        let fable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: RateWindow(usedPercent: 29, windowMinutes: 7 * 24 * 60,
                               resetsAt: nil, resetDescription: nil),
            usageKnown: true)
        let sonnetOnly = NamedRateWindow(
            id: "claude-weekly-scoped-sonnet",
            title: "Sonnet only",
            window: RateWindow(usedPercent: 10, windowMinutes: 7 * 24 * 60,
                               resetsAt: nil, resetDescription: nil),
            usageKnown: true)
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 2, windowMinutes: 5 * 60,
                                resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            extraRateWindows: [fable, sonnetOnly])

        let status = ClaudeProvider.materialize(
            from: snapshot, override: nil, sourceLabel: "cli", status: nil,
            allowKeychainRead: false)

        XCTAssertTrue(status.windows.contains { $0.label == "Fable" && $0.isSupplementary })
        XCTAssertFalse(status.windows.contains { $0.label.localizedCaseInsensitiveContains("Sonnet") })
        XCTAssertTrue(ClaudeProvider.isFableWindowLabel("Fable"))
        XCTAssertTrue(ClaudeProvider.isFableWindowLabel("Fable only"))
        XCTAssertFalse(ClaudeProvider.isFableWindowLabel("5 giờ"))
    }

    // MARK: - Prepaid Extra usage balance

    func testPrepaidBalanceParsesMinorUnits() throws {
        let data = #"{"amount":12345,"currency":"usd"}"#.data(using: .utf8)!
        let balance = try XCTUnwrap(ClaudeWebAPIFetcher.parsePrepaidBalanceForTesting(data))
        XCTAssertEqual(balance.amount, 123.45, accuracy: 0.001)
        XCTAssertEqual(balance.currencyCode, "USD")
    }

    func testPrepaidBalanceMergesWithBillingCost() throws {
        let balanceData = #"{"amount":1250,"currency":"USD"}"#.data(using: .utf8)!
        let cost = ProviderCostSnapshot(
            used: 2.5, limit: 20, currencyCode: "USD", period: "Monthly cap", updatedAt: Date())
        let merged = try XCTUnwrap(
            ClaudeWebAPIFetcher.applyingPrepaidBalanceForTesting(balanceData, to: cost))
        XCTAssertEqual(merged.balance, 12.5)
        let snapshot = ClaudeUsageSnapshot(
            primary: nil, secondary: nil, opus: nil, providerCost: merged)
        let status = ClaudeProvider.materialize(
            from: snapshot, override: nil, sourceLabel: "Web", status: nil,
            allowKeychainRead: false)
        XCTAssertEqual(status.creditsRemaining, 12.5)
    }

    func testPrepaidBalanceWorksWithoutBillingCost() throws {
        let data = #"{"amount":875,"currency":"USD"}"#.data(using: .utf8)!
        let merged = try XCTUnwrap(
            ClaudeWebAPIFetcher.applyingPrepaidBalanceForTesting(data, to: nil))
        XCTAssertEqual(merged.limit, 0)
        XCTAssertEqual(merged.balance, 8.75)
        let snapshot = ClaudeUsageSnapshot(
            primary: nil, secondary: nil, opus: nil, providerCost: merged)
        let status = ClaudeProvider.materialize(
            from: snapshot, override: nil, sourceLabel: "Web", status: nil,
            allowKeychainRead: false)
        XCTAssertEqual(status.creditsRemaining, 8.75)
    }

    func testPrepaidEndpointFailureIsNoOp() {
        XCTAssertNil(ClaudeWebAPIFetcher.parsePrepaidBalanceForTesting(Data("not json".utf8)))
        let valid = #"{"amount":100,"currency":"USD"}"#.data(using: .utf8)!
        XCTAssertTrue(ClaudeWebAPIFetcher.prepaidResponseFailureForTesting(valid))
    }

    // MARK: - Max multiplier labels

    func testClaudeMaxMultiplierLabels() {
        XCTAssertEqual(
            ClaudePlanLabeler.label(subscriptionType: nil, rateLimitTier: "default_claude_max_5x"),
            "Max 5x")
        XCTAssertEqual(
            ClaudePlanLabeler.label(subscriptionType: nil, rateLimitTier: "default_claude_max_20x"),
            "Max 20x")
        XCTAssertEqual(
            ClaudePlanLabeler.label(subscriptionType: nil, rateLimitTier: "v2_default_claude_max_20x"),
            "Max 20x")
        XCTAssertEqual(
            ClaudePlanLabeler.label(subscriptionType: "team", rateLimitTier: "default_claude_max_5x"),
            "Team")
        XCTAssertEqual(
            ClaudePlanLabeler.label(subscriptionType: nil, rateLimitTier: nil),
            nil)
    }


    func testAdminSnapshotRollup() throws {
        let costs = """
        {"data":[{"starting_at":"2026-06-01T00:00:00Z","ending_at":"2026-06-02T00:00:00Z",
          "results":[{"amount":"1234","description":"Claude API"}]}]}
        """.data(using: .utf8)!
        let messages = """
        {"data":[{"starting_at":"2026-06-01T00:00:00Z","ending_at":"2026-06-02T00:00:00Z",
          "results":[{"uncached_input_tokens":100,"cache_read_input_tokens":20,
                      "output_tokens":50,"model":"claude-opus-4"}]}]}
        """.data(using: .utf8)!
        let now = ISO8601DateFormatter().date(from: "2026-06-15T00:00:00Z")!
        let snap = try ClaudeAdminAPIUsageFetcher.parseSnapshotForTesting(
            costs: costs, messages: messages, now: now)
        XCTAssertEqual(snap.daily.count, 1)
        XCTAssertEqual(snap.last30Days.costUSD, 12.34, accuracy: 0.001)   // cents → dollars
        XCTAssertEqual(snap.last30Days.totalTokens, 170)
        XCTAssertEqual(snap.topModels.first?.name, "claude-opus-4")
    }

    // MARK: - Cost-scan dedup across roots

    func testCostScanDedupsSameMessageAcrossRoots() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root1 = base.appendingPathComponent("a/projects/enc")
        let root2 = base.appendingPathComponent("b/projects/enc")
        try fm.createDirectory(at: root1, withIntermediateDirectories: true)
        try fm.createDirectory(at: root2, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        // Same message (id+requestId) logged in both a parent and a subagent
        // file — must be counted ONCE, not twice.
        let line = """
        {"type":"assistant","timestamp":"\(ts)","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        try line.write(to: root1.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: root2.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)

        let report = ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("a/projects"),
                    base.appendingPathComponent("b/projects")],
            now: Date())
        XCTAssertEqual(report?.last30Tokens, 150)   // 100 + 50, deduped (not 300)
    }

    /// Multi-content-block assistant turns repeat identical usage on 3 lines
    /// with the same message.id and no requestId — must count once.
    func testCostScanDedupsSameMessageIdWithoutRequestIdInOneFile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"type":"assistant","timestamp":"\(ts)",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        let body = [line, line, line].joined(separator: "\n")
        try body.write(to: root.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)

        let report = ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("projects")],
            now: Date())
        XCTAssertEqual(report?.last30Tokens, 150)   // not 450
    }

    /// Parent session + subagent file both log the same message.id without
    /// requestId — must count once.
    func testCostScanDedupsSameMessageIdWithoutRequestIdAcrossFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"type":"assistant","timestamp":"\(ts)",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        try line.write(to: root.appendingPathComponent("parent.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: root.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)

        let report = ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("projects")],
            now: Date())
        XCTAssertEqual(report?.last30Tokens, 150)   // not 300
    }

    /// `scanDays` narrows both the entry cutoff and the daily bucket window;
    /// the default keeps the full 120-day behaviour.
    func testCostScanFullScanDaysNarrowsWindow() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-2 * 86_400))
        let old = iso.string(from: now.addingTimeInterval(-10 * 86_400))
        let lines = """
        {"type":"assistant","timestamp":"\(recent)","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","timestamp":"\(old)","requestId":"r2",\
        "message":{"id":"m2","model":"claude-sonnet","usage":{"input_tokens":200,"output_tokens":100}}}
        """
        try lines.write(to: root.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)
        let roots = [base.appendingPathComponent("projects")]

        // Narrow scan: only the 2-day-old entry is inside the 7-day cutoff.
        let narrow = ClaudeCostScanner.scanFull(roots: roots, now: now, scanDays: 7)
        XCTAssertEqual(narrow?.daily.count, 7)
        XCTAssertEqual(narrow?.daily.map(\.tokens).reduce(0, +), 150)

        // Default window still counts both entries.
        let full = ClaudeCostScanner.scanFull(roots: roots, now: now)
        XCTAssertEqual(full?.daily.count, 120)
        XCTAssertEqual(full?.daily.map(\.tokens).reduce(0, +), 450)
    }

    func testHapoModelPricesAndPricingRevision() throws {
        let luna = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-luna"))
        XCTAssertEqual(luna.inputPerM, 1.0, accuracy: 0.0001)
        XCTAssertEqual(luna.cacheReadPerM, 0.10, accuracy: 0.0001)
        XCTAssertEqual(luna.outputPerM, 6.0, accuracy: 0.0001)
        let longLuna = try XCTUnwrap(ClaudeModelPrice.price(
            for: "openai.gpt-5.6-luna", inputSideTokens: 272_001))
        XCTAssertEqual(longLuna.inputPerM, 2.0, accuracy: 0.0001)
        XCTAssertEqual(longLuna.outputPerM, 9.0, accuracy: 0.0001)

        let terra = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-terra"))
        XCTAssertEqual(terra.inputPerM, 2.5, accuracy: 0.0001)
        XCTAssertEqual(terra.outputPerM, 15.0, accuracy: 0.0001)
        let sol = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-sol"))
        XCTAssertEqual(sol.inputPerM, 5.0, accuracy: 0.0001)
        XCTAssertEqual(sol.outputPerM, 30.0, accuracy: 0.0001)

        let m25 = try XCTUnwrap(ClaudeModelPrice.price(for: "minimax.minimax-m2.5"))
        XCTAssertEqual(m25.inputPerM, 0.30, accuracy: 0.0001)
        XCTAssertEqual(m25.cacheWritePerM, 0.375, accuracy: 0.0001)
        XCTAssertEqual(m25.cacheReadPerM, 0.03, accuracy: 0.0001)
        XCTAssertEqual(m25.outputPerM, 1.20, accuracy: 0.0001)
        XCTAssertNotNil(ClaudeModelPrice.price(for: "minimax-m2.5-ultra-5"))
        XCTAssertNil(ClaudeModelPrice.price(for: "gpt-5.6-luna"))
        XCTAssertNil(ClaudeModelPrice.price(for: "openai.gpt-5.60-luna"))

        XCTAssertEqual(ClaudeCostScanner.scanDaysForHistory(
            storedPricingRevision: 0, incrementalDays: 7), ClaudeCostScanner.historyDays)
        XCTAssertEqual(ClaudeCostScanner.scanDaysForHistory(
            storedPricingRevision: ClaudeCostScanner.pricingRevision, incrementalDays: 7), 7)
        XCTAssertEqual(ClaudeCostScanner.scanDaysForProjectHistory(
            storedPricingRevision: ClaudeCostScanner.pricingRevision,
            incrementalDays: 7,
            hasStoredClaudeProjects: false), ClaudeCostScanner.historyDays)
        XCTAssertEqual(ClaudeCostScanner.scanDaysForProjectHistory(
            storedPricingRevision: ClaudeCostScanner.pricingRevision,
            incrementalDays: 7,
            hasStoredClaudeProjects: true), 7)
    }

    /// Lines without a parseable timestamp must not fall into "today".
    func testCostScanDropsLinesWithoutParseableTimestamp() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        let lines = """
        {"type":"assistant","timestamp":"\(ts)","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant",\
        "message":{"id":"m2","model":"claude-sonnet","usage":{"input_tokens":900,"output_tokens":0}}}
        {"type":"assistant","timestamp":"not-a-date","requestId":"r3",\
        "message":{"id":"m3","model":"claude-sonnet","usage":{"input_tokens":800,"output_tokens":0}}}
        """
        try lines.write(to: root.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)

        let report = ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("projects")],
            now: Date())
        XCTAssertEqual(report?.todayTokens, 150)
        XCTAssertEqual(report?.last30Tokens, 150)
    }
}

private final class ClaudeWebURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func reset() {
        lock.lock()
        capturedRequests.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "claude.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.capturedRequests.append(request)
        Self.lock.unlock()

        let body: Data
        let statusCode: Int
        var headers = ["Content-Type": "application/json"]
        switch url.path {
        case "/api/organizations":
            statusCode = 200
            headers["Set-Cookie"] = "sessionKey=sk-ant-rotated; Path=/"
            body = Data(#"[{"uuid":"org-first","name":"Personal","capabilities":["chat"]},{"uuid":"org-active","name":"Team","capabilities":["chat"]}]"#.utf8)
        case "/api/organizations/org-active/usage":
            statusCode = 200
            body = Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":4}}"#.utf8)
        default:
            statusCode = 404
            body = Data("{}".utf8)
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
