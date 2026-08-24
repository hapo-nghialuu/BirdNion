import AppKit
import SwiftUI

@MainActor
final class AgentDetailPanelCoordinator: NSObject, NSWindowDelegate {
    /// What the shared side panel is currently rendering — hover-driven day
    /// detail must never hijack a pinned agent/activity surface.
    private enum Content { case agent, activity, day }

    private let panelWidth: CGFloat = 340
    private let defaultHeight: CGFloat = 480
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var settings: SettingsStore?
    private var content: Content?
    /// Day panel opened by click (pinned) vs hover (transient).
    private var dayDetailPinned = false
    /// Generation token: a new hover cancels the pending transient close.
    private var transientCloseGeneration = 0

    func show(snapshot: AgentDetailSnapshot, settings: SettingsStore, beside parent: NSWindow) {
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .agent
        dayDetailPinned = false
        detailPanel.contentViewController = NSHostingController(
            rootView: AgentDetailPanelRoot(snapshot: snapshot)
                .environmentObject(settings)
                .ignoresSafeArea()
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
        content = .activity
        dayDetailPinned = false
        detailPanel.contentViewController = NSHostingController(
            rootView: ActivityPanelRoot(window: snapshot.overall)
                .environmentObject(settings)
                .ignoresSafeArea()
        )
        position(detailPanel, beside: parent)
        detailPanel.makeKeyAndOrderFront(nil)
        panel = detailPanel
    }

    /// Chart drill-down: hover shows a transient panel, click pins it.
    /// A pinned panel only closes via its × button (`closeDayDetail`).
    func showDayDetail(
        day: CombinedDailyUsage,
        pinned: Bool,
        windowUSD: Double,
        windowLabel: String,
        settings: SettingsStore,
        beside parent: NSWindow
    ) {
        transientCloseGeneration += 1
        if !pinned {
            // Hover không đè panel đang ghim hoặc surface agent/activity đang mở.
            if dayDetailPinned { return }
            if let panel, panel.isVisible, content != nil, content != .day { return }
        }
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .day
        dayDetailPinned = pinned
        detailPanel.contentViewController = NSHostingController(
            rootView: DayDetailPanelRoot(
                day: day, pinned: pinned,
                windowUSD: windowUSD, windowLabel: windowLabel)
                .environmentObject(settings)
                .ignoresSafeArea()
        )
        position(detailPanel, beside: parent)
        // orderFront (không makeKey) để hover không giật focus khỏi popover.
        detailPanel.orderFront(nil)
        panel = detailPanel
    }

    /// Hover-out: close after a short debounce, only while un-pinned — moving
    /// between adjacent bars re-enters before the deadline and keeps the panel.
    func closeDayDetailTransient() {
        guard content == .day, !dayDetailPinned else { return }
        transientCloseGeneration += 1
        let generation = transientCloseGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, self.content == .day, !self.dayDetailPinned,
                  self.transientCloseGeneration == generation else { return }
            self.panel?.orderOut(nil)
            self.content = nil
            NotificationCenter.default.post(name: .birdnionDayDetailClosed, object: nil)
        }
    }

    /// Explicit close from the panel's × button (or period switch).
    func closeDayDetail() {
        guard content == .day else { return }
        transientCloseGeneration += 1
        dayDetailPinned = false
        content = nil
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: .birdnionDayDetailClosed, object: nil)
    }

    func close() {
        dayDetailPinned = false
        content = nil
        panel?.orderOut(nil)
    }

    func update(snapshot: AgentDetailSnapshot) {
        guard let panel, let settings else { return }
        panel.contentViewController = NSHostingController(
            rootView: AgentDetailPanelRoot(snapshot: snapshot)
                .environmentObject(settings)
                .ignoresSafeArea()
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
            if content == .day {
                NotificationCenter.default.post(name: .birdnionDayDetailClosed, object: nil)
            }
            dayDetailPinned = false
            content = nil
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
        // Ẩn traffic lights hệ thống — mọi panel con đều có nút đóng riêng
        // trong nội dung, chấm đỏ/xám của titlebar chỉ làm bẩn giao diện.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
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
    static let birdnionOpenDayDetail = Notification.Name("com.local.birdnion.openDayDetail")
    static let birdnionCloseDayDetailTransient = Notification.Name(
        "com.local.birdnion.closeDayDetailTransient")
    static let birdnionCloseDayDetail = Notification.Name("com.local.birdnion.closeDayDetail")
    static let birdnionDayDetailClosed = Notification.Name("com.local.birdnion.dayDetailClosed")
}
