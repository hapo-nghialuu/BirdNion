import Foundation
import os

/// Per-provider scheduling lane. Owns everything `QuotaService` used to keep
/// in parallel dictionaries: fetch cadence state, failure bookkeeping, the
/// in-flight fetch task, and the merge rules that decide what reaches
/// `statuses`. A lane is the only place a provider's fetch is started —
/// `kick` deduplicates concurrent requests and queues a forced follow-up
/// behind a background fetch.
///
/// Lane in-flight lifetime = kick → stream end or extras deadline (F-08):
/// a second kick never starts a parallel fetch while extras are pending,
/// but the card publishes the core status at emission 0.
@MainActor
final class ProviderLane {
    /// Callbacks the facade injects. All run on the main actor.
    struct Hooks {
        /// Merge output → `QuotaService.statuses`.
        var publish: (ProviderStatus) -> Void = { _ in }
        /// Re-evaluate quota warnings after a core publish (facade iterates
        /// the full status list — warnings are cross-provider).
        var warningsChanged: () -> Void = {}
        /// Failure-episode evaluation — facade owns the state machine (its
        /// `evaluateFailureEpisode` is a public test seam for arbitrary ids).
        var evaluateFailure: (String, String, String?) -> Void = { _, _, _ in }
        /// Account/config invalidation cleanup (notification removal +
        /// facade dictionaries), fired by `invalidateContext`.
        var invalidateCleanup: (String) -> Void = { _ in }
        /// Account-keyed snapshot save (codex/antigravity) on renderable core.
        var saveAccountSnapshot: (ProviderStatus) -> Void = { _ in }
        /// In-flight set changed (lane started or finished a run).
        var fetchingChanged: () -> Void = {}
        /// Elapsed time of a completed run (facade logs >2s providers).
        var recordTiming: (String, TimeInterval) -> Void = { _, _ in }
    }

    private(set) var provider: QuotaProvider
    private let hooks: Hooks
    private let env: ProviderScheduler.Environment

    // Scheduling state (was QuotaService dictionaries).
    private(set) var lastFetchedAt: Date?
    private(set) var adaptiveFailureCount = 0
    private var errorSurfaceGate = ConsecutiveFailureGate()
    private(set) var contextGeneration: UInt = 0
    /// Transient-failure banner state (was `QuotaService.staleWarnings[id]`);
    /// facade reads via `staleWarning(for:)`.
    private(set) var staleWarning: StaleQuotaWarning?
    /// Last published (post-merge) status — the lane's single source for
    /// last-good preservation and enrichment merge base.
    private(set) var currentStatus: ProviderStatus?

    // In-flight bookkeeping.
    private(set) var inFlight: Task<Void, Never>?
    /// Set when a forced request lands on an in-flight fetch; consumed by the
    /// kick task tail which re-runs unless the fetch already succeeded in the
    /// current generation.
    private(set) var pendingForceFollowUp = false
    private var phase: Phase = .idle
    private var emissionIndex = 0
    private var coreEmittedError = false
    private var coreSucceeded = false
    /// Generation + wall time of the last successful core emission — the
    /// facade's repeat-pass filter needs both (a queued force is satisfied
    /// only by a success that landed during the pass it was queued in).
    private(set) var succeededGeneration: UInt?
    private(set) var lastSucceededAt: Date?
    private var armedCoreBudget: TimeInterval = 0
    private var deadlineTask: Task<Void, Never>?

    private enum Phase { case idle, core, extras, done }

    init(provider: QuotaProvider, hooks: Hooks, env: ProviderScheduler.Environment) {
        self.provider = provider
        self.hooks = hooks
        self.env = env
    }

    var isFetching: Bool { inFlight != nil }
    var id: String { provider.id }

    // MARK: - Kick (single-flight entry)

    /// Start a fetch. If one is already in flight the caller joins the same
    /// task; a forced request on an in-flight fetch queues a user-initiated
    /// follow-up that runs only when the current fetch did NOT succeed in the
    /// current context generation (matches the old `pendingForceProviderIDs`
    /// repeat-pass filter).
    @discardableResult
    func kick(force: Bool, interaction: ProviderInteraction) -> Task<Void, Never> {
        if let inFlight {
            if force { pendingForceFollowUp = true }
            return inFlight
        }
        if force {
            // Manual refresh resets the failure streak before the pass starts
            // (was `adaptiveFailureCounts.removeValue` per forced id).
            adaptiveFailureCount = 0
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(interaction: interaction)
            // Forced follow-up chain inside the same task handle so joiners
            // await the whole sequence (old refreshWaiters semantics). The
            // queued force is satisfied only when the in-flight fetch
            // succeeded in the current context generation.
            while self.pendingForceFollowUp {
                self.pendingForceFollowUp = false
                if self.coreSucceeded,
                   self.succeededGeneration == self.contextGeneration {
                    break
                }
                await self.run(interaction: .userInitiated)
            }
            self.inFlight = nil
            self.hooks.fetchingChanged()
        }
        inFlight = task
        hooks.fetchingChanged()
        return task
    }

