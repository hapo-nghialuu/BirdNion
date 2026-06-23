import SwiftUI

/// 1×1 keep-alive window so SwiftUI's lifecycle stays alive when the only
/// other top-level scene is `Settings`. It also bridges AppKit → SwiftUI:
/// AppDelegate can't call the `openSettings` environment action directly, so
/// it posts `.openSettingsWindow` and this view (which lives in a real scene)
/// invokes the action. Same trick CodexBar uses in `CodexbarApp.swift`.
struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                openSettings()
            }
    }
}
