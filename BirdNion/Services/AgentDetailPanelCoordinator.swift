import AppKit
import SwiftUI

@MainActor
final class AgentDetailPanelCoordinator: NSObject, NSWindowDelegate {
    /// What the shared side panel is currently rendering — hover-driven day
    /// detail must never hijack a pinned agent/activity surface.
    private enum Content { case agent, activity, day, models, quotaAgenda }

    private let panelWidth: CGFloat = 340
    private let defaultHeight: CGFloat = 480
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var settings: SettingsStore?
    private var content: Content?
    /// Agent đang hiển thị trong panel — để click cùng agent lần nữa = toggle đóng.
    private var currentAgentID: InstalledAgentID?
    private var quotaAgendaSelection: ((String) -> Void)?
    /// Panel đang ghim (mở bằng click) hay transient (mở bằng hover).
    private var contentPinned = false
    /// Generation token: a new hover cancels the pending transient close.
    private var transientCloseGeneration = 0

    func show(snapshot: AgentDetailSnapshot, settings: SettingsStore, beside parent: NSWindow, pinned: Bool = true, initialTab: String? = nil) {
        transientCloseGeneration += 1
        if pinned, let panel, panel.isVisible, contentPinned,
           content == .agent, currentAgentID == snapshot.id {
            // Toggle: click lại đúng agent đang ghim → đóng.
            NotificationCenter.default.post(name: .birdnionInvalidateAgentPanelRequests, object: nil)
            close()
            return
        }
        // Hover không đè panel đang ghim.
        if !pinned, contentPinned { return }
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .agent
        quotaAgendaSelection = nil
        currentAgentID = snapshot.id
        contentPinned = pinned
        detailPanel.contentViewController = hostController(
            for: AgentDetailPanelRoot(snapshot: snapshot, initialTab: initialTab)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        applyPanelChrome(detailPanel)
        if pinned { detailPanel.makeKeyAndOrderFront(nil) } else { detailPanel.orderFront(nil) }
        panel = detailPanel
    }

    func showActivity(
        snapshot: AgentActivitySnapshot,
        dayModels: [Date: [CombinedModelCost]] = [:],
        settings: SettingsStore,
        beside parent: NSWindow,
        pinned: Bool = true
    ) {
        transientCloseGeneration += 1
        if !pinned, contentPinned { return }
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .activity
        quotaAgendaSelection = nil
        currentAgentID = nil
        contentPinned = pinned
        detailPanel.contentViewController = hostController(
            for: ActivityPanelRoot(window: snapshot.overall, dayModels: dayModels)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        applyPanelChrome(detailPanel)
        if pinned { detailPanel.makeKeyAndOrderFront(nil) } else { detailPanel.orderFront(nil) }
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
        // Hover không đè panel đang ghim; transient thay transient thoải mái.
        if !pinned, contentPinned { return }
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .day
        quotaAgendaSelection = nil
        currentAgentID = nil
        contentPinned = pinned
        detailPanel.contentViewController = hostController(
            for: DayDetailPanelRoot(
                day: day, pinned: pinned,
                windowUSD: windowUSD, windowLabel: windowLabel)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        applyPanelChrome(detailPanel)
        // orderFront (không makeKey) để hover không giật focus khỏi popover.
        detailPanel.orderFront(nil)
        panel = detailPanel
    }

    /// Danh sách model tràn ("+N more models") — hover-only, không ghim.
    func showModelList(
        items: [AgentModelRow],
        mode: String,
        settings: SettingsStore,
        beside parent: NSWindow
    ) {
        transientCloseGeneration += 1
        if contentPinned { return }
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .models
        quotaAgendaSelection = nil
        currentAgentID = nil
        contentPinned = false
        detailPanel.contentViewController = hostController(
            for: ModelOverflowPanelRoot(items: items, mode: mode)
                .environmentObject(settings)
        )
        position(detailPanel, beside: parent)
        applyPanelChrome(detailPanel)
        detailPanel.orderFront(nil)
        panel = detailPanel
    }

    /// Footer action: show a pinned Quota Agenda in the existing companion
    /// panel. Opening it does not mutate the selected provider in the parent.
    func showQuotaAgenda(
        items: [QuotaAgendaPanelItem],
        settings: SettingsStore,
        beside parent: NSWindow,
        onSelectProvider: @escaping (String) -> Void
    ) {
        transientCloseGeneration += 1
        let detailPanel = panel ?? makePanel()
        parentWindow = parent
        self.settings = settings
        content = .quotaAgenda
        currentAgentID = nil
        contentPinned = true
        quotaAgendaSelection = onSelectProvider
        installQuotaAgenda(items, in: detailPanel, settings: settings)
        refit(panel: detailPanel)
        position(detailPanel, beside: parent)
        applyPanelChrome(detailPanel)
        detailPanel.makeKeyAndOrderFront(nil)
        panel = detailPanel
    }

    /// Hover-out: đóng sau debounce ngắn, chỉ khi chưa ghim — rê chuột giữa
    /// các phần tử liền kề sẽ re-enter trước deadline và giữ panel.
    func closeTransient() {
        guard content != nil, !contentPinned else { return }
        transientCloseGeneration += 1
        let generation = transientCloseGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, self.content != nil, !self.contentPinned,
                  self.transientCloseGeneration == generation else { return }
            let wasDay = self.content == .day
            self.panel?.orderOut(nil)
            self.content = nil
            self.currentAgentID = nil
            if wasDay {
                NotificationCenter.default.post(name: .birdnionDayDetailClosed, object: nil)
            }
        }
    }

    /// Explicit close from the panel's × button (or period switch).
    func closeDayDetail() {
        guard content == .day else { return }
        transientCloseGeneration += 1
        contentPinned = false
        content = nil
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: .birdnionDayDetailClosed, object: nil)
    }

    func close() {
        contentPinned = false
        content = nil
        currentAgentID = nil
        quotaAgendaSelection = nil
        panel?.orderOut(nil)
    }

    func update(snapshot: AgentDetailSnapshot) {
        guard content == .agent, let panel, let settings else { return }
        panel.contentViewController = hostController(
            for: AgentDetailPanelRoot(snapshot: snapshot)
                .environmentObject(settings)
        )
        applyPanelChrome(panel)
    }

    func updateQuotaAgenda(items: [QuotaAgendaPanelItem]) {
        guard content == .quotaAgenda, let panel, panel.isVisible, let settings else { return }
        installQuotaAgenda(items, in: panel, settings: settings)
        refit(panel: panel)
        if let parentWindow { position(panel, beside: parentWindow) }
        applyPanelChrome(panel)
    }

    /// Đổi tab trong panel làm nội dung đổi chiều cao — đo lại fitting size
    /// của hosting view và co khung panel cho khít (height-auto, không scroll).
    func refitToContent() {
        guard let panel, let view = panel.contentViewController?.view else { return }
        panel.setContentSize(view.fittingSize)
        if let parentWindow { position(panel, beside: parentWindow) }
        applyPanelChrome(panel)
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
            contentPinned = false
            content = nil
            currentAgentID = nil
            quotaAgendaSelection = nil
            panel = nil
        }
    }