    /// Whether the lane should fetch on a background tick (per-provider
    /// override `refreshInterval.<id>` × adaptive backoff on failures).
    func isDue(now: Date, globalInterval: TimeInterval) -> Bool {
        let effective = effectiveInterval(globalInterval: globalInterval)
        guard effective > 0 else { return true }
        guard let last = lastFetchedAt else { return true }
        return now.timeIntervalSince(last) >= effective
    }

    func effectiveInterval(globalInterval: TimeInterval) -> TimeInterval {
        let override = UserDefaults.standard.double(
            forKey: "refreshInterval.\(provider.id)")
        let base = override > 0 ? override : globalInterval
        return QuotaService.adaptiveInterval(
            base: base, consecutiveFailures: adaptiveFailureCount)
    }

    /// Same-id provider-instance swap (`setProviders` replacement). Bumps the
    /// context generation so the OLD instance's in-flight emissions are
    /// dropped — the lane equivalent of the task-group `ObjectIdentifier`
    /// check — while cadence and last-good state carry over to the new
    /// instance, matching the pre-lane dictionary behavior.
    func replaceProvider(_ newProvider: QuotaProvider) {
        contextGeneration &+= 1
        provider = newProvider
    }

    /// Account/config invalidation: bump the generation so in-flight results
    /// are dropped, and clear every piece of per-provider state so last-good
    /// data never crosses identities.
    func invalidateContext() {
        contextGeneration &+= 1
        lastFetchedAt = nil
        adaptiveFailureCount = 0
        errorSurfaceGate = ConsecutiveFailureGate()
        succeededGeneration = nil
        lastSucceededAt = nil
        staleWarning = nil
        currentStatus = nil
        pendingForceFollowUp = false
        hooks.invalidateCleanup(id)
    }

    /// Adopt a status published outside the fetch path (self-test result,
    /// cached account snapshot, provider removal). Clears the stale warning —
    /// matching the old call sites that removed it unconditionally. An
    /// explicit `fetchedAt` seeds the cadence clock (self-test, cache restore).
    func adopt(_ status: ProviderStatus?, fetchedAt: Date? = nil) {
        currentStatus = status
        if let fetchedAt { lastFetchedAt = fetchedAt }
        staleWarning = nil
    }

    /// A successful self-test re-arms the one free pass a background
    /// `notConfigured` flake gets (was `errorSurfaceGates[id].recordSuccess()`).
    func recordSurfaceGateSuccess() {
        errorSurfaceGate.recordSuccess()
    }

    /// A completed in-flight fetch cleared by its own defer already; this only
    /// tears down a still-running one (provider removal / service stop).
    func cancel() {
        pendingForceFollowUp = false
        deadlineTask?.cancel()
        inFlight?.cancel()
        inFlight = nil
        phase = .idle
        hooks.fetchingChanged()
    }

    // MARK: - Run

    private func run(interaction: ProviderInteraction) async {
        let gen = contextGeneration
        emissionIndex = 0
        coreEmittedError = false
        coreSucceeded = false
        phase = .core
        let startedAt = env.now()
        let coreBudget = coreBudget(for: interaction)
        armedCoreBudget = coreBudget
        armDeadline(coreBudget, generation: gen)

        let stream = provider.statuses(interaction: interaction)
        await ProviderInteractionContext.$current.withValue(interaction) {
            for await status in stream {
                if Task.isCancelled || phase == .done { break }
                handleEmission(status, generation: gen)
            }
        }
        deadlineTask?.cancel()
        if phase == .core, emissionIndex == 0 {
            // Stream finished without a single emission — a buggy provider
            // must still produce a bounded outcome.
            handleEmission(ProviderStatus(
                id: provider.id, displayName: provider.displayName,
                windows: [], lastUpdated: env.now(),
                error: "Provider produced no status"), generation: gen)
        }
        phase = .done
        hooks.recordTiming(provider.id, env.now().timeIntervalSince(startedAt))
    }

    private func coreBudget(for interaction: ProviderInteraction) -> TimeInterval {
        env.coreDeadlineOverride
            ?? ProviderFetchPhaseBudgets.coreSeconds(for: interaction)
    }

