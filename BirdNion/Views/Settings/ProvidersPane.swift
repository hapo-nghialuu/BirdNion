import SwiftUI
import UniformTypeIdentifiers

/// Providers tab — CodexBar-style two-pane layout: a sidebar listing every
/// provider (logo + name + status + enable toggle) on the left, and a detail
/// panel for the selected provider on the right.
///
/// Reuses the existing model layer: BirdNionConfigStore (settings.json
/// — single source of truth for tokens + enabled flags + metadata),
/// QuotaService (live status), and the bundled brand logos. Codex is
/// zero-config (login status from ~/.codex/auth.json); the other providers
/// take a token.
///
/// P4: view modules live in ProvidersSidebar / ProviderDetail /
/// ProviderAccountsSection / ProviderCostSection (extensions of this type).
struct ProvidersPane: View {
    /// Drag payload type for provider reordering. Uses the system plain-text
    /// type: a custom UTType would need a UTExportedTypeDeclarations entry in
    /// Info.plist or macOS silently rejects the drop (validateDrop /
    /// hasItemsConforming never match, so onDrop stays inert). The payload is
    /// never read on drop — delegates track the dragged row via
    /// `draggedRowId` — so plain text is sufficient and external text drags
    /// are still rejected by the `draggedProviderId != nil` guard.
    static let providerDragType = UTType.plainText

    @EnvironmentObject var quota: QuotaService
    @EnvironmentObject var settings: SettingsStore
    /// On-disk footprint cache for the "Dung lượng" info row (Advanced toggle).
    @ObservedObject var storageScanner = ProviderStorageScanner.shared

    /// Settings nav selection — the pane renders the whole window row
    /// (sidebar with embedded provider roster + detail), so it needs the
    /// shared tab binding for the nav block.
    @Binding var tab: SettingsTab

    @State var rows: [BirdNionConfigStore.Provider] = []
    @State var selectedID: String?
    /// Search filter for the provider sidebar. Matches display name + id
    /// case-insensitively; empty string shows all rows.
    @State var searchText: String = ""
    /// Codex token cost (today / 30d), scanned lazily when Codex is selected.
    @State var codexCost: CodexCostSummary?
    /// Claude token cost (today / 30d), scanned lazily when Claude is
    /// selected — mirrors CodexCostScanner but reads Claude Code's local
    /// session jsonl files (see ClaudeCostScanner.swift).
    @State var claudeCost: ClaudeCostSummary?
    /// Claude multi-account state (web sessionKey / Admin API key accounts).
    @State var claudeAccounts: ClaudeTokenAccountData = ClaudeTokenAccountStore.load()
    @State var newAccountToken: String = ""
    @State var newAccountLabel: String = ""
    @State var newAccountKind: ClaudeTokenAccount.Kind = .web

    // MARK: - Antigravity OAuth state
    @State var antigravityStore: AntigravityOAuthStore.Store = AntigravityOAuthStore.load()
    @State var antigravityNewLabel: String = ""
    @State var antigravityNewJSON: String = ""
    @State var antigravityLoginInProgress: Bool = false
    @State var antigravityLoginError: String? = nil
    @State var antigravityReloadTick: Int = 0

    // MARK: - Copilot OAuth state
    @State var copilotStore: CopilotAccountStore.Store = CopilotAccountStore.load()
    @State var copilotReloadTick: Int = 0
    @State var copilotDeviceUserCode: String? = nil
    @State var copilotLoginInProgress: Bool = false
    @State var copilotLoginError: String? = nil
    @State var copilotLoginTask: Task<Void, Never>? = nil

    // Kilo organizations: transient list fetched on demand for the scope picker.
    @State var kiloKnownOrgs: [KiloOrganization] = []
    @State var kiloOrgRefreshing: Bool = false
    @State var kiloOrgError: String? = nil

    // Bumped to force the per-provider menu-bar-metric picker to re-read its
    // UserDefaults-backed selection after a change.
    @State var menuBarMetricTick: Int = 0

