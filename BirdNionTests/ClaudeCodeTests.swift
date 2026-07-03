import XCTest
@testable import BirdNion

/// Tests for the "Claude Code" env-config feature: backend mapping, /v1/models
/// fetch (incl. Bearer fallback), full-config gating, and the settings.json /
/// settings.local.json writer (global + per-project).
final class ClaudeCodeTests: XCTestCase {

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - ClaudeCodeBackend

    func testBackendSupport() {
        // Hapo host is derived from config (not hardcoded), so test the origin
        // extractor directly rather than asserting a committed hostname.
        XCTAssertEqual(ClaudeCodeBackend.anthropicOrigin(from: "https://api.example.com/v1/budget/week"),
                       "https://api.example.com")
        XCTAssertEqual(ClaudeCodeBackend.anthropicOrigin(from: "https://api.example.com:8443/x"),
                       "https://api.example.com:8443")
        XCTAssertNil(ClaudeCodeBackend.anthropicOrigin(from: ""))
        // Anthropic-compatible providers.
        XCTAssertEqual(ClaudeCodeBackend.baseURL(forProviderID: "deepseek"), "https://api.deepseek.com/anthropic")
        XCTAssertTrue(ClaudeCodeBackend.isSupported("minimax"))   // region-based URL
        XCTAssertTrue(ClaudeCodeBackend.isSupported("zai"))
        XCTAssertTrue(ClaudeCodeBackend.baseURL(forProviderID: "minimax")?.hasSuffix("/anthropic") ?? false)
        XCTAssertTrue(ClaudeCodeBackend.baseURL(forProviderID: "zai")?.hasSuffix("/api/anthropic") ?? false)
        // Not Claude Code backends.
        XCTAssertNil(ClaudeCodeBackend.baseURL(forProviderID: "openrouter"))
        XCTAssertFalse(ClaudeCodeBackend.isSupported("groq"))
        // Documented model suggestions for endpoints without /v1/models.
        XCTAssertFalse(ClaudeCodeBackend.suggestedModels(forProviderID: "deepseek").isEmpty)
        XCTAssertTrue(ClaudeCodeBackend.suggestedModels(forProviderID: "hapo").isEmpty)
    }

    // MARK: - modelsURL construction

    func testModelsURL() {
        XCTAssertEqual(ClaudeCodeModelsFetcher.modelsURL(baseURL: "https://x.dev")?.absoluteString,
                       "https://x.dev/v1/models")
        XCTAssertEqual(ClaudeCodeModelsFetcher.modelsURL(baseURL: "https://x.dev/")?.absoluteString,
                       "https://x.dev/v1/models")
        XCTAssertEqual(ClaudeCodeModelsFetcher.modelsURL(baseURL: "https://x.dev/v1")?.absoluteString,
                       "https://x.dev/v1/models")
        XCTAssertNil(ClaudeCodeModelsFetcher.modelsURL(baseURL: "  "))
    }

    // MARK: - parse

    func testParseModels() throws {
        // Empty ids filtered; results sorted most-recent-first by created_at.
        let json = """
        {"data":[
          {"id":"old","created_at":"2024-01-01T00:00:00Z"},
          {"id":"newest","created_at":"2025-06-01T00:00:00Z"},
          {"id":"mid","created_at":"2024-09-01T00:00:00Z"},
          {"id":""}
        ],"object":"list"}
        """.data(using: .utf8)!
        let ids = try ClaudeCodeModelsFetcher.parse(json)
        XCTAssertEqual(ids, ["newest", "mid", "old"])
    }

    func testParseModelsUnixCreatedAndUndatedLast() throws {
        let json = """
        {"data":[
          {"id":"a","created":1700000000},
          {"id":"b","created":1800000000},
          {"id":"undated"}
        ]}
        """.data(using: .utf8)!
        let ids = try ClaudeCodeModelsFetcher.parse(json)
        XCTAssertEqual(ids, ["b", "a", "undated"])  // newest first, undated last
    }

    // MARK: - fetch (stubbed)

