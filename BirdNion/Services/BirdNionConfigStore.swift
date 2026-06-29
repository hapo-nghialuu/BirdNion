import Foundation

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
            Provider(id: "bedrock", enabled: false)
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

    /// Remove one provider entry (clears its token + metadata). The
    /// provider id is removed entirely; a fresh read will not see it.
    static func remove(provider id: String, url: URL = configURL()) throws {
        var config = read(url: url) ?? Config(version: 1, providers: [])
        config.providers?.removeAll { $0.id == id }
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
