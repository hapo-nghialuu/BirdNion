import SwiftUI
import AppKit

/// Settings → "Claude Code" tab. Two-pane layout: left lists every provider
/// that has an API key and can back Claude Code; right configures the Claude
/// Code `env` block (base URL, model tiers, 1M-context flag) and writes it to
/// the global `~/.claude/settings.json` or a per-project `settings.local.json`.
struct ClaudeCodePane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService
    @ObservedObject private var localProxy = EmbeddedCLIProxyService.shared

    @State private var providers: [BirdNionConfigStore.Provider] = []
    @State private var selectedID: String?

    // Custom user-defined backends.
    @State private var profiles: [BirdNionConfigStore.ClaudeCodeProfile] = []
    @State private var selectedProfileID: String?
    @State private var hoveredProviderID: String?
    @State private var hoveredProfileID: String?
    @State private var workingProfile: BirdNionConfigStore.ClaudeCodeProfile?
    @State private var showingPasteJSON = false
    @State private var pasteJSONText = ""
    @State private var importError: String?

    // Per-selection working state (reset whenever the selected provider changes).
    @State private var models: [String] = []
    @State private var haiku: String = ""
    @State private var sonnet: String = ""
    @State private var opus: String = ""
    @State private var disable1M: Bool = false
    @State private var scope: ScopeChoice = .global
    @State private var projectDir: URL?
    @State private var loadingModels = false
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var customFeedbackTarget: CustomFeedbackTarget?
    @State private var showingRemoveEnvConfirmation = false
    @State private var showingStopLocalProxyConfirmation = false

    private enum ScopeChoice: String, CaseIterable, Identifiable {
        case global, project
        var id: String { rawValue }
    }

    private enum CustomFeedbackTarget: Equatable {
        case upstream
        case proxy
        case claudeCode
    }

    private var lang: String { settings.appLanguage }
    private var scopeBinding: Binding<ScopeChoice> {
        Binding(
            get: { scope },
            set: { newValue in
                scope = newValue
                persistCurrentTarget()
            }
        )
    }

    var body: some View {
        // Scroll so the (tall) config form is never clipped by the fixed window
        // height. Always two-pane so the "＋ Add config" is reachable even with
        // no preset providers configured.
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                providerList
                Divider()
                    .overlay(SettingsTheme.border)
                detail
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.background)
        .onAppear {
            reloadProviders()
            reloadProfiles()
            loadSelection()
            Task { await localProxy.refreshRuntimeStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .birdnionProvidersChanged)) { _ in
            reloadProviders()
        }
        .onChange(of: selectedID) { _ in loadSelection() }
        .onChange(of: selectedProfileID) { _ in loadProfileSelection() }
        .onChange(of: workingProfile) { newValue in persistWorkingProfile(newValue) }
        .alert(L10n.t("claudeCode.removeEnv.confirmTitle", lang),
               isPresented: $showingRemoveEnvConfirmation) {
            Button(L10n.t("claudeCode.removeEnv.confirmButton", lang), role: .destructive) {
                removeCurrentEnvSettings()
            }
            Button(L10n.t("ccx.pasteJSON.cancel", lang), role: .cancel) {}
        } message: {
            Text(L10n.f("claudeCode.removeEnv.confirmMessage", lang, visibleTargetPath()))
        }
        .confirmationDialog(
            L10n.t("ccx.proxy.stop.confirmTitle", lang),
            isPresented: $showingStopLocalProxyConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("ccx.proxy.stop", lang), role: .destructive) {
                stopLocalProxy()
            }
            Button(L10n.t("ccx.pasteJSON.cancel", lang), role: .cancel) {}
        } message: {
            Text(L10n.t("ccx.proxy.stop.confirmMessage", lang))
        }
    }

    /// Auto-save custom-profile edits as the user types, and reflect the change
    /// (e.g. renamed) in the left list live — without disturbing the selection.
    private func persistWorkingProfile(_ profile: BirdNionConfigStore.ClaudeCodeProfile?) {
        guard let p = profile else { return }
        try? BirdNionConfigStore.saveClaudeCodeProfile(p)
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
    }

    // MARK: - Left column

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("claudeCode.selectProvider", lang))
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !providers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { idx, p in
                        providerRow(p)
                        if idx < providers.count - 1 { SettingsRowDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1))
            }

            // Custom user-defined backends.
            HStack {
                SettingsSectionHeader(title: L10n.t("ccx.custom", lang))
                Spacer()
                Button { addProfile() } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SettingsTheme.accent)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L10n.t("ccx.add", lang))
            }
            .padding(.top, 4)
            if !profiles.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { idx, p in
                        profileRow(p)
                        if idx < profiles.count - 1 { SettingsRowDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1))
            }
        }
        .frame(width: 240, alignment: .top)
    }

    private func profileRow(_ p: BirdNionConfigStore.ClaudeCodeProfile) -> some View {
        let selected = p.id == selectedProfileID
        let hovering = p.id == hoveredProfileID
        let activated = profileIsActivated(p)
        return Button {
            selectedID = nil
            selectedProfileID = p.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(activated
                                     ? SettingsTheme.success
                                     : (selected ? SettingsTheme.accent : SettingsTheme.secondary))
                    .frame(width: 18)
                Text(p.name.isEmpty ? L10n.t("ccx.newName", lang) : p.name)
                    .font(.system(size: 13, weight: selected || activated ? .semibold : .regular))
                    .foregroundStyle(SettingsTheme.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if activated {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.success)
                        .accessibilityLabel(L10n.t("claudeCode.state.on", lang))
                } else if ClaudeCodeConfigWriter.isReady(p) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.success)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(activated
                        ? SettingsTheme.success.opacity(selected ? 0.18 : 0.11)
                        : (selected
                           ? SettingsTheme.selectedSurface
                        : (hovering ? SettingsTheme.hoverSurface.opacity(0.62) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { inside in
            if inside {
                hoveredProfileID = p.id
            } else if hoveredProfileID == p.id {
                hoveredProfileID = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func providerRow(_ p: BirdNionConfigStore.Provider) -> some View {
        let active = p.id == selectedID
        let hovering = p.id == hoveredProviderID
        return Button {
            selectedProfileID = nil
            selectedID = p.id
        } label: {
            HStack(spacing: 8) {
                ProviderLogoMark(id: p.id,
                                 tint: active ? SettingsTheme.accent : SettingsTheme.secondary)
                    .frame(width: 18, height: 18)
                Text(providerName(p))
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(SettingsTheme.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if ClaudeCodeConfigWriter.isFullyConfigured(p) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.success)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active
                        ? SettingsTheme.selectedSurface
                        : (hovering ? SettingsTheme.hoverSurface.opacity(0.62) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { inside in
            if inside {
                hoveredProviderID = p.id
            } else if hoveredProviderID == p.id {
                hoveredProviderID = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // MARK: - Right column

    @ViewBuilder
    private var detail: some View {
        if selectedProfileID != nil {
            customDetail
        } else if let p = selectedProvider {
            presetDetail(p)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func presetDetail(_ p: BirdNionConfigStore.Provider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
                activationPanel(p)

                if let msg = errorMessage {
                    Text(msg).font(.system(size: 11)).foregroundStyle(SettingsTheme.critical)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let msg = statusMessage {
                    Text(msg).font(.system(size: 11)).foregroundStyle(SettingsTheme.success)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                SettingsCard {
                    scopeRow
                    if scope == .project {
                        SettingsRowDivider()
                        projectRow
                    }
                    SettingsRowDivider()
                    removeEnvRow
                    SettingsRowDivider()
                    infoRow(L10n.t("claudeCode.token", lang),
                            L10n.f("claudeCode.token.using", lang, providerName(p)) + " · " + masked(p.apiKey))
                    SettingsRowDivider()
                    infoRow(L10n.t("claudeCode.baseURL", lang),
                            ClaudeCodeBackend.baseURL(forProviderID: p.id) ?? "—")
                }

                SettingsCard(header: L10n.t("claudeCode.model", lang)) {
                    modelHeaderRow
                    SettingsRowDivider()
                    modelInputRow(L10n.t("claudeCode.model.haiku", lang), selection: $haiku)
                    SettingsRowDivider()
                    modelInputRow(L10n.t("claudeCode.model.sonnet", lang), selection: $sonnet)
                    SettingsRowDivider()
                    modelInputRow(L10n.t("claudeCode.model.opus", lang), selection: $opus)
                }

                SettingsCard {
                    Toggle(isOn: $disable1M) {
                        Text(L10n.t("claudeCode.disable1M", lang))
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsTheme.primary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Custom profile detail

    @ViewBuilder
    private var customDetail: some View {
        if workingProfile != nil {
            let binding = Binding<BirdNionConfigStore.ClaudeCodeProfile>(
                get: { workingProfile ?? Self.blankProfile() },
                set: { workingProfile = $0 }
            )
            VStack(alignment: .leading, spacing: 14) {
                ClaudeCodeCustomProfileConnectionFields(
                    profile: binding,
                    lang: lang,
                    header: L10n.t("ccx.step.upstream", lang),
                    onPasteJSON: openPasteJSON
                )
                customFeedbackRow(for: .upstream)

                if binding.wrappedValue.usesEmbeddedCLIProxy {
                    ClaudeCodeLocalProxyStatusCard(
                        runtimeState: localProxy.runtimeState,
                        hasUpstreamConfiguration: binding.wrappedValue.hasUpstreamConfiguration,
                        configurationCurrent: binding.wrappedValue.isCLIProxyConfigurationCurrent,
                        endpoint: EmbeddedCLIProxyService.localEndpoint,
                        lang: lang,
                        busy: busy,
                        feedback: customFeedback(for: .proxy),
                        feedbackIsError: customFeedbackIsError,
                        onStart: startLocalProxy,
                        onStop: { showingStopLocalProxyConfirmation = true },
                        onRefresh: refreshLocalProxyStatus
                    )
                }

                ClaudeCodeCustomProfileForm(
                    profile: binding,
                    lang: lang,
                    includesConnectionFields: false
                )

                customClaudeCodeStep(binding.wrappedValue)

                HStack {
                    Spacer()
                    Button(role: .destructive) { deleteProfile() } label: {
                        Label(L10n.t("ccx.delete", lang), systemImage: "trash")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showingPasteJSON) { pasteJSONSheet }
        }
    }

    private var pasteJSONSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("ccx.pasteJSON.title", lang))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(L10n.t("ccx.pasteJSON.hint", lang))
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pasteJSONText)
                .font(.system(size: 12).monospaced())
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsTheme.border, lineWidth: 1))
            if let err = importError {
                Text(err).font(.system(size: 11)).foregroundStyle(SettingsTheme.critical)
            }
            HStack {
                Spacer()
                Button(L10n.t("ccx.pasteJSON.cancel", lang)) { showingPasteJSON = false }
                Button(L10n.t("ccx.pasteJSON.apply", lang)) { importJSON() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasteJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .background(SettingsTheme.background)
    }

    private func importJSON() {
        guard let current = workingProfile else { return }
        do {
            workingProfile = try ClaudeCodeConfigWriter.profile(byImporting: pasteJSONText, into: current)
            showingPasteJSON = false
            importError = nil
            customFeedbackTarget = .upstream
            errorMessage = nil
            statusMessage = L10n.t("ccx.pasteJSON.imported", lang)
        } catch let e as ClaudeCodeConfigWriter.ImportError {
            importError = e.message
        } catch {
            importError = error.localizedDescription
        }
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                    .frame(width: 52, height: 52)
                    .background(SettingsTheme.selectedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1)
                    )
                Text(L10n.t("claudeCode.empty.title", lang))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(L10n.t("claudeCode.empty.body", lang))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        NotificationCenter.default.post(name: .openProvidersTab, object: nil)
                    } label: {
                        Label(L10n.t("claudeCode.empty.openProviders", lang), systemImage: "key")
                    }
                    .controlSize(.small)
                    Button {
                        addProfile()
                    } label: {
                        Label(L10n.t("ccx.add", lang), systemImage: "plus.circle")
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func openPasteJSON() {
        customFeedbackTarget = nil
        errorMessage = nil
        statusMessage = nil
        pasteJSONText = ""
        importError = nil
        showingPasteJSON = true
    }

    private func customFeedback(for target: CustomFeedbackTarget) -> String? {
        guard customFeedbackTarget == target else { return nil }
        return errorMessage ?? statusMessage
    }

    private var customFeedbackIsError: Bool {
        errorMessage != nil
    }

    @ViewBuilder
    private func customFeedbackRow(for target: CustomFeedbackTarget) -> some View {
        if let feedback = customFeedback(for: target) {
            Label(feedback, systemImage: customFeedbackIsError
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(customFeedbackIsError ? SettingsTheme.critical : SettingsTheme.success)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func customClaudeCodeStep(_ profile: BirdNionConfigStore.ClaudeCodeProfile) -> some View {
        let scope = currentScope()
        let state = profilePowerState(for: profile, scope: scope)
        let title = profile.name.isEmpty ? L10n.t("ccx.newName", lang) : profile.name
        let headerKey = profile.usesEmbeddedCLIProxy ? "ccx.step.claudeCode" : "ccx.step.claudeCode.direct"
        return SettingsCard(header: L10n.t(headerKey, lang)) {
            activationPanelBody(
                icon: Image(systemName: "terminal.fill"),
                title: title,
                subtitle: profileActivationSubtitle(state: state, profile: profile),
                target: visibleTargetLabel(),
                state: state,
                diameter: 64,
                action: { powerTapProfile(profile, state: state, scope: scope) }
            )

            SettingsRowDivider()
            scopeRow
            if self.scope == .project {
                SettingsRowDivider()
                projectRow
            }
            SettingsRowDivider()
            removeEnvRow

            if let feedback = customFeedback(for: .claudeCode) {
                SettingsRowDivider()
                Label(feedback, systemImage: customFeedbackIsError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(customFeedbackIsError ? SettingsTheme.critical : SettingsTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }

    private func profilePowerState(for profile: BirdNionConfigStore.ClaudeCodeProfile,
                                   scope: ClaudeCodeConfigWriter.Scope) -> ClaudeCodePowerButton.PowerState {
        let targetIsReady = self.scope != .project || projectDir != nil
        let configured = ClaudeCodeConfigWriter.isReady(profile) && targetIsReady
        guard configured else { return .needsSetup }
        let sync = ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: scope, using: config)
        if profile.usesEmbeddedCLIProxy,
           (localProxy.runtimeState != .running || !profile.isCLIProxyConfigurationCurrent) {
            return .stale
        }
        return powerState(configured: true, sync: sync)
    }

    private func activationPanel(_ p: BirdNionConfigStore.Provider) -> some View {
        // Draft = provider + the current (possibly-unsaved) form values, so the
        // sync state reflects what would be written now.
        var draft = p
        draft.claudeHaikuModel = haiku
        draft.claudeSonnetModel = sonnet
        draft.claudeOpusModel = opus
        draft.claudeDisable1M = disable1M
        draft.claudeCodeScope = scope.rawValue
        draft.claudeCodeProjectPath = projectDir?.path
        let configured = ClaudeCodeConfigWriter.isFullyConfigured(draft)
            && (scope != .project || projectDir != nil)
        let sc = currentScope()
        let sync = configured ? ClaudeCodeConfigWriter.syncState(forProvider: draft, scope: sc, using: config) : .off
        let state = powerState(configured: configured, sync: sync)
        return SettingsCard {
            activationPanelBody(
                icon: Image(systemName: "terminal.fill"),
                title: L10n.t("claudeCode.quickCard.title", lang),
                subtitle: powerSubtitle(state: state, name: providerName(p)),
                target: visibleTargetLabel(),
                state: state,
                diameter: 76,
                action: { powerTap(draft, state: state, scope: sc) },
                accessory: AnyView(HStack(spacing: 9) {
                    ProviderLogoMark(id: p.id, tint: SettingsTheme.accent)
                        .frame(width: 18, height: 18)
                    Text(providerName(p))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                        .lineLimit(1)
                })
            )
        }
    }

    private func activationPanelBody(icon: Image,
                                     title: String,
                                     subtitle: String,
                                     target: String,
                                     state: ClaudeCodePowerButton.PowerState,
                                     diameter: CGFloat,
                                     action: @escaping () -> Void,
                                     accessory: AnyView = AnyView(EmptyView())) -> some View {
        HStack(alignment: .center, spacing: 14) {
            icon
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(stateColor(state))
                .frame(width: 38, height: 38)
                .background(stateColor(state).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    HStack(spacing: 4) {
                        Image(systemName: stateIcon(state))
                            .font(.system(size: 9, weight: .bold))
                        Text(stateLabel(state))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(stateColor(state))
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(target, systemImage: "scope")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(SettingsTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    accessory
                }
            }

            Spacer(minLength: 10)

            ClaudeCodePowerButton(
                state: state,
                subtitle: "",
                diameter: diameter,
                busy: busy,
                subtitleColor: SettingsTheme.primary,
                showsSubtitle: false,
                action: action
            )
            .help(subtitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func powerState(configured: Bool,
                            sync: ClaudeCodeConfigWriter.SyncState) -> ClaudeCodePowerButton.PowerState {
        guard configured else { return .needsSetup }
        switch sync {
        case .synced: return .on
        case .stale: return .stale
        case .off: return .off
        }
    }

    private func powerSubtitle(state: ClaudeCodePowerButton.PowerState, name: String) -> String {
        switch state {
        case .on: return L10n.f("claudeCode.power.on", lang, name)
        case .off: return L10n.t("claudeCode.power.off", lang)
        case .stale: return L10n.t("claudeCode.power.stale", lang)
        case .needsSetup:
            if scope == .project && projectDir == nil { return L10n.t("claudeCode.project.none", lang) }
            return L10n.t("claudeCode.power.needModels", lang)
        }
    }

    private func profileActivationSubtitle(state: ClaudeCodePowerButton.PowerState,
                                           profile: BirdNionConfigStore.ClaudeCodeProfile) -> String {
        switch state {
        case .on:
            let name = profile.name.isEmpty ? L10n.t("ccx.newName", lang) : profile.name
            return L10n.f("claudeCode.power.on", lang, name)
        case .off: return L10n.t("claudeCode.power.off", lang)
        case .stale:
            if profile.usesEmbeddedCLIProxy,
               (localProxy.runtimeState != .running || !profile.isCLIProxyConfigurationCurrent) {
                return L10n.t("ccx.proxy.error.startFirst", lang)
            }
            return L10n.t("claudeCode.power.stale", lang)
        case .needsSetup:
            if scope == .project && projectDir == nil { return L10n.t("claudeCode.project.none", lang) }
            if profile.usesEmbeddedCLIProxy, profile.hasUpstreamConfiguration,
               (localProxy.runtimeState != .running || !profile.isCLIProxyConfigurationCurrent) {
                return L10n.t("ccx.proxy.error.startFirst", lang)
            }
            return profile.usesEmbeddedCLIProxy
                ? L10n.t("ccx.needProxyConfig", lang)
                : L10n.t("ccx.needConfig", lang)
        }
    }

    private func stateLabel(_ state: ClaudeCodePowerButton.PowerState) -> String {
        switch state {
        case .on: return L10n.t("claudeCode.state.on", lang)
        case .off: return L10n.t("claudeCode.state.off", lang)
        case .stale: return L10n.t("claudeCode.state.stale", lang)
        case .needsSetup: return L10n.t("claudeCode.state.setup", lang)
        }
    }

    private func stateIcon(_ state: ClaudeCodePowerButton.PowerState) -> String {
        switch state {
        case .on: return "checkmark.circle.fill"
        case .off: return "power.circle"
        case .stale: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsSetup: return "exclamationmark.circle.fill"
        }
    }

    private func stateColor(_ state: ClaudeCodePowerButton.PowerState) -> Color {
        switch state {
        case .on: return SettingsTheme.success
        case .off: return SettingsTheme.secondary
        case .stale: return SettingsTheme.warning
        case .needsSetup: return SettingsTheme.accent
        }
    }

    private func currentScope() -> ClaudeCodeConfigWriter.Scope {
        if scope == .project, let dir = projectDir { return .project(dir) }
        return .global
    }

    private func scope(for profile: BirdNionConfigStore.ClaudeCodeProfile) -> ClaudeCodeConfigWriter.Scope {
        guard profile.claudeCodeScope == ScopeChoice.project.rawValue,
              let path = cleaned(profile.claudeCodeProjectPath) else {
            return .global
        }
        return .project(URL(fileURLWithPath: path))
    }

    private func profileIsActivated(_ profile: BirdNionConfigStore.ClaudeCodeProfile) -> Bool {
        guard ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: scope(for: profile), using: config) == .synced else {
            return false
        }
        guard profile.usesEmbeddedCLIProxy else { return true }
        return EmbeddedCLIProxyService.isProfileRunning(profile, runtimeState: localProxy.runtimeState)
    }

    private func visibleTargetLabel() -> String {
        if scope == .project, projectDir == nil {
            return L10n.t("claudeCode.project.none", lang)
        }
        return targetLabel(currentScope())
    }

    private func removableScope() -> ClaudeCodeConfigWriter.Scope? {
        if scope == .project {
            guard let dir = projectDir else { return nil }
            return .project(dir)
        }
        return .global
    }

    private func visibleTargetPath() -> String {
        guard let sc = removableScope() else {
            return L10n.t("claudeCode.project.none", lang)
        }
        return ClaudeCodeConfigWriter.targetURL(scope: sc, config: config).path
    }

    private func targetLabel(_ sc: ClaudeCodeConfigWriter.Scope) -> String {
        switch sc {
        case .global:
            return L10n.t("claudeCode.quickCard.globalTarget", lang)
        case .project(let dir):
            return dir.appendingPathComponent(".claude/settings.json").path
        }
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L10n.t("claudeCode.scope", lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: scopeBinding) {
                    Text(L10n.t("claudeCode.scope.global", lang)).tag(ScopeChoice.global)
                    Text(L10n.t("claudeCode.scope.project", lang)).tag(ScopeChoice.project)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            if scope == .global {
                Text(L10n.t("claudeCode.scope.globalPath", lang))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var projectRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(projectDir?.path ?? L10n.t("claudeCode.project.none", lang))
                    .font(.system(size: 11))
                    .foregroundStyle(projectDir == nil ? SettingsTheme.tertiary : SettingsTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(L10n.t("claudeCode.project.choose", lang)) { chooseProjectDir() }
                    .controlSize(.small)
            }
            Text(L10n.t("claudeCode.project.gitignore", lang))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var removeEnvRow: some View {
        SettingsLabeledRow(
            title: L10n.t("claudeCode.removeEnv.title", lang),
            subtitle: L10n.f("claudeCode.removeEnv.subtitle", lang, visibleTargetPath())
        ) {
            Button(role: .destructive) {
                showingRemoveEnvConfirmation = true
            } label: {
                Label(L10n.t("claudeCode.removeEnv.button", lang), systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(removableScope() == nil || busy)
            .pointingHandCursor()
        }
    }

    private var modelHeaderRow: some View {
        HStack(spacing: 10) {
            if loadingModels {
                Text(L10n.t("claudeCode.loadingModels", lang))
                    .font(.system(size: 11)).foregroundStyle(SettingsTheme.secondary)
            } else if !models.isEmpty {
                Text(L10n.f("claudeCode.modelsLoaded", lang, models.count))
                    .font(.system(size: 11)).foregroundStyle(SettingsTheme.secondary)
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
            .controlSize(.small)
            .disabled(loadingModels)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Editable model id + a suggestions menu. Free text is required because
    /// some backends (MiniMax/DeepSeek) don't expose `/v1/models`, so the user
    /// must be able to type or pick a documented id.
    private func modelInputRow(_ label: String, selection: Binding<String>) -> some View {
        let options = suggestionOptions(current: selection.wrappedValue)
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(SettingsTheme.primary)
                .frame(width: 62, alignment: .leading)
            TextField(L10n.t("claudeCode.model.pickPlaceholder", lang), text: selection)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
            Menu {
                ForEach(options, id: \.self) { id in
                    Button(id) { selection.wrappedValue = id }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)   // hide the built-in arrow; keep our chevron only
            .frame(width: 22)
            .fixedSize()
            .disabled(options.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Data

    private var selectedProvider: BirdNionConfigStore.Provider? {
        providers.first { $0.id == selectedID }
    }

    private func reloadProviders() {
        providers = BirdNionConfigStore.allProviders().filter {
            cleaned($0.apiKey) != nil && ClaudeCodeBackend.isSupported($0.id)
        }
        if selectedID == nil || !providers.contains(where: { $0.id == selectedID }) {
            selectedID = providers.first?.id
        }
    }

    /// Load the selected provider's stored model choices into the working
    /// state. Seeds the picker option list with the stored ids so the current
    /// values render before the user hits "Load models".
    private func loadSelection() {
        statusMessage = nil
        errorMessage = nil
        customFeedbackTarget = nil
        guard let p = selectedProvider else {
            haiku = ""; sonnet = ""; opus = ""; disable1M = false; models = []
            return
        }
        haiku = p.claudeHaikuModel ?? ""
        sonnet = p.claudeSonnetModel ?? ""
        opus = p.claudeOpusModel ?? ""
        disable1M = p.claudeDisable1M ?? false
        loadTarget(scopeValue: p.claudeCodeScope, projectPath: p.claudeCodeProjectPath)
        // Seed the suggestion list with stored ids + the provider's documented
        // models, so pickers are usable even before "Load models".
        let suggestions = ClaudeCodeBackend.suggestedModels(forProviderID: p.id)
        models = orderedUnique([haiku, sonnet, opus].filter { !$0.isEmpty } + suggestions)
        // Pre-fill empty tiers: substring match first, else the first documented id.
        if let first = suggestions.first {
            if haiku.isEmpty { haiku = firstModel(containing: "haiku") ?? first }
            if sonnet.isEmpty { sonnet = firstModel(containing: "sonnet") ?? first }
            if opus.isEmpty { opus = firstModel(containing: "opus") ?? first }
        }
    }

    /// Suggestion menu options = fetched/known models ∪ the current value.
    private func suggestionOptions(current: String) -> [String] {
        var opts = models
        if !current.isEmpty, !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }

    private func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func loadModels() {
        guard let p = selectedProvider,
              let baseURL = ClaudeCodeBackend.baseURL(forProviderID: p.id),
              let token = cleaned(p.apiKey) else { return }
        loadingModels = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let fetched = try await ClaudeCodeModelsFetcher.fetchModels(baseURL: baseURL, token: token)
                await MainActor.run {
                    models = orderedUnique(fetched + models)  // keep documented suggestions
                    autoMatchIfEmpty()
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? ClaudeCodeModelsFetcher.FetchError)?.message
                        ?? error.localizedDescription
                    loadingModels = false
                }
            }
        }
    }

    /// Pre-select each tier by substring when it has no value yet.
    private func autoMatchIfEmpty() {
        if haiku.isEmpty { haiku = firstModel(containing: "haiku") ?? haiku }
        if sonnet.isEmpty { sonnet = firstModel(containing: "sonnet") ?? sonnet }
        if opus.isEmpty { opus = firstModel(containing: "opus") ?? opus }
    }

    private func firstModel(containing needle: String) -> String? {
        models.first { $0.lowercased().contains(needle) }
    }

    private func chooseProjectDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("claudeCode.project.choose", lang)
        if panel.runModal() == .OK, let url = panel.url {
            projectDir = url
            persistCurrentTarget()
        }
    }

    private func loadTarget(scopeValue: String?, projectPath: String?) {
        scope = ScopeChoice(rawValue: scopeValue ?? "") ?? .global
        projectDir = cleaned(projectPath).map { URL(fileURLWithPath: $0) }
    }

    private func persistCurrentTarget() {
        if let id = selectedID, let idx = providers.firstIndex(where: { $0.id == id }) {
            providers[idx].claudeCodeScope = scope.rawValue
            providers[idx].claudeCodeProjectPath = projectDir?.path
            try? BirdNionConfigStore.save(providers[idx])
            NotificationCenter.default.post(name: .claudeCodeTargetChanged, object: nil)
            return
        }

        guard selectedProfileID != nil, var profile = workingProfile else { return }
        profile.claudeCodeScope = scope.rawValue
        profile.claudeCodeProjectPath = projectDir?.path
        workingProfile = profile
        try? BirdNionConfigStore.saveClaudeCodeProfile(profile)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
        NotificationCenter.default.post(name: .claudeCodeTargetChanged, object: nil)
    }

    private func profileWithCurrentTarget(_ profile: BirdNionConfigStore.ClaudeCodeProfile)
    -> BirdNionConfigStore.ClaudeCodeProfile {
        var updated = profile
        updated.claudeCodeScope = scope.rawValue
        updated.claudeCodeProjectPath = projectDir?.path
        return updated
    }

    /// Power handler. `.on` (synced) → deactivate. `.off`/`.stale` → persist the
    /// form + merge the values into the settings file in place (patches only the
    /// managed keys, e.g. a changed API key; never clears the block).
    /// `draft` already carries the current form values.
    private func powerTap(_ draft: BirdNionConfigStore.Provider,
                          state: ClaudeCodePowerButton.PowerState,
                          scope sc: ClaudeCodeConfigWriter.Scope) {
        guard state != .needsSetup else { return }
        errorMessage = nil
        statusMessage = nil
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                if state == .on {
                    try ClaudeCodeConfigWriter.deactivate(scope: sc, using: config)
                    statusMessage = L10n.t("claudeCode.deactivated", lang)
                } else {
                    try BirdNionConfigStore.save(draft)
                    try ClaudeCodeConfigWriter.apply(provider: draft, scope: sc, using: config)
                    let target = ClaudeCodeConfigWriter.targetURL(scope: sc, config: config)
                    statusMessage = state == .stale
                        ? L10n.t("claudeCode.updated", lang)
                        : L10n.f("claudeCode.saved", lang, target.path)
                }
                reloadProviders()
            } catch let e as ClaudeCodeConfigWriter.WriteError {
                errorMessage = e.message
            } catch let e as ConfigError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func removeCurrentEnvSettings() {
        guard let sc = removableScope() else { return }
        let target = ClaudeCodeConfigWriter.targetURL(scope: sc, config: config)
        errorMessage = nil
        statusMessage = nil
        if selectedProfileID != nil { customFeedbackTarget = .claudeCode }
        busy = true
        Task { @MainActor in
            do {
                let removed = try ClaudeCodeConfigWriter.removeEnvSettings(scope: sc, using: config)
                statusMessage = removed
                    ? L10n.f("claudeCode.removeEnv.done", lang, target.path)
                    : L10n.t("claudeCode.removeEnv.none", lang)
                reloadProviders()
                reloadProfiles()
            } catch let e as ConfigError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    // MARK: - Custom profile data

    private func reloadProfiles() {
        profiles = BirdNionConfigStore.claudeCodeProfiles()
    }

    private func loadProfileSelection() {
        statusMessage = nil
        errorMessage = nil
        customFeedbackTarget = nil
        guard let id = selectedProfileID else { workingProfile = nil; return }
        guard var profile = profiles.first(where: { $0.id == id }) else {
            workingProfile = nil
            return
        }
        if profile.migrateLegacyLocalProxyToOpenAIIfNeeded() {
            do {
                try BirdNionConfigStore.saveClaudeCodeProfile(profile)
                if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[index] = profile
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        loadTarget(scopeValue: profile.claudeCodeScope, projectPath: profile.claudeCodeProjectPath)
        workingProfile = profile
    }

    private static func blankProfile() -> BirdNionConfigStore.ClaudeCodeProfile {
        .init(id: UUID().uuidString, name: "", baseURL: "", token: "",
              tokenEnvKey: "ANTHROPIC_AUTH_TOKEN", apiKeyHelper: nil,
              haikuModel: nil, sonnetModel: nil, opusModel: nil, extraEnv: nil,
              compatibilityMode: BirdNionConfigStore.ClaudeCodeProfile.CompatibilityMode.anthropic.rawValue,
              embeddedLocalProxy: false)
    }

    private func addProfile() {
        var p = Self.blankProfile()
        p.name = L10n.t("ccx.newName", lang)
        try? BirdNionConfigStore.saveClaudeCodeProfile(p)
        reloadProfiles()
        selectedID = nil
        selectedProfileID = p.id   // triggers loadProfileSelection
    }

    private func deleteProfile() {
        guard let id = selectedProfileID else { return }
        do {
            try BirdNionConfigStore.removeClaudeCodeProfile(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        selectedProfileID = nil
        workingProfile = nil
        customFeedbackTarget = nil
        reloadProfiles()
        selectedID = providers.first?.id
        Task { @MainActor in
            await EmbeddedCLIProxyService.shared.reconcileStoredProfiles()
        }
    }

    private func startLocalProxy() {
        guard var profile = workingProfile else { return }
        customFeedbackTarget = .proxy
        errorMessage = nil
        statusMessage = nil
        guard profile.hasUpstreamConfiguration else {
            errorMessage = L10n.t("ccx.proxy.error.incomplete", lang)
            return
        }

        busy = true
        Task { @MainActor in
            do {
                profile = profileWithCurrentTarget(profile)
                try BirdNionConfigStore.saveClaudeCodeProfile(profile)
                profile = try await EmbeddedCLIProxyService.shared.prepare(profile: profile)
                workingProfile = profile
                reloadProfiles()
                statusMessage = L10n.t("ccx.proxy.started", lang)
            } catch let error as EmbeddedCLIProxyService.ServiceError {
                errorMessage = embeddedCLIProxyErrorMessage(error)
            } catch let error as CLIProxyAPIClient.ClientError {
                errorMessage = cliProxyErrorMessage(error)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func refreshLocalProxyStatus() {
        customFeedbackTarget = nil
        Task { @MainActor in
            await EmbeddedCLIProxyService.shared.refreshRuntimeStatus()
        }
    }

    private func stopLocalProxy() {
        guard var profile = workingProfile else { return }
        customFeedbackTarget = .proxy
        errorMessage = nil
        statusMessage = nil
        let didStop = EmbeddedCLIProxyService.shared.stopManagedLocalProxy()
        profile.cliProxyAppliedSignature = nil
        do {
            try BirdNionConfigStore.saveClaudeCodeProfile(profile)
            workingProfile = profile
            reloadProfiles()
            errorMessage = nil
            statusMessage = L10n.t(
                didStop ? "ccx.proxy.stop.done" : "ccx.proxy.stop.none",
                lang
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Power toggle for a custom profile. Persists the working profile first,
    /// then activates (writes env + apiKeyHelper) or deactivates (strips them).
    private func powerTapProfile(_ profile: BirdNionConfigStore.ClaudeCodeProfile,
                                 state: ClaudeCodePowerButton.PowerState,
                                 scope sc: ClaudeCodeConfigWriter.Scope) {
        customFeedbackTarget = .claudeCode
        errorMessage = nil
        statusMessage = nil
        guard state != .needsSetup else {
            errorMessage = profile.usesEmbeddedCLIProxy && profile.hasUpstreamConfiguration
                ? L10n.t("ccx.proxy.error.startFirst", lang)
                : L10n.t(profile.usesEmbeddedCLIProxy ? "ccx.needProxyConfig" : "ccx.needConfig", lang)
            return
        }
        if state != .on, profile.usesEmbeddedCLIProxy,
           (localProxy.runtimeState != .running || !profile.isCLIProxyConfigurationCurrent) {
            errorMessage = L10n.t("ccx.proxy.error.startFirst", lang)
            return
        }
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                let profile = profileWithCurrentTarget(profile)
                try BirdNionConfigStore.saveClaudeCodeProfile(profile)  // persist edits
                if state == .on {
                    try ClaudeCodeConfigWriter.deactivate(profile: profile, scope: sc, using: config)
                    statusMessage = L10n.t("claudeCode.deactivated", lang)
                } else {
                    try ClaudeCodeConfigWriter.apply(profile: profile, scope: sc, using: config)
                    if !profile.usesEmbeddedCLIProxy {
                        EmbeddedCLIProxyService.shared.deactivateForDirectUpstream()
                    }
                    let target = ClaudeCodeConfigWriter.targetURL(scope: sc, config: config)
                    statusMessage = state == .stale
                        ? L10n.t("claudeCode.updated", lang)
                        : L10n.f("claudeCode.saved", lang, target.path)
                }
                reloadProfiles()
            } catch let e as EmbeddedCLIProxyService.ServiceError {
                errorMessage = embeddedCLIProxyErrorMessage(e)
            } catch let e as CLIProxyAPIClient.ClientError {
                errorMessage = cliProxyErrorMessage(e)
            } catch let e as ClaudeCodeConfigWriter.WriteError {
                errorMessage = e.message
            } catch let e as ConfigError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func masked(_ key: String?) -> String {
        guard let k = cleaned(key) else { return "••••" }
        return String(k.prefix(4)) + "••••"
    }

    private func cleaned(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private func cliProxyErrorMessage(_ error: CLIProxyAPIClient.ClientError) -> String {
        switch error {
        case .invalidProxyURL: return L10n.t("ccx.proxy.error.invalidURL", lang)
        case .network: return L10n.t("ccx.proxy.error.network", lang)
        case .http(let code): return L10n.f("ccx.proxy.error.http", lang, String(code))
        case .invalidResponse: return L10n.t("ccx.proxy.error.invalidResponse", lang)
        }
    }

    private func embeddedCLIProxyErrorMessage(_ error: EmbeddedCLIProxyService.ServiceError) -> String {
        switch error {
        case .incompleteConfiguration: return L10n.t("ccx.proxy.error.incomplete", lang)
        case .helperUnavailable: return L10n.t("ccx.proxy.error.helperUnavailable", lang)
        case .didNotStart: return L10n.t("ccx.proxy.error.didNotStart", lang)
        }
    }

    private func providerName(_ p: BirdNionConfigStore.Provider) -> String {
        switch p.id {
        case "hapo": return p.displayName ?? "Hapo AI Hub"
        case "minimax": return "MiniMax"
        case "claude": return "Claude"
        case "zai": return "z.ai"
        case "openrouter": return "OpenRouter"
        case "deepseek": return "DeepSeek"
        default: return p.displayName ?? p.id
        }
    }
}

extension Notification.Name {
    /// Routes the Settings window to the Providers tab (empty-state shortcut).
    static let openProvidersTab = Notification.Name("birdnion.openProvidersTab")
    /// Lightweight signal for Claude Code target metadata changes. Unlike
    /// `.birdnionProvidersChanged`, this only needs the popover quick card to
    /// re-read config and must not force a quota refresh.
    static let claudeCodeTargetChanged = Notification.Name("birdnion.claudeCodeTargetChanged")
}