    private func extrasBudget() -> TimeInterval {
        env.extrasDeadlineOverride ?? ProviderFetchPhaseBudgets.extrasSeconds
    }

    // MARK: - Emissions

    private func handleEmission(_ status: ProviderStatus, generation gen: UInt) {
        guard phase != .done, gen == contextGeneration else { return }
        defer { emissionIndex += 1 }
        guard ProviderStatusEmissionPolicy.isPublishable(
            emissionIndex: emissionIndex, status: status) else {
            return
        }
        if emissionIndex == 0 {
            handleCore(status)
            coreEmittedError = status.error != nil
            phase = .extras
            armDeadline(extrasBudget(), generation: gen)
        } else {
            // Extras after an error core are meaningless — the contract says
            // providers end the stream on error; drop defensively.
            guard !coreEmittedError else { return }
            guard let base = currentStatus else {
                publish(status)
                return
            }
            publish(base.withEnrichment(from: status))
        }
    }

    /// Merge pipeline for the core emission — direct port of the old
    /// `runRefreshPass` per-completion block (`QuotaService.swift` ~760-811).
    private func handleCore(_ status: ProviderStatus) {
        // Failure-episode + adaptive backoff read the AWAITED status, never
        // the preserved snapshot that may stay on screen.
        hooks.evaluateFailure(provider.id, status.displayName, status.error)
        recordAdaptiveOutcome(error: status.error)
        if status.error == nil {
            coreSucceeded = true
            succeededGeneration = contextGeneration
            lastSucceededAt = env.now()
        }
        lastFetchedAt = env.now()

        let previous = currentStatus
        let hadPriorData = previous?.isRenderableSnapshot == true
        let suppressedAsFirstFlake: Bool
        if status.error == nil {
            errorSurfaceGate.recordSuccess()
            suppressedAsFirstFlake = false
        } else if classify(rawError: status.error) == .notConfigured {
            suppressedAsFirstFlake = !errorSurfaceGate
                .shouldSurfaceError(onFailureWithPriorData: hadPriorData)
        } else {
            suppressedAsFirstFlake = false
        }
        if status.error != nil, let previous, previous.isRenderableSnapshot,
           isTransientForLastGood(rawError: status.error) || suppressedAsFirstFlake {
            staleWarning = StaleQuotaWarning(
                kind: classify(rawError: status.error) ?? .unknown,
                lastGoodUpdated: previous.lastUpdated)
            // Previous snapshot stays published — no publish call.
        } else {
            staleWarning = nil
            publish(QuotaService.preservingLastGoodServiceStatus(
                status, previous: previous))
        }
        if status.error == nil, status.isRenderableSnapshot {
            hooks.saveAccountSnapshot(status)
        }
        hooks.warningsChanged()
    }

    private func publish(_ status: ProviderStatus) {
        currentStatus = status
        hooks.publish(status)
    }

    private func recordAdaptiveOutcome(error: String?) {
        if let error, !error.isEmpty {
            adaptiveFailureCount += 1
        } else {
            adaptiveFailureCount = 0
        }
    }

    // MARK: - Deadline

    private func armDeadline(_ seconds: TimeInterval, generation gen: UInt) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.env.sleep(UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.onDeadline(generation: gen)
        }
    }

    private func onDeadline(generation gen: UInt) {
        guard gen == contextGeneration, phase != .done else { return }
        let wasCore = phase == .core
        phase = .done
        if wasCore {
            // Same message shape as fetchWithDeadline's timeout status so
            // `classify` resolves `.networkUnreachableOrTimeout`.
            handleCore(ProviderStatus(
                id: provider.id, displayName: provider.displayName,
                windows: [], lastUpdated: env.now(),
                error: "Timeout: provider did not respond within "
                    + "\(Int(armedCoreBudget))s"))
        }
        inFlight?.cancel()   // ends the for-await in run(); its defer cleans up
    }
}

/// Owns one `ProviderLane` per provider id. Replaces the monolithic refresh
/// pass: ticks kick only due lanes, explicit refreshes kick the target lanes,
/// and every lane settles independently — one slow provider never delays
/// another card.
@MainActor
final class ProviderScheduler {
    /// Injectable clock/sleep + deadline overrides for deterministic tests.
    struct Environment {
        var now: () -> Date = Date.init
        /// Sleep in nanoseconds; default real sleep. Tests inject a shorter
        /// or gated sleep to control deadlines.
        var sleep: @Sendable (UInt64) async -> Void = {
            try? await Task.sleep(nanoseconds: $0)
        }
        var coreDeadlineOverride: TimeInterval?
        var extrasDeadlineOverride: TimeInterval?

