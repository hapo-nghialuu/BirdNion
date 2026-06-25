import Foundation
import Combine
import UserNotifications
import os

/// Polls every enabled provider in parallel on a 120s ± 10s loop.
/// Throwing providers are caught and recorded on the status (no crash).
@MainActor
final class QuotaService: ObservableObject {
    @Published private(set) var statuses: [ProviderStatus] = []
    @Published private(set) var isRefreshing: Bool = false

    /// Per provider+window warning state: last seen remaining % and the set of
    /// thresholds already fired (so we notify once per crossing, not every poll).
    private var warnState: [String: [String: (last: Int, fired: Set<Int>)]] = [:]

    private(set) var providers: [QuotaProvider] = []
    private var interval: TimeInterval
    private var loopTask: Task<Void, Never>?

    init(providers: [QuotaProvider] = [], interval: TimeInterval = 120) {
        self.providers = providers
        self.interval = interval
    }

    /// Update the polling interval. The running loop reads `self.interval`
    /// fresh on every iteration, so the change applies at the next sleep.
    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
    }

    func add(_ p: QuotaProvider) {
        providers.append(p)
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        statuses.removeAll { $0.id == id }
    }

    /// Move a provider to a new position in the polling + tab order. The
    /// move is purely positional — `statuses` is not refetched here, just
    /// rebuilt from cached entries in the new order so the menu-bar
    /// popover immediately reflects the change. Callers that want fresh
    /// data should also post `.aistatusbarRefresh` (the ProvidersPane
    /// sidebar does this on every reorder).
    func reorder(id: String, toIndex: Int) {
        guard let from = providers.firstIndex(where: { $0.id == id }) else { return }
        let p = providers.remove(at: from)
        let clamped = max(0, min(toIndex, providers.count))
        providers.insert(p, at: clamped)
        // Re-sort cached statuses to match the new providers order. Stale
        // entries keep their old lastUpdated; that's intentional — the
        // next refresh will overwrite them anyway.
        var byId = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byId.removeValue(forKey: $0.id) }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            // already present? no-op
        } else {
            remove(id: id)
        }
    }

    func start() {
        guard loopTask == nil else { return }
        // Manual refresh hook from footer button (.aistatusbarRefresh)
        NotificationCenter.default.addObserver(
            forName: .aistatusbarRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let jitter = Double.random(in: -10...10)
                let delay = max(60.0, self.interval + jitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = providers
        let startedAt = Date()
        let log = Logger(subsystem: "com.local.birdnion", category: "quota.refresh")
        log.info("refresh start — providers=\(snapshot.count, privacy: .public)")

        // Publish statuses progressively as each provider completes — so the
        // menu-bar popover stops showing 'Đang tải…' as soon as the first
        // provider returns instead of waiting for the slowest one (which
        // can be Codex at 30s timeout on first cold call).
        await withTaskGroup(of: (String, ProviderStatus, TimeInterval).self) { group in
            for p in snapshot {
                group.addTask {
                    let t0 = Date()
                    do {
                        let status = try await p.fetch()
                        return (p.id, status, Date().timeIntervalSince(t0))
                    } catch {
                        return (p.id,
                                ProviderStatus(id: p.id, displayName: p.displayName,
                                               windows: [], lastUpdated: Date(),
                                               error: "\(error)"),
                                Date().timeIntervalSince(t0))
                    }
                }
            }
            var pending: [String: ProviderStatus] = [:]
            var timings: [(String, TimeInterval)] = []
            for await (id, status, elapsed) in group {
                pending[id] = status
                timings.append((id, elapsed))
                // Re-publish on each completion so the popover updates
                // incrementally (tab appears, then fills in).
                statuses = providers.compactMap { pending[$0.id] }
                if QuotaWarnConfig.enabled { evaluateWarnings(statuses) }
            }
            // Log slow providers (>2s) so the cause of slow loads is
            // visible in Console.app without attaching a debugger.
            let total = Date().timeIntervalSince(startedAt)
            let sortedByDuration = timings.sorted { $0.1 > $1.1 }
            for (id, elapsed) in sortedByDuration where elapsed > 2.0 {
                log.warning("slow provider: \(id, privacy: .public) took \(String(format: "%.2f", elapsed), privacy: .public)s")
            }
            log.info("refresh done — total=\(String(format: "%.2f", total), privacy: .public)s slow=\(sortedByDuration.filter { $0.1 > 2.0 }.count, privacy: .public)")
        }
    }

    // MARK: - Quota warnings

    /// Fires a notification the first time a window's remaining % drops to/below
    /// a configured threshold; re-arms once it recovers back above that level.
    private func evaluateWarnings(_ statuses: [ProviderStatus]) {
        for status in statuses where status.error == nil {
            for w in status.windows {
                let windowKey = QuotaWarnConfig.windowKey(w.label)
                let thresholds = QuotaWarnConfig.thresholds(provider: status.id, window: windowKey)
                guard !thresholds.isEmpty else { continue }

                var state = warnState[status.id]?[windowKey] ?? (last: 100, fired: [])
                let current = w.remainingPct
                // Re-arm any threshold we've climbed back above.
                state.fired = state.fired.filter { current <= $0 }
                // Fire on a downward crossing not yet notified.
                for t in QuotaWarnConfig.crossings(previous: state.last, current: current,
                                                   thresholds: thresholds, fired: state.fired) {
                    QuotaNotifier.post(
                        id: "\(status.id).\(windowKey).\(t)",
                        title: "\(status.displayName) • \(w.label)",
                        body: "Còn \(current)% — dưới ngưỡng \(t)%")
                    state.fired.insert(t)
                }
                state.last = current
                warnState[status.id, default: [:]][windowKey] = state
            }
        }
    }
}

// MARK: - Quota warning configuration

/// Resolves quota-warning thresholds from UserDefaults (shared by SettingsStore
/// UI and QuotaService). Thresholds are "remaining %" levels, high → low; a
/// provider+window may override the global pair, otherwise it inherits.
enum QuotaWarnConfig {
    static let level1Key = "quotaWarnLevel1"   // first (warning) level, default 50
    static let level2Key = "quotaWarnLevel2"   // second (critical) level, default 20
    static let enabledKey = "quotaWarningNotificationsEnabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
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

/// Thin wrapper over UNUserNotificationCenter. Requests authorization lazily on
/// first use (the system caches the decision, so repeat calls don't re-prompt).
enum QuotaNotifier {
    static func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            center.add(request)
        }
    }
}
