import Foundation
import Combine
import SwiftUI
import UserNotifications
import os

/// Polls every enabled provider in parallel on a 120s ± 10s loop.
/// Throwing providers are caught and recorded on the status (no crash).
@MainActor
final class QuotaService: ObservableObject {
    @Published private(set) var statuses: [ProviderStatus] = []
    @Published private(set) var displayStatuses: [ProviderStatus] = []
    @Published private(set) var isRefreshing: Bool = false

    /// Always-fully-populated status array used by the popover UI. Contains
    /// one entry per provider in `providers`, even if a fetch is still
    /// in-flight — missing entries get a placeholder so the tabs + cards
    /// render immediately and the user sees a per-card spinner instead of
    /// the whole popover blocked on a single slow provider.
    private func rebuildDisplayStatuses() {
        let have = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        displayStatuses = providers.compactMap { p in
            if let s = have[p.id] { return s }
            return ProviderStatus(
                id: p.id, displayName: p.displayName,
                windows: [], lastUpdated: Date())
        }
    }

    /// Per provider+window warning state: last seen remaining % and the set of
    /// thresholds already fired (so we notify once per crossing, not every poll).
    private var warnState: [String: [String: (last: Int, fired: Set<Int>)]] = [:]

    private(set) var providers: [QuotaProvider] = []
    private var interval: TimeInterval
    private var loopTask: Task<Void, Never>?

