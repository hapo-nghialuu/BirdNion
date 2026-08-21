import SwiftUI

/// Editable form for a user-defined Claude Code backend (custom profile).
/// Pure presentational: binds to a working `ClaudeCodeProfile` copy; the parent
/// pane owns persistence and the power toggle.
struct ClaudeCodeCustomProfileForm: View {
    @Binding var profile: BirdNionConfigStore.ClaudeCodeProfile
    let lang: String
    var includesConnectionFields: Bool = true
    var modelHeader: String? = nil

    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if includesConnectionFields {
                ClaudeCodeCustomProfileConnectionFields(profile: $profile, lang: lang)
            }

            section(modelHeader ?? L10n.t("claudeCode.model", lang)) {
                modelHeaderRow
                fieldRow(L10n.t("claudeCode.model.haiku", lang)) {
                    modelInput(text: modelBinding(\.haikuModel))
                }
                fieldRow(L10n.t("claudeCode.model.sonnet", lang)) {
                    modelInput(text: modelBinding(\.sonnetModel))
                }
                fieldRow(L10n.t("claudeCode.model.opus", lang)) {
                    modelInput(text: modelBinding(\.opusModel))
                }
                if let modelsError {
                    Text(modelsError)
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }

            section(L10n.t("ccx.advanced", lang)) {
                if !profile.usesEmbeddedCLIProxy {
                    fieldRow("apiKeyHelper") {
                        TextField(L10n.t("ccx.apiKeyHelper.placeholder", lang),
                                  text: optionalBinding(\.apiKeyHelper))
                            .font(.plexMono(12))
                            .instrumentInputStyle()
                    }
                }
                extraEnvEditor
            }
        }
    }

    // MARK: - Model discovery

    private var canFetchModels: Bool {
        profile.upstreamBaseURL != nil && profile.upstreamAPIKey != nil
    }

    private var modelHeaderRow: some View {
        HStack(spacing: 10) {
            if loadingModels {
                Text(L10n.t("claudeCode.loadingModels", lang))
                    .font(.plexSans(11)).foregroundStyle(VocabbyTheme.secondary)
            } else if !models.isEmpty {
                Text(L10n.f("claudeCode.modelsLoaded", lang, models.count))
                    .font(.plexSans(11)).foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 8)
            Button {
                loadModels()
            } label: {
                HStack(spacing: 5) {
                    if loadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(models.isEmpty
                         ? L10n.t("claudeCode.loadModels", lang)
                         : L10n.t("claudeCode.reloadModels", lang))
                }
            }
            .buttonStyle(.instrumentOutline)
            .disabled(loadingModels || !canFetchModels)
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairlineTop()
    }

    private func modelInput(text: Binding<String>) -> some View {
        let options = suggestionOptions(current: text.wrappedValue)
        return HStack(spacing: 8) {
            TextField(L10n.t("ccx.model.optional", lang), text: text)
                .font(.plexMono(12))
                .instrumentInputStyle()
            Menu {
                ForEach(options, id: \.self) { id in
                    Button(id) { text.wrappedValue = id }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .fixedSize()
            .disabled(options.isEmpty)
        }
    }

    private func suggestionOptions(current: String) -> [String] {
        var opts = models
        if !current.isEmpty, !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }

    private func loadModels() {
        guard let baseURL = profile.upstreamBaseURL,
              let token = profile.upstreamAPIKey else { return }
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

    // MARK: - Extra env editor

    private var extraEnvEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("ccx.extraEnv", lang))
                .font(.plexSans(13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
            ForEach(pairs) { pair in
                HStack(spacing: 6) {
                    TextField("KEY", text: keyBinding(pair.id))
                        .font(.plexMono(11))
                        .instrumentInputStyle()
                    Text("=")
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    TextField("value", text: valueBinding(pair.id))
                        .font(.plexMono(11))
                        .instrumentInputStyle()
                    Button { removePair(pair.id) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(VocabbyTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            Button { addPair() } label: {
                Label(L10n.t("ccx.extraEnv.add", lang), systemImage: "plus.circle")
                    .font(.plexSans(12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VocabbyTheme.blue)
            .pointingHandCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairlineTop()
    }

    // MARK: - Helpers

    private func section<Content: View>(_ header: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header).plexEyebrow()
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
        }
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

/// Square, hairline-bordered text field chrome matching the Instrument
/// redesign's `.ccp-input` (border, no fill accent, 4pt corner) — replaces
/// `.textFieldStyle(.roundedBorder)` call sites in this file.
private extension View {
    func instrumentInputStyle() -> some View {
        instrumentControlFieldStyle()
    }
}
