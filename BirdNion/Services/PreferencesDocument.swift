import Foundation

/// Explicit portable-preferences transfer format (CodexBar `PreferencesDocument`
/// port). The allowlist is deliberate and independent of the defaults search
/// domain: secrets, account identity, local paths and runtime state never
/// leave this Mac.
struct PreferencesDocument: Codable {
    enum Error: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case let .invalid(message): message
            }
        }
    }

    /// A CLI `config import` queues the document here; the running app picks
    /// it up at launch via `consumePendingPreferencesImport`.
    static let pendingImportKey = "portablePreferencesPendingImport"

    var version = 1
    var preferences: [String: PreferenceValue] = [:]
    /// Provider enable flags in display order — entries carry no credentials.
    var providers: [ProviderPreference]? = nil

    struct ProviderPreference: Codable, Equatable {
        var id: String
        var enabled: Bool
    }

    // MARK: - Allowlist

    private static let boolKeys: Set<String> = [
        "launchAtLogin",
        "debugMenuEnabled",
        "statusChecksEnabled",
        "sessionQuotaNotificationsEnabled",
        "providerFailureNotificationsEnabled",
        "quotaWarningNotificationsEnabled",
        "credentialExpiryNotificationsEnabled",
        "stayAwakeEnabled",
        "weeklyDigestEnabled",
        "quotaWarningSoundEnabled",
        "quotaWarningOnScreenAlertEnabled",
        "refreshOnMenuOpen",
        "providerStorageFootprintsEnabled",
        "updateAutoCheckEnabled",
        "hidePersonalInfo",
        "mergeIcons",
        "switcherShowsIcons",
        "showPercentInMenuBar",
        "codexAutoPrimeEnabled",
        "codexOpenAIWebEnabled",
        "codexShowSparkInPopover",
        "claudeShowFableInPopover",
        "debugDisableKeychainAccess",
    ]

    /// Integer keys with a sanity range (min...max).
    private static let intKeys: [String: ClosedRange<Int>] = [
        "quotaWarnLevel1": 1...100,
        "quotaWarnLevel2": 0...100,
        "codexAutoPrimeMinutes": 1...1440,
    ]

    private static let doubleKeys: Set<String> = [
        "refreshIntervalSeconds",
        "monthlyBudgetUSD",
        "claudeBudgetUSD",
        "codexBudgetUSD",
        "grokBudgetUSD",
        "kiroBudgetUSD",
        "ompBudgetUSD",
        "piBudgetUSD",
    ]

    /// Free-form string keys (bounded length; no secrets — cookie headers,
    /// tokens, org ids and local paths are intentionally absent).
    private static let stringKeys: Set<String> = [
        "appLanguage",
        "minimaxRegion",
        "zaiRegion",
        "alibabaRegion",
        "codexMenuBarMetric",
        "codexUsageSource",
        "antigravityUsageSource",
        "antigravityMenuBarMetric",
        "kiloUsageDataSource",
        "kiroMenuBarDisplayMode",
        "menuBarMetricPreferencesJSON",
        "codexCookieSource",
        "claudeUsageDataSource",
        "claudeCookieSource",
        "claudeOAuthKeychainPromptMode",
        PreferredCurrency.defaultsKey,
    ]

    private static let stringChoices: [String: [String]] = [
        "appAppearance": ["auto", "light", "dark"],
        "updateChannel": ["stable", "beta"],
        "birdnion.budgetPeriod": ["week", "month"],
    ]

    private static var keys: Set<String> {
        boolKeys
            .union(intKeys.keys)
            .union(doubleKeys)
            .union(stringKeys)
            .union(stringChoices.keys)
    }

    // MARK: - Codable JSON value

    enum PreferenceValue: Codable, Equatable {
        case bool(Bool)
        case string(String)
        case integer(Int)
        case double(Double)
        case array([PreferenceValue])
        case object([String: PreferenceValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            if let v = try? container.decode(Int.self) { self = .integer(v); return }
            if let v = try? container.decode(Double.self) { self = .double(v); return }
            if let v = try? container.decode(String.self) { self = .string(v); return }
            if let v = try? container.decode([PreferenceValue].self) { self = .array(v); return }
            if let v = try? container.decode([String: PreferenceValue].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported preference value")
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .bool(v): try container.encode(v)
            case let .string(v): try container.encode(v)
            case let .integer(v): try container.encode(v)
            case let .double(v): try container.encode(v)
            case let .array(v): try container.encode(v)
            case let .object(v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }
    }

    // MARK: - Construction / access

    init() {}

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        try self.validate()
    }

    func encoded() throws -> Data {
        try self.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func value<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T? {
        guard let value = preferences[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    mutating func set(_ key: String, _ value: some Encodable) throws {
        preferences[key] = try JSONDecoder().decode(
            PreferenceValue.self, from: JSONEncoder().encode(value))
    }

    // MARK: - Read current defaults

    /// Snapshot every allowlisted key that is currently set. Unset keys are
    /// omitted so import only touches what the file actually carries.
    init(defaults: UserDefaults) throws {
        for key in Self.keys {
            guard let raw = defaults.object(forKey: key) else { continue }
            let data = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
            preferences[key] = try JSONDecoder().decode(PreferenceValue.self, from: data)
        }
        providers = BirdNionConfigStore.allProviders()
            .map { ProviderPreference(id: $0.id, enabled: $0.enabled ?? false) }
        try self.validate()
    }

    // MARK: - Validation

    func validate() throws {
        guard version == 1 else { throw Error.invalid("Unsupported preferences version") }
        for (key, value) in preferences {
            let valid: Bool
            switch value {
            case .bool:
                valid = Self.boolKeys.contains(key)
            case let .integer(number):
                // NSNumber conflation: a Double preference (e.g.
                // refreshIntervalSeconds = 120) round-trips as an integer —
                // accept it under either typed bucket.
                valid = (Self.intKeys[key]?.contains(number) ?? false)
                    || Self.doubleKeys.contains(key) && number >= 0
            case let .double(number):
                valid = Self.doubleKeys.contains(key) && number >= 0
            case let .string(raw):
                if let choices = Self.stringChoices[key] {
                    valid = choices.contains(raw)
                } else {
                    valid = Self.stringKeys.contains(key) && raw.utf8.count <= 4096
                }
            default:
                valid = false
            }
            guard valid else {
                throw Error.invalid("Invalid or non-portable preference: \(key)")
            }
        }
        if let providers {
            guard providers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 }),
                  Set(providers.map(\.id)).count == providers.count else {
                throw Error.invalid("Invalid provider preference list")
            }
        }
    }

    // MARK: - Pending import (queued by a CLI or another process)

    func queueImport(in defaults: UserDefaults) throws {
        try defaults.set(encoded(), forKey: Self.pendingImportKey)
        defaults.synchronize()
    }
}