        init(now: @escaping () -> Date = Date.init,
             sleep: @escaping @Sendable (UInt64) async -> Void = {
                 try? await Task.sleep(nanoseconds: $0)
             },
             coreDeadlineOverride: TimeInterval? = nil,
             extrasDeadlineOverride: TimeInterval? = nil) {
            self.now = now
            self.sleep = sleep
            self.coreDeadlineOverride = coreDeadlineOverride
            self.extrasDeadlineOverride = extrasDeadlineOverride
        }
    }

    private let env: Environment
    private let hooks: ProviderLane.Hooks
    /// Lane order mirrors the providers array (statuses publish order).
    private(set) var providerOrder: [String] = []
    private(set) var lanes: [String: ProviderLane] = [:]

    /// Fires once after every batch (tick or refresh) when all kicked lanes
    /// settle — including zero-due batches, which fire immediately
    /// (preserves the old every-pass WeeklyDigest hook). Awaited so the
    /// caller's refresh completes after the digest like the old pass did.
    var onBatchSettled: (() async -> Void)?

    init(env: Environment = Environment(),
         hooks: ProviderLane.Hooks = ProviderLane.Hooks()) {
        self.env = env
        self.hooks = hooks
    }

    // MARK: - Lane lifecycle

    /// Sync lanes to the provider list: create lanes for new ids, tear down
    /// (and cancel) lanes for removed ones.
    func configure(providers: [QuotaProvider]) {
        let keep = Set(providers.map(\.id))
        for id in lanes.keys where !keep.contains(id) {
            lanes[id]?.cancel()
            lanes.removeValue(forKey: id)
        }
        for p in providers {
            if let lane = lanes[p.id] {
                if ObjectIdentifier(lane.provider) != ObjectIdentifier(p) {
                    lane.replaceProvider(p)
                }
            } else {
                lanes[p.id] = ProviderLane(provider: p, hooks: hooks, env: env)
            }
        }
        providerOrder = providers.map(\.id)
    }

    func lane(for id: String) -> ProviderLane? { lanes[id] }

    var fetchingIDs: Set<String> {
        Set(lanes.values.filter(\.isFetching).map(\.id))
    }

    var isRefreshing: Bool { !fetchingIDs.isEmpty }

    /// Stop everything (service shutdown).
    func cancelAll() {
        for lane in lanes.values { lane.cancel() }
    }

    // MARK: - Batches

    /// Background tick: kick every due lane, await them, then settle the
    /// batch (digest / antigravity hooks fire even when nothing was due).
    func tick(globalInterval: TimeInterval) async {
        let now = env.now()
        let tasks = providerOrder.compactMap { id -> Task<Void, Never>? in
            guard let lane = lanes[id], lane.isDue(now: now, globalInterval: globalInterval)
            else { return nil }
            return lane.kick(force: false, interaction: .background)
        }
        for t in tasks { await t.value }
        await onBatchSettled?()
    }

    /// Full-pass refresh (menu button, settings change, notification).
    /// Forced ids fetch as `.userInitiated` and bypass the due gate; other
    /// providers join only when due — matching the old pass filter.
    func refreshAll(forceProviderIDs: Set<String>, globalInterval: TimeInterval) async {
        let now = env.now()
        var tasks: [Task<Void, Never>] = []
        for id in providerOrder {
            guard let lane = lanes[id] else { continue }
            if forceProviderIDs.contains(id) {
                tasks.append(lane.kick(force: true, interaction: .userInitiated))
            } else if lane.isDue(now: now, globalInterval: globalInterval) {
                tasks.append(lane.kick(force: false, interaction: .background))
            }
        }
        for t in tasks { await t.value }
        await onBatchSettled?()
    }

    /// Targeted refresh for a subset of ids (card-level retry). `force`
    /// bypasses the due gate and marks the run `.userInitiated`.
    func refresh(ids: Set<String>, force: Bool, globalInterval: TimeInterval) async {
        let now = env.now()
        var tasks: [Task<Void, Never>] = []
        for id in providerOrder where ids.contains(id) {
            guard let lane = lanes[id] else { continue }
            if force {
                tasks.append(lane.kick(force: true, interaction: .userInitiated))
            } else if lane.isDue(now: now, globalInterval: globalInterval) {
                tasks.append(lane.kick(force: false, interaction: .background))
            }
        }
        for t in tasks { await t.value }
        await onBatchSettled?()
    }
}
