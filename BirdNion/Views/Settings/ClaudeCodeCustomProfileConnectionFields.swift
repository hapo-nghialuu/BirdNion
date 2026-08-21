import SwiftUI

enum ClaudeCodeProtocolSelection: String {
    case anthropic
    case chat
    case responses

    static func value(for profile: BirdNionConfigStore.ClaudeCodeProfile) -> Self {
        guard profile.isOpenAICompatible else { return .anthropic }
        return profile.openAIProxyFormat == "responses" ? .responses : .chat
    }

    static func applying(
        _ selection: Self,
        to profile: BirdNionConfigStore.ClaudeCodeProfile
    ) -> BirdNionConfigStore.ClaudeCodeProfile {
        var updated = profile
        if selection == .anthropic {
            if updated.baseURL.isEmpty { updated.baseURL = updated.openAIBaseURL ?? "" }
            if updated.token.isEmpty { updated.token = updated.openAIAPIKey ?? "" }
            updated.openAIFormat = nil
            updated.compatibilityMode =
                BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue
        } else {
            if updated.openAIBaseURL?.isEmpty ?? true { updated.openAIBaseURL = nonEmpty(updated.baseURL) }
            if updated.openAIAPIKey?.isEmpty ?? true { updated.openAIAPIKey = nonEmpty(updated.token) }
            updated.embeddedLocalProxy = true
            updated.openAIFormat = selection == .responses ? "responses" : nil
            updated.compatibilityMode =
                BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.openAI.rawValue
        }
        return updated
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
                        }
                        .buttonStyle(.instrumentOutline)
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
                    InstrumentSegmentedControl(
                        options: [
                            (.anthropic, L10n.t("codexConfig.protocol.anthropic", lang)),
                            (.chat, L10n.t("codexConfig.protocol.openaiChat", lang)),
                            (.responses, L10n.t("codexConfig.protocol.responses", lang)),
                        ],
                        selection: protocolSelection
                    )
                    // Recreate when moving between custom profiles.
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
            InstrumentMenuSelect(
                options: tokenEnvKeys.map { ($0, $0) },
                selection: $profile.tokenEnvKey
            )
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
    private var protocolSelection: Binding<ClaudeCodeProtocolSelection> {
        Binding(
            get: { ClaudeCodeProtocolSelection.value(for: profile) },
            set: { profile = ClaudeCodeProtocolSelection.applying($0, to: profile) }
        )
    }

    private var connectionModeRow: some View {
        fieldRow(L10n.t("ccx.connection", lang)) {
            InstrumentSegmentedControl(
                options: [
                    (.direct, L10n.t("ccx.connection.direct", lang)),
                    (.localProxy, L10n.t("ccx.connection.proxy", lang)),
                ],
                selection: connectionModeBinding
            )
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
        instrumentControlFieldStyle()
    }
}
