import CodexBarCore
import SwiftUI

@main
struct BirdNionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var config: ConfigService
    @State private var quota: QuotaService
    @State private var installedAgents: InstalledAgentCatalog
    @State private var agentVisibility: InstalledAgentVisibilityStore
    init() {
        // CLI mode: `birdnion usage --json`, `serve`, `config import`, …
        // skips the GUI path entirely — AppDelegate branches on `active`.
        if BirdNionCLI.wantsCLIMode(ProcessInfo.processInfo.arguments) {
            BirdNionCLI.activate()
        }
        AppFonts.registerBundledFonts()
        do {
            try CostUsageFetcher.performPrivacyMigrations()
        } catch {
            NSLog("BirdNion privacy migration failed: %@", error.localizedDescription)
        }
        let services = ServicesContainer()
        ServicesContainer.register(services: services)
        // CLI runs never consume queued imports (they can only queue them)
        // and don't need display-currency rates.
        if !BirdNionCLI.active {
            services.settings.consumePendingPreferencesImport()
            Task {
                await CurrencyExchange.shared
                    .fetchLatestRatesIfNeeded(preferredCurrencyCode: PreferredCurrency.preference)
            }
        }
        _settings = State(initialValue: services.settings)
        _config = State(initialValue: services.configService)
        _quota = State(initialValue: services.quotaService)
        _installedAgents = State(initialValue: services.installedAgents)
        _agentVisibility = State(initialValue: services.agentVisibility)
    }

    var body: some Scene {
        WindowGroup("BirdNionLifecycleKeepalive") {
            HiddenWindowView()
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsSceneRoot()
                .environmentObject(settings)
                .environmentObject(config)
                .environmentObject(quota)
                .environmentObject(installedAgents)
                .environmentObject(agentVisibility)
        }
        .defaultSize(width: 920, height: 620)
    }
}
