import Foundation

/// Writes the Claude Code `env` block for a provider into a Claude Code
/// settings file — global (`~/.claude/settings.json`) or per-project
/// (`<dir>/.claude/settings.local.json`) — preserving every other key.
///
/// Shared by the "Claude Code" Settings tab (Save) and the popover quick-apply
/// button so both surfaces produce byte-identical output.
enum ClaudeCodeConfigWriter {
    /// Where the env block is written.
    enum Scope: Equatable {
        case global
        /// Per-project: writes to `<projectDir>/.claude/settings.local.json`.
        case project(URL)
    }

    enum WriteError: Error, Equatable {
        case notSupported
        case missingToken
        case missingModels

        var message: String {
            switch self {
            case .notSupported: return "Provider không hỗ trợ làm backend Claude Code"
            case .missingToken: return "Provider chưa có API key"
            case .missingModels: return "Chưa chọn đủ 3 model (Haiku/Sonnet/Opus)"
            }
        }
    }

    // Env keys this writer owns. Other env keys in the file are left untouched.
    static let authTokenKey = "ANTHROPIC_AUTH_TOKEN"
    static let baseURLKey = "ANTHROPIC_BASE_URL"
    static let haikuKey = "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    static let sonnetKey = "ANTHROPIC_DEFAULT_SONNET_MODEL"
    static let opusKey = "ANTHROPIC_DEFAULT_OPUS_MODEL"
    static let modelKey = "ANTHROPIC_MODEL"
    static let disable1MKey = "CLAUDE_CODE_DISABLE_1M_CONTEXT"

    /// A provider is "fully configured" — eligible for one-click quick-apply —
    /// when it is a supported backend, has an API key, and has all three models
    /// chosen. This is the gate the popover uses to decide apply-vs-open.
    static func isFullyConfigured(_ provider: BirdNionConfigStore.Provider) -> Bool {
        guard ClaudeCodeBackend.isSupported(provider.id),
              nonEmpty(provider.apiKey) else { return false }
        return nonEmpty(provider.claudeHaikuModel)
            && nonEmpty(provider.claudeSonnetModel)
            && nonEmpty(provider.claudeOpusModel)
    }

    /// Merge this provider's Claude Code env into the settings file for `scope`.
    /// Reads the provider's stored models + api key; the base URL comes from
    /// `ClaudeCodeBackend`.
    @MainActor
    static func apply(provider: BirdNionConfigStore.Provider,
                      scope: Scope,
                      using config: ConfigService) throws {
        guard let baseURL = ClaudeCodeBackend.baseURL(forProviderID: provider.id) else {
            throw WriteError.notSupported
        }
        guard cleaned(provider.apiKey) != nil else { throw WriteError.missingToken }
        guard cleaned(provider.claudeHaikuModel) != nil,
              cleaned(provider.claudeSonnetModel) != nil,
              cleaned(provider.claudeOpusModel) != nil else {
            throw WriteError.missingModels
        }
        _ = baseURL  // presence validated above via spec
        guard let s = spec(forProvider: provider) else { throw WriteError.missingModels }
        try write(spec: s, scope: scope, using: config)
    }

    /// Write an env spec: the `env` block becomes EXACTLY `spec.env` (so
    /// switching configs never leaves a previous config's keys behind), and
    /// `apiKeyHelper` is set when the spec has one or removed when it doesn't.
    /// All other top-level keys (e.g. `permissions`) are preserved.
    @MainActor
    static func write(spec: EnvSpec, scope: Scope, using config: ConfigService) throws {
        let url = targetURL(scope: scope, config: config)
        var settings = try config.load(at: url)
        settings["env"] = spec.env
        if let helper = spec.apiKeyHelper {
            settings["apiKeyHelper"] = helper
        } else {
            settings.removeValue(forKey: "apiKeyHelper")
        }
        try config.save(settings, at: url)
    }

    @MainActor
    static func targetURL(scope: Scope, config: ConfigService) -> URL {
        switch scope {
        case .global: return config.activePath
        case .project(let dir): return ConfigService.projectSettingsURL(projectDir: dir)
        }
    }

    /// Turn Claude Code's backing OFF: clear the `env` block and remove
    /// `apiKeyHelper`, reverting Claude Code to its default Anthropic backend.
    /// Other top-level keys are left intact.
    @MainActor
    static func deactivate(scope: Scope, using config: ConfigService) throws {
        let url = targetURL(scope: scope, config: config)
        var settings = try config.load(at: url)
        settings["env"] = [String: Any]()
        settings.removeValue(forKey: "apiKeyHelper")
        try config.save(settings, at: url)
    }

    /// Remove the Claude Code env settings from the selected target without
    /// creating a settings file when none exists. Other top-level settings are
    /// preserved.
    @MainActor
    static func removeEnvSettings(scope: Scope, using config: ConfigService) throws -> Bool {
        let url = targetURL(scope: scope, config: config)
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return false }

        var settings = try config.load(at: url)
        let hadEnv = settings.removeValue(forKey: "env") != nil
        let hadHelper = settings.removeValue(forKey: "apiKeyHelper") != nil
        guard hadEnv || hadHelper else { return false }

