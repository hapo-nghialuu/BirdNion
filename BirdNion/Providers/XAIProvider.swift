import Foundation

/// xAI Platform billing provider.
///
/// Uses the Management API, not Grok's consumer quota/session path. The API
/// exposes prepaid money balance and recent dollar spend, so no reset-based
/// quota windows are inferred.
final class XAIProvider: QuotaProvider {
    let id = "xai"
    let displayName = "xAI"

    private let env: [String: String]
    private let configURL: URL

    init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL = BirdNionConfigStore.configURL())
    {
        self.env = env
        self.configURL = configURL
    }

    func fetch() async throws -> ProviderStatus {
        guard let apiKey = Self.resolveToken(env: env, configURL: configURL) else {
            return failure("xAI Management API key is not configured. Set XAI_MANAGEMENT_API_KEY or add an API key in Settings.")
        }
        guard let teamID = Self.resolveTeamID(env: env, configURL: configURL) else {
            return failure("xAI team ID is not configured. Set XAI_TEAM_ID or enter it in Settings.")
        }
        guard XAIBillingFetcher.validTeamID(teamID) else {
            return failure("xAI team ID is invalid. Check XAI_TEAM_ID or the Team ID in Settings.")
        }

        do {
            let fetcher = try XAIBillingFetcher(apiKey: apiKey, teamID: teamID)
            let snapshot = try await fetcher.fetch(historyDays: 30)
            return Self.map(snapshot, teamID: teamID, accountLabel: Self.accountLabel(configURL: configURL))
        } catch {
            return failure(Self.friendly(error))
        }
    }

    // MARK: - Resolution

    static func resolveToken(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL = BirdNionConfigStore.configURL()) -> String?
    {
        if let value = cleaned(env["XAI_MANAGEMENT_API_KEY"]) { return value }
        return BirdNionConfigStore.apiKey(provider: "xai", url: configURL)
    }

    static func resolveTeamID(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL = BirdNionConfigStore.configURL()) -> String?
    {
        if let value = cleaned(env["XAI_TEAM_ID"]) { return value }
        return cleaned(BirdNionConfigStore.provider(id: "xai", url: configURL)?.region)
    }

    // MARK: - Mapping

    static func map(
        _ snapshot: XAIUsageSnapshot,
        teamID: String,
        accountLabel: String? = nil,
        now: Date = Date()) -> ProviderStatus
    {
        let balance = snapshot.balanceUSD
        let balanceText = String(format: "$%.2f USD", balance)
        let balanceWindow = QuotaWindow(
            label: "Balance",
            usedPct: 0,
            remainingPct: 100,
            subtitle: balanceText)
        let spend = snapshot.daily.reduce(0) { $0 + $1.usd }
        let period = snapshot.limitReached ? "Last 30 days (partial)" : "Last 30 days"

        return ProviderStatus(
            id: "xai",
            displayName: "xAI",
            windows: [balanceWindow],
            lastUpdated: now,
            error: nil,
            accountLabel: accountLabel ?? teamID,
            creditsRemaining: balance,
            planName: "xAI Platform",
            cost: ProviderCostSnapshot(
                used: spend,
                limit: 0,
                currencyCode: "USD",
                period: period,
                updatedAt: now),
            sourceLabel: "api")
    }

    /// Mapping seam for unit tests; avoids network access and config reads.
    static func _mapForTesting(
        balanceUSD: Double,
        dailyUSD: [Double],
        limitReached: Bool = false,
        teamID: String = "team-test",
        accountLabel: String? = nil,
        now: Date = Date()) -> ProviderStatus
    {
        let daily = dailyUSD.enumerated().map { index, amount in
            XAIDailyUsage(day: now.addingTimeInterval(TimeInterval(index * 86_400)), usd: amount)
        }
        return map(
            XAIUsageSnapshot(balanceUSD: balanceUSD, daily: daily, limitReached: limitReached),
            teamID: teamID,
            accountLabel: accountLabel,
            now: now)
    }

    // MARK: - Errors

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: displayName,
            windows: [],
            lastUpdated: Date(),
            error: message,
            accountLabel: Self.accountLabel(configURL: configURL))
    }

    private static func friendly(_ error: Error) -> String {
        switch error as? XAIBillingError {
        case .missingCredentials:
            return "xAI Management API key is missing. Set XAI_MANAGEMENT_API_KEY or add an API key in Settings."
        case .invalidTeamID:
            return "xAI team ID is invalid. Check XAI_TEAM_ID or the Team ID in Settings."
        case .invalidBaseURL:
            return "xAI billing endpoint is invalid."
        case .authenticationRejected:
            return "xAI rejected the Management API key (HTTP 401/403). Check the key and team access."
        case .teamNotFound:
            return "xAI team was not found (HTTP 404). Check the Team ID."
        case .rateLimited:
            return "xAI rate limited the billing request (HTTP 429). Try again later."
        case let .apiError(status):
            return status > 0
                ? "xAI billing returned HTTP \(status)."
                : "xAI billing returned a non-HTTP response."
        case .parseError:
            return "xAI billing returned an invalid response."
        case nil:
            let text = error.localizedDescription
            return text.isEmpty ? "Could not fetch xAI billing data." : "Could not fetch xAI billing data: \(text)"
        }
    }

    private static func accountLabel(configURL: URL) -> String? {
        cleaned(BirdNionConfigStore.accountLabel(provider: "xai", url: configURL))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
