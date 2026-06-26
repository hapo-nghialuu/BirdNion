import Foundation

/// Whether the in-flight quota refresh was user-initiated. `QuotaService` sets
/// this around a manual refresh (the footer Refresh button / account switch) so
/// background-only throttles — like the Codex CLI launch gate — can let an
/// explicit retry through. Background poll cycles leave it `false`.
enum RefreshInteraction {
    @TaskLocal static var isManual: Bool = false
}

/// Throttles local `codex` launches after a failure (e.g. macOS quarantined or
/// moved the binary) so the background poll doesn't respawn it every cycle. A
/// manual refresh bypasses the gate so the user can retry immediately after
/// reinstalling/unblocking `codex`. Native port of CodexBar's
/// `CodexCLILaunchGate` (keyed by binary path, 30-minute cooldown).
final class CodexCLILaunchGate: @unchecked Sendable {
    static let shared = CodexCLILaunchGate()
    static let cooldown: TimeInterval = 30 * 60

    private let lock = NSLock()
    private var expiry: [String: Date] = [:]

    /// True when a *background* launch of `binary` should be skipped because a
    /// recent failure is still within the cooldown. Manual refreshes never skip.
    func shouldSkipLaunch(binary: String,
                          now: Date = Date(),
                          manual: Bool = RefreshInteraction.isManual) -> Bool {
        if manual { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let until = expiry[binary] else { return false }
        if until > now { return true }
        expiry.removeValue(forKey: binary)  // expired → forget
        return false
    }

    /// Record a launch failure → pause background launches for the cooldown.
    func recordFailure(binary: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        expiry[binary] = now.addingTimeInterval(Self.cooldown)
    }

    /// Clear the throttle after a successful launch.
    func clearFailure(binary: String) {
        lock.lock()
        defer { lock.unlock() }
        expiry.removeValue(forKey: binary)
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        expiry.removeAll()
    }
}