        try config.save(settings, at: url)
        return true
    }

    // MARK: - Sync state (drift detection)

    /// Whether the settings file for a scope points at this config and whether
    /// the written values still match the current source.
    /// - `.off`   : file does not point here (base URL differs / absent).
    /// - `.synced`: file matches every managed value.
    /// - `.stale` : file points here (base URL matches) but a managed value
    ///              differs — e.g. the API key changed. Re-applying patches just
    ///              those values in place (never clears the block).
    enum SyncState: Equatable { case off, synced, stale }

    /// Build the write spec for a built-in provider preset (nil until it has a
    /// token + base URL + all three models).
    static func spec(forProvider p: BirdNionConfigStore.Provider) -> EnvSpec? {
        guard let base = ClaudeCodeBackend.baseURL(forProviderID: p.id),
              let token = cleaned(p.apiKey),
              let h = cleaned(p.claudeHaikuModel),
              let s = cleaned(p.claudeSonnetModel),
              let o = cleaned(p.claudeOpusModel) else { return nil }
        var env: [String: String] = [
            authTokenKey: token, baseURLKey: base,
            haikuKey: h, sonnetKey: s, opusKey: o,
        ]
        // Provider-specific documented env (e.g. MiniMax auto-compact window,
        // Z.ai timeout) so the preset matches the provider's official config.
        for (k, v) in ClaudeCodeBackend.staticEnv(forProviderID: p.id) { env[k] = v }
        // Some providers document a top-level ANTHROPIC_MODEL (primary model).
        if ClaudeCodeBackend.usesPrimaryModelKey(p.id) { env[modelKey] = s }
        if p.claudeDisable1M == true { env[disable1MKey] = "1" }
        return EnvSpec(env: env, apiKeyHelper: nil)
    }

    @MainActor
    static func syncState(spec: EnvSpec, scope: Scope, using config: ConfigService) -> SyncState {
        guard let base = spec.baseURL,
              let settings = try? config.load(at: targetURL(scope: scope, config: config)),
              let env = settings["env"] as? [String: Any],
              let currentBase = env[baseURLKey] as? String, currentBase == base else {
            return .off
        }
        // Active (base URL matches). Synced only if the whole env block equals
        // the spec exactly (no missing keys AND no leftover keys from another
        // config) and apiKeyHelper matches; otherwise stale.
        let fileEnv = env.compactMapValues { $0 as? String }
        if fileEnv != spec.env { return .stale }
        if (settings["apiKeyHelper"] as? String) != spec.apiKeyHelper { return .stale }
        return .synced
    }

    @MainActor
    static func syncState(forProvider p: BirdNionConfigStore.Provider,
                          scope: Scope, using config: ConfigService) -> SyncState {
        guard let spec = spec(forProvider: p) else { return .off }
        return syncState(spec: spec, scope: scope, using: config)
    }

    @MainActor
    static func syncState(forProfile p: BirdNionConfigStore.ClaudeCodeProfile,
                          scope: Scope, using config: ConfigService) -> SyncState {
        guard let spec = spec(forProfile: p) else { return .off }
        let state = syncState(spec: spec, scope: scope, using: config)
        if state == .synced, p.embeddedLocalProxy == true, !p.isCLIProxyConfigurationCurrent {
            return .stale
        }
        return state
    }

    // MARK: - Custom profiles

    /// A resolved set of Claude Code settings to write: the env keys/values
    /// this profile owns, plus an optional top-level `apiKeyHelper`.
    struct EnvSpec: Equatable {
        let env: [String: String]
        let apiKeyHelper: String?
        var baseURL: String? { env[baseURLKey] }
    }

    /// Build the write spec for a custom profile. Embedded-proxy profiles point
    /// Claude Code at BirdNion's loopback CLIProxyAPI core; upstream and
    /// management secrets never enter Claude Code's env block.
    static func spec(forProfile p: BirdNionConfigStore.ClaudeCodeProfile) -> EnvSpec? {
        if p.embeddedLocalProxy == true {
            guard p.isEmbeddedCLIProxyReady,
                  let proxyKey = cleaned(p.cliProxyAPIKey),
                  let proxyBaseURL = p.normalizedCLIProxyBaseURL else { return nil }
            var env: [String: String] = [
                authTokenKey: proxyKey,
                baseURLKey: proxyBaseURL,
            ]
            if let h = cleaned(p.haikuModel) { env[haikuKey] = p.cliProxyModelAlias(for: h) }
            if let s = cleaned(p.sonnetModel) { env[sonnetKey] = p.cliProxyModelAlias(for: s) }
            if let o = cleaned(p.opusModel) { env[opusKey] = p.cliProxyModelAlias(for: o) }
            let managedKeys = Set([authTokenKey, "ANTHROPIC_API_KEY", baseURLKey, haikuKey, sonnetKey, opusKey])
            for pair in p.extraEnv ?? [] {
                if let k = cleaned(pair.key), !managedKeys.contains(k) { env[k] = pair.value }
            }
            return EnvSpec(env: env, apiKeyHelper: nil)
        }

        switch p.compatibility {
        case .anthropic:
            guard let token = cleaned(p.token), let base = cleaned(p.baseURL) else { return nil }
            var env: [String: String] = [:]
            env[cleaned(p.tokenEnvKey) ?? authTokenKey] = token
            env[baseURLKey] = base
            if let h = cleaned(p.haikuModel) { env[haikuKey] = h }
            if let s = cleaned(p.sonnetModel) { env[sonnetKey] = s }
            if let o = cleaned(p.opusModel) { env[opusKey] = o }
            for pair in p.extraEnv ?? [] {
                if let k = cleaned(pair.key) { env[k] = pair.value }
            }
            return EnvSpec(env: env, apiKeyHelper: cleaned(p.apiKeyHelper))

        case .openAI:
            return nil
        }
    }

    /// Embedded profiles need only their upstream URL + key before activation:
    /// BirdNion generates their loopback credentials at activation time.
    static func isReady(_ p: BirdNionConfigStore.ClaudeCodeProfile) -> Bool {
        if p.usesEmbeddedCLIProxy { return p.hasUpstreamConfiguration }
        return spec(forProfile: p) != nil
    }

    @MainActor
    static func apply(profile: BirdNionConfigStore.ClaudeCodeProfile,
                      scope: Scope, using config: ConfigService) throws {
        guard let s = spec(forProfile: profile) else { throw WriteError.missingToken }
        try write(spec: s, scope: scope, using: config)
    }

    @MainActor
    static func deactivate(profile: BirdNionConfigStore.ClaudeCodeProfile,
                           scope: Scope, using config: ConfigService) throws {
        try deactivate(scope: scope, using: config)
    }

    // MARK: - Import from pasted JSON

    enum ImportError: Error, Equatable {
        case invalidJSON
        case noEnv

        var message: String {
            switch self {
            case .invalidJSON: return "JSON không hợp lệ"
            case .noEnv: return "Không tìm thấy khối env / các biến ANTHROPIC_*"
            }
        }
    }

    /// Parse a pasted Claude Code settings snippet into a profile, updating
    /// `base` in place (keeps its id + name). Accepts either a full settings
    /// object (`{ "apiKeyHelper": ..., "env": { ... } }`) or a bare env object
    /// (`{ "ANTHROPIC_BASE_URL": ... }`). Recognized keys map to typed fields;
    /// everything else in `env` becomes an extra env pair.
    static func profile(byImporting json: String,
                        into base: BirdNionConfigStore.ClaudeCodeProfile) throws
    -> BirdNionConfigStore.ClaudeCodeProfile {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidJSON
        }
        // env is either root["env"] or (when a bare env object was pasted) root.
        let env: [String: Any]
        if let e = root["env"] as? [String: Any] {
            env = e
        } else if root[baseURLKey] != nil || root[authTokenKey] != nil || root["ANTHROPIC_API_KEY"] != nil {
            env = root
        } else {
            throw ImportError.noEnv
        }

        var p = base
        // Imported JSON is an Anthropic-shaped upstream configuration.
        p.compatibilityMode = BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
        p.openAIFormat = nil
        p.embeddedLocalProxy = nil
        p.cliProxyBaseURL = nil
        p.cliProxyAPIKey = nil
        p.cliProxyManagementKey = nil
        p.cliProxyAppliedSignature = nil
        // Token: prefer an explicit API key, else the auth token.
        if let key = str(env["ANTHROPIC_API_KEY"]) {
            p.token = key
            p.tokenEnvKey = "ANTHROPIC_API_KEY"
        } else if let tok = str(env[authTokenKey]) {
            p.token = tok
            p.tokenEnvKey = authTokenKey
        }
        if let base = str(env[baseURLKey]) { p.baseURL = base }
        p.haikuModel = str(env[haikuKey]) ?? p.haikuModel
        p.sonnetModel = str(env[sonnetKey]) ?? p.sonnetModel
        p.opusModel = str(env[opusKey]) ?? p.opusModel
        // apiKeyHelper lives at the top level, not inside env.
        if let helper = str(root["apiKeyHelper"]) { p.apiKeyHelper = helper }

        // Remaining env keys → extra pairs (verbatim, stringified).
        let recognized: Set<String> = [
            "ANTHROPIC_API_KEY", authTokenKey, baseURLKey, haikuKey, sonnetKey, opusKey,
        ]
        var extra: [BirdNionConfigStore.ClaudeCodeEnvPair] = []
        for (k, v) in env where !recognized.contains(k) {
            if let value = str(v) {
                extra.append(.init(id: UUID().uuidString, key: k, value: value))
            }
        }
        p.extraEnv = extra.isEmpty ? nil : extra.sorted { $0.key < $1.key }
        return p
    }

    /// Coerce a JSON value to a String (numbers/bools become their literal form,
    /// matching how Claude Code env vars are stringly-typed).
    private static func str(_ any: Any?) -> String? {
        switch any {
        case let s as String: return cleaned(s)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func nonEmpty(_ value: String?) -> Bool { cleaned(value) != nil }
}