    var language: String { settings.appLanguage }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $tab) {
                sidebar
            }

            VStack(alignment: .leading, spacing: 12) {
                SettingsPaneHeader(
                    title: L10n.t("settings.tab.providers", language),
                    subtitle: L10n.t("settings.providers.subtitle", language)
                )
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsTheme.background)
        }
        // Catch-all: a reorder drag released anywhere in the pane that isn't
        // a row or divider (search field, detail panel, padding) still
        // commits the current preview order and clears the ghosted row —
        // otherwise the dragged row stays faded until the next drag starts.
        .onDrop(of: [Self.providerDragType], delegate: SidebarDropCompletionDelegate(
            draggedProviderId: $draggedRowId,
            dropTargetRowId: $dropTargetRowId,
            finish: finishRowMove))
        .task {
            // Always reload on first appearance (and on tab re-focus via
            // the parent's `.task(id:)` trigger below). The previous
            // `if rows.isEmpty` guard meant a panel that once loaded with
            // `[]` from a missing config file would stay empty even after
            // the user created the file via Settings — `allProviders()` now
            // falls back to the canonical 7-provider list, but we still
            // want a fresh read so toggles from another pane propagate.
            rows = BirdNionConfigStore.allProviders()
            if selectedID == nil { selectedID = rows.first?.id }
        }
        .task(id: selectedID) {
            // Stale self-test results don't carry across provider switches.
            selfTestState = [:]
            // Scan local sessions for token cost only while the provider is
            // selected. Mirrors CodexCostScanner's behavior — cached 5 min
            // so the panel doesn't re-walk the project tree on every refresh.
            switch selectedID {
            case "codex":
                claudeCost = nil
                codexCost = await CodexCostScanner.summary()
            case "claude":
                codexCost = nil
                claudeCost = await ClaudeCostScanner.summary()
            default:
                codexCost = nil
                claudeCost = nil
            }
            // On-disk footprint for the storage row (Advanced toggle).
            if settings.providerStorageFootprintsEnabled, let id = selectedID {
                storageScanner.refreshIfStale(id: id)
            }
        }
        .task(id: antigravityReloadTick) {
            antigravityStore = AntigravityOAuthStore.load()
        }
        .task(id: copilotReloadTick) {
            copilotStore = CopilotAccountStore.load()
        }
    }

    /// Pure reorder helper used by the live drag preview and unit tests. The
    /// visible order can differ from storage order because enabled providers
    /// are grouped first, so direction is derived from `visibleIDs` while the
    /// actual item is moved in the complete provider array.
    static func reorderedProviders(
        _ providers: [BirdNionConfigStore.Provider],
        visibleIDs: [String],
        draggedID: String,
        targetIndex: Int
    ) -> [BirdNionConfigStore.Provider] {
        guard let fromVisible = visibleIDs.firstIndex(of: draggedID),
              visibleIDs.indices.contains(targetIndex)
        else { return providers }

        let targetID = visibleIDs[targetIndex]
        guard targetID != draggedID,
              let fromReal = providers.firstIndex(where: { $0.id == draggedID })
        else { return providers }

        var reordered = providers
        let item = reordered.remove(at: fromReal)
        guard let targetReal = reordered.firstIndex(where: { $0.id == targetID }) else {
            return providers
        }
        let movingDown = fromVisible < targetIndex
        let insertionIndex = movingDown ? targetReal + 1 : targetReal
        reordered.insert(item, at: min(insertionIndex, reordered.endIndex))
        return reordered
    }

    /// Tracks which row is currently being dragged (used by the drop
    /// delegate to know when to activate the row's drop indicator).
    @State var draggedRowId: String?
    @State var dropTargetRowId: String?
    @State var hoveredRowId: String?
    @State var dragStartRows: [BirdNionConfigStore.Provider]?

    // MARK: - Self-test (R2-02)

    /// Per-provider one-shot probe lifecycle for the detail-header button.
    enum SelfTestState: Equatable {
        case idle, running, pass
        case fail(kind: ProviderErrorKind, raw: String)
    }

    @State var selfTestState: [String: SelfTestState] = [:]

    /// Pre-defined options for the per-provider refresh picker. `seconds = 0`
    /// means "use global"; the other values are absolute.
    static let providerRefreshOptions: [Double] = [0, 30, 60, 120, 300, 600, 1800]

    /// Provider ids that authenticate via a browser session cookie (no API token).
    static let cookieProviderIDs: Set<String> = [
        "commandcode", "mimo", "alibaba", "opencode", "opencodego", "cursor", "freemodel", "ollama",
    ]
}

// MARK: - Bindings & helpers (P4 module split)

extension ProvidersPane {
    func enabledBinding(_ idx: Int) -> Binding<Bool> {
        Binding(
            get: { rows[idx].enabled == true },
            set: {
                rows[idx].enabled = $0
                saveAll()
                // Rebuild QuotaService providers so the menu-bar popover picks
                // up the enable/disable immediately. The sidebar checkbox already
                // posts these; the detail-header toggle was missing them, so
                // enabling a provider here didn't show it in the popover until
                // an app restart.
                NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
            }
        )
    }

