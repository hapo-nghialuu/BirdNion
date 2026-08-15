import SwiftUI

/// Connection fields are isolated from the profile form so the upstream stays
/// concise while BirdNion manages its local conversion core internally.
struct ClaudeCodeCustomProfileConnectionFields: View {
    private enum ConnectionMode: String, Hashable {
        case direct
        case localProxy
    }

    @Binding var profile: BirdNionConfigStore.ClaudeCodeProfile
    let lang: String
    var header: String? = nil
    var onPasteJSON: (() -> Void)? = nil

    @State private var visibleSecrets: Set<String> = []

    private let tokenEnvKeys = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if header != nil || onPasteJSON != nil {
                HStack(spacing: 8) {
                    if let header {
                        Text(header).plexEyebrow()
                    }

                    Spacer(minLength: 8)

                    if let onPasteJSON {
                        Button(action: onPasteJSON) {
                            Label(L10n.t("ccx.pasteJSON", lang), systemImage: "doc.on.clipboard")
                                .font(.plexMono(11, weight: .semibold))
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: InstrumentShape.controlRadius))
                        .controlSize(.small)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                fieldRow(L10n.t("ccx.name", lang)) {
                    TextField(L10n.t("ccx.name.placeholder", lang), text: $profile.name)
                        .font(.plexSans(12))
                        .instrumentInputStyle()
                }
                fieldRow(L10n.t("ccx.compatibility", lang)) {
                    Picker("", selection: protocolSelection) {
                        Text(L10n.t("codexConfig.protocol.anthropic", lang)).tag("anthropic")
                        Text(L10n.t("codexConfig.protocol.openaiChat", lang)).tag("chat")
                        Text(L10n.t("codexConfig.protocol.responses", lang)).tag("responses")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // SegmentedControl caches its previous selection in AppKit.
                    // Recreate it when moving between custom profiles.
                    .id(profile.id)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(L10n.t("ccx.compatibility.hint", lang))
                    .accessibilityLabel(L10n.t("ccx.compatibility", lang))
                }
                if !profile.isOpenAICompatible {
                    connectionModeRow
                }
                upstreamFields
                if !profile.usesEmbeddedCLIProxy {
                    tokenEnvironmentRow
                }
            }
        }
    }

    @ViewBuilder
    private var upstreamFields: some View {
        if profile.isOpenAICompatible {
            openAIFields
        } else {
            anthropicFields
        }
    }

    @ViewBuilder
    private var anthropicFields: some View {
        fieldRow(L10n.t("claudeCode.baseURL", lang)) {
            TextField("https://api.example.com", text: $profile.baseURL)
                .font(.plexMono(12))
                .instrumentInputStyle()
        }
        fieldRow(L10n.t("claudeCode.token", lang)) {
            secretInput("anthropic-token", text: $profile.token)
        }
    }

    @ViewBuilder
    private var tokenEnvironmentRow: some View {
        fieldRow(L10n.t("ccx.tokenEnvKey", lang)) {
            Picker("", selection: $profile.tokenEnvKey) {
                ForEach(tokenEnvKeys, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var openAIFields: some View {
        fieldRow(L10n.t("ccx.openai.baseURL", lang)) {
            TextField("https://api.example.com/v1", text: optionalBinding(\.openAIBaseURL))
                .font(.plexMono(12))
                .instrumentInputStyle()
        }
        fieldRow(L10n.t("ccx.openai.apiKey", lang)) {
            secretInput("openai-api-key", text: optionalBinding(\.openAIAPIKey))
        }
    }

    /// One user-facing wire-protocol choice covering both stored fields:
    /// anthropic ⇄ compatibility, chat/responses ⇄ compatibility=openai +
    /// `openAIFormat` nil / "responses". Built as a single write — a second
    /// write derived from re-reading `profile` in the same update would see
    /// the stale value and clobber the first.
    private var protocolSelection: Binding<String> {
        Binding(
            get: {
                guard profile.isOpenAICompatible else { return "anthropic" }
                return profile.openAIProxyFormat == "responses" ? "responses" : "chat"
            },
            set: { raw in
                var updated = profile
                if raw == "anthropic" {
                    if updated.baseURL.isEmpty { updated.baseURL = updated.openAIBaseURL ?? "" }
                    if updated.token.isEmpty { updated.token = updated.openAIAPIKey ?? "" }
                    updated.openAIFormat = nil
                    updated.compatibilityMode =
                        BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
                } else {
                    if updated.openAIBaseURL?.isEmpty ?? true { updated.openAIBaseURL = nonEmpty(updated.baseURL) }
                    if updated.openAIAPIKey?.isEmpty ?? true { updated.openAIAPIKey = nonEmpty(updated.token) }
                    updated.embeddedLocalProxy = true
                    updated.openAIFormat = raw == "responses" ? "responses" : nil
                    updated.compatibilityMode =
                        BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.openAI.rawValue
                }
                profile = updated
            }
        )
    }

    private var connectionModeRow: some View {
        fieldRow(L10n.t("ccx.connection", lang)) {
            Picker("", selection: connectionModeBinding) {
                Text(L10n.t("ccx.connection.direct", lang)).tag(ConnectionMode.direct)
                Text(L10n.t("ccx.connection.proxy", lang)).tag(ConnectionMode.localProxy)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(L10n.t("ccx.connection", lang))
        }
    }

    private var connectionModeBinding: Binding<ConnectionMode> {
        Binding(
            get: { profile.usesEmbeddedCLIProxy ? .localProxy : .direct },
            set: { mode in
                var updated = profile
                // Persist the fallback explicitly before a legacy direct profile
                // is switched to the local proxy, so future loads stay unambiguous.
                if updated.compatibilityMode == nil {
                    updated.compatibilityMode = updated.compatibility.rawValue
                }
                updated.embeddedLocalProxy = mode == .localProxy
                if mode == .direct {
                    updated.cliProxyAppliedSignature = nil
                }
                profile = updated
            }
        )
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
            .font(.plexMono(12))
            .instrumentInputStyle()

            Button {
                if isVisible { visibleSecrets.remove(id) } else { visibleSecrets.insert(id) }
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
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

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder _ trailing: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
                .frame(width: 110, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .hairlineTop()
    }
}

/// Square, hairline-bordered text field chrome matching the Instrument
/// redesign's `.ccp-input` (border, no fill accent, 4pt corner) — replaces
/// `.textFieldStyle(.roundedBorder)` call sites in this file.
private extension View {
    func instrumentInputStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(VocabbyTheme.background)
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
    }
}
