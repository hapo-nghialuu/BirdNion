import SwiftUI

struct CodexProfileConnectionFields: View {
    @Binding var profile: BirdNionConfigStore.CodexProfile
    let lang: String
    var header: String? = nil

    @State private var apiKeyVisible = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    var body: some View {
        SettingsCard(header: header ?? L10n.t("ccx.step.upstream", lang)) {
            fieldRow(L10n.t("codexConfig.name", lang)) {
                TextField(L10n.t("codexConfig.name.placeholder", lang), text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            SettingsRowDivider()
            fieldRow(L10n.t("codexConfig.protocol", lang)) {
                Picker("", selection: protocolBinding) {
                    ForEach(BirdNionConfigStore.CodexProfile.UpstreamProtocol.allCases) { protocolValue in
                        Text(protocolLabel(protocolValue)).tag(protocolValue.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .id(profile.id)
                .frame(maxWidth: 380, alignment: .trailing)
            }
            SettingsRowDivider()
            connectionRow
            SettingsRowDivider()
            fieldRow(L10n.t("codexConfig.baseURL", lang)) {
                TextField("https://api.example.com/v1", text: $profile.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
            }
            SettingsRowDivider()
            fieldRow(L10n.t("codexConfig.apiKey", lang)) {
                secretInput
            }
            SettingsRowDivider()
            fieldRow(L10n.t("codexConfig.model", lang)) {
                modelInput
            }
            if let modelsError {
                Text(modelsError)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.critical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }

    private var modelInput: some View {
        let options = suggestionOptions(current: profile.model)
        return HStack(spacing: 8) {
            TextField("gpt-5.6", text: $profile.model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
            Button {
                loadModels()
            } label: {
                if loadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.secondary)
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(loadingModels || !canFetchModels)
            .help(models.isEmpty
                  ? L10n.t("claudeCode.loadModels", lang)
                  : L10n.t("claudeCode.reloadModels", lang))
            .accessibilityLabel(models.isEmpty
                                ? L10n.t("claudeCode.loadModels", lang)
                                : L10n.t("claudeCode.reloadModels", lang))
            Menu {
                ForEach(options, id: \.self) { id in
                    Button(id) { profile.model = id }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .fixedSize()
            .disabled(options.isEmpty)
        }
    }

    private var canFetchModels: Bool {
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isEmpty && !key.isEmpty
    }

    private func suggestionOptions(current: String) -> [String] {
        var opts = models
        if !current.isEmpty, !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }

    private func loadModels() {
        let baseURL = profile.baseURL
        let token = profile.apiKey
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loadingModels = true
        modelsError = nil
        Task {
            do {
                let fetched = try await ClaudeCodeModelsFetcher.fetchModels(baseURL: baseURL, token: token)
                await MainActor.run {
                    models = fetched
                    loadingModels = false
                }
            } catch let error as ClaudeCodeModelsFetcher.FetchError {
                await MainActor.run {
                    modelsError = error.message
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    modelsError = error.localizedDescription
                    loadingModels = false
                }
            }
        }
    }

    private var protocolBinding: Binding<String> {
        Binding(
            get: { profile.upstreamProtocol.rawValue },
            set: { rawValue in
                guard let protocolValue = BirdNionConfigStore.CodexProfile.UpstreamProtocol(rawValue: rawValue) else { return }
                var updated = profile
                updated.upstreamProtocolRaw = protocolValue.rawValue
                if protocolValue != .responses {
                    updated.connectionModeRaw = BirdNionConfigStore.CodexProfile.ConnectionMode.localProxy.rawValue
                } else if updated.connectionModeRaw == nil {
                    updated.connectionModeRaw = BirdNionConfigStore.CodexProfile.ConnectionMode.direct.rawValue
                }
                updated.cliProxyAppliedSignature = nil
                profile = updated
            }
        )
    }

    @ViewBuilder
    private var connectionRow: some View {
        fieldRow(L10n.t("codexConfig.connection", lang)) {
            if profile.requiresEmbeddedCLIProxy {
                Label(L10n.t("codexConfig.connection.proxy", lang), systemImage: "arrow.triangle.swap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Picker("", selection: connectionBinding) {
                    Text(L10n.t("codexConfig.connection.direct", lang))
                        .tag(BirdNionConfigStore.CodexProfile.ConnectionMode.direct)
                    Text(L10n.t("codexConfig.connection.proxy", lang))
                        .tag(BirdNionConfigStore.CodexProfile.ConnectionMode.localProxy)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300, alignment: .trailing)
            }
        }
    }

    private var connectionBinding: Binding<BirdNionConfigStore.CodexProfile.ConnectionMode> {
        Binding(
            get: { profile.connectionMode },
            set: { mode in
                var updated = profile
                updated.connectionModeRaw = mode.rawValue
                updated.cliProxyAppliedSignature = nil
                profile = updated
            }
        )
    }

    private var secretInput: some View {
        HStack(spacing: 6) {
            Group {
                if apiKeyVisible {
                    TextField(L10n.t("config.enter", lang), text: $profile.apiKey)
                } else {
                    SecureField(L10n.t("config.enter", lang), text: $profile.apiKey)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12).monospaced())

            Button { apiKeyVisible.toggle() } label: {
                Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(L10n.t(apiKeyVisible ? "ccx.token.hide" : "ccx.token.show", lang))
        }
    }

    private func protocolLabel(_ value: BirdNionConfigStore.CodexProfile.UpstreamProtocol) -> String {
        switch value {
        case .responses: L10n.t("codexConfig.protocol.responses", lang)
        case .openAIChat: L10n.t("codexConfig.protocol.openaiChat", lang)
        case .anthropic: L10n.t("codexConfig.protocol.anthropic", lang)
        }
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
                .frame(width: 150, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
