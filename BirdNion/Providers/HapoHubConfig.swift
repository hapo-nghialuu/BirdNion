import Foundation

/// Hapo AI Hub adapter config. Endpoint values are supplied outside source
/// control: local dev may use environment variables, while release builds can
/// bake the same values into Info.plist via build-setting substitution. The
/// source tree only carries placeholder keys, not the private hostnames.
///
/// Env vars consumed:
///   - `HAPO_BASE_URL`        — full URL for the weekly budget endpoint
///   - `HAPO_ME_URL`          — full URL for the identity endpoint
///   - `HAPO_AUTH_TEMPLATE`   — `Authorization` header template, must contain
///                              the literal `{token}` placeholder
///
/// Bundle keys consumed when env is absent:
///   - `HapoBaseURL`
///   - `HapoMeURL`
///   - `HapoAuthTemplate`
///
/// If both env and bundle values are missing, the matching URL field is `""`
/// and the provider short-circuits with a clear missing-build-config error.
struct HapoHubConfig: Codable, Equatable {
    let id: String
    let displayName: String
    let baseURL: String
    let meURL: String
    let authHeaderTemplate: String
    let jsonPath: String

    /// Real Hapo AI Hub config. Env values win for local development; bundle
    /// values are used by packaged builds. `jsonPath` is unused by the typed
    /// decoder but kept for legacy compatibility with `MockHapoHubProvider`.
    static let real = HapoHubConfig(
        id: "hapo",
        displayName: "AIHub",
        baseURL: envOrBundle("HAPO_BASE_URL", bundleKey: "HapoBaseURL"),
        meURL: envOrBundle("HAPO_ME_URL", bundleKey: "HapoMeURL"),
        authHeaderTemplate: envOrBundle("HAPO_AUTH_TEMPLATE", bundleKey: "HapoAuthTemplate").isEmpty
            ? "Bearer {token}"
            : envOrBundle("HAPO_AUTH_TEMPLATE", bundleKey: "HapoAuthTemplate"),
        jsonPath: "usage_percentage"
    )

    /// Stand-in config for when the user has not entered a Hapo key
    /// or wants to see the UI without a live request.
    static let mock = HapoHubConfig(
        id: "hapo",
        displayName: "AIHub (mock)",
        baseURL: "TODO_BOSS",
        meURL: "TODO_BOSS",
        authHeaderTemplate: "Bearer {token}",
        jsonPath: "data.quota.remaining"
    )

    private static func envOrBundle(_ envKey: String, bundleKey: String) -> String {
        if let value = cleaned(ProcessInfo.processInfo.environment[envKey]) {
            return value
        }
        return cleaned(Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String) ?? ""
    }

    private static func cleaned(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
