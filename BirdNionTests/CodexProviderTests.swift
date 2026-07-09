import XCTest
@testable import BirdNion

final class CodexProviderTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }

    // MARK: - CodexAuthStore.parse

    func testParseOAuthTokens() throws {
        let json = """
        {"tokens":{"access_token":"at","refresh_token":"rt","id_token":"it","account_id":"acc"},
         "last_refresh":"2026-06-01T00:00:00Z"}
        """.data(using: .utf8)!
        let creds = try CodexAuthStore.parse(json)
        XCTAssertEqual(creds.accessToken, "at")
        XCTAssertEqual(creds.refreshToken, "rt")
        XCTAssertEqual(creds.accountId, "acc")
        XCTAssertNotNil(creds.lastRefresh)
    }

    func testParseAPIKeyFallback() throws {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#.data(using: .utf8)!
        let creds = try CodexAuthStore.parse(json)
        XCTAssertEqual(creds.accessToken, "sk-test")
        XCTAssertTrue(creds.refreshToken.isEmpty)
    }

    func testParseMissingTokens() {
        let json = #"{"other":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexAuthStore.parse(json)) { error in
            XCTAssertEqual(error as? CodexAuthError, .missingTokens)
        }
    }

    func testLoadNotFound() {
        XCTAssertThrowsError(try CodexAuthStore.load(url: tempURL())) { error in
            XCTAssertEqual(error as? CodexAuthError, .notFound)
        }
    }

    func testSaveRoundTripPrivatePermissions() throws {
        let url = tempURL()
        let creds = CodexCredentials(
            accessToken: "new-at", refreshToken: "new-rt",
            idToken: nil, accountId: "acc", lastRefresh: Date())
        try CodexAuthStore.save(creds, url: url)
        let reloaded = try CodexAuthStore.load(url: url)
        XCTAssertEqual(reloaded.accessToken, "new-at")
        XCTAssertEqual(reloaded.refreshToken, "new-rt")

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - needsRefresh

    func testNeedsRefreshBoundary() {
        let stale = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: Date().addingTimeInterval(-9 * 86400))
        let fresh = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: Date())
        let never = CodexCredentials(accessToken: "a", refreshToken: "r", idToken: nil,
                                     accountId: nil, lastRefresh: nil)
        XCTAssertTrue(stale.needsRefresh)
        XCTAssertFalse(fresh.needsRefresh)
        XCTAssertTrue(never.needsRefresh)
    }

    // MARK: - Usage decode + map

    private let usageJSON = """
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"used_percent":42,"reset_at":1750000000,"limit_window_seconds":18000},
      "secondary_window":{"used_percent":8,"reset_at":1750500000,"limit_window_seconds":604800}}}
    """.data(using: .utf8)!

    func testDecodeAndMapWindows() throws {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: usageJSON)
        XCTAssertEqual(usage.planType, "plus")
        let windows = CodexProvider.map(usage)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5 giờ")
        XCTAssertEqual(windows[0].usedPct, 42)
        XCTAssertEqual(windows[0].remainingPct, 58)
        XCTAssertEqual(windows[0].resetDate, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(windows[1].label, "Tuần")
        XCTAssertEqual(windows[1].remainingPct, 92)
    }

    func testDecodeCreditsNumber() throws {
        let json = #"{"plan_type":"plus","credits":{"balance":12.5}}"#.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        XCTAssertEqual(usage.credits?.balance, 12.5)
    }

    func testDecodeCreditsString() throws {
        // Balance may arrive as a string; decode leniently.
        let json = #"{"credits":{"balance":"0"}}"#.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        XCTAssertEqual(usage.credits?.balance, 0)
    }

    func testDecodeNoCredits() throws {
        // Absent credits block stays nil (backward-compatible with old payloads).
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: usageJSON)
        XCTAssertNil(usage.credits)
    }

    // Cost-scanner tests live in CodexCostScannerTests.swift (they import
    // CodexBarCore for CostUsageTokenSnapshot, which would otherwise clash with
    // BirdNion's own Codex types in this file).

    // MARK: - Usage source

    func testUsageSourceDefaultsToAuto() {
        let key = CodexUsageSource.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CodexUsageSource.current, .auto)
    }

    func testSourceCLIUsesCLIDirectly() throws {
        // .cli skips OAuth entirely — the stub session must never be hit.
        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            XCTFail("OAuth must not be called in .cli mode")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)],
            planType: "pro", credits: 3, email: "cli@example.com")
        let p = CodexProvider(session: session, authURL: tempURL(), source: .cli,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.count, 1)
        XCTAssertEqual(status?.sourceLabel, "CLI")
        XCTAssertEqual(status?.accountLabel, "cli@example.com")
        XCTAssertEqual(status?.planType, "Pro 20x")
    }

    func testCLICreditsUnlimitedFlowsThrough() throws {
        let session = URLSession(configuration: makeStubConfig())
        defer { StubURLProtocol.reset() }
        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 0, remainingPct: 100)],
            planType: nil, credits: nil, creditsUnlimited: true, email: nil)
        let p = CodexProvider(session: session, authURL: tempURL(), source: .cli,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.creditsUnlimited, true)
        XCTAssertNil(status?.creditsRemaining)
    }

    func testSourceOAuthDoesNotFallBackToCLI() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        // CLI probe returns data, but .oauth must ignore it and fail hard.
        let cli = CodexCLIUsage(windows: [QuotaWindow(label: "5 giờ", usedPct: 1, remainingPct: 99)],
                                planType: nil, credits: nil, email: nil)
        let p = CodexProvider(session: session, authURL: url, source: .oauth,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.windows.count, 0)
        XCTAssertEqual(status?.error, "HTTP 500")
    }

    // MARK: - CodexCLILaunchGate

    func testLaunchGateThrottlesBackgroundAfterFailure() {
        let gate = CodexCLILaunchGate()
        let bin = "/opt/homebrew/bin/codex"
        let now = Date()
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: now, manual: false))
        gate.recordFailure(binary: bin, now: now)
        XCTAssertTrue(gate.shouldSkipLaunch(binary: bin, now: now, manual: false))
        // A manual refresh always bypasses the throttle.
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: now, manual: true))
        // The throttle clears once the cooldown elapses.
        let later = now.addingTimeInterval(CodexCLILaunchGate.cooldown + 1)
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, now: later, manual: false))
    }

    func testLaunchGateClearResets() {
        let gate = CodexCLILaunchGate()
        let bin = "/usr/local/bin/codex"
        gate.recordFailure(binary: bin)
        XCTAssertTrue(gate.shouldSkipLaunch(binary: bin, manual: false))
        gate.clearFailure(binary: bin)
        XCTAssertFalse(gate.shouldSkipLaunch(binary: bin, manual: false))
    }

    func testRefreshInteractionDefaultsToBackground() {
        XCTAssertFalse(RefreshInteraction.isManual)
    }

    // MARK: - Account reconciliation + snapshot cache

    func testReconcileDedupesByEmail() {
        let system = CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil)
        let managed = [
            CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1"),  // dup of system
            CodexAccount(id: "2", email: "b@x.com", isSystem: false, homePath: "/h2"),  // unique
            CodexAccount(id: "3", email: "B@x.com", isSystem: false, homePath: "/h3"),  // dup of #2 (case-insensitive)
            CodexAccount(id: "4", email: nil, isSystem: false, homePath: "/h4"),        // unknown → kept
        ]
        let result = CodexAccountStore.reconcile(system: system, managed: managed)
        XCTAssertEqual(result.map(\.id), ["system", "2", "4"])
    }

    func testReconcilePrefersSwitchedManagedOverSystemMirror() {
        let system = CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil)
        let managed = [
            CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1"),
            CodexAccount(id: "2", email: "b@x.com", isSystem: false, homePath: "/h2"),
        ]
        // Preferred managed account mirrors the system login → managed row
        // wins, system mirror hidden.
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed, preferManagedID: "1")
                .map(\.id),
            ["1", "2"])
        // No preference → original behavior (system wins, dup hidden).
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed).map(\.id),
            ["system", "2"])
        // Preference only applies when the emails actually mirror each other.
        XCTAssertEqual(
            CodexAccountStore.reconcile(system: system, managed: managed, preferManagedID: "2")
                .map(\.id),
            ["system", "2"])
    }

    func testVisibleAccountsHidesEmptySystemWhenManagedAccountsExist() {
        let system = CodexAccount(id: "system", email: nil, isSystem: true, homePath: nil)
        let managed = [CodexAccount(id: "1", email: "a@x.com", isSystem: false, homePath: "/h1")]
        XCTAssertEqual(CodexAccountStore.visibleAccounts(system: system, managed: managed).map(\.id), ["1"])
    }

    func testFallbackActiveIDAfterRemovingUsesNextVisibleAccount() {
        let accounts = [
            CodexAccount(id: "system", email: "a@x.com", isSystem: true, homePath: nil),
            CodexAccount(id: "1", email: "b@x.com", isSystem: false, homePath: "/h1"),
        ]
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "system", from: accounts), "1")
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "1", from: accounts), "system")
        XCTAssertEqual(CodexAccountStore.fallbackActiveID(afterRemoving: "only", from: []), "system")
    }

    func testSnapshotStoreRoundTrip() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        let status = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 40, remainingPct: 60)],
            lastUpdated: Date(), accountLabel: "a@x.com", sourceLabel: "OAuth")
        store.save(status, forAccount: "acc-1")
        XCTAssertEqual(store.snapshot(forAccount: "acc-1")?.accountLabel, "a@x.com")
        XCTAssertNil(store.snapshot(forAccount: "other"))
        // Persisted: a fresh instance on the same file reloads it.
        let reopened = CodexAccountSnapshotStore(fileURL: tmp)
        XCTAssertEqual(reopened.snapshot(forAccount: "acc-1")?.windows.first?.usedPct, 40)
    }

    func testSnapshotStoreIgnoresErrorAndEmpty() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CodexAccountSnapshotStore(fileURL: tmp)
        store.save(ProviderStatus(id: "codex", displayName: "Codex", windows: [],
                                  lastUpdated: Date(), error: "boom"), forAccount: "e")
        XCTAssertNil(store.snapshot(forAccount: "e"))   // error status ignored
        store.save(ProviderStatus(id: "codex", displayName: "Codex", windows: [],
                                  lastUpdated: Date()), forAccount: "z")
        XCTAssertNil(store.snapshot(forAccount: "z"))   // empty-windows ignored
    }

    func testAccountActiveSelectionRoundTrip() {
        let previous = CodexAccountStore.activeID()
        defer { CodexAccountStore.setActive(previous) }
        CodexAccountStore.setActive("system")
        XCTAssertEqual(CodexAccountStore.activeID(), "system")
        XCTAssertEqual(CodexAccountStore.activeAuthURL(), CodexAccountStore.systemAuthURL())
    }

    func testAccountActiveAuthURLFallsBackToSystem() {
        let previous = CodexAccountStore.activeID()
        defer { CodexAccountStore.setActive(previous) }
        CodexAccountStore.setActive("does-not-exist")
        // Unknown active id → safe fallback to the system login.
        XCTAssertEqual(CodexAccountStore.activeAuthURL(), CodexAccountStore.systemAuthURL())
    }

    func testAllAccountsIncludesSystem() {
        XCTAssertTrue(CodexAccountStore.allAccounts().contains { $0.id == "system" && $0.isSystem })
    }

    // MARK: - CLI switch: pure decisions
    // Round-trip file mutation (switchCLI/restoreSystemCLI/reconcileCLISyncBack)
    // is intentionally NOT exercised here: those functions operate on the
    // real ~/.codex/auth.json with no injectable URL, and an automated test
    // must never overwrite a developer's live Codex CLI login. Verified
    // manually per task-R2-01/R4-01 evidence instead.

    func testShouldSyncBack() {
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: nil, managedModifiedAt: nil))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: nil, managedModifiedAt: Date()))
        let now = Date()
        let earlier = now.addingTimeInterval(-60)
        XCTAssertTrue(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: earlier))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: earlier, managedModifiedAt: now))
        XCTAssertFalse(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: now))
        XCTAssertTrue(CodexAccountStore.shouldSyncBack(cliModifiedAt: now, managedModifiedAt: nil))
    }

    func testNeedsPromoteBeforeOverwrite() {
        XCTAssertTrue(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: nil, managedEmails: []))
        XCTAssertTrue(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: "a@x.com", managedEmails: ["b@x.com"]))
        XCTAssertFalse(CodexAccountStore.needsPromoteBeforeOverwrite(systemEmail: "a@x.com", managedEmails: ["A@X.com"]))
    }

    func testIsAlreadyCLIIdentity() {
        XCTAssertTrue(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "1", trackedID: "1"))
        XCTAssertFalse(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "1", trackedID: "2"))
        XCTAssertTrue(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "system", trackedID: nil))
        XCTAssertFalse(CodexAccountStore.isAlreadyCLIIdentity(selectedID: "system", trackedID: "1"))
    }

    func testSwitchCLINoOpWhenAlreadyIdentity() {
        // Selecting the system account while nothing is tracked (the default
        // state) must be a no-op and must not throw, since isAlreadyCLIIdentity
        // short-circuits before any file I/O.
        let previous = CodexAccountStore.cliSwitchedID()
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: CodexAccountStore.cliSwitchedKey) }
            else { UserDefaults.standard.removeObject(forKey: CodexAccountStore.cliSwitchedKey) }
        }
        UserDefaults.standard.removeObject(forKey: CodexAccountStore.cliSwitchedKey)
        XCTAssertNoThrow(try CodexAccountStore.switchCLI(to: "system"))
        XCTAssertNil(CodexAccountStore.cliSwitchedID())
    }

    func testCodexBinaryCandidatesPreferIntelHomebrewOnIntelArchitecture() {
        let paths = CodexAccountStore.orderedCodexBinaryCandidates(
            home: "/Users/tester", architecture: "x86_64")
        XCTAssertLessThan(paths.firstIndex(of: "/usr/local/bin/codex")!,
                          paths.firstIndex(of: "/opt/homebrew/bin/codex")!)
    }

    func testCodexBinaryCandidatesPreferAppleSiliconHomebrewOnArmArchitecture() {
        let paths = CodexAccountStore.orderedCodexBinaryCandidates(
            home: "/Users/tester", architecture: "arm64")
        XCTAssertLessThan(paths.firstIndex(of: "/opt/homebrew/bin/codex")!,
                          paths.firstIndex(of: "/usr/local/bin/codex")!)
    }

    func testLoginSearchPathAddsBinaryDirectoryAndCommonToolDirs() {
        let path = CodexAccountStore.loginSearchPath(
            binaryPath: "/custom/bin/codex",
            inheritedPath: "/usr/bin:/bin",
            home: "/Users/tester")
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/custom/bin")
        XCTAssertTrue(parts.contains("/usr/local/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertTrue(parts.contains("/Users/tester/.local/bin"))
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testFirstAbsolutePathFromShellOutput() {
        XCTAssertEqual(CodexAccountStore.firstAbsolutePath(from: "codex not found\n/usr/local/bin/codex\n"),
                       "/usr/local/bin/codex")
        XCTAssertNil(CodexAccountStore.firstAbsolutePath(from: "codex: aliased to codex\n"))
    }

    // MARK: - CodexQuotaPrimer.shouldPrime (pure decision, R2)

    private func makeDate(hour: Int, minute: Int, day: Int = 9) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testShouldPrimeOnTimeAndIdle() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertTrue(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseWhenWindowActive() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: 1, enabled: true))
    }

    func testShouldPrimeFalseWhenAlreadyPrimedToday() {
        let now = makeDate(hour: 9, minute: 0)
        let lastRunToday = makeDate(hour: 8, minute: 55).timeIntervalSince1970
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: lastRunToday, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseBeforeScheduledTime() {
        let now = makeDate(hour: 8, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeCatchUpPastScheduledNotYetPrimed() {
        // Missed the exact scheduled minute (e.g. machine was asleep) — the
        // first awake tick after the scheduled time still primes once.
        let now = makeDate(hour: 14, minute: 30)
        let lastRunYesterday = makeDate(hour: 9, minute: 0, day: 8).timeIntervalSince1970
        XCTAssertTrue(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: lastRunYesterday, scheduledMinutes: 535, windowUsedPct: nil, enabled: true))
    }

    func testShouldPrimeFalseWhenDisabled() {
        let now = makeDate(hour: 9, minute: 0)
        XCTAssertFalse(CodexQuotaPrimer.shouldPrime(
            now: now, lastRun: 0, scheduledMinutes: 535, windowUsedPct: nil, enabled: false))
    }

    func testMenuBarMetricFilter() {
        let session = QuotaWindow(label: "5 giờ", usedPct: 1, remainingPct: 99)
        let weekly = QuotaWindow(label: "Tuần", usedPct: 7, remainingPct: 93)
        let all = [session, weekly]
        XCTAssertEqual(CodexMenuBarMetric.automatic.filter(all).count, 2)
        XCTAssertEqual(CodexMenuBarMetric.session.filter(all).map(\.label), ["5 giờ"])
        XCTAssertEqual(CodexMenuBarMetric.weekly.filter(all).map(\.label), ["Tuần"])
        // Fallback: chosen window absent → keep all rather than show nothing.
        XCTAssertEqual(CodexMenuBarMetric.weekly.filter([session]).map(\.label), ["5 giờ"])
    }

    // MARK: - fetch()

    func testFetchHappyPath() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            // Two endpoints are called concurrently: usage + reset credits.
            // Route by URL; the URL assertion is split so a routing mistake fails fast.
            let url = req.url?.absoluteString ?? ""
            if url.hasSuffix("/wham/usage") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.usageJSON)
            }
            if url.hasSuffix("/wham/rate-limit-reset-credits") {
                let body = #"{"credits":[],"available_count":0}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            XCTFail("unexpected URL: \(url)")
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil })
        let status = try await p.fetch()
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.count, 2)
        XCTAssertEqual(status.windows[0].label, "5 giờ")
        XCTAssertEqual(status.sourceLabel, "OAuth")
    }

    func testFetchUnauthorizedNoRefreshToken() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":""},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        // Inject an empty CLI probe so the test never spawns `codex app-server`.
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { nil })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.windows.count, 0)
        XCTAssertEqual(status?.error, "Token Codex hết hạn — chạy `codex` để đăng nhập lại")
    }

    // MARK: - CLI RPC fallback (codex app-server)

    func testFetchFallsBackToCLIOnServerError() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let auth = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            // OAuth usage is down (500) → provider must fall back to the CLI probe.
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "5 giờ", usedPct: 30, remainingPct: 70)],
            planType: "pro", credits: 5, email: "rpc@example.com")
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let status = try await p.fetch()
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.count, 1)
        XCTAssertEqual(status.windows.first?.label, "5 giờ")
        XCTAssertEqual(status.planType, "Pro 20x")   // CodexPlanFormatting applied
        XCTAssertEqual(status.creditsRemaining, 5)
        XCTAssertEqual(status.accountLabel, "rpc@example.com")
    }

    func testFetchUnauthorizedFallsBackToCLI() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        // Empty refresh token → no reactive refresh; goes straight to CLI fallback.
        let auth = #"{"tokens":{"access_token":"at","refresh_token":""},"last_refresh":"\#(nowISO)"}"#
        try auth.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }

        let cli = CodexCLIUsage(
            windows: [QuotaWindow(label: "Tuần", usedPct: 10, remainingPct: 90)],
            planType: nil, credits: nil, email: nil)
        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil },
                              cliUsageProbe: { cli })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.map(\.label), ["Tuần"])
    }

    func testFetchNotLoggedIn() throws {
        let session = URLSession(configuration: makeStubConfig())
        defer { StubURLProtocol.reset() }
        let p = CodexProvider(session: session, authURL: tempURL())
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.error, "Chưa đăng nhập Codex — chạy `codex` để đăng nhập")
    }

    // MARK: - CodexStatusProbe parser (CLI fallback)

    func testStatusProbeParseCleanText() throws {
        // CodexBar only supports `HH:mm` and `on <date> <time>` for reset
        // date parsing — not relative phrases like "in 3h 12m" or bare
        // "<date> <time>" without the "on" prefix.
        let text = """
        Credits: 42
        5h limit    78% left   resets 14:30
        Weekly limit 91% left  resets on 2 Jul 14:30
        """
        let snap = try CodexStatusProbe.parse(text: text)
        XCTAssertEqual(snap.credits, 42)
        XCTAssertEqual(snap.fiveHourPercentLeft, 78)
        XCTAssertEqual(snap.weeklyPercentLeft, 91)
        XCTAssertNotNil(snap.fiveHourResetsAt)
        XCTAssertNotNil(snap.weeklyResetsAt)
    }

    func testStatusProbeParseStripsAnsi() throws {
        let text = "\u{001B}[32mCredits: 10\u{001B}[0m\n5h limit 50% left resets 12:34"
        let snap = try CodexStatusProbe.parse(text: text)
        XCTAssertEqual(snap.credits, 10)
        XCTAssertEqual(snap.fiveHourPercentLeft, 50)
    }

    func testStatusProbeParseMissingFieldsThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: "hello world"))
    }

    func testStatusProbeParseEmptyThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: ""))
    }

    func testStatusProbeParseDataNotAvailableThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: "data not available yet\n"))
    }

    // MARK: - CodexResetCreditsAPI decode

    func testResetCreditsDecode() throws {
        let now = Date()
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let granted = f1.string(from: now)
        let json = #"""
        {"credits":[{"id":"abc","reset_type":"weekly","status":"available",
        "granted_at":"\#(granted)","expires_at":"\#(granted)","title":"Manual reset"}],
        "available_count":1}
        """#.data(using: .utf8)!
        let snap = try CodexResetCreditsAPI.decode(json, now: now)
        XCTAssertEqual(snap.availableCount, 1)
        XCTAssertEqual(snap.credits.count, 1)
        XCTAssertEqual(snap.credits[0].id, "abc")
        XCTAssertEqual(snap.credits[0].status, "available")
        XCTAssertEqual(snap.credits[0].title, "Manual reset")
    }

    func testResetCreditsDecodeMissingFields() throws {
        // No `available_count` key still decodes; absent credits array works too.
        let json = #"{"credits":[],"available_count":0}"#.data(using: .utf8)!
        let snap = try CodexResetCreditsAPI.decode(json, now: Date())
        XCTAssertEqual(snap.availableCount, 0)
        XCTAssertEqual(snap.credits.count, 0)
    }

    func testResetCreditsDecodeNegativeCountThrows() {
        let json = #"{"credits":[],"available_count":-1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexResetCreditsAPI.decode(json, now: Date()))
    }
}