    func labelBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { rows[idx].accountLabel ?? "" },
            set: {
                rows[idx].accountLabel = $0.isEmpty ? nil : $0
                saveAll()
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            }
        )
    }

    func status(for id: String) -> ProviderStatus? {
        quota.statuses.first { $0.id == id }
    }

    func displayName(for row: BirdNionConfigStore.Provider) -> String {
        switch row.id {
        case "codex": "Codex"
        case "minimax": "MiniMax"
        case "hapo": row.displayName ?? "Hapo Hub"
        case "claude": "Claude"
        case "openrouter": "OpenRouter"
        case "deepseek": "DeepSeek"
        case "zai": "z.ai"
        case "elevenlabs": "ElevenLabs"
        case "deepgram": "Deepgram"
        case "groq": "Groq"
        case "grok": "Grok"
        case "openai": "OpenAI"
        case "ollama": "Ollama"
        case "copilot": "Copilot"
        case "kilo": "Kilo"
        case "commandcode": "Command Code"
        case "mimo": "Xiaomi MiMo"
        case "alibaba": "Alibaba / Qwen"
        case "cursor": "Cursor"
        case "gemini": "Gemini"
        case "kiro": "Kiro"
        case "opencode": "OpenCode"
        case "opencodego": "OpenCode Go"
        case "antigravity": "Antigravity"
        case "bedrock": "AWS Bedrock"
        case "freemodel": "FreeModel"
        case "hiyo": "Hiyo"
        default: row.displayName ?? row.id
        }
    }

    func statusSubtitle(for row: BirdNionConfigStore.Provider) -> String {
        if row.enabled != true { return L10n.t("provider.disabled", language) }
        guard let s = status(for: row.id) else { return L10n.t("provider.notLoaded", language) }
        if let err = s.error, !err.isEmpty {
            // Show the classified remediation hint instead of the raw error —
            // the raw string stays reachable via the row tooltip
            // (`statusSubtitleDetail`) and the detail pane.
            return L10n.f("provider.errorPrefix", language,
                          truncated(classifiedMessage(for: err), max: 32))
        }
        if let first = s.windows.first {
            return L10n.f("provider.remaining", language, first.remainingPct)
        }
        return L10n.t("provider.loading", language)
    }

    /// Actionable, localized message for a raw provider error: classify into
    /// a `ProviderErrorKind` and resolve its remediation hint. Single seam
    /// shared by the sidebar subtitle and the detail grid (R2.1/R2.2).
    func classifiedMessage(for rawError: String) -> String {
        let kind = classify(rawError: rawError) ?? .unknown
        return L10n.t(kind.hintKey, language)
    }

    /// Full error message for the sidebar row's `.help()` tooltip. Hover
    /// the row to see the entire message — useful when the truncated pill
    /// cuts off at "Lỗi: cookie is miss…".
    func statusSubtitleDetail(for row: BirdNionConfigStore.Provider) -> String? {
        guard row.enabled == true,
              let err = status(for: row.id)?.error,
              !err.isEmpty else { return nil }
        return L10n.providerText(err, preference: language)
    }

    /// Truncate `s` to `max` characters with an ellipsis suffix when it
    /// exceeds the limit. Pure string helper.
    func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// Header subtitle: prefix the CLI version when known (Codex), e.g.
    /// "codex-cli 0.140.0 • 2 giây trước".
    func headerSubtitle(for row: BirdNionConfigStore.Provider) -> String {
        // While a refresh is running, surface it here too (the popover header
        // does the same) so the user sees the click took effect.
        if quota.isRefreshing {
            return L10n.t("popover.updating", language)
        }
        let updated = updatedSubtitle(for: row.id)
        if let version = status(for: row.id)?.version, !version.isEmpty {
            return "\(version) • \(updated)"
        }
        return updated
    }

    func updatedSubtitle(for id: String) -> String {
        guard let s = status(for: id) else { return L10n.t("provider.notLoaded", language) }
        return L10n.relativeUpdated(from: s.lastUpdated, preference: language)
    }

    func codexLoginStatus() -> String {
        guard let creds = try? CodexAuthStore.load() else {
            return L10n.languageCode(language) == "vi" ? "Chưa đăng nhập" : "Not signed in"
        }
        if let email = CodexAuthStore.emailFromIDToken(creds.idToken) {
            return L10n.languageCode(language) == "vi" ? "Đã đăng nhập: \(email)" : "Signed in: \(email)"
        }
        return L10n.languageCode(language) == "vi" ? "Đã đăng nhập" : "Signed in"
    }

    func saveAll() {
        // Persist the whole row array back to BirdNionConfigStore. Single-row
        // upsert preserves the old on-disk order, but drag-reorder needs the
        // current array order written as-is.
        let persistedRows = rows.map { row -> BirdNionConfigStore.Provider in
            var copy = row
            if copy.id == "hapo" {
                copy.baseURL = nil
            }
            // Credential guard: TokenField (and other panes) write apiKey /
            // secretKey straight to disk, so a `rows` snapshot loaded before
            // that save carries nil and this wholesale write would wipe the
            // stored credential. No UI path clears a credential through
            // `rows`, so nil here always means "stale", never "remove".
            if copy.apiKey == nil || copy.secretKey == nil {
                let disk = BirdNionConfigStore.provider(id: copy.id)
                copy.apiKey = copy.apiKey ?? disk?.apiKey
                copy.secretKey = copy.secretKey ?? disk?.secretKey
            }
            return copy
        }
        do {
            try BirdNionConfigStore.saveProviders(persistedRows)
            for row in persistedRows where row.enabled != true {
                quota.remove(id: row.id)
            }
        } catch {
            // Non-fatal: surfaced indirectly through the live status.
        }
    }
}

