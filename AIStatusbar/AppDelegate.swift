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

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings(_:)),
            name: .openSettings, object: nil
        )

        // Status bar item — dynamic bird icon, redrawn once at launch.
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        refreshIcon()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
        }

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

        // Re-render the menu bar icon whenever QuotaService publishes.
        services.quotaService.$statuses
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in self?.refreshIcon(statuses: statuses) }
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
        let image = MenuBarIconRenderer.image(statuses: statuses)
        image.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageOnly
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
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        services.stop()
    }
}
