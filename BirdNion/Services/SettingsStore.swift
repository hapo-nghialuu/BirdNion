import SwiftUI
import ServiceManagement

/// Central user-preferences store. Each property uses `@AppStorage` so SwiftUI
/// views bind directly and values persist in UserDefaults automatically.
///
/// Real wiring: applyLanguage (writes AppleLanguages), setLaunchAtLogin
/// (SMAppService.mainApp), pushRefreshInterval (QuotaService). The remaining
/// 5 settings are persisted; their UI controls are wired in the pane views
/// (YAGNI — they have no code that reads them yet).
@MainActor
final class SettingsStore: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case system = ""        // empty string = use AppleLanguages as-is
        case english = "en"
        case vietnamese = "vi"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: "Theo hệ thống"
            case .english: "English"
            case .vietnamese: "Tiếng Việt"
            }
        }
    }

    enum RefreshFrequency: Double, CaseIterable, Identifiable {
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case oneHour = 3600

        var id: Double { rawValue }
        var displayName: String {
            switch self {
            case .oneMinute: "1 phút"
            case .twoMinutes: "2 phút"
            case .fiveMinutes: "5 phút"
            case .fifteenMinutes: "15 phút"
            case .oneHour: "1 giờ"
            }
        }
    }

    @AppStorage("appLanguage") var appLanguage: String = Language.system.rawValue
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("refreshIntervalSeconds") var refreshIntervalSeconds: Double = RefreshFrequency.twoMinutes.rawValue
    @AppStorage("debugMenuEnabled") var debugMenuEnabled: Bool = false
    @AppStorage("statusChecksEnabled") var statusChecksEnabled: Bool = true
    @AppStorage("sessionQuotaNotificationsEnabled") var sessionQuotaNotificationsEnabled: Bool = true
    @AppStorage("quotaWarningNotificationsEnabled") var quotaWarningNotificationsEnabled: Bool = false
    /// Global quota-warning thresholds (remaining %). Two levels: warning then
    /// critical. `QuotaWarnConfig` reads the same keys; providers may override.
    @AppStorage(QuotaWarnConfig.level1Key) var quotaWarnLevel1: Int = 50
    @AppStorage(QuotaWarnConfig.level2Key) var quotaWarnLevel2: Int = 20
    @AppStorage("hidePersonalInfo") var hidePersonalInfo: Bool = false
    @AppStorage("mergeIcons") var mergeIcons: Bool = true
    @AppStorage("switcherShowsIcons") var switcherShowsIcons: Bool = true
    /// MiniMax API host region: "io" (global) or "com" (mainland China).
    /// `MiniMaxProvider` reads the same UserDefaults key directly.
    @AppStorage(MiniMaxRegion.defaultsKey) var minimaxRegion: String = MiniMaxRegion.io.rawValue
    /// Z.ai / GLM API host region (global vs BigModel CN). `ZaiProvider` reads
    /// the same UserDefaults key directly.
    @AppStorage(ZaiRegion.defaultsKey) var zaiRegion: String = ZaiRegion.global.rawValue
    /// Which Codex window drives the menu bar percent. `MenuBarIconRenderer`
    /// reads the same UserDefaults key directly.
    @AppStorage(CodexMenuBarMetric.defaultsKey) var codexMenuBarMetric: String = CodexMenuBarMetric.automatic.rawValue
    /// Codex usage source (auto/oauth/cli). `CodexProvider` reads the same key.
    @AppStorage(CodexUsageSource.defaultsKey) var codexUsageSource: String = CodexUsageSource.auto.rawValue

    // MARK: - Claude parity settings (CodexBar parity)
    //
    // The keys below are read directly by `ClaudeProvider` (so the fetcher
    // picks up changes without going through the @Published path) and also
    // exposed via these AppStorage properties for SwiftUI binding.
    // Defaults match CodexBar's out-of-the-box behavior so existing users
    // see no change on first launch after upgrading.

    /// Which data source `ClaudeProvider` should use. CodexBar's `.auto`
    /// walks OAuth → Web → CLI and stops at the first that returns data;
    /// the other modes pin to a single strategy. Default `.oauth` matches
    /// BirdNion's pre-parity behavior (no change for existing users).
    /// `ClaudeProvider.readUsageDataSource()` reads the same UserDefaults key.
    @AppStorage("claudeUsageDataSource") var claudeUsageDataSource: String = "oauth"
    /// Whether `ClaudeUsageFetcher` should auto-detect browser cookies
    /// (`.auto`), use a user-pasted Cookie: header (`.manual`), or skip
    /// cookies entirely (`.off`). Default `.auto` matches CodexBar.
    /// `ClaudeProvider.readCookieSource()` reads the same UserDefaults key.
    @AppStorage("claudeCookieSource") var claudeCookieSource: String = "auto"
    /// User-pasted Cookie: header used when `claudeCookieSource == .manual`.
    /// Stored plaintext in UserDefaults — only the user sees it (paste from
    /// DevTools), never logged. Cleared by the user via the Settings UI.
    @AppStorage("claudeManualCookieHeader") var claudeManualCookieHeader: String = ""
    /// How aggressively the OAuth Keychain reader may prompt for access.
    /// `.never` suppresses the prompt entirely (CLI/Web only);
    /// `.onlyOnUserAction` (default) prompts when the user clicks Refresh;
    /// `.always` prompts on every background fetch. Matches CodexBar's
    /// `ClaudeOAuthKeychainPromptMode`. `ClaudeProvider` reads via
    /// `ClaudeOAuthKeychainPromptPreference.current()` (CodexBarCore).
    @AppStorage("claudeOAuthKeychainPromptMode") var claudeOAuthKeychainPromptMode: String = "onlyOnUserAction"
    /// Anthropic Admin API key (Admin mode only). Stored in macOS Keychain
    /// via KeychainService, not UserDefaults. The plain string below is a
    /// UI bind only — `KeychainService.saveProviderKey` writes it through
    /// Security framework. Empty by default.
    @AppStorage("claudeAdminAPIKeyConfigured") var claudeAdminAPIKeyConfigured: Bool = false

    var language: Language {
        get { Language(rawValue: appLanguage) ?? .system }
        set { appLanguage = newValue.rawValue }
    }

    var refreshFrequency: RefreshFrequency {
        get { RefreshFrequency(rawValue: refreshIntervalSeconds) ?? .twoMinutes }
        set { refreshIntervalSeconds = newValue.rawValue }
    }

    private weak var quotaService: QuotaService?

    func bind(quotaService: QuotaService) {
        self.quotaService = quotaService
        quotaService.setInterval(refreshIntervalSeconds)
    }

    func pushRefreshInterval() {
        quotaService?.setInterval(refreshIntervalSeconds)
    }

    /// Writes the language preference into AppleLanguages so the next launch
    /// picks it up. macOS applies locale changes at process start, so this
    /// only takes effect after the app restarts (matches CodexBar behavior).
    func applyLanguage() {
        let key = "AppleLanguages"
        if appLanguage.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([appLanguage], forKey: key)
        }
    }

    /// Registers/unregisters the app as a login item using the modern
    /// SMAppService.mainApp API (macOS 13+). Replaces the deprecated
    /// SMLoginItemSetEnabled which silently no-ops on signed bundles.
    func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            // Surface to console — SwiftUI binding still reflects user intent
            // even if the OS rejected the request (e.g. not signed).
            print("SMAppService error: \(error)")
        }
    }
}
