import Foundation
import SwiftUI
import UserNotifications

// MARK: - Quota warning configuration

/// Resolves quota-warning thresholds from UserDefaults (shared by SettingsStore
/// UI and QuotaService). Thresholds are "remaining %" levels, high → low; a
/// provider+window may override the global pair, otherwise it inherits.
enum QuotaWarnConfig {
    static let level1Key = "quotaWarnLevel1"   // first (warning) level, default 50
    static let level2Key = "quotaWarnLevel2"   // second (critical) level, default 20
    static let enabledKey = "quotaWarningNotificationsEnabled"
    /// Delivery options (SettingsStore exposes the same keys): notification
    /// sound (default on, matching the pre-existing behavior) and a brief
    /// on-screen overlay (default off, CodexBar parity).
    static let soundKey = "quotaWarningSoundEnabled"
    static let alertKey = "quotaWarningOnScreenAlertEnabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }

    static var onScreenAlertEnabled: Bool {
        UserDefaults.standard.bool(forKey: alertKey)
    }

    static var globalThresholds: [Int] {
        let l1 = UserDefaults.standard.object(forKey: level1Key) as? Int ?? 50
        let l2 = UserDefaults.standard.object(forKey: level2Key) as? Int ?? 20
        return [l1, l2].filter { $0 > 0 && $0 <= 100 }.sorted(by: >)
    }

    /// "session" for the ~5h window, "weekly" for the 7-day window.
    static func windowKey(_ label: String) -> String {
        label.contains("Tuần") ? "weekly" : "session"
    }

    static func overrideKey(_ provider: String, _ window: String) -> String {
        "quotaWarn.\(provider).\(window)"
    }

    static func hasOverride(provider: String, window: String) -> Bool {
        UserDefaults.standard.string(forKey: overrideKey(provider, window)) != nil
    }

    static func thresholds(provider: String, window: String) -> [Int] {
        if let raw = UserDefaults.standard.string(forKey: overrideKey(provider, window)), !raw.isEmpty {
            let parsed = raw.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 && $0 <= 100 }
            if !parsed.isEmpty { return parsed.sorted(by: >) }
        }
        return globalThresholds
    }

    static func setOverride(provider: String, window: String, thresholds: [Int]?) {
        let key = overrideKey(provider, window)
        if let thresholds {
            UserDefaults.standard.set(thresholds.map(String.init).joined(separator: ","), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Pure crossing test (unit-tested): thresholds whose level was above
    /// `previous` but is now at/below `current`, and hasn't been fired yet.
    static func crossings(previous: Int, current: Int, thresholds: [Int], fired: Set<Int>) -> [Int] {
        thresholds.filter { previous > $0 && current <= $0 && !fired.contains($0) }
    }
}

// MARK: - Notifications

/// Serializes async side effects in invocation order. Notification removal
/// must never overtake a delayed authorization/add operation.
@MainActor
final class OrderedAsyncOperationQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    func drain() async {
        await tail?.value
    }
}

/// Thin wrapper over UNUserNotificationCenter. Requests authorization lazily on
/// first use (the system caches the decision, so repeat calls don't re-prompt).
@MainActor
enum QuotaNotifier {
    private static let operations = OrderedAsyncOperationQueue()

    static func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let soundEnabled = QuotaWarnConfig.soundEnabled
        operations.enqueue {
            let granted = await requestAuthorization(center)
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = soundEnabled ? .default : nil
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            await add(request, to: center)
        }
        if QuotaWarnConfig.onScreenAlertEnabled {
            QuotaAlertOverlay.shared.show(title: title, message: body)
        }
    }

    /// Awaitable variant of `post` — returns `true` only when the OS
    /// actually queued the notification (authorization granted AND `add`
    /// completed without an error). Used by `WeeklyDigest` so `lastSentAt`
    /// only advances on confirmed delivery; every other call site keeps
    /// using the fire-and-forget `post` above, which this does not replace.
    @discardableResult
    static func postAndWait(
        id: String,
        title: String,
        body: String,
        revalidate: @escaping @MainActor () async -> Bool = { true }
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let soundEnabled = QuotaWarnConfig.soundEnabled
        let posted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            operations.enqueue {
                let mayPost = await authorizationAndRevalidationAllowPost(
                    requestAuthorization: { await requestAuthorization(center) },
                    revalidate: revalidate)
                guard mayPost else {
                    continuation.resume(returning: false)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = soundEnabled ? .default : nil
                let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                let succeeded = await addAwaitingResult(request, to: center)
                continuation.resume(returning: succeeded)
            }
        }
        if posted, QuotaWarnConfig.onScreenAlertEnabled {
            QuotaAlertOverlay.shared.show(title: title, message: body)
        }
        return posted
    }

    /// Keeps the consent/source check causally after the potentially blocking
    /// OS permission prompt and immediately before the notification is added.
    static func authorizationAndRevalidationAllowPost(
        requestAuthorization: @escaping @MainActor () async -> Bool,
        revalidate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard await requestAuthorization() else { return false }
        return await revalidate()
    }

    static func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        operations.enqueue {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    static func removeLegacyFailureNotifications(providerID: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = "\(providerID).failing."
        operations.enqueue {
            let requests = await pendingRequests(center)
            let pendingIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
            let notifications = await deliveredNotifications(center)
            let deliveredIDs = notifications.map(\.request.identifier).filter {
                $0.hasPrefix(prefix)
            }
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    static func removeAllFailureNotifications() {
        let center = UNUserNotificationCenter.current()
        operations.enqueue {
            let requests = await pendingRequests(center)
            let pendingIDs = requests.map(\.identifier).filter(isFailureNotificationID)
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
            let notifications = await deliveredNotifications(center)
            let deliveredIDs = notifications.map(\.request.identifier).filter(isFailureNotificationID)
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    private static func isFailureNotificationID(_ id: String) -> Bool {
        id.hasPrefix("provider.failure.") || id.contains(".failing.")
    }

    private static func requestAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func add(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter
    ) async {
        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume()
            }
        }
    }

    /// Same as `add` but reports whether the OS actually accepted the
    /// request (`error == nil`), for `postAndWait`.
    private static func addAwaitingResult(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func pendingRequests(
        _ center: UNUserNotificationCenter
    ) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests {
                continuation.resume(returning: $0)
            }
        }
    }

    private static func deliveredNotifications(
        _ center: UNUserNotificationCenter
    ) async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications {
                continuation.resume(returning: $0)
            }
        }
    }
}

// MARK: - On-screen alert overlay

/// Brief centered on-screen alert for quota warnings — a floating,
/// non-activating, click-through panel that auto-dismisses. Trimmed-down
/// port of CodexBar's `QuotaWarningAlertOverlayController`.
@MainActor
final class QuotaAlertOverlay {
    static let shared = QuotaAlertOverlay()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private static let displayDuration: TimeInterval = 4.5

    func show(title: String, message: String) {
        dismiss()

        let content = VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - hosting.fittingSize.width / 2,
                y: frame.midY - hosting.fittingSize.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
