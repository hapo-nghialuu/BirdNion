import Foundation

/// One quota window (e.g. "5 giờ" or "Tuần") reported by a provider.
/// Matches the `<!-- contract:QuotaWindow -->` block in `specs/ai-statusbar/design.md`.
///
/// `subtitle` and `resetDate` are optional overlays used by providers that
/// carry richer context (e.g. Hapo Hub's "$16.19 / $20.00" dollar amount and
/// ISO-8601 weekly reset timestamp). MiniMax leaves them nil and the UI
/// falls back to the plain "Còn X%" + "Resets in 5h"/"Resets weekly" text.
struct QuotaWindow: Identifiable, Codable, Equatable {
    let id: UUID
    let label: String
    let usedPct: Int
    let remainingPct: Int
    let subtitle: String?
    let resetDate: Date?
    /// Full window length in seconds (e.g. 18000 for 5h, 604800 for a week).
    /// Used with `resetDate` to compute consumption pace. nil when unknown.
    let windowSeconds: Int?

    init(id: UUID = UUID(),
         label: String,
         usedPct: Int,
         remainingPct: Int,
         subtitle: String? = nil,
         resetDate: Date? = nil,
         windowSeconds: Int? = nil) {
        self.id = id
        self.label = label
        self.usedPct = usedPct
        self.remainingPct = remainingPct
        self.subtitle = subtitle
        self.resetDate = resetDate
        self.windowSeconds = windowSeconds
    }
}

/// Linear consumption pace for one window — derived purely from its current
/// usage, reset time, and total length. "Reserve" is how far below the steady
/// (linear) burn rate you are; "lasts until reset" projects the current rate to
/// the window end. No history needed, so it works from the first sample.
struct WindowPace: Equatable {
    /// Percentage points you're under the linear pace (>= 0).
    let reservePct: Int
    /// Whether the current burn rate leaves budget until the window resets.
    let lastsUntilReset: Bool
    /// Human countdown to reset, e.g. "20h 46m" / "2d 3h". nil if unknown.
    let resetText: String?

    init?(window: QuotaWindow, now: Date = Date()) {
        guard let reset = window.resetDate, let seconds = window.windowSeconds, seconds > 0 else {
            return nil
        }
        let duration = Double(seconds)
        let timeUntilReset = max(0, reset.timeIntervalSince(now))
        let elapsed = min(duration, max(0, duration - timeUntilReset))
        let actualUsed = Double(max(0, min(100, window.usedPct)))

        if elapsed <= 0 {
            self.reservePct = 0
            self.lastsUntilReset = true
        } else {
            let expectedUsed = elapsed / duration * 100
            self.reservePct = max(0, Int((expectedUsed - actualUsed).rounded()))
            // Project usage to the reset moment at the current burn rate.
            let projectedAtReset = actualUsed * (duration / elapsed)
            self.lastsUntilReset = projectedAtReset <= 100
        }
        self.resetText = Self.format(timeUntilReset)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Snapshot of one provider's quota state at a point in time.
/// Matches the `<!-- contract:ProviderStatus -->` block in `specs/ai-statusbar/design.md`.
///
/// Invariant: if `error != nil`, then `windows.isEmpty` MUST be true.
///            if `windows` is non-empty, `error` MUST be nil.
struct ProviderStatus: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let windows: [QuotaWindow]
    let lastUpdated: Date
    let error: String?
    /// User-facing identifier for this account. Strategy:
    /// 1. If user explicitly set one in Settings (ProviderConfig.accountLabel),
    ///    use that.
    /// 2. Otherwise derive from the keychain token's first 8 chars
    ///    (e.g. "sk-cp-dEwaSdME") so the chip has *something* identifying.
    /// nil only if no token is configured.
    let accountLabel: String?

    // MARK: - Optional provider detail overlays
    //
    // Enrichments surfaced in the providers detail panel. Codex populates them;
    // other providers leave them nil. All optional + defaulted so old cached
    // snapshots (without these keys) still decode.

    /// Subscription plan, e.g. "plus" / "pro" (Codex `plan_type`).
    let planType: String?
    /// Remaining credit balance (Codex `credits.balance`). nil when absent.
    let creditsRemaining: Double?
    /// Detected CLI version string, e.g. "codex-cli 0.140.0-alpha.19".
    let version: String?
    /// Provider service-status text, e.g. "All Systems Operational".
    let serviceStatus: String?
    /// Status severity: "none" / "minor" / "major" / "critical" (drives color).
    let serviceStatusLevel: String?
    /// OpenAI `account_id` from `~/.codex/auth.json`. Sent in the
    /// `ChatGPT-Account-Id` header for the Codex usage + reset-credits APIs.
    /// nil for providers that don't have an account_id.
    let accountID: String?
    /// Plan display name for MiniMax (e.g. "Token Plan Max") — distinct from
    /// `planType` which carries a code (`plus` / `pro`). Surfaced in header.
    let planName: String?

    init(id: String,
         displayName: String,
         windows: [QuotaWindow],
         lastUpdated: Date,
         error: String? = nil,
         accountLabel: String? = nil,
         planType: String? = nil,
         creditsRemaining: Double? = nil,
         version: String? = nil,
         serviceStatus: String? = nil,
         serviceStatusLevel: String? = nil,
         accountID: String? = nil,
         planName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.windows = windows
        self.lastUpdated = lastUpdated
        self.error = error
        self.accountLabel = accountLabel
        self.planType = planType
        self.creditsRemaining = creditsRemaining
        self.version = version
        self.serviceStatus = serviceStatus
        self.serviceStatusLevel = serviceStatusLevel
        self.accountID = accountID
        self.planName = planName
    }
}