// MARK: - Brand logo

/// Real brand logo per provider id, falling back to a SF Symbol when no
/// bundled asset matches. Mirrors `QuotaPanel.providerLogoView`.
struct ProviderLogoView: View {
    let id: String
    let tint: Color?

    init(id: String, tint: Color? = nil) {
        self.id = id
        self.tint = tint
    }

    var body: some View {
        switch id {
        case "minimax":
            logo("MiniMaxLogo")
        case "hapo":
            logo("HapoLogo")
        case "codex":
            logo("CodexLogo", brand: VocabbyTheme.codex)
        case "openrouter":
            logo("OpenRouterLogo", brand: VocabbyTheme.openRouter)
        case "deepseek":
            logo("DeepSeekLogo", brand: VocabbyTheme.deepSeek)
        case "zai":
            logo("ZaiLogo", brand: VocabbyTheme.zai)
        case "claude":
            logo("ClaudeLogo", brand: VocabbyTheme.claude)
        case "elevenlabs":
            logo("ElevenLabsLogo", brand: VocabbyTheme.elevenLabs)
        case "deepgram":
            logo("DeepgramLogo", brand: VocabbyTheme.deepgram)
        case "groq":
            logo("GroqLogo", brand: VocabbyTheme.groq)
        case "grok":
            logo("GrokLogo", brand: VocabbyTheme.grok)
        case "openai":
            logo("CodexLogo", brand: VocabbyTheme.openAI)
        case "ollama":
            logo("OllamaLogo", brand: VocabbyTheme.ollama)
        case "copilot":
            logo("CopilotLogo", brand: VocabbyTheme.copilot)
        case "kilo":
            logo("KiloLogo", brand: VocabbyTheme.kilo)
        case "commandcode":
            logo("CommandCodeLogo", brand: VocabbyTheme.commandCode)
        case "freemodel":
            logo("FreemodelLogo", brand: VocabbyTheme.freemodel)
        case "mimo":
            logo("MiMoLogo", brand: VocabbyTheme.mimo)
        case "alibaba":
            logo("AlibabaLogo", brand: VocabbyTheme.alibaba)
        case "cursor":
            logo("CursorLogo", brand: VocabbyTheme.cursor)
        case "gemini":
            logo("GeminiLogo", brand: VocabbyTheme.gemini)
        case "kiro":
            logo("KiroLogo", brand: VocabbyTheme.kiro)
        case "opencode":
            logo("OpenCodeLogo", brand: VocabbyTheme.openCode)
        case "opencodego":
            logo("OpenCodeGoLogo", brand: VocabbyTheme.openCode)
        case "antigravity":
            logo("AntigravityLogo", brand: VocabbyTheme.antigravity)
        case "bedrock":
            logo("BedrockLogo", brand: VocabbyTheme.bedrock)
        case "hiyo":
            logo("HiyoLogo", brand: VocabbyTheme.hiyo)
        default:
            Image(systemName: "circle.dotted")
                .resizable()
                .foregroundStyle(tint ?? SettingsTheme.secondary)
        }
    }