    /// HH:mm formatter for the Codex auto-prime notification body.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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
        rebuildDisplayStatuses()
    }

    /// Replace the entire provider list with `newProviders`. Used after the
    /// user reorders or toggles providers in the Settings sidebar so the
    /// Replace the entire provider list with `newProviders`. Used after the
    /// user reorders or toggles providers in the Settings sidebar so the
    /// popover tabs + menu-bar percent rotation pick up the new arrangement
    /// without an app restart. **Cached statuses are preserved** across
    /// this call — we only drop entries for providers that are no longer
    /// in the list. Clearing `statuses` entirely would leave every pill
    /// showing "Chưa tải" until the next refresh cycle completes, which
    /// can take 10–15s when Codex + Claude both time out (see the Claude
    /// 12s timeout in `ClaudeProvider`). Preserving the cache means the
    /// popover shows the *previous* good data for unchanged providers
    /// while a single click of the Refresh button races.
    func setProviders(_ newProviders: [QuotaProvider]) {
        providers = newProviders
        let keep = Set(newProviders.map(\.id))
        statuses = statuses.filter { keep.contains($0.id) }
        // Drop cached last-fetched timestamps for providers no longer in
        // the list, otherwise the per-provider throttle could skip a fresh
        // provider's first poll under the right timing.
        providerLastFetched = providerLastFetched.filter { keep.contains($0.key) }
        // Re-sort cached statuses to match the new providers order. Stale
        // entries keep their old lastUpdated; that's intentional — the
        // next refresh will overwrite them anyway.
        var byId = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byId.removeValue(forKey: $0.id) }
        rebuildDisplayStatuses()
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        statuses.removeAll { $0.id == id }
        rebuildDisplayStatuses()
    }

    /// Move a provider to a new position in the polling + tab order. The
    /// move is purely positional — `statuses` is not refetched here, just
    /// rebuilt from cached entries in the new order so the menu-bar
    /// popover immediately reflects the change. Callers that want fresh
    /// data should also post `.birdnionRefresh` (the ProvidersPane
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
        rebuildDisplayStatuses()
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
        // Manual refresh hook from footer button (.birdnionRefresh)
        NotificationCenter.default.addObserver(
            forName: .birdnionRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Mark this as a user-initiated refresh so background-only throttles
            // (e.g. the Codex CLI launch gate) let the retry through. Manual
            // refreshes also bypass per-provider interval throttles so the
            // footer/header action always fetches fresh data.
            Task { @MainActor in
                await RefreshInteraction.$isManual.withValue(true) {
                    await self.refresh(forceProviderIDs: Set(self.providers.map(\.id)))
                }
            }
        }
        // Codex account switch: show that account's cached snapshot instantly,
        // then refetch (also counts as a manual interaction).
        NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyCachedCodexStatus()
                await RefreshInteraction.$isManual.withValue(true) {
                    await self.refresh(forceProviderIDs: ["codex"])
                }
            }
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                // Manual mode (interval <= 0): idle in short sleeps so a later
                // setting change is picked up, but never auto-fetch — only the
                // .birdnionRefresh path (button / refresh-on-open) fetches.
                let base = self.interval
                let jitter = Double.random(in: -10...10)
                let delay = base <= 0 ? 60.0 : max(60.0, base + jitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                if self.interval <= 0 { continue }
                await self.refresh()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Per-provider refresh override (in seconds). 0 or absent means "use the
    /// global interval set via `setInterval`". When set, this provider is
    /// only fetched on refresh cycles where `now - lastFetched[id] >=
    /// override` has elapsed, so a slow / rate-limited provider can be polled
    /// less often than a fast one.
    private var providerIntervals: [String: TimeInterval] = [:]
    private var providerLastFetched: [String: Date] = [:]

    /// Read a provider's refresh override from UserDefaults (0 = use
    /// global). Used by `refresh()` to decide whether to fetch this cycle.
    private static func overrideInterval(for providerId: String) -> TimeInterval {
        UserDefaults.standard.double(forKey: "refreshInterval.\(providerId)")
    }

    /// Set or clear a provider's refresh override. Pass 0 to fall back to
    /// the global interval (the default).
    static func setOverrideInterval(_ seconds: TimeInterval, for providerId: String) {
        UserDefaults.standard.set(seconds, forKey: "refreshInterval.\(providerId)")
    }

    /// Effective refresh interval for a provider: its override if non-zero,
    /// otherwise the global one.
    private func effectiveInterval(for providerId: String) -> TimeInterval {
        let override = Self.overrideInterval(for: providerId)
        return override > 0 ? override : interval
    }

    /// Replace the Codex status with the active account's cached snapshot so an
    /// account switch shows its last-known numbers immediately, before the
    /// refetch completes. No-op when nothing is cached for that account.
    func applyCachedCodexStatus() {
        guard let cached = CodexAccountSnapshotStore.shared.currentSnapshot() else { return }
        if let idx = statuses.firstIndex(where: { $0.id == "codex" }) {
            statuses[idx] = cached
        } else {
            statuses.append(cached)
        }
        rebuildDisplayStatuses()
    }

    func refresh(forceProviderIDs: Set<String> = []) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = providers
        let startedAt = Date()
        let log = Logger(subsystem: "com.local.birdnion", category: "quota.refresh")

        // Per-provider throttling: skip a provider if its individual override
        // interval hasn't elapsed since the last successful fetch. The
        // global `interval` is still the loop cadence; this only stops
        // re-polling providers whose own setting says "wait longer".
        let due: [QuotaProvider] = snapshot.filter { p in
            if forceProviderIDs.contains(p.id) { return true }
            let interval = effectiveInterval(for: p.id)
            guard interval > 0 else { return true }
            guard let last = providerLastFetched[p.id] else { return true }
            return Date().timeIntervalSince(last) >= interval
        }
        log.info("refresh start — due=\(due.count, privacy: .public)/\(snapshot.count, privacy: .public)")

        // Token-rotation sync-back: reconcile the managed account's cached
        // auth.json copy against ~/.codex/auth.json on the existing refresh
        // cadence (no new polling loop). Best-effort — swallows errors.
        if due.contains(where: { $0.id == "codex" }) {
            _ = CodexAccountStore.reconcileCLISyncBack()

            // Codex 5h auto-prime: reuses this same cadence (no new
            // Timer/polling loop) so a missed/asleep schedule catches up on
            // the next awake refresh. Read the current codex 5h `usedPct`
            // from the last-known status so `tick` can skip while the window
            // is already active.
            let codexUsedPct = statuses.first(where: { $0.id == "codex" })?
                .windows.first(where: { $0.label == "5 giờ" })?.usedPct
            let now = Date()
            if await CodexQuotaPrimer.tick(windowUsedPct: codexUsedPct, now: now) {
                let time = Self.timeFormatter.string(from: now)
                QuotaNotifier.post(
                    id: "codex.autoPrime",
                    title: L10n.t("notification.codexPrimed.title"),
                    body: L10n.f("notification.codexPrimed.body", nil, time))
            }
        }

        // Publish statuses progressively as each provider completes — so the
        // menu-bar popover stops showing 'Đang tải…' as soon as the first
        // provider returns instead of waiting for the slowest one (which
        // can be Codex at 30s timeout on first cold call).
        //
        // Seed `pending` with the LAST KNOWN statuses so providers keep
        // showing their previous data while the new fetch is in flight.
        // Without this seed the popover would flash empty placeholders for
        // every provider the moment refresh() starts — confusing and
        // visually jarring. Now: old data stays, header shows a subtle
        // 'Đang cập nhật…' indicator, and each row swaps to fresh data
        // the moment its fetch returns.
        var pending: [String: ProviderStatus] = Dictionary(
            uniqueKeysWithValues: statuses.map { ($0.id, $0) }
        )
        let isFirstRefresh = statuses.isEmpty
        await withTaskGroup(of: (String, ProviderStatus, TimeInterval).self) { group in
            for p in due {
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
            var timings: [(String, TimeInterval)] = []
            var firstCompletionAt: Date?
            for await (id, status, elapsed) in group {
                let previous = pending[id]
                // Failure-episode bookkeeping reads the AWAITED status only —
                // `pending`/`statuses` may keep a preserved stale good
                // snapshot that would mask an ongoing failure (R3.5).
                evaluateFailureEpisode(id: id, displayName: status.displayName,
                                       error: status.error)
                if status.error != nil, previous?.isRenderableSnapshot == true {
                    log.warning("preserve stale status for \(id, privacy: .public) after refresh error: \(status.error ?? "", privacy: .public)")
                } else {
                    pending[id] = status
                }
                providerLastFetched[id] = Date()
                timings.append((id, elapsed))
                if firstCompletionAt == nil { firstCompletionAt = Date() }
                // Re-publish on each completion so the popover updates
                // incrementally (tab appears, then fills in).
                statuses = providers.compactMap { pending[$0.id] }
                rebuildDisplayStatuses()
                if QuotaWarnConfig.enabled { evaluateWarnings(statuses) }
            }
            if isFirstRefresh, let firstAt = firstCompletionAt {
                log.info("first fetch done in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)s — popover has data")
                _ = firstAt  // reserved for future "first-paint" metric
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
                        title: "\(status.displayName) • \(L10n.windowLabel(w.label))",
                        body: L10n.f("notification.quotaBelowThreshold", nil, current, t))
                    state.fired.insert(t)
                }
                state.last = current
                warnState[status.id, default: [:]][windowKey] = state
            }
        }
    }

    // MARK: - Failure-transition notification (R3)

    /// Per-provider failure-episode state, SEPARATE from `warnState` — the
    /// quota-threshold system is untouched. `consecutive` counts consecutive
    /// failing FETCHES (skipped/throttled cycles never reach the evaluator);
    /// `notified` prevents re-notifying within one episode; `episodeSeq`
    /// makes each episode's notification id unique so macOS doesn't dedup a
    /// later episode against an earlier one.
    private var failureEpisode: [String: (consecutive: Int, notified: Bool, episodeSeq: Int)] = [:]
    private static let failureNotifyThreshold = 3

    /// Dedicated flag, default ON — reliability alerts must work out of the
    /// box and are NOT coupled to the quota-warning master toggle
    /// (`QuotaWarnConfig.enabled`, default off).
    static var failureNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "providerFailureNotificationsEnabled") as? Bool ?? true
    }

    /// Called once per FETCHED provider per refresh cycle with the awaited
    /// fetch result. Fires exactly one notification at the Nth consecutive
    /// failure, stays silent while the episode continues, and re-arms on
    /// recovery (a fresh episode notifies again under a new id).
    func evaluateFailureEpisode(id: String, displayName: String, error: String?) {
        var st = failureEpisode[id] ?? (consecutive: 0, notified: false, episodeSeq: 0)
        guard let error, !error.isEmpty else {
            failureEpisode[id] = (consecutive: 0, notified: false, episodeSeq: st.episodeSeq)
            return
        }
        st.consecutive += 1
        if st.consecutive >= Self.failureNotifyThreshold, !st.notified, Self.failureNotificationsEnabled {
            st.episodeSeq += 1
            let kind = classify(rawError: error) ?? .unknown
            QuotaNotifier.post(
                id: "\(id).failing.\(st.episodeSeq)",
                title: displayName,
                body: L10n.f("notification.providerFailing", nil,
                             L10n.t(kind.titleKey), L10n.t(kind.hintKey)))
            st.notified = true
        }
        failureEpisode[id] = st
    }

    /// Test seam: expose the episode tuple so unit tests can assert
    /// consecutive/notified/episodeSeq transitions without a notifier mock.
    func failureEpisodeState(for id: String) -> (consecutive: Int, notified: Bool, episodeSeq: Int)? {
        failureEpisode[id]
    }
}

private extension ProviderStatus {
    /// A previous non-error snapshot that has meaningful UI content. When a
    /// follow-up refresh times out, keep this around so the popover does not
    /// collapse quota rows or chart payloads into an error-only card.
    var isRenderableSnapshot: Bool {
        guard error == nil else { return false }
        return !windows.isEmpty
            || cost != nil
            || webExtras != nil
            || codexWeb != nil
            || claudeAdminUsage != nil
            || kiroMenu != nil
            || creditsRemaining != nil
            || creditsUnlimited
            || resetCreditsAvailable != nil
            || planType != nil
            || planName != nil
            || accountLabel != nil
            || version != nil
            || serviceStatus != nil
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
            content.sound = QuotaWarnConfig.soundEnabled ? .default : nil
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            center.add(request)
        }
        if QuotaWarnConfig.onScreenAlertEnabled {
            Task { @MainActor in
                QuotaAlertOverlay.shared.show(title: title, message: body)
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
