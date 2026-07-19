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

    func testClaudeTargetTransferPreservesResponsesUpstream() throws {
        var claude = embeddedClaudeProfile()
        claude.compatibilityMode = BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.openAI.rawValue
        claude.openAIBaseURL = "https://responses.example/v1"
        claude.openAIAPIKey = "responses-secret"
        claude.openAIFormat = "responses"

        let codex = BirdNionConfigStore.makeCodexProfile(from: claude, id: "codex-copy")

        XCTAssertEqual(codex.claudeCodeProfileID, "claude-profile")
        XCTAssertEqual(codex.baseURL, "https://responses.example/v1")
        XCTAssertEqual(codex.apiKey, "responses-secret")
        XCTAssertEqual(codex.upstreamProtocol, .responses)
        XCTAssertEqual(codex.connectionMode, .direct)
    }

    func testCodexTargetTransferKeepsResponsesFormatForClaudeProxy() throws {
        let codex = profile(protocolValue: .responses, connection: .direct)
        var claude = BirdNionConfigStore.makeClaudeCodeProfile(from: codex, id: "claude-copy")
        claude.cliProxyBaseURL = CLIProxyAPIConfiguration.localBaseURL
        claude.cliProxyAPIKey = "claude-local-secret"
        claude.cliProxyManagementKey = "management-secret"
        claude.cliProxyAppliedSignature = claude.cliProxyConfigurationSignature

        XCTAssertEqual(claude.codexProfileID, "profile-1")
        XCTAssertEqual(claude.compatibility, .openAI)
        XCTAssertEqual(claude.openAIProxyFormat, "responses")
        XCTAssertEqual(claude.sonnetModel, "example-model")

        let configuration = try XCTUnwrap(
            CLIProxyAPIConfiguration(
                claudeProfiles: [claude],
                codexProfiles: [],
                authDirectory: FileManager.default.temporaryDirectory
            )
        )
        XCTAssertEqual(configuration.openAICompatibility.first?.format, "responses")
    }

    // MARK: - Linked upstream sync (Claude ↔ Codex)

    func testSyncedCodexProfileFromAnthropicClaude() {
        var claude = embeddedClaudeProfile()
        claude.baseURL = "https://new-anthropic.example"
        claude.token = "new-token"
        claude.compatibilityMode = "anthropic"
        var codex = profile(protocolValue: .responses, connection: .direct)
        codex.model = "keep-me"
        codex.cliProxyAppliedSignature = "stale-sig"

        let (synced, changed) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: codex)

        XCTAssertTrue(changed)
        XCTAssertEqual(synced.baseURL, "https://new-anthropic.example")
        XCTAssertEqual(synced.apiKey, "new-token")
        XCTAssertEqual(synced.upstreamProtocol, .anthropic)
        XCTAssertEqual(synced.connectionMode, .localProxy)
        XCTAssertEqual(synced.model, "keep-me")
        XCTAssertNil(synced.cliProxyAppliedSignature)
    }

    func testSyncedCodexProfileFromOpenAIChatAndResponses() {
        var claude = embeddedClaudeProfile()
        claude.compatibilityMode = "openai"
        claude.openAIBaseURL = "https://chat.example/v1"
        claude.openAIAPIKey = "chat-key"
        claude.openAIFormat = nil

        let chat = profile(protocolValue: .anthropic, connection: .localProxy)
        let (syncedChat, changedChat) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: chat)
        XCTAssertTrue(changedChat)
        XCTAssertEqual(syncedChat.upstreamProtocol, .openAIChat)
        XCTAssertEqual(syncedChat.baseURL, "https://chat.example/v1")
        XCTAssertEqual(syncedChat.apiKey, "chat-key")

        claude.openAIFormat = "responses"
        let responses = profile(protocolValue: .openAIChat, connection: .localProxy)
        let (syncedResponses, changedResponses) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: responses)
        XCTAssertTrue(changedResponses)
        XCTAssertEqual(syncedResponses.upstreamProtocol, .responses)
        // Protocol moved to Codex-native Responses — default to direct so the
        // proxy is only in the path when a translation is actually needed.
        XCTAssertEqual(syncedResponses.connectionMode, .direct)

        // An unchanged protocol preserves an explicit connection choice.
        let keepProxy = profile(protocolValue: .responses, connection: .localProxy)
        let (syncedKeep, _) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: keepProxy)
        XCTAssertEqual(syncedKeep.connectionMode, .localProxy)
    }

    func testSyncedClaudeCodeProfileFromCodexProtocols() {
        var claude = embeddedClaudeProfile()
        claude.haikuModel = "haiku-keep"
        claude.sonnetModel = "sonnet-keep"
        claude.opusModel = "opus-keep"
        claude.extraEnv = [.init(id: "e1", key: "FOO", value: "1")]
        claude.claudeCodeScope = "project"
        claude.cliProxyAppliedSignature = "sig"

        // Anthropic
        var anthropicCodex = profile(protocolValue: .anthropic, connection: .localProxy)
        anthropicCodex.baseURL = "https://a.example"
        anthropicCodex.apiKey = "a-key"
        let (syncedA, changedA) = BirdNionConfigStore.syncedClaudeCodeProfile(from: anthropicCodex, into: claude)
        XCTAssertTrue(changedA)
        XCTAssertEqual(syncedA.baseURL, "https://a.example")
        XCTAssertEqual(syncedA.token, "a-key")
        XCTAssertEqual(syncedA.compatibility, .anthropic)
        XCTAssertEqual(syncedA.haikuModel, "haiku-keep")
        XCTAssertEqual(syncedA.sonnetModel, "sonnet-keep")
        XCTAssertEqual(syncedA.opusModel, "opus-keep")
        XCTAssertEqual(syncedA.extraEnv?.first?.key, "FOO")
        XCTAssertEqual(syncedA.claudeCodeScope, "project")
        XCTAssertNil(syncedA.cliProxyAppliedSignature)

        // OpenAI chat
        var chatCodex = profile(protocolValue: .openAIChat, connection: .localProxy)
        chatCodex.baseURL = "https://chat.example/v1"
        chatCodex.apiKey = "chat-key"
        let (syncedChat, changedChat) = BirdNionConfigStore.syncedClaudeCodeProfile(from: chatCodex, into: claude)
        XCTAssertTrue(changedChat)
        XCTAssertEqual(syncedChat.compatibility, .openAI)
        XCTAssertEqual(syncedChat.openAIBaseURL, "https://chat.example/v1")
        XCTAssertEqual(syncedChat.openAIAPIKey, "chat-key")
        XCTAssertNil(syncedChat.openAIFormat)
        XCTAssertEqual(syncedChat.embeddedLocalProxy, true)
        XCTAssertEqual(syncedChat.sonnetModel, "sonnet-keep")

        // Responses
        var responsesCodex = profile(protocolValue: .responses, connection: .direct)
        responsesCodex.baseURL = "https://resp.example/v1"
        responsesCodex.apiKey = "resp-key"
        let (syncedR, changedR) = BirdNionConfigStore.syncedClaudeCodeProfile(from: responsesCodex, into: claude)
        XCTAssertTrue(changedR)
        XCTAssertEqual(syncedR.openAIFormat, "responses")
        XCTAssertEqual(syncedR.openAIProxyFormat, "responses")
    }

    func testSyncedProfilesIdempotent() {
        var claude = embeddedClaudeProfile()
        claude.compatibilityMode = "openai"
        claude.openAIBaseURL = "https://same.example/v1"
        claude.openAIAPIKey = "same-key"
        claude.openAIFormat = "responses"
        claude.embeddedLocalProxy = true

        var codex = profile(protocolValue: .responses, connection: .direct)
        codex.baseURL = "https://same.example/v1"
        codex.apiKey = "same-key"
        codex.cliProxyAppliedSignature = "keep-sig"

        let (syncedCodex, changedCodex) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: codex)
        XCTAssertFalse(changedCodex)
        XCTAssertEqual(syncedCodex.cliProxyAppliedSignature, "keep-sig")

        claude.cliProxyAppliedSignature = "claude-sig"
        let (syncedClaude, changedClaude) = BirdNionConfigStore.syncedClaudeCodeProfile(from: codex, into: claude)
        XCTAssertFalse(changedClaude)
        XCTAssertEqual(syncedClaude.cliProxyAppliedSignature, "claude-sig")

        // Round-trip still idempotent after first apply
        let (again, changedAgain) = BirdNionConfigStore.syncedCodexProfile(from: claude, into: syncedCodex)
        XCTAssertFalse(changedAgain)
    }

    func testSaveClaudeCodeProfileMirrorsLinkedCodex() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var claude = embeddedClaudeProfile()
        claude.codexProfileID = "profile-1"
        claude.baseURL = "https://orig-claude.example"
        claude.token = "orig-token"
        claude.compatibilityMode = "anthropic"
        claude.sonnetModel = "claude-sonnet-only"

        var codex = profile(protocolValue: .responses, connection: .direct)
        codex.claudeCodeProfileID = claude.id
        codex.baseURL = "https://old-codex.example"
        codex.apiKey = "old-key"
        codex.model = "codex-model-only"
        codex.cliProxyAppliedSignature = "applied"

        try BirdNionConfigStore.saveClaudeCodeProfile(claude, url: url)
        try BirdNionConfigStore.saveCodexProfile(codex, url: url)

        // Edit Claude upstream and save — Codex should pick it up
        claude.baseURL = "https://mirrored.example"
        claude.token = "mirrored-token"
        try BirdNionConfigStore.saveClaudeCodeProfile(claude, url: url)

        let storedCodex = try XCTUnwrap(BirdNionConfigStore.codexProfiles(url: url).first { $0.id == "profile-1" })
        XCTAssertEqual(storedCodex.baseURL, "https://mirrored.example")
        XCTAssertEqual(storedCodex.apiKey, "mirrored-token")
        XCTAssertEqual(storedCodex.upstreamProtocol, .anthropic)
        XCTAssertEqual(storedCodex.model, "codex-model-only")
        XCTAssertNil(storedCodex.cliProxyAppliedSignature)

        // Reverse: edit Codex → Claude mirrors, model tiers untouched
        var updatedCodex = storedCodex
        updatedCodex.baseURL = "https://from-codex.example"
        updatedCodex.apiKey = "from-codex-key"
        updatedCodex.upstreamProtocolRaw = BirdNionConfigStore.CodexProfile.UpstreamProtocol.openAIChat.rawValue
        updatedCodex.connectionModeRaw = BirdNionConfigStore.CodexProfile.ConnectionMode.localProxy.rawValue
        try BirdNionConfigStore.saveCodexProfile(updatedCodex, url: url)

        let storedClaude = try XCTUnwrap(BirdNionConfigStore.claudeCodeProfiles(url: url).first { $0.id == claude.id })
        XCTAssertEqual(storedClaude.compatibility, .openAI)
        XCTAssertEqual(storedClaude.openAIBaseURL, "https://from-codex.example")
        XCTAssertEqual(storedClaude.openAIAPIKey, "from-codex-key")
        XCTAssertNil(storedClaude.openAIFormat)
        XCTAssertEqual(storedClaude.sonnetModel, "claude-sonnet-only")
        XCTAssertNil(storedClaude.cliProxyAppliedSignature)

        // Second save with same values is a no-op on the peer (idempotent)
        let before = try XCTUnwrap(BirdNionConfigStore.codexProfiles(url: url).first { $0.id == "profile-1" })
        try BirdNionConfigStore.saveClaudeCodeProfile(storedClaude, url: url)
        let after = try XCTUnwrap(BirdNionConfigStore.codexProfiles(url: url).first { $0.id == "profile-1" })
        XCTAssertEqual(before, after)
    }

    // MARK: - Per-project profile files

    func testProfileFlagNameSanitizesDisplayName() {
        var p = profile()
        p.name = "virouter 25$"
        XCTAssertEqual(CodexConfigWriter.profileFlagName(for: p), "bn-virouter-25")
        p.name = "  ---  "
        XCTAssertEqual(CodexConfigWriter.profileFlagName(for: p), "bn-profile-")
    }

    func testWriteProfileFileCreatesOverlayAndTracksState() throws {
        let url = tempConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let p = profile()
        let flag = try CodexConfigWriter.writeProfileFile(for: p, configURL: url)
        XCTAssertEqual(flag, "bn-virouter")
        XCTAssertEqual(CodexConfigWriter.profileFlag(forProfileID: p.id, configURL: url), "bn-virouter")

        let overlay = url.deletingLastPathComponent().appendingPathComponent("bn-virouter.config.toml")
        let contents = try String(contentsOf: overlay, encoding: .utf8)
        XCTAssertTrue(contents.contains("model = \"example-model\""))
        XCTAssertTrue(contents.contains("wire_api = \"responses\""))
    }

    func testWriteProfileFileRenameRemovesPreviousOverlay() throws {
        let url = tempConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var p = profile()
        _ = try CodexConfigWriter.writeProfileFile(for: p, configURL: url)
        p.name = "Renamed"
        let flag = try CodexConfigWriter.writeProfileFile(for: p, configURL: url)
        XCTAssertEqual(flag, "bn-renamed")

        let dir = url.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bn-virouter.config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bn-renamed.config.toml").path))
    }

    func testRemoveProfileFileDeletesOverlayAndMapping() throws {
        let url = tempConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let p = profile()
        _ = try CodexConfigWriter.writeProfileFile(for: p, configURL: url)
        CodexConfigWriter.removeProfileFile(profileID: p.id, configURL: url)

        XCTAssertNil(CodexConfigWriter.profileFlag(forProfileID: p.id, configURL: url))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().appendingPathComponent("bn-virouter.config.toml").path))
    }
}
