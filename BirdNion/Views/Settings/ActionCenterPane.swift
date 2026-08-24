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
    /// Sheet đã có header riêng nên pane bỏ tiêu đề để khỏi trùng.
    var showsHeader: Bool = true

    private var issues: [ActionCenterIssue] {
        ActionCenterIssue.current(
            statuses: quota.displayStatuses,
            staleWarning: { quota.staleWarning(for: $0) })
    }

    var body: some View {
        SettingsPage {
            if showsHeader {
                SettingsPaneHeader(
                    title: L10n.t("actionCenter.title", settings.appLanguage),
                    subtitle: L10n.t("actionCenter.subtitle", settings.appLanguage))
            }

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
            .buttonStyle(.instrumentPrimary)
            .pointingHandCursor()
        } else {
            Button(L10n.t("actionCenter.retry", settings.appLanguage)) {
                Task { await quota.refresh(forceProviderIDs: [issue.providerID]) }
            }
            .buttonStyle(.instrumentOutline)
            .pointingHandCursor()
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


/// Action Center dạng sheet: header riêng + nút đóng, bọc quanh pane cũ.
struct ActionCenterSheet: View {
    @EnvironmentObject private var quota: QuotaService
    @EnvironmentObject private var settings: SettingsStore
    @Binding var isPresented: Bool

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("actionCenter.title", settings.appLanguage))
                    .font(.plexSans(15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsTheme.secondary)
                        .frame(width: 26, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                                .stroke(VocabbyTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vi ? "Đóng" : "Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { VocabbyTheme.chromeRule.frame(height: 1) }

            ActionCenterPane(showsHeader: false)
                .environmentObject(quota)
                .environmentObject(settings)
        }
        .frame(width: 620, height: 460)
        .background(SettingsTheme.background)
    }
}


/// Icon Action Center dùng trong header mọi pane Settings: ✓ khi sạch,
/// ⚠ + số khi có việc cần xử lý. Bấm phát notification để SceneRoot mở sheet.
struct ActionCenterIconButton: View {
    @EnvironmentObject private var quota: QuotaService
    @EnvironmentObject private var settings: SettingsStore

    private var count: Int {
        ActionCenterIssue.current(
            statuses: quota.displayStatuses,
            staleWarning: { quota.staleWarning(for: $0) }).count
    }

    var body: some View {
        let vi = L10n.languageCode(settings.appLanguage) == "vi"
        let title = L10n.t("actionCenter.title", settings.appLanguage)
        let has = count > 0
        return Button {
            NotificationCenter.default.post(name: .openActionCenterTab, object: nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: has ? "exclamationmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(has ? SettingsTheme.critical : SettingsTheme.success)
                if has {
                    Text("\(count)")
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(SettingsTheme.critical)
                }
            }
            .frame(height: 26)
            .padding(.horizontal, has ? 8 : 7)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                    .fill(has ? SettingsTheme.criticalSurface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                    .stroke(has ? Color.clear : VocabbyTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(has
              ? (vi ? "\(title): \(count) việc cần xử lý" : "\(title): \(count) open issues")
              : (vi ? "\(title): không có vấn đề" : "\(title): no open issues"))
    }
}
