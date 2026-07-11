import Foundation
import CodexBarCore

/// OpenAI **API Platform** provider (organization Admin spend / legacy credits).
/// Not ChatGPT/Codex subscription limits — those stay on the Codex provider.
///
/// Data sources (CodexBar parity):
/// 1. Admin API: `OPENAI_ADMIN_KEY` or config apiKey → org costs + completions usage
/// 2. Fallback: legacy credit grants for user keys without Admin access
///
/// Optional project scope: `OPENAI_PROJECT_ID` or `Provider.projectID` in settings.
final class OpenAIProvider: QuotaProvider {
    let id = "openai"
    let displayName = "OpenAI"

    private let session: URLSession
    private let historyDays: Int

    init(session: URLSession = .shared, historyDays: Int = 30) {
        self.session = session
        self.historyDays = historyDays
    }

    func fetch() async throws -> ProviderStatus {
        guard let token = Self.resolveToken(), !token.isEmpty else {
            return failure("Chưa cấu hình OpenAI Admin/API key. Dán key hoặc set OPENAI_ADMIN_KEY.")
        }
        let projectID = Self.resolveProjectID()
        let accountOverride = BirdNionConfigStore.accountLabel(provider: id)

        // Preferred path: organization Admin usage/costs.
        do {
            let snap = try await OpenAIAPIUsageFetcher.fetchUsage(
                apiKey: token,
                projectID: projectID,
                historyDays: historyDays)
            return Self.mapUsage(snap, accountLabel: accountOverride, token: token)
        } catch {
            // Project-scoped admin keys must not fall through to legacy balance.
            if projectID != nil {
                return failure(Self.friendly(error))
            }
            // Best-effort legacy credit grants for user API keys.
            do {
                let balance = try await OpenAIAPICreditBalanceFetcher.fetchBalance(apiKey: token)
                return Self.mapBalance(balance, accountLabel: accountOverride, token: token)
            } catch {
                return failure(Self.friendly(error))
            }
        }
    }

    // MARK: - Token / project resolution

    static func resolveToken(
        env: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
            if let t = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        return BirdNionConfigStore.apiKey(provider: "openai")
    }

    static func resolveProjectID(
        env: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let p = env["OPENAI_PROJECT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        let raw = BirdNionConfigStore.provider(id: "openai")?.projectID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    // MARK: - Mapping

    static func mapUsage(
        _ snap: OpenAIAPIUsageSnapshot,
        accountLabel: String?,
        token: String) -> ProviderStatus
    {
        let today = snap.latestDay
        let week = snap.last7Days
        let month = snap.last30Days
        let top = snap.topModels.first?.name

        func spendWindow(label: String, summary: OpenAIAPIUsageSnapshot.Summary) -> QuotaWindow {
            // No hard limit on Admin spend — surface dollars in subtitle.
            QuotaWindow(
                label: label,
                usedPct: 0,
                remainingPct: 100,
                subtitle: String(format: "$%.2f · %@ tokens",
                                 summary.costUSD,
                                 formatTokens(summary.totalTokens)))
        }

        let windows = [
            spendWindow(label: "Hôm nay", summary: today),
            spendWindow(label: "7 ngày", summary: week),
            spendWindow(label: "30 ngày", summary: month),
        ]

        let label = accountLabel
            ?? snap.projectID.map { "proj \($0.prefix(12))" }
            ?? String(token.prefix(8))
        let plan = snap.projectID.map { "Admin · \($0)" } ?? "Admin API"

        return ProviderStatus(
            id: "openai",
            displayName: "OpenAI",
            windows: windows,
            lastUpdated: snap.updatedAt,
            error: nil,
            accountLabel: label,
            planName: plan,
            cost: ProviderCostSnapshot(
                used: month.costUSD,
                limit: 0,
                currencyCode: "USD",
                period: snap.historyWindowPeriodLabel,
                updatedAt: snap.updatedAt),
            sourceLabel: top.map { "top: \($0)" } ?? "admin-api")
    }

    static func mapBalance(
        _ balance: OpenAIAPICreditBalanceSnapshot,
        accountLabel: String?,
        token: String) -> ProviderStatus
    {
        let granted = max(0, balance.totalGranted)
        let used = max(0, balance.totalUsed)
        let available = max(0, balance.totalAvailable)
        let usedPct: Int = {
            guard granted > 0 else { return available > 0 ? 0 : 100 }
            return max(0, min(100, Int((used / granted * 100).rounded())))
        }()
        let window = QuotaWindow(
            label: "Credits",
            usedPct: usedPct,
            remainingPct: 100 - usedPct,
            subtitle: String(format: "$%.2f available / $%.2f granted", available, granted),
            resetDate: balance.nextGrantExpiry)

        return ProviderStatus(
            id: "openai",
            displayName: "OpenAI",
            windows: [window],
            lastUpdated: balance.updatedAt,
            error: nil,
            accountLabel: accountLabel ?? String(token.prefix(8)),
            creditsRemaining: available,
            planName: "API credits",
            cost: ProviderCostSnapshot(
                used: used,
                limit: granted,
                currencyCode: "USD",
                period: "Credit grants",
                resetsAt: balance.nextGrantExpiry,
                updatedAt: balance.updatedAt),
            sourceLabel: "credit-grants")
    }

    /// Unit-test helper without importing CodexBarCore types into the test target.
    static func _mapBalanceForTesting(
        granted: Double, used: Double, available: Double, now: Date = Date()) -> ProviderStatus
    {
        mapBalance(
            OpenAIAPICreditBalanceSnapshot(
                totalGranted: granted,
                totalUsed: used,
                totalAvailable: available,
                nextGrantExpiry: nil,
                updatedAt: now),
            accountLabel: "u",
            token: "sk-test")
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? OpenAIAPIUsageError { return e.localizedDescription }
        if let e = error as? OpenAIAPICreditBalanceError { return e.localizedDescription }
        return error.localizedDescription
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}
