import Foundation

/// Maps a BirdNion provider id → the Anthropic-compatible base URL to use when
/// that provider backs Claude Code (written to `ANTHROPIC_BASE_URL` in the
/// Claude Code `settings.json`), plus a set of documented model ids to suggest
/// for the Haiku/Sonnet/Opus pickers.
///
/// Only providers that expose an Anthropic-compatible surface (`/v1/messages`)
/// can back Claude Code, so `baseURL(forProviderID:)` returns `nil` for the
/// rest (audio APIs, OpenAI-only routers, GitHub, etc.) — those never surface
/// the "Claude Code" config UI.
///
/// Region-aware providers (MiniMax, Z.ai) read their region from the same
/// UserDefaults key their quota provider uses. Hapo's host is not committed to
/// source: it is derived from the same env/Info.plist config the Hapo quota
/// provider uses, so the hostname never ships in the repo.
enum ClaudeCodeBackend {
    /// Anthropic-compatible base URL for a provider id, or nil if the provider
    /// cannot back Claude Code. Value is the API root that Claude Code appends
    /// `/v1/messages` and `/v1/models` to.
    static func baseURL(forProviderID id: String) -> String? {
        switch id {
        case "hapo":
            // Derived from the (non-source-controlled) Hapo endpoint config so
            // the private hostname is never committed. Nil when Hapo is not
            // configured for this build.
            return anthropicOrigin(from: HapoHubConfig.real.baseURL)
        case "minimax":
            // e.g. api.minimax.io/anthropic (global) / api.minimaxi.com (CN).
            return "https://\(MiniMaxRegion.current.apiHost)/anthropic"
        case "deepseek":
            // DeepSeek's Anthropic-compatible endpoint.
            return "https://api.deepseek.com/anthropic"
        case "zai":
            // e.g. api.z.ai/api/anthropic (global) / open.bigmodel.cn (CN).
            return "https://\(ZaiRegion.current.baseHost)/api/anthropic"
        default:
            return nil
        }
    }

    /// Whether a provider can be configured as a Claude Code backend.
    static func isSupported(_ id: String) -> Bool {
        baseURL(forProviderID: id) != nil
    }

    /// Extract `scheme://host[:port]` (the API origin) from a full URL string.
    /// Used to derive the Hapo Anthropic base from its configured endpoint
    /// without hardcoding — and shipping — the hostname. Nil if no host.
    static func anthropicOrigin(from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString),
              let scheme = comps.scheme,
              let host = comps.host, !host.isEmpty else { return nil }
        if let port = comps.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Documented model ids to seed the tier pickers for providers whose
    /// Anthropic endpoint does not implement `/v1/models` (MiniMax, DeepSeek,
    /// Z.ai commonly return 404 there). The user can still type any id or hit
    /// "Load models" for providers that do expose the list (e.g. Hapo).
    /// Names come from each provider's Claude Code docs; keep this list in sync
    /// as providers rename models. The `[1m]` suffix (MiniMax) selects the
    /// 1M-token context variant and is the documented default.
    static func suggestedModels(forProviderID id: String) -> [String] {
        switch id {
        case "minimax":
            return ["MiniMax-M3[1m]", "MiniMax-M3", "MiniMax-M2"]
        case "deepseek":
            return ["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"]
        case "zai":
            return ["GLM-4.7", "GLM-4.5-Air", "glm-4.6", "glm-4.5"]
        default:
            return []
        }
    }

    /// Extra provider-specific env vars documented for Claude Code, beyond the
    /// standard token/base/model keys. These are written verbatim into the
    /// `env` block so a preset matches the provider's official settings.json.
    /// (MiniMax → 1M auto-compact window; Z.ai → long request timeout.)
    static func staticEnv(forProviderID id: String) -> [String: String] {
        switch id {
        case "minimax":
            return ["CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000"]
        case "zai":
            return ["API_TIMEOUT_MS": "3000000"]
        default:
            return [:]
        }
    }

    /// Providers whose docs set a top-level `ANTHROPIC_MODEL` (the primary model)
    /// alongside the per-tier defaults. We mirror it from the Sonnet tier.
    static func usesPrimaryModelKey(_ id: String) -> Bool {
        id == "minimax"
    }
}
