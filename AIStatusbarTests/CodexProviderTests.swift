import XCTest
@testable import AIStatusbar

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

    func testCostScannerSessionDate() {
        let d = CodexCostScanner.sessionDate(from: "rollout-2026-06-23T15-57-40-019ef3b3.jsonl")
        XCTAssertNotNil(d)
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour], from: d!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 6)
        XCTAssertEqual(c.day, 23)
    }

    func testCostScannerAggregatesLastCumulativeUsage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codexcost-\(UUID().uuidString)")
        let sub = tmp.appendingPathComponent("2026/06")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let stamp = fmt.string(from: now)
        let file = sub.appendingPathComponent("rollout-\(stamp)-abc.jsonl")
        let lines = [
            #"{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}"#,
            #"{"type":"turn_context","model":"gpt-5.5"}"#,
            // Later cumulative line wins (running total).
            #"{"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"total_tokens":1050}}}}"#,
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)

        let summary = CodexCostScanner.scan(sessionsDir: tmp, now: now)
        XCTAssertEqual(summary?.last30Tokens, 1050)  // input 1000 + output 50
        XCTAssertEqual(summary?.todayTokens, 1050)
        XCTAssertGreaterThan(summary?.last30USD ?? 0, 0)
    }

    func testCostScannerSkipsOldSessions() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codexcost-\(UUID().uuidString)")
        let sub = tmp.appendingPathComponent("2025/01")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = sub.appendingPathComponent("rollout-2025-01-01T10-00-00-old.jsonl")
        try #"{"payload":{"info":{"total_token_usage":{"input_tokens":999,"output_tokens":1}}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let summary = CodexCostScanner.scan(sessionsDir: tmp, now: Date())
        XCTAssertEqual(summary?.last30Tokens, 0)  // older than 30 days → excluded
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

    func testFetchHappyPath() throws {
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
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.count, 2)
        XCTAssertEqual(status?.windows[0].label, "5 giờ")
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

        let p = CodexProvider(session: session, authURL: url,
                              statusProbe: { nil }, versionProbe: { nil })
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.windows.count, 0)
        XCTAssertEqual(status?.error, "Token Codex hết hạn — chạy `codex` để đăng nhập lại")
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
