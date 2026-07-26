// No `import Foundation` here — the protocol only references types defined in our own model layer.
// Keeping this file free of Foundation makes the contract trivially testable in isolation.

protocol QuotaProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> ProviderStatus
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
