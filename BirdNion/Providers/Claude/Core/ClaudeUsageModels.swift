import Foundation

// Native Claude usage models — the BirdNion-owned replacements for the
// CodexBarCore types the Claude provider used to import. Everything here is
// pure Foundation so the Claude path can be fully detached from CodexBarCore
// (the vendored package stays only for Codex). Shapes mirror CodexBar so the
// ported fetchers/parsers translate 1:1.

// MARK: - Rate windows

/// One usage window (e.g. 5h session, weekly, opus) as a percent-used figure
/// plus reset metadata. Mirrors CodexBarCore's `RateWindow`.
struct RateWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    /// Optional textual reset description (used by the CLI UI scrape).
    let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers
    /// with rolling recovery.
    let nextRegenPercent: Double?

    init(usedPercent: Double,
         windowMinutes: Int?,
         resetsAt: Date?,
         resetDescription: String?,
         nextRegenPercent: Double? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// When a fresh window lacks a reset time, borrow it from a cached window
    /// that still points to the future. Mirrors CodexBar so cookie/CLI scrapes
    /// keep showing a reset countdown across partial fetches.
    func backfillingResetTime(from cached: RateWindow?, now: Date = Date()) -> RateWindow {
        if resetsAt != nil { return self }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let minutes = (windowMinutes.map { $0 > 0 ? $0 : nil } ?? nil) ?? cached?.windowMinutes
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: cachedReset,
            resetDescription: resetDescription ?? cached?.resetDescription,
            nextRegenPercent: nextRegenPercent)
    }
}

/// A named rate window surfaced as its own row (e.g. "Daily Routines").
/// Mirrors CodexBarCore's `NamedRateWindow`, including the `usageKnown` flag
/// that distinguishes "reset metadata only" windows from real usage.
struct NamedRateWindow: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let window: RateWindow
    /// Whether `window.usedPercent` reflects known quota usage. Older cached
    /// payloads without the key decode as `true`.
    let usageKnown: Bool

    init(id: String, title: String, window: RateWindow, usageKnown: Bool = true) {
        self.id = id
        self.title = title
        self.window = window
        self.usageKnown = usageKnown
    }

    private enum CodingKeys: String, CodingKey { case id, title, window, usageKnown }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        window = try c.decode(RateWindow.self, forKey: .window)
        usageKnown = try c.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(window, forKey: .window)
        if !usageKnown { try c.encode(false, forKey: .usageKnown) }
    }
}

// MARK: - Usage snapshot

/// One Claude usage reading from any native source (OAuth / Web / CLI / Admin),
/// before it's materialized into the app-facing `ProviderStatus`. Mirrors
/// CodexBarCore's `ClaudeUsageSnapshot` so the ported fetchers map 1:1.
struct ClaudeUsageSnapshot: Sendable {
    enum PrimaryWindowKind: Equatable, Sendable {
        case usage
        case spendLimit
    }

    /// nil only for the Admin (`.api`) source, which has no quota windows —
    /// just the cost/token org dashboard in `adminUsage`.
    let primary: RateWindow?
    let primaryWindowKind: PrimaryWindowKind
    let secondary: RateWindow?
    let opus: RateWindow?
    let extraRateWindows: [NamedRateWindow]
    let providerCost: ProviderCostSnapshot?
    let updatedAt: Date
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
    let rawText: String?
    /// Admin-API org dashboard (only the `.api` source fills this; the popover
    /// renders it as a 30-day breakdown).
    let adminUsage: ClaudeAdminAPIUsageSnapshot?

    init(primary: RateWindow?,
         primaryWindowKind: PrimaryWindowKind = .usage,
         secondary: RateWindow?,
         opus: RateWindow?,
         extraRateWindows: [NamedRateWindow] = [],
         providerCost: ProviderCostSnapshot? = nil,
         updatedAt: Date = Date(),
         accountEmail: String? = nil,
         accountOrganization: String? = nil,
         loginMethod: String? = nil,
         rawText: String? = nil,
         adminUsage: ClaudeAdminAPIUsageSnapshot? = nil) {
        self.primary = primary
        self.primaryWindowKind = primaryWindowKind
        self.secondary = secondary
        self.opus = opus
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.updatedAt = updatedAt
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.rawText = rawText
        self.adminUsage = adminUsage
    }
}

/// Anthropic public service status (status.anthropic.com). Native replacement
/// for CodexBarCore's `OpenAIServiceStatus` on the Claude path.
struct ClaudeServiceStatus: Sendable {
    let indicator: String   // none / minor / major / critical / unknown
    let description: String
}

// MARK: - Source / cookie / prompt enums