    @ViewBuilder
    func logo(_ name: String, brand: Color? = nil) -> some View {
        if let tint {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(tint)
        } else if let brand {
            Image(name)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(brand)
        } else {
            Image(name)
                .resizable()
                .interpolation(.high)
        }
    }
}

// MARK: - Token field

/// Secure token entry + save button for providers that authenticate with a
/// bearer token (everything except zero-config Codex).
struct TokenField: View {
    @EnvironmentObject var settings: SettingsStore

    let providerID: String
    let onSaved: () -> Void

    @State var token = ""
    @State var banner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("provider.token", settings.appLanguage))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            HStack(spacing: 8) {
                SecureField(L10n.t("provider.tokenPlaceholder", settings.appLanguage), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Button(L10n.t("provider.save", settings.appLanguage)) {
                    guard !token.isEmpty else { return }
                    do {
                        // Save to BirdNionConfigStore (the single source of
                        // truth after the 2026-06-25 storage refactor). The
                        // existing provider entry is updated in-place — we
                        // keep the user's earlier choices for enabled /
                        // accountLabel / provider-specific metadata and only
                        // swap the apiKey.
                        var entry = BirdNionConfigStore.provider(id: providerID)
                            ?? BirdNionConfigStore.Provider(id: providerID)
                        entry.apiKey = token
                        if providerID == "hapo" {
                            entry.baseURL = nil
                        }
                        try BirdNionConfigStore.save(entry)
                        token = ""
                        banner = L10n.t("provider.savedSettings", settings.appLanguage)
                        onSaved()
                    } catch {
                        banner = L10n.f("provider.saveError", settings.appLanguage, error.localizedDescription)
                    }
                }
                .controlSize(.small)
                .disabled(token.isEmpty)
            }
            if let banner {
                Text(banner)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quota warning card

struct SettingsCheckboxGlyph: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOn ? SettingsTheme.accent : SettingsTheme.tertiary)
            .frame(width: 16, height: 22)
    }
}

/// Per-provider quota-warning thresholds. Each window (session/weekly) inherits
/// the global thresholds unless "Customize" is on, mirroring CodexBar's panel.
/// Overrides are persisted via `QuotaWarnConfig` (UserDefaults).
struct QuotaWarningCard: View {
    @EnvironmentObject var settings: SettingsStore

    let providerID: String

    @State var sessionCustom = false
    @State var weeklyCustom = false
    @State var sessionLevels: [Int] = [50, 20]
    @State var weeklyLevels: [Int] = [50, 20]

