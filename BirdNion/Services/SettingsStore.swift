import SwiftUI
import ServiceManagement

enum MenuBarPercentDisplay {
    static let defaultsKey = "showPercentInMenuBar"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

/// Central user-preferences store. Each property uses `@AppStorage` so SwiftUI
/// views bind directly and values persist in UserDefaults automatically.
///
/// Real wiring: applyLanguage (writes AppleLanguages), setLaunchAtLogin
/// (SMAppService.mainApp), pushRefreshInterval (QuotaService), and menu-bar
/// percent visibility (AppDelegate/MenuBarIconRenderer).
@MainActor
final class SettingsStore: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case system = ""        // empty string = use AppleLanguages as-is
        case english = "en"
        case vietnamese = "vi"

        var id: String { rawValue }
        func displayName(language: String? = nil) -> String {
            switch self {
            case .system: L10n.t("language.system", language)
            case .english: L10n.t("language.english", language)
            case .vietnamese: L10n.t("language.vietnamese", language)
            }
        }
    }

    enum RefreshFrequency: Double, CaseIterable, Identifiable {
        /// 0 = manual: the background poll loop idles and only the popover's
        /// refresh button (or refresh-on-open) fetches. Matches CodexBar's
        /// `RefreshFrequency.manual`.
        case manual = 0
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case oneHour = 3600

        var id: Double { rawValue }
        func displayName(language: String? = nil) -> String {
            switch self {
            case .manual: L10n.t("settings.refresh.manual", language)
            case .oneMinute: L10n.duration(60, preference: language)
            case .twoMinutes: L10n.duration(120, preference: language)
            case .fiveMinutes: L10n.duration(300, preference: language)
            case .fifteenMinutes: L10n.duration(900, preference: language)
            case .oneHour: L10n.duration(3600, preference: language)
            }
        }
    }

    @AppStorage("appLanguage") var appLanguage: String = Language.system.rawValue
    /// App-wide appearance: light / dark / auto (follow macOS). Applied via
    /// `applyAppearance()` on launch and whenever the picker changes.
    @AppStorage("appAppearance") var appAppearance: String = AppAppearance.auto.rawValue
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
    /// Delivery options for quota warnings: notification sound + a brief
    /// on-screen overlay. `QuotaWarnConfig` reads the same keys.
    @AppStorage(QuotaWarnConfig.soundKey) var quotaWarningSoundEnabled: Bool = true
    @AppStorage(QuotaWarnConfig.alertKey) var quotaWarningOnScreenAlertEnabled: Bool = false
    /// Refresh every provider each time the menu-bar popover opens (CodexBar's
    /// `refreshAllProvidersOnMenuOpen`). `AppDelegate.showPanel()` reads this.
    @AppStorage("refreshOnMenuOpen") var refreshOnMenuOpen: Bool = false
    /// Debug: skip every macOS Keychain read. Key intentionally matches
    /// CodexBarCore's `KeychainAccessGate`, so the vendored cookie/web paths
    /// honor the same toggle for free; `ClaudeOAuth.readKeychainData` checks
    /// it too and falls back to the CLI credentials file.
    @AppStorage("debugDisableKeychainAccess") var debugDisableKeychainAccess: Bool = false
    /// Show each provider's on-disk data size in the Providers detail pane.
    /// `ProviderStorageScanner` only scans while this is on.
    @AppStorage("providerStorageFootprintsEnabled") var providerStorageFootprintsEnabled: Bool = false
    /// GitHub-releases update check (About pane). Auto-check runs at launch,
    /// throttled to once a day by `UpdateChecker`.
    @AppStorage("updateAutoCheckEnabled") var updateAutoCheckEnabled: Bool = true
    /// "stable" hides GitHub prereleases; "beta" includes them.
    @AppStorage("updateChannel") var updateChannel: String = "stable"
    @AppStorage("hidePersonalInfo") var hidePersonalInfo: Bool = false
    @AppStorage(MenuBarPercentDisplay.defaultsKey) var showPercentInMenuBar: Bool = false
    @AppStorage("mergeIcons") var mergeIcons: Bool = true
    @AppStorage("switcherShowsIcons") var switcherShowsIcons: Bool = true
    /// MiniMax API host region: "io" (global) or "com" (mainland China).
    /// `MiniMaxProvider` reads the same UserDefaults key directly.
    /// Codex 5h-window auto-prime: opt-in scheduled `codex exec` that starts
    /// the rate-limit clock at a predictable time. `codexAutoPrimeMinutes` is
    /// minutes-since-midnight (0..1439; default 535 = 08:55). `LastRun` is the
    /// dedup cursor (epoch seconds, 0 = never) — `CodexQuotaPrimer` reads/writes
    /// these same keys directly via `UserDefaults.standard`.
    @AppStorage("codexAutoPrimeEnabled") var codexAutoPrimeEnabled: Bool = false
    @AppStorage("codexAutoPrimeMinutes") var codexAutoPrimeMinutes: Int = 535
    @AppStorage("codexAutoPrimeLastRun") var codexAutoPrimeLastRun: Double = 0
    @AppStorage(MiniMaxRegion.defaultsKey) var minimaxRegion: String = MiniMaxRegion.io.rawValue
    /// Z.ai / GLM API host region (global vs BigModel CN). `ZaiProvider` reads
    /// the same UserDefaults key directly.
    @AppStorage(ZaiRegion.defaultsKey) var zaiRegion: String = ZaiRegion.global.rawValue
    @AppStorage(AlibabaRegion.defaultsKey) var alibabaRegion: String = AlibabaRegion.international.rawValue
    /// Which Codex window drives the menu bar percent. `MenuBarIconRenderer`
    /// reads the same UserDefaults key directly.
    @AppStorage(CodexMenuBarMetric.defaultsKey) var codexMenuBarMetric: String = CodexMenuBarMetric.automatic.rawValue
    /// Codex usage source (auto/oauth/cli). `CodexProvider` reads the same key.
    @AppStorage(CodexUsageSource.defaultsKey) var codexUsageSource: String = CodexUsageSource.auto.rawValue
    /// Antigravity usage source (auto/app/ide/cli/oauth). `AntigravityProvider` reads the same key.
    @AppStorage(AntigravityUsageSource.defaultsKey) var antigravityUsageSource: String = AntigravityUsageSource.auto.rawValue
    /// Kilo usage source (auto/api/cli). `KiloProvider` reads the same key.
    @AppStorage(KiloUsageSource.defaultsKey) var kiloUsageDataSource: String = KiloUsageSource.auto.rawValue
    /// Selected Kilo quota scope: org id + cached name ("" = personal account).
    /// `KiloProvider` reads these keys to send `X-KILOCODE-ORGANIZATIONID`.
    @AppStorage(KiloUsageScope.orgIDKey) var kiloOrgID: String = ""
    @AppStorage(KiloUsageScope.orgNameKey) var kiloOrgName: String = ""
    /// How Kiro's quota is shown in the menu bar (credits/percent/used÷total/
    /// overage). `MenuBarIconRenderer` reads the same key.
    @AppStorage(KiroMenuBarDisplayMode.defaultsKey) var kiroMenuBarDisplayMode: String = KiroMenuBarDisplayMode.automatic.rawValue

    /// OpenAI web extras for Codex (off by default — loads chatgpt.com in a
    /// hidden WebView, heavier on battery/network). `CodexWebDashboard` reads
    /// these keys directly.
    @AppStorage(CodexWebDashboard.enabledKey) var codexOpenAIWebEnabled: Bool = false
    @AppStorage(CodexWebDashboard.cookieSourceKey) var codexCookieSource: String = "auto"
    @AppStorage(CodexWebDashboard.manualCookieKey) var codexManualCookieHeader: String = ""

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
    /// Forces the app-wide appearance (or clears the override for `auto`).
    /// NSApp.appearance cascades to every window including the popover panel.
    func applyAppearance() {
        let choice = AppAppearance(rawValue: appAppearance) ?? .auto
        NSApp.appearance = choice.nsAppearance
    }

    func applyLanguage() {
        objectWillChange.send()
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
