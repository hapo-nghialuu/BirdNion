import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("birdnion.openSettingsWindow")
}

/// Invisible keep-alive scene that owns SwiftUI's `openSettings` environment
/// action. Mirrors CodexBar's approach: keep the window alive for SwiftUI,
/// but make it borderless, transparent, non-interactive, and off-screen.
struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .background(KeepaliveWindowConfigurator())
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { notification in
                // Ack so AppDelegate/SettingsWindowOpener know the SwiftUI
                // path ran (login-item launches sometimes miss this view).
                (notification.object as? SettingsOpenRequest)?.wasHandled = true
                Task { @MainActor in
                    self.openSettings()
                }
            }
    }
}

/// Configures the keepalive WindowGroup via the hosting NSView's window —
/// more reliable than matching by title in `onAppear` (title can lag / differ
/// after a login-item cold start).
@MainActor
private struct KeepaliveWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> KeepaliveWindowConfiguratorView {
        KeepaliveWindowConfiguratorView()
    }

    func updateNSView(_ nsView: KeepaliveWindowConfiguratorView, context: Context) {}
}

@MainActor
private final class KeepaliveWindowConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("BirdNionLifecycleKeepalive")
        window.styleMask = [.borderless]
        window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient, .canJoinAllSpaces]
        window.isExcludedFromWindowsMenu = true
        window.level = .floating
        window.isOpaque = false
        window.alphaValue = 0
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.setContentSize(NSSize(width: 1, height: 1))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        SettingsWindowOpener.markKeepaliveReady()
    }
}