    var body: some View {
        SettingsCard(
            header: L10n.t("settings.section.quotaWarnings", settings.appLanguage),
            footer: LocalizedStringKey(L10n.t("provider.quotaWarningsFooter", settings.appLanguage))
        ) {
            windowRow(title: L10n.t("provider.sessionWindow", settings.appLanguage), window: "session",
                      custom: $sessionCustom, levels: $sessionLevels)
            SettingsRowDivider()
            windowRow(title: L10n.t("provider.weekWindow", settings.appLanguage), window: "weekly",
                      custom: $weeklyCustom, levels: $weeklyLevels)
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    func windowRow(title: String, window: String,
                           custom: Binding<Bool>, levels: Binding<[Int]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let nextValue = !custom.wrappedValue
                custom.wrappedValue = nextValue
                QuotaWarnConfig.setOverride(provider: providerID, window: window,
                                            thresholds: nextValue ? levels.wrappedValue : nil)
            } label: {
                HStack(spacing: 8) {
                    SettingsCheckboxGlyph(isOn: custom.wrappedValue)
                    Text(L10n.f("provider.customThresholds", settings.appLanguage, title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointingHandCursor()

            if custom.wrappedValue {
                HStack(spacing: 16) {
                    levelStepper(L10n.t("provider.warning", settings.appLanguage),
                                 levels: levels, index: 0, window: window)
                    levelStepper(L10n.t("provider.critical", settings.appLanguage),
                                 levels: levels, index: 1, window: window)
                }
            } else {
                let inherited = QuotaWarnConfig.globalThresholds.map { "\($0)%" }.joined(separator: ", ")
                Text(L10n.f("provider.inherited", settings.appLanguage, inherited))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func levelStepper(_ label: String, levels: Binding<[Int]>, index: Int, window: String) -> some View {
        Stepper(value: Binding(
            get: { levels.wrappedValue[index] },
            set: { value in
                var arr = levels.wrappedValue
                arr[index] = value
                levels.wrappedValue = arr
                QuotaWarnConfig.setOverride(provider: providerID, window: window, thresholds: arr)
            }
        ), in: 1...100, step: 5) {
            Text("\(label): \(levels.wrappedValue[index])%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(SettingsTheme.primary)
        }
        .fixedSize()
    }

    func load() {
        sessionCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "session")
        weeklyCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "weekly")
        sessionLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "session"))
        weeklyLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "weekly"))
    }

    /// Ensure exactly two levels for the two steppers.
    func padded(_ values: [Int]) -> [Int] {
        var x = values
        while x.count < 2 { x.append(x.last ?? 20) }
        return Array(x.prefix(2))
    }
}

// MARK: - Codex accounts card

/// Multi-account management for Codex. The system account (~/.codex) is shown
// MARK: - ElevenLabs multi-key card

/// Settings card for managing multiple ElevenLabs API keys — add / switch /
/// remove. Secrets live in `elevenlabs-keys.json`; the active id is in
/// UserDefaults (`activeElevenLabsKey`).
struct ElevenLabsKeysCard: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

    @State var keys: [ElevenLabsKey] = []
    @State var activeID: String?
    @State var newKey = ""
    @State var newLabel = ""
    @State var errorText: String?
    @State var busy = false

    var body: some View {
        SettingsCard(
            header: L10n.t("elevenlabs.keysLabel", settings.appLanguage),
            footer: LocalizedStringKey(L10n.t("elevenlabs.keysFooter", settings.appLanguage))
        ) {
            if keys.isEmpty {
                Text(L10n.t("elevenlabs.keysEmpty", settings.appLanguage))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                SettingsRowDivider()
            }
            ForEach(keys) { key in
                keyRow(key)
                SettingsRowDivider()
            }
            addRow
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.critical)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .birdnionElevenLabsKeysChanged)) { _ in
            reload()
        }
    }

    func displayName(_ key: ElevenLabsKey) -> String {
        if let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return key.preview
    }

    func keyRow(_ key: ElevenLabsKey) -> some View {
        let isActive = key.id == activeID
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.secondary)
                .onTapGesture { switchTo(key) }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(key))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(key.preview + "…")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(SettingsTheme.secondary)
            }

            Spacer(minLength: 6)

            if isActive {
                Text(L10n.t("elevenlabs.activeBadge", settings.appLanguage))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
            } else {
                Button(L10n.t("elevenlabs.switchKey", settings.appLanguage)) {
                    switchTo(key)
                }
                .controlSize(.small)
                .disabled(busy)
            }

            Button(role: .destructive) {
                removeKey(key)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(L10n.t("elevenlabs.keyPlaceholder", settings.appLanguage), text: $newKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
            HStack(spacing: 8) {
                TextField(L10n.t("elevenlabs.labelPlaceholder", settings.appLanguage), text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(L10n.t("elevenlabs.addKey", settings.appLanguage)) {
                    addKey()
                }
                .controlSize(.small)
                .disabled(busy || newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func reload() {
        keys = ElevenLabsKeyStore.allKeys()
        activeID = ElevenLabsKeyStore.activeID()
    }

    func switchTo(_ key: ElevenLabsKey) {
        // Store posts keys-changed + birdnionRefresh (force fetch).
        ElevenLabsKeyStore.setActive(key.id)
        reload()
        errorText = nil
    }

    func addKey() {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            // Store notifies Settings + popover to re-list immediately.
            _ = try ElevenLabsKeyStore.add(apiKey: newKey, label: newLabel.isEmpty ? nil : newLabel)
            newKey = ""
            newLabel = ""
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func removeKey(_ key: ElevenLabsKey) {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try ElevenLabsKeyStore.remove(key.id)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Hiyo multi-key card

/// Settings card for managing multiple Hiyo API keys — add / switch /
/// remove. Secrets live in `hiyo-keys.json`; the active id is in
/// UserDefaults (`activeHiyoKey`).
struct HiyoKeysCard: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

    @State var keys: [HiyoKey] = []
    @State var activeID: String?
    @State var newKey = ""
    @State var newLabel = ""
    @State var errorText: String?
    @State var busy = false

    var body: some View {
        SettingsCard(
            header: L10n.t("hiyo.keysLabel", settings.appLanguage),
            footer: LocalizedStringKey(L10n.t("hiyo.keysFooter", settings.appLanguage))
        ) {
            if keys.isEmpty {
                Text(L10n.t("hiyo.keysEmpty", settings.appLanguage))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                SettingsRowDivider()
            }
            ForEach(keys) { key in
                keyRow(key)
                SettingsRowDivider()
            }
            addRow
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.critical)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .birdnionHiyoKeysChanged)) { _ in
            reload()
        }
    }

    func displayName(_ key: HiyoKey) -> String {
        if let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return key.preview
    }

    func keyRow(_ key: HiyoKey) -> some View {
        let isActive = key.id == activeID
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.secondary)
                .onTapGesture { switchTo(key) }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(key))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(key.preview + "…")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(SettingsTheme.secondary)
            }

            Spacer(minLength: 6)

            if isActive {
                Text(L10n.t("hiyo.activeBadge", settings.appLanguage))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
            } else {
                Button(L10n.t("hiyo.switchKey", settings.appLanguage)) {
                    switchTo(key)
                }
                .controlSize(.small)
                .disabled(busy)
            }

            Button(role: .destructive) {
                removeKey(key)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(L10n.t("hiyo.keyPlaceholder", settings.appLanguage), text: $newKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
            HStack(spacing: 8) {
                TextField(L10n.t("hiyo.labelPlaceholder", settings.appLanguage), text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(L10n.t("hiyo.addKey", settings.appLanguage)) {
                    addKey()
                }
                .controlSize(.small)
                .disabled(busy || newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func reload() {
        keys = HiyoKeyStore.allKeys()
        activeID = HiyoKeyStore.activeID()
    }

    func switchTo(_ key: HiyoKey) {
        // Store posts keys-changed + birdnionRefresh (force fetch).
        HiyoKeyStore.setActive(key.id)
        reload()
        errorText = nil
    }

    func addKey() {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            // Store notifies Settings + popover to re-list immediately.
            _ = try HiyoKeyStore.add(apiKey: newKey, label: newLabel.isEmpty ? nil : newLabel)
            newKey = ""
            newLabel = ""
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func removeKey(_ key: HiyoKey) {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try HiyoKeyStore.remove(key.id)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// read-only; managed accounts live in their own CODEX_HOME and are added via
/// `codex login` in the browser. Selecting one switches which login the
/// provider reads.
struct CodexAccountsCard: View {
    @EnvironmentObject var settings: SettingsStore

    @State var accounts: [CodexAccount] = []
    @State var activeID = "system"
    @State var busy = false
    @State var errorText: String?
    @State var accountPendingRemoval: CodexAccount?
    @State var showingRemoveConfirmation = false

    var body: some View {
        SettingsCard(
            header: L10n.t("settings.section.account", settings.appLanguage),
            footer: LocalizedStringKey(L10n.t("provider.accountsFooter", settings.appLanguage))
        ) {
            ForEach(accounts) { account in
                accountRow(account)
                SettingsRowDivider()
            }
            addRow
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            removeConfirmationTitle,
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(removeConfirmationButtonTitle, role: .destructive) {
                if let accountPendingRemoval {
                    remove(accountPendingRemoval)
                }
            }
            Button(L10n.t("ccx.pasteJSON.cancel", settings.appLanguage), role: .cancel) {}
        } message: {
            Text(removeConfirmationMessage)
        }
    }

    func accountRow(_ account: CodexAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.id == activeID ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(account.id == activeID ? SettingsTheme.accent : SettingsTheme.secondary)
                .onTapGesture {
                    CodexAccountStore.setActive(account.id)
                    activeID = account.id
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.email ?? (account.isSystem
                                       ? L10n.t("provider.systemAccount", settings.appLanguage)
                                       : L10n.t("provider.accountGeneric", settings.appLanguage)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(account.isSystem
                     ? L10n.t("provider.systemManaged", settings.appLanguage)
                     : L10n.t("provider.appManaged", settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.secondary)
            }

            Spacer(minLength: 6)

            Button(L10n.t("provider.reauth", settings.appLanguage)) { Task { await reauth(account.id) } }
                .controlSize(.small)
                .disabled(busy)

            if account.isSystem {
                // Copy the current ~/.codex login into a managed account so it
                // survives a later system re-login.
                Button(L10n.t("provider.saveManaged", settings.appLanguage)) { promote() }
                    .controlSize(.small)
                    .disabled(busy || account.email == nil)
            }

            if canRemove(account) {
                Button(role: .destructive) {
                    confirmRemove(account)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    var addRow: some View {
        HStack(spacing: 8) {
            Button { Task { await add() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text(L10n.t("provider.addAccount", settings.appLanguage))
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor(enabled: !busy)
            .disabled(busy)

            if busy {
                ProgressView().controlSize(.small)
                Text(L10n.t("provider.waitingLogin", settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.secondary)
            }

            Spacer(minLength: 6)

            if let errorText {
                Text(L10n.providerText(errorText, preference: settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.warning)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func reload() {
        accounts = CodexAccountStore.allAccounts()
        activeID = CodexAccountStore.activeID()
        if !accounts.contains(where: { $0.id == activeID }), let first = accounts.first {
            CodexAccountStore.setActive(first.id)
            activeID = first.id
        }
    }

    func canRemove(_ account: CodexAccount) -> Bool {
        !account.isSystem || accounts.count > 1
    }

    func accountLabel(_ account: CodexAccount) -> String {
        account.email ?? L10n.t(account.isSystem ? "provider.systemAccount" : "provider.accountGeneric",
                                settings.appLanguage)
    }

    var removeConfirmationTitle: String {
        guard let accountPendingRemoval else {
            return L10n.t("provider.removeAccount", settings.appLanguage)
        }
        return L10n.f("provider.removeAccountTitle", settings.appLanguage, accountLabel(accountPendingRemoval))
    }

    var removeConfirmationButtonTitle: String {
        guard let accountPendingRemoval, accountPendingRemoval.isSystem else {
            return L10n.t("provider.removeAccount", settings.appLanguage)
        }
        return L10n.t("provider.removeSystemAccount", settings.appLanguage)
    }

    var removeConfirmationMessage: String {
        guard let accountPendingRemoval else { return "" }
        return L10n.t(accountPendingRemoval.isSystem
                     ? "provider.removeSystemAccountMessage"
                     : "provider.removeAccountMessage",
                     settings.appLanguage)
    }

    func confirmRemove(_ account: CodexAccount) {
        accountPendingRemoval = account
        showingRemoveConfirmation = true
    }

    func add() async {
        busy = true; errorText = nil
        defer { busy = false }
        do { _ = try await CodexAccountStore.addAccount(); reload() }
        catch { errorText = error.localizedDescription }
    }

    func reauth(_ id: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do { try await CodexAccountStore.reauth(id: id); reload() }
        catch { errorText = error.localizedDescription }
    }

    func promote() {
        errorText = nil
        do { _ = try CodexAccountStore.promoteSystem(); reload() }
        catch { errorText = error.localizedDescription }
    }

    func remove(_ account: CodexAccount) {
        errorText = nil
        do {
            try CodexAccountStore.remove(account: account, from: accounts)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
        accountPendingRemoval = nil
    }
}

// MARK: - Codex auto-prime card

/// Opt-in schedule that auto-activates the Codex 5h rate-limit window (via a
/// trivial `codex exec` request) at a fixed time each day, so the reset cycle
/// aligns with the user's working hours. The actual decision/execution lives
/// in `CodexQuotaPrimer` (`CodexAccountStore.swift`); this card only edits the
/// three `SettingsStore` `@AppStorage` keys it reads.
struct CodexAutoPrimeCard: View {
    @EnvironmentObject var settings: SettingsStore

    /// Bridges the `Int` minutes-since-midnight setting to a `DatePicker`'s
    /// `Date`. The calendar day is irrelevant — only hour/minute are read.
    var timeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = settings.codexAutoPrimeMinutes / 60
                c.minute = settings.codexAutoPrimeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings.codexAutoPrimeMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    var body: some View {
        SettingsCard(header: L10n.t("settings.codex.autoPrime.title", settings.appLanguage)) {
            SettingsLabeledRow(
                title: L10n.t("settings.codex.autoPrime.toggle", settings.appLanguage),
                subtitle: L10n.t("settings.codex.autoPrime.toggleSubtitle", settings.appLanguage)
            ) {
                Toggle("", isOn: $settings.codexAutoPrimeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRowDivider()

            SettingsLabeledRow(
                title: L10n.t("settings.codex.autoPrime.time", settings.appLanguage),
                subtitle: L10n.t("settings.codex.autoPrime.timeSubtitle", settings.appLanguage)
            ) {
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!settings.codexAutoPrimeEnabled)
            }
        }
    }
}
