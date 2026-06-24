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
