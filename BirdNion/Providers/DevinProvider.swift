import Foundation
import CodexBarCore

/// Devin (Cognition) quota provider (CodexBar parity).
///
/// Sources:
/// 1. **Auto:** Devin browser session imported from Chrome localStorage via
///    `DevinSessionImporter` — access token + organization metadata that
///    app.devin.ai stores locally. No cookie scan, macOS-only upstream too.
/// 2. **Manual:** Bearer token in Settings (`apiKey`, accepts a bare token or
///    a full `Authorization: Bearer ...` line) + optional Organization
///    (`devinOrganization`) — slug, internal `org-...`/`org_...` ID, or the
///    full `https://app.devin.ai/org/<slug>` URL.
///
/// Endpoint: `GET https://app.devin.ai/api/<org>/billing/quota/usage`
/// → `DevinUsageSnapshot` (daily + weekly percentage windows + plan name).
///
/// Env overrides (CodexBar parity): `DEVIN_BEARER_TOKEN` / `DEVIN_AUTHORIZATION`
/// for the token, `DEVIN_ORGANIZATION` / `DEVIN_ORG` for the organization.
/// Environment values take precedence over Settings, matching xAI's team-ID
/// convention.
final class DevinProvider: QuotaProvider {
    let id = "devin"
    let displayName = "Devin"

    func fetch() async throws -> ProviderStatus {
        let token = Self.resolveToken()
        let organization = Self.resolveOrganization()
        let accountLabel = BirdNionConfigStore.accountLabel(provider: id)

        do {
            let fetcher = DevinUsageFetcher(browserDetection: BrowserDetection())
            let snap = try await fetcher.fetch(
                bearerTokenOverride: token,
                organizationOverride: organization)
            return Self.map(
                snap,
                accountLabel: accountLabel,
                sourceLabel: token != nil ? "manual" : "auto")
        } catch {
            return failure(Self.friendly(error))
        }
    }

    static func resolveToken(
        env: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in ["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"] {
            if let t = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        return BirdNionConfigStore.apiKey(provider: "devin")
    }

    static func resolveOrganization(
        env: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in ["DEVIN_ORGANIZATION", "DEVIN_ORG"] {
            if let t = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        let configured = BirdNionConfigStore.provider(id: "devin")?.devinOrganization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured : nil
    }

    // MARK: - Mapping

    static func map(
        _ snap: DevinUsageSnapshot,
        accountLabel: String?,
        sourceLabel: String?
    ) -> ProviderStatus {
        var windows: [QuotaWindow] = []
        if let daily = snap.daily {
            windows.append(Self.window(
                daily, label: "Ngày", windowSeconds: 24 * 3600))
        }
        if let weekly = snap.weekly {
            windows.append(Self.window(
                weekly, label: "Tuần", windowSeconds: 7 * 24 * 3600))
        }
        if windows.isEmpty {
            return ProviderStatus(
                id: "devin",
                displayName: "Devin",
                windows: [],
                lastUpdated: snap.updatedAt,
                error: "Devin: không có dữ liệu quota",
                accountLabel: accountLabel ?? snap.organization,
                planName: snap.planName)
        }
        return ProviderStatus(
            id: "devin",
            displayName: "Devin",
            windows: windows,
            lastUpdated: snap.updatedAt,
            error: nil,
            accountLabel: accountLabel ?? snap.organization,
            creditsRemaining: snap.overageBalance,
            planName: snap.planName,
            sourceLabel: sourceLabel,
            devinUsage: Self.usageHistory(from: snap))
    }

    private static func usageHistory(from snap: DevinUsageSnapshot) -> DevinUsageHistorySnapshot? {
        guard let history = snap.usageHistory, !history.days.isEmpty else { return nil }
        return DevinUsageHistorySnapshot(
            days: history.days.map { .init(date: $0.date, amount: $0.amount) },
            products: history.products
                .filter { $0.total > 0 }
                .sorted { $0.total > $1.total }
                .map { .init(view: $0.view, total: $0.total) },
            total: history.total,
            cycleEnd: history.cycleEnd)
    }

    /// Unit-test hook: map a snapshot without network I/O.
    static func _mapForTesting(_ snap: DevinUsageSnapshot) -> ProviderStatus {
        map(snap, accountLabel: nil, sourceLabel: "auto")
    }

    private static func window(
        _ quota: DevinQuotaWindow, label: String, windowSeconds: Int
    ) -> QuotaWindow {
        let used = max(0, min(100, Int(quota.usedPercent.rounded())))
        return QuotaWindow(
            label: label,
            usedPct: used,
            remainingPct: 100 - used,
            resetDate: quota.resetsAt,
            windowSeconds: windowSeconds)
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? DevinUsageError {
            switch e {
            case .noSession:
                return "Chưa đăng nhập Devin. Mở app.devin.ai → trang Usage & Limits trong Chrome, hoặc dán Bearer token."
            case .missingOrganization:
                return "Thiếu Devin Organization — nhập slug hoặc org-... ID, hoặc mở trang Usage & Limits của org đó trong Chrome."
            case .invalidCredentials:
                return "Devin session/token không hợp lệ hoặc đã hết hạn."
            case let .apiError(message):
                return "Lỗi API Devin: \(message)"
            case let .parseFailed(message):
                return "Không parse được Devin usage: \(message)"
            }
        }
        return error.localizedDescription
    }

    private func failure(_ message: String) -> ProviderStatus {
        ProviderStatus(id: id, displayName: displayName, windows: [], lastUpdated: Date(), error: message)
    }
}
