import SwiftUI

@main
struct BirdNionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var config: ConfigService
    @State private var quota: QuotaService

    init() {
        let services = ServicesContainer()
        ServicesContainer.register(services: services)
        _settings = State(initialValue: services.settings)
        _config = State(initialValue: services.configService)
        _quota = State(initialValue: services.quotaService)
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
        }
        .defaultSize(width: 720, height: 620)
    }
}
