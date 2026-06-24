import XCTest
@testable import AIStatusbar

final class HapoHubProviderTests: XCTestCase {
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
        // config.id == keychain account so the token resolves via the
        // Keychain fallback; a random id guarantees the shared config file
        // has no matching entry, keeping the test isolated from machine state.
        let keychain = KeychainService()
        let account = "test-hapo-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "abc123")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        let config = HapoHubConfig(id: account, displayName: "Hapo",
                                   baseURL: "https://hapo.example/api",
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
        let p = HapoHubProvider(session: session, config: config, keychain: keychain)
        let s = try await p.fetch()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].remainingPct, 73)
    }

    func testRealNon2xx() async throws {
        let keychain = KeychainService()
        let account = "test-hapo-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "abc123")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        let config = HapoHubConfig(id: account, displayName: "Hapo",
                                   baseURL: "https://hapo.example/api",
                                   authHeaderTemplate: "Bearer {token}",
                                   jsonPath: "data.quota.remaining")
        StubURLProtocol.handler = { req in
            let body = Data()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        defer { StubURLProtocol.reset() }
        let p = HapoHubProvider(session: session, config: config, keychain: keychain)
        let s = try await p.fetch()
        XCTAssertTrue(s.error?.contains("HTTP 500") ?? false)
    }
}
