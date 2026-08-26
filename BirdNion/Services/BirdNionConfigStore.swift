import Foundation
import CryptoKit
import Darwin

@_silgen_name("flock")
func birdNionFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Single source of truth for all BirdNion configuration: provider tokens,
/// enable flags, per-provider metadata (region, base URL, display name,
/// account label). Replaces the prior split of
/// `CodexBarConfigStore` + `ProvidersStore` + `KeychainService` so the
/// file at `~/.config/birdnion/settings.json` is the only place secrets live.
///
/// Path priority (mirrors CodexBar's resolution):
///   `BIRDNION_CONFIG` env → `XDG_CONFIG_HOME/birdnion/settings.json` →
///   `~/.config/birdnion/settings.json` → legacy `~/.birdnion/settings.json`.
///
/// Schema mirrors CodexBar's array-of-providers shape so the file format
/// stays familiar to anyone migrating from CodexBar:
/// ```json
/// {
///   "version": 1,
///   "providers": [
///     { "id": "minimax", "apiKey": "sk-…", "enabled": true, "region": "io",
///       "baseURL": null, "displayName": null, "accountLabel": null }
///   ]
/// }
/// ```
enum BirdNionConfigStore {
    static let pathEnvKey = "BIRDNION_CONFIG"
    private static let maximumSettingsBytes = 8 * 1024 * 1024

