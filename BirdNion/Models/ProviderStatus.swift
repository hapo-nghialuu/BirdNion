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
    /// True for supplementary/bonus-credit windows (referral bonuses, one-off
    /// signup credits) that are expected to sit at 0% once spent — unlike a
    /// recurring rate-limit window, running out isn't an urgent signal.
    /// `ProviderStatusSummary.lowestWindow` excludes these so an exhausted
    /// bonus doesn't outrank a healthy primary quota as the popover headline
    /// (mirrors `MenuBarIconRenderer.freemodelMenuBarPercents`, which already
    /// keeps FreeModel's balance window out of the menu-bar percent for the
    /// same reason).
    let isSupplementary: Bool

    init(id: UUID = UUID(),
         label: String,
         usedPct: Int,
         remainingPct: Int,
         subtitle: String? = nil,
         resetDate: Date? = nil,
         windowSeconds: Int? = nil,
         isSupplementary: Bool = false) {
        self.id = id
        self.label = label
        self.usedPct = usedPct
        self.remainingPct = remainingPct
        self.subtitle = subtitle
        self.resetDate = resetDate
        self.windowSeconds = windowSeconds
        self.isSupplementary = isSupplementary
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPct, remainingPct, subtitle, resetDate, windowSeconds, isSupplementary
    }

    /// Custom decode so cached snapshots written before this field existed
    /// (`CodexAccountSnapshotStore`'s on-disk JSON) still decode — a missing
    /// key defaults to `false` instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        usedPct = try c.decode(Int.self, forKey: .usedPct)
        remainingPct = try c.decode(Int.self, forKey: .remainingPct)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        resetDate = try c.decodeIfPresent(Date.self, forKey: .resetDate)
        windowSeconds = try c.decodeIfPresent(Int.self, forKey: .windowSeconds)
        isSupplementary = try c.decodeIfPresent(Bool.self, forKey: .isSupplementary) ?? false
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
    /// True when credits are unlimited (Codex CLI RPC reports this); the UI then
    /// shows "∞" instead of a number. Defaults false.
    let creditsUnlimited: Bool
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
    /// Number of unused manual-reset credits (Codex). nil when the provider
    /// doesn't support it or the API didn't return data.
    let resetCreditsAvailable: Int?
    /// Token cost + spend summary scraped from the provider's web dashboard
    /// (e.g. Claude's claude.ai/settings/billing). nil when the provider
    /// doesn't expose this or the scrape failed. Surfaced in the Usage
    /// section as "Today: $X · NM tokens" + "Last 30 days: ..." lines.
    let cost: ProviderCostSnapshot?
    /// Bag of Claude web-API extras (account identity from cookies + quota
    /// fallback percentages). Carries everything that comes from
    /// `ClaudeWebAPIFetcher.fetchUsage()` but does NOT belong on the OAuth
    /// row — surfaced by `ClaudeProvider` so the panel can render account
    /// info (email / org / login method) and fall back to cookie-derived
    /// quota when OAuth fails. Other providers leave it nil.
    /// Mirrors CodexBar's `ClaudeUsageSnapshot` minus the quota windows
    /// (which we keep in `windows` for layout consistency across providers).
    let webExtras: ClaudeWebExtras?
    /// Which data source actually produced this status — e.g. "OAuth" / "CLI"
    /// for Codex. Surfaced in the providers panel so the user can see which
    /// path the source selector resolved to. nil for providers that don't
    /// expose a selectable source.
    let sourceLabel: String?
    /// Optional OpenAI web-dashboard extras for Codex (code-review remaining,
    /// credits, purchase URL) — populated only when the user enables OpenAI web
    /// extras. nil otherwise.
    let codexWeb: CodexWebExtras?
    /// Claude Admin-API org usage dashboard (30-day cost/token/per-model
    /// breakdown). Populated only when the Claude source is `.api`. The popover
    /// renders it as a chart card. nil for every other provider/source.
    let claudeAdminUsage: ClaudeAdminAPIUsageSnapshot?
    /// Structured Kiro credits/overage for the menu-bar display-mode picker
    /// (credits left / percent / used÷total / overage). nil for non-Kiro.
    let kiroMenu: KiroMenuUsage?

    init(id: String,
         displayName: String,
         windows: [QuotaWindow],
         lastUpdated: Date,
         error: String? = nil,
         accountLabel: String? = nil,
         planType: String? = nil,
         creditsRemaining: Double? = nil,
         creditsUnlimited: Bool = false,
         version: String? = nil,
         serviceStatus: String? = nil,
         serviceStatusLevel: String? = nil,
         accountID: String? = nil,
         planName: String? = nil,
         resetCreditsAvailable: Int? = nil,
         cost: ProviderCostSnapshot? = nil,
         webExtras: ClaudeWebExtras? = nil,
         sourceLabel: String? = nil,
         codexWeb: CodexWebExtras? = nil,
         claudeAdminUsage: ClaudeAdminAPIUsageSnapshot? = nil,
         kiroMenu: KiroMenuUsage? = nil) {
        self.id = id
        self.displayName = displayName
        self.windows = windows
        self.lastUpdated = lastUpdated
        self.error = error
        self.accountLabel = accountLabel
        self.planType = planType
        self.creditsRemaining = creditsRemaining
        self.creditsUnlimited = creditsUnlimited
        self.version = version
        self.serviceStatus = serviceStatus
        self.serviceStatusLevel = serviceStatusLevel
        self.accountID = accountID
        self.planName = planName
        self.resetCreditsAvailable = resetCreditsAvailable
        self.cost = cost
        self.webExtras = webExtras
        self.sourceLabel = sourceLabel
        self.codexWeb = codexWeb
        self.claudeAdminUsage = claudeAdminUsage
        self.kiroMenu = kiroMenu
    }
}

