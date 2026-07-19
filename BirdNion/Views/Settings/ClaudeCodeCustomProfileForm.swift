import SwiftUI

/// Editable form for a user-defined Claude Code backend (custom profile).
/// Pure presentational: binds to a working `ClaudeCodeProfile` copy; the parent
/// pane owns persistence and the power toggle.
struct ClaudeCodeCustomProfileForm: View {
    @Binding var profile: BirdNionConfigStore.ClaudeCodeProfile
    let lang: String
    var includesConnectionFields: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if includesConnectionFields {
                ClaudeCodeCustomProfileConnectionFields(profile: $profile, lang: lang)
            }

            SettingsCard(header: L10n.t("claudeCode.model", lang)) {
                fieldRow(L10n.t("claudeCode.model.haiku", lang)) {
                    TextField(L10n.t("ccx.model.optional", lang), text: modelBinding(\.haikuModel))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                }
                SettingsRowDivider()
                fieldRow(L10n.t("claudeCode.model.sonnet", lang)) {
                    TextField(L10n.t("ccx.model.optional", lang), text: modelBinding(\.sonnetModel))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                }
                SettingsRowDivider()
                fieldRow(L10n.t("claudeCode.model.opus", lang)) {
                    TextField(L10n.t("ccx.model.optional", lang), text: modelBinding(\.opusModel))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                }
            }

            SettingsCard(header: L10n.t("ccx.advanced", lang)) {
                if !profile.usesEmbeddedCLIProxy {
                    fieldRow("apiKeyHelper") {
                        TextField(L10n.t("ccx.apiKeyHelper.placeholder", lang),
                                  text: optionalBinding(\.apiKeyHelper))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                    }
                    SettingsRowDivider()
                }
                extraEnvEditor
            }
        }
    }

    // MARK: - Extra env editor

    private var extraEnvEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("ccx.extraEnv", lang))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            ForEach(pairs) { pair in
                HStack(spacing: 6) {
                    TextField("KEY", text: keyBinding(pair.id))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11).monospaced())
                    Text("=").foregroundStyle(SettingsTheme.tertiary)
                    TextField("value", text: valueBinding(pair.id))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11).monospaced())
                    Button { removePair(pair.id) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(SettingsTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            Button { addPair() } label: {
                Label(L10n.t("ccx.extraEnv.add", lang), systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsTheme.accent)
            .pointingHandCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder _ trailing: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
                .frame(width: 110, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Binding for an optional model field (empty string ⇄ nil).
    private func modelBinding(_ keyPath: WritableKeyPath<BirdNionConfigStore.ClaudeCodeProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
    private func optionalBinding(_ keyPath: WritableKeyPath<BirdNionConfigStore.ClaudeCodeProfile, String?>) -> Binding<String> {
        modelBinding(keyPath)
    }

    private var pairs: [BirdNionConfigStore.ClaudeCodeEnvPair] { profile.extraEnv ?? [] }

    private func setPairs(_ p: [BirdNionConfigStore.ClaudeCodeEnvPair]) {
        profile.extraEnv = p.isEmpty ? nil : p
    }
    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { pairs.first { $0.id == id }?.key ?? "" },
            set: { v in var p = pairs; if let i = p.firstIndex(where: { $0.id == id }) { p[i].key = v; setPairs(p) } }
        )
    }
    private func valueBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { pairs.first { $0.id == id }?.value ?? "" },
            set: { v in var p = pairs; if let i = p.firstIndex(where: { $0.id == id }) { p[i].value = v; setPairs(p) } }
        )
    }
    private func addPair() {
        var p = pairs
        p.append(.init(id: UUID().uuidString, key: "", value: ""))
        setPairs(p)
    }
    private func removePair(_ id: String) {
        setPairs(pairs.filter { $0.id != id })
    }
}