    /// Resolve the config file URL. Test-friendly: home/env/fileManager are
    /// injectable so unit tests can point at a temp directory without
    /// touching the real `~/.config/birdnion/`.
    static func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          env: [String: String] = ProcessInfo.processInfo.environment,
                          fileManager: FileManager = .default) -> URL {
        if let override = env[pathEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let xdg = env["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty, (xdg as NSString).isAbsolutePath {
            return URL(fileURLWithPath: xdg).appendingPathComponent("birdnion/settings.json")
        }
        let xdgDefault = home.appendingPathComponent(".config/birdnion/settings.json")
        let legacy = home.appendingPathComponent(".birdnion/settings.json")
        if fileManager.fileExists(atPath: xdgDefault.path) { return xdgDefault }
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return xdgDefault
    }

    // MARK: - Schema

    struct Config: Codable {
        var version: Int?
        /// Shared optimistic-concurrency token. Linux treats a missing value
        /// as revision zero; every successful macOS mutation advances it.
        var settingsRevision: UInt64? = nil
        var providers: [Provider]?
        /// User-defined Claude Code backends (Settings → "Claude Code" → Custom).
        var claudeCodeProfiles: [ClaudeCodeProfile]?
        /// User-defined third-party Codex CLI backends (Settings → "Codex").
        var codexProfiles: [CodexProfile]?
    }

    /// One third-party backend for Codex CLI. Codex only speaks the OpenAI
    /// Responses protocol, so non-Responses upstreams use BirdNion's embedded
    /// CLIProxyAPI conversion service.
    struct CodexProfile: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var baseURL: String
        var apiKey: String
        var model: String
        /// `responses`, `openai-chat`, or `anthropic`. Nil is migrated to the
        /// safe direct default because it matches Codex's native wire protocol.
        var upstreamProtocolRaw: String? = nil
        /// `direct` or `local-proxy`. Non-Responses upstreams always resolve
        /// to local proxy even if an older profile omitted this field.
        var connectionModeRaw: String? = nil
        var cliProxyBaseURL: String? = nil
        var cliProxyAPIKey: String? = nil
        var cliProxyManagementKey: String? = nil
        var cliProxyAppliedSignature: String? = nil
        /// Optional link to the Claude Code configuration created from the same
        /// upstream. Keeping each agent's settings independent avoids one CLI
        /// overwriting the other while still making the target switch reversible.
        var claudeCodeProfileID: String? = nil

        enum UpstreamProtocol: String, CaseIterable, Identifiable {
            case responses
            case openAIChat = "openai-chat"
            case anthropic

            var id: String { rawValue }
        }

        enum ConnectionMode: String, CaseIterable, Identifiable {
            case direct
            case localProxy = "local-proxy"

            var id: String { rawValue }
        }

        var upstreamProtocol: UpstreamProtocol {
            UpstreamProtocol(rawValue: upstreamProtocolRaw ?? "") ?? .responses
        }

        var requiresEmbeddedCLIProxy: Bool {
            upstreamProtocol != .responses
        }

        var connectionMode: ConnectionMode {
            if requiresEmbeddedCLIProxy { return .localProxy }
            return ConnectionMode(rawValue: connectionModeRaw ?? "") ?? .direct
        }

        var usesEmbeddedCLIProxy: Bool {
            connectionMode == .localProxy
        }

        var hasUpstreamConfiguration: Bool {
            BirdNionConfigStore.cleaned(baseURL) != nil
                && BirdNionConfigStore.cleaned(apiKey) != nil
                && BirdNionConfigStore.cleaned(model) != nil
        }

        var cliProxyProviderName: String {
            let safeID = id.lowercased().unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
            }.joined()
            return "birdnion-codex-\(safeID)"
        }

        var normalizedCLIProxyBaseURL: String? {
            guard let raw = BirdNionConfigStore.cleaned(cliProxyBaseURL),
                  var components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host != nil else { return nil }
            var path = components.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == "/v1" { path = "" }
            components.path = path
            components.query = nil
            components.fragment = nil
            return components.string
        }

        var isEmbeddedCLIProxyReady: Bool {
            normalizedCLIProxyBaseURL != nil
                && hasUpstreamConfiguration
                && BirdNionConfigStore.cleaned(cliProxyAPIKey) != nil
                && BirdNionConfigStore.cleaned(cliProxyManagementKey) != nil
        }

        var cliProxyConfigurationSignature: String? {
            guard usesEmbeddedCLIProxy,
                  let proxyBaseURL = normalizedCLIProxyBaseURL,
                  let baseURL = BirdNionConfigStore.cleaned(baseURL),
                  let apiKey = BirdNionConfigStore.cleaned(apiKey),
                  let model = BirdNionConfigStore.cleaned(model),
                  let proxyAPIKey = BirdNionConfigStore.cleaned(cliProxyAPIKey),
                  let managementKey = BirdNionConfigStore.cleaned(cliProxyManagementKey)
            else { return nil }
            let material = [
                "codex-proxy-v1",
                cliProxyProviderName,
                upstreamProtocol.rawValue,
                proxyBaseURL,
                baseURL,
                apiKey,
                model,
                proxyAPIKey,
                managementKey,
            ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        var isCLIProxyConfigurationCurrent: Bool {
            guard let signature = cliProxyConfigurationSignature else { return false }
            return signature == cliProxyAppliedSignature
        }

        /// Marker used by the Codex config writer to distinguish a saved draft
        /// from the provider/model values that are actually active in Codex.
        var codexConfigurationSignature: String? {
            guard let model = BirdNionConfigStore.cleaned(model) else { return nil }
            let endpoint: String
            let token: String
            if usesEmbeddedCLIProxy {
                guard let base = normalizedCLIProxyBaseURL,
                      let key = BirdNionConfigStore.cleaned(cliProxyAPIKey) else { return nil }
                endpoint = base + "/v1"
                token = key
            } else {
                guard let base = BirdNionConfigStore.cleaned(baseURL),
                      let key = BirdNionConfigStore.cleaned(apiKey) else { return nil }
                endpoint = base
                token = key
            }
            let material = [
                "codex-config-v1",
                cliProxyProviderName,
                model,
                endpoint,
                token,
            ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// One user-defined Claude Code backend. Unlike the built-in provider
    /// presets (which derive their base URL from `ClaudeCodeBackend`), a profile
    /// carries everything explicitly so any Anthropic-compatible endpoint shape
    /// can be expressed: the token env-key can be `ANTHROPIC_API_KEY` or
    /// `ANTHROPIC_AUTH_TOKEN`, an optional top-level `apiKeyHelper`, and an
    /// arbitrary list of extra env pairs (e.g. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`).
    struct ClaudeCodeProfile: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var baseURL: String
        var token: String
        /// Which env var receives the token: "ANTHROPIC_AUTH_TOKEN" (default) or
        /// "ANTHROPIC_API_KEY".
        var tokenEnvKey: String
        /// Optional top-level `apiKeyHelper` shell command (sibling of `env`).
        var apiKeyHelper: String?
        var haikuModel: String?
        var sonnetModel: String?
        var opusModel: String?
        /// Last selected Claude Code target for this custom profile:
        /// "global" or "project". Optional keeps older config files valid.
        var claudeCodeScope: String?
        /// Last selected project directory path for this profile when using
        /// project scope. Preserved even when the current scope is global so
        /// switching back to project can restore the previous folder.
        var claudeCodeProjectPath: String?
        /// Arbitrary extra env pairs merged verbatim into the `env` block.
        var extraEnv: [ClaudeCodeEnvPair]?
        /// Nil preserves profiles created before protocol selection existed.
        /// Values are currently "anthropic" and "openai".
        var compatibilityMode: String? = nil
        /// OpenAI-compatible upstream configuration. These values are sent only
        /// to BirdNion's embedded CLIProxyAPI core, never to Claude Code settings.
        var openAIBaseURL: String? = nil
        var openAIAPIKey: String? = nil
        /// `responses` preserves an OpenAI Responses upstream when this profile
        /// was created from a Codex configuration. Nil retains the established
        /// OpenAI Chat-compatible behavior.
        var openAIFormat: String? = nil
        /// Explicitly marks a profile as managed by BirdNion's embedded local
        /// proxy. Nil keeps old Anthropic profiles on their direct path, while
        /// older OpenAI profiles migrate automatically on their next apply.
        var embeddedLocalProxy: Bool? = nil
        /// Internal credentials for BirdNion's loopback CLIProxyAPI core. The
        /// local API key is written to Claude Code; the management key remains
        /// inside BirdNion's restricted configuration file.
        var cliProxyBaseURL: String? = nil
        var cliProxyAPIKey: String? = nil
        var cliProxyManagementKey: String? = nil
        /// SHA-256 marker of the last CLIProxyAPI registration. It makes an
        /// upstream-only edit visibly stale without storing another plaintext
        /// copy of any secret.
        var cliProxyAppliedSignature: String? = nil
        /// Optional link to the Codex configuration created from this upstream.
        var codexProfileID: String? = nil
        /// Last selected AI Coding agent for this profile (`AICodingAgent` rawValue:
        /// "claudeCode" or "codex"). Optional keeps older config files valid.
        var preferredAgent: String? = nil

        enum CompatibilityMode: String, CaseIterable, Identifiable {
            case anthropic
            case openAI = "openai"

            var id: String { rawValue }
        }

        var compatibility: CompatibilityMode {
            CompatibilityMode(rawValue: compatibilityMode ?? "") ?? .anthropic
        }

        var isOpenAICompatible: Bool { compatibility == .openAI }

        /// Profiles created before the compatibility selector was made reliable
        /// stored their OpenAI upstream in the legacy base URL/token fields while
        /// already opting into BirdNion's local proxy. Promote that combination
        /// once when the profile is opened, preserving the original values.
        @discardableResult
        mutating func migrateLegacyLocalProxyToOpenAIIfNeeded() -> Bool {
            guard compatibilityMode == nil, embeddedLocalProxy == true else { return false }

            compatibilityMode = CompatibilityMode.openAI.rawValue
            if BirdNionConfigStore.cleaned(openAIBaseURL) == nil {
                openAIBaseURL = BirdNionConfigStore.cleaned(baseURL)
            }
            if BirdNionConfigStore.cleaned(openAIAPIKey) == nil {
                openAIAPIKey = BirdNionConfigStore.cleaned(token)
            }
            return true
        }

        /// New profiles persist their proxy choice explicitly. Older OpenAI
        /// profiles without that choice preserve their original local-proxy path.
        var usesEmbeddedCLIProxy: Bool {
            embeddedLocalProxy ?? isOpenAICompatible
        }

        var upstreamBaseURL: String? {
            isOpenAICompatible
                ? BirdNionConfigStore.cleaned(openAIBaseURL) ?? BirdNionConfigStore.cleaned(baseURL)
                : BirdNionConfigStore.cleaned(baseURL)
        }

        var upstreamAPIKey: String? {
            isOpenAICompatible
                ? BirdNionConfigStore.cleaned(openAIAPIKey) ?? BirdNionConfigStore.cleaned(token)
                : BirdNionConfigStore.cleaned(token)
        }

        var hasUpstreamConfiguration: Bool {
            upstreamBaseURL != nil && upstreamAPIKey != nil
        }

        /// Stable per-profile ownership marker for CLIProxyAPI configuration.
        /// It is never exposed in the model names written to Claude Code.
        var cliProxyProviderName: String {
            let safeID = id.lowercased().unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
            }.joined()
            return "birdnion-\(safeID)"
        }

        var normalizedCLIProxyBaseURL: String? {
            guard let raw = BirdNionConfigStore.cleaned(cliProxyBaseURL),
                  var components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host != nil else { return nil }
            var path = components.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == "/v1" { path = "" }
            components.path = path
            components.query = nil
            components.fragment = nil
            return components.string
        }

        var openAIModelNames: [String] {
            [haikuModel, sonnetModel, opusModel].compactMap(BirdNionConfigStore.cleaned)
        }

        var openAIProxyFormat: String? {
            openAIFormat == "responses" ? "responses" : nil
        }

        var isEmbeddedCLIProxyReady: Bool {
            guard normalizedCLIProxyBaseURL != nil,
                  hasUpstreamConfiguration,
                  BirdNionConfigStore.cleaned(cliProxyAPIKey) != nil,
                  BirdNionConfigStore.cleaned(cliProxyManagementKey) != nil else { return false }
            return true
        }

        /// Compatibility alias retained for the previous OpenAI-only flow.
        var isOpenAIProxyReady: Bool {
            usesEmbeddedCLIProxy && isEmbeddedCLIProxyReady
        }

        var cliProxyConfigurationSignature: String? {
            guard usesEmbeddedCLIProxy,
                  let proxyBaseURL = normalizedCLIProxyBaseURL,
                  let upstreamBaseURL,
                  let upstreamAPIKey,
                  let proxyAPIKey = BirdNionConfigStore.cleaned(cliProxyAPIKey),
                  let managementKey = BirdNionConfigStore.cleaned(cliProxyManagementKey) else { return nil }
            let material = ([
                "direct-models-v1",
                cliProxyProviderName,
                compatibility.rawValue,
                openAIProxyFormat ?? "openai-chat",
                proxyBaseURL,
                upstreamBaseURL,
                upstreamAPIKey,
                proxyAPIKey,
                managementKey,
            ] + openAIModelNames).map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        var isCLIProxyConfigurationCurrent: Bool {
            guard let signature = cliProxyConfigurationSignature else { return false }
            return signature == cliProxyAppliedSignature
        }

        func cliProxyModelAlias(for model: String) -> String {
            // The local endpoint receives model names directly. CLIProxyAPI
            // still needs an internal alias for Claude Code's `[1m]` handling.
            CLIProxyAPIConfiguration.localModelAlias(for: model)
        }
    }

    /// A single key=value env entry for a `ClaudeCodeProfile`.
    struct ClaudeCodeEnvPair: Codable, Equatable, Identifiable {
        var id: String
        var key: String
        var value: String
    }

    /// Creates a Codex configuration from a custom Claude Code backend. The
    /// agent-specific model settings stay separate; only the upstream source is
    /// copied so users can configure both CLIs without re-entering credentials.
    static func makeCodexProfile(from claude: ClaudeCodeProfile,
                                 id: String = UUID().uuidString) -> CodexProfile {
        let upstreamProtocol: CodexProfile.UpstreamProtocol
        switch claude.compatibility {
        case .anthropic:
            upstreamProtocol = .anthropic
        case .openAI:
            upstreamProtocol = claude.openAIProxyFormat == "responses" ? .responses : .openAIChat
        }

        return CodexProfile(
            id: id,
            name: claude.name,
            baseURL: claude.upstreamBaseURL ?? "",
            apiKey: claude.upstreamAPIKey ?? "",
            model: cleaned(claude.sonnetModel) ?? cleaned(claude.haikuModel) ?? cleaned(claude.opusModel) ?? "",
            upstreamProtocolRaw: upstreamProtocol.rawValue,
            connectionModeRaw: upstreamProtocol == .responses
                ? CodexProfile.ConnectionMode.direct.rawValue
                : CodexProfile.ConnectionMode.localProxy.rawValue,
            claudeCodeProfileID: claude.id
        )
    }

    /// Creates a Claude Code configuration from a Codex backend. OpenAI
    /// Responses is kept as an explicit proxy format so the embedded helper
    /// forwards requests using the upstream's real wire protocol.
    static func makeClaudeCodeProfile(from codex: CodexProfile,
                                      id: String = UUID().uuidString) -> ClaudeCodeProfile {
        let isAnthropic = codex.upstreamProtocol == .anthropic
        let model = cleaned(codex.model)
        return ClaudeCodeProfile(
            id: id,
            name: codex.name,
            baseURL: isAnthropic ? codex.baseURL : "",
            token: isAnthropic ? codex.apiKey : "",
            tokenEnvKey: "ANTHROPIC_AUTH_TOKEN",
            apiKeyHelper: nil,
            haikuModel: nil,
            sonnetModel: model,
            opusModel: nil,
            extraEnv: nil,
            compatibilityMode: isAnthropic
                ? ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
                : ClaudeCodeProfile.CompatibilityMode.openAI.rawValue,
            openAIBaseURL: isAnthropic ? nil : codex.baseURL,
            openAIAPIKey: isAnthropic ? nil : codex.apiKey,
            openAIFormat: codex.upstreamProtocol == .responses ? "responses" : nil,
            embeddedLocalProxy: isAnthropic ? false : true,
            codexProfileID: codex.id
        )
    }

    /// Pure upstream sync Claude → linked Codex. Never touches `model` (per-agent).
    /// Returns the updated profile and whether any upstream field actually changed.
    static func syncedCodexProfile(from claude: ClaudeCodeProfile,
                                   into codex: CodexProfile) -> (CodexProfile, Bool) {
        var updated = codex
        let newBase = claude.upstreamBaseURL ?? ""
        let newKey = claude.upstreamAPIKey ?? ""
        let newProtocol: CodexProfile.UpstreamProtocol
        switch claude.compatibility {
        case .anthropic:
            newProtocol = .anthropic
        case .openAI:
            newProtocol = claude.openAIProxyFormat == "responses" ? .responses : .openAIChat
        }

        let protocolChanged = updated.upstreamProtocol != newProtocol
        updated.baseURL = newBase
        updated.apiKey = newKey
        updated.upstreamProtocolRaw = newProtocol.rawValue
        if protocolChanged {
            // Codex natively speaks Responses, so that protocol defaults to a
            // direct connection; every other protocol needs the proxy. Only a
            // protocol CHANGE resets the mode — an explicit direct/proxy
            // choice on an unchanged protocol is preserved.
            updated.connectionModeRaw = newProtocol == .responses
                ? CodexProfile.ConnectionMode.direct.rawValue
                : CodexProfile.ConnectionMode.localProxy.rawValue
        }

        let changed = updated.baseURL != codex.baseURL
            || updated.apiKey != codex.apiKey
            || updated.upstreamProtocol != codex.upstreamProtocol
            || updated.connectionModeRaw != codex.connectionModeRaw
        if !changed { return (codex, false) }
        updated.cliProxyAppliedSignature = nil
        return (updated, true)
    }

    /// One provider's configuration. Fields are all optional so partial
    /// entries are valid (e.g. just an apiKey without enabled).
    struct Provider: Codable, Equatable {
        var id: String
        var apiKey: String?
        var enabled: Bool?
        var region: String?
        var budget: Double?
        /// Deepgram project ID — when set, fetch only that project; blank = aggregate all.
        var projectID: String?
        /// Bedrock AWS secret access key (paired with `apiKey` = access key ID).
        var secretKey: String?
        /// Bedrock auth mode: "keys" (static access keys) or "profile" (named AWS profile).
        var awsAuthMode: String?
        /// Bedrock named AWS profile (when `awsAuthMode == "profile"`).
        var awsProfile: String?
        var baseURL: String?
        var displayName: String?
        var accountLabel: String?
        /// Reserved for future use (e.g. Claude cookie paste from DevTools).
        var cookieHeader: String?

        /// Claude Code env config (Settings → "Claude Code" tab). The chosen
        /// model ids per tier are written to `ANTHROPIC_DEFAULT_*_MODEL` in the
        /// Claude Code `settings.json`. Persisted per provider so the popover
        /// quick-apply button knows this provider is fully configured and can
        /// re-apply without reopening the config screen. Nil = not yet chosen.
        var claudeHaikuModel: String?
        var claudeSonnetModel: String?
        var claudeOpusModel: String?
        /// Maps to `CLAUDE_CODE_DISABLE_1M_CONTEXT` ("1" when true). Nil/false = unset.
        var claudeDisable1M: Bool?
        /// Last selected Claude Code target for this provider: "global" or
        /// "project". Stored per provider so the popover quick action matches
        /// what the user chose in Settings for that provider.
        var claudeCodeScope: String?
        /// Last selected project directory path for this provider. Preserved
        /// across global/project toggles and independent from other providers.
        var claudeCodeProjectPath: String?
        /// Derived Codex record backing this preset through the embedded
        /// proxy (Anthropic wire protocol). Nil until the user targets Codex.
        var codexProfileID: String?
        /// Last selected AI Coding agent for this provider (`AICodingAgent` rawValue:
        /// "claudeCode" or "codex"). Optional keeps older config files valid.
        var preferredAgent: String? = nil

        /// Default value used when a provider entry has no `enabled` flag.
        /// First-run user-revision (2026-06-25): opt-in, so default off.
        var defaultEnabled: Bool { false }
    }

    // MARK: - Read

    /// First-run default document. All providers disabled (opt-in),
    /// mirrors the prior `ProvidersStore.defaultDocument` shape so
    /// the Settings sidebar always shows the canonical provider list
    /// and the user can opt in via toggles. Metadata (displayName,
    /// baseURL for hapo) is preserved — it's not auth state.
    static let defaultDocument: Config = {
        Config(providers: [
            Provider(id: "minimax", enabled: false),
            Provider(id: "codex", enabled: false),
            Provider(id: "hapo", enabled: false,
                     displayName: "AI Hub"),
            Provider(id: "openrouter", enabled: false),
            Provider(id: "tryapi", enabled: false),
            Provider(id: "deepseek", enabled: false),
            Provider(id: "zai", enabled: false),
            Provider(id: "claude", enabled: false),
            Provider(id: "elevenlabs", enabled: false),
            Provider(id: "deepgram", enabled: false),
            Provider(id: "groq", enabled: false),
            Provider(id: "grok", enabled: false),
            Provider(id: "xai", enabled: false),
            Provider(id: "openai", enabled: false),
            Provider(id: "ollama", enabled: false),
            Provider(id: "copilot", enabled: false),
            Provider(id: "kilo", enabled: false),
            Provider(id: "commandcode", enabled: false),
            Provider(id: "mimo", enabled: false),
            Provider(id: "alibaba", enabled: false),
            Provider(id: "cursor", enabled: false),
            Provider(id: "gemini", enabled: false),
            Provider(id: "kiro", enabled: false),
            Provider(id: "opencode", enabled: false),
            Provider(id: "opencodego", enabled: false),
            Provider(id: "antigravity", enabled: false),
            Provider(id: "bedrock", enabled: false),
            Provider(id: "freemodel", enabled: false),
            Provider(id: "hiyo", enabled: false)
        ])
    }()

    static func read(url: URL = configURL()) -> Config? {
        do {
            return try readChecked(url: url)
        } catch {
            return nil
        }
    }

    /// Authoritative read: `nil` means the locked, bound settings route was
    /// verified absent. Malformed, unsafe, recovery, route, and I/O failures
    /// remain errors so Settings cannot mistake them for first-run state.
    static func readChecked(url: URL = configURL()) throws -> Config? {
        try readLocked(url: url, afterLock: nil)
    }

#if DEBUG
    static func readForTesting(
        url: URL,
        afterLock: @escaping () throws -> Void
    ) -> Config? {
        try? readLocked(url: url, afterLock: afterLock)
    }
#endif

    private static func readLocked(
        url: URL,
        afterLock: (() throws -> Void)?
    ) throws -> Config? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let transaction = try SettingsTransaction(settingsURL: url)
        try afterLock?()
        try transaction.file.ensureCurrentRoute()
        try recoverConditionalBackup(file: transaction.file)
        guard let data = try readRegularFileBounded(
            file: transaction.file,
            name: transaction.file.name)
        else {
            try transaction.file.ensureCurrentRoute()
            return nil
        }
        guard !data.isEmpty, let config = try? JSONDecoder().decode(Config.self, from: data) else {
            throw ConfigStoreError.malformedExistingFile(path: url.path)
        }
        try transaction.file.ensureCurrentRoute()
        return config
    }

    struct ProvidersSnapshot {
        let providers: [Provider]
        let settingsRevision: UInt64
        let isAuthoritative: Bool
    }

    /// Reads provider rows and their optimistic-concurrency token from the
    /// same document snapshot so Settings cannot pair fresh rows with a stale
    /// revision (or vice versa).
    static func providersSnapshot(url: URL = configURL()) -> ProvidersSnapshot {
        do {
            return try providersSnapshotChecked(url: url)
        } catch {
            // Settings already passes this token back through expectedRevision.
            // UInt64.max is never writable, so a transient read failure cannot
            // later save a fabricated revision-zero default over restored data.
            return ProvidersSnapshot(
                providers: defaultDocument.providers ?? [],
                settingsRevision: UInt64.max,
                isAuthoritative: false)
        }
    }

    static func providersSnapshotChecked(url: URL = configURL()) throws -> ProvidersSnapshot {
        let defaults = defaultDocument.providers ?? []
        guard let config = try readChecked(url: url) else {
            return ProvidersSnapshot(
                providers: defaults,
                settingsRevision: 0,
                isAuthoritative: true)
        }
        let existing = config.providers ?? []
        let existingIDs = Set(existing.map(\.id))
        let missing = defaults.filter { !existingIDs.contains($0.id) }
        return ProvidersSnapshot(
            providers: existing + missing,
            settingsRevision: config.settingsRevision ?? 0,
            isAuthoritative: true)
    }

    static func allProviders(url: URL = configURL()) -> [Provider] {
        providersSnapshot(url: url).providers
    }

    static func provider(id: String, url: URL = configURL()) -> Provider? {
        allProviders(url: url).first { $0.id == id }
    }

    /// API token for a provider id (e.g. "minimax"), trimmed; nil if unset.
    static func apiKey(provider id: String, url: URL = configURL()) -> String? {
        cleaned(provider(id: id, url: url)?.apiKey)
    }

    /// Whether a provider is enabled. Returns the explicit flag if present,
    /// otherwise `false` (opt-in default). Distinguishes "explicitly off"
    /// from "not configured" — callers that want to distinguish can use
    /// `provider(id:)` directly.
    static func isEnabled(provider id: String, url: URL = configURL()) -> Bool {
        provider(id: id, url: url)?.enabled ?? false
    }

    /// Account label for a provider (the user-facing "Tài khoản" string in
    /// the Settings detail panel). Nil → caller derives from token / keychain.
    static func accountLabel(provider id: String, url: URL = configURL()) -> String? {
        cleaned(provider(id: id, url: url)?.accountLabel)
    }

    /// MiniMax API token with env-var precedence (matches CodexBar's
    /// behaviour for `MINIMAX_CODING_API_KEY` / `MINIMAX_API_KEY`), then the
    /// config file. Used by `MiniMaxProvider` so users who already set the
    /// env var for CodexBar don't have to re-enter it.
    static func minimaxToken(env: [String: String] = ProcessInfo.processInfo.environment,
                              url: URL = configURL()) -> String? {
        for key in ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"] {
            if let token = cleaned(env[key]) { return token }
        }
        return apiKey(provider: "minimax", url: url)
    }

    // MARK: - Write

    /// Upsert one provider's configuration. Atomic write with 0o600
    /// permissions (matching CodexBar) so the file is owner-only.
    static func save(_ provider: Provider, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            var providers = config.providers ?? []
            if let index = providers.firstIndex(where: { $0.id == provider.id }) {
                providers[index] = provider
            } else {
                providers.append(provider)
            }
            config.providers = providers
            config.version = config.version ?? 1
        }
    }

    /// Persist the full provider list in the given order. Used by Settings
    /// drag-reorder; single-provider upsert preserves an existing array order
    /// and therefore cannot represent reorder operations.
    @discardableResult
    static func saveProviders(
        _ providers: [Provider],
        expectedRevision: UInt64? = nil,
        url: URL = configURL()
    ) throws -> UInt64 {
        var savedRevision: UInt64 = 0
        try mutateConfig(url: url) { config in
            let currentRevision = config.settingsRevision ?? 0
            if let expectedRevision, currentRevision != expectedRevision {
                throw ConfigStoreError.concurrentModification(path: url.path)
            }
            guard currentRevision < UInt64.max else {
                throw ConfigStoreError.revisionOverflow
            }
            config.providers = providers
            config.version = config.version ?? 1
            savedRevision = currentRevision + 1
        }
        return savedRevision
    }

    /// Remove one provider entry (clears its token + metadata). The
    /// provider id is removed entirely; a fresh read will not see it.
    static func remove(provider id: String, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            config.providers?.removeAll { $0.id == id }
        }
    }

    // MARK: - Claude Code custom profiles

    static func claudeCodeProfiles(url: URL = configURL()) -> [ClaudeCodeProfile] {
        read(url: url)?.claudeCodeProfiles ?? []
    }

    /// Upsert one custom profile by id (atomic write, preserves providers).
    /// When `codexProfileID` points at an existing Codex profile, mirrors the
    /// upstream credentials/protocol onto that profile in the same write
    /// (idempotent — no loop when values already match).
    static func saveClaudeCodeProfile(_ profile: ClaudeCodeProfile, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            var profiles = config.claudeCodeProfiles ?? []
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            config.claudeCodeProfiles = profiles

            if let codexID = profile.codexProfileID {
                var codexProfiles = config.codexProfiles ?? []
                if let index = codexProfiles.firstIndex(where: { $0.id == codexID }) {
                    let (synced, changed) = syncedCodexProfile(from: profile, into: codexProfiles[index])
                    if changed {
                        codexProfiles[index] = synced
                        config.codexProfiles = codexProfiles
                    }
                }
            }

            config.version = config.version ?? 1
        }
    }

    static func removeClaudeCodeProfile(id: String, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            config.claudeCodeProfiles?.removeAll { $0.id == id }
        }
    }

    // MARK: - Codex custom profiles

    static func codexProfiles(url: URL = configURL()) -> [CodexProfile] {
        read(url: url)?.codexProfiles ?? []
    }

    /// Upsert one Codex profile by id (atomic write, preserves providers).
    /// Deliberately does NOT mirror back onto the linked Claude record: the
    /// Claude record is the single source of truth for the shared upstream
    /// (the unified UI only edits upstream there), and Codex-side bookkeeping
    /// saves (proxy prepare, signature clears) may carry stale in-memory
    /// snapshots that would silently overwrite the user's protocol choice.
    static func saveCodexProfile(_ profile: CodexProfile, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            var profiles = config.codexProfiles ?? []
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            config.codexProfiles = profiles
            config.version = config.version ?? 1
        }
    }

    static func removeCodexProfile(id: String, url: URL = configURL()) throws {
        try mutateConfig(url: url) { config in
            config.codexProfiles?.removeAll { $0.id == id }
        }
    }

    /// Mutation failures are fail-closed: no caller may replace malformed,
    /// concurrently changed, or revision-exhausted settings.
    enum ConfigStoreError: LocalizedError {
        case malformedExistingFile(path: String)
        case concurrentModification(path: String)
        case revisionOverflow
        case mutationLockFailed(path: String, reason: String)
        case unsafeExistingFile(path: String, reason: String)
        case atomicWriteFailed(path: String, reason: String)
        case directoryRouteChanged(path: String)

        var errorDescription: String? {
            switch self {
            case .malformedExistingFile(let path):
                return "Refusing to overwrite unreadable config at \(path): existing file is not valid JSON."
            case .concurrentModification(let path):
                return "Settings changed outside this mutation at \(path); reload before saving."
            case .revisionOverflow:
                return "Settings revision overflow; refusing to overwrite config."
            case .mutationLockFailed(let path, let reason):
                return "Cannot acquire settings mutation lock at \(path): \(reason)"
            case .unsafeExistingFile(let path, let reason):
                return "Refusing to read unsafe config at \(path): \(reason)"
            case .atomicWriteFailed(let path, let reason):
                return "Cannot atomically write settings at \(path): \(reason)"
            case .directoryRouteChanged(let path):
                return "Settings directory route changed at \(path); reload before saving."
            }
        }
    }

    /// Serializes threads in this process; the sibling descriptor lock below
    /// serializes macOS with Linux/other BirdNion processes.
    private static let mutationLock = NSLock()

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Stable parent binding for one settings transaction. All config and lock
    /// entries are addressed relative to this descriptor; only route checks
    /// intentionally re-open the original parent pathname.
    private final class BoundSettingsFile {
        let directoryDescriptor: Int32
        let name: String
        let displayURL: URL
        let parentURL: URL
        private let identity: DirectoryIdentity

        init(settingsURL: URL) throws {
            let parent = settingsURL.deletingLastPathComponent()
            let name = settingsURL.lastPathComponent
            guard BirdNionConfigStore.isValidFileName(name) else {
                throw ConfigStoreError.unsafeExistingFile(
                    path: settingsURL.path,
                    reason: "settings path has no valid file name")
            }
            do {
                try FileManager.default.createDirectory(
                    at: parent.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            } catch {
                throw ConfigStoreError.atomicWriteFailed(
                    path: parent.path,
                    reason: error.localizedDescription)
            }

            let createResult = parent.path.withCString {
                Darwin.mkdir($0, mode_t(0o700))
            }
            if createResult != 0 {
                let createError = errno
                guard createError == EEXIST else {
                    throw ConfigStoreError.atomicWriteFailed(
                        path: parent.path,
                        reason: String(cString: strerror(createError)))
                }
            }

            let descriptor = parent.path.withCString {
                Darwin.open(
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw ConfigStoreError.unsafeExistingFile(
                    path: parent.path,
                    reason: String(cString: strerror(errno)))
            }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                let reason = String(cString: strerror(errno))
                Darwin.close(descriptor)
                throw ConfigStoreError.unsafeExistingFile(path: parent.path, reason: reason)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(descriptor)
                throw ConfigStoreError.unsafeExistingFile(
                    path: parent.path,
                    reason: "settings parent is not a real directory")
            }
            directoryDescriptor = descriptor
            self.name = name
            displayURL = settingsURL
            parentURL = parent
            identity = DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
        }

        deinit {
            Darwin.close(directoryDescriptor)
        }

        func ensureCurrentRoute() throws {
            let descriptor = parentURL.path.withCString {
                Darwin.open(
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw ConfigStoreError.directoryRouteChanged(path: parentURL.path)
            }
            defer { Darwin.close(descriptor) }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino) == identity
            else {
                throw ConfigStoreError.directoryRouteChanged(path: parentURL.path)
            }
        }

        func syncDirectory() throws {
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw ConfigStoreError.atomicWriteFailed(
                    path: parentURL.path,
                    reason: String(cString: strerror(errno)))
            }
        }

        func displayPath(for childName: String) -> String {
            parentURL.appendingPathComponent(childName).path
        }
    }

    private final class InterprocessMutationLock {
        private let descriptor: Int32

        init(file: BoundSettingsFile) throws {
            let lockName = file.name + ".birdnion.lock"
            let lockPath = file.displayPath(for: lockName)
            let fd = lockName.withCString {
                Darwin.openat(
                    file.directoryDescriptor,
                    $0,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    mode_t(0o600))
            }
            guard fd >= 0 else {
                throw ConfigStoreError.mutationLockFailed(
                    path: lockPath,
                    reason: String(cString: strerror(errno)))
            }

            var metadata = stat()
            guard Darwin.fstat(fd, &metadata) == 0 else {
                let reason = String(cString: strerror(errno))
                Darwin.close(fd)
                throw ConfigStoreError.mutationLockFailed(path: lockPath, reason: reason)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
                Darwin.close(fd)
                throw ConfigStoreError.mutationLockFailed(
                    path: lockPath,
                    reason: "lock is not a private regular file")
            }
            guard birdNionFlock(fd, LOCK_EX) == 0 else {
                let reason = String(cString: strerror(errno))
                Darwin.close(fd)
                throw ConfigStoreError.mutationLockFailed(path: lockPath, reason: reason)
            }
            guard Darwin.fchmod(fd, mode_t(0o600)) == 0 else {
                let reason = String(cString: strerror(errno))
                _ = birdNionFlock(fd, LOCK_UN)
                Darwin.close(fd)
                throw ConfigStoreError.mutationLockFailed(path: lockPath, reason: reason)
            }
            descriptor = fd
        }

        deinit {
            _ = birdNionFlock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    private final class SettingsTransaction {
        let file: BoundSettingsFile
        private let lock: InterprocessMutationLock

        init(settingsURL: URL) throws {
            let file = try BoundSettingsFile(settingsURL: settingsURL)
            let lock = try InterprocessMutationLock(file: file)
            try file.ensureCurrentRoute()
            self.file = file
            self.lock = lock
        }
    }

    /// Top-level `Config` keys this build actively models. Any other key
    /// found in an existing on-disk document (e.g. written by a newer
    /// BirdNion version) is preserved verbatim across a save.
    private static let knownTopLevelKeys: Set<String> = [
        "version", "settingsRevision", "providers", "claudeCodeProfiles", "codexProfiles",
    ]

    /// `Provider` keys this build actively models — mirrors its stored
    /// property names (no custom `CodingKeys`, so JSON key == property name).
    /// Any other per-provider key in an existing document is preserved.
    private static let knownProviderKeys: Set<String> = [
        "id", "apiKey", "enabled", "region", "budget", "projectID", "secretKey",
        "awsAuthMode", "awsProfile", "baseURL", "displayName", "accountLabel",
        "cookieHeader", "claudeHaikuModel", "claudeSonnetModel", "claudeOpusModel",
        "claudeDisable1M", "claudeCodeScope", "claudeCodeProjectPath",
        "codexProfileID", "preferredAgent",
    ]

    /// Canonical mutation transaction shared by every macOS write API.
    /// Decision, revision advance, byte-CAS, and atomic replacement all occur
    /// while both process and interprocess locks are held.
    private static func mutateConfig(
        url: URL,
        afterLock: (() throws -> Void)? = nil,
        beforeClaim: (() throws -> Void)? = nil,
        afterClaim: (() throws -> Void)? = nil,
        _ mutation: (inout Config) throws -> Void
    ) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let transaction = try SettingsTransaction(settingsURL: url)
        try afterLock?()
        try transaction.file.ensureCurrentRoute()
        try recoverConditionalBackup(file: transaction.file)
        let (loaded, expectedData) = try readForMutation(file: transaction.file)
        var config = loaded
        let revision = config.settingsRevision ?? 0
        try mutation(&config)
        guard revision < UInt64.max else { throw ConfigStoreError.revisionOverflow }
        config.settingsRevision = revision + 1
        try writeConfig(
            config,
            file: transaction.file,
            expectedData: expectedData,
            beforeClaim: beforeClaim,
            afterClaim: afterClaim)
        try transaction.file.ensureCurrentRoute()
    }

#if DEBUG
    /// Deterministic seam for replacing the settings parent after the
    /// interprocess lock is held but before recovery/read begins.
    static func performMutationAfterLockForTesting(
        url: URL,
        afterLock: @escaping () throws -> Void,
        _ mutation: (inout Config) throws -> Void
    ) throws {
        try mutateConfig(url: url, afterLock: afterLock, mutation)
    }

    /// Deterministic seam for exercising an uncooperative external writer
    /// after staging/readback and immediately before the destination claim.
    /// Never touches live settings unless a test explicitly passes that URL.
    static func performMutationForTesting(
        url: URL,
        beforeClaim: @escaping () throws -> Void,
        _ mutation: (inout Config) throws -> Void
    ) throws {
        try mutateConfig(url: url, beforeClaim: beforeClaim, mutation)
    }

    /// Deterministic seam for pausing a writer while the canonical settings
    /// path is claimed into its recovery sibling. Used to prove readers wait
    /// for the same transaction instead of observing a transient absence.
    static func performMutationAfterClaimForTesting(
        url: URL,
        afterClaim: @escaping () throws -> Void,
        _ mutation: (inout Config) throws -> Void
    ) throws {
        try mutateConfig(url: url, afterClaim: afterClaim, mutation)
    }
#endif

    private static func readForMutation(file: BoundSettingsFile) throws -> (Config, Data?) {
        guard let data = try readRegularFileBounded(file: file, name: file.name) else {
            return (Config(version: 1, providers: []), nil)
        }
        guard !data.isEmpty, let config = try? JSONDecoder().decode(Config.self, from: data) else {
            throw ConfigStoreError.malformedExistingFile(path: file.displayURL.path)
        }
        return (config, data)
    }

    /// Descriptor-based bounded read matching Linux's settings contract.
    /// Non-blocking/no-follow open prevents FIFO hangs and symlink traversal;
    /// metadata plus the read cap rejects special, sparse, and growing files.
    private static func readRegularFileBounded(
        file: BoundSettingsFile,
        name: String
    ) throws -> Data? {
        guard isValidFileName(name) else {
            throw ConfigStoreError.unsafeExistingFile(
                path: file.displayPath(for: name),
                reason: "entry is not a direct child file name")
        }
        let descriptor = name.withCString {
            Darwin.openat(
                file.directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ConfigStoreError.unsafeExistingFile(
                path: file.displayPath(for: name),
                reason: String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ConfigStoreError.unsafeExistingFile(
                path: file.displayPath(for: name),
                reason: String(cString: strerror(errno)))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ConfigStoreError.unsafeExistingFile(
                path: file.displayPath(for: name),
                reason: "path is not a regular file")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumSettingsBytes else {
            throw ConfigStoreError.unsafeExistingFile(
                path: file.displayPath(for: name),
                reason: "file exceeds \(maximumSettingsBytes) byte limit")
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumSettingsBytes {
            let remaining = maximumSettingsBytes + 1 - data.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigStoreError.unsafeExistingFile(
                    path: file.displayPath(for: name),
                    reason: String(cString: strerror(errno)))
            }
            data.append(contentsOf: buffer[0..<Int(count)])
        }
        throw ConfigStoreError.unsafeExistingFile(
            path: file.displayPath(for: name),
            reason: "file exceeds \(maximumSettingsBytes) byte limit")
    }

    /// Merge unknown keys from the exact bytes read for this transaction, then
    /// commit through the claim-based conditional replacement below.
    private static func writeConfig(
        _ config: Config,
        file: BoundSettingsFile,
        expectedData: Data?,
        beforeClaim: (() throws -> Void)?,
        afterClaim: (() throws -> Void)?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let freshData = try encoder.encode(config)
        guard var topLevel = try JSONSerialization.jsonObject(with: freshData) as? [String: Any] else {
            throw ConfigStoreError.malformedExistingFile(path: file.displayURL.path)
        }

        if let expectedData {
            guard let existingTopLevel = try? JSONSerialization.jsonObject(with: expectedData) as? [String: Any] else {
                throw ConfigStoreError.malformedExistingFile(path: file.displayURL.path)
            }

            for (key, value) in existingTopLevel where !knownTopLevelKeys.contains(key) {
                topLevel[key] = value
            }
            if let existingProviders = existingTopLevel["providers"] as? [[String: Any]] {
                var rawByID: [String: [String: Any]] = [:]
                for raw in existingProviders {
                    if let id = raw["id"] as? String { rawByID[id] = raw }
                }
                if let freshProviders = topLevel["providers"] as? [[String: Any]] {
                    topLevel["providers"] = freshProviders.map { fresh -> [String: Any] in
                        guard let id = fresh["id"] as? String, let rawExisting = rawByID[id] else { return fresh }
                        var merged = fresh
                        for (key, value) in rawExisting where !knownProviderKeys.contains(key) {
                            merged[key] = value
                        }
                        return merged
                    }
                }
            }
        }

        let mergedData = try JSONSerialization.data(withJSONObject: topLevel, options: [.prettyPrinted, .sortedKeys])
        guard mergedData.count <= maximumSettingsBytes else {
            throw ConfigStoreError.atomicWriteFailed(
                path: file.displayURL.path,
                reason: "document exceeds \(maximumSettingsBytes) byte limit")
        }
        try file.ensureCurrentRoute()
        guard try readRegularFileBounded(file: file, name: file.name) == expectedData else {
            throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
        }
        try writePrivateAtomic(
            mergedData,
            file: file,
            expectedData: expectedData,
            beforeClaim: beforeClaim,
            afterClaim: afterClaim)
        try file.ensureCurrentRoute()
    }

    /// Stages private bytes, then uses two no-replace renames as the CAS
    /// linearization points. The destination is first claimed into a fixed
    /// recovery path and validated there; an external writer can win either
    /// rename without ever being overwritten.
    private static func writePrivateAtomic(
        _ data: Data,
        file: BoundSettingsFile,
        expectedData: Data?,
        beforeClaim: (() throws -> Void)?,
        afterClaim: (() throws -> Void)?
    ) throws {
        let temporaryName = ".\(file.name).\(UUID().uuidString).tmp"
        var descriptor = temporaryName.withCString {
            Darwin.openat(
                file.directoryDescriptor,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw ConfigStoreError.atomicWriteFailed(
                path: file.displayURL.path,
                reason: String(cString: strerror(errno)))
        }
        var cleanupTemporary = true
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if cleanupTemporary {
                try? unlinkFileIfPresent(
                    file: file,
                    name: temporaryName,
                    errorPath: file.displayURL.path)
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ConfigStoreError.atomicWriteFailed(
                        path: file.displayURL.path,
                        reason: String(cString: strerror(errno)))
                }
                offset += count
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw ConfigStoreError.atomicWriteFailed(
                path: file.displayURL.path,
                reason: String(cString: strerror(errno)))
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw ConfigStoreError.atomicWriteFailed(
                path: file.displayURL.path,
                reason: String(cString: strerror(errno)))
        }
        descriptor = -1
        try beforeClaim?()
        try file.ensureCurrentRoute()

        guard let expectedData else {
            let installError = renameNoReplace(
                file: file,
                sourceName: temporaryName,
                destinationName: file.name)
            guard installError == 0 else {
                if installError == EEXIST || installError == ENOENT {
                    throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
                }
                throw atomicWriteError(file: file, code: installError)
            }
            cleanupTemporary = false
            let committedData = try readRegularFileBounded(file: file, name: file.name)
            try file.syncDirectory()
            guard committedData == data else {
                throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
            }
            return
        }

        let backupName = conditionalBackupName(for: file)
        let claimError = renameNoReplace(
            file: file,
            sourceName: file.name,
            destinationName: backupName)
        guard claimError == 0 else {
            if claimError == EEXIST || claimError == ENOENT {
                throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
            }
            throw atomicWriteError(file: file, code: claimError)
        }
        try afterClaim?()

        let claimedData: Data
        do {
            guard let data = try readRegularFileBounded(file: file, name: backupName) else {
                try restoreClaimedDestination(
                    file: file,
                    backupName: backupName,
                    destinationName: file.name)
                throw ConfigStoreError.atomicWriteFailed(
                    path: file.displayURL.path,
                    reason: "claimed settings disappeared before validation")
            }
            claimedData = data
        } catch {
            try? restoreClaimedDestination(
                file: file,
                backupName: backupName,
                destinationName: file.name)
            throw error
        }

        guard claimedData == expectedData else {
            try restoreClaimedDestination(
                file: file,
                backupName: backupName,
                destinationName: file.name)
            throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
        }

        let installError = renameNoReplace(
            file: file,
            sourceName: temporaryName,
            destinationName: file.name)
        guard installError == 0 else {
            if installError == EEXIST {
                try discardBackupIfDestinationIsValid(
                    file: file,
                    backupName: backupName)
                throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
            }
            try? restoreClaimedDestination(
                file: file,
                backupName: backupName,
                destinationName: file.name)
            throw atomicWriteError(file: file, code: installError)
        }
        cleanupTemporary = false

        guard let committedData = try readRegularFileBounded(file: file, name: file.name) else {
            throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
        }
        guard committedData == data else {
            try discardBackupIfDestinationIsValid(
                file: file,
                backupName: backupName)
            throw ConfigStoreError.concurrentModification(path: file.displayURL.path)
        }
        try unlinkFileIfPresent(
            file: file,
            name: backupName,
            errorPath: file.displayURL.path)
        try file.syncDirectory()
    }

    /// A crash after claiming the destination leaves only the fixed backup;
    /// restore it before any load or mutation can interpret the config as new.
    /// If both paths exist, the current valid destination is authoritative.
    private static func recoverConditionalBackup(file: BoundSettingsFile) throws {
        let backupName = conditionalBackupName(for: file)
        guard let backupData = try readRegularFileBounded(file: file, name: backupName) else {
            return
        }
        try validateConfigDocument(backupData, path: file.displayPath(for: backupName))

        if let currentData = try readRegularFileBounded(file: file, name: file.name) {
            try validateConfigDocument(currentData, path: file.displayURL.path)
            try unlinkFileIfPresent(
                file: file,
                name: backupName,
                errorPath: file.displayURL.path)
            try file.syncDirectory()
            return
        }

        let restoreError = renameNoReplace(
            file: file,
            sourceName: backupName,
            destinationName: file.name)
        if restoreError == 0 {
            try file.syncDirectory()
            return
        }
        if restoreError == EEXIST {
            try discardBackupIfDestinationIsValid(file: file, backupName: backupName)
            return
        }
        throw atomicWriteError(file: file, code: restoreError)
    }

    private static func restoreClaimedDestination(
        file: BoundSettingsFile,
        backupName: String,
        destinationName: String
    ) throws {
        let restoreError = renameNoReplace(
            file: file,
            sourceName: backupName,
            destinationName: destinationName)
        if restoreError == 0 {
            try file.syncDirectory()
            return
        }
        // A newer external writer owns `url`; preserve both documents and let
        // the next recovery pass validate the external destination.
        if restoreError == EEXIST { return }
        throw atomicWriteError(file: file, code: restoreError)
    }

    private static func discardBackupIfDestinationIsValid(
        file: BoundSettingsFile,
        backupName: String
    ) throws {
        guard let currentData = try readRegularFileBounded(file: file, name: file.name) else {
            throw ConfigStoreError.atomicWriteFailed(
                path: file.displayURL.path,
                reason: "external settings disappeared during conflict recovery")
        }
        try validateConfigDocument(currentData, path: file.displayURL.path)
        try unlinkFileIfPresent(
            file: file,
            name: backupName,
            errorPath: file.displayURL.path)
        try file.syncDirectory()
    }

    private static func validateConfigDocument(_ data: Data, path: String) throws {
        guard !data.isEmpty, (try? JSONDecoder().decode(Config.self, from: data)) != nil else {
            throw ConfigStoreError.malformedExistingFile(path: path)
        }
    }

    private static func conditionalBackupName(for file: BoundSettingsFile) -> String {
        file.name + ".birdnion-cas-backup"
    }

    private static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    /// Returns zero on success, otherwise the captured POSIX errno.
    private static func renameNoReplace(
        file: BoundSettingsFile,
        sourceName: String,
        destinationName: String
    ) -> Int32 {
        guard isValidFileName(sourceName), isValidFileName(destinationName) else {
            return EINVAL
        }
        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                Darwin.renameatx_np(
                    file.directoryDescriptor,
                    sourcePath,
                    file.directoryDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func unlinkFileIfPresent(
        file: BoundSettingsFile,
        name: String,
        errorPath: String
    ) throws {
        guard isValidFileName(name) else {
            throw ConfigStoreError.atomicWriteFailed(
                path: errorPath,
                reason: "entry is not a direct child file name")
        }
        let result = name.withCString {
            Darwin.unlinkat(file.directoryDescriptor, $0, 0)
        }
        if result == 0 || errno == ENOENT { return }
        throw ConfigStoreError.atomicWriteFailed(
            path: errorPath,
            reason: String(cString: strerror(errno)))
    }

    private static func atomicWriteError(file: BoundSettingsFile, code: Int32) -> ConfigStoreError {
        .atomicWriteFailed(
            path: file.displayURL.path,
            reason: String(cString: strerror(code)))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
