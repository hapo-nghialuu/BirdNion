import SwiftUI

enum ActionCenterIssueKind: Equatable {
    case setup
    case connection
}

struct ActionCenterIssue: Identifiable, Equatable {
    let providerID: String
    let providerName: String
    let kind: ActionCenterIssueKind
    let remediationTarget: ProviderRemediationTarget?

    var id: String { providerID }

    static func current(
        statuses: [ProviderStatus],
        staleWarning: (String) -> StaleQuotaWarning?
    ) -> [ActionCenterIssue] {
        current(
            providers: BirdNionConfigStore.allProviders(),
            statuses: statuses,
            detectionReady: { ProvidersPane.detectOnboardingSource(for: $0).isReady },
            staleWarning: staleWarning)
    }

    static func current(
        providers: [BirdNionConfigStore.Provider],
        statuses: [ProviderStatus],
        detectionReady: (String) -> Bool,
        staleWarning: (String) -> StaleQuotaWarning?
    ) -> [ActionCenterIssue] {
        let supported = Set(["claude", "codex", "grok"])
        return providers.compactMap { provider -> (Int, ActionCenterIssue)? in
            guard provider.enabled == true, supported.contains(provider.id) else { return nil }
            let status = statuses.first { $0.id == provider.id }
            let providerName = status?.displayName ?? provider.displayName ?? provider.id.capitalized
            if let rawError = status?.error, !rawError.isEmpty {
                let errorKind = classify(rawError: rawError) ?? .unknown
                let target = BirdNion.remediationTarget(providerID: provider.id, kind: errorKind)
                let priority: Int
                if errorKind == .notConfigured {
                    priority = 0
                } else if target != nil {
                    priority = 1
                } else if isTransientForLastGood(rawError: rawError) {
                    priority = 2
                } else {
                    return nil
                }
                return (priority, ActionCenterIssue(
                    providerID: provider.id,
                    providerName: providerName,
                    kind: target == nil ? .connection : .setup,
                    remediationTarget: target))
            }
            if staleWarning(provider.id) != nil {
                return (2, ActionCenterIssue(
                    providerID: provider.id,
                    providerName: providerName,
                    kind: .connection,
                    remediationTarget: nil))
            }
            if status?.windows.isEmpty != false, !detectionReady(provider.id) {
                return (0, ActionCenterIssue(
                    providerID: provider.id,
                    providerName: providerName,
                    kind: .setup,
                    remediationTarget: .setupSource))
            }
            return nil
        }
        .sorted { $0.0 < $1.0 }
        .prefix(3)
        .map(\.1)
    }
}

struct ActionCenterPane: View {
    @EnvironmentObject private var quota: QuotaService
    @EnvironmentObject private var settings: SettingsStore

    private var issues: [ActionCenterIssue] {
        ActionCenterIssue.current(
            statuses: quota.displayStatuses,
            staleWarning: { quota.staleWarning(for: $0) })
    }

    var body: some View {
        SettingsPage {
            SettingsPaneHeader(
                title: L10n.t("actionCenter.title", settings.appLanguage),
                subtitle: L10n.t("actionCenter.subtitle", settings.appLanguage))

            if issues.isEmpty {
                emptyState
            } else {
                SettingsCard(header: L10n.t("actionCenter.current", settings.appLanguage)) {
                    ForEach(issues) { issue in
                        SettingsLabeledRow(
                            title: "\(issue.providerName) · \(title(for: issue.kind))",
                            subtitle: hint(for: issue.kind)
                        ) {
                            action(for: issue)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.t("actionCenter.emptyTitle", settings.appLanguage),
                systemImage: "checkmark.circle.fill")
                .font(.plexSans(15, weight: .semibold))
                .foregroundStyle(SettingsTheme.success)
            Text(L10n.t("actionCenter.emptyBody", settings.appLanguage))
                .font(.plexSans(13))
                .foregroundStyle(SettingsTheme.secondary)
        }
        .padding(.top, 22)
    }

    @ViewBuilder
    private func action(for issue: ActionCenterIssue) -> some View {
        if let target = issue.remediationTarget {
            Button(L10n.t("actionCenter.fix", settings.appLanguage)) {
                openProviderSettings(issue.providerID, target: target)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(L10n.t("actionCenter.retry", settings.appLanguage)) {
                Task { await quota.refresh(forceProviderIDs: [issue.providerID]) }
            }
            .buttonStyle(.bordered)
            .disabled(quota.isRefreshing)
        }
    }

    private func title(for kind: ActionCenterIssueKind) -> String {
        switch kind {
        case .setup: L10n.t("actionCenter.setupTitle", settings.appLanguage)
        case .connection: L10n.t("actionCenter.connectionTitle", settings.appLanguage)
        }
    }

    private func hint(for kind: ActionCenterIssueKind) -> String {
        switch kind {
        case .setup: L10n.t("actionCenter.setupHint", settings.appLanguage)
        case .connection: L10n.t("actionCenter.connectionHint", settings.appLanguage)
        }
    }
}
