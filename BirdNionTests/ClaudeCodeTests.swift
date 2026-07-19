import AppKit
import SwiftUI
import XCTest
@testable import BirdNion

/// Tests for the "Claude Code" env-config feature: backend mapping, /v1/models
/// fetch (incl. Bearer fallback), full-config gating, and the settings.json /
/// settings.local.json writer (global + per-project).
final class ClaudeCodeTests: XCTestCase {

    private final class CompatibilityProfileRecorder {
        var profile: BirdNionConfigStore.ClaudeCodeProfile?
    }

    private struct CompatibilityPickerHarness: View {
        @State private var profile: BirdNionConfigStore.ClaudeCodeProfile
        let recorder: CompatibilityProfileRecorder

        init(profile: BirdNionConfigStore.ClaudeCodeProfile,
             recorder: CompatibilityProfileRecorder) {
            _profile = State(initialValue: profile)
            self.recorder = recorder
        }

        var body: some View {
            ClaudeCodeCustomProfileConnectionFields(profile: $profile, lang: "en")
                .frame(width: 500)
                .onAppear { recorder.profile = profile }
                .onChange(of: profile) { recorder.profile = $0 }
        }
    }

    private func makeStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }

    private func makeCLIProxyStubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [CLIProxyURLProtocol.self] + (c.protocolClasses ?? [])
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

    @MainActor
    func testRemoveEnvSettingsRemovesOnlyEnvAndHelper() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        let url = config.activePath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try """
        {"env":{"ANTHROPIC_AUTH_TOKEN":"old"},"apiKeyHelper":"echo token","permissions":{"defaultMode":"plan"}}
        """.data(using: .utf8)!.write(to: url)

        XCTAssertTrue(try ClaudeCodeConfigWriter.removeEnvSettings(scope: .global, using: config))

        let root = try readJSON(url)
        XCTAssertNil(root["env"])
        XCTAssertNil(root["apiKeyHelper"])
        XCTAssertNotNil(root["permissions"])
    }

    @MainActor
    func testRemoveEnvSettingsDoesNotCreateMissingFile() throws {
        let config = ConfigService(homeOverride: tempDir())

        XCTAssertFalse(try ClaudeCodeConfigWriter.removeEnvSettings(scope: .global, using: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.activePath.path))
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

    private func openAIProfile() -> BirdNionConfigStore.ClaudeCodeProfile {
        var profile = freeModelProfile()
        profile.compatibilityMode = "openai"
        profile.embeddedLocalProxy = true
        profile.openAIBaseURL = "https://openai-upstream.example/v1"
        profile.openAIAPIKey = "upstream-key"
        profile.cliProxyBaseURL = CLIProxyAPIConfiguration.localBaseURL + "/v1"
        profile.cliProxyAPIKey = "proxy-key"
        profile.cliProxyManagementKey = "management-key"
        profile.haikuModel = "gpt-4o-mini"
        profile.sonnetModel = "gpt-4o"
        profile.opusModel = "gpt-4.1"
        return profile
    }

    private func embeddedAnthropicProfile() -> BirdNionConfigStore.ClaudeCodeProfile {
        var profile = freeModelProfile()
        profile.embeddedLocalProxy = true
        profile.cliProxyBaseURL = CLIProxyAPIConfiguration.localBaseURL + "/v1"
        profile.cliProxyAPIKey = "anthropic-local-key"
        profile.cliProxyManagementKey = "management-key"
        profile.haikuModel = "claude-haiku"
        profile.sonnetModel = "claude-sonnet"
        profile.opusModel = "claude-opus"
        return profile
    }

    func testLegacyProfileDecodesAsAnthropic() throws {
        let json = """
        {
          "id": "legacy", "name": "Legacy", "baseURL": "https://anthropic.example",
          "token": "legacy-token", "tokenEnvKey": "ANTHROPIC_AUTH_TOKEN"
        }
        """
        let profile = try JSONDecoder().decode(BirdNionConfigStore.ClaudeCodeProfile.self,
                                               from: Data(json.utf8))

        XCTAssertEqual(profile.compatibility, .anthropic)
        XCTAssertTrue(ClaudeCodeConfigWriter.isReady(profile))
        XCTAssertEqual(ClaudeCodeConfigWriter.spec(forProfile: profile)?.env["ANTHROPIC_AUTH_TOKEN"],
                       "legacy-token")
    }

    func testLegacyLocalProxyProfileMigratesToOpenAICompatibility() {
        var profile = freeModelProfile()
        profile.compatibilityMode = nil
        profile.embeddedLocalProxy = true
        profile.openAIBaseURL = nil
        profile.openAIAPIKey = nil

        XCTAssertTrue(profile.migrateLegacyLocalProxyToOpenAIIfNeeded())
        XCTAssertEqual(profile.compatibility, .openAI)
        XCTAssertEqual(profile.openAIBaseURL, profile.baseURL)
        XCTAssertEqual(profile.openAIAPIKey, profile.token)
    }

    func testLegacyDirectProfileStaysAnthropic() {
        var profile = freeModelProfile()
        profile.compatibilityMode = nil
        profile.embeddedLocalProxy = nil

        XCTAssertFalse(profile.migrateLegacyLocalProxyToOpenAIIfNeeded())
        XCTAssertEqual(profile.compatibility, .anthropic)
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

    func testOpenAIProfileWriterUsesProxyCredentialsAndDirectModels() {
        let profile = openAIProfile()
        let spec = ClaudeCodeConfigWriter.spec(forProfile: profile)

        XCTAssertTrue(profile.isOpenAIProxyReady)
        XCTAssertEqual(spec?.env["ANTHROPIC_AUTH_TOKEN"], "proxy-key")
        XCTAssertNil(spec?.env["ANTHROPIC_API_KEY"])
        XCTAssertEqual(spec?.env["ANTHROPIC_BASE_URL"], CLIProxyAPIConfiguration.localBaseURL)
        XCTAssertEqual(spec?.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
                       "gpt-4o-mini")
        XCTAssertEqual(spec?.env["ANTHROPIC_DEFAULT_SONNET_MODEL"],
                       "gpt-4o")
        XCTAssertEqual(spec?.env["ANTHROPIC_DEFAULT_OPUS_MODEL"],
                       "gpt-4.1")
        XCTAssertFalse(spec?.env.values.contains("upstream-key") ?? true)
        XCTAssertFalse(spec?.env.values.contains("management-key") ?? true)
        XCTAssertNil(spec?.apiKeyHelper)
    }

    func testEmbeddedAnthropicProfileWriterKeepsUpstreamCredentialsOutOfClaudeCode() {
        let profile = embeddedAnthropicProfile()
        let spec = ClaudeCodeConfigWriter.spec(forProfile: profile)

        XCTAssertEqual(spec?.env["ANTHROPIC_AUTH_TOKEN"], "anthropic-local-key")
        XCTAssertEqual(spec?.env["ANTHROPIC_BASE_URL"], CLIProxyAPIConfiguration.localBaseURL)
        XCTAssertEqual(spec?.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
                       "claude-haiku")
        XCTAssertFalse(spec?.env.values.contains("fe_oa_abc") ?? true)
        XCTAssertFalse(spec?.env.values.contains("management-key") ?? true)
        XCTAssertNil(spec?.apiKeyHelper)
    }

    func testAnthropicProfileCanApplyTheOriginalUpstreamWithoutLocalProxy() {
        var profile = embeddedAnthropicProfile()
        profile.embeddedLocalProxy = false
        profile.cliProxyAppliedSignature = "old-proxy-state"

        let spec = ClaudeCodeConfigWriter.spec(forProfile: profile)

        XCTAssertFalse(profile.usesEmbeddedCLIProxy)
        XCTAssertEqual(spec?.env["ANTHROPIC_API_KEY"], "fe_oa_abc")
        XCTAssertNil(spec?.env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(spec?.env["ANTHROPIC_BASE_URL"], "https://api-cc.example.dev")
        XCTAssertEqual(spec?.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "claude-haiku")
        XCTAssertEqual(spec?.apiKeyHelper, "echo 'fe_oa_abc'")
        XCTAssertFalse(spec?.env.values.contains("anthropic-local-key") ?? true)
    }

    func testCLIProxyConfigurationContainsBothUpstreamProtocols() throws {
        let anthropic = embeddedAnthropicProfile()
        let openAI = openAIProfile()
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(profiles: [anthropic, openAI], authDirectory: tempDir())
        )
        let yaml = try XCTUnwrap(String(data: configuration.yamlData(), encoding: .utf8))

        XCTAssertEqual(configuration.apiKeys, ["anthropic-local-key", "proxy-key"])
        XCTAssertEqual(configuration.claudeAPIKeys.first?.baseURL, anthropic.baseURL)
        XCTAssertEqual(configuration.claudeAPIKeys.first?.prefix, "")
        XCTAssertEqual(configuration.openAICompatibility.first?.baseURL, openAI.openAIBaseURL)
        XCTAssertEqual(configuration.openAICompatibility.first?.prefix, "")
        XCTAssertTrue(yaml.contains("host: \"127.0.0.1\""))
        XCTAssertTrue(yaml.contains("claude-api-key:"))
        XCTAssertTrue(yaml.contains("openai-compatibility:"))
        XCTAssertTrue(yaml.contains("force-model-prefix: false"))
    }

    func testCLIProxyConfigurationUsesDedicatedPortAndYAMLSafePaths() throws {
        let authDirectory = tempDir()
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(profiles: [openAIProfile()], authDirectory: authDirectory)
        )
        let yaml = try XCTUnwrap(String(data: configuration.yamlData(), encoding: .utf8))

        XCTAssertEqual(CLIProxyAPIConfiguration.localBaseURL, "http://127.0.0.1:24323")
        XCTAssertTrue(yaml.contains("port: 24323"))
        XCTAssertTrue(yaml.contains("auth-dir: \"\(authDirectory.path)\""))
        XCTAssertTrue(yaml.contains("base-url: \"https://openai-upstream.example/v1\""))
        XCTAssertFalse(yaml.contains("\\/"))
    }

    func testCLIProxyConfigurationKeepsOneMillionMarkerOnlyUpstream() throws {
        var profile = openAIProfile()
        profile.haikuModel = "gpt-5.6-luna[1m]"
        profile.sonnetModel = "gpt-5.6-terra[1m]"
        profile.opusModel = "gpt-5.6-terra[1m]"

        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(profiles: [profile], authDirectory: tempDir())
        )
        let models = try XCTUnwrap(configuration.openAICompatibility.first?.models)

        XCTAssertEqual(models, [
            .init(name: "gpt-5.6-luna[1m]", alias: "gpt-5.6-luna"),
            .init(name: "gpt-5.6-terra[1m]", alias: "gpt-5.6-terra"),
        ])
        XCTAssertEqual(profile.cliProxyModelAlias(for: "gpt-5.6-terra[1m]"), "gpt-5.6-terra")
        XCTAssertEqual(profile.cliProxyModelAlias(for: "gpt-4.1"), "gpt-4.1")
    }

    @MainActor
    func testLocalProxyOnlyRestoresTheCurrentProfile() {
        var active = openAIProfile()
        active.cliProxyAppliedSignature = active.cliProxyConfigurationSignature

        var inactive = embeddedAnthropicProfile()
        inactive.id = "inactive-profile"
        inactive.cliProxyAppliedSignature = nil

        XCTAssertEqual(
            EmbeddedCLIProxyService.activeProfiles(from: [inactive, active]).map(\.id),
            [active.id]
        )
    }

    @MainActor
    func testLocalProxyRunningStateRequiresTheCurrentEmbeddedProfile() {
        var profile = openAIProfile()
        profile.cliProxyAppliedSignature = profile.cliProxyConfigurationSignature

        XCTAssertTrue(EmbeddedCLIProxyService.isProfileRunning(profile, runtimeState: .running))
        XCTAssertFalse(EmbeddedCLIProxyService.isProfileRunning(profile, runtimeState: .stopped))

        profile.embeddedLocalProxy = false
        XCTAssertFalse(EmbeddedCLIProxyService.isProfileRunning(profile, runtimeState: .running))
    }

    @MainActor
    func testLocalProxyStopOnlyMatchesBirdNionManagedHelper() {
        let configURL = URL(fileURLWithPath: "/tmp/birdnion/cli-proxy-api/config.yaml")

        XCTAssertTrue(LocalProxyProcessController.isManagedProcess(
            "/Applications/BirdNion.app/Contents/Resources/cliproxyapi -config \(configURL.path) -local-model",
            configURL: configURL
        ))
        XCTAssertFalse(LocalProxyProcessController.isManagedProcess(
            "/usr/local/bin/cliproxyapi -config /tmp/another-app/config.yaml",
            configURL: configURL
        ))
        XCTAssertFalse(LocalProxyProcessController.isManagedProcess(
            "/usr/bin/python3 -m http.server 24323",
            configURL: configURL
        ))
    }

    @MainActor
    func testEmbeddedProxyPortMigrationMarks8317ProfilesForReapply() {
        var profile = openAIProfile()
        profile.cliProxyBaseURL = "http://127.0.0.1:8317/v1"
        XCTAssertTrue(EmbeddedCLIProxyService.needsLocalPortMigration(profile))

        profile.cliProxyBaseURL = CLIProxyAPIConfiguration.localBaseURL + "/v1"
        XCTAssertFalse(EmbeddedCLIProxyService.needsLocalPortMigration(profile))
    }

    func testCLIProxyConfigurationDropsDeletedProfileCredentials() throws {
        let remaining = embeddedAnthropicProfile()
        let deleted = openAIProfile()
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(profiles: [remaining], authDirectory: tempDir())
        )

        XCTAssertEqual(configuration.apiKeys, ["anthropic-local-key"])
        XCTAssertEqual(configuration.claudeAPIKeys.count, 1)
        XCTAssertTrue(configuration.openAICompatibility.isEmpty)
        let yaml = try XCTUnwrap(String(data: configuration.yamlData(), encoding: .utf8))
        XCTAssertFalse(yaml.contains(deleted.cliProxyAPIKey!))
        XCTAssertFalse(yaml.contains(deleted.openAIAPIKey!))
    }

    func testImportIntoOpenAIProfileReturnsToAnthropicMode() throws {
        let json = #"{"env":{"ANTHROPIC_AUTH_TOKEN":"direct-token","ANTHROPIC_BASE_URL":"https://direct.example"}}"#
        var source = openAIProfile()
        source.openAIFormat = "responses"
        let profile = try ClaudeCodeConfigWriter.profile(byImporting: json, into: source)

        XCTAssertEqual(profile.compatibility, .anthropic)
        XCTAssertNil(profile.openAIFormat)
        XCTAssertNil(profile.embeddedLocalProxy)
        XCTAssertEqual(profile.token, "direct-token")
        XCTAssertEqual(profile.baseURL, "https://direct.example")
    }

    @MainActor
    func testOpenAIProfileBecomesStaleWhenOnlyUpstreamChanges() throws {
        let home = tempDir()
        let config = ConfigService(homeOverride: home)
        var profile = openAIProfile()
        profile.cliProxyAppliedSignature = profile.cliProxyConfigurationSignature
        try ClaudeCodeConfigWriter.apply(profile: profile, scope: .global, using: config)

        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .synced)
        profile.openAIAPIKey = "changed-upstream-key"
        XCTAssertEqual(ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: .global, using: config), .stale)
    }

    func testCLIProxyAPIClientSynchronizesBirdNionOwnedLists() async throws {
        let session = URLSession(configuration: makeCLIProxyStubConfig())
        let anthropic = embeddedAnthropicProfile()
        let openAI = openAIProfile()
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(profiles: [anthropic, openAI], authDirectory: tempDir())
        )
        CLIProxyURLProtocol.install { request, _ in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            guard request.httpMethod == "PUT",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer management-key",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return (response, Data())
        }
        defer { CLIProxyURLProtocol.reset() }

        try await CLIProxyAPIClient(session: session).synchronize(configuration)

        XCTAssertEqual(CLIProxyURLProtocol.allRequests.map { $0.url?.path }, [
            "/v0/management/api-keys",
            "/v0/management/claude-api-key",
            "/v0/management/openai-compatibility",
        ])
        let bodies = CLIProxyURLProtocol.allBodies
        guard bodies.count == 3 else {
            return XCTFail("expected three management payloads, got \(bodies.count)")
        }
        let apiKeys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodies[0])) as? [String]
        )
        XCTAssertEqual(apiKeys, ["anthropic-local-key", "proxy-key"])

        let claude = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodies[1])) as? [[String: Any]]
        )
        XCTAssertEqual(claude.first?["api-key"] as? String, "fe_oa_abc")
        XCTAssertEqual(claude.first?["prefix"] as? String, "")

        let openAIEntries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodies[2])) as? [[String: Any]]
        )
        XCTAssertEqual(openAIEntries.first?["name"] as? String, openAI.cliProxyProviderName)
        XCTAssertEqual(openAIEntries.first?["prefix"] as? String, "")
        let upstreamKeys = openAIEntries.first?["api-key-entries"] as? [[String: Any]]
        XCTAssertEqual(upstreamKeys?.first?["api-key"] as? String, "upstream-key")

        let payload = bodies.compactMap { $0 }.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(payload.contains("management-key"))
    }

    func testCLIProxyAPIClientSurfacesHTTPFailure() async {
        let session = URLSession(configuration: makeCLIProxyStubConfig())
        CLIProxyURLProtocol.install { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { CLIProxyURLProtocol.reset() }

        do {
            let configuration = try XCTUnwrap(
                CLIProxyAPIConfiguration(profiles: [openAIProfile()], authDirectory: tempDir())
            )
            try await CLIProxyAPIClient(session: session).synchronize(configuration)
            XCTFail("expected HTTP failure")
        } catch let error as CLIProxyAPIClient.ClientError {
            XCTAssertEqual(error, .http(503))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(CLIProxyURLProtocol.requestCount, 1)
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

    @MainActor
    func testNewCustomProfileCanSelectOpenAICompatibility() {
        var profile = freeModelProfile()
        profile.id = "new-profile"
        profile.compatibilityMode = nil
        profile.embeddedLocalProxy = false
        let recorder = CompatibilityProfileRecorder()

        let host = NSHostingView(rootView: CompatibilityPickerHarness(profile: profile, recorder: recorder))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // The picker now exposes the three wire protocols directly:
        // Anthropic / Chat (OpenAI Chat Completions) / Responses.
        func protocolControl() -> NSSegmentedControl? {
            allSubviews(of: host)
                .compactMap { $0 as? NSSegmentedControl }
                .first { $0.segmentCount == 3 && $0.label(forSegment: 0) == "Anthropic" }
        }
        let compatibilityControl = protocolControl()
        XCTAssertNotNil(compatibilityControl)
        XCTAssertEqual(compatibilityControl?.selectedSegment, 0)

        compatibilityControl?.selectedSegment = 1   // OpenAI Chat
        compatibilityControl?.sendAction(compatibilityControl?.action, to: compatibilityControl?.target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(recorder.profile?.compatibility, .openAI)
        XCTAssertEqual(recorder.profile?.compatibilityMode, "openai")
        XCTAssertEqual(recorder.profile?.embeddedLocalProxy, true)
        XCTAssertNil(recorder.profile?.openAIFormat)

        let refreshed = protocolControl()
        refreshed?.selectedSegment = 2   // OpenAI Responses
        refreshed?.sendAction(refreshed?.action, to: refreshed?.target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(recorder.profile?.compatibility, .openAI)
        XCTAssertEqual(recorder.profile?.openAIFormat, "responses")
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
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

private final class CLIProxyURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, Int) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var requests: [URLRequest] = []
    private static var requestBodies: [Data?] = []

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }

    static var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return requestBodies.last ?? nil
    }

    static var allRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static var allBodies: [Data?] {
        lock.lock(); defer { lock.unlock() }
        return requestBodies
    }

    static func install(_ newHandler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
        requests = []
        requestBodies = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = []
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(from: request)
        let handlerAndCount: (Handler?, Int) = Self.locked {
            Self.requests.append(request)
            Self.requestBodies.append(body)
            return (Self.handler, Self.requests.count)
        }
        guard let handler = handlerAndCount.0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request, handlerAndCount.1)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
