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
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                Task { @MainActor in
                    self.openSettings()
                }
            }
            .onAppear {
                if let window = NSApp.windows.first(where: { $0.title == "BirdNionLifecycleKeepalive" }) {
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
                }
            }
    }
}
