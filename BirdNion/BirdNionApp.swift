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
        AppFonts.registerBundledFonts()
        do {
            try CostUsageFetcher.performPrivacyMigrations()
        } catch {
            NSLog("BirdNion privacy migration failed: %@", error.localizedDescription)
        }
        let services = ServicesContainer()
        ServicesContainer.register(services: services)
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
