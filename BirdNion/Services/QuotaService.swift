import Foundation
import Combine
import SwiftUI
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

/// Facade over `ProviderScheduler`. Keeps the public surface and semantics:
/// statuses publish incrementally as lanes emit, warnings/failure episodes/
/// persistence/notifications stay identical, and the refresh coalescing
/// queue serializes whole-refresh callers while lanes inside a batch run
/// independently.
@MainActor
final class QuotaService: ObservableObject {
    @Published private(set) var statuses: [ProviderStatus] = []
    @Published private(set) var displayStatuses: [ProviderStatus] = []
    /// Derived from the scheduler's in-flight lane set — true while any
    /// provider lane is mid-fetch (core or extras phase).
    @Published private(set) var isRefreshing: Bool = false
    /// Per-provider in-flight set — powers the per-card refresh indicator.
    @Published private(set) var fetchingIDs: Set<String> = []

    /// Bumped when the background per-account Antigravity refresh stores a new
    /// snapshot. The popover's all-accounts card reads `AccountSnapshotStore`
    /// directly — SwiftUI cannot observe that file, so this publish is what
    /// puts the freshly fetched rows on screen.
    @Published private(set) var accountSnapshotsRevision: Int = 0

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

    /// Merge a lane emission into `statuses`, preserving provider order.
    private func mergePublished(_ status: ProviderStatus) {
        if let index = statuses.firstIndex(where: { $0.id == status.id }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byID[$0.id] }
        rebuildDisplayStatuses()
        if passIsFirstRefresh, !passFirstCompletionLogged {
            passFirstCompletionLogged = true
            if let started = passStartedAt {
                Self.refreshLog.info(
                    "first fetch done in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s — popover has data")
            }
        }
    }

    /// Per provider+window warning state: last seen remaining % and the set of
    /// thresholds already fired (so we notify once per crossing, not every poll).
    private var warnState: [String: [String: (last: Int, fired: Set<Int>)]] = [:]

    /// Current stale-data warning for a provider, if its last refresh failed
    /// transiently while a last-good snapshot was preserved. `nil` once a
    /// fresh success or a non-transient error lands (both replace the entry
    /// with the fresh status instead of preserving the old one).
    func staleWarning(for id: String) -> StaleQuotaWarning? {
        scheduler.lane(for: id)?.staleWarning
    }

    private(set) var providers: [QuotaProvider] = []
    private var interval: TimeInterval
    private var loopTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var refreshPassIsRunning = false
    private var antigravityAccountRefreshTask: Task<Void, Never>?
    private var antigravityAccountRefreshGeneration: UInt = 0
    private var pendingRefreshRequested = false
    private var pendingForceProviderIDs: Set<String> = []
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var settingsRefreshTask: Task<Void, Never>?
    private var pendingSettingsRefreshProviderIDs: Set<String> = []
    private var settingsRefreshGeneration: UInt = 0

    // Per-pass diagnostics (reset at each `runSchedulerPass`).
    private static let refreshLog = Logger(
        subsystem: "com.local.birdnion", category: "quota.refresh")
    private var passStartedAt: Date?
    private var passIsFirstRefresh = false
    private var passFirstCompletionLogged = false
    private var passTimings: [(String, TimeInterval)] = []

    private lazy var scheduler: ProviderScheduler = {
        var hooks = ProviderLane.Hooks()
        hooks.publish = { [weak self] status in self?.mergePublished(status) }
        hooks.warningsChanged = { [weak self] in
            guard let self, QuotaWarnConfig.enabled else { return }
            self.evaluateWarnings(self.statuses)
        }
        hooks.evaluateFailure = { [weak self] id, name, error in
            self?.evaluateFailureEpisode(id: id, displayName: name, error: error)
        }
        hooks.invalidateCleanup = { [weak self] id in
            guard let self else { return }
            self.failureEpisode.removeValue(forKey: id)
            self.warnState.removeValue(forKey: id)
            self.failureNotificationRemove(Self.failureNotificationID(for: id))
            self.legacyFailureNotificationCleanup(id)
        }
        hooks.saveAccountSnapshot = { [weak self] status in
            self?.saveAccountSnapshot(for: status)
        }
        hooks.fetchingChanged = { [weak self] in self?.syncFetchingState() }
        hooks.recordTiming = { [weak self] id, elapsed in
            self?.passTimings.append((id, elapsed))
        }
        let scheduler = ProviderScheduler(hooks: hooks)
        scheduler.onBatchSettled = { [weak self] in
            await self?.handleBatchSettled()
        }
        scheduler.configure(providers: providers)
        return scheduler
    }()