    /// Hosting controller with the titlebar safe area disabled — the hidden
    /// titled bar otherwise pads the fitting size, leaving a blank strip at
    /// the top (content pushed down) or bottom (auto-height overshoot).
    private func hostController<V: View>(for view: V) -> NSHostingController<V> {
        let host = NSHostingController(rootView: view)
        host.safeAreaRegions = []
        return host
    }

    private func installQuotaAgenda(
        _ items: [QuotaAgendaPanelItem],
        in panel: NSPanel,
        settings: SettingsStore
    ) {
        panel.contentViewController = hostController(
            for: QuotaAgendaPanelRoot(
                items: items,
                onSelectProvider: { [weak self] providerID in
                    let selection = self?.quotaAgendaSelection
                    self?.close()
                    selection?(providerID)
                },
                onClose: { [weak self] in self?.close() }
            )
            .environmentObject(settings)
        )
    }

    private func refit(panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        panel.setContentSize(view.fittingSize)
    }

    private func makePanel() -> NSPanel {
        // Borderless: window KHÔNG có chrome hệ thống — hết viền xám quanh
        // shadow và hết corner mask ~10pt đè lên radius 3 của content.
        // .nonactivatingPanel giữ được key khi cần mà không activate app.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Nền window trong suốt để bo góc 3pt của content là hình dạng thật.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Đồng bộ popover chính: không shadow hệ thống → không rim xám.
        panel.hasShadow = false
        return panel
    }

    /// Bo góc 3pt cho content — phải re-apply mỗi lần contentViewController
    /// bị thay (content view mới chưa có layer mask).
    private func applyPanelChrome(_ panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 3
        content.layer?.masksToBounds = true
    }

    private func position(_ panel: NSPanel, beside parent: NSWindow) {
        let parentFrame = parent.frame
        let screen = parent.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Gap 4pt — panel con nép sát cạnh popover chính.
        let height = min(panel.frame.height, max(320, visible.height - 16))
        let preferredRightX = parentFrame.maxX + 4
        let rightFits = preferredRightX + panelWidth <= visible.maxX - 8
        let originX = rightFits
            ? preferredRightX
            : max(visible.minX + 8, parentFrame.minX - panelWidth - 4)
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
    static let birdnionAgentPanelRefit = Notification.Name("com.local.birdnion.agentPanelRefit")
    static let birdnionOpenModelList = Notification.Name("com.local.birdnion.openModelList")
    static let birdnionOpenQuotaAgenda = Notification.Name("com.local.birdnion.openQuotaAgenda")
    static let birdnionUpdateQuotaAgenda = Notification.Name("com.local.birdnion.updateQuotaAgenda")
    static let birdnionSelectProviderTab = Notification.Name("com.local.birdnion.selectProviderTab")
}
