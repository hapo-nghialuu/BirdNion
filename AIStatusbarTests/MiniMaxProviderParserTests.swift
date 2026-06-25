import XCTest
@testable import AIStatusbar

final class MiniMaxProviderParserTests: XCTestCase {
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
        let keychain = KeychainService()
        let account = "test-minimax-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "test-token")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session, keychain: keychain)
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
        let p = MiniMaxProvider(keychain: KeychainService())
        let s = p.parse(json, accountLabel: "u")
        XCTAssertEqual(s.planName, "Plus")
    }

    func testPlanNameNilWhenAllMissing() throws {
        // happyJSON has current_subscribe_title so non-nil; verify the parser
        // accepts missing plan fields by parsing a payload that omits them.
        let empty = #"""
        {"base_resp":{"status_code":0,"status_msg":"success"},
        "model_remains":[{"model_name":"general",
        "current_interval_total_count":100,"current_interval_usage_count":0,
        "current_interval_remaining_percent":100,
        "current_weekly_total_count":700,"current_weekly_usage_count":0,
        "current_weekly_remaining_percent":100}]}
        """#.data(using: .utf8)!
        let p = MiniMaxProvider(keychain: KeychainService())
        let s2 = p.parse(empty, accountLabel: "u")
        XCTAssertNil(s2.planName)
    }

    func testMissingModel() throws {
        let keychain = KeychainService()
        let account = "test-minimax-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "test-token")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session, keychain: keychain)
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
        let keychain = KeychainService()
        let account = "test-minimax-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "test-token")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session, keychain: keychain)
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
        let keychain = KeychainService()
        let account = "test-minimax-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        try keychain.save(account: account, secret: "test-token")
        let session = URLSession(configuration: makeStubConfig())
        let p = MiniMaxProvider(session: session, keychain: keychain)
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

/// Isolated tests for the shared CodexBar config file (token interop store).
/// All file I/O goes to a temp URL so nothing touches the real
/// `~/.codexbar/config.json`.
final class CodexBarConfigStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cfg-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
    }

    func testWriteThenReadRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CodexBarConfigStore.setAPIKey("sk-test-123", provider: "minimax", url: url)
        XCTAssertEqual(CodexBarConfigStore.apiKey(provider: "minimax", url: url), "sk-test-123")
    }

    func testUpsertUpdatesExistingWithoutDuplicating() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CodexBarConfigStore.setAPIKey("first", provider: "minimax", url: url)
        try CodexBarConfigStore.setAPIKey("second", provider: "minimax", url: url)
        XCTAssertEqual(CodexBarConfigStore.apiKey(provider: "minimax", url: url), "second")
        let cfg = CodexBarConfigStore.read(url: url)
        XCTAssertEqual(cfg?.providers?.filter { $0.id == "minimax" }.count, 1)
    }

    func testPreservesOtherProviders() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CodexBarConfigStore.setAPIKey("codex-key", provider: "codex", url: url)
        try CodexBarConfigStore.setAPIKey("minimax-key", provider: "minimax", url: url)
        // Writing one provider must not drop the other.
        XCTAssertEqual(CodexBarConfigStore.apiKey(provider: "codex", url: url), "codex-key")
        XCTAssertEqual(CodexBarConfigStore.apiKey(provider: "minimax", url: url), "minimax-key")
    }

    func testTrimsWhitespace() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CodexBarConfigStore.setAPIKey("  sk-padded  ", provider: "minimax", url: url)
        XCTAssertEqual(CodexBarConfigStore.apiKey(provider: "minimax", url: url), "sk-padded")
    }

    func testMissingFileReturnsNil() {
        let url = tempURL()   // never written
        XCTAssertNil(CodexBarConfigStore.read(url: url))
        XCTAssertNil(CodexBarConfigStore.apiKey(provider: "minimax", url: url))
    }

    // MARK: - Path resolution

    func testConfigURLEnvOverrideWins() {
        let url = CodexBarConfigStore.configURL(env: ["CODEXBAR_CONFIG": "/tmp/custom/cfg.json"])
        XCTAssertEqual(url.path, "/tmp/custom/cfg.json")
    }

    func testConfigURLPrefersLegacyWhenOnlyLegacyPresent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)")
        let legacy = home.appendingPathComponent(".codexbar/config.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{}".write(to: legacy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(CodexBarConfigStore.configURL(home: home, env: [:]), legacy)
    }

    func testConfigURLDefaultsToXDGWhenNeitherPresent() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)")
        XCTAssertEqual(CodexBarConfigStore.configURL(home: home, env: [:]),
                       home.appendingPathComponent(".config/codexbar/config.json"))
    }
}

// MARK: - Ported providers (parser-only, no network)

final class OpenRouterProviderTests: XCTestCase {
    func testParseCreditsWindow() {
        let json = #"{"data":{"total_credits":10.0,"total_usage":2.5}}"#.data(using: .utf8)!
        let s = OpenRouterProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].usedPct, 25)        // 2.5 / 10 = 25%
        XCTAssertEqual(s.windows[0].remainingPct, 75)
        XCTAssertEqual(s.creditsRemaining, 7.5)
    }

    func testParseZeroCredits() {
        let json = #"{"data":{"total_credits":0,"total_usage":0}}"#.data(using: .utf8)!
        let s = OpenRouterProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.first?.usedPct, 0)     // no divide-by-zero
    }

    func testParseMalformed() {
        let s = OpenRouterProvider(keychain: KeychainService()).parse(Data("x".utf8), accountLabel: "u")
        XCTAssertEqual(s.error, "Response thiếu trường")
    }
}

final class DeepSeekProviderTests: XCTestCase {
    func testParseBalance() {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.34"}]}"#
            .data(using: .utf8)!
        let s = DeepSeekProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.creditsRemaining, 12.34)
        XCTAssertEqual(s.windows.first?.subtitle, "$12.34")
    }

    func testParseCNY() {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"88.00"}]}"#
            .data(using: .utf8)!
        let s = DeepSeekProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
        XCTAssertEqual(s.windows.first?.subtitle, "¥88.00")
    }

    func testParseEmptyInfos() {
        let json = #"{"is_available":true,"balance_infos":[]}"#.data(using: .utf8)!
        let s = DeepSeekProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
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
        let s = ZaiProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
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
        let s = ZaiProvider(keychain: KeychainService()).parse(json, accountLabel: "u")
        XCTAssertEqual(s.error, "unauthorized")
    }

    func testLabelMapping() {
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 3, number: 5), "5 giờ")
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 1, number: 7), "7 ngày")
        XCTAssertEqual(ZaiProvider.label(type: "TIME_LIMIT", unit: 6, number: 1), "Tuần")
        XCTAssertEqual(ZaiProvider.label(type: "TOKENS_LIMIT", unit: 0, number: 0), "Tokens")
    }
}

final class ClaudeProviderTests: XCTestCase {
    func testParseUsageWindows() {
        let json = #"""
        {"five_hour":{"utilization":30,"resets_at":"2026-07-01T00:00:00Z"},
        "seven_day":{"utilization":72,"resets_at":"2026-07-05T00:00:00Z"}}
        """#.data(using: .utf8)!
        let s = ClaudeProvider().parse(json, accountLabel: nil)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows[0].label, "5 giờ")
        XCTAssertEqual(s.windows[0].remainingPct, 70)
        XCTAssertEqual(s.windows[1].label, "Tuần")
        XCTAssertEqual(s.windows[1].remainingPct, 28)
        XCTAssertNotNil(s.windows[0].resetDate)
    }

    func testParseAllWindows() {
        // five_hour + seven_day + seven_day_opus + seven_day_sonnet + extra_usage
        let json = #"""
        {"five_hour":{"utilization":10},
        "seven_day":{"utilization":40},
        "seven_day_opus":{"utilization":55},
        "seven_day_sonnet":{"utilization":20},
        "extra_usage":{"is_enabled":true,"monthly_limit":50.0,"used_credits":12.34}}
        """#.data(using: .utf8)!
        let s = ClaudeProvider().parse(json, accountLabel: nil)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 4)
        XCTAssertEqual(s.windows.map(\.label), ["5 giờ", "Tuần", "Opus", "Sonnet"])
        XCTAssertEqual(s.windows[2].remainingPct, 45)
        XCTAssertEqual(s.creditsRemaining ?? 0, 37.66, accuracy: 0.001) // 50 - 12.34
    }

    func testExtraUsageDisabledNoCredits() {
        let json = #"""
        {"five_hour":{"utilization":10},
        "extra_usage":{"is_enabled":false,"monthly_limit":50.0,"used_credits":12.34}}
        """#.data(using: .utf8)!
        let s = ClaudeProvider().parse(json, accountLabel: nil)
        XCTAssertNil(s.creditsRemaining) // disabled → no spend surface
    }

    func testParseEmptyThrowsErrorStatus() {
        let json = #"{}"#.data(using: .utf8)!
        let s = ClaudeProvider().parse(json, accountLabel: nil)
        XCTAssertEqual(s.error, "Claude chưa có dữ liệu quota")
    }

    func testTokenFromKeychainJSON() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-abc"}}"#.data(using: .utf8)!
        XCTAssertEqual(ClaudeProvider.tokenFromKeychainJSON(json), "sk-ant-oat-abc")
    }

    func testTokenFromKeychainJSONMissing() {
        XCTAssertNil(ClaudeProvider.tokenFromKeychainJSON(Data("{}".utf8)))
    }

    func testTokenFromKeychainJSONEmptyString() {
        let json = #"{"claudeAiOauth":{"accessToken":"   "}}"#.data(using: .utf8)!
        XCTAssertNil(ClaudeProvider.tokenFromKeychainJSON(json))
    }

    // MARK: - Plan mapping (ClaudePlan.label)

    func testPlanLabelMaxFromRateLimitTier() {
        XCTAssertEqual(ClaudePlan.label(forSubscriptionType: nil, rateLimitTier: "claude_max_20x"), "Max")
    }

    func testPlanLabelProFromSubscriptionType() {
        XCTAssertEqual(ClaudePlan.label(forSubscriptionType: "Claude Pro", rateLimitTier: nil), "Pro")
    }

    func testPlanLabelTeamAndEnterprise() {
        XCTAssertEqual(ClaudePlan.label(forSubscriptionType: "Claude Team", rateLimitTier: nil), "Team")
        XCTAssertEqual(ClaudePlan.label(forSubscriptionType: "Claude Enterprise", rateLimitTier: nil), "Enterprise")
    }

    func testPlanLabelFallsBackToTier() {
        // tier wins when subscriptionType doesn't match.
        XCTAssertEqual(ClaudePlan.label(forSubscriptionType: "anything", rateLimitTier: "max"), "Max")
    }

    func testPlanLabelUnknownReturnsNil() {
        XCTAssertNil(ClaudePlan.label(forSubscriptionType: nil, rateLimitTier: nil))
        XCTAssertNil(ClaudePlan.label(forSubscriptionType: "free", rateLimitTier: "free_tier"))
    }
}
