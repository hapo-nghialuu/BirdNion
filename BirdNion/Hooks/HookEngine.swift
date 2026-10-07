import Foundation

/// Detects quota/provider transitions on each published `ProviderStatus` and
/// dispatches matching user hook commands. Same event set and edge semantics
/// as upstream `HookTransitionDetector`, scoped to what BirdNion observes:
/// per-window threshold crossings, depletion, reset rollovers, refresh
/// failure/recovery, and post-fetch updates.
///
/// `@MainActor` because it runs inside `QuotaService.mergePublished`.
@MainActor
final class HookEngine {
    struct LaneState {
        var lastUsedPct: Int?
        var lastResetAt: Date?
        var hadError = false
    }

    private var lanes: [String: [String: LaneState]] = [:]
    private let rateLimiter = HookRateLimiter()
    private let configProvider: () -> HooksConfig?
    private let warnThresholds: (String, String) -> [Int]

    /// Test seam: invoked with every emitted event before dispatch, so edge
    /// detection is verifiable without spawning hook processes.
    var onEmit: ((HookEvent) -> Void)?

    init(configProvider: @escaping () -> HooksConfig? = { BirdNionConfigStore.hooks() },
         warnThresholds: @escaping (String, String) -> [Int] = { provider, window in
             QuotaWarnConfig.thresholds(provider: provider, window: window)
         }) {
        self.configProvider = configProvider
        self.warnThresholds = warnThresholds
    }

    func reset(provider id: String) {
        lanes.removeValue(forKey: id)
    }

    /// Called once per published status (success or failure). Fire-and-forget:
    /// rule execution happens on a detached task and never blocks refresh.
    func observe(_ status: ProviderStatus, now: Date = Date()) {
        guard let config = configProvider(), config.enabled else { return }
        guard config.events.count <= HooksConfig.maximumRuleCount else { return }

        var lanesForProvider = lanes[status.id] ?? [:]

        if status.error != nil {
            var state = lanesForProvider[""] ?? LaneState()
            let wasHealthy = !state.hadError
            state.hadError = true
            lanesForProvider[""] = state
            lanes[status.id] = lanesForProvider
            if wasHealthy {
                emit(.refreshFailed, config: config, provider: status.id,
                     account: status.accountLabel,
                     status: "fetch_error")
            }
            return
        }

        var providerState = lanesForProvider[""] ?? LaneState()
        if providerState.hadError {
            providerState.hadError = false
            emit(.providerRecovered, config: config, provider: status.id,
                 account: status.accountLabel)
        }
        lanesForProvider[""] = providerState

        // usage_updated carries the primary window's headline numbers.
        let primary = status.windows.first
        emit(.usageUpdated, config: config, provider: status.id,
             account: status.accountLabel,
             window: primary?.label,
             usagePercent: primary.map { Double($0.usedPct) / 100 },
             windowMinutes: primary?.windowSeconds.map { $0 / 60 },
             used: primary?.allowance?.used,
             limit: primary?.allowance?.limit,
             resetAt: primary?.resetDate)

        for window in status.windows {
            let key = QuotaWarnConfig.windowKey(window.label)
            var state = lanesForProvider[key] ?? LaneState()
            let usedPct = window.usedPct
            let usage = Double(usedPct) / 100
            let previousUsage = state.lastUsedPct.map { Double($0) / 100 }

            // quota_low: downward-remaining == upward-usage crossing.
            if let previousUsage, previousUsage < usage {
                let candidates = config.events.filter {
                    $0.enabled && $0.event == .quotaLow
                        && ($0.provider == nil || $0.provider == status.id)
                }
                let fallback = warnThresholds(status.id, key)
                    .map { 1.0 - Double($0) / 100 }
                let crossed = QuotaLowHookThreshold.crossedRules(
                    candidates, previousUsage: previousUsage,
                    currentUsage: usage, fallbackThresholds: fallback)
                if !crossed.isEmpty {
                    emit(.quotaLow, config: HooksConfig(enabled: true, events: crossed),
                         provider: status.id, account: status.accountLabel,
                         window: window.label, usagePercent: usage,
                         windowMinutes: window.windowSeconds.map { $0 / 60 },
                         used: window.allowance?.used, limit: window.allowance?.limit,
                         resetAt: window.resetDate)
                }
            }

            // quota_reached: depletion edge (previous above 0% remaining, now 0).
            if let previousUsage, previousUsage < 1, usage >= 1 {
                emit(.quotaReached, config: config, provider: status.id,
                     account: status.accountLabel,
                     window: window.label, usagePercent: usage,
                     windowMinutes: window.windowSeconds.map { $0 / 60 },
                     used: window.allowance?.used, limit: window.allowance?.limit,
                     resetAt: window.resetDate)
            }

            // quota_reset: previous reset instant passed and a new one took over.
            if let prevReset = state.lastResetAt, let newReset = window.resetDate,
               newReset > prevReset, prevReset <= now {
                emit(.quotaReset, config: config, provider: status.id,
                     account: status.accountLabel,
                     window: window.label, usagePercent: usage,
                     windowMinutes: window.windowSeconds.map { $0 / 60 },
                     resetAt: newReset)
            }

            state.lastUsedPct = usedPct
            state.lastResetAt = window.resetDate ?? state.lastResetAt
            lanesForProvider[key] = state
        }

        lanes[status.id] = lanesForProvider
    }

    private func emit(_ type: HookEventType,
                      config: HooksConfig,
                      provider: String,
                      account: String? = nil,
                      window: String? = nil,
                      usagePercent: Double? = nil,
                      windowMinutes: Int? = nil,
                      used: Double? = nil,
                      limit: Double? = nil,
                      resetAt: Date? = nil,
                      status: String? = nil) {
        let event = HookEvent(
            event: type, provider: provider, account: account, window: window,
            usagePercent: usagePercent, windowMinutes: windowMinutes,
            used: used, limit: limit, resetAt: resetAt,
            status: status, timestamp: Date())
        onEmit?(event)
        let limiter = rateLimiter
        Task.detached(priority: .utility) {
            await HookRunner.dispatch(
                event: event, config: config, rateLimiter: limiter)
        }
    }
}
