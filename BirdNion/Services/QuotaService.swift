import Foundation
import Combine
import SwiftUI
import UserNotifications
import os

/// A refresh failure recorded while the popover still shows a prior
/// last-good snapshot (see `isTransientForLastGood`). Deliberately kept OUT
/// of `ProviderStatus` — and therefore out of the disk cache — so surfacing
/// it never requires breaking the `windows.isEmpty == (error != nil)`
/// invariant, and so it never survives a relaunch: a transient hiccup from a
/// past session must not resurrect a stale-data banner before this session's
/// own polling has had a chance to succeed or fail again.
struct StaleQuotaWarning: Equatable {
    /// Classified reason for the refresh failure being suppressed behind the
    /// last-good snapshot (network/timeout, rate-limit, or a genuine 5xx) —
    /// drives the localized, actionable cause line. Never the raw error text.
    let kind: ProviderErrorKind
    /// `lastUpdated` of the preserved last-good snapshot — when the windows
    /// currently on screen were actually fetched successfully.
    let lastGoodUpdated: Date
}

/// Tracks consecutive refresh failures per provider so a single flake never
/// replaces good on-screen data with an error card. Ported from CodexBar's
/// `ConsecutiveFailureGate` (`UsageStoreSupport.swift`).
///
/// Only the FIRST failure is swallowed, and only while a renderable snapshot is
/// still showing — a provider that is genuinely broken still surfaces on the
/// next pass, and a provider that never had data surfaces immediately.
struct ConsecutiveFailureGate: Equatable {
    private(set) var streak: Int = 0

    mutating func recordSuccess() {
        streak = 0
    }

    mutating func reset() {
        streak = 0
    }

