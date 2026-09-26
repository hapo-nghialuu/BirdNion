// No `import Foundation` here — the protocol only references types defined in our own model layer.
// Keeping this file free of Foundation makes the contract trivially testable in isolation.

protocol QuotaProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Legacy single-shot fetch — kept as the minimal conformance surface.
    /// New code should consume `statuses(interaction:)` instead.
    func fetch() async throws -> ProviderStatus

    /// Two-phase status stream. Emission 0 is the *core* quota status
    /// (windows / error / account / plan / source label); emissions ≥ 1 are
    /// enrichment snapshots (version, service status, web extras, …) and must
    /// carry `error == nil` — an enrichment emission with a non-nil error is
    /// invalid and consumers drop it. Every emission is a complete
    /// `ProviderStatus`; the latest publishable emission wins.
    ///
    /// Implementations must observe `Task.isCancelled` between phases and must
    /// set `ProviderInteractionContext.current` to `interaction` around any
    /// work that reads it (the default implementation already does).
    /// The stream must never hang forever: consumers bound
    /// time-to-first-emission and the enrichment tail via
    /// `ProviderFetchPhaseBudgets`.
    func statuses(interaction: ProviderInteraction) -> AsyncStream<ProviderStatus>
}

/// Whether the current fetch was requested by the user (forced refresh, source
/// change in Settings) or by the background polling loop. Mirrors CodexBarCore's
/// `ProviderInteraction` — gates (rate-limit cooldowns, Keychain prompts) only
/// apply to background fetches; a user-initiated refresh always tries for real.
enum ProviderInteraction: Sendable {
    case background
    case userInitiated
}

/// Task-local carrier for the current interaction kind. `QuotaService` sets it
/// around each provider fetch; providers read `ProviderInteractionContext.current`.
enum ProviderInteractionContext {
    @TaskLocal static var current: ProviderInteraction = .background
}
