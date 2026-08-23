import AppKit
import SwiftUI

@MainActor
final class AgentDetailPanelCoordinator: NSObject, NSWindowDelegate {
    private let panelWidth: CGFloat = 340
    private let defaultHeight: CGFloat = 480
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var settings: SettingsStore?

    func show(snapshot: AgentDetailSnapshot, settings: SettingsStore, beside parent: NSWindow) {
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        detailPanel.contentViewController = NSHostingController(
            rootView: AgentDetailPanelRoot(snapshot: snapshot)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        detailPanel.makeKeyAndOrderFront(nil)
        panel = detailPanel
    }

    func showActivity(
        snapshot: AgentActivitySnapshot,
        settings: SettingsStore,
        beside parent: NSWindow
    ) {
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        detailPanel.contentViewController = NSHostingController(
            rootView: ActivityPanelRoot(window: snapshot.overall)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        detailPanel.makeKeyAndOrderFront(nil)
        panel = detailPanel
    }

    func close() {
        panel?.orderOut(nil)
    }

    func update(snapshot: AgentDetailSnapshot) {
        guard let panel, let settings else { return }
        panel.contentViewController = NSHostingController(
            rootView: AgentDetailPanelRoot(snapshot: snapshot)
                .environmentObject(settings)
        )
    }

    func contains(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panel === window
    }

    func repositionIfNeeded() {
        guard let panel, let parentWindow else { return }
        position(panel, beside: parentWindow)
    }

    func windowWillClose(_ notification: Notification) {
        if let current = notification.object as? NSWindow, current === panel {
            NotificationCenter.default.post(name: .birdnionInvalidateAgentPanelRequests, object: nil)
            panel = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    private func position(_ panel: NSPanel, beside parent: NSWindow) {
        let parentFrame = parent.frame
        let screen = parent.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(panel.frame.height, max(320, visible.height - 16))
        let preferredRightX = parentFrame.maxX + 8
        let rightFits = preferredRightX + panelWidth <= visible.maxX - 8
        let originX = rightFits
            ? preferredRightX
            : max(visible.minX + 8, parentFrame.minX - panelWidth - 8)
        let originY = min(
            max(visible.minY + 8, parentFrame.maxY - height),
            visible.maxY - height - 8
        )
        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: height),
            display: true
        )
    }
}

extension Notification.Name {
    static let birdnionOpenAgentDetail = Notification.Name("com.local.birdnion.openAgentDetail")
    static let birdnionUpdateAgentDetail = Notification.Name("com.local.birdnion.updateAgentDetail")
    static let birdnionCloseAgentDetail = Notification.Name("com.local.birdnion.closeAgentDetail")
    static let birdnionOpenAgentActivity = Notification.Name("com.local.birdnion.openAgentActivity")
    static let birdnionInvalidateAgentPanelRequests = Notification.Name(
        "com.local.birdnion.invalidateAgentPanelRequests")
}
