import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Global hotkey that toggles the quota popover (recorded in
    /// Settings → General). No default — the user opts in.
    static let openPopover = Self("openPopover")
}

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
    /// Use the ServicesContainer already registered by `BirdNionApp.init`
    /// so the Settings scene and AppDelegate share the exact same instances.
    var services: ServicesContainer {
        ServicesContainer.shared ?? {
            assertionFailure("ServicesContainer not registered; check BirdNionApp.init")
            return ServicesContainer()
        }()
    }
    private var statusItem: NSStatusItem!
    /// Right-click / Ctrl-click menu for the status item. Kept off
    /// `statusItem.menu` so a left click still toggles the quota popover; it's
    /// attached only for the duration of a right-click (see `togglePanel`).
    private var statusMenu: NSMenu?
    private weak var settingsMenuItem: NSMenuItem?
    private var panel: DropdownPanel!
    private var hostingController: NSHostingController<AnyView>!
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    /// Screen-space Y of the panel's top edge while shown, so height changes
    /// (e.g. switching to the settings section) grow downward, not upward.
    private var panelTopY: CGFloat?
    /// True for as long as the popover's "all" tab is selected. While true,
    /// the panel is pinned at `maxPanelHeight` regardless of the tall All
    /// content's own fitting size, so no in-tab interaction (period picker,
    /// bar pin, heatmap cell select — anything that changes what
    /// `AllUsageOverview` renders) ever resizes the outer panel. That outer
    /// resize is what raced with SwiftUI's own layout pass and recursed
    /// NSISEngine to a stack overflow (see `preExpandPanelForTallTab`); by
    /// keeping the frame constant for the tab's whole lifetime, the internal
    /// ScrollView absorbs every content-height change instead.
    private var isAllTabActive = false

    // Fixed width; height is driven by the SwiftUI content's fitting size.
    private let panelWidth: CGFloat = 420
    /// Hard height cap. Clamping only to the screen still let the panel span
    /// menu bar → screen bottom on tall displays, leaving a scroll range of a
    /// few px that reads as "scrolling is broken". Capping guarantees the
    /// content ScrollView has a real scroll range on tall tabs.
    private let maxPanelHeight: CGFloat = 640
    /// Pixels the panel is nudged up toward the menu bar from its anchor.
    private let topNudge: CGFloat = 10

    // Menu bar frames: either the bird, or provider percent frames when
    // enabled in Display settings.
    private var frames: [MenuBarIconRenderer.Frame] = [.bird]
    private var frameIndex: Int = 0
    private var rotationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
        // Restore the user's appearance choice before any window shows.
        services.settings.applyAppearance()
        Task { @MainActor in
            await EmbeddedCLIProxyService.shared.restoreIfConfigured()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings(_:)),
            name: .openSettings, object: nil
        )
        // Listen for menu-bar visibility toggles so the menu-bar frame rebuilds
        // immediately when the user flips a provider off the bar.
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBarVisibilityDidChange(_:)),
            name: .menuBarVisibilityChanged, object: nil
        )
        // Listen for provider-list changes (reorder / toggle from the
        // Settings sidebar) so the popover + menu-bar frame pick up
        // the new order without an app restart.
        NotificationCenter.default.addObserver(
            self, selector: #selector(providersDidChange(_:)),
            name: .birdnionProvidersChanged, object: nil
        )

        // Status bar item — variable length so the optional percent text fits.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Receive both clicks so we can route them ourselves: left toggles
            // the quota popover, right shows the Settings menu. Assigning
            // `statusItem.menu` directly would make AppKit swallow the left
            // click and always show the menu instead.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Build the right-click menu (Settings…). Cmd+, is handled by the
            // global key monitor below, not by this menu's keyEquivalent —
            // an LSUIElement app doesn't own the system Cmd+, chain, so the
            // shortcut only works while the menu is already open otherwise.
            let menu = NSMenu()
            let settingsItem = NSMenuItem(
                title: L10n.t("popover.settings", services.settings.appLanguage),
                action: #selector(openSettings(_:)),
                keyEquivalent: ",")
            settingsItem.keyEquivalentModifierMask = [.command]
            settingsItem.target = self
            menu.addItem(settingsItem)
            self.settingsMenuItem = settingsItem
            statusMenu = menu

            button.image = MenuBarIconRenderer.iconImage()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            // System monospaced digit font so the quota numbers keep a stable
            // width as the digits change frame to frame.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        }
        applyCurrentFrame()

        // SwiftUI content hosted in a controller that reports its fitting
        // size, so we can resize the panel to hug the content.
        let host = NSHostingController(
            rootView: AnyView(
                PopoverView()
                    .environmentObject(services.quotaService)
                    .environmentObject(services.configService)
                    .environmentObject(services.settings)
            )
        )
        // Deliberately NO `.preferredContentSize` sizing option: with it,
        // AppKit queries `preferredContentSize` during its own
        // update-constraints pass; the query runs a SwiftUI graph update,
        // and any resulting `setNeedsUpdateConstraints` re-post mid-flush
        // raises an NSException (`_postWindowNeedsUpdateConstraints`) that
        // crashes the app — reproduced deterministically at launch whenever
        // boot-time data changed what the popover renders (2026-07-23).
        // Height now flows the other way: PopoverView posts
        // `.birdnionPopoverContentHeightChanged` as a change trigger, and the
        // panel resizes explicitly via `hostingController.view.fittingSize`
        // (see `resizePanelToContent`).
        hostingController = host

        // Borderless, non-activating panel — no arrow, floats above windows.
        // contentSize height is capped (maxPanelHeight) so tall tabs scroll;
        // seeding it on creation gives the hosting view a stable initial
        // size before the first content-height report lands.
        let p = DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: maxPanelHeight),
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

        // Resize the panel whenever the SwiftUI content's natural height
        // changes (loading -> loaded, tab switch, data landing). This
        // notification (PopoverView's GeometryReader preference) is only the
        // trigger — a plain SwiftUI value change, safe to observe. The actual
        // height comes from `hostingController.view.fittingSize`, AppKit's own
        // Auto Layout measurement, which the GeometryReader route under-reports
        // by the ScrollView's own content margins (left the popover a few
        // points short of its content, showing a spurious scrollbar). Deferred
        // via Task so it runs on a fresh run-loop turn, after the SwiftUI
        // update pass that triggered the preference has fully completed —
        // never inside AppKit's own update-constraints flush.
        NotificationCenter.default.publisher(for: .birdnionPopoverContentHeightChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.resizePanelToContent() }
            }
            .store(in: &cancellables)

        // Pre-expand to cap height when the user opens the All tab, before
        // SwiftUI mutates selected tab and lays out AllUsageOverview.
        // Synchronous on the posting thread (main) — must not wrap in Task.
        NotificationCenter.default.publisher(for: .birdnionAllTabWillOpen)
            .sink { [weak self] _ in self?.preExpandPanelForTallTab() }
            .store(in: &cancellables)

        // Release the height pin when the user leaves the All tab. Just
        // flips the flag — the content-height subscriber above fires its own
        // resizePanelToContent() once PopoverView reports the new (non-all)
        // tab's real content height, which by then reads the flag as false
        // and hugs that content instead of staying pinned to the cap.
        NotificationCenter.default.publisher(for: .birdnionAllTabDidClose)
            .sink { [weak self] _ in self?.isAllTabActive = false }
            .store(in: &cancellables)

        // Re-render the menu bar title whenever QuotaService publishes.
        services.quotaService.$displayStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in self?.updateFrames(from: statuses) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshLocalizedChrome()
                self.updateFrames(from: self.services.quotaService.displayStatuses)
            }
            .store(in: &cancellables)

        installClickOutsideMonitor()
        installCmdCommaShortcut()

        // Global hotkey (Settings → General → Phím tắt). KeyUp so the
        // recorded chord doesn't leak a stray keyDown into the popover.
        KeyboardShortcuts.onKeyUp(for: .openPopover) { [weak self] in
            self?.togglePanel(nil)
        }

        // Daily GitHub-releases update check (About pane toggle gates it).
        UpdateChecker.shared.checkOnLaunchIfDue()
    }

    private func refreshLocalizedChrome() {
        settingsMenuItem?.title = L10n.t("popover.settings", services.settings.appLanguage)
    }

    // MARK: - Show / hide

    @objc func togglePanel(_ sender: AnyObject?) {
        // Right-click (or Ctrl-click) shows the Settings menu; left-click
        // toggles the quota popover. We attach the menu only for this one
        // click and detach it immediately so the next left-click still
        // reaches this action instead of AppKit opening the menu.
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isContextClick, let menu = statusMenu, let button = statusItem.button {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }

        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Bootstrap: the popover can open directly onto a persisted "all"
        // selection with no tab-switch transition to fire the will-open
        // notification, so check the persisted tab before the first layout
        // pass and pin the height the same way a live switch would.
        if UserDefaults.standard.string(forKey: QuotaOverview.selectedTabKey) == "all" {
            isAllTabActive = true
        }

        // Measure via AppKit's own Auto Layout fitting size — safe here,
        // outside any AppKit constraint flush.
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingHeight = max(1, hostingController.view.fittingSize.height)

        // Anchor: just below the status item button, centered, nudged up.
        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let topY = buttonRect.minY + topNudge
        panelTopY = topY
        var originX = buttonRect.midX - panelWidth / 2

        // Clamp height to the visible screen below the menu-bar anchor so
        // tall content (e.g. All tab) scrolls instead of running off-screen.
        // Clamp horizontally so the panel stays on screen.
        let screen = buttonWindow.screen ?? NSScreen.main
        let height = clampedHeight(fittingHeight: fittingHeight, top: topY, screen: screen)
        if let screen {
            let vf = screen.visibleFrame
            let margin: CGFloat = 8
            originX = min(max(originX, vf.minX + margin), vf.maxX - panelWidth - margin)
        }
        let originY = topY - height

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: height),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)

        // Optional CodexBar-parity behavior: force-refresh every provider on
        // open. Guarded so an already-running cycle isn't doubled.
        if services.settings.refreshOnMenuOpen, !services.quotaService.isRefreshing {
            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        panelTopY = nil
    }

    /// Height to use for the panel given the content's own `fittingHeight`,
    /// clamped to the visible screen below `top` and to `maxPanelHeight`.
    /// While `isAllTabActive`, the cap itself is used as the baseline
    /// instead of `fittingHeight` — see `isAllTabActive` for why the panel
    /// must not track the All tab's fluctuating content height.
    private func clampedHeight(fittingHeight: CGFloat, top: CGFloat, screen: NSScreen?) -> CGFloat {
        let baseline = isAllTabActive ? maxPanelHeight : fittingHeight
        guard let screen else { return max(1, baseline) }
        let available = top - screen.visibleFrame.minY - 8
        return max(1, min(baseline, available, maxPanelHeight))
    }

    /// Keep the top edge fixed and grow/shrink downward when the content
    /// height changes while the panel is visible. Height is clamped to the
    /// visible screen so tall content scrolls instead of overflowing.
    private func resizePanelToContent() {
        guard panel.isVisible else { return }
        // Deferred here via the caller's `Task { @MainActor in ... }`, so this
        // runs on a fresh run-loop turn — safe to re-measure fittingSize
        // rather than trust the GeometryReader-reported value, which under-
        // reports by the ScrollView's own content margins.
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingHeight = max(1, hostingController.view.fittingSize.height)
        let frame = panel.frame
        let top = panelTopY ?? frame.maxY
        let height = clampedHeight(fittingHeight: fittingHeight, top: top, screen: panel.screen ?? NSScreen.main)
        panel.setFrame(
            NSRect(x: frame.origin.x, y: top - height, width: panelWidth, height: height),
            display: true
        )
    }

    /// Expand the panel to cap height *before* the tall All tab content
    /// renders, and pin it there via `isAllTabActive` for as long as "all"
    /// stays selected. The hosting view must have stable bounds during that
    /// layout pass; if HostingScrollView's PlatformContainer changes frame
    /// mid-pass while NSISEngine flushes pending removals, constraint
    /// cleanup can recurse until the thread stack overflows. Pinning the
    /// frame (rather than only pre-expanding once) also covers every later
    /// in-tab interaction that changes what `AllUsageOverview` renders —
    /// the period picker, pinning a chart bar, selecting a heatmap cell —
    /// none of which may resize the panel while the flag is set.
    /// Called synchronously from the `.birdnionAllTabWillOpen` publisher
    /// (NotificationCenter posts are sync) so resize completes before the
    /// Binding setter mutates `selectedProviderId`.
    private func preExpandPanelForTallTab() {
        isAllTabActive = true
        guard panel.isVisible else { return }
        let frame = panel.frame
        let top = panelTopY ?? frame.maxY
        let height = clampedHeight(fittingHeight: maxPanelHeight, top: top, screen: panel.screen ?? NSScreen.main)
        panel.setFrame(
            NSRect(x: frame.origin.x, y: top - height, width: panelWidth, height: height),
            display: true
        )
    }

    // MARK: - Click-outside dismissal

    /// Global key monitor that intercepts Cmd+, and calls `openSettings(_:)`.
    /// LSUIElement menu-bar apps don't own the default Cmd+, chain — a
    /// local monitor wouldn't see the keystroke because the foreground
    /// app owns the keyDown. A global monitor can see it but cannot
    /// return nil to swallow the event, so we accept the duplicate
    /// dispatch (the foreground app will also handle Cmd+, and open
    /// its own Preferences — that's the existing macOS behaviour we
    /// can't fully suppress without a privileged event tap).
    private var cmdCommaMonitor: Any?

    private func installCmdCommaShortcut() {
        cmdCommaMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            // The global monitor only sees modifier flags + characters,
            // not the full NSEvent; we filter for "Cmd+," here so any
            // other Cmd-shortcut the user presses doesn't open Settings.
            let isCmd = event.modifierFlags.contains(.command)
            let isComma = event.charactersIgnoringModifiers == ","
            guard isCmd && isComma else { return }
            guard let self else { return }
            self.openSettings(nil)
        }
    }

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

    // MARK: - Menu bar frames

    /// How long each provider frame is shown before advancing.
    private let frameDuration: TimeInterval = 5.0

    /// Recompute the menu-bar frames from the latest statuses. With the percent
    /// setting off, or with no active quota data, this resolves to the bird.
    private func updateFrames(from statuses: [ProviderStatus]) {
        frames = MenuBarIconRenderer.frames(from: statuses)
        if frameIndex >= frames.count { frameIndex = 0 }
        if frames.count > 1 {
            startRotationTimer()
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
        }
        applyCurrentFrame()
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        let t = Timer(timeInterval: frameDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceFrame() }
        }
        // .common so it fires during menu tracking too.
        RunLoop.main.add(t, forMode: .common)
        rotationTimer = t
    }

    private func advanceFrame() {
        guard frames.count > 1 else { return }
        frameIndex = (frameIndex + 1) % frames.count
        applyCurrentFrame()
    }

    /// Render the current frame on the status bar button.
    ///
    /// Visual contract: **`91%` then provider logo** (percent text left,
    /// brand mark right). Bird frame is image-only (no title).
    private func applyCurrentFrame() {
        guard let button = statusItem?.button else { return }
        let frame = frames.indices.contains(frameIndex) ? frames[frameIndex] : .bird
        switch frame {
        case .bird:
            button.imagePosition = .imageOnly
            button.image = MenuBarIconRenderer.iconImage()
            button.title = ""
        case let .provider(id, _, percents, text):
            // Percent on the left, brand logo on the right — never the
            // provider display name in the title (that lives in the tooltip
            // / popover). Trailing space keeps the last digit off the logo.
            button.imagePosition = .imageRight
            button.image = MenuBarIconRenderer.providerLogo(for: id)
            if let text {
                // Display-mode override (Kiro credits). Empty = logo only.
                button.title = text.isEmpty ? "" : "\(text) "
            } else {
                let numbers = MenuBarIconRenderer.percentTitle(for: percents)
                button.title = "\(numbers) "
            }
        }
    }

    @objc func menuBarVisibilityDidChange(_ notification: Notification) {
        // Rebuild the menu-bar frame with the new visibility state and reset the
        // frame pointer so the user sees the change immediately.
        updateFrames(from: services.quotaService.displayStatuses)
        frameIndex = 0
        applyCurrentFrame()
    }

    @objc func providersDidChange(_ notification: Notification) {
        // Re-read providers.json and rebuild the QuotaService provider list
        // so popover tabs + menu-bar percent candidates reflect the new order, then
        // refresh statuses so the tab data is fresh too.
        services.rebuildProviders()
        Task { @MainActor in
            // Force a genuine fetch (bypass per-provider interval throttles) and
            // mark it manual — same as the popup/header refresh button. Without
            // forcing, recently-fetched providers are skipped so the refresh
            // returns instantly: the Settings refresh button would flip to
            // "Đang cập nhật" then snap back with no real update.
            let ids = Set(services.quotaService.providers.map(\.id))
            await RefreshInteraction.$isManual.withValue(true) {
                await services.quotaService.refresh(forceProviderIDs: ids)
            }
            updateFrames(from: services.quotaService.displayStatuses)
            frameIndex = 0
            applyCurrentFrame()
        }
    }

    @objc func openSettings(_ sender: AnyObject?) {
        // Dismiss the transient popover, bring the app forward, then ask the
        // invisible keep-alive scene to call SwiftUI's openSettings action.
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        EmbeddedCLIProxyService.shared.stop()
        services.stop()
    }
}