/// Which data source the Claude provider should use. Mirrors CodexBarCore's
/// `ClaudeUsageDataSource`. Persisted as the UserDefaults `claudeUsageDataSource`
/// string; default `.oauth` matches BirdNion's pre-parity behavior.
enum ClaudeUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case api
    case oauth
    case web
    case cli

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .api: "API (Admin key)"
        case .oauth: "OAuth API"
        case .web: "Web API (cookies)"
        case .cli: "CLI (PTY)"
        }
    }

    /// Short identifier surfaced to the UI as "Source: <label>".
    var sourceLabel: String { rawValue }
}

/// How the web fetcher should obtain claude.ai cookies. Mirrors CodexBarCore's
/// `ProviderCookieSource` for the Claude path (Codex still uses the CodexBarCore
/// type in its own web-extras controls).
enum ClaudeCookieSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case manual
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .manual: "Manual"
        case .off: "Off"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .off: false
        case .auto, .manual: true
        }
    }
}

/// How aggressively the OAuth Keychain reader may prompt. Mirrors CodexBarCore's
/// `ClaudeOAuthKeychainPromptMode`.
enum ClaudeOAuthKeychainPromptMode: String, CaseIterable, Sendable, Codable {
    case never
    case onlyOnUserAction
    case always
}

/// Reads the user's Keychain-prompt preference from UserDefaults. Simplified
/// from CodexBar (no read-strategy matrix — BirdNion always uses the Security
/// framework reader). Default `.never` so background/manual OAuth never pops
/// the macOS Keychain dialog; CLI/Web cover signed-in Claude Code users.
enum ClaudeOAuthKeychainPromptPreference {
    static let userDefaultsKey = "claudeOAuthKeychainPromptMode"

    static func current(userDefaults: UserDefaults = .standard) -> ClaudeOAuthKeychainPromptMode {
        guard let raw = userDefaults.string(forKey: userDefaultsKey),
              let mode = ClaudeOAuthKeychainPromptMode(rawValue: raw)
        else { return .never }
        return mode
    }
}

// MARK: - Plan labeling

/// Maps Anthropic subscription/tier hints to a human plan label ("Max" / "Pro"
/// / etc.) and derives login-method labels for the web/OAuth paths. Mirrors the
/// subset of CodexBar's `ClaudePlan` the BirdNion UI needs.
enum ClaudePlanLabeler {
    /// Exact label from the Keychain blob's subscriptionType + rateLimitTier.
    static func label(subscriptionType sub: String?, rateLimitTier tier: String?) -> String? {
        if let s = sub?.lowercased() {
            if s.contains("max") {
                if let multiplier = maxUsageMultiplier(rateLimitTier: tier) {
                    return "Max \(multiplier)"
                }
                return "Max"
            }
            if s.contains("ultra") { return "Ultra" }
            if s.contains("pro") { return "Pro" }
            if s.contains("team") { return "Team" }
            if s.contains("enterprise") { return "Enterprise" }
        }
        if let t = tier?.lowercased() {
            if let multiplier = maxUsageMultiplier(rateLimitTier: t) { return "Max \(multiplier)" }
            if t.contains("max") { return "Max" }
            if t.contains("ultra") { return "Ultra" }
        }
        return nil
    }

    private static func maxUsageMultiplier(rateLimitTier tier: String?) -> String? {
        let normalized = tier?.lowercased() ?? ""
        if normalized.contains("default_claude_max_5x") { return "5x" }
        if normalized.contains("default_claude_max_20x") { return "20x" }
        return nil
    }

    static func label(fromLoginMethod method: String?) -> String? {
        guard let m = method?.lowercased(), !m.isEmpty else { return nil }
        if m.contains("max") { return "Max" }
        if m.contains("ultra") { return "Ultra" }
        if m.contains("pro") { return "Pro" }
        if m.contains("team") { return "Team" }
        if m.contains("enterprise") { return "Enterprise" }
        return nil
    }

    /// Login-method label for the OAuth path (Keychain-derived).
    static func oauthLoginMethod(subscriptionType sub: String?, rateLimitTier tier: String? = nil) -> String {
        if let plan = label(subscriptionType: sub, rateLimitTier: tier) { return "Claude \(plan)" }
        return "Claude account"
    }

    /// Login-method label for the web path (cookie-derived).
    static func webLoginMethod(organization: String?) -> String {
        if let org = organization, !org.isEmpty, org.lowercased() != "personal" { return org }
        return "Claude account"
    }
}

// MARK: - Errors

/// Errors surfaced by the native Claude fetchers. Mirrors CodexBarCore's
/// `ClaudeUsageError`.
enum ClaudeUsageError: LocalizedError, Sendable {
    case claudeNotInstalled
    case parseFailed(String)
    case oauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            "Chưa cài Claude CLI — cài từ https://code.claude.com/docs"
        case let .parseFailed(details):
            "Không phân tích được dữ liệu Claude: \(details)"
        case let .oauthFailed(details):
            details
        }
    }
}
