import XCTest
@testable import BirdNion

final class CodexConfigWriterTests: XCTestCase {
    private func tempConfigURL() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-config-\(UUID().uuidString)", isDirectory: true)
        return root.appendingPathComponent(".codex/config.toml")
    }

    private func profile(protocolValue: BirdNionConfigStore.CodexProfile.UpstreamProtocol = .responses,
                         connection: BirdNionConfigStore.CodexProfile.ConnectionMode = .direct) -> BirdNionConfigStore.CodexProfile {
        BirdNionConfigStore.CodexProfile(
            id: "profile-1",
            name: "Virouter",
            baseURL: "https://api.example.com/v1",
            apiKey: "upstream-secret",
            model: "example-model",
            upstreamProtocolRaw: protocolValue.rawValue,
            connectionModeRaw: connection.rawValue,
            cliProxyBaseURL: "http://127.0.0.1:24323",
            cliProxyAPIKey: "local-secret",
            cliProxyManagementKey: "management-secret",
            cliProxyAppliedSignature: "proxy-signature"
        )
    }

    private func embeddedClaudeProfile() -> BirdNionConfigStore.ClaudeCodeProfile {
        var profile = BirdNionConfigStore.ClaudeCodeProfile(
            id: "claude-profile",
            name: "Claude upstream",
            baseURL: "https://anthropic.example/v1",
            token: "claude-upstream-secret",
            tokenEnvKey: "ANTHROPIC_AUTH_TOKEN",
            apiKeyHelper: nil,
            haikuModel: "claude-haiku",
            sonnetModel: "claude-sonnet",
            opusModel: "claude-opus",
            extraEnv: nil
        )
        profile.embeddedLocalProxy = true
        profile.cliProxyBaseURL = "http://127.0.0.1:24323"
        profile.cliProxyAPIKey = "claude-local-secret"
        profile.cliProxyManagementKey = "management-secret"
        profile.cliProxyAppliedSignature = profile.cliProxyConfigurationSignature
        return profile
    }

    func testDirectApplyPreservesOtherConfigAndRestoresRootSelection() throws {
        let url = tempConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        model = "old-model"
        model_provider = "old-provider"
        approval_policy = "on-request"

        [mcp_servers.docs]
        url = "https://example.com/mcp"
        """
        try original.data(using: .utf8)!.write(to: url)

        let profile = profile()
        try CodexConfigWriter.apply(profile: profile, configURL: url)

        let applied = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(applied.contains("model = \"example-model\""))
        XCTAssertTrue(applied.contains("model_provider = \"birdnion-codex-profile-1\""))
        XCTAssertTrue(applied.contains("base_url = \"https://api.example.com/v1\""))
        XCTAssertTrue(applied.contains("experimental_bearer_token = \"upstream-secret\""))
        XCTAssertTrue(applied.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(applied.contains("[mcp_servers.docs]"))
        XCTAssertTrue(CodexConfigWriter.isApplied(profile, configURL: url))

        XCTAssertTrue(try CodexConfigWriter.deactivate(configURL: url))
        let restored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(restored.contains("model = \"old-model\""))
        XCTAssertTrue(restored.contains("model_provider = \"old-provider\""))
        XCTAssertFalse(restored.contains("BirdNion Codex provider"))
        XCTAssertTrue(restored.contains("[mcp_servers.docs]"))
    }

    func testProxyApplyUsesLoopbackCredentialRatherThanUpstreamCredential() throws {
        let url = tempConfigURL()
        var profile = profile(protocolValue: .anthropic, connection: .localProxy)
        profile.cliProxyAppliedSignature = profile.cliProxyConfigurationSignature

        try CodexConfigWriter.apply(profile: profile, configURL: url)
        let applied = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(applied.contains("base_url = \"http://127.0.0.1:24323/v1\""))
        XCTAssertTrue(applied.contains("experimental_bearer_token = \"local-secret\""))
        XCTAssertFalse(applied.contains("experimental_bearer_token = \"upstream-secret\""))
        XCTAssertTrue(applied.contains("wire_api = \"responses\""))
    }

    func testDeactivateDoesNotRecreateAUserRemovedConfig() throws {
        let url = tempConfigURL()
        let profile = profile()
        try CodexConfigWriter.apply(profile: profile, configURL: url)
        try FileManager.default.removeItem(at: url)

        XCTAssertFalse(try CodexConfigWriter.deactivate(configURL: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNonResponsesProtocolRequiresLocalProxy() {
        let chat = profile(protocolValue: .openAIChat, connection: .direct)
        let anthropic = profile(protocolValue: .anthropic, connection: .direct)
        let responses = profile(protocolValue: .responses, connection: .direct)

        XCTAssertTrue(chat.usesEmbeddedCLIProxy)
        XCTAssertTrue(anthropic.usesEmbeddedCLIProxy)
        XCTAssertFalse(responses.usesEmbeddedCLIProxy)
    }

    @MainActor
    func testProxyProfileIsActiveOnlyWhileTheLocalProxyRuns() {
        var proxy = profile(protocolValue: .openAIChat, connection: .localProxy)
        proxy.cliProxyAppliedSignature = proxy.cliProxyConfigurationSignature
        let direct = profile(protocolValue: .responses, connection: .direct)

        XCTAssertTrue(EmbeddedCLIProxyService.isProfileRunning(proxy, runtimeState: .running))
        XCTAssertFalse(EmbeddedCLIProxyService.isProfileRunning(proxy, runtimeState: .stopped))
        XCTAssertFalse(EmbeddedCLIProxyService.isProfileRunning(direct, runtimeState: .running))
    }

    func testResponsesProxyWritesResponsesUpstreamFormat() throws {
        var profile = profile(protocolValue: .responses, connection: .localProxy)
        profile.cliProxyAppliedSignature = profile.cliProxyConfigurationSignature
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(
                claudeProfiles: [],
                codexProfiles: [profile],
                authDirectory: FileManager.default.temporaryDirectory
            )
        )
        let yaml = try XCTUnwrap(String(data: configuration.yamlData(), encoding: .utf8))

        XCTAssertEqual(configuration.openAICompatibility.first?.format, "responses")
        XCTAssertTrue(yaml.contains("format: \"responses\""))
        XCTAssertTrue(yaml.contains("name: \"example-model\""))
        XCTAssertTrue(yaml.contains("alias: \"example-model\""))
    }

    func testSharedProxyCanRegisterOneClaudeAndOneCodexProfile() throws {
        var codex = profile(protocolValue: .responses, connection: .localProxy)
        codex.cliProxyAppliedSignature = codex.cliProxyConfigurationSignature
        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(
                claudeProfiles: [embeddedClaudeProfile()],
                codexProfiles: [codex],
                authDirectory: FileManager.default.temporaryDirectory
            )
        )
        let yaml = try XCTUnwrap(String(data: configuration.yamlData(), encoding: .utf8))

        XCTAssertEqual(configuration.apiKeys, ["claude-local-secret", "local-secret"])
        XCTAssertEqual(configuration.claudeAPIKeys.count, 1)
        XCTAssertEqual(configuration.openAICompatibility.count, 1)
        XCTAssertTrue(yaml.contains("claude-api-key:"))
        XCTAssertTrue(yaml.contains("openai-compatibility:"))
    }
}
