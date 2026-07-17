import SwiftUI

/// Connection fields are isolated from the profile form so both protocol modes
/// stay compact and the credentials' destinations remain visually distinct.
struct ClaudeCodeCustomProfileConnectionFields: View {
    @Binding var profile: BirdNionConfigStore.ClaudeCodeProfile
    let lang: String

    @State private var visibleSecrets: Set<String> = []

    private let tokenEnvKeys = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]

    var body: some View {
        SettingsCard {
            fieldRow(L10n.t("ccx.name", lang)) {
                TextField(L10n.t("ccx.name.placeholder", lang), text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            SettingsRowDivider()
            fieldRow(L10n.t("ccx.compatibility", lang)) {
                Picker("", selection: compatibilityBinding) {
                    ForEach(BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.allCases) { mode in
                        Text(modeLabel(mode)).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .accessibilityLabel(L10n.t("ccx.compatibility", lang))
            }
            SettingsRowDivider()
            if profile.isOpenAICompatible {
                openAIFields
            } else {
                anthropicFields
            }
        }
    }

    @ViewBuilder
    private var anthropicFields: some View {
        fieldRow(L10n.t("claudeCode.baseURL", lang)) {
            TextField("https://api.example.com", text: $profile.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
        }
        SettingsRowDivider()
        fieldRow(L10n.t("claudeCode.token", lang)) {
            secretInput("anthropic-token", text: $profile.token)
        }
        SettingsRowDivider()
        fieldRow(L10n.t("ccx.tokenEnvKey", lang)) {
            Picker("", selection: $profile.tokenEnvKey) {
                ForEach(tokenEnvKeys, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }

    @ViewBuilder
    private var openAIFields: some View {
        fieldRow(L10n.t("ccx.openai.baseURL", lang)) {
            TextField("https://api.example.com/v1", text: optionalBinding(\.openAIBaseURL))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
        }
        SettingsRowDivider()
        fieldRow(L10n.t("ccx.openai.apiKey", lang)) {
            secretInput("openai-api-key", text: optionalBinding(\.openAIAPIKey))
        }
        SettingsRowDivider()
        fieldRow(L10n.t("ccx.proxy.baseURL", lang)) {
            TextField("http://127.0.0.1:8317", text: optionalBinding(\.cliProxyBaseURL))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
        }
        SettingsRowDivider()
        fieldRow(L10n.t("ccx.proxy.apiKey", lang)) {
            secretInput("proxy-api-key", text: optionalBinding(\.cliProxyAPIKey))
        }
        SettingsRowDivider()
        fieldRow(L10n.t("ccx.proxy.managementKey", lang)) {
            secretInput("proxy-management-key", text: optionalBinding(\.cliProxyManagementKey))
        }
    }

    private var compatibilityBinding: Binding<String> {
        Binding(
            get: { profile.compatibility.rawValue },
            set: { value in
                profile.compatibilityMode = value == BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
                    ? nil
                    : value
            }
        )
    }

    private func modeLabel(_ mode: BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode) -> String {
        let key = mode == .anthropic ? "ccx.compatibility.anthropic" : "ccx.compatibility.openai"
        return L10n.t(key, lang)
    }

    private func secretInput(_ id: String, text: Binding<String>) -> some View {
        let isVisible = visibleSecrets.contains(id)
        return HStack(spacing: 6) {
            Group {
                if isVisible {
                    TextField(L10n.t("config.enter", lang), text: text)
                } else {
                    SecureField(L10n.t("config.enter", lang), text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12).monospaced())

            Button {
                if isVisible { visibleSecrets.remove(id) } else { visibleSecrets.insert(id) }
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(L10n.t(isVisible ? "ccx.token.hide" : "ccx.token.show", lang))
            .accessibilityLabel(L10n.t(isVisible ? "ccx.token.hide" : "ccx.token.show", lang))
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<BirdNionConfigStore.ClaudeCodeProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder _ trailing: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
                .frame(width: 150, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