/// Structured Kiro usage consumed by the menu-bar display-mode picker and the
/// Settings info grid. All optional so a partial parse still yields what it
/// found. Mirrors CodexBar's `KiroUsageDetails` (+ flattened context usage).
struct KiroMenuUsage: Codable, Equatable, Sendable {
    /// Credits remaining (plan credits left).
    let creditsRemaining: Double?
    /// Credits used this period.
    let creditsUsed: Double?
    /// Total plan credits this period.
    let creditsTotal: Double?
    /// Primary window's remaining percent (drives the percent modes).
    let primaryRemainingPct: Int?
    /// Pay-as-you-go overage credits used beyond the plan (when exhausted).
    let overageCreditsUsed: Double?
    /// Pay-as-you-go overage cost in USD (when exhausted).
    let overageCostUSD: Double?
    /// Raw "Overages: …" status line from /usage (e.g. "Enabled" / "Disabled").
    let overagesStatus: String?
    /// Context-window usage from `/context` — total percent used.
    let contextPercentUsed: Double?
    /// Per-category context percents (context files / tools / responses / prompts).
    let contextFilesPercent: Double?
    let contextToolsPercent: Double?
    let contextResponsesPercent: Double?
    let contextPromptsPercent: Double?

    init(creditsRemaining: Double? = nil,
         creditsUsed: Double? = nil,
         creditsTotal: Double? = nil,
         primaryRemainingPct: Int? = nil,
         overageCreditsUsed: Double? = nil,
         overageCostUSD: Double? = nil,
         overagesStatus: String? = nil,
         contextPercentUsed: Double? = nil,
         contextFilesPercent: Double? = nil,
         contextToolsPercent: Double? = nil,
         contextResponsesPercent: Double? = nil,
         contextPromptsPercent: Double? = nil) {
        self.creditsRemaining = creditsRemaining
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.primaryRemainingPct = primaryRemainingPct
        self.overageCreditsUsed = overageCreditsUsed
        self.overageCostUSD = overageCostUSD
        self.overagesStatus = overagesStatus
        self.contextPercentUsed = contextPercentUsed
        self.contextFilesPercent = contextFilesPercent
        self.contextToolsPercent = contextToolsPercent
        self.contextResponsesPercent = contextResponsesPercent
        self.contextPromptsPercent = contextPromptsPercent
    }
}