    /// Records one failure and returns whether the caller should show it.
    mutating func shouldSurfaceError(onFailureWithPriorData hadPriorData: Bool) -> Bool {
        streak += 1
        if hadPriorData, streak == 1 { return false }
        return true
    }
}

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

    /// Per-provider stale-data warning, populated only while a *transient*
    /// refresh error is being suppressed behind a preserved last-good
    /// snapshot (see `runRefreshPass`). Intentionally NOT `@Published` or
    /// persisted: SwiftUI already re-renders alongside the `statuses` publish
    /// that happens in the very same refresh iteration, and a fresh launch
    /// always starts empty — see `StaleQuotaWarning`'s doc comment.
    private var staleWarnings: [String: StaleQuotaWarning] = [:]

    /// Current stale-data warning for a provider, if its last refresh failed
    /// transiently while a last-good snapshot was preserved. `nil` once a
    /// fresh success or a non-transient error lands (both replace the entry
    /// with the fresh status instead of preserving the old one).
    func staleWarning(for id: String) -> StaleQuotaWarning? {
        staleWarnings[id]
    }

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
        failureNotificationNow: @escaping () -> Date = Date.init,
        statusCacheURL: URL? = nil
    ) {
        self.providers = providers
        self.interval = interval
        self.statusCacheURL = statusCacheURL
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
    /// can take tens of seconds when Codex + Claude both hit their
    /// per-source timeouts. Preserving the cache means the
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

    /// Publishes the result of an explicit Settings self-test immediately so
    /// onboarding can transition to live quota without waiting for the poller.
    func applySelfTestStatus(_ status: ProviderStatus) {
        guard providers.contains(where: { $0.id == status.id }) else { return }
        // The self-test result fully replaces the entry (success or fresh
        // error) rather than merging against a prior snapshot, so any
        // preserved stale-data warning no longer applies.
        staleWarnings.removeValue(forKey: status.id)
        // A self-test that reached real quota is proof the provider works, so
        // the next background flake gets its one free pass again. A failing
        // self-test deliberately leaves the streak alone — it already wrote its
        // error straight into `statuses`, and the poller must not treat that as
        // fresh prior data.
        if status.error == nil {
            errorSurfaceGates[status.id, default: ConsecutiveFailureGate()].recordSuccess()
        }
        if let index = statuses.firstIndex(where: { $0.id == status.id }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byID[$0.id] }
        providerLastFetched[status.id] = Date()
        rebuildDisplayStatuses()
        persistStatuses()
    }

    private func cleanupRemovedProvider(_ id: String) {
        failureNotificationRemove(Self.failureNotificationID(for: id))
        legacyFailureNotificationCleanup(id)
        failureEpisode.removeValue(forKey: id)
        adaptiveFailureCounts.removeValue(forKey: id)
        errorSurfaceGates.removeValue(forKey: id)
        providerLastFetched.removeValue(forKey: id)
        warnState.removeValue(forKey: id)
        staleWarnings.removeValue(forKey: id)
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
    private var providerLastFetched: [String: Date] = [:]
    /// Consecutive awaited failures per provider. The existing loop still
    /// wakes at the configured global cadence; this map only makes failed
    /// providers progressively less likely to perform another expensive fetch.
    private var adaptiveFailureCounts: [String: Int] = [:]
    /// Per-provider gate deciding whether a refresh failure reaches the UI.
    /// Separate from `adaptiveFailureCounts` (fetch cadence) and
    /// `failureEpisode` (notifications) on purpose: this one governs only what
    /// the popover/Settings card renders.
    private var errorSurfaceGates: [String: ConsecutiveFailureGate] = [:]

    /// Where the last published statuses are cached across launches (nil =
    /// persistence disabled, e.g. in unit tests). See ProviderStatusCache.
    private let statusCacheURL: URL?

    // MARK: - Status persistence (CodexBar parity)

    /// Restore the previous session's snapshots so a relaunch shows data
    /// immediately instead of empty placeholders — and seed the per-provider
    /// throttle from each snapshot's own timestamp so an expensive provider
    /// (Claude's CLI probe runs ~1–2 min) isn't refetched on every app start
    /// while its data is still fresh. Only renderable (non-error) snapshots
    /// for currently-enabled providers are restored; a stale error banner
    /// from a previous session is never resurrected.
    func restorePersistedStatuses() {
        guard let url = statusCacheURL, statuses.isEmpty else { return }
        let known = Set(providers.map(\.id))
        let restored = ProviderStatusCache.read(url: url)
            .filter { known.contains($0.id) && $0.isRenderableSnapshot }
        guard !restored.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        statuses = providers.compactMap { byId.removeValue(forKey: $0.id) }
        for status in statuses {
            providerLastFetched[status.id] = status.lastUpdated
        }
        rebuildDisplayStatuses()
    }

    private func persistStatuses() {
        guard let url = statusCacheURL, !statuses.isEmpty else { return }
        ProviderStatusCache.write(statuses, url: url)
    }

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
        let base = override > 0 ? override : interval
        return Self.adaptiveInterval(
            base: base,
            consecutiveFailures: adaptiveFailureCounts[providerId, default: 0]
        )
    }

    /// Deterministic, bounded backoff: the first failure keeps the configured
    /// cadence, then repeated failures use 2x, 4x and at most 8x. Multiplying
    /// the provider's own effective interval means a large user override can
    /// never accidentally be shortened by an absolute cap.
    nonisolated static func adaptiveBackoffMultiplier(for consecutiveFailures: Int) -> Int {
        switch max(0, consecutiveFailures) {
        case 0...1: return 1
        case 2: return 2
        case 3: return 4
        default: return 8
        }
    }

    nonisolated static func adaptiveInterval(base: TimeInterval,
                                             consecutiveFailures: Int) -> TimeInterval {
        guard base > 0 else { return base }
        return base * Double(adaptiveBackoffMultiplier(for: consecutiveFailures))
    }

    /// Test seam and diagnostics without exposing mutable scheduler state.
    func adaptiveBackoffState(for providerID: String)
    -> (consecutiveFailures: Int, multiplier: Int) {
        let failures = adaptiveFailureCounts[providerID, default: 0]
        return (failures, Self.adaptiveBackoffMultiplier(for: failures))
    }

    private func recordAdaptiveOutcome(providerID: String, error: String?) {
        if let error, !error.isEmpty {
            adaptiveFailureCounts[providerID, default: 0] += 1
        } else {
            adaptiveFailureCounts.removeValue(forKey: providerID)
        }
    }

    /// Replace the Codex status with the active account's cached snapshot so an
    /// account switch shows its last-known numbers immediately, before the
    /// refetch completes. No-op when nothing is cached for that account.
    func applyCachedCodexStatus() {
        guard let cached = CodexAccountSnapshotStore.shared.currentSnapshot() else { return }
        // A different account's cached snapshot is a fresh context — any
        // stale-data warning attached to the previous account no longer
        // applies here.
        staleWarnings.removeValue(forKey: "codex")
        if let idx = statuses.firstIndex(where: { $0.id == "codex" }) {
            statuses[idx] = cached
        } else {
            statuses.append(cached)
        }
        rebuildDisplayStatuses()
    }

    /// Fire-and-forget refresh for a control the user just changed in Settings
    /// (source picker, region, token save, account switch). Every such control
    /// must use this instead of a bare `refresh()`: an unforced pass fetches at
    /// `.background`, which makes providers skip user-gated sources — the same
    /// reason a Settings click on a Keychain-only Claude login reported "not
    /// configured". Forcing also bypasses the per-provider interval and
    /// adaptive backoff, so the click always produces a real fetch.
    /// Mirrors CodexBar's `ProviderSettingsRefreshInteraction.perform`.
    ///
    /// `nonisolated` so it can be called straight from a `Binding` setter or a
    /// button action regardless of that closure's isolation, the way the
    /// `Task { await quota.refresh() }` it replaces could be; the hop to the
    /// main actor happens inside.
    nonisolated func refreshFromSettings(_ providerID: String) {
        Task { @MainActor in
            await RefreshInteraction.$isManual.withValue(true) {
                await self.refresh(forceProviderIDs: [providerID])
            }
        }
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
            let successfulProviderIDs = await runRefreshPass(
                forceProviderIDs: nextForceProviderIDs
            )
            guard pendingRefreshRequested else { break }
            // A forced request that queued up WHILE the pass was fetching that
            // same provider is satisfied only when that in-flight fetch
            // succeeded. A failed or skipped background fetch still gets the
            // promised user-initiated retry, which resets adaptive backoff and
            // bypasses provider cooldowns without duplicating successful work.
            nextForceProviderIDs = pendingForceProviderIDs.subtracting(successfulProviderIDs)
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

    private func runRefreshPass(forceProviderIDs: Set<String>) async -> Set<String> {
        let snapshot = providers
        let startedAt = Date()
        let log = Logger(subsystem: "com.local.birdnion", category: "quota.refresh")

        // User-driven refreshes (button, popover-open and account switch)
        // always bypass timing gates and start a fresh failure episode. A
        // failed manual retry becomes failure #1, so it is never immediately
        // penalized by an older automatic backoff streak.
        for id in forceProviderIDs {
            adaptiveFailureCounts.removeValue(forKey: id)
        }

        // Per-provider throttling: skip a provider if its individual override
        // interval (including adaptive backoff) hasn't elapsed since the last
        // fetch attempt. The
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
        var successfulProviderIDs: Set<String> = []
        await withTaskGroup(
            of: (String, ObjectIdentifier, ProviderStatus, TimeInterval).self
        ) { group in
            for p in due {
                // Forced providers (user clicked Refresh / changed a source in
                // Settings) fetch as `.userInitiated` — providers use this to
                // bypass rate-limit cooldowns and allow Keychain prompts.
                let interaction: ProviderInteraction =
                    forceProviderIDs.contains(p.id) ? .userInitiated : .background
                group.addTask {
                    let t0 = Date()
                    let providerIdentity = ObjectIdentifier(p)
                    let status = await ProviderInteractionContext.$current
                        .withValue(interaction) { await p.fetchWithDeadline() }
                    return (p.id, providerIdentity, status, Date().timeIntervalSince(t0))
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
                recordAdaptiveOutcome(providerID: id, error: status.error)
                if status.error == nil {
                    successfulProviderIDs.insert(id)
                }
                // `.notConfigured` reached during a poll is the one ambiguous
                // kind: it usually means the provider was never set up, but it
                // also fires when the fetch DELIBERATELY skipped a user-gated
                // source. A background pass never reads Claude's macOS Keychain
                // login under the default `.onlyOnUserAction` prompt policy, so
                // on a machine where the Keychain is the only credential source
                // every poll "proved" a signed-in provider was unconfigured and
                // wiped its numbers. Give that kind exactly one free pass while
                // a good snapshot is on screen. Every other kind (token
                // revoked, cookie expired, schema drift) is positive evidence
                // from a real response and still surfaces on the first failure.
                // The gate is NOT reset by a forced refresh: a user who clicks
                // Retry and fails again must see the error, not a silent no-op.
                let hadPriorData = previous?.isRenderableSnapshot == true
                let suppressedAsFirstFlake: Bool
                if status.error == nil {
                    errorSurfaceGates[id, default: ConsecutiveFailureGate()].recordSuccess()
                    suppressedAsFirstFlake = false
                } else if classify(rawError: status.error) == .notConfigured {
                    suppressedAsFirstFlake = !errorSurfaceGates[id, default: ConsecutiveFailureGate()]
                        .shouldSurfaceError(onFailureWithPriorData: hadPriorData)
                } else {
                    suppressedAsFirstFlake = false
                }
                // Preserve a good snapshot across a *transient* refresh error
                // (timeout, rate-limit, 5xx) so the popover doesn't flicker to
                // empty. But a credential, cookie, or generic schema error means
                // the shown numbers are no longer trustworthy — the key was
                // revoked/rotated, the cookie expired, or the response shape
                // genuinely changed — so surface the fresh error instead of a
                // stale "still fine" reading.
                if status.error != nil, let previous, previous.isRenderableSnapshot,
                   isTransientForLastGood(rawError: status.error) || suppressedAsFirstFlake {
                    let kind = classify(rawError: status.error) ?? .unknown
                    staleWarnings[id] = StaleQuotaWarning(kind: kind, lastGoodUpdated: previous.lastUpdated)
                    log.warning("preserve stale status for \(id, privacy: .public) after classified refresh error: \(kind.rawValue, privacy: .public)")
                } else {
                    staleWarnings.removeValue(forKey: id)
                    pending[id] = Self.preservingLastGoodServiceStatus(status, previous: previous)
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
        persistStatuses()
        await runWeeklyDigestIfDue()
        return successfulProviderIDs
    }

    // MARK: - Weekly Digest (rolling 7-day cost/token summary notification)

    /// Runs after every completed refresh pass. Gated by
    /// `WeeklyDigest.isEnabled` (a disabled toggle costs one UserDefaults
    /// read) and `WeeklyDigest.isDue` (a 7-day cadence, so an enabled toggle
    /// still only scans once a week). `refreshPassIsRunning` already
    /// serializes every call into `runRefreshPass`, so no separate overlap
    /// flag is needed here. Reuses the same three local cost scanners the
    /// All tab already calls — no new Timer/daemon/polling loop.
    private func runWeeklyDigestIfDue() async {
        guard WeeklyDigest.isEnabled else { return }
        let now = Date()
        guard WeeklyDigest.isDue(now: now, lastEvaluatedAt: WeeklyDigest.lastEvaluatedAt) else { return }

        let enabledIDs = Set(providers.map(\.id))
        let includeClaude = enabledIDs.contains("claude")
        let includeCodex = enabledIDs.contains("codex")
        let includeGrok = enabledIDs.contains("grok")

        let claudeReport = includeClaude ? await ClaudeCostScanner.usageReport(now: now) : nil
        let codexReport = includeCodex ? await CodexCostScanner.usageReport(now: now) : nil
        let grokReport = includeGrok ? await GrokCostScanner.usageReport(now: now) : nil
        let kiroReport = await KiroCostScanner.usageReport(now: now)
        let ompReport = await OMPCostScanner.loadReport(now: now)
        let piReport = await PiCostScanner.loadReport(now: now)
        let includeKiro = kiroReport?.scanConfidence.included == true
        let includeOMP = ompReport.scanConfidence.included
        let includePi = piReport.scanConfidence.included
        guard includeClaude || includeCodex || includeGrok || includeKiro || includeOMP || includePi else {
            WeeklyDigest.lastEvaluatedAt = now
            return
        }

        let evaluation = WeeklyDigest.evaluate(
            claude: claudeReport, codex: codexReport, grok: grokReport,
            kiro: kiroReport, omp: ompReport, pi: piReport,
            includeClaude: includeClaude, includeCodex: includeCodex, includeGrok: includeGrok,
            includeKiro: includeKiro, includeOMP: includeOMP, includePi: includePi,
            budgetUSD: WeeklyDigest.budgetUSD,
            budgetPeriod: WeeklyDigest.budgetPeriod,
            now: now)

        // Stamp the evaluation cadence regardless of outcome — a suppressed
        // week (no live source, or zero activity) must not rescan on every
        // refresh for the rest of the day.
        WeeklyDigest.lastEvaluatedAt = now
        guard evaluation.shouldSend else { return }

        let posted = await QuotaNotifier.postAndWait(
            id: WeeklyDigest.notificationID, title: evaluation.title, body: evaluation.body)
        if posted {
            WeeklyDigest.lastSentAt = now
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

    // MARK: - Service-status last-good preservation

    /// When a fresh, successful status (`error == nil`) comes back with BOTH
    /// service-status fields nil — the side probe (e.g. a status-page fetch
    /// separate from the quota windows) didn't return anything this cycle —
    /// carry forward the same provider's last-good `serviceStatus` /
    /// `serviceStatusLevel` pair so a transient probe hiccup doesn't blank
    /// the health line. Everything else (windows, `lastUpdated`, `error`,
    /// ...) always comes from the incoming snapshot. Never runs when the
    /// primary fetch itself failed (that error must surface, not be
    /// masked), never merges across providers, and any incoming non-nil
    /// service-status value always wins — this only fills a true nil/nil gap.
    nonisolated static func preservingLastGoodServiceStatus(
        _ status: ProviderStatus, previous: ProviderStatus?
    ) -> ProviderStatus {
        guard status.error == nil else { return status }
        guard let previous, previous.id == status.id else { return status }
        guard status.serviceStatus == nil, status.serviceStatusLevel == nil else { return status }
        guard previous.serviceStatus != nil || previous.serviceStatusLevel != nil else { return status }
        return status.withServiceStatus(previous.serviceStatus, level: previous.serviceStatusLevel)
    }
}

// MARK: - Shared provider fetch deadline

/// Hard outer deadline for a single provider fetch, shared by the background
/// refresh loop AND Settings self-test (`ProvidersPane.runSelfTest`) so one
/// hung/misbehaving provider can never stall a whole refresh pass — and
/// therefore the next auto-refresh cycle — or leave a self-test spinning
/// forever.
///
/// This is a pure backstop, not a replacement for each provider's own
/// internal budgets: it sits well above the slowest known legitimate chain
/// (Claude's cold CLI probe, observed up to ~160s with its OAuth/CLI/web
/// fallback chain) so no existing provider is cut off mid-flight.
enum ProviderFetchDeadline {
    static let seconds: TimeInterval = 200
}

/// Serializes the single "who resumes the continuation" decision below so a
/// slow fetch that finishes right as the deadline fires can never resume
/// twice (which would trap). An `actor` gives mutual exclusion without a
/// manual lock.
private actor ProviderFetchDeadlineResumeBox {
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<ProviderStatus, Never>, with status: ProviderStatus) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: status)
    }
}

extension QuotaProvider {
    /// `fetchWithDeadline()` under an explicit `.userInitiated` interaction —
    /// the entry point for one-shot probes the user asked for (Settings
    /// self-test), which bypass `QuotaService.refresh()` and would otherwise
    /// inherit the task-local default `.background`.
    ///
    /// That default is wrong for a user action and not merely cosmetic:
    /// providers gate real sources on it. Claude only reads the macOS Keychain
    /// item `Claude Code-credentials` when the interaction is `.userInitiated`
    /// (prompt mode `.onlyOnUserAction`), so on a machine where the Keychain is
    /// the ONLY credential source — no `~/.claude/.credentials.json`, no env
    /// token — a `.background` self-test resolved no credentials and reported
    /// "not configured" for a provider that was actually signed in.
    func fetchAsUserAction(deadline: TimeInterval = ProviderFetchDeadline.seconds) async -> ProviderStatus {
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await fetchWithDeadline(deadline: deadline)
        }
    }

    /// Races `fetch()` against `deadline` (defaults to
    /// `ProviderFetchDeadline.seconds`; overridable for tests) and returns
    /// whichever finishes first.
    ///
    /// Deliberately NOT implemented with `withTaskGroup`: a structured task
    /// group only returns once every child task has actually finished, even
    /// after `cancelAll()` — cancellation is cooperative, so a provider that
    /// never checks `Task.isCancelled` (blocked on synchronous I/O, or a
    /// loop that swallows `CancellationError`) would keep the whole group —
    /// and therefore this function — from returning until IT finishes,
    /// silently defeating the deadline. Racing via an unstructured `Task`
    /// plus a checked continuation lets this function return the moment the
    /// deadline fires regardless of whether the fetch cooperates; the loser
    /// keeps running detached (best-effort — it may never actually stop) but
    /// can no longer hold up the caller. The timeout status's error message
    /// contains "Timeout" so `classify(rawError:)` resolves it to
    /// `.networkUnreachableOrTimeout`.
    func fetchWithDeadline(deadline: TimeInterval = ProviderFetchDeadline.seconds) async -> ProviderStatus {
        let timeoutStatus = ProviderStatus(
            id: id, displayName: displayName, windows: [], lastUpdated: Date(),
            error: "Timeout: provider did not respond within \(Int(deadline))s")
        let box = ProviderFetchDeadlineResumeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProviderStatus, Never>) in
            let fetchTask = Task {
                let status: ProviderStatus
                do {
                    status = try await self.fetch()
                } catch {
                    status = ProviderStatus(id: self.id, displayName: self.displayName,
                                             windows: [], lastUpdated: Date(), error: "\(error)")
                }
                await box.resumeOnce(continuation, with: status)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
                // Best-effort: stops a cooperative provider early; a
                // non-cooperative one ignores this and keeps running
                // detached, but the resume below still fires on time.
                fetchTask.cancel()
                await box.resumeOnce(continuation, with: timeoutStatus)
            }
        }
    }
}

// MARK: - Status cache (disk)

/// Disk cache of the last published statuses, stored next to the config file
/// (like cost-history.json). Read at launch by `restorePersistedStatuses()`,
/// written after every completed refresh pass. Best-effort — a missing or
/// corrupt file just means the popover starts empty like before.
enum ProviderStatusCache {
    static func cacheURL(configURL: URL = BirdNionConfigStore.configURL()) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("status-cache.json")
    }

    static func read(url: URL = cacheURL()) -> [ProviderStatus] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ProviderStatus].self, from: data)
        else { return [] }
        return list
    }

    static func write(_ statuses: [ProviderStatus], url: URL = cacheURL()) {
        // Error statuses may contain provider-returned details. They are useful
        // for the current in-memory UI, but must never cross the disk boundary.
        let snapshots = statuses.filter(\.isRenderableSnapshot)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension ProviderStatus {
    /// A previous non-error snapshot that has meaningful UI content. When a
    /// follow-up refresh times out, keep this around so the popover does not
    /// collapse quota rows or chart payloads into an error-only card. Also
    /// the restore filter for the disk cache.
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

    /// Awaitable variant of `post` — returns `true` only when the OS
    /// actually queued the notification (authorization granted AND `add`
    /// completed without an error). Used by `WeeklyDigest` so `lastSentAt`
    /// only advances on confirmed delivery; every other call site keeps
    /// using the fire-and-forget `post` above, which this does not replace.
    @discardableResult
    static func postAndWait(id: String, title: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let soundEnabled = QuotaWarnConfig.soundEnabled
        let posted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            operations.enqueue {
                let granted = await requestAuthorization(center)
                guard granted else {
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
