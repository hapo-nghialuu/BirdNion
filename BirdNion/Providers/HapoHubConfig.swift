import Foundation

/// Hapo AI Hub adapter config. All non-trivial endpoints are resolved from
/// environment variables at startup so the source tree doesn't hardcode
/// any hostnames — the rest of the codebase only ever sees `baseURL` /
/// `meURL` strings, not where they came from.
///
/// Env vars consumed:
///   - `HAPO_BASE_URL`        — full URL for the weekly budget endpoint
///   - `HAPO_ME_URL`          — full URL for the identity endpoint
///   - `HAPO_AUTH_TEMPLATE`   — `Authorization` header template, must contain
///                              the literal `{token}` placeholder
///
/// If an env var is missing, the matching URL field is `""` and the
/// provider short-circuits with `"HAPO_BASE_URL chưa được set"` /
/// `"HAPO_ME_URL chưa được set"`. This makes the missing-config state
/// loud and obvious instead of silently contacting the wrong host.
struct HapoHubConfig: Codable, Equatable {
    let id: String
    let displayName: String
    let baseURL: String
    let meURL: String
    let authHeaderTemplate: String
    let jsonPath: String

    /// Real Hapo AI Hub config. Pulled from env vars; no hostnames in
    /// source. `jsonPath` is unused by the typed decoder but kept for
    /// legacy compatibility with `MockHapoHubProvider`.
    static let real = HapoHubConfig(
        id: "hapo",
        displayName: "AIHub",
        baseURL: envOrEmpty("HAPO_BASE_URL"),
        meURL: envOrEmpty("HAPO_ME_URL"),
        authHeaderTemplate: envOrEmpty("HAPO_AUTH_TEMPLATE").isEmpty
            ? "Bearer {token}"
            : envOrEmpty("HAPO_AUTH_TEMPLATE"),
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

    private static func envOrEmpty(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
