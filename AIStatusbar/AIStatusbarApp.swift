import SwiftUI

/// Notification name the AppDelegate uses to ask SwiftUI to open the
/// settings window. We can't call `openWindow` directly from AppDelegate
/// (it's an environment value), so we go through NotificationCenter.
extension Notification.Name {
    static let openSettingsWindow = Notification.Name("aistatusbar.openSettingsWindow")
}

@main
struct AIStatusbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var keychain: KeychainService
    @State private var config: ConfigService
    @State private var quota: QuotaService

    init() {
        let services = ServicesContainer()
        ServicesContainer.register(services: services)
        _settings = State(initialValue: services.settings)
        _keychain = State(initialValue: services.keychain)
        _config = State(initialValue: services.configService)
        _quota = State(initialValue: services.quotaService)
    }

    var body: some Scene {
        // 1×1 keep-alive so the AppKit shell stays alive while the Settings
        // window is closed.
        WindowGroup("AIStatusbarLifecycleKeepalive") {
            HiddenWindowView()
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        // Native SwiftUI Settings scene. SwiftUI owns this window, so there's
        // no hand-built NSWindow + NSHostingView to drive NSISEngine into
        // recursion. AppDelegate brings the app forward and HiddenWindowView
        // calls the `openSettings` environment action to present it.
        Settings {
            SettingsSceneRoot()
                .environmentObject(settings)
                .environmentObject(keychain)
                .environmentObject(config)
                .environmentObject(quota)
        }
        .windowResizability(.contentSize)
    }
}
