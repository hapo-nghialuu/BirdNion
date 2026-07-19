import Foundation
import CryptoKit

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
        if protocolChanged && newProtocol != .responses {
            updated.connectionModeRaw = CodexProfile.ConnectionMode.localProxy.rawValue
        }

        let changed = updated.baseURL != codex.baseURL
            || updated.apiKey != codex.apiKey
            || updated.upstreamProtocol != codex.upstreamProtocol
            || updated.connectionModeRaw != codex.connectionModeRaw
        if !changed { return (codex, false) }
        updated.cliProxyAppliedSignature = nil
        return (updated, true)
    }

    /// Pure upstream sync Codex → linked Claude. Never touches model tiers,
    /// `extraEnv`, or scope fields.
    static func syncedClaudeCodeProfile(from codex: CodexProfile,
                                        into claude: ClaudeCodeProfile) -> (ClaudeCodeProfile, Bool) {
        var updated = claude
        if codex.upstreamProtocol == .anthropic {
            updated.baseURL = codex.baseURL
            updated.token = codex.apiKey
            updated.compatibilityMode = ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
        } else {
            updated.openAIBaseURL = codex.baseURL
            updated.openAIAPIKey = codex.apiKey
            updated.compatibilityMode = ClaudeCodeProfile.CompatibilityMode.openAI.rawValue
            updated.openAIFormat = codex.upstreamProtocol == .responses ? "responses" : nil
            updated.embeddedLocalProxy = true
        }

        let changed: Bool
        if codex.upstreamProtocol == .anthropic {
            changed = updated.baseURL != claude.baseURL
                || updated.token != claude.token
                || updated.compatibility != claude.compatibility
        } else {
            changed = updated.openAIBaseURL != claude.openAIBaseURL
                || updated.openAIAPIKey != claude.openAIAPIKey
                || updated.compatibility != claude.compatibility
                || updated.openAIFormat != claude.openAIFormat
                || updated.embeddedLocalProxy != claude.embeddedLocalProxy
        }
        if !changed { return (claude, false) }
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
            Provider(id: "deepseek", enabled: false),
            Provider(id: "zai", enabled: false),
            Provider(id: "claude", enabled: false),
            Provider(id: "elevenlabs", enabled: false),
            Provider(id: "deepgram", enabled: false),
            Provider(id: "groq", enabled: false),
            Provider(id: "grok", enabled: false),
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
            Provider(id: "freemodel", enabled: false)
        ])
    }()

    static func read(url: URL = configURL()) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    static func allProviders(url: URL = configURL()) -> [Provider] {
        let defaults = defaultDocument.providers ?? []
        guard let existing = read(url: url)?.providers else {
            // First-run / no config file: show the full canonical list disabled.
            return defaults
        }
        // Merge: keep the user's saved providers (their enabled state, token,
        // and order), then APPEND any provider added to `defaultDocument` that
        // isn't in the saved file yet. This makes newly-shipped providers show
        // up in the sidebar for existing users without wiping their config.
        let existingIDs = Set(existing.map { $0.id })
        let missing = defaults.filter { !existingIDs.contains($0.id) }
        return existing + missing
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
        var config = read(url: url) ?? Config(version: 1, providers: [])
        var providers = config.providers ?? []
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        config.providers = providers
        config.version = config.version ?? 1
        try writeConfig(config, url: url)
    }

    /// Persist the full provider list in the given order. Used by Settings
    /// drag-reorder; single-provider upsert preserves an existing array order
    /// and therefore cannot represent reorder operations.
    static func saveProviders(_ providers: [Provider], url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        config.providers = providers
        config.version = config.version ?? 1
        try writeConfig(config, url: url)
    }

    /// Remove one provider entry (clears its token + metadata). The
    /// provider id is removed entirely; a fresh read will not see it.
    static func remove(provider id: String, url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        config.providers?.removeAll { $0.id == id }
        try writeConfig(config, url: url)
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
        var config = read(url: url) ?? Config(version: 1, providers: [])
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
        try writeConfig(config, url: url)
    }

    static func removeClaudeCodeProfile(id: String, url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        config.claudeCodeProfiles?.removeAll { $0.id == id }
        try writeConfig(config, url: url)
    }

    // MARK: - Codex custom profiles

    static func codexProfiles(url: URL = configURL()) -> [CodexProfile] {
        read(url: url)?.codexProfiles ?? []
    }

    /// Upsert one Codex profile by id. When `claudeCodeProfileID` points at an
    /// existing Claude Code profile, mirrors upstream credentials/protocol onto
    /// that profile in the same write (idempotent).
    static func saveCodexProfile(_ profile: CodexProfile, url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        var profiles = config.codexProfiles ?? []
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        config.codexProfiles = profiles

        if let claudeID = profile.claudeCodeProfileID {
            var claudeProfiles = config.claudeCodeProfiles ?? []
            if let index = claudeProfiles.firstIndex(where: { $0.id == claudeID }) {
                let (synced, changed) = syncedClaudeCodeProfile(from: profile, into: claudeProfiles[index])
                if changed {
                    claudeProfiles[index] = synced
                    config.claudeCodeProfiles = claudeProfiles
                }
            }
        }

        config.version = config.version ?? 1
        try writeConfig(config, url: url)
    }

    static func removeCodexProfile(id: String, url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        config.codexProfiles?.removeAll { $0.id == id }
        try writeConfig(config, url: url)
    }

    private static func writeConfig(_ config: Config, url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
