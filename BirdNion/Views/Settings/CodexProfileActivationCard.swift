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
        VStack(alignment: .leading, spacing: 6) {
            Text(header ?? L10n.t("aiCoding.step.agent", lang)).plexEyebrow()
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                Text(L10n.t("aiCoding.target", lang))
                    .font(.plexSans(13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
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
            .hairlineTop()
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

    /// Pure health mapping for `current`: a direct connection is healthy once
    /// applied, but an embedded-proxy connection also needs the loopback
    /// proxy process to actually be alive — otherwise the card would read
    /// "Active" while Codex CLI calls silently fail against a dead proxy.
    static func isCurrentlyHealthy(applied: Bool, usesEmbeddedProxy: Bool, proxyIsRunning: Bool) -> Bool {
        applied && (!usesEmbeddedProxy || proxyIsRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header ?? L10n.t("codexConfig.target", lang)).plexEyebrow()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: active && current ? "checkmark.circle.fill" : "command")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(active && current ? VocabbyTheme.success : VocabbyTheme.blue)
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: InstrumentShape.plateRadius, style: .continuous)
                                .stroke(active && current ? VocabbyTheme.success : VocabbyTheme.blue, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.plexSans(13, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                        Text(L10n.t("codexConfig.target.path", lang))
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }

                    Spacer(minLength: 10)

                    actionButton
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .hairlineTop()

                HStack(spacing: 8) {
                    Text(profile.usesEmbeddedCLIProxy
                         ? L10n.t("codexConfig.connection.proxy", lang)
                         : L10n.t("codexConfig.connection.direct", lang))
                        .font(.plexSans(11, weight: .medium))
                        .foregroundStyle(VocabbyTheme.secondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
                    .controlSize(.small)
                    .disabled(busy)
                    .pointingHandCursor(enabled: !busy)
                    .help(L10n.t("codexConfig.delete", lang))
                    .accessibilityLabel(L10n.t("codexConfig.delete", lang))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .hairlineTop()
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if active && current {
            Button(action: onDeactivate) {
                Label(L10n.t("codexConfig.deactivate", lang), systemImage: "power")
                    .font(.plexMono(11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
            .controlSize(.small)
            .tint(VocabbyTheme.critical)
            .disabled(busy)
            .pointingHandCursor(enabled: !busy)
        } else {
            Button(action: onApply) {
                Label(active ? L10n.t("codexConfig.update", lang) : L10n.t("codexConfig.apply", lang),
                      systemImage: active ? "arrow.triangle.2.circlepath" : "power")
                    .font(.plexMono(11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
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
