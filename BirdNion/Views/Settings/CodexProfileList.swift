import SwiftUI

struct CodexProfileList: View {
    let profiles: [BirdNionConfigStore.CodexProfile]
    @Binding var selectedID: String?
    let activeProfileID: String?
    let currentProfileID: String?
    let proxyRuntimeState: LocalProxyRuntimeState
    let lang: String
    let onAdd: () -> Void

    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsSectionHeader(title: L10n.t("codexConfig.custom", lang))
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SettingsTheme.accent)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L10n.t("codexConfig.add", lang))
                .accessibilityLabel(L10n.t("codexConfig.add", lang))
            }

            if profiles.isEmpty {
                Text(L10n.t("codexConfig.add", lang))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        row(profile)
                        if index < profiles.count - 1 { SettingsRowDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1))
            }
        }
        .frame(width: 220, alignment: .top)
    }

    private func row(_ profile: BirdNionConfigStore.CodexProfile) -> some View {
        let selected = profile.id == selectedID
        let configuredForCodex = profile.id == activeProfileID
        let currentForCodex = profile.id == currentProfileID
        let active = currentForCodex && (
            !profile.usesEmbeddedCLIProxy
                || EmbeddedCLIProxyService.isProfileRunning(profile, runtimeState: proxyRuntimeState)
        )
        let hovering = profile.id == hoveredID
        return Button {
            selectedID = profile.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? SettingsTheme.success : (selected ? SettingsTheme.accent : SettingsTheme.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name.isEmpty ? L10n.t("codexConfig.newName", lang) : profile.name)
                        .font(.system(size: 13, weight: selected || active ? .semibold : .regular))
                        .foregroundStyle(SettingsTheme.primary)
                        .lineLimit(1)
                    Text(statusLabel(
                        profile,
                        active: active,
                        configuredForCodex: configuredForCodex,
                        currentForCodex: currentForCodex
                    ))
                        .font(.system(size: 10))
                        .foregroundStyle(active ? SettingsTheme.success : SettingsTheme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: active ? "checkmark.circle.fill" : readinessIcon(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(active ? SettingsTheme.success : readinessColor(profile))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active
                        ? SettingsTheme.success.opacity(selected ? 0.18 : 0.11)
                        : (selected ? SettingsTheme.selectedSurface
                           : (hovering ? SettingsTheme.hoverSurface.opacity(0.62) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { inside in
            if inside { hoveredID = profile.id }
            else if hoveredID == profile.id { hoveredID = nil }
        }
    }

    private func statusLabel(_ profile: BirdNionConfigStore.CodexProfile,
                             active: Bool,
                             configuredForCodex: Bool,
                             currentForCodex: Bool) -> String {
        if active { return L10n.t("codexConfig.state.active", lang) }
        if configuredForCodex && !currentForCodex {
            return L10n.t("codexConfig.state.stale", lang)
        }
        if configuredForCodex && profile.usesEmbeddedCLIProxy {
            return L10n.t("ccx.proxy.status.stopped", lang)
        }
        if !profile.hasUpstreamConfiguration { return L10n.t("codexConfig.state.setup", lang) }
        if profile.usesEmbeddedCLIProxy && !profile.isCLIProxyConfigurationCurrent {
            return L10n.t("codexConfig.state.stale", lang)
        }
        return L10n.t("codexConfig.state.ready", lang)
    }

    private func readinessIcon(_ profile: BirdNionConfigStore.CodexProfile) -> String {
        profile.hasUpstreamConfiguration ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func readinessColor(_ profile: BirdNionConfigStore.CodexProfile) -> Color {
        profile.hasUpstreamConfiguration ? SettingsTheme.success : SettingsTheme.warning
    }
}
