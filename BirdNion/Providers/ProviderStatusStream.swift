import Foundation

/// Per-phase fetch budgets consumed by `ProviderScheduler` lanes.
///
/// - `coreSeconds`: bounds time-to-first-emission of `statuses(interaction:)`.
///   Background polls get 60s so a provider's internal fallback chain (e.g.
///   Claude OAuth‖Web → CLI) cannot stall a card for the whole 200s legacy
///   deadline; user-initiated refreshes get the full 120s so manual retries
///   can still run the complete chain.
/// - `extrasSeconds`: bounds the enrichment tail measured from the first
///   emission — a lane stops waiting for extras after this and considers the
///   fetch finished.
enum ProviderFetchPhaseBudgets {
    static func coreSeconds(for interaction: ProviderInteraction) -> TimeInterval {
        interaction == .userInitiated ? 120 : 60
    }

    static let extrasSeconds: TimeInterval = 30
}

/// Validity rules for stream emissions.
///
/// Emission 0 (core) is always publishable — including error statuses.
/// Enrichment emissions (index ≥ 1) are publishable only when `error == nil`:
/// an enrichment failure must never turn a healthy core status into an error.
enum ProviderStatusEmissionPolicy {
    static func isPublishable(emissionIndex: Int, status: ProviderStatus) -> Bool {
        emissionIndex == 0 || status.error == nil
    }
}

extension QuotaProvider {
    /// Default single-emission implementation: wraps `fetch()` so providers
    /// that don't override `statuses(interaction:)` keep working unchanged.
    /// A thrown error maps to an error `ProviderStatus` exactly like
    /// `fetchWithDeadline` does (`error: "\(error)"`).
    func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus> {
        AsyncStream { continuation in
            let task = Task {
                let status: ProviderStatus
                do {
                    status = try await ProviderInteractionContext.$current
                        .withValue(interaction) { try await self.fetch() }
                } catch {
                    status = ProviderStatus(
                        id: self.id, displayName: self.displayName,
                        windows: [], lastUpdated: Date(), error: "\(error)")
                }
                continuation.yield(status)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
