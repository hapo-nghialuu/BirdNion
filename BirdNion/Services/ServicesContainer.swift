import Foundation
import SwiftUI

/// Owns the app-wide services so AppDelegate (non-SwiftUI) and Views
/// (SwiftUI) can share the same instances.
///
/// As of the 2026-06-25 storage refactor: providers no longer take a
/// `KeychainService` — each one reads its own token from
/// `BirdNionConfigStore` directly. `ConfigService` (Claude settings.json)
/// stays as-is; the Anthropic API key it manages now also lives in
/// `BirdNionConfigStore` (via `ConfigPanel` writes), so there is no longer
/// a per-app `KeychainService` instance.
@MainActor
final class ServicesContainer: ObservableObject {
    let configService: ConfigService
    let quotaService: QuotaService
    let settings: SettingsStore
    /// Refreshes when the system `~/.codex` login changes (terminal `codex login`).
    let codexAccountObserver = CodexSystemAccountObserver()

    /// Process-wide instance. Set by `BirdNionApp.init` so the Settings
    /// scene can use the same services as AppDelegate. Reading before
    /// registration is a programmer error.
    static private(set) var shared: ServicesContainer?

    static func register(services: ServicesContainer) {
        shared = services
    }

    init() {
        self.configService = ConfigService()
        let store = SettingsStore()
        self.settings = store
        self.quotaService = QuotaService(
            providers: Self.makeProviders(),
            interval: store.refreshIntervalSeconds
        )
        // Bind so settings.pushRefreshInterval() can push changes into the loop.
        store.bind(quotaService: quotaService)
    }

    /// Build the ordered list of `QuotaProvider` instances from
    /// `BirdNionConfigStore`. Order matches the config file (the order the
    /// user arranged in the Settings sidebar); disabled entries are skipped.
    /// First-run: every provider is `enabled: false` so the returned list
    /// is empty — the popover shows the empty-state hint.
    /// Shared between `init()` and `rebuildProviders()` so reorder / toggle
    /// flows use the same factory.
    static func makeProviders() -> [QuotaProvider] {
        let providers = BirdNionConfigStore.allProviders().filter { $0.enabled == true }
        var result: [QuotaProvider] = []
        for cfg in providers {
            switch cfg.id {
            case "minimax":
                result.append(MiniMaxProvider())
            case "codex":
                // Zero-config: reads ~/.codex/auth.json directly.
                result.append(CodexProvider())
            case "hapo":
                let hapoConfig = HapoHubConfig(
                    id: cfg.id,
                    displayName: cfg.displayName ?? "AIHub",
                    baseURL: HapoHubConfig.real.baseURL,
                    meURL: HapoHubConfig.real.meURL,
                    authHeaderTemplate: HapoHubConfig.real.authHeaderTemplate,
                    jsonPath: HapoHubConfig.real.jsonPath)
                result.append(HapoHubFactory.make(
                    session: .shared,
                    config: hapoConfig))
            case "openrouter":
                result.append(OpenRouterProvider())
            case "deepseek":
                result.append(DeepSeekProvider())
            case "zai":
                result.append(ZaiProvider())
            case "claude":
                // Zero-config: reads Anthropic key from BirdNionConfigStore.
                result.append(ClaudeProvider())
            case "elevenlabs":
                result.append(ElevenLabsProvider())
            case "deepgram":
                result.append(DeepgramProvider())
            case "groq":
                result.append(GroqProvider())
            case "copilot":
                result.append(CopilotProvider())
            case "kilo":
                result.append(KiloProvider())
            case "commandcode":
                result.append(CommandCodeProvider())
            case "freemodel":
                result.append(FreemodelProvider())
            case "mimo":
                result.append(MiMoProvider())
            case "cursor":
                result.append(CursorProvider())
            case "alibaba":
                result.append(AlibabaProvider())
            case "opencode":
                result.append(OpenCodeProvider())
            case "opencodego":
                result.append(OpenCodeGoProvider())
            case "gemini":
                result.append(GeminiProvider())
            case "kiro":
                result.append(KiroProvider())
            case "antigravity":
                result.append(AntigravityProvider())
            case "bedrock":
                result.append(BedrockProvider())
            default:
                break
            }
        }
        return result
    }

    /// Rebuild the QuotaService provider list from the current
    /// `BirdNionConfigStore` on disk. Called by AppDelegate after the user
    /// reorders / toggles in the Settings sidebar so the popover tabs +
    /// menu-bar rotation pick up the new order immediately (no app restart
    /// needed).
    func rebuildProviders() {
        quotaService.setProviders(Self.makeProviders())
    }

    func start() {
        quotaService.start()
        codexAccountObserver.start()
    }

    func stop() {
        quotaService.stop()
        codexAccountObserver.stop()
    }
}
