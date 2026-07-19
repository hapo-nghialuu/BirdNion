import SwiftUI

/// The final setup step selects which coding CLI will consume this upstream.
/// A target change is handled by the parent pane because it may open a linked
/// profile with a different model schema and config-file writer.
struct AICodingAgentSelectionCard: View {
    let selectedAgent: AICodingAgent
    let profileID: String
    let lang: String
    var header: String? = nil
    let onSelect: (AICodingAgent) -> Void

    var body: some View {
        SettingsCard(header: header ?? L10n.t("aiCoding.step.agent", lang)) {
            HStack(spacing: 12) {
                Text(L10n.t("aiCoding.target", lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                    .frame(width: 110, alignment: .leading)

                Picker("", selection: selection) {
                    ForEach(AICodingAgent.allCases) { agent in
                        Text(agent.title(language: lang)).tag(agent)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // AppKit caches segmented selections across profile changes.
                .id(profileID)
                .frame(maxWidth: 360, alignment: .trailing)
                .accessibilityLabel(L10n.t("aiCoding.target", lang))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var selection: Binding<AICodingAgent> {
        Binding(
            get: { selectedAgent },
            set: { next in
                guard next != selectedAgent else { return }
                onSelect(next)
            }
        )
    }
}

struct CodexProfileActivationCard: View {
    let profile: BirdNionConfigStore.CodexProfile
    let active: Bool
    let current: Bool
    let lang: String
    let busy: Bool
    var header: String? = nil
    let onApply: () -> Void
    let onDeactivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsCard(header: header ?? L10n.t("codexConfig.target", lang)) {
            HStack(spacing: 12) {
                Image(systemName: active && current ? "checkmark.circle.fill" : "command")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(active && current ? SettingsTheme.success : SettingsTheme.accent)
                    .frame(width: 34, height: 34)
                    .background((active && current ? SettingsTheme.success : SettingsTheme.accent).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(L10n.t("codexConfig.target.path", lang))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(SettingsTheme.secondary)
                }

                Spacer(minLength: 10)

                actionButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsRowDivider()

            HStack(spacing: 8) {
                Text(profile.usesEmbeddedCLIProxy
                     ? L10n.t("codexConfig.connection.proxy", lang)
                     : L10n.t("codexConfig.connection.direct", lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsTheme.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .pointingHandCursor(enabled: !busy)
                .help(L10n.t("codexConfig.delete", lang))
                .accessibilityLabel(L10n.t("codexConfig.delete", lang))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if active && current {
            Button(action: onDeactivate) {
                Label(L10n.t("codexConfig.deactivate", lang), systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(SettingsTheme.critical)
            .disabled(busy)
            .pointingHandCursor(enabled: !busy)
        } else {
            Button(action: onApply) {
                Label(active ? L10n.t("codexConfig.update", lang) : L10n.t("codexConfig.apply", lang),
                      systemImage: active ? "arrow.triangle.2.circlepath" : "power")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy || !profile.hasUpstreamConfiguration)
            .pointingHandCursor(enabled: !busy && profile.hasUpstreamConfiguration)
        }
    }

    private var statusTitle: String {
        if active && current { return L10n.t("codexConfig.state.active", lang) }
        if active { return L10n.t("codexConfig.state.stale", lang) }
        if !profile.hasUpstreamConfiguration { return L10n.t("codexConfig.state.setup", lang) }
        return L10n.t("codexConfig.state.ready", lang)
    }
}
