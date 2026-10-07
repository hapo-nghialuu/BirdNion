import Foundation

/// Quota/provider state changes that can run external commands. Raw values are
/// the stable event names used in config, env vars, and the JSON payload.
/// Ported from CodexBar `HookEventType` (BirdNion has no provider status-page
/// concept, so `provider_unavailable` folds into `refresh_failed`).
enum HookEventType: String, Codable, Sendable, CaseIterable {
    /// A successful provider refresh published a current quota snapshot.
    case usageUpdated = "usage_updated"
    /// Remaining usage crossed a watched threshold downward.
    case quotaLow = "quota_low"
    /// A window hit 0% remaining.
    case quotaReached = "quota_reached"
    /// A window's reset timestamp rolled forward past now.
    case quotaReset = "quota_reset"
    /// A provider fetch failed.
    case refreshFailed = "refresh_failed"
    /// A provider returned to healthy after a failure.
    case providerRecovered = "provider_recovered"

    /// Events that can repeat on every refresh while a condition persists get
    /// the rate-limiter backstop. Quota events dedupe upstream (edge detection
    /// in `HookEngine`) and must not be throttled here, or a lower threshold
    /// crossed within the window would be dropped.
    var isRateLimited: Bool {
        switch self {
        case .usageUpdated, .refreshFailed: true
        case .quotaLow, .quotaReached, .quotaReset, .providerRecovered: false
        }
    }
}

/// One quota/provider event, handed to the hook command via `BIRDNION_*`
/// environment variables and a JSON stdin payload. Carries only non-secret
/// observability data — never tokens, keys, or raw error bodies.
struct HookEvent: Codable, Sendable, Equatable {
    let event: HookEventType
    let provider: String
    let account: String?
    let window: String?
    /// 0...1 usage fraction (0.92 == 92% used) — same convention as upstream.
    let usagePercent: Double?
    let windowMinutes: Int?
    let used: Double?
    let limit: Double?
    let resetAt: Date?
    /// Coarse failure category for `refresh_failed` (never a raw error string).
    let status: String?
    let timestamp: Date

    init(event: HookEventType,
         provider: String,
         account: String? = nil,
         window: String? = nil,
         usagePercent: Double? = nil,
         windowMinutes: Int? = nil,
         used: Double? = nil,
         limit: Double? = nil,
         resetAt: Date? = nil,
         status: String? = nil,
         timestamp: Date = Date()) {
        self.event = event
        self.provider = provider
        self.account = account
        self.window = window
        self.usagePercent = usagePercent
        self.windowMinutes = windowMinutes
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.status = status
        self.timestamp = timestamp
    }

    /// Nil fields are omitted so a script can distinguish "absent" from "zero".
    func environmentVariables() -> [String: String] {
        var env: [String: String] = [
            "BIRDNION_EVENT": event.rawValue,
            "BIRDNION_PROVIDER": provider,
            "BIRDNION_TIMESTAMP": Self.iso8601String(timestamp),
        ]
        if let account { env["BIRDNION_ACCOUNT"] = account }
        if let window { env["BIRDNION_WINDOW"] = window }
        if let usagePercent { env["BIRDNION_USAGE_PERCENT"] = Self.number(usagePercent) }
        if let windowMinutes { env["BIRDNION_WINDOW_MINUTES"] = String(windowMinutes) }
        if let used { env["BIRDNION_USED"] = Self.number(used) }
        if let limit { env["BIRDNION_LIMIT"] = Self.number(limit) }
        if let resetAt { env["BIRDNION_RESET_AT"] = Self.iso8601String(resetAt) }
        if let status { env["BIRDNION_STATUS"] = status }
        return env
    }

    /// The JSON written to the hook command's stdin.
    func jsonPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Trim a trailing ".0" so integers read cleanly, keep fractions intact.
    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
