import AppKit
import SwiftUI
import Combine

/// AppDelegate creates the NSStatusItem (menu bar icon) programmatically and
/// manages an NSPopover for the popover content. The menu bar icon is a
/// dynamic NSImage redrawn from the latest QuotaService statuses (codexbar
/// "usage meter drawn dynamically" approach).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServicesContainer()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

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
            button.action = #selector(togglePopover(_:))
        }

        // Popover — transient behavior plus a manual click-outside monitor.
        // Some macOS builds ignore `behavior = .transient` when the popover is
        // opened from an NSStatusItem button, so we install an NSEvent monitor
        // that explicitly closes the popover when a click lands outside its
        // content frame.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 460)
        let host = NSHostingController(
            rootView: PopoverView()
                .environmentObject(services.quotaService)
                .environmentObject(services.configService)
                .environmentObject(services.keychain)
        )
        popover.contentViewController = host
        popover.delegate = self

        // Re-render icon whenever QuotaService publishes a new status
        services.quotaService.$statuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        installClickOutsideMonitor()
    }

    private func installClickOutsideMonitor() {
        // Local monitor: catches mouse events delivered to any window of this
        // app. If a click happens outside the popover window, close it.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            self.closePopoverIfClickOutside(event: event)
            return event
        }

        // Global monitor: catches mouse events outside this app entirely.
        // If the popover is still shown after a click elsewhere on the system,
        // close it.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.popover.isShown { self.popover.performClose(nil) }
            }
        }
    }

    private func closePopoverIfClickOutside(event: NSEvent) {
        guard popover.isShown else { return }
        guard let popoverWindow = popover.contentViewController?.view.window else {
            return
        }
        // Convert event location (window coords) to screen coords for comparison
        let mouseLocationInWindow = event.locationInWindow
        let mouseOnScreen = popoverWindow.convertPoint(toScreen: mouseLocationInWindow)
        if !popoverWindow.frame.contains(mouseOnScreen) {
            // Also check we are not clicking on the status bar button itself,
            // because that click will toggle (close) the popover via togglePopover.
            if let button = statusItem.button, button.window?.frame.contains(mouseOnScreen) == true {
                return
            }
            popover.performClose(nil)
        }
    }

    private func refreshIcon() {
        let image = MenuBarIconRenderer.image()
        image.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageOnly
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    // Settings via Cmd+, — opens a regular AppKit window
    @objc func openSettings(_ sender: AnyObject?) {
        if settingsWindow == nil {
            let host = NSHostingController(
                rootView: SettingsWindow()
                    .environmentObject(services.quotaService)
                    .environmentObject(services.configService)
                    .environmentObject(services.keychain)
            )
            settingsWindow = NSWindow(contentViewController: host)
            settingsWindow?.title = "BirdNion — Settings"
            settingsWindow?.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow?.setContentSize(NSSize(width: 420, height: 300))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        services.stop()
    }
}

// MARK: - NSPopoverDelegate
extension AppDelegate: NSPopoverDelegate {
    nonisolated func popoverDidShow(_ notification: Notification) {
        // After the popover is shown, force its window to become key so the
        // local mouse monitor can correctly attribute clicks to its frame.
        Task { @MainActor in
            self.popover.contentViewController?.view.window?.becomeKey()
        }
    }
}