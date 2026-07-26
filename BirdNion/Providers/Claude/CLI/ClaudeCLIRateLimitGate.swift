import Foundation

// Native port of CodexBarCore's ClaudeCLIRateLimitGate.
// Static 429/rate-limit cooldown gate persisted in UserDefaults.
// Internal access — app module only, not a library.

enum ClaudeCLIRateLimitGate {
    private static let blockedUntilKey = "claudeCLIUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5

    static let message = "Claude CLI usage endpoint is rate limited right now. Please try again later."

    /// Gate entry point mirroring CodexBar: background fetches respect the
    /// cooldown, user-initiated fetches bypass it entirely.
    static func blockedUntil(
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date? {
        guard interaction != .userInitiated else { return nil }
        return currentBlockedUntil(now: now)
    }

    /// Returns the date until which background automatic fetches are blocked.
    /// User-initiated fetches bypass the gate entirely.
    static func currentBlockedUntil(now: Date = Date()) -> Date? {
        guard let raw = UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double else {
            return nil
        }
        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
            return nil
        }
        return blockedUntil
    }

    /// Records a rate-limit hit; blocks automatic fetches for 5 minutes.
    static func recordRateLimit(now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(self.defaultCooldown).timeIntervalSince1970,
            forKey: self.blockedUntilKey)
    }

    /// Clears any active cooldown on a successful fetch.
    static func recordSuccess() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
    }

    /// Returns true when the given error represents a rate-limit condition from
    /// the Claude CLI usage endpoint.
    static func isRateLimitError(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return self.isRateLimitMessage(message, allowRawRateLimitToken: true)
        }
        return self.isRateLimitMessage(error.localizedDescription, allowRawRateLimitToken: false)
    }

    private static func isRateLimitMessage(_ message: String, allowRawRateLimitToken: Bool) -> Bool {
        let lower = message.lowercased()
        return lower.contains(Self.message.lowercased())
            || (allowRawRateLimitToken && lower.contains("rate_limit_error"))
            || (lower.contains("claude cli") && lower.contains("usage") && lower.contains("rate limited"))
    }

    #if DEBUG
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
    }
    #endif
}

/// Capability gate: remembers that `claude /usage` on this machine renders NO
/// subscription-quota panel at all (API-key / apiKeyHelper auth instead of a
/// subscription login). That verdict is deterministic — retrying doesn't help —
/// yet each doomed probe chain burns ~90s (PTY attempt + direct fallback +
/// 60s retry) before the auto plan reaches the web source. While the gate is
/// armed the AUTO plan skips the CLI step entirely; an explicit CLI source
/// selection still probes for real, and any successful probe clears the gate.
enum ClaudeCLIQuotaUnsupportedGate {
    private static let blockedUntilKey = "claudeCLIQuotaUnsupportedUntilV1"
    private static let cooldown: TimeInterval = 6 * 60 * 60

    static let message =
        "Claude CLI /usage has no subscription quota panel (API-key auth) — skipping the CLI probe."

    static func blockedUntil(now: Date = Date()) -> Date? {
        guard let raw = UserDefaults.standard.object(forKey: blockedUntilKey) as? Double else {
            return nil
        }
        let until = Date(timeIntervalSince1970: raw)
        guard until > now else {
            UserDefaults.standard.removeObject(forKey: blockedUntilKey)
            return nil
        }
        return until
    }

    static func recordUnsupported(now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(cooldown).timeIntervalSince1970, forKey: blockedUntilKey)
    }

    static func recordSuccess() {
        UserDefaults.standard.removeObject(forKey: blockedUntilKey)
    }

    /// True for the deterministic "usage panel has no quota" parse failure —
    /// the probe rendered /usage fine but there was no "Current session" data.
    static func isQuotaUnsupportedError(_ error: Error) -> Bool {
        guard case let ClaudeStatusProbeError.parseFailed(message) = error else { return false }
        return message.contains("Missing Current session")
    }

    #if DEBUG
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: blockedUntilKey)
    }
    #endif
}
