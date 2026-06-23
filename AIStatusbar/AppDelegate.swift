import AppKit
import SwiftUI
import Combine

/// Borderless panel used as the menu-bar dropdown. Unlike NSPopover it draws
/// no triangular arrow and can be positioned freely. It must be allowed to
/// become key so the SwiftUI buttons inside it receive clicks.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// AppDelegate creates the NSStatusItem (menu bar icon) programmatically and
/// manages a borderless DropdownPanel for the popover content. The menu bar
/// icon is a dynamic NSImage redrawn from the latest QuotaService statuses.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServicesContainer()
    private var statusItem: NSStatusItem!
    private var panel: DropdownPanel!
    private var hostingController: NSHostingController<AnyView>!
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    /// Screen-space Y of the panel's top edge while shown, so height changes
    /// (e.g. switching to the settings section) grow downward, not upward.
    private var panelTopY: CGFloat?

    // Fixed width; height is driven by the SwiftUI content's fitting size.
    private let panelWidth: CGFloat = 420
    /// Pixels the panel is nudged up toward the menu bar from its anchor.
    private let topNudge: CGFloat = 10

    // Menu bar rotation: per-(provider, window) slots, advanced by a timer.
    private var slots: [MenuBarIconRenderer.Slot] = []
    private var slotIndex: Int = 0
    private var rotationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings(_:)),
            name: .openSettings, object: nil
        )

        // Status bar item — variable length so the title text fits; the
        // icon is the bundled bird and the title is the rotating percentage.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.image = MenuBarIconRenderer.iconImage()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageLeft
            // AppKit's NSButtonCell exposes no public imagePadding/
            // titlePadding on macOS — the menu bar button always keeps a
            // small internal gap between image and title. We compensate
            // by setting a tiny leading space on the title string so the
            // visual distance still feels tight without overflowing.
            // Use the system monospaced digit font so the title width stays
            // stable as the digits change.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        }
        applyCurrentSlot()

        // SwiftUI content hosted in a controller that reports its fitting
        // size, so we can resize the panel to hug the content.
        let host = NSHostingController(
            rootView: AnyView(
                PopoverView()
                    .environmentObject(services.quotaService)
                    .environmentObject(services.configService)
                    .environmentObject(services.keychain)
            )
        )
        host.sizingOptions = [.preferredContentSize]
        hostingController = host

        // Borderless, non-activating panel — no arrow, floats above windows.
        let p = DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentViewController = host
        // Round the corners of the hosted content; the panel itself stays
        // clear so the rounded edges are transparent and the shadow follows.
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = 16
        p.contentView?.layer?.masksToBounds = true
        panel = p

        // Resize the panel whenever the SwiftUI content's preferred size
        // changes (loading -> loaded, quota -> settings section, etc.).
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor in self?.resizePanelToContent() }
        }

        // Re-render the menu bar title whenever QuotaService publishes.
        services.quotaService.$statuses
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in self?.updateSlots(from: statuses) }
            .store(in: &cancellables)

        installClickOutsideMonitor()
    }

    // MARK: - Show / hide

    @objc func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Force a layout pass so fittingSize is valid on the first open.
        hostingController.view.layoutSubtreeIfNeeded()
        let height = max(1, hostingController.view.fittingSize.height)

        // Anchor: just below the status item button, centered, nudged up.
        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let topY = buttonRect.minY + topNudge
        panelTopY = topY
        var originX = buttonRect.midX - panelWidth / 2
        let originY = topY - height

        // Clamp horizontally so the panel stays on screen.
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let margin: CGFloat = 8
            originX = min(max(originX, vf.minX + margin), vf.maxX - panelWidth - margin)
        }

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: height),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        panelTopY = nil
    }

    /// Keep the top edge fixed and grow/shrink downward when the content
    /// height changes while the panel is visible.
    private func resizePanelToContent() {
        guard panel.isVisible else { return }
        hostingController.view.layoutSubtreeIfNeeded()
        let height = max(1, hostingController.view.fittingSize.height)
        let frame = panel.frame
        let top = panelTopY ?? frame.maxY
        panel.setFrame(
            NSRect(x: frame.origin.x, y: top - height, width: panelWidth, height: height),
            display: true
        )
    }

    // MARK: - Click-outside dismissal

    private func installClickOutsideMonitor() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            self.closePanelIfClickOutside(event: event)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.panel.isVisible { self.hidePanel() }
            }
        }
    }

    private func closePanelIfClickOutside(event: NSEvent) {
        guard panel.isVisible else { return }
        // A click inside the panel's own window is delivered to that window;
        // only dismiss when the event targets a different window.
        if event.window == panel { return }
        // Clicking the status item button toggles the panel itself.
        if let button = statusItem.button, event.window == button.window { return }
        hidePanel()
    }

    private func refreshIcon(statuses: [ProviderStatus] = []) {
        // Legacy entry point kept for compatibility with any caller passing
        // the old signature; the menu bar title is now driven by
        // updateSlots(from:) + applyCurrentSlot().
        updateSlots(from: statuses)
    }

    // MARK: - Menu bar rotation

    /// How long each (provider, window) slot is shown before advancing.
    private let slotDuration: TimeInterval = 5.0

    /// Recompute the list of slots from the latest statuses and restart
    /// the rotation timer. When the list shrinks (a provider disappears
    /// or hits an error), the next slot is the one after the previously
    /// shown one, clamped to the new bounds.
    private func updateSlots(from statuses: [ProviderStatus]) {
        let newSlots = MenuBarIconRenderer.slots(from: statuses)
        let wasEmpty = slots.isEmpty
        slots = newSlots
        if slots.isEmpty {
            slotIndex = 0
            rotationTimer?.invalidate()
            rotationTimer = nil
        } else {
            // Keep advancing position when possible so the rotation feels
            // continuous after a refresh.
            if slotIndex >= slots.count { slotIndex = 0 }
            startRotationTimer()
        }
        applyCurrentSlot()
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        let t = Timer(timeInterval: slotDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceSlot() }
        }
        // .common so it fires during menu tracking too.
        RunLoop.main.add(t, forMode: .common)
        rotationTimer = t
    }

    private func advanceSlot() {
        guard !slots.isEmpty else { return }
        slotIndex = (slotIndex + 1) % slots.count
        applyCurrentSlot()
    }

    /// Push the current slot's text to the status bar button. The icon is
    /// always the bird; only the title changes.
    private func applyCurrentSlot() {
        guard let button = statusItem?.button else { return }
        guard let slot = slots.indices.contains(slotIndex) ? slots[slotIndex] : nil else {
            button.title = ""
            return
        }
        // One thin space between the icon and the digits. The button cell
        // already inserts a couple of points of padding, so a single space
        // is enough to keep them readable without floating far apart.
        button.title = " \(slot.remainingPct)%"
    }

    // Cmd+, / menu "Settings" — open the panel (if closed) and switch to the
    // Providers section inline. PopoverView listens for `.openSettings`.
    @objc func openSettings(_ sender: AnyObject?) {
        if !panel.isVisible {
            showPanel()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        services.stop()
    }
}
