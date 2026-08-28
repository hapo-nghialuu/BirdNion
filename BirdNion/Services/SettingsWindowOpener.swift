import AppKit
import OSLog
import SwiftUI

private let settingsOpenLog = Logger(subsystem: "com.local.birdnion", category: "settings-open")

/// Shared open-Settings request so the keepalive scene can ack that SwiftUI's
/// `openSettings` environment action actually ran.
@MainActor
final class SettingsOpenRequest {
    var wasHandled = false
}

/// Opens the SwiftUI `Settings` scene for an LSUIElement menu-bar app.
///
/// Launch-at-login (SMAppService) and a fresh quit/reopen leave the process in
/// the accessory / agent activation policy. The keepalive `WindowGroup` that
/// owns SwiftUI's `openSettings` often mounts a beat later — a single-shot
/// open then no-ops until the next process launch. Promote to `.regular`,
/// retry until a Settings window appears, then demote when idle.
@MainActor
enum SettingsWindowOpener {
    private static var managingRegularPolicy = false
    private static var observersStarted = false
    /// Set when the keepalive WindowGroup's hosting view attaches to a window.
    private static var keepaliveReady = false
    /// Bumps on each `open()` so overlapping retry chains cancel themselves.
    private static var openGeneration = 0

    /// Call once the invisible keepalive scene has a real `NSWindow`.
    static func markKeepaliveReady() {
        keepaliveReady = true
    }

    /// Nudge the keepalive WindowGroup to mount after cold start / login-item
    /// launch so the first Settings click is not racing scene creation.
    static func warmup() {
        startObserversIfNeeded()
        // Accessory apps sometimes defer WindowGroup creation until activation.
        NSApp.activate(ignoringOtherApps: false)
        // Re-nudge over the first few seconds: at a cold macOS boot the keepalive
        // WindowGroup may not mount on the first pass under heavy login load, so
        // the first Settings click would otherwise race scene creation.
        for delay in [0.5, 1.5, 3.0, 6.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = NSApp.windows
                if !keepaliveReady { NSApp.activate(ignoringOtherApps: false) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            settingsOpenLog.notice("warmup done keepalive=\(keepaliveReady) policy=\(NSApp.activationPolicy().rawValue)")
        }
    }

    static func open() {
        startObserversIfNeeded()
        promoteForSettings()

        openGeneration += 1
        let generation = openGeneration
        attemptOpen(generation: generation, attempt: 0)
    }

    // MARK: - Open attempts

    // Kéo dài retry tới ~20s: sau khi khởi động lại macOS, login-item chạy nền
    // ở `.accessory` và SwiftUI hoãn materialize `Settings` scene cho tới khi
    // app thực sự active; dưới tải boot nặng việc này có thể mất >3s. Cửa sổ
    // retry ngắn (cũ ~3.5s) cạn trước khi scene sẵn sàng → nút Settings "chết".
    /// Delays are intervals between attempts, not absolute timestamps. Keep
    /// their sum at or below 20 seconds so a failed open cannot retain focus
    /// or Dock presence indefinitely during login-item startup.
    static let retryIntervals: [TimeInterval] = [
        0, 0.12, 0.18, 0.25, 0.45, 0.6, 0.9, 1.0, 1.5, 2.0, 2.5, 3.0, 3.0, 4.5]

    private static func attemptOpen(generation: Int, attempt: Int) {
        guard generation == openGeneration else { return }

        if settingsWindowVisible() {
            if attempt > 0 {
                settingsOpenLog.notice("Settings visible after \(attempt) retries")
            }
            frontSettingsWindows()
            return
        }

        promoteForSettings()

        let request = SettingsOpenRequest()
        NotificationCenter.default.post(name: .openSettingsWindow, object: request)

        // AppKit fallback when keepalive hasn't subscribed yet (cold start).
        // Even after ack, cold-start openSettings can no-op until the next
        // attempt — keep sending AppKit show until a window is visible.
        var appKitHandled = true
        if !request.wasHandled || !keepaliveReady || !settingsWindowVisible() {
            appKitHandled = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        settingsOpenLog.notice(
            "open attempt=\(attempt) policy=\(NSApp.activationPolicy().rawValue) keepalive=\(keepaliveReady) swiftUIAck=\(request.wasHandled) appKit=\(appKitHandled) visible=\(settingsWindowVisible())")

        // Front whatever Settings window exists after this tick.
        DispatchQueue.main.async {
            guard generation == openGeneration else { return }
            frontSettingsWindows()
            if settingsWindowVisible() { return }

            let next = attempt + 1
            guard next < retryIntervals.count else {
                settingsOpenLog.error("Settings did not become visible before retry deadline")
                demoteIfIdle()
                return
            }
            let delay = retryIntervals[next]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                attemptOpen(generation: generation, attempt: next)
            }
        }
    }

    private static func settingsWindowVisible() -> Bool {
        NSApp.windows.contains { isSettingsWindow($0) && $0.isVisible }
    }

    // MARK: - Activation policy

    private static func promoteForSettings() {
        if NSApp.activationPolicy() != .regular {
            if NSApp.setActivationPolicy(.regular) {
                managingRegularPolicy = true
            } else {
                // Có thể fail nếu gọi quá sớm sau login-item cold start; các
                // attempt sau sẽ thử lại (log để chẩn đoán nếu vẫn kẹt).
                settingsOpenLog.error("setActivationPolicy(.regular) returned false")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func demoteIfIdle() {
        guard managingRegularPolicy else { return }
        let hasRealWindow = NSApp.windows.contains { isRealUserWindow($0) }
        guard !hasRealWindow else { return }
        if NSApp.setActivationPolicy(.accessory) {
            managingRegularPolicy = false
        }
    }

    private static func isRealUserWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized, window.canBecomeKey else { return false }
        if window.identifier?.rawValue == "BirdNionLifecycleKeepalive" { return false }
        if window.title == "BirdNionLifecycleKeepalive" { return false }
        if window.frame.width <= 20 && window.frame.height <= 20 { return false }
        let className = NSStringFromClass(type(of: window))
        if className.contains("NSStatusBarWindow") { return false }
        return true
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if let id = window.identifier?.rawValue, id.contains("com_apple_SwiftUI_Settings") {
            return true
        }
        let className = NSStringFromClass(type(of: window))
        if className.contains("Settings") { return true }
        // SwiftUI Settings often uses an empty/generic title; size is a hint.
        if window.frame.width >= 600 && window.frame.height >= 400 && window.canBecomeKey {
            return true
        }
        return false
    }

    private static func frontSettingsWindows() {
        for window in NSApp.windows where isSettingsWindow(window) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func startObserversIfNeeded() {
        guard !observersStarted else { return }
        observersStarted = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await Task.yield()
                demoteIfIdle()
            }
        }
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            Task { @MainActor in
                if let window = note.object as? NSWindow, isSettingsWindow(window) {
                    managingRegularPolicy = true
                }
            }
        }
    }
}
