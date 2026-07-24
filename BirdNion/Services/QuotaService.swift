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
    private var refreshPassIsRunning = false
    private var pendingRefreshRequested = false
    private var pendingForceProviderIDs: Set<String> = []
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    typealias FailureNotificationPost = @MainActor (
        _ id: String, _ title: String, _ body: String
    ) -> Void
    typealias FailureNotificationRemove = @MainActor (_ id: String) -> Void
    typealias LegacyFailureNotificationCleanup = @MainActor (_ providerID: String) -> Void
    typealias AllFailureNotificationCleanup = @MainActor () -> Void
    private let failureNotificationPost: FailureNotificationPost
    private let failureNotificationRemove: FailureNotificationRemove
    private let legacyFailureNotificationCleanup: LegacyFailureNotificationCleanup
    private let allFailureNotificationCleanup: AllFailureNotificationCleanup
    private let failureNotificationNow: () -> Date
    private var didSweepFailureNotifications = false

    /// HH:mm formatter for the Codex auto-prime notification body.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(
        providers: [QuotaProvider] = [],
        interval: TimeInterval = 120,
        failureNotificationPost: @escaping FailureNotificationPost = {
            QuotaNotifier.post(id: $0, title: $1, body: $2)
        },
        failureNotificationRemove: @escaping FailureNotificationRemove = {
            QuotaNotifier.remove(id: $0)
        },
        legacyFailureNotificationCleanup: @escaping LegacyFailureNotificationCleanup = {
            QuotaNotifier.removeLegacyFailureNotifications(providerID: $0)
        },
        allFailureNotificationCleanup: @escaping AllFailureNotificationCleanup = {
            QuotaNotifier.removeAllFailureNotifications()
        },
        failureNotificationNow: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.interval = interval
        self.failureNotificationPost = failureNotificationPost
        self.failureNotificationRemove = failureNotificationRemove
        self.legacyFailureNotificationCleanup = legacyFailureNotificationCleanup
        self.allFailureNotificationCleanup = allFailureNotificationCleanup
        self.failureNotificationNow = failureNotificationNow
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
        let keep = Set(newProviders.map(\.id))
        let removedIDs = Set(providers.map(\.id)).subtracting(keep)
        removedIDs.forEach(cleanupRemovedProvider)
        providers = newProviders
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
        guard providers.contains(where: { $0.id == id }) else { return }
        cleanupRemovedProvider(id)
        providers.removeAll { $0.id == id }
        statuses.removeAll { $0.id == id }
        rebuildDisplayStatuses()
    }

    private func cleanupRemovedProvider(_ id: String) {
        failureNotificationRemove(Self.failureNotificationID(for: id))
        legacyFailureNotificationCleanup(id)
        failureEpisode.removeValue(forKey: id)
        warnState.removeValue(forKey: id)
    }

    /// Move a provider to a new position in the polling + tab order. The
    /// move is purely positional — `statuses` is not refetched here, just
    /// rebuilt from cached entries in the new order so the menu-bar
    /// popover immediately reflects the change. Provider-change observers
    /// schedule the canonical forced refresh after rebuilding the list.
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
        if !didSweepFailureNotifications {
            didSweepFailureNotifications = true
            allFailureNotificationCleanup()
        }
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
        if refreshPassIsRunning {
            pendingRefreshRequested = true
            pendingForceProviderIDs.formUnion(forceProviderIDs)
            await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
            return
        }

        refreshPassIsRunning = true
        isRefreshing = true
        var nextForceProviderIDs = forceProviderIDs
        repeat {
            await runRefreshPass(forceProviderIDs: nextForceProviderIDs)
            guard pendingRefreshRequested else { break }
            nextForceProviderIDs = pendingForceProviderIDs
            pendingForceProviderIDs.removeAll()
            pendingRefreshRequested = false
        } while true
        isRefreshing = false
        refreshPassIsRunning = false

        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Test seam for deterministic fan-in assertions.
    func refreshCoordinatorState() -> (running: Bool, pending: Bool, forcedProviderIDs: Set<String>) {
        (refreshPassIsRunning, pendingRefreshRequested, pendingForceProviderIDs)
    }

    private func runRefreshPass(forceProviderIDs: Set<String>) async {
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
        await withTaskGroup(
            of: (String, ObjectIdentifier, ProviderStatus, TimeInterval).self
        ) { group in
            for p in due {
                group.addTask {
                    let t0 = Date()
                    let providerIdentity = ObjectIdentifier(p)
                    do {
                        let status = try await p.fetch()
                        return (p.id, providerIdentity, status, Date().timeIntervalSince(t0))
                    } catch {
                        return (p.id, providerIdentity,
                                ProviderStatus(id: p.id, displayName: p.displayName,
                                               windows: [], lastUpdated: Date(),
                                               error: "\(error)"),
                                Date().timeIntervalSince(t0))
                    }
                }
            }
            var timings: [(String, TimeInterval)] = []
            var firstCompletionAt: Date?
            for await (id, providerIdentity, status, elapsed) in group {
                guard providers.contains(where: {
                    $0.id == id && ObjectIdentifier($0) == providerIdentity
                }) else {
                    log.info("discard removed or replaced provider result: \(id, privacy: .public)")
                    continue
                }
                let previous = pending[id]
                // Failure-episode bookkeeping reads the AWAITED status only —
                // `pending`/`statuses` may keep a preserved stale good
                // snapshot that would mask an ongoing failure (R3.5).
                evaluateFailureEpisode(id: id, displayName: status.displayName,
                                       error: status.error)
                // Preserve a good snapshot across a *transient* refresh error
                // (timeout, rate-limit, 5xx) so the popover doesn't flicker to
                // empty. But a credential error (401/403 / invalid token) means
                // the shown numbers are no longer trustworthy — the key was
                // revoked, rotated, or replaced — so surface the error instead
                // of a stale "still fine" reading.
                let isCredentialError = classify(rawError: status.error) == .tokenInvalidOrMissing
                if status.error != nil, previous?.isRenderableSnapshot == true, !isCredentialError {
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

    private struct FailureEpisodeState {
        var consecutiveFailures = 0
        var consecutiveSuccesses = 0
        var isFailureActive = false
        var hasActiveNotification = false
        var episodeSeq = 0
        var lastNotificationAt: Date?
        var didRunLegacyCleanup = false
        var didRemoveOrphanStableNotification = false
    }

    /// State is separate from quota threshold warnings. A provider enters an
    /// active failure after three failures and only recovers after two
    /// consecutive successes, preventing a single lucky poll from re-arming.
    private var failureEpisode: [String: FailureEpisodeState] = [:]
    private static let failureNotifyThreshold = 3
    private static let failureRecoveryThreshold = 2
    private static let failureNotificationCooldown: TimeInterval = 10 * 60
    private static let failureLog = Logger(
        subsystem: "com.local.birdnion",
        category: "quota.failure-notifications")

    static func failureNotificationID(for providerID: String) -> String {
        "provider.failure.\(providerID)"
    }

    /// Dedicated flag, default ON — reliability alerts must work out of the
    /// box and are NOT coupled to the quota-warning master toggle
    /// (`QuotaWarnConfig.enabled`, default off).
    static var failureNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "providerFailureNotificationsEnabled") as? Bool ?? true
    }

    /// Called once per FETCHED provider per refresh cycle with the awaited
    /// result. Posts with one stable provider ID and removes pending/delivered
    /// copies only after recovery is confirmed.
    func evaluateFailureEpisode(id: String, displayName: String, error: String?) {
        var state = failureEpisode[id] ?? FailureEpisodeState()
        let notificationID = Self.failureNotificationID(for: id)
        if !state.didRunLegacyCleanup {
            legacyFailureNotificationCleanup(id)
            state.didRunLegacyCleanup = true
            Self.failureLog.info(
                "cleanup legacy provider=\(id, privacy: .public)")
        }

        guard let error, !error.isEmpty else {
            state.consecutiveFailures = 0
            guard state.isFailureActive else {
                if !state.didRemoveOrphanStableNotification {
                    state.consecutiveSuccesses += 1
                    if state.consecutiveSuccesses >= Self.failureRecoveryThreshold {
                        failureNotificationRemove(notificationID)
                        state.didRemoveOrphanStableNotification = true
                        state.consecutiveSuccesses = 0
                        Self.failureLog.info(
                            "recovery confirmed provider=\(id, privacy: .public) remove-orphan=\(notificationID, privacy: .public)")
                    }
                } else {
                    state.consecutiveSuccesses = 0
                }
                failureEpisode[id] = state
                return
            }

            state.consecutiveSuccesses += 1
            guard state.consecutiveSuccesses >= Self.failureRecoveryThreshold else {
                Self.failureLog.info(
                    "recovery pending provider=\(id, privacy: .public) successes=\(state.consecutiveSuccesses, privacy: .public)")
                failureEpisode[id] = state
                return
            }

            state.isFailureActive = false
            state.consecutiveSuccesses = 0
            failureNotificationRemove(notificationID)
            state.hasActiveNotification = false
            state.didRemoveOrphanStableNotification = true
            Self.failureLog.info(
                "recovery confirmed provider=\(id, privacy: .public) removeID=\(notificationID, privacy: .public)")
            failureEpisode[id] = state
            return
        }

        state.consecutiveSuccesses = 0
        state.consecutiveFailures += 1
        let kind = classify(rawError: error) ?? .unknown
        Self.failureLog.warning(
            "failure provider=\(id, privacy: .public) kind=\(kind.rawValue, privacy: .public) count=\(state.consecutiveFailures, privacy: .public)")

        if state.consecutiveFailures >= Self.failureNotifyThreshold {
            state.isFailureActive = true
        }
        guard state.isFailureActive, !state.hasActiveNotification else {
            if state.hasActiveNotification {
                Self.failureLog.info(
                    "suppressed provider=\(id, privacy: .public) reason=active-notification")
            }
            failureEpisode[id] = state
            return
        }
        guard Self.failureNotificationsEnabled else {
            Self.failureLog.info(
                "suppressed provider=\(id, privacy: .public) reason=disabled")
            failureEpisode[id] = state
            return
        }

        let now = failureNotificationNow()
        if let lastNotificationAt = state.lastNotificationAt {
            let elapsed = now.timeIntervalSince(lastNotificationAt)
            if elapsed < Self.failureNotificationCooldown {
                let remaining = max(0, Self.failureNotificationCooldown - elapsed)
                Self.failureLog.info(
                    "suppressed provider=\(id, privacy: .public) reason=cooldown remaining=\(remaining, privacy: .public)")
                failureEpisode[id] = state
                return
            }
        }

        failureNotificationPost(
            notificationID,
            displayName,
            L10n.f("notification.providerFailing", nil,
                   L10n.t(kind.titleKey), L10n.t(kind.hintKey)))
        state.hasActiveNotification = true
        state.lastNotificationAt = now
        state.episodeSeq += 1
        Self.failureLog.notice(
            "posted provider=\(id, privacy: .public) kind=\(kind.rawValue, privacy: .public) id=\(notificationID, privacy: .public)")
        failureEpisode[id] = state
    }

    /// Test seam for deterministic state-machine assertions.
    func failureEpisodeState(for id: String) -> (
        consecutive: Int,
        consecutiveSuccesses: Int,
        active: Bool,
        notified: Bool,
        episodeSeq: Int,
        lastNotificationAt: Date?
    )? {
        guard let state = failureEpisode[id] else { return nil }
        return (
            state.consecutiveFailures,
            state.consecutiveSuccesses,
            state.isFailureActive,
            state.hasActiveNotification,
            state.episodeSeq,
            state.lastNotificationAt)
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