    func testFetchUsesXApiKey() async throws {
        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { _ in
            let body = #"{"data":[{"id":"m1"},{"id":"m2"}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.example.com/v1/models")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        defer { StubURLProtocol.reset() }

        let ids = try await ClaudeCodeModelsFetcher.fetchModels(
            baseURL: "https://api.example.com", token: "SECRET", session: session)
        XCTAssertEqual(ids, ["m1", "m2"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "SECRET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"),
                       ClaudeCodeModelsFetcher.anthropicVersion)
    }

    func testFetchFallsBackToBearerOn401() async throws {
        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            let url = req.url!
            // First call (x-api-key) → 401; second call (Bearer) → 200.
            if StubURLProtocol.requestCount == 1 {
                return (HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
            let body = #"{"data":[{"id":"ok"}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { StubURLProtocol.reset() }

        let ids = try await ClaudeCodeModelsFetcher.fetchModels(
            baseURL: "https://api.example.com", token: "TOK", session: session)
        XCTAssertEqual(ids, ["ok"])
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer TOK")
    }

    func testFetchThrowsOnHTTPError() async {
        let session = URLSession(configuration: makeStubConfig())
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }
        do {
            _ = try await ClaudeCodeModelsFetcher.fetchModels(
                baseURL: "https://x.dev", token: "t", session: session)
            XCTFail("expected throw")
        } catch let e as ClaudeCodeModelsFetcher.FetchError {
            XCTAssertEqual(e, .http(500))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - isFullyConfigured

    func testIsFullyConfigured() {
        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "k")
        XCTAssertFalse(ClaudeCodeConfigWriter.isFullyConfigured(p))  // no models
        p.claudeHaikuModel = "h"; p.claudeSonnetModel = "s"; p.claudeOpusModel = "o"
        XCTAssertTrue(ClaudeCodeConfigWriter.isFullyConfigured(p))

        // Unsupported provider is never fully configured.
        var unsup = BirdNionConfigStore.Provider(id: "openrouter", apiKey: "k")
        unsup.claudeHaikuModel = "h"; unsup.claudeSonnetModel = "s"; unsup.claudeOpusModel = "o"
        XCTAssertFalse(ClaudeCodeConfigWriter.isFullyConfigured(unsup))

        // Missing key.
        var noKey = BirdNionConfigStore.Provider(id: "deepseek")
        noKey.claudeHaikuModel = "h"; noKey.claudeSonnetModel = "s"; noKey.claudeOpusModel = "o"
        XCTAssertFalse(ClaudeCodeConfigWriter.isFullyConfigured(noKey))
    }

    // MARK: - projectSettingsURL

    func testProjectSettingsURL() {
        let dir = URL(fileURLWithPath: "/tmp/proj")
        XCTAssertEqual(ConfigService.projectSettingsURL(projectDir: dir).path,
                       "/tmp/proj/.claude/settings.json")
    }

    // MARK: - writer (global) replaces env, preserves top-level keys

    @MainActor
    func testApplyGlobalWritesExactEnv() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        // Seed an existing settings.json with unrelated env + top-level keys.
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let seed = #"{"env":{"FOO":"bar"},"permissions":{"defaultMode":"plan"}}"#
        try seed.data(using: .utf8)!.write(to: settingsURL)

        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "SECRET")
        p.claudeHaikuModel = "h1"; p.claudeSonnetModel = "s1"; p.claudeOpusModel = "o1"
        p.claudeDisable1M = true

        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)

        let root = try readJSON(settingsURL)
        let env = root["env"] as? [String: Any]
        XCTAssertNil(env?["FOO"])                                           // env replaced, not merged
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"] as? String, "SECRET")
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"] as? String, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(env?["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, "h1")
        XCTAssertEqual(env?["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "s1")
        XCTAssertEqual(env?["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, "o1")
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_1M_CONTEXT"] as? String, "1")
        XCTAssertNotNil(root["permissions"])                                // top-level preserved
    }

    @MainActor
    func testApplyGlobalRemoves1MFlagWhenDisabledFalse() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"env":{"CLAUDE_CODE_DISABLE_1M_CONTEXT":"1"}}"#.data(using: .utf8)!.write(to: settingsURL)

        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "k")
        p.claudeHaikuModel = "h"; p.claudeSonnetModel = "s"; p.claudeOpusModel = "o"
        p.claudeDisable1M = false

        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)
        let env = try readJSON(settingsURL)["env"] as? [String: Any]
        XCTAssertNil(env?["CLAUDE_CODE_DISABLE_1M_CONTEXT"])  // removed when false
    }

    // MARK: - writer (per-project) → .claude/settings.json, creates .claude

    @MainActor
    func testApplyProjectWritesProjectSettings() throws {
        let config = ConfigService(homeOverride: tempDir())
        let projectDir = tempDir()  // no .claude yet
        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "PT")
        p.claudeHaikuModel = "h"; p.claudeSonnetModel = "s"; p.claudeOpusModel = "o"

        try ClaudeCodeConfigWriter.apply(provider: p, scope: .project(projectDir), using: config)

        let projURL = projectDir.appendingPathComponent(".claude/settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projURL.path))
        let env = try readJSON(projURL)["env"] as? [String: Any]
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"] as? String, "PT")
        // The global settings.json must be untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.activePath.path))
    }

    @MainActor
    func testApplyThrowsWhenModelsMissing() {
        let config = ConfigService(homeOverride: tempDir())
        let p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "k")  // no models
        XCTAssertThrowsError(try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)) {
            XCTAssertEqual($0 as? ClaudeCodeConfigWriter.WriteError, .missingModels)
        }
    }

    // MARK: - power toggle (isActive / deactivate)

    @MainActor
    func testApplyReplacesEnvAndKeepsTopLevel() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        let url = config.activePath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Pre-existing env from a DIFFERENT config + a top-level key.
        try #"{"env":{"STALE_KEY":"x","ANTHROPIC_AUTH_TOKEN":"old"},"permissions":{"defaultMode":"plan"}}"#
            .data(using: .utf8)!.write(to: url)

        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "k")
        p.claudeHaikuModel = "h"; p.claudeSonnetModel = "s"; p.claudeOpusModel = "o"

        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .off)
        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .synced)

        let root = try readJSON(url)
        let env = root["env"] as? [String: Any]
        // env is EXACTLY this config — the other config's key is gone.
        XCTAssertNil(env?["STALE_KEY"])
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"] as? String, "k")
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"] as? String, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(env?.count, 5)  // token, base, haiku, sonnet, opus
        XCTAssertNotNil(root["permissions"])  // top-level preserved

        try ClaudeCodeConfigWriter.deactivate(scope: .global, using: config)
        let after = try readJSON(url)
        XCTAssertTrue((after["env"] as? [String: Any])?.isEmpty ?? false)  // env cleared
        XCTAssertNotNil(after["permissions"])  // top-level still preserved
    }

    // MARK: - custom profiles

    private func freeModelProfile() -> BirdNionConfigStore.ClaudeCodeProfile {
        .init(id: "p1", name: "FreeModel",
              baseURL: "https://api-cc.example.dev",
              token: "fe_oa_abc",
              tokenEnvKey: "ANTHROPIC_API_KEY",
              apiKeyHelper: "echo 'fe_oa_abc'",
              haikuModel: nil, sonnetModel: nil, opusModel: nil,
              extraEnv: [.init(id: "e1", key: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", value: "1")])
    }

    func testProfileReadyAndSpec() {
        XCTAssertTrue(ClaudeCodeConfigWriter.isReady(freeModelProfile()))
        let spec = ClaudeCodeConfigWriter.spec(forProfile: freeModelProfile())
        XCTAssertEqual(spec?.env["ANTHROPIC_API_KEY"], "fe_oa_abc")
        XCTAssertEqual(spec?.apiKeyHelper, "echo 'fe_oa_abc'")

        // Missing token / base URL → not ready.
        let empty = BirdNionConfigStore.ClaudeCodeProfile(
            id: "x", name: "n", baseURL: "", token: "", tokenEnvKey: "ANTHROPIC_AUTH_TOKEN",
            apiKeyHelper: nil, haikuModel: nil, sonnetModel: nil, opusModel: nil, extraEnv: nil)
        XCTAssertFalse(ClaudeCodeConfigWriter.isReady(empty))
        XCTAssertNil(ClaudeCodeConfigWriter.spec(forProfile: empty))
    }

    @MainActor
    func testCustomProfileApplyReplacesEnv() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        let url = config.activePath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Prior env from another config + a top-level key to preserve.
        try #"{"env":{"ANTHROPIC_AUTH_TOKEN":"other"},"permissions":{"defaultMode":"plan"}}"#
            .data(using: .utf8)!.write(to: url)
        let profile = freeModelProfile()

        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .off)
        try ClaudeCodeConfigWriter.apply(profile: profile, scope: .global, using: config)

        var root = try readJSON(url)
        var env = root["env"] as? [String: Any]
        XCTAssertEqual(env?["ANTHROPIC_API_KEY"] as? String, "fe_oa_abc")
        XCTAssertNil(env?["ANTHROPIC_AUTH_TOKEN"])  // other config's key wiped
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"] as? String, "https://api-cc.example.dev")
        XCTAssertEqual(env?["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] as? String, "1")
        XCTAssertEqual(root["apiKeyHelper"] as? String, "echo 'fe_oa_abc'")
        XCTAssertNotNil(root["permissions"])  // top-level preserved
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .synced)

        try ClaudeCodeConfigWriter.deactivate(profile: profile, scope: .global, using: config)
        root = try readJSON(url)
        env = root["env"] as? [String: Any]
        XCTAssertTrue(env?.isEmpty ?? false)   // env cleared
        XCTAssertNil(root["apiKeyHelper"])
        XCTAssertNotNil(root["permissions"])   // top-level preserved
    }

    func testProfileCRUD() throws {
        let url = tempDir().appendingPathComponent("cfg.json")
        try BirdNionConfigStore.saveClaudeCodeProfile(freeModelProfile(), url: url)
        XCTAssertEqual(BirdNionConfigStore.claudeCodeProfiles(url: url).count, 1)
        XCTAssertEqual(BirdNionConfigStore.claudeCodeProfiles(url: url).first?.name, "FreeModel")
        try BirdNionConfigStore.removeClaudeCodeProfile(id: "p1", url: url)
        XCTAssertTrue(BirdNionConfigStore.claudeCodeProfiles(url: url).isEmpty)
    }

    func testClaudeCodeTargetPersistsIndependently() throws {
        let url = tempDir().appendingPathComponent("cfg.json")

        var minimax = BirdNionConfigStore.Provider(id: "minimax", apiKey: "sk-mm")
        minimax.claudeCodeScope = "project"
        minimax.claudeCodeProjectPath = "/tmp/minimax-project"
        try BirdNionConfigStore.save(minimax, url: url)

        var deepseek = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "sk-ds")
        deepseek.claudeCodeScope = "global"
        deepseek.claudeCodeProjectPath = "/tmp/remembered-deepseek-project"
        try BirdNionConfigStore.save(deepseek, url: url)

        var profile = freeModelProfile()
        profile.claudeCodeScope = "project"
        profile.claudeCodeProjectPath = "/tmp/custom-profile-project"
        try BirdNionConfigStore.saveClaudeCodeProfile(profile, url: url)

        XCTAssertEqual(BirdNionConfigStore.provider(id: "minimax", url: url)?.claudeCodeScope, "project")
        XCTAssertEqual(BirdNionConfigStore.provider(id: "minimax", url: url)?.claudeCodeProjectPath,
                       "/tmp/minimax-project")
        XCTAssertEqual(BirdNionConfigStore.provider(id: "deepseek", url: url)?.claudeCodeScope, "global")
        XCTAssertEqual(BirdNionConfigStore.provider(id: "deepseek", url: url)?.claudeCodeProjectPath,
                       "/tmp/remembered-deepseek-project")
        XCTAssertEqual(BirdNionConfigStore.claudeCodeProfiles(url: url).first?.claudeCodeScope, "project")
        XCTAssertEqual(BirdNionConfigStore.claudeCodeProfiles(url: url).first?.claudeCodeProjectPath,
                       "/tmp/custom-profile-project")
    }

    // MARK: - import from pasted JSON

    func testImportFullSettingsJSON() throws {
        let json = """
        {
          "apiKeyHelper": "echo 'fe_oa_x'",
          "env": {
            "ANTHROPIC_API_KEY": "fe_oa_x",
            "ANTHROPIC_BASE_URL": "https://api-cc.example.dev",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "big",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
          }
        }
        """
        let base = BirdNionConfigStore.ClaudeCodeProfile(
            id: "keep", name: "keep-name", baseURL: "", token: "",
            tokenEnvKey: "ANTHROPIC_AUTH_TOKEN", apiKeyHelper: nil,
            haikuModel: nil, sonnetModel: nil, opusModel: nil, extraEnv: nil)
        let p = try ClaudeCodeConfigWriter.profile(byImporting: json, into: base)
        XCTAssertEqual(p.id, "keep")            // id/name preserved
        XCTAssertEqual(p.name, "keep-name")
        XCTAssertEqual(p.token, "fe_oa_x")
        XCTAssertEqual(p.tokenEnvKey, "ANTHROPIC_API_KEY")
        XCTAssertEqual(p.baseURL, "https://api-cc.example.dev")
        XCTAssertEqual(p.opusModel, "big")
        XCTAssertEqual(p.apiKeyHelper, "echo 'fe_oa_x'")
        XCTAssertEqual(p.extraEnv?.first(where: { $0.key == "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" })?.value, "1")
        // Recognized keys are NOT duplicated into extraEnv.
        XCTAssertNil(p.extraEnv?.first { $0.key == "ANTHROPIC_API_KEY" })
    }

    func testImportBareEnvAndNumberCoercion() throws {
        let json = #"{"ANTHROPIC_AUTH_TOKEN":"t","ANTHROPIC_BASE_URL":"https://x","FOO":42}"#
        let p = try ClaudeCodeConfigWriter.profile(byImporting: json, into: freeModelProfile())
        XCTAssertEqual(p.token, "t")
        XCTAssertEqual(p.tokenEnvKey, "ANTHROPIC_AUTH_TOKEN")
        XCTAssertEqual(p.baseURL, "https://x")
        XCTAssertEqual(p.extraEnv?.first(where: { $0.key == "FOO" })?.value, "42")  // number → "42"
    }

    func testImportInvalidJSONThrows() {
        XCTAssertThrowsError(try ClaudeCodeConfigWriter.profile(byImporting: "not json", into: freeModelProfile())) {
            XCTAssertEqual($0 as? ClaudeCodeConfigWriter.ImportError, .invalidJSON)
        }
    }

    // MARK: - sync state (drift on key change)

    @MainActor
    func testSyncStateStaleOnKeyChangeThenReapply() throws {
        let config = ConfigService(homeOverride: tempDir())
        var p = BirdNionConfigStore.Provider(id: "deepseek", apiKey: "OLD")
        p.claudeHaikuModel = "h"; p.claudeSonnetModel = "s"; p.claudeOpusModel = "o"

        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .off)
        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .synced)

        // Key changed in BirdNion → file is now stale (base URL still matches).
        p.apiKey = "NEW"
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .stale)

        // Re-apply patches the value in place → synced; token updated.
        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProvider: p, scope: .global, using: config), .synced)
        let env = try readJSON(config.activePath)["env"] as? [String: Any]
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"] as? String, "NEW")
    }

    @MainActor
    func testMiniMaxPresetIncludesDocumentedEnv() throws {
        let config = ConfigService(homeOverride: tempDir())
        var p = BirdNionConfigStore.Provider(id: "minimax", apiKey: "sk-x")
        p.claudeHaikuModel = "MiniMax-M3[1m]"
        p.claudeSonnetModel = "MiniMax-M3[1m]"
        p.claudeOpusModel = "MiniMax-M3[1m]"
        try ClaudeCodeConfigWriter.apply(provider: p, scope: .global, using: config)

        let env = try readJSON(config.activePath)["env"] as? [String: Any]
        // Documented extras from MiniMax's Claude Code docs.
        XCTAssertEqual(env?["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String, "1000000")
        XCTAssertEqual(env?["ANTHROPIC_MODEL"] as? String, "MiniMax-M3[1m]")  // primary = sonnet tier
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"] as? String, "https://api.minimax.io/anthropic")
        // Suggestions surface the 1M variant first.
        XCTAssertEqual(ClaudeCodeBackend.suggestedModels(forProviderID: "minimax").first, "MiniMax-M3[1m]")
    }

    func testStaticEnvOnlyForDocumentedProviders() {
        XCTAssertTrue(ClaudeCodeBackend.staticEnv(forProviderID: "deepseek").isEmpty)
        XCTAssertEqual(ClaudeCodeBackend.staticEnv(forProviderID: "zai")["API_TIMEOUT_MS"], "3000000")
        XCTAssertFalse(ClaudeCodeBackend.usesPrimaryModelKey("zai"))
    }

    @MainActor
    func testSyncStateStaleForProfileTokenChange() throws {
        let config = ConfigService(homeOverride: tempDir())
        var profile = freeModelProfile()
        try ClaudeCodeConfigWriter.apply(profile: profile, scope: .global, using: config)
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .synced)
        profile.token = "fe_oa_new"
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .stale)
    }
}
