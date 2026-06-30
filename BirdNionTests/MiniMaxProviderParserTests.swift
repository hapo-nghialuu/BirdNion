import XCTest
@testable import BirdNion

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
}
