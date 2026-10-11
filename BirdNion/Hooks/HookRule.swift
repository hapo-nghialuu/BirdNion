import Foundation

/// A user-configured hook: when `event` fires (optionally scoped to `provider`
/// and, for `quotaLow`, gated by `threshold`), run `executable` with `arguments`.
/// Same contract as upstream CodexBar's `HookRule`.
struct HookRule: Codable, Sendable, Equatable, Identifiable {
    static let minimumTimeoutSeconds: Double = 0.1
    static let maximumTimeoutSeconds: Double = 300
    static let maximumIDBytes = 128
    static let maximumArgumentCount = 32
    static let maximumStringBytes = 4096
    static let maximumCommandBytes = 32 * 1024
    static let defaultTimeoutSeconds: Double = 10

    var id: String
    var enabled: Bool
    var event: HookEventType
    /// Provider id (e.g. "codex"). Nil matches any provider.
    var provider: String?
    /// For `quotaLow`: fire only when `usagePercent >= threshold` (0...1).
    /// Ignored for other events.
    var threshold: Double?
    var executable: String
    var arguments: [String]
    var timeoutSeconds: Double

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         event: HookEventType,
         provider: String? = nil,
         threshold: Double? = nil,
         executable: String,
         arguments: [String] = [],
         timeoutSeconds: Double = HookRule.defaultTimeoutSeconds) {
        self.id = id
        self.enabled = enabled
        self.event = event
        self.provider = provider
        self.threshold = threshold
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        event = try container.decode(HookEventType.self, forKey: .event)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? Self.defaultTimeoutSeconds
    }

    /// True when this rule should run for the given event. Requires an
    /// absolute executable path: hooks never resolve via PATH or a shell.
    func matches(_ event: HookEvent) -> Bool {
        guard enabled else { return false }
        guard self.event == event.event else { return false }
        guard hasValidExecutablePath, hasValidTimeout, hasValidCommandShape else { return false }
        guard hasValidThreshold else { return false }
        if let provider, provider != event.provider { return false }
        if self.event == .quotaLow, let threshold {
            guard let usage = event.usagePercent, usage >= threshold else { return false }
        }
        return true
    }

    var hasValidExecutablePath: Bool {
        !executable.isEmpty
            && executable.utf8.count <= Self.maximumStringBytes
            && (executable as NSString).isAbsolutePath
    }

    var hasValidTimeout: Bool {
        timeoutSeconds.isFinite
            && Self.minimumTimeoutSeconds...Self.maximumTimeoutSeconds ~= timeoutSeconds
    }

    var hasValidThreshold: Bool {
        guard let threshold else { return true }
        return threshold.isFinite && threshold > 0 && threshold <= 1
    }

    var hasValidCommandShape: Bool {
        guard !id.isEmpty, id.utf8.count <= Self.maximumIDBytes else { return false }
        guard arguments.count <= Self.maximumArgumentCount else { return false }
        guard arguments.allSatisfy({ $0.utf8.count <= Self.maximumStringBytes }) else { return false }
        return executable.utf8.count + arguments.reduce(0) { $0 + $1.utf8.count }
            <= Self.maximumCommandBytes
    }
}

enum QuotaLowHookThreshold {
    /// Returns the `quota_low` rules whose watched threshold was crossed upward
    /// between `previousUsage` and `currentUsage` (0...1 usage fractions).
    /// A rule without `threshold` falls back to `fallbackThresholds` (the
    /// provider's notification thresholds) so a plain "quota low" hook fires
    /// at the app's warning points.
    static func crossedRules(
        _ rules: [HookRule],
        previousUsage: Double,
        currentUsage: Double,
        fallbackThresholds: [Double]) -> [HookRule] {
        rules.filter { rule in
            let watched = rule.threshold.map { [$0] } ?? fallbackThresholds
            return watched.contains { previousUsage < $0 && currentUsage >= $0 }
        }
    }
}

/// Top-level `hooks` section of `settings.json`. Absent or `enabled == false`
/// means hooks never run.
struct HooksConfig: Codable, Sendable, Equatable {
    static let maximumRuleCount = 32

    var enabled: Bool
    var events: [HookRule]

    init(enabled: Bool = false, events: [HookRule] = []) {
        self.enabled = enabled
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        events = try container.decodeIfPresent([HookRule].self, forKey: .events) ?? []
    }

    /// Enabled rules that match the event. Returns nothing when hooks are off.
    func matchingRules(for event: HookEvent) -> [HookRule] {
        guard enabled, events.count <= Self.maximumRuleCount else { return [] }
        return events.filter { $0.matches(event) }
    }
}