/// OpenAI web-dashboard extras for Codex, scraped from chatgpt.com when the user
/// enables "OpenAI web extras". Mirrors the dashboard-only fields CodexBar
/// surfaces. All optional — a partial scrape still yields what it found.
struct CodexWebExtras: Codable, Equatable, Sendable {
    /// Email the dashboard reports as signed in (for account matching).
    let signedInEmail: String?
    /// Code-review quota remaining, as a percentage (0...100).
    let codeReviewRemainingPercent: Int?
    /// Credit balance from the dashboard (fallback when OAuth/CLI don't carry it).
    let creditsRemaining: Double?
    /// Best-effort URL to the credits purchase page.
    let creditsPurchaseURL: String?
    /// Number of credit-usage history rows the dashboard returned.
    let creditsHistoryCount: Int?

    init(signedInEmail: String? = nil,
         codeReviewRemainingPercent: Int? = nil,
         creditsRemaining: Double? = nil,
         creditsPurchaseURL: String? = nil,
         creditsHistoryCount: Int? = nil) {
        self.signedInEmail = signedInEmail
        self.codeReviewRemainingPercent = codeReviewRemainingPercent
        self.creditsRemaining = creditsRemaining
        self.creditsPurchaseURL = creditsPurchaseURL
        self.creditsHistoryCount = creditsHistoryCount
    }
}

/// All non-quota-window extras that come from Claude's web/CLI sources,
/// collected together so `ProviderStatus` doesn't grow 9 new fields. Each
/// member is independently optional — `ClaudeWebAPIFetcher` may return
/// partial data if some endpoints fail (e.g. account endpoint down).
/// Matches CodexBar's `ClaudeUsageSnapshot` minus the windows.
struct ClaudeWebExtras: Codable, Equatable, Sendable {
    /// Account email from `claude.ai/api/account`. May differ from the OAuth
    /// accountLabel when the user logged in via web but not via `claude login`.
    let accountEmail: String?
    /// Organization name from claude.ai (e.g. "Personal" / company name).
    let accountOrganization: String?
    /// Login method label (e.g. "Claude account" / "SSO" / "Admin API").
    let loginMethod: String?
    /// Session (5h) utilization as a percentage. Backup for `windows[0]` when
    /// OAuth is unavailable.
    let sessionPercentUsed: Double?
    /// Weekly utilization as a percentage. Backup for `windows[1]`.
    let weeklyPercentUsed: Double?
    /// Opus-specific weekly utilization. Backup for `windows[2]`.
    let opusPercentUsed: Double?
    /// Named rate windows (Daily Routines, etc.) from web/CLI sources.
    /// Each carries its own `RateWindow` plus a `title` for display.
    let extraRateWindows: [ClaudeExtraRateWindow]
    /// Identifier of the source that actually produced this data — "oauth",
    /// "web", "cli", "api", or "auto:<strategy>". Used by the Settings UI to
    /// show the user "Last fetch via: <source>" so they know the planner
    /// picked for them.
    let sourceLabel: String?

    init(accountEmail: String? = nil,
         accountOrganization: String? = nil,
         loginMethod: String? = nil,
         sessionPercentUsed: Double? = nil,
         weeklyPercentUsed: Double? = nil,
         opusPercentUsed: Double? = nil,
         extraRateWindows: [ClaudeExtraRateWindow] = [],
         sourceLabel: String? = nil) {
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.sessionPercentUsed = sessionPercentUsed
        self.weeklyPercentUsed = weeklyPercentUsed
        self.opusPercentUsed = opusPercentUsed
        self.extraRateWindows = extraRateWindows
        self.sourceLabel = sourceLabel
    }
}

/// One named rate window surfaced as a separate row in the Claude panel
/// (e.g. "Daily Routines"). Mirrors CodexBarCore's `NamedRateWindow` but
/// copies the small subset BirdNion needs so the UI doesn't have to depend
/// on CodexBarCore's concrete type.
struct ClaudeExtraRateWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetsAt: Date?
    /// Reset description as parsed from the source (e.g. "Resets 4am").
    let resetDescription: String?
    let windowMinutes: Int?

    init(id: String,
         title: String,
         usedPercent: Int,
         resetsAt: Date? = nil,
         resetDescription: String? = nil,
         windowMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.windowMinutes = windowMinutes
    }
}
