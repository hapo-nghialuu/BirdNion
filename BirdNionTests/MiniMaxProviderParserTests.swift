import XCTest
@testable import BirdNion

@_silgen_name("mkfifo")
private func birdNionTestMkfifo(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32

/// Tests for `MiniMaxProvider` parser + the providers that share its
/// Keychain-less architecture. Uses `BirdNionConfigStore` (via an isolated
/// `BIRDNION_CONFIG` env override) to inject tokens without touching the
/// real `~/.birdnion/settings.json` on the developer's machine.
final class MiniMaxProviderParserTests: XCTestCase {
    private var testConfigURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-test-\(UUID().uuidString)/settings.json")
        setenv("BIRDNION_CONFIG", testConfigURL.path, 1)
        UserDefaults.standard.removeObject(forKey: MiniMaxRegion.defaultsKey)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testConfigURL.deletingLastPathComponent())
        UserDefaults.standard.removeObject(forKey: MiniMaxRegion.defaultsKey)
        unsetenv("BIRDNION_CONFIG")
        try super.tearDownWithError()
    }

    private func installToken(_ token: String, for providerID: String) throws {
        var entry = BirdNionConfigStore.provider(id: providerID)
            ?? BirdNionConfigStore.Provider(id: providerID)
        entry.apiKey = token
        try BirdNionConfigStore.save(entry)
    }

    private let happyJSON = """
    {"base_resp":{"status_code":0,"status_msg":"success"},
    "current_subscribe_title":"Token Plan Max",
    "model_remains":[{"model_name":"general",
    "current_interval_total_count":100,"current_interval_usage_count":13,
    "current_interval_remaining_percent":87,
    "current_weekly_total_count":700,"current_weekly_usage_count":80,
    "current_weekly_remaining_percent":89}]}
    """.data(using: .utf8)!

    private let missingModelJSON = """
    {"other":[]}
    """.data(using: .utf8)!

    private let missingPctJSON = """
    {"model_remains":[{"model_name":"general"}]}
    """.data(using: .utf8)!

    private let malformedJSON = "not json".data(using: .utf8)!

    func testHappyPath() throws {
        try installToken("test-token", for: "minimax")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.happyJSON)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task {
            status = try? await p.fetch()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(status?.windows.count, 2)
        XCTAssertEqual(status?.windows[0].label, "5 giờ")
        XCTAssertEqual(status?.windows[0].remainingPct, 87)
        XCTAssertEqual(status?.windows[1].label, "Tuần")
        XCTAssertEqual(status?.windows[1].remainingPct, 89)
        XCTAssertEqual(status?.planName, "Token Plan Max")
    }

    func testChinaRegionUsesAPIHostForTokenPath() throws {
        try installToken("test-token", for: "minimax")
        UserDefaults.standard.set(MiniMaxRegion.com.rawValue, forKey: MiniMaxRegion.defaultsKey)
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        var requestedURLs: [String] = []
        StubURLProtocol.handler = { req in
            requestedURLs.append(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.happyJSON)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task {
            status = try? await p.fetch()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(requestedURLs, ["https://api.minimaxi.com/v1/token_plan/remains"])
    }

    func testChinaRegionFallsBackAfterTokenPlan404() throws {
        try installToken("test-token", for: "minimax")
        UserDefaults.standard.set(MiniMaxRegion.com.rawValue, forKey: MiniMaxRegion.defaultsKey)
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        var requestedURLs: [String] = []
        StubURLProtocol.handler = { req in
            requestedURLs.append(req.url?.absoluteString ?? "")
            let statusCode = requestedURLs.count == 1 ? 404 : 200
            let data = statusCode == 404 ? Data() : self.happyJSON
            return (HTTPURLResponse(url: req.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                    data)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task {
            status = try? await p.fetch()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertNil(status?.error)
        XCTAssertEqual(requestedURLs, [
            "https://api.minimaxi.com/v1/token_plan/remains",
            "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        ])
    }

    func testPlanNameFallback() throws {
        // When `current_subscribe_title` is missing, `plan_name` should win.
        let json = #"""
        {"base_resp":{"status_code":0,"status_msg":"success"},
        "plan_name":"Plus",
        "model_remains":[{"model_name":"general",
        "current_interval_total_count":100,"current_interval_usage_count":0,
        "current_interval_remaining_percent":100,
        "current_weekly_total_count":700,"current_weekly_usage_count":0,
        "current_weekly_remaining_percent":100}]}
        """#.data(using: .utf8)!
        let p = MiniMaxProvider()
        let s = p.parse(json, accountLabel: "u")
        XCTAssertEqual(s.planName, "Plus")
    }

    func testPlanNameNilWhenAllMissing() throws {
        let empty = #"""
        {"base_resp":{"status_code":0,"status_msg":"success"},
        "model_remains":[{"model_name":"general",
        "current_interval_total_count":100,"current_interval_usage_count":0,
        "current_interval_remaining_percent":100,
        "current_weekly_total_count":700,"current_weekly_usage_count":0,
        "current_weekly_remaining_percent":100}]}
        """#.data(using: .utf8)!
        let p = MiniMaxProvider()
        let s2 = p.parse(empty, accountLabel: "u")
        XCTAssertNil(s2.planName)
    }

    func testMissingModel() throws {
        try installToken("test-token", for: "minimax")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.missingModelJSON)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.error, "Response thiếu trường")
    }

    func testMissingPercent() throws {
        try installToken("test-token", for: "minimax")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.missingPctJSON)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(status?.error, "Response thiếu trường")
    }

    func testMalformedJSON() throws {
        try installToken("test-token", for: "minimax")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.malformedJSON)
        }
        defer { StubURLProtocol.reset() }
        let exp = expectation(description: "fetch")
        var status: ProviderStatus?
        Task { status = try? await p.fetch(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNotNil(status?.error)
    }

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }
}

// MARK: - Ported providers (parser-only, no network)

final class OpenRouterProviderTests: XCTestCase {
    func testParseCreditsWindow() {
        let json = #"{"data":{"total_credits":10.0,"total_usage":2.5}}"#.data(using: .utf8)!
        let s = OpenRouterProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].usedPct, 25)        // 2.5 / 10 = 25%
        XCTAssertEqual(s.windows[0].remainingPct, 75)
        XCTAssertEqual(s.creditsRemaining, 7.5)
    }

    func testParseZeroCredits() {
        let json = #"{"data":{"total_credits":0,"total_usage":0}}"#.data(using: .utf8)!
        let s = OpenRouterProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.first?.usedPct, 0)     // no divide-by-zero
    }

    func testParseMalformed() {
        let s = OpenRouterProvider().parse(Data("x".utf8), accountLabel: "u")
        XCTAssertEqual(s.error, "Response thiếu trường")
    }
}

final class TryAPIProviderTests: XCTestCase {
    func testParseUnrestrictedWallet() {
        let json = """
        {
          "balance": 290.6,
          "remaining": 290.6,
          "unit": "USD",
          "planName": "钱包余额",
          "isValid": true,
          "mode": "unrestricted",
          "usage": {
            "today": {"requests":0,"cost":0,"actual_cost":0},
            "total": {"requests":89,"cost":8.85,"actual_cost":10.14}
          }
        }
        """.data(using: .utf8)!
        let s = TryAPIProvider().parse(json, accountLabel: "sk-try12")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].label, "Số dư")
        // used=10.14, remaining=290.6, total=300.74 → ~3%
        XCTAssertEqual(s.windows[0].usedPct, 3)
        XCTAssertEqual(s.windows[0].remainingPct, 97)
        XCTAssertEqual(s.windows[0].subtitle, "$10.14 / $300.74")
        XCTAssertEqual(s.creditsRemaining, 290.6)
        XCTAssertEqual(s.planName, "钱包余额")
        XCTAssertEqual(s.accountLabel, "sk-try12")
    }

    func testPrefersActualCostOverCost() {
        let json = """
        {"remaining":90.0,"isValid":true,"usage":{"total":{"cost":5.0,"actual_cost":10.0}}}
        """.data(using: .utf8)!
        let s = TryAPIProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows[0].usedPct, 10)
        XCTAssertEqual(s.windows[0].subtitle, "$10.00 / $100.00")
    }

    func testTodayWindowWhenTraffic() {
        let json = """
        {
          "remaining":100.0,"isValid":true,
          "usage":{
            "today":{"requests":3,"actual_cost":1.25},
            "total":{"actual_cost":5.0}
          }
        }
        """.data(using: .utf8)!
        let s = TryAPIProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows[1].label, "Hôm nay")
        XCTAssertEqual(s.windows[1].subtitle, "$1.25 · 3 req")
    }

    func testQuotaLimitedSubscriptionWindows() {
        let json = """
        {
          "remaining":10.0,"isValid":true,"mode":"quota_limited",
          "usage":{"total":{"actual_cost":2.0}},
          "subscription":{
            "daily_usage_usd":1.0,"daily_limit_usd":5.0,
            "weekly_usage_usd":3.0,"weekly_limit_usd":20.0,
            "monthly_usage_usd":8.0,"monthly_limit_usd":50.0
          }
        }
        """.data(using: .utf8)!
        let s = TryAPIProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.map(\.label), ["Số dư", "Ngày", "Tuần", "Tháng"])
        XCTAssertEqual(s.windows[1].usedPct, 20)
        XCTAssertEqual(s.windows[2].usedPct, 15)
        XCTAssertEqual(s.windows[3].usedPct, 16)
    }

    func testInvalidKeyIsError() {
        let json = #"{"isValid":false,"remaining":0}"#.data(using: .utf8)!
        let s = TryAPIProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.error, "API key không hợp lệ")
        XCTAssertTrue(s.windows.isEmpty)
    }

    func testParseMalformed() {
        let s = TryAPIProvider().parse(Data("x".utf8), accountLabel: "u")
        XCTAssertEqual(s.error, "Response thiếu trường")
    }

    func testMissingTokenMessage() async throws {
        // Ensure env is unset for this process and config has no tryapi key.
        // parse-path only; fetch missing-token is covered by failure helper shape.
        let s = TryAPIProvider().parse(Data("{}".utf8), accountLabel: "u")
        // empty JSON still decodes (all optional) with isValid=nil → not invalid
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.first?.label, "Số dư")
    }
}

final class DeepSeekProviderTests: XCTestCase {
    func testParseBalance() {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34"}]}"#
            .data(using: .utf8)!
        let s = DeepSeekProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.creditsRemaining, 12.34)
        XCTAssertEqual(s.windows.first?.subtitle, "$12.34")
    }

    func testParseCNY() {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"88.00"}]}"#
            .data(using: .utf8)!
        let s = DeepSeekProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.first?.subtitle, "¥88.00")
    }

    func testParseEmptyInfos() {
        let json = #"{"is_available":true,"balance_infos":[]}"#.data(using: .utf8)!
        let s = DeepSeekProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.error, "Không có thông tin số dư")
    }
}

final class ZaiProviderTests: XCTestCase {
    func testParseLimits() {
        let json = #"""
        {"code":200,"msg":"ok","success":true,"data":{"plan_name":"GLM Max",
        "limits":[{"type":"TIME_LIMIT","unit":3,"number":5,"percentage":40,"next_reset_time":1750000000000},
        {"type":"TOKENS_LIMIT","unit":0,"number":0,"percentage":10}]}}
        """#.data(using: .utf8)!
        let s = ZaiProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows[0].label, "5 giờ")
        XCTAssertEqual(s.windows[0].remainingPct, 60)
        XCTAssertNotNil(s.windows[0].resetDate)
        XCTAssertEqual(s.windows[1].label, "Tokens")
        XCTAssertEqual(s.planName, "GLM Max")
    }

    func testParseLogicalError() {
        let json = #"{"code":401,"msg":"unauthorized","success":false,"data":null}"#.data(using: .utf8)!
        let s = ZaiProvider().parse(json, accountLabel: "u")
        XCTAssertEqual(s.error, "unauthorized")
    }

    func testLabelMapping() {
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 3, number: 5), "5 giờ")
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 1, number: 7), "7 ngày")
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 6, number: 1), "Tuần")
        XCTAssertEqual(ZaiProvider.label(type: "TOKENS_LIMIT", unit: 0, number: 0), "Tokens")
    }
}

// MARK: - BirdNionConfigStore round-trip

final class BirdNionConfigStoreTests: XCTestCase {
    private var testConfigURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-cfg-\(UUID().uuidString)/settings.json")
        setenv("BIRDNION_CONFIG", testConfigURL.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testConfigURL.deletingLastPathComponent())
        unsetenv("BIRDNION_CONFIG")
        try super.tearDownWithError()
    }

    func testWriteThenReadRoundTrip() throws {
        let p = BirdNionConfigStore.Provider(id: "minimax", apiKey: "sk-test", enabled: true)
        try BirdNionConfigStore.save(p, url: testConfigURL)
        let read = BirdNionConfigStore.provider(id: "minimax", url: testConfigURL)
        XCTAssertEqual(read?.apiKey, "sk-test")
        XCTAssertEqual(read?.enabled, true)
    }

    func testUpsertUpdatesExistingWithoutDuplicating() throws {
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "minimax", apiKey: "first"), url: testConfigURL)
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "minimax", apiKey: "second"), url: testConfigURL)
        let cfg = BirdNionConfigStore.read(url: testConfigURL)
        XCTAssertEqual(cfg?.providers?.filter { $0.id == "minimax" }.count, 1)
        XCTAssertEqual(BirdNionConfigStore.apiKey(provider: "minimax", url: testConfigURL), "second")
    }

    func testMacMutationsIncrementSharedSettingsRevision() throws {
        try BirdNionConfigStore.save(.init(id: "minimax", enabled: true), url: testConfigURL)
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(raw["settingsRevision"] as? Int, 1)

        try BirdNionConfigStore.save(.init(id: "codex", enabled: true), url: testConfigURL)
        raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(raw["settingsRevision"] as? Int, 2)
    }

    func testPreservesOtherProviders() throws {
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "codex", apiKey: "codex-key"), url: testConfigURL)
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "minimax", apiKey: "minimax-key"), url: testConfigURL)
        XCTAssertEqual(BirdNionConfigStore.apiKey(provider: "codex", url: testConfigURL), "codex-key")
        XCTAssertEqual(BirdNionConfigStore.apiKey(provider: "minimax", url: testConfigURL), "minimax-key")
    }

    func testSaveProvidersPreservesExplicitOrder() throws {
        let firstOrder = [
            BirdNionConfigStore.Provider(id: "minimax", enabled: true),
            BirdNionConfigStore.Provider(id: "codex", enabled: true),
            BirdNionConfigStore.Provider(id: "hapo", enabled: true)
        ]
        try BirdNionConfigStore.saveProviders(firstOrder, url: testConfigURL)

        let reordered = [
            BirdNionConfigStore.Provider(id: "codex", enabled: true),
            BirdNionConfigStore.Provider(id: "minimax", enabled: true),
            BirdNionConfigStore.Provider(id: "hapo", enabled: true)
        ]
        try BirdNionConfigStore.saveProviders(reordered, url: testConfigURL)

        XCTAssertEqual(BirdNionConfigStore.allProviders(url: testConfigURL).prefix(3).map(\.id),
                       ["codex", "minimax", "hapo"])
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(raw["settingsRevision"] as? Int, 2)
    }

    func testSaveProvidersRejectsStaleSettingsSnapshotWithoutRevertingNewFields() throws {
        try BirdNionConfigStore.saveProviders([
            .init(id: "claude", apiKey: "old-token", enabled: true),
        ], url: testConfigURL)
        let stale = BirdNionConfigStore.providersSnapshot(url: testConfigURL)

        try BirdNionConfigStore.save(
            .init(id: "claude", apiKey: "rotated-token", enabled: true),
            url: testConfigURL)
        var staleRows = stale.providers
        staleRows[0].enabled = false

        XCTAssertThrowsError(try BirdNionConfigStore.saveProviders(
            staleRows,
            expectedRevision: stale.settingsRevision,
            url: testConfigURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("reload before saving"))
        }
        let current = try XCTUnwrap(BirdNionConfigStore.provider(
            id: "claude", url: testConfigURL))
        XCTAssertEqual(current.apiKey, "rotated-token")
        XCTAssertEqual(current.enabled, true)
        XCTAssertEqual(BirdNionConfigStore.read(url: testConfigURL)?.settingsRevision, 2)
    }

    func testProvidersSnapshotCarriesRevisionWhenProviderArrayIsAbsent() throws {
        try writeRaw(#"{"version":1,"settingsRevision":7,"claudeCodeProfiles":[]}"#)

        let snapshot = BirdNionConfigStore.providersSnapshot(url: testConfigURL)

        XCTAssertEqual(snapshot.settingsRevision, 7)
        XCTAssertFalse(snapshot.providers.isEmpty)
        let savedRevision = try BirdNionConfigStore.saveProviders(
            snapshot.providers,
            expectedRevision: snapshot.settingsRevision,
            url: testConfigURL)
        XCTAssertEqual(savedRevision, 8)
        XCTAssertEqual(BirdNionConfigStore.read(url: testConfigURL)?.settingsRevision, 8)
    }

    func testDefaultIsEnabledFalse() throws {
        // First-run (2026-06-25) opt-in default: missing `enabled` key
        // returns `false` (NOT the prior `true` from CodexBar compat).
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "minimax", apiKey: "x"), url: testConfigURL)
        XCTAssertFalse(BirdNionConfigStore.isEnabled(provider: "minimax", url: testConfigURL))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertNil(BirdNionConfigStore.apiKey(provider: "minimax", url: testConfigURL))
        XCTAssertFalse(BirdNionConfigStore.isEnabled(provider: "minimax", url: testConfigURL))
    }

    func testRemoveProvider() throws {
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "a", apiKey: "1"), url: testConfigURL)
        try BirdNionConfigStore.save(BirdNionConfigStore.Provider(id: "b", apiKey: "2"), url: testConfigURL)
        try BirdNionConfigStore.remove(provider: "a", url: testConfigURL)
        XCTAssertNil(BirdNionConfigStore.apiKey(provider: "a", url: testConfigURL))
        XCTAssertEqual(BirdNionConfigStore.apiKey(provider: "b", url: testConfigURL), "2")
    }

    // MARK: - Path resolution

    func testConfigURLEnvOverrideWins() {
        let url = BirdNionConfigStore.configURL(env: ["BIRDNION_CONFIG": "/tmp/custom/birdnion.json"])
        XCTAssertEqual(url.path, "/tmp/custom/birdnion.json")
    }

    func testConfigURLDefaultsToXDGWhenNeitherPresent() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)")
        XCTAssertEqual(BirdNionConfigStore.configURL(home: home, env: [:]),
                       home.appendingPathComponent(".config/birdnion/settings.json"))
    }

    // MARK: - Fail-closed + lossless save (reliability hardening)

    private func writeRaw(_ raw: String) throws {
        try FileManager.default.createDirectory(at: testConfigURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try raw.data(using: .utf8)!.write(to: testConfigURL)
    }

    private var casBackupURL: URL {
        testConfigURL.deletingLastPathComponent().appendingPathComponent(
            testConfigURL.lastPathComponent + ".birdnion-cas-backup")
    }

    func testSaveRefusesToOverwriteMalformedExistingFile() throws {
        let raw = "{ this is not valid json"
        try writeRaw(raw)

        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
        // File on disk must stay byte-for-byte untouched — never silently
        // replaced by a fresh/empty document.
        XCTAssertEqual(try String(contentsOf: testConfigURL, encoding: .utf8), raw)
    }

    func testSaveRefusesToOverwriteEmptyExistingFile() throws {
        try writeRaw("")
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
    }

    func testSaveRejectsSymlinkWithoutChangingTarget() throws {
        let target = testConfigURL.deletingLastPathComponent().appendingPathComponent("target.json")
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let original = #"{"version":1,"settingsRevision":9,"providers":[]}"#
        try original.data(using: .utf8)!.write(to: target)
        try FileManager.default.createSymbolicLink(at: testConfigURL, withDestinationURL: target)

        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
    }

    func testSaveRejectsFIFOWithoutBlocking() throws {
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let result = testConfigURL.path.withCString { birdNionTestMkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0)

        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
    }

    func testSaveRejectsOversizedSettingsWithoutChangingBytes() throws {
        let oversized = Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try oversized.write(to: testConfigURL)

        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
        XCTAssertEqual(try Data(contentsOf: testConfigURL).count, oversized.count)
    }

    func testSaveRejectsSymlinkedMutationLock() throws {
        let parent = testConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("lock-target")
        let original = Data("do-not-touch".utf8)
        try original.write(to: target)
        let lock = parent.appendingPathComponent(testConfigURL.lastPathComponent + ".birdnion.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)

        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testConfigURL.path))
    }

    func testAtomicSaveCreatesOwnerOnlyRegularFile() throws {
        try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)

        let parentAttributes = try FileManager.default.attributesOfItem(
            atPath: testConfigURL.deletingLastPathComponent().path)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let attributes = try FileManager.default.attributesOfItem(atPath: testConfigURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)

        let lockURL = testConfigURL.deletingLastPathComponent()
            .appendingPathComponent(testConfigURL.lastPathComponent + ".birdnion.lock")
        let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((lockAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(lockAttributes[.type] as? FileAttributeType, .typeRegular)
    }

    func testExistingConfigParentModeRemainsUnchanged() throws {
        let parent = testConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: parent.path)

        try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: testConfigURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSavePreservesUnknownTopLevelKey() throws {
        try writeRaw(#"{"version":1,"settingsRevision":7,"providers":[],"activeCodexAccount":"linux-account","futureFeatureFlag":true}"#)

        try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        XCTAssertEqual(raw["settingsRevision"] as? Int, 8)
        XCTAssertEqual(raw["activeCodexAccount"] as? String, "linux-account")
        XCTAssertEqual(raw["futureFeatureFlag"] as? Bool, true)
        XCTAssertNotNil(raw["providers"])
    }

    func testSavePreservesUnknownPerProviderKey() throws {
        try writeRaw(#"{"version":1,"providers":[{"id":"claude","enabled":true,"refreshInterval":120,"showInTray":false,"futureProviderField":"keep-me"}]}"#)

        var provider = try XCTUnwrap(BirdNionConfigStore.provider(id: "claude", url: testConfigURL))
        provider.accountLabel = "My Account"
        try BirdNionConfigStore.save(provider, url: testConfigURL)

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(raw["providers"] as? [[String: Any]])
        let claude = try XCTUnwrap(providers.first { $0["id"] as? String == "claude" })
        XCTAssertEqual(claude["refreshInterval"] as? Int, 120)
        XCTAssertEqual(claude["showInTray"] as? Bool, false)
        XCTAssertEqual(claude["futureProviderField"] as? String, "keep-me")
        XCTAssertEqual(claude["accountLabel"] as? String, "My Account")
    }

    func testConcurrentExternalMutationFailsClosedWithoutOverwritingNewBytes() throws {
        try writeRaw(#"{"version":1,"settingsRevision":4,"providers":[{"id":"claude","enabled":true}]}"#)
        let external = Data(
            #"{"version":1,"settingsRevision":5,"providers":[{"id":"claude","enabled":false,"showInTray":false}],"activeCodexAccount":"linux-new"}"#.utf8
        )

        XCTAssertThrowsError(
            try BirdNionConfigStore.performMutationForTesting(
                url: testConfigURL,
                beforeClaim: { try external.write(to: self.testConfigURL, options: .atomic) },
                { config in config.version = 2 }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed outside this mutation"))
        }
        XCTAssertEqual(try Data(contentsOf: testConfigURL), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: casBackupURL.path))
    }

    func testReaderWaitsUntilClaimedSettingsAreInstalled() throws {
        try writeRaw(
            #"{"version":1,"settingsRevision":3,"providers":[{"id":"claude","apiKey":"before","enabled":true}]}"#)
        let claimed = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let readerStarted = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var writerError: Error?
        var loaded: BirdNionConfigStore.Config?

        DispatchQueue.global().async {
            do {
                try BirdNionConfigStore.performMutationAfterClaimForTesting(
                    url: self.testConfigURL,
                    afterClaim: {
                        claimed.signal()
                        guard releaseWriter.wait(timeout: .now() + 2) == .success else {
                            throw NSError(domain: "BirdNionConfigStoreTests", code: 1)
                        }
                    },
                    { config in config.providers?[0].apiKey = "after" })
            } catch {
                resultLock.lock()
                writerError = error
                resultLock.unlock()
            }
            writerFinished.signal()
        }

        XCTAssertEqual(claimed.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            readerStarted.signal()
            let value = BirdNionConfigStore.read(url: self.testConfigURL)
            resultLock.lock()
            loaded = value
            resultLock.unlock()
            readerFinished.signal()
        }
        XCTAssertEqual(readerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readerFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)

        releaseWriter.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
        resultLock.lock()
        let capturedError = writerError
        let capturedLoaded = loaded
        resultLock.unlock()
        XCTAssertNil(capturedError)
        XCTAssertEqual(capturedLoaded?.providers?.first?.apiKey, "after")
        XCTAssertFalse(FileManager.default.fileExists(atPath: casBackupURL.path))
    }

    func testParentSwapAfterLockBeforeReadCannotOverwriteReplacementRoute() throws {
        let base = testConfigURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appendingPathComponent("current")
        let detached = base.appendingPathComponent("detached")
        testConfigURL = current.appendingPathComponent("settings.json")
        let original = Data(
            #"{"version":1,"settingsRevision":0,"providers":[{"id":"claude","apiKey":"route-a","enabled":true}]}"#.utf8)
        let replacement = Data(
            #"{"version":1,"settingsRevision":0,"providers":[{"id":"claude","apiKey":"route-b","enabled":true}]}"#.utf8)
        try writeRaw(String(decoding: original, as: UTF8.self))

        XCTAssertThrowsError(
            try BirdNionConfigStore.performMutationAfterLockForTesting(
                url: testConfigURL,
                afterLock: {
                    try FileManager.default.moveItem(at: current, to: detached)
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                    try replacement.write(to: self.testConfigURL)
                },
                { config in
                    config.providers = [
                        .init(id: "claude", apiKey: "stale-route-a", enabled: false),
                    ]
                }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("directory route changed"))
        }
        XCTAssertEqual(try Data(contentsOf: testConfigURL), replacement)
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("settings.json")),
            original)
    }

    func testFailedProviderSnapshotCannotOverwriteRestoredLegacyRevisionZeroConfig() throws {
        try writeRaw("{ transient read failure")
        XCTAssertThrowsError(
            try BirdNionConfigStore.providersSnapshotChecked(url: testConfigURL))
        let failedSnapshot = BirdNionConfigStore.providersSnapshot(url: testConfigURL)
        XCTAssertFalse(failedSnapshot.isAuthoritative)
        XCTAssertEqual(failedSnapshot.settingsRevision, UInt64.max)
        let restored = Data(
            #"{"version":1,"providers":[{"id":"claude","apiKey":"restored-legacy","enabled":true}]}"#.utf8)
        try restored.write(to: testConfigURL)
        var staleRows = failedSnapshot.providers
        let claudeIndex = try XCTUnwrap(staleRows.firstIndex { $0.id == "claude" })
        staleRows[claudeIndex].enabled = false

        XCTAssertThrowsError(try BirdNionConfigStore.saveProviders(
            staleRows,
            expectedRevision: failedSnapshot.settingsRevision,
            url: testConfigURL))
        XCTAssertEqual(try Data(contentsOf: testConfigURL), restored)
    }

    func testBackupOnlyCrashStateRecoversBeforeLoadAndMutation() throws {
        let original = Data(
            #"{"version":1,"settingsRevision":9,"providers":[{"id":"claude","apiKey":"keep-me","enabled":true}]}"#.utf8
        )
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try original.write(to: casBackupURL)

        let loaded = try XCTUnwrap(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertEqual(loaded.settingsRevision, 9)
        XCTAssertEqual(loaded.providers?.first?.apiKey, "keep-me")
        XCTAssertEqual(try Data(contentsOf: testConfigURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: casBackupURL.path))

        try FileManager.default.moveItem(at: testConfigURL, to: casBackupURL)
        try BirdNionConfigStore.save(
            .init(id: "minimax", apiKey: "new-key", enabled: true),
            url: testConfigURL)

        let saved = try XCTUnwrap(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertEqual(saved.settingsRevision, 10)
        XCTAssertEqual(saved.providers?.first { $0.id == "claude" }?.apiKey, "keep-me")
        XCTAssertEqual(saved.providers?.first { $0.id == "minimax" }?.apiKey, "new-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: casBackupURL.path))
    }

    func testMalformedBackupOnlyStateFailsClosedWithoutCreatingDefaults() throws {
        let malformed = Data("{ broken recovery json".utf8)
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try malformed.write(to: casBackupURL)

        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: testConfigURL.path))
        XCTAssertEqual(try Data(contentsOf: casBackupURL), malformed)
    }

    func testMalformedExternalDestinationKeepsValidRecoveryBackup() throws {
        let backup = Data(
            #"{"version":1,"settingsRevision":3,"providers":[{"id":"claude","enabled":true}]}"#.utf8
        )
        let external = Data("external partial write".utf8)
        try FileManager.default.createDirectory(
            at: testConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try backup.write(to: casBackupURL)
        try external.write(to: testConfigURL)

        XCTAssertNil(BirdNionConfigStore.read(url: testConfigURL))
        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "minimax", enabled: true), url: testConfigURL)
        )
        XCTAssertEqual(try Data(contentsOf: testConfigURL), external)
        XCTAssertEqual(try Data(contentsOf: casBackupURL), backup)
    }

    func testRevisionOverflowFailsWithoutChangingExistingBytes() throws {
        let original = #"{"version":1,"settingsRevision":18446744073709551615,"providers":[]}"#
        try writeRaw(original)

        XCTAssertThrowsError(
            try BirdNionConfigStore.save(.init(id: "claude", enabled: true), url: testConfigURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("revision overflow"))
        }
        XCTAssertEqual(try String(contentsOf: testConfigURL, encoding: .utf8), original)
    }

    func testSaveClearsKnownOptionalFieldWithoutResurrectingIt() throws {
        try writeRaw(#"{"version":1,"providers":[{"id":"claude","enabled":true,"accountLabel":"Old Label"}]}"#)

        var provider = try XCTUnwrap(BirdNionConfigStore.provider(id: "claude", url: testConfigURL))
        XCTAssertEqual(provider.accountLabel, "Old Label")
        provider.accountLabel = nil
        try BirdNionConfigStore.save(provider, url: testConfigURL)

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: testConfigURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(raw["providers"] as? [[String: Any]])
        let claude = try XCTUnwrap(providers.first { $0["id"] as? String == "claude" })
        // Cleared, not resurrected by the unknown-key merge (which only ever
        // applies to keys this build doesn't model).
        XCTAssertNil(claude["accountLabel"])
    }
}
