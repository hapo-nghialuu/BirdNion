import Foundation

struct HapoHubConfig: Codable, Equatable {
    let id: String
    let displayName: String
    let baseURL: String
    let authHeaderTemplate: String
    let jsonPath: String

    /// Real Hapo AI Hub config (verified 2026-06-23 against live endpoint):
    /// `GET /v1/budget/week` with `Authorization: Bearer <key>` returns
    /// `{ usage_percentage, remaining_budget_usd, used_budget_usd,
    ///    weekly_budget_usd, budget_week_ends_at, ... }`.
    /// jsonPath is unused in the real adapter (it has its own typed
    /// decoder) but kept for legacy compatibility with MockHapoHubProvider.
    static let real = HapoHubConfig(
        id: "hapo",
        displayName: "Hapo AI Hub",
        baseURL: "https://<HAPO_BASE_URL>",
        authHeaderTemplate: "Bearer {token}",
        jsonPath: "usage_percentage"
    )

    /// Stand-in config for when the user has not entered a Hapo key
    /// or wants to see the UI without a live request.
    static let mock = HapoHubConfig(
        id: "hapo",
        displayName: "Hapo AI Hub (mock)",
        baseURL: "TODO_BOSS",
        authHeaderTemplate: "Bearer {token}",
        jsonPath: "data.quota.remaining"
    )
}