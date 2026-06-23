import Foundation

/// Stand-in for HapoHubProvider when real endpoint is unknown (config.baseURL == "TODO_BOSS").
///
/// Mock mirrors the real adapter shape: a single "Tuần" window with a
/// subtitle + resetDate, since /v1/budget/week only reports weekly quota.
/// The mock values are static; real data comes from HapoHubProvider.
final class MockHapoHubProvider: QuotaProvider {
    let id = "hapo"
    let displayName = "Hapo AI Hub"

    func fetch() async throws -> ProviderStatus {
        let now = Date()
        let weeklyReset = now.addingTimeInterval(7 * 24 * 3600)
        return ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [
                QuotaWindow(label: "Tuần",
                            usedPct: 20,
                            remainingPct: 80,
                            subtitle: "$16.00 / $20.00",
                            resetDate: weeklyReset)
            ],
            lastUpdated: now,
            error: nil
        )
    }
}