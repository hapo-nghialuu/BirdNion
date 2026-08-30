import Foundation

enum QuotaAgendaResetState: Equatable {
    case scheduled(Date)
    case awaitingRefresh
    case unknown
    case staleLastKnown
}

enum QuotaAgendaRemaining: Equatable {
    case current(Int)
    case unavailable
    case lastKnown(Int)
}

struct QuotaAgendaMetadata: Equatable {
    enum Account: Equatable {
        case named(String)
        case hidden
        case unknown
    }

    let sourceLabel: String?
    let account: Account
    let observedAt: Date
    let isStale: Bool
}

/// Trust-first projection for the companion Quota Agenda. It only uses explicit
/// reset timestamps; `windowSeconds` is deliberately outside this contract.
struct QuotaAgendaProjection: Equatable, Identifiable {
    let providerID: String
    let providerName: String
    let windowLabel: String
    let remaining: QuotaAgendaRemaining
    let resetState: QuotaAgendaResetState
    let metadata: QuotaAgendaMetadata

    var id: String { providerID }

    static func build(
        statuses: [ProviderStatus],
        staleProviderIDs: Set<String>,
        hidePersonalInfo: Bool,
        now: Date = Date()
    ) -> [QuotaAgendaProjection] {
        let indexed: [(Int, QuotaAgendaProjection)] = statuses.enumerated().compactMap { pair in
            let (index, status) = pair
            guard let window = selectedWindow(for: status) else { return nil }
            let stale = staleProviderIDs.contains(status.id)
            let resetState = resetState(
                window: window,
                observedAt: status.lastUpdated,
                stale: stale,
                now: now)
            let remaining: QuotaAgendaRemaining
            switch resetState {
            case .staleLastKnown:
                remaining = .lastKnown(clampedPercent(window.remainingPct))
            case .awaitingRefresh:
                remaining = .unavailable
            case .scheduled, .unknown:
                remaining = .current(clampedPercent(window.remainingPct))
            }
            return (
                index,
                QuotaAgendaProjection(
                    providerID: status.id,
                    providerName: status.displayName,
                    windowLabel: window.label,
                    remaining: remaining,
                    resetState: resetState,
                    metadata: metadata(
                        for: status,
                        hidePersonalInfo: hidePersonalInfo,
                        stale: stale)))
        }
        return indexed.sorted { lhs, rhs in
            let leftRank = sortRank(lhs.1.resetState)
            let rightRank = sortRank(rhs.1.resetState)
            if leftRank != rightRank { return leftRank < rightRank }
            if case let .scheduled(leftDate) = lhs.1.resetState,
               case let .scheduled(rightDate) = rhs.1.resetState,
               leftDate != rightDate {
                return leftDate < rightDate
            }
            return lhs.0 < rhs.0
        }
        .map(\.1)
    }

    static func metadata(
        for status: ProviderStatus,
        hidePersonalInfo: Bool,
        stale: Bool
    ) -> QuotaAgendaMetadata {
        let source = nonempty(status.sourceLabel)
        let account: QuotaAgendaMetadata.Account
        if let label = nonempty(status.accountLabel) {
            account = hidePersonalInfo ? .hidden : .named(label)
        } else {
            account = .unknown
        }
        return QuotaAgendaMetadata(
            sourceLabel: source,
            account: account,
            observedAt: status.lastUpdated,
            isStale: stale)
    }

    /// Keep the provider summary consistent with the rest of BirdNion: one
    /// provider is represented by its most constrained valid quota window.
    /// Agenda sorts providers by that window's reset; it must not swap in a
    /// healthier window merely because that window resets sooner.
    private static func selectedWindow(for status: ProviderStatus) -> QuotaWindow? {
        let primary = status.windows.enumerated().filter {
            !isAgendaSupplementary($0.element)
                && !$0.element.isInactive
                && !isAgendaExcluded(status: status, window: $0.element)
        }
        return primary.min {
            $0.element.remainingPct == $1.element.remainingPct
                ? $0.offset < $1.offset
                : $0.element.remainingPct < $1.element.remainingPct
        }?.element
    }

    private static func resetState(
        window: QuotaWindow,
        observedAt: Date,
        stale: Bool,
        now: Date
    ) -> QuotaAgendaResetState {
        if stale { return .staleLastKnown }
        guard let reset = window.resetDate else { return .unknown }
        if reset > now { return .scheduled(reset) }
        return observedAt < reset ? .awaitingRefresh : .unknown
    }

    private static func sortRank(_ state: QuotaAgendaResetState) -> Int {
        switch state {
        case .scheduled: 0
        case .awaitingRefresh: 1
        case .unknown: 2
        case .staleLastKnown: 3
        }
    }

    private static func clampedPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    /// Old cached snapshots predate the explicit supplementary flag. Keep the
    /// small canonical label fallback aligned with Linux until caches age out.
    private static func isAgendaSupplementary(_ window: QuotaWindow) -> Bool {
        if window.isSupplementary { return true }
        let label = window.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["số dư", "bonus credits", "daily routines"].contains(label)
    }

    /// Provider metadata and ambiguous 100% placeholders are not observed
    /// allowance. The provider model cannot represent Unknown yet, so Agenda
    /// omits them instead of turning missing denominators into a green claim.
    private static func isAgendaExcluded(status: ProviderStatus, window: QuotaWindow) -> Bool {
        let label = window.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["gia hạn", "chi phí 30 ngày", "vượt hạn mức"].contains(label) { return true }
        if status.id == "kiro",
           label == "credits",
           window.usedPct == 0,
           window.remainingPct == 100,
           nonempty(window.subtitle) == nil,
           window.resetDate == nil {
            return true
        }
        if status.id == "cursor",
           ["plan", "total", "on-demand"].contains(label),
           window.usedPct == 0,
           window.remainingPct == 100,
           !hasPositiveDenominator(window.subtitle) {
            return true
        }
        return false
    }

    private static func hasPositiveDenominator(_ subtitle: String?) -> Bool {
        guard let rhs = subtitle?.split(separator: "/", maxSplits: 1).last,
              subtitle?.contains("/") == true,
              let start = rhs.firstIndex(where: { $0.isNumber }) else { return false }
        let numeric = rhs[start...].prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Double(numeric.replacingOccurrences(of: ",", with: "")) ?? 0 > 0
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