    private func syncFetchingState() {
        fetchingIDs = scheduler.fetchingIDs
        isRefreshing = scheduler.isRefreshing
    }

    /// Per-account snapshot write keyed under the ACTIVE account at publish
    /// time, so the popover can show every account's last known quota without
    /// paying for a fetch per account.
    private func saveAccountSnapshot(for status: ProviderStatus) {
        let snapshotAccountKey: String? = switch status.id {
        case "codex": CodexAccountStore.activeSelection().id
        case "antigravity": AntigravityOAuthStore.load().activeLabel
        default: nil
        }
        guard let snapshotAccountKey else { return }
        switch status.id {
        case "codex": codexSnapshotSave(status, snapshotAccountKey)
        case "antigravity": antigravitySnapshotSave(status, snapshotAccountKey)
        default: break
        }
    }

    typealias FailureNotificationPost = @MainActor (
        _ id: String, _ title: String, _ body: String
    ) -> Void
    typealias FailureNotificationRemove = @MainActor (_ id: String) -> Void
    typealias LegacyFailureNotificationCleanup = @MainActor (_ providerID: String) -> Void
    typealias AllFailureNotificationCleanup = @MainActor () -> Void
    typealias CodexSnapshotSave = (_ status: ProviderStatus, _ accountID: String) -> Void
    typealias CodexSnapshotRemove = (_ accountID: String) -> Void
    typealias AntigravitySnapshotSave =
        (_ status: ProviderStatus, _ accountLabel: String) -> Void
    private let failureNotificationPost: FailureNotificationPost
    private let failureNotificationRemove: FailureNotificationRemove
    private let legacyFailureNotificationCleanup: LegacyFailureNotificationCleanup
    private let allFailureNotificationCleanup: AllFailureNotificationCleanup
    private let codexSnapshotSave: CodexSnapshotSave
    private let codexSnapshotRemove: CodexSnapshotRemove
    private let antigravitySnapshotSave: AntigravitySnapshotSave
    private let failureNotificationNow: () -> Date
    private let settingsRefreshDebounceNanoseconds: UInt64
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
        statusCacheURL: URL? = nil,
        settingsRefreshDebounceNanoseconds: UInt64 = 350_000_000,
        codexSnapshotRemove: @escaping CodexSnapshotRemove = {
            _ = AccountSnapshotStore.codex.removeSnapshot(forAccount: $0)
        },
        codexSnapshotSave: @escaping CodexSnapshotSave = {
            AccountSnapshotStore.codex.save($0, forAccount: $1)
        },
        antigravitySnapshotSave: @escaping AntigravitySnapshotSave = {
            AccountSnapshotStore.antigravity.save($0, forAccount: $1)
        }
    ) {
        self.providers = providers
        self.interval = interval
        self.statusCacheURL = statusCacheURL
        self.failureNotificationPost = failureNotificationPost
        self.failureNotificationRemove = failureNotificationRemove
        self.legacyFailureNotificationCleanup = legacyFailureNotificationCleanup
        self.allFailureNotificationCleanup = allFailureNotificationCleanup
        self.codexSnapshotSave = codexSnapshotSave
        self.codexSnapshotRemove = codexSnapshotRemove
        self.antigravitySnapshotSave = antigravitySnapshotSave
        self.failureNotificationNow = failureNotificationNow
        self.settingsRefreshDebounceNanoseconds = settingsRefreshDebounceNanoseconds
    }

    /// Update the polling interval. The running loop reads `self.interval`
    /// fresh on every iteration, so the change applies at the next sleep.
    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
    }

    func add(_ p: QuotaProvider) {
        providers.append(p)
        scheduler.configure(providers: providers)
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
        if let current = providers.first(where: { $0.id == "antigravity" }),
           let replacement = newProviders.first(where: { $0.id == "antigravity" }),
           ObjectIdentifier(current) != ObjectIdentifier(replacement)
        {
            cancelAntigravityAccountSnapshotRefresh()
        }
        providers = newProviders
        scheduler.configure(providers: providers)
        statuses = statuses.filter { keep.contains($0.id) }
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
        scheduler.configure(providers: providers)
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
        let lane = scheduler.lane(for: status.id)
        lane?.adopt(status, fetchedAt: Date())
        // A self-test that reached real quota is proof the provider works, so
        // the next background flake gets its one free pass again. A failing
        // self-test deliberately leaves the streak alone — it already wrote its
        // error straight into `statuses`, and the poller must not treat that as
        // fresh prior data.
        if status.error == nil {
            lane?.recordSurfaceGateSuccess()
        }
        if let index = statuses.firstIndex(where: { $0.id == status.id }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        statuses = providers.compactMap { byID[$0.id] }
        rebuildDisplayStatuses()
        persistStatuses()
    }

    private func cleanupRemovedProvider(_ id: String) {
        if id == "antigravity" {
            cancelAntigravityAccountSnapshotRefresh()
        }
        failureNotificationRemove(Self.failureNotificationID(for: id))
        legacyFailureNotificationCleanup(id)
        failureEpisode.removeValue(forKey: id)
        warnState.removeValue(forKey: id)
        // Lane teardown (in-flight cancel + per-provider state drop) happens
        // in `scheduler.configure` / `remove` right after this call.
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
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .birdnionRefresh, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let providerID = notification.object as? String {
                self.refreshFromSettings(providerID)
                return
            }
            // Mark this as a user-initiated refresh so background-only throttles
            // (e.g. the Codex CLI launch gate) let the retry through. Manual
            // refreshes also bypass per-provider interval throttles so the
            // footer/header action always fetches fresh data.
            Task { @MainActor in
                await RefreshInteraction.$isManual.withValue(true) {
                    await self.refresh(forceProviderIDs: Set(self.providers.map(\.id)))
                }
            }
        })
        // Codex account switch: show that account's cached snapshot instantly,
        // then refetch (also counts as a manual interaction).
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .birdnionCodexAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.invalidateProviderContext(for: "codex")
                self.applyCachedCodexStatus()
                self.scheduleSettingsRefresh(for: "codex")
            }
        })
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
        scheduler.cancelAll()
        cancelAntigravityAccountSnapshotRefresh()
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        pendingSettingsRefreshProviderIDs.removeAll()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

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
            // Seed the lane's cadence clock AND its last-good base so a
            // transient first-poll failure preserves the restored card.
            scheduler.lane(for: status.id)?.adopt(status, fetchedAt: status.lastUpdated)
        }
        rebuildDisplayStatuses()
    }

    private func persistStatuses() {
        guard let url = statusCacheURL else { return }
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
        let failures = scheduler.lane(for: providerID)?.adaptiveFailureCount ?? 0
        return (failures, Self.adaptiveBackoffMultiplier(for: failures))
    }

    /// Replace the Codex status with the active account's cached snapshot so an
    /// account switch shows its last-known numbers immediately, before the
    /// refetch completes. No-op when nothing is cached for that account.
    func applyCachedCodexStatus() {
        guard let cached = AccountSnapshotStore.codex.currentCodexSnapshot() else { return }
        // A different account's cached snapshot is a fresh context — any
        // stale-data warning attached to the previous account no longer
        // applies here (adopt clears it).
        scheduler.lane(for: "codex")?.adopt(cached)
        if let idx = statuses.firstIndex(where: { $0.id == "codex" }) {
            statuses[idx] = cached
        } else {
            statuses.append(cached)
        }
        rebuildDisplayStatuses()
    }

    /// Invalidate immediately, then debounce a forced refresh for a durable
    /// provider identity/configuration change made in Settings.
    /// (source picker, region, token save, account switch). Every such control
    /// must use this instead of a bare `refresh()`: an unforced pass fetches at
    /// `.background`, which makes providers skip user-gated sources — the same
    /// reason a Settings click on a Keychain-only Claude login reported "not
    /// configured". Forcing also bypasses the per-provider interval and
    /// adaptive backoff, so the click always produces a real fetch.
    /// Mirrors CodexBar's `ProviderSettingsRefreshInteraction.perform`.
    ///
    /// Binding setters are not actor-annotated in the SwiftUI API, but every
    /// production callsite is a main-queue UI or NotificationCenter callback.
    /// Keeping this entry nonisolated avoids forcing those synchronous setters
    /// to spawn a Task, while `assumeIsolated` enforces the main-actor contract.
    nonisolated func refreshFromSettings(_ providerID: String) {
        MainActor.assumeIsolated {
            if providerID == "codex" {
                codexSnapshotRemove(CodexAccountStore.activeSelection().id)
            }
            invalidateProviderContext(for: providerID)
            scheduleSettingsRefresh(for: providerID)
        }
    }

    private func scheduleSettingsRefresh(for providerID: String) {
        pendingSettingsRefreshProviderIDs.insert(providerID)
        settingsRefreshGeneration &+= 1
        let generation = settingsRefreshGeneration
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.settingsRefreshDebounceNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: self.settingsRefreshDebounceNanoseconds
                )
            }
            guard !Task.isCancelled,
                  self.settingsRefreshGeneration == generation else { return }
            let providerIDs = self.pendingSettingsRefreshProviderIDs
            self.pendingSettingsRefreshProviderIDs.removeAll()
            self.settingsRefreshTask = nil
            await RefreshInteraction.$isManual.withValue(true) {
                await self.refresh(forceProviderIDs: providerIDs)
            }
        }
    }

    /// Invalidates every in-flight completion that captured the provider's
    /// prior account/configuration. Runtime and persisted status from that
    /// context are cleared so last-good data never crosses identities.
    func invalidateProviderContext(for providerID: String) {
        if providerID == "antigravity" {
            cancelAntigravityAccountSnapshotRefresh()
        }
        // Lane-side: generation bump + cadence/gate/state reset + cleanup hook.
        scheduler.lane(for: providerID)?.invalidateContext()
        statuses.removeAll { $0.id == providerID }
        rebuildDisplayStatuses()
        persistStatuses()
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
        var nextForceProviderIDs = forceProviderIDs
        repeat {
            let passStart = Date()
            await runSchedulerPass(forceProviderIDs: nextForceProviderIDs)
            guard pendingRefreshRequested else { break }
            // A forced request that queued up WHILE the pass was fetching that
            // same provider is satisfied only when that in-flight fetch
            // succeeded. A failed or skipped background fetch still gets the
            // promised user-initiated retry, which resets adaptive backoff and
            // bypasses provider cooldowns without duplicating successful work.
            nextForceProviderIDs = Set(pendingForceProviderIDs.filter { providerID in
                guard let lane = scheduler.lane(for: providerID) else { return true }
                guard lane.succeededGeneration == lane.contextGeneration,
                      let succeededAt = lane.lastSucceededAt,
                      succeededAt >= passStart
                else { return true }
                return false
            })
            pendingForceProviderIDs.removeAll()
            pendingRefreshRequested = false
        } while true
        refreshPassIsRunning = false

        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Test seam for deterministic fan-in assertions.
    func refreshCoordinatorState() -> (running: Bool, pending: Bool, forcedProviderIDs: Set<String>) {
        (refreshPassIsRunning, pendingRefreshRequested, pendingForceProviderIDs)
    }

    /// Test seam for deterministic provider-identity debounce assertions.
    func settingsRefreshCoordinatorState() -> (scheduled: Bool, providerIDs: Set<String>) {
        (settingsRefreshTask != nil, pendingSettingsRefreshProviderIDs)
    }

    /// One refresh pass over the scheduler: Codex bookkeeping for the cadence
    /// rides ahead of the batch, then due lanes kick and settle independently.
    private func runSchedulerPass(forceProviderIDs: Set<String>) async {
        passStartedAt = Date()
        passIsFirstRefresh = statuses.isEmpty
        passFirstCompletionLogged = false
        passTimings = []

        // Token-rotation sync-back: reconcile the managed account's cached
        // auth.json copy against ~/.codex/auth.json on the existing refresh
        // cadence (no new polling loop). Best-effort — swallows errors.
        let codexDue = forceProviderIDs.contains("codex")
            || (scheduler.lane(for: "codex")?
                .isDue(now: Date(), globalInterval: interval) ?? false)
        if codexDue {
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

        let dueCount = providerCountPendingFetch(forceProviderIDs)
        let providerCount = providers.count
        Self.refreshLog.info(
            "refresh start — due=\(dueCount, privacy: .public)/\(providerCount, privacy: .public)")
        await scheduler.refreshAll(
            forceProviderIDs: forceProviderIDs, globalInterval: interval)
    }

    /// How many providers this pass will actually fetch — mirrors the old
    /// `due.count` log field (forced ids + non-forced lanes that are due).
    private func providerCountPendingFetch(_ forceProviderIDs: Set<String>) -> Int {
        providers.filter { p in
            if forceProviderIDs.contains(p.id) { return true }
            return scheduler.lane(for: p.id)?
                .isDue(now: Date(), globalInterval: interval) ?? false
        }.count
    }

    /// Post-batch work — runs once per scheduler batch, including batches
    /// that kicked zero lanes (the digest cadence is internally gated).
    private func handleBatchSettled() async {
        let log = Self.refreshLog
        // Log slow providers (>2s) so the cause of slow loads is
        // visible in Console.app without attaching a debugger.
        if let started = passStartedAt {
            let total = Date().timeIntervalSince(started)
            let sortedByDuration = passTimings.sorted { $0.1 > $1.1 }
            for (id, elapsed) in sortedByDuration where elapsed > 2.0 {
                log.warning("slow provider: \(id, privacy: .public) took \(String(format: "%.2f", elapsed), privacy: .public)s")
            }
            log.info("refresh done — total=\(String(format: "%.2f", total), privacy: .public)s slow=\(sortedByDuration.filter { $0.1 > 2.0 }.count, privacy: .public)")
        }
        persistStatuses()
        scheduleAntigravityAccountSnapshotRefresh()
        await runWeeklyDigestIfDue()
        syncFetchingState()
    }

    /// Tops up the popover's all-accounts Antigravity card in the background.
    /// The pass above only probes the ACTIVE account, so every other account
    /// would read "no data" until the user switched to it. Deliberately NOT
    /// awaited: it makes three HTTPS round trips per account and must not hold
    /// up the refresh pass. Coalesced — never more than one in flight.
    private func scheduleAntigravityAccountSnapshotRefresh() {
        guard antigravityAccountRefreshTask == nil,
              let provider = providers.first(where: { $0.id == "antigravity" })
                  as? AntigravityProvider,
              let lane = scheduler.lane(for: provider.id)
        else { return }
        let providerIdentity = ObjectIdentifier(provider)
        let contextGeneration = lane.contextGeneration
        antigravityAccountRefreshGeneration &+= 1
        let refreshGeneration = antigravityAccountRefreshGeneration
        antigravityAccountRefreshTask = Task { [weak self] in
            let stored = await AntigravityAccountSnapshotRefresher
                .refreshStaleAccounts(provider: provider)
            guard let self,
                  refreshGeneration == antigravityAccountRefreshGeneration
            else { return }
            antigravityAccountRefreshTask = nil
            guard !Task.isCancelled,
                  scheduler.lane(for: provider.id)?.contextGeneration == contextGeneration,
                  providers.contains(where: {
                      $0.id == provider.id && ObjectIdentifier($0) == providerIdentity
                  })
            else { return }
            if stored { accountSnapshotsRevision &+= 1 }
        }
    }

    private func cancelAntigravityAccountSnapshotRefresh() {
        antigravityAccountRefreshGeneration &+= 1
        antigravityAccountRefreshTask?.cancel()
        antigravityAccountRefreshTask = nil
    }

    // MARK: - Weekly Digest (rolling 7-day cost/token summary notification)

    /// Runs after every completed refresh pass. Gated by
    /// `WeeklyDigest.isEnabled` (a disabled toggle costs one UserDefaults
    /// read) and `WeeklyDigest.isDue` (a 7-day cadence, so an enabled toggle
    /// still only scans once a week). The refresh serializer already
    /// serializes every call into `runSchedulerPass`, so no separate overlap
    /// flag is needed here. Reuses the same six local cost scanners the All
    /// tab already calls — no new Timer/daemon/polling loop.
    private func runWeeklyDigestIfDue() async {
        guard WeeklyDigest.isEnabled else { return }
        let now = Date()
        guard WeeklyDigest.isDue(now: now, lastEvaluatedAt: WeeklyDigest.lastEvaluatedAt) else { return }

        let enabledIDs = Set(providers.map(\.id))
        let detectedAgentRecords = await Task.detached(priority: .utility) {
            InstalledAgentDetectors.detect()
        }.value
        let authorizedSources = Self.authorizedWeeklyDigestSources(
            enabledProviderIDs: enabledIDs,
            detectedAgentRecords: detectedAgentRecords)
        guard !authorizedSources.isEmpty else {
            WeeklyDigest.lastEvaluatedAt = now
            return
        }

        let claudeReport = authorizedSources.contains(.claude)
            ? await UsageReportCoordinator.shared.claudeReport() : nil
        let codexReport = authorizedSources.contains(.codex)
            ? await UsageReportCoordinator.shared.codexReport() : nil
        let grokReport = authorizedSources.contains(.grok)
            ? await UsageReportCoordinator.shared.grokReport() : nil
        let kiroReport = authorizedSources.contains(.kiro)
            ? await UsageReportCoordinator.shared.kiroReport() : nil
        let ompReport = authorizedSources.contains(.omp)
            ? await UsageReportCoordinator.shared.ompReport() : nil
        let piReport = authorizedSources.contains(.pi)
            ? await UsageReportCoordinator.shared.piReport() : nil

        // Scanner calls can take long enough for a provider to be disabled or
        // an agent to be removed. Re-read both sources of authority at the
        // evaluation boundary, and never add a newly-authorized source whose
        // report was not scanned in this pass.
        let currentDetectedAgentRecords = await Task.detached(priority: .utility) {
            InstalledAgentDetectors.detect()
        }.value
        // The user may opt out while the asynchronous scanners are running.
        // Do not stamp or notify after consent has been withdrawn.
        guard WeeklyDigest.isEnabled else { return }
        let revalidatedSources = Self.revalidatedWeeklyDigestSources(
            scannedSources: authorizedSources,
            enabledProviderIDs: Set(providers.map(\.id)),
            detectedAgentRecords: currentDetectedAgentRecords)
        guard !revalidatedSources.isEmpty else {
            WeeklyDigest.lastEvaluatedAt = now
            return
        }

        let evaluation = WeeklyDigest.evaluate(
            claude: claudeReport, codex: codexReport, grok: grokReport,
            kiro: kiroReport, omp: ompReport, pi: piReport,
            includeClaude: revalidatedSources.contains(.claude),
            includeCodex: revalidatedSources.contains(.codex),
            includeGrok: revalidatedSources.contains(.grok),
            includeKiro: revalidatedSources.contains(.kiro),
            includeOMP: revalidatedSources.contains(.omp),
            includePi: revalidatedSources.contains(.pi),
            budgetUSD: WeeklyDigest.budgetUSD,
            budgetPeriod: WeeklyDigest.budgetPeriod,
            now: now)

        // Stamp the evaluation cadence regardless of outcome — a suppressed
        // week (no live source, or zero activity) must not rescan on every
        // refresh for the rest of the day.
        WeeklyDigest.lastEvaluatedAt = now
        guard evaluation.shouldSend else { return }

        let posted = await QuotaNotifier.postAndWait(
            id: WeeklyDigest.notificationID,
            title: evaluation.title,
            body: evaluation.body,
            revalidate: { [weak self] in
                guard let self else { return false }
                let detectedAgentRecords = await Task.detached(priority: .utility) {
                    InstalledAgentDetectors.detect()
                }.value
                guard WeeklyDigest.isEnabled else { return false }
                return Self.weeklyDigestSourcesRemainAuthorized(
                    evaluatedSources: revalidatedSources,
                    enabledProviderIDs: Set(self.providers.map(\.id)),
                    detectedAgentRecords: detectedAgentRecords)
            })
        if posted {
            WeeklyDigest.lastSentAt = now
        }
    }

    /// Canonical local-cost authorization shared by digest scanner and build
    /// gates. Provider enablement or a current safe detector record is enough;
    /// retained reports/history never grant access on their own.
    nonisolated static func authorizedWeeklyDigestSources(
        enabledProviderIDs: Set<String>,
        detectedAgentRecords: [InstalledAgentRecord]
    ) -> Set<WeeklyDigest.SourceID> {
        let detectedIDs = Set(detectedAgentRecords.compactMap { record in
            record.evidence.isEmpty ? nil : record.id.rawValue
        })
        return Set(WeeklyDigest.SourceID.allCases.filter { source in
            enabledProviderIDs.contains(source.rawValue)
                || detectedIDs.contains(source.rawValue)
        })
    }

    /// Keeps only sources that were scanned and remain authorized after the
    /// asynchronous scan phase. A newly enabled source waits for the next pass.
    nonisolated static func revalidatedWeeklyDigestSources(
        scannedSources: Set<WeeklyDigest.SourceID>,
        enabledProviderIDs: Set<String>,
        detectedAgentRecords: [InstalledAgentRecord]
    ) -> Set<WeeklyDigest.SourceID> {
        scannedSources.intersection(authorizedWeeklyDigestSources(
            enabledProviderIDs: enabledProviderIDs,
            detectedAgentRecords: detectedAgentRecords))
    }

    /// A digest body is valid only while every source used to construct it
    /// remains authorized. Newly authorized sources wait for the next scan;
    /// losing even one evaluated source suppresses the already-built body.
    nonisolated static func weeklyDigestSourcesRemainAuthorized(
        evaluatedSources: Set<WeeklyDigest.SourceID>,
        enabledProviderIDs: Set<String>,
        detectedAgentRecords: [InstalledAgentRecord]
    ) -> Bool {
        revalidatedWeeklyDigestSources(
            scannedSources: evaluatedSources,
            enabledProviderIDs: enabledProviderIDs,
            detectedAgentRecords: detectedAgentRecords) == evaluatedSources
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
    /// result (lanes route core-emission outcomes here). Posts with one
    /// stable provider ID and removes pending/delivered copies only after
    /// recovery is confirmed.
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
///
/// Lane scheduling (task-02) now bounds time-to-first-emission separately
/// via `ProviderFetchPhaseBudgets`; this deadline still backs the one-shot
/// `fetchAsUserAction`/`fetchWithDeadline` self-test path.
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
    /// "not configured" for a provider that was actually signed in. Codex's
    /// CLI launch cooldown uses the older `RefreshInteraction` task-local, so
    /// a Guided Setup retry must set both interaction seams consistently.
    func fetchAsUserAction(deadline: TimeInterval = ProviderFetchDeadline.seconds) async -> ProviderStatus {
        await RefreshInteraction.$isManual.withValue(true) {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await fetchWithDeadline(deadline: deadline)
            }
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
    static let maxStoredBytes = 2 * 1024 * 1024

    static func cacheURL(configURL: URL = BirdNionConfigStore.configURL()) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("status-cache.json")
    }

    static func read(url: URL = cacheURL()) -> [ProviderStatus] {
        guard let data = try? CodexAuthStore.readPrivateFile(
                  url, maximumBytes: maxStoredBytes),
              let list = try? JSONDecoder().decode([ProviderStatus].self, from: data)
        else { return [] }
        return list
    }

    static func write(_ statuses: [ProviderStatus], url: URL = cacheURL()) {
        // Error statuses may contain provider-returned details. They are useful
        // for the current in-memory UI, but must never cross the disk boundary.
        let snapshots = statuses.filter(\.isRenderableSnapshot)
        guard let data = try? JSONEncoder().encode(snapshots),
              data.count <= maxStoredBytes
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CodexAuthStore.writePrivateFile(
                data, to: url, maximumBytes: maxStoredBytes)
        } catch {
            // Best-effort cache only. A failed secure write leaves runtime
            // state untouched and restore fails closed on the next launch.
        }
    }
}

extension ProviderStatus {
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
