import SwiftUI

/// Settings → Codex. Configures a user-level Codex custom provider without
/// touching Codex authentication or project-scoped configuration files.
struct CodexPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var localProxy = EmbeddedCLIProxyService.shared

    var initialProfileID: String? = nil
    var onSwitchToClaudeCode: ((BirdNionConfigStore.CodexProfile) -> Void)? = nil

    @State private var profiles: [BirdNionConfigStore.CodexProfile] = []
    @State private var selectedID: String?
    @State private var workingProfile: BirdNionConfigStore.CodexProfile?
    @State private var activeProfileID: String?
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingStopProxyConfirmation = false
    @State private var showingDeleteProfileConfirmation = false

    private var lang: String { settings.appLanguage }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                CodexProfileList(
                    profiles: profiles,
                    selectedID: $selectedID,
                    activeProfileID: activeProfileID,
                    currentProfileID: currentProfileID,
                    proxyRuntimeState: localProxy.runtimeState,
                    lang: lang,
                    onAdd: addProfile
                )
                Divider().overlay(SettingsTheme.border)
                detail
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.background)
        .onAppear {
            reloadProfiles()
            if let initialProfileID,
               profiles.contains(where: { $0.id == initialProfileID }) {
                selectedID = initialProfileID
            } else if selectedID == nil {
                selectedID = profiles.first?.id
            }
            loadSelection()
            Task { await localProxy.refreshRuntimeStatus() }
        }
        .onChange(of: selectedID) { _, _ in loadSelection() }
        .onChange(of: workingProfile) { _, profile in saveWorkingProfile(profile) }
        .confirmationDialog(
            L10n.t("codexConfig.proxy.stopConfirmTitle", lang),
            isPresented: $showingStopProxyConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("ccx.proxy.stop", lang), role: .destructive) { stopProxy() }
            Button(L10n.t("ccx.pasteJSON.cancel", lang), role: .cancel) {}
        } message: {
            Text(L10n.t("codexConfig.proxy.stopConfirmMessage", lang))
        }
        .confirmationDialog(
            L10n.t("ccx.delete.confirmTitle", lang),
            isPresented: $showingDeleteProfileConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("codexConfig.delete", lang), role: .destructive) { deleteProfile() }
            Button(L10n.t("ccx.pasteJSON.cancel", lang), role: .cancel) {}
        } message: {
            Text(L10n.f("ccx.delete.confirmMessage", lang, workingProfileDisplayName))
        }
    }

    private var workingProfileDisplayName: String {
        guard let name = workingProfile?.name, !name.isEmpty else {
            return L10n.t("codexConfig.newName", lang)
        }
        return name
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = workingProfile {
            let binding = Binding<BirdNionConfigStore.CodexProfile>(
                get: { workingProfile ?? profile },
                set: { workingProfile = $0 }
            )
            // One top-to-bottom flow; numbers shift when the proxy step is
            // skipped (direct Responses upstream) or the agent picker hidden.
            let hasProxy = profile.usesEmbeddedCLIProxy
            let agentStep = hasProxy ? 3 : 2
            let activateStep = onSwitchToClaudeCode != nil ? agentStep + 1 : agentStep
            VStack(alignment: .leading, spacing: 14) {
                CodexProfileConnectionFields(profile: binding, lang: lang,
                                             header: stepTitle(1, "ccx.step.upstream"))

                if hasProxy {
                    ClaudeCodeLocalProxyStatusCard(
                        runtimeState: localProxy.runtimeState,
                        hasUpstreamConfiguration: profile.hasUpstreamConfiguration,
                        configurationCurrent: profile.isCLIProxyConfigurationCurrent,
                        endpoint: EmbeddedCLIProxyService.localEndpoint,
                        lang: lang,
                        busy: busy,
                        feedback: proxyFeedback,
                        feedbackIsError: errorMessage != nil,
                        onStart: startProxy,
                        onStop: { showingStopProxyConfirmation = true },
                        onRefresh: refreshProxy,
                        header: stepTitle(2, "ccx.step.proxy"),
                        runningDetail: L10n.t("codexConfig.proxy.running", lang),
                        stoppedDetail: L10n.t("codexConfig.proxy.stopped", lang)
                    )
                }

                if let onSwitchToClaudeCode {
                    AICodingAgentSelectionCard(
                        selectedAgent: .codex,
                        profileID: profile.id,
                        lang: lang,
                        header: stepTitle(agentStep, "aiCoding.step.agent")
                    ) { target in
                        if target == .claudeCode {
                            onSwitchToClaudeCode(profile)
                        }
                    }
                }

                CodexProfileActivationCard(
                    profile: profile,
                    active: activeProfileID == profile.id,
                    current: CodexConfigWriter.isApplied(profile),
                    lang: lang,
                    busy: busy,
                    header: stepTitle(activateStep, "codexConfig.target"),
                    onApply: applyProfile,
                    onDeactivate: deactivateProfile,
                    onDelete: { showingDeleteProfileConfirmation = true }
                )

                feedback
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Spacer().frame(height: 1)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsTheme.critical)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsTheme.success)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// "N. <title>" — mirrors ClaudeCodePane's dynamic step numbering.
    private func stepTitle(_ number: Int, _ key: String) -> String {
        "\(number). " + L10n.t(key, lang)
    }

    private var proxyFeedback: String? {
        guard workingProfile?.usesEmbeddedCLIProxy == true else { return nil }
        return errorMessage ?? statusMessage
    }

    private func reloadProfiles() {
        profiles = BirdNionConfigStore.codexProfiles()
        activeProfileID = CodexConfigWriter.activeProfileID()
    }

    private var currentProfileID: String? {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              CodexConfigWriter.isApplied(profile) else { return nil }
        return activeProfileID
    }

    private func loadSelection() {
        errorMessage = nil
        statusMessage = nil
        guard let selectedID,
              let profile = profiles.first(where: { $0.id == selectedID }) else {
            workingProfile = nil
            return
        }
        workingProfile = profile
    }

    private func saveWorkingProfile(_ profile: BirdNionConfigStore.CodexProfile?) {
        guard let profile else { return }
        try? BirdNionConfigStore.saveCodexProfile(profile)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    private func addProfile() {
        let profile = BirdNionConfigStore.CodexProfile(
            id: UUID().uuidString,
            name: L10n.t("codexConfig.newName", lang),
            baseURL: "",
            apiKey: "",
            model: "",
            upstreamProtocolRaw: BirdNionConfigStore.CodexProfile.UpstreamProtocol.responses.rawValue,
            connectionModeRaw: BirdNionConfigStore.CodexProfile.ConnectionMode.direct.rawValue
        )
        try? BirdNionConfigStore.saveCodexProfile(profile)
        reloadProfiles()
        selectedID = profile.id
    }

    private func startProxy() {
        guard let profile = workingProfile, profile.hasUpstreamConfiguration else {
            errorMessage = L10n.t("codexConfig.error.incomplete", lang)
            return
        }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            do {
                let prepared = try await localProxy.prepare(codexProfile: profile)
                workingProfile = prepared
                reloadProfiles()
                statusMessage = L10n.t("ccx.proxy.started", lang)
            } catch {
                errorMessage = proxyErrorMessage(error)
            }
            busy = false
        }
    }

    private func refreshProxy() {
        errorMessage = nil
        statusMessage = nil
        Task { await localProxy.refreshRuntimeStatus() }
    }

    private func stopProxy() {
        guard var profile = workingProfile else { return }
        let stopped = localProxy.stopManagedLocalProxy()
        profile.cliProxyAppliedSignature = nil
        try? BirdNionConfigStore.saveCodexProfile(profile)
        workingProfile = profile
        reloadProfiles()
        statusMessage = L10n.t(stopped ? "ccx.proxy.stop.done" : "ccx.proxy.stop.none", lang)
    }

    private func applyProfile() {
        guard var profile = workingProfile, profile.hasUpstreamConfiguration else {
            errorMessage = L10n.t("codexConfig.error.incomplete", lang)
            return
        }
        let replacingActive = activeProfileID == profile.id
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            do {
                if profile.usesEmbeddedCLIProxy {
                    profile = try await localProxy.prepare(codexProfile: profile)
                    try CodexConfigWriter.apply(profile: profile)
                } else {
                    profile.cliProxyAppliedSignature = nil
                    try BirdNionConfigStore.saveCodexProfile(profile)
                    try CodexConfigWriter.apply(profile: profile)
                    try await localProxy.deactivateCodexProxyProfiles()
                }
                workingProfile = profile
                reloadProfiles()
                statusMessage = L10n.t(replacingActive ? "codexConfig.updated" : "codexConfig.applied", lang)
            } catch {
                errorMessage = proxyErrorMessage(error)
            }
            busy = false
        }
    }

    private func deactivateProfile() {
        guard var profile = workingProfile else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            do {
                _ = try CodexConfigWriter.deactivate()
                profile.cliProxyAppliedSignature = nil
                try BirdNionConfigStore.saveCodexProfile(profile)
                try await localProxy.deactivateCodexProxyProfiles()
                workingProfile = profile
                reloadProfiles()
                statusMessage = L10n.t("codexConfig.deactivated", lang)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func deleteProfile() {
        guard let profile = workingProfile else { return }
        if activeProfileID == profile.id { _ = try? CodexConfigWriter.deactivate() }
        try? BirdNionConfigStore.removeCodexProfile(id: profile.id)
        Task { await localProxy.reconcileStoredProfiles() }
        selectedID = nil
        workingProfile = nil
        reloadProfiles()
        selectedID = profiles.first?.id
    }

    private func proxyErrorMessage(_ error: Error) -> String {
        if let serviceError = error as? EmbeddedCLIProxyService.ServiceError {
            switch serviceError {
            case .incompleteConfiguration:
                return L10n.t("codexConfig.error.incomplete", lang)
            case .helperUnavailable:
                return L10n.t("ccx.proxy.error.helperUnavailable", lang)
            case .didNotStart:
                return L10n.t("ccx.proxy.error.didNotStart", lang)
            }
        }
        if let clientError = error as? CLIProxyAPIClient.ClientError {
            switch clientError {
            case .invalidProxyURL:
                return L10n.t("ccx.proxy.error.invalidURL", lang)
            case .network:
                return L10n.t("ccx.proxy.error.network", lang)
            case .http(let code):
                return L10n.f("ccx.proxy.error.http", lang, code)
            case .invalidResponse:
                return L10n.t("ccx.proxy.error.invalidResponse", lang)
            }
        }
        return error.localizedDescription
    }
}
