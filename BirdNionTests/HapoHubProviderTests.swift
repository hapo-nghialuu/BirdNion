import XCTest
@testable import BirdNion

/// Tests for `HapoHubProvider`. Uses `BirdNionConfigStore` (via an isolated
/// `BIRDNION_CONFIG` env override) to inject tokens without touching the
/// real `~/.birdnion/settings.json` on the developer's machine.
final class HapoHubProviderTests: XCTestCase {
    /// Per-test config file path so parallel tests can't trample each other.
    private var testConfigURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hapo-test-\(UUID().uuidString)/settings.json")
        setenv("BIRDNION_CONFIG", testConfigURL.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testConfigURL.deletingLastPathComponent())
        unsetenv("BIRDNION_CONFIG")
        try super.tearDownWithError()
    }

    /// Writes a token into the BirdNion config for `providerID`, returning a
    /// cleanup closure that the caller can `defer`.
    private func installToken(_ token: String, for providerID: String) throws {
        var entry = BirdNionConfigStore.provider(id: providerID)
            ?? BirdNionConfigStore.Provider(id: providerID)
        entry.apiKey = token
        try BirdNionConfigStore.save(entry)
    }

    func testMockReturnsFixedWindows() async throws {
        let p = MockHapoHubProvider()
        let s = try await p.fetch()
        // Mock mirrors the real adapter: /v1/budget/week reports a single
        // weekly window only.
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].label, "Tuần")
        XCTAssertEqual(s.windows[0].remainingPct, 80)
        XCTAssertNil(s.error)
    }

    func testRealReturns2xxParsed() async throws {
        let account = "test-hapo-\(UUID().uuidString)"
        try installToken("abc123", for: account)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        let config = HapoHubConfig(id: account, displayName: "Hapo",
                                   baseURL: "https://hapo.example/api",
                                   meURL: "https://hapo.example/me",
                                   authHeaderTemplate: "Bearer {token}",
                                   jsonPath: "data.quota.remaining")
        StubURLProtocol.handler = { req in
            // Matches the real `/v1/budget/week` schema (usage_percentage 27 → 73% left).
            let body = #"""
            {"usage_percentage":27.0,"remaining_budget_usd":14.6,"used_budget_usd":5.4,
            "weekly_budget_usd":20.0,"budget_week_ends_at":"2026-07-01T00:00:00Z",
            "budget_week_start_at":"2026-06-24T00:00:00Z","timezone":"Asia/Ho_Chi_Minh"}
            """#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
        defer { StubURLProtocol.reset() }
        let p = HapoHubProvider(session: session, config: config)
        let s = try await p.fetch()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].remainingPct, 73)
    }

    func testRealNon2xx() async throws {
        let account = "test-hapo-\(UUID().uuidString)"
        try installToken("abc123", for: account)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        let config = HapoHubConfig(id: account, displayName: "Hapo",
                                   baseURL: "https://hapo.example/api",
                                   meURL: "https://hapo.example/me",
                                   authHeaderTemplate: "Bearer {token}",
                                   jsonPath: "data.quota.remaining")
        StubURLProtocol.handler = { req in
            let body = Data()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        defer { StubURLProtocol.reset() }
        let p = HapoHubProvider(session: session, config: config)
        let s = try await p.fetch()
        XCTAssertTrue(s.error?.contains("HTTP 500") ?? false)
    }
}
