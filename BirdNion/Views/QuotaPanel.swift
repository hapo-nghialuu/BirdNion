import SwiftUI
import AppKit

// MARK: - Quota Overview (CodexBar-style)

/// Menu-bar popover body:
///   - Top: BirdNion identity + manual refresh.
///   - Provider chips with lowest remaining quota.
///   - Selected provider metadata and quota summary/details.
///   - Bottom: app-level actions.
struct QuotaOverview: View {
    @EnvironmentObject var quota: QuotaService
    /// Persisted so re-opening the popover lands on the tab the user last
    /// chose — either the "all" pseudo-tab or a provider id.
    private static let selectedTabKey = "popover.selectedTab"
    @State private var selectedProviderId: String? =
        UserDefaults.standard.string(forKey: QuotaOverview.selectedTabKey)
    /// Lazy-scanned Claude usage report (per-day buckets + top model) for
    /// the 30-day chart in the popover. Only re-scanned when the user
    /// opens Claude's tab; cached 5 min by `ClaudeCostScanner` itself.
    @State private var claudeReport: ClaudeUsageReport?
    @State private var claudeReportTaskId: String?
    /// Lazy-scanned Codex usage report (per-day cost buckets + top model) for
    /// the 30-day chart. Only scanned when the user opens Codex's tab; cached
    /// 5 min by `CodexCostScanner` itself.
    @State private var codexReport: CodexUsageReport?
    @State private var codexReportTaskId: String?
    /// Lazy-scanned Grok usage report from `~/.grok/sessions/**/signals.json`.
    @State private var grokReport: GrokUsageReport?
    @State private var grokReportTaskId: String?
    /// Lazy-scanned Kiro usage report from local kiro-cli SQLite sessions.
    @State private var kiroReport: KiroUsageReport?
    @State private var kiroReportTaskId: String?
    @State private var claudeCodeTargetRevision = 0

    var body: some View {
        ZStack {
            VocabbyTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 7) {
                if quota.displayStatuses.isEmpty {
                    // First-run / opt-in state. The bird logo + title + body
                    // + prominent Settings button are all contained in
                    // `EmptyProvidersState` (single fixed-size subview) so
                    // SwiftUI's hosting-view autosize doesn't re-trigger
                    // the NSISEngine recursion documented in
                    // `SettingsSceneRoot`. All interactive elements are
                    // inside one stable identity; the icon is decorative
                    // (`.accessibilityHidden`) so VoiceOver doesn't trip
                    // on the hover state.
                    EmptyProvidersState()
                        .frame(maxWidth: .infinity)
                } else {
                    BirdNionHeader(isRefreshing: quota.isRefreshing)
                    let selected = effectiveSelectedId()
                    ProviderTabs(
                        providers: quota.displayStatuses,
                        selectedId: Binding(
                            get: { selected },
                            set: {
                                selectedProviderId = $0
                                UserDefaults.standard.set($0, forKey: Self.selectedTabKey)
                            }
                        ),
                        showAllTab: hasLocalCostSources
                    )
                    if selected == "all" {
                        // Combined Claude CLI + Codex + Grok overview (no real
                        // ProviderStatus behind it — reports only).
                        VStack(alignment: .leading, spacing: 8) {
                            AllUsageOverview(
                                claude: claudeReport,
                                codex: codexReport,
                                grok: grokReport,
                                claudeEnabled: quota.displayStatuses.contains { $0.id == "claude" },
                                codexEnabled: quota.displayStatuses.contains { $0.id == "codex" },
                                grokEnabled: quota.displayStatuses.contains { $0.id == "grok" })
                        }
                    } else if let s = quota.displayStatuses.first(where: { $0.id == selected })
                        ?? quota.displayStatuses.first {
                        VStack(alignment: .leading, spacing: 8) {
                            ProviderHeaderCard(status: s, isPlaceholder: s.windows.isEmpty && s.error == nil)
                            ProviderCard(status: s)
                            // Claude Code backend: round quick-apply / setup button,
                            // shown only for providers with a key that can back Claude Code.
                            if ClaudeCodeQuickApplyButton.shouldShow(providerID: s.id) {
                                ClaudeCodeQuickApplyButton(providerID: s.id)
                                    .id("\(s.id)-\(claudeCodeTargetRevision)")
                            }
                            // Claude-specific: 30-day chart + top-model line.
                            // Only rendered for the Claude tab so other providers
                            // don't pull in the local session scan.
                            if s.id == "claude", let report = claudeReport,
                               !report.isEmpty {
                                ClaudeUsageChartCard(report: report)
                            }
                            // Claude Admin API org dashboard (source = .api).
                            if s.id == "claude", let admin = s.claudeAdminUsage,
                               !admin.daily.isEmpty {
                                ClaudeAdminUsageChartCard(snapshot: admin)
                            }
                            // Codex-specific: 30-day cost chart + top-model line,
                            // scanned only when the Codex tab is open.
                            if s.id == "codex", let report = codexReport,
                               !report.isEmpty {
                                CodexUsageChartCard(report: report)
                            }
                            // Codex-specific: account list (click to reveal) +
                            // CLI switch. Below the chart per user preference.
                            if s.id == "codex" {
                                CodexAccountsPopoverSection()
                            }
                            // FreeModel: account switcher (per-browser sessions
                            // + pasted cookies), same collapsed-card pattern.
                            if s.id == "freemodel" {
                                FreemodelAccountsPopoverSection()
                            }
                            // ElevenLabs: multi API-key switcher (same card pattern).
                            if s.id == "elevenlabs" {
                                ElevenLabsKeysPopoverSection()
                            }
                            // Grok Build: 30-day cost chart from local
                            // ~/.grok/sessions/**/signals.json (parity with Codex).
                            if s.id == "grok", let report = grokReport,
                               !report.isEmpty {
                                GrokUsageChartCard(report: report)
                            }
                            // Kiro: 30-day usage chart from local kiro-cli
                            // sessions (~/.kiro/sessions sidecars with real
                            // metered credits + legacy SQLite/archives).
                            if s.id == "kiro", let report = kiroReport,
                               !report.isEmpty {
                                KiroUsageChartCard(report: report)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                ActionsList()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            if selectedProviderId == nil,
               let first = quota.displayStatuses.first {
                selectedProviderId = first.id
            }
        }
        .onChange(of: selectedProviderId) { id in
            triggerReportsIfNeeded(providerId: id ?? "")
        }
        .onChange(of: quota.displayStatuses.map(\.id)) { ids in
            // "all" stays valid as long as one local-cost source is enabled;
            // anything else must still be a live provider id.
            let selectionValid: Bool
            switch selectedProviderId {
            case "all":
                selectionValid = ids.contains("claude") || ids.contains("codex") || ids.contains("grok")
            case let sel?: selectionValid = ids.contains(sel)
            case nil: selectionValid = false
            }
            if !selectionValid {
                selectedProviderId = ids.first
            }
            // (Re)kick the scans for the now-effective tab regardless: on
            // first open the provider list can arrive AFTER the `.task`
            // trigger ran against an empty list — the guards inside the
            // trigger functions then skipped every scan and the All tab sat
            // on its skeleton until the user switched tabs. Re-running here
            // is cheap (scanners cache for 5 min).
            triggerReportsIfNeeded(providerId: effectiveSelectedId())
        }
        .task {
            triggerReportsIfNeeded(providerId: selectedProviderId ?? effectiveSelectedId())
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeCodeTargetChanged)) { _ in
            claudeCodeTargetRevision += 1
        }
    }

    /// Kick off whichever provider-specific 30-day scan matches the open tab.
    private func triggerReportsIfNeeded(providerId: String) {
        triggerClaudeReportIfNeeded(providerId: providerId)
        triggerCodexReportIfNeeded(providerId: providerId)
        triggerGrokReportIfNeeded(providerId: providerId)
        triggerKiroReportIfNeeded(providerId: providerId)
    }

    /// Trigger the Claude 30-day scan only when the user actually views the
    /// Claude tab. The scanner is cached internally so re-opening Claude
    /// within 5 min is instant. Keep the previous report in memory when the
    /// user switches away so the chart is still visible while the next scan
    /// refreshes it.
    private func triggerClaudeReportIfNeeded(providerId: String) {
        // The All tab needs the Claude scan too — but only when the Claude
        // provider is actually enabled (disabled sources stay out of the mix).
        let wantsClaude = providerId == "claude"
            || (providerId == "all"
                && quota.displayStatuses.contains(where: { $0.id == "claude" }))
        guard wantsClaude else { return }
        let taskId = UUID().uuidString
        claudeReportTaskId = taskId
        let needsSeed = claudeReport == nil
        Task {
            // Seed instantly from persisted history; the live scan overwrites.
            if needsSeed, let seed = await ClaudeCostScanner.seededReport() {
                await MainActor.run {
                    guard claudeReportTaskId == taskId, claudeReport == nil else { return }
                    claudeReport = seed
                }
            }
            let report = await ClaudeCostScanner.usageReport()
            await MainActor.run {
                guard claudeReportTaskId == taskId else { return }
                claudeReport = report
            }
        }
    }

    /// Trigger the Codex 30-day scan only when the user views the Codex tab.
    /// Cached 5 min by `CodexCostScanner`; switching tabs cancels via taskId.
    private func triggerCodexReportIfNeeded(providerId: String) {
        let wantsCodex = providerId == "codex"
            || (providerId == "all"
                && quota.displayStatuses.contains(where: { $0.id == "codex" }))
        guard wantsCodex else {
            codexReport = nil
            return
        }
        let taskId = UUID().uuidString
        codexReportTaskId = taskId
        let needsSeed = codexReport == nil
        Task {
            // Seed instantly from persisted history; the live scan overwrites.
            if needsSeed, let seed = await CodexCostScanner.seededReport() {
                await MainActor.run {
                    guard codexReportTaskId == taskId, codexReport == nil else { return }
                    codexReport = seed
                }
            }
            let report = await CodexCostScanner.usageReport()
            await MainActor.run {
                guard codexReportTaskId == taskId else { return }
                codexReport = report
            }
        }
    }

    /// Trigger the Grok session-signal scan when the user views Grok or All.
    /// Cached 5 min by `GrokCostScanner`.
    private func triggerGrokReportIfNeeded(providerId: String) {
        let wantsGrok = providerId == "grok"
            || (providerId == "all"
                && quota.displayStatuses.contains(where: { $0.id == "grok" }))
        guard wantsGrok else { return }
        let taskId = UUID().uuidString
        grokReportTaskId = taskId
        let needsSeed = grokReport == nil
        Task {
            // Seed instantly from persisted history; the live scan overwrites.
            if needsSeed, let seed = await GrokCostScanner.seededReport() {
                await MainActor.run {
                    guard grokReportTaskId == taskId, grokReport == nil else { return }
                    grokReport = seed
                }
            }
            let report = await GrokCostScanner.usageReport()
            await MainActor.run {
                guard grokReportTaskId == taskId else { return }
                grokReport = report
            }
        }
    }

    /// Trigger the Kiro CLI session scan when the user views the Kiro tab.
    /// Cached 5 min by `KiroCostScanner`.
    private func triggerKiroReportIfNeeded(providerId: String) {
        guard providerId == "kiro" else { return }
        let taskId = UUID().uuidString
        kiroReportTaskId = taskId
        let needsSeed = kiroReport == nil
        Task {
            if needsSeed, let seed = await KiroCostScanner.seededReport() {
                await MainActor.run {
                    guard kiroReportTaskId == taskId, kiroReport == nil else { return }
                    kiroReport = seed
                }
            }
            let report = await KiroCostScanner.usageReport()
            await MainActor.run {
                guard kiroReportTaskId == taskId else { return }
                kiroReport = report
            }
        }
    }

    /// The All tab only exists when at least one local-cost source (Claude
    /// Code CLI or Codex) is enabled.
    private var hasLocalCostSources: Bool {
        quota.displayStatuses.contains { $0.id == "claude" || $0.id == "codex" || $0.id == "grok" }
    }

    private func effectiveSelectedId() -> String {
        if selectedProviderId == "all", hasLocalCostSources { return "all" }
        if let sel = selectedProviderId, sel != "all",
           quota.displayStatuses.contains(where: { $0.id == sel }) {
            return sel
        }
        return quota.displayStatuses.first?.id ?? ""
    }
}

// MARK: - App Header

struct BirdNionHeader: View {
    @EnvironmentObject var settings: SettingsStore

    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("BirdNion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(isRefreshing
                     ? L10n.t("popover.updating", settings.appLanguage)
                     : L10n.t("popover.ready", settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            } label: {
                ZStack {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.blue)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(L10n.t("popover.refresh", settings.appLanguage))
            .accessibilityLabel(L10n.t("popover.refresh", settings.appLanguage))
        }
    }
}

// MARK: - Provider Tabs

/// Native-feeling segmented provider selector with icon + provider name.
struct ProviderTabs: View {
    static let chipHeight: CGFloat = 30

    let providers: [ProviderStatus]
    @Binding var selectedId: String
    /// Renders the combined "All" pseudo-tab ahead of the provider chips.
    var showAllTab: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if showAllTab {
                    allChip
                    if !providers.isEmpty {
                        Divider()
                            .frame(height: 18)
                    }
                }
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    chip(for: provider)
                    if index < providers.count - 1 {
                        Divider()
                            .frame(height: 18)
                    }
                }
            }
            .background(VocabbyTheme.segment)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
        }
    }

    /// Combined-overview pseudo-tab (sentinel id "all") — no ProviderStatus
    /// behind it, so it renders its own chip instead of `chip(for:)`.
    /// Icon-only, like the provider chips; the name lives in the tooltip.
    private var allChip: some View {
        let active = selectedId == "all"
        return Button {
            selectedId = "all"
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? VocabbyTheme.blue : VocabbyTheme.secondary)
                .frame(width: 18, height: 18)
                .frame(minWidth: 40, minHeight: Self.chipHeight)
                .background(active ? VocabbyTheme.selectedSurface : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("All")
        .accessibilityLabel("All")
    }

    @ViewBuilder
    private func chip(for p: ProviderStatus) -> some View {
        let active = p.id == selectedId
        // Icon-only chip: the provider name moved into the tooltip /
        // accessibility label so the strip fits more providers.
        Button {
            selectedId = p.id
        } label: {
            ProviderLogoMark(id: p.id, tint: active ? VocabbyTheme.blue : VocabbyTheme.secondary)
                .frame(width: 18, height: 18)
                .frame(minWidth: 40, minHeight: Self.chipHeight)
                .background(active ? VocabbyTheme.selectedSurface : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())  // whole chip is the click target
        .help(p.displayName)
        .accessibilityLabel(p.displayName)
    }
}

/// Provider logo per provider id. Pass `tint` when the surrounding surface
/// needs a single app colour instead of per-provider brand colours.
struct ProviderLogoMark: View {
    let id: String
    let tint: Color?

    init(id: String, tint: Color? = nil) {
        self.id = id
        self.tint = tint
    }

    var body: some View {
        logo
            .aspectRatio(contentMode: .fit)
    }

    @ViewBuilder
    private var logo: some View {
        switch id {
        case "minimax":
            logo("MiniMaxLogo")
        case "codex":
            // Codex's SVG declares itself a template image so it can be
            // recoloured by .foregroundStyle(). The chip's parent stack
            // sometimes wins over the inherited tint, leaving the logo
            // rendered against the chip background as an empty disc.
            // Pass a fixed dark tint explicitly so the mark always shows.
            logo("CodexLogo", brand: VocabbyTheme.primary)
        case "hapo":
            logo("HapoLogo")
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
        default:
            Image(systemName: "circle.fill")
                .foregroundStyle(tint ?? VocabbyTheme.secondary)
        }
    }

    @ViewBuilder
    private func logo(_ name: String, brand: Color? = nil) -> some View {
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

enum ProviderStatusSummary {
    static func lowestWindow(_ status: ProviderStatus) -> QuotaWindow? {
        status.windows.min { $0.remainingPct < $1.remainingPct }
    }
}

// MARK: - Provider Header Card

/// Provider info card: brand mark + account metadata + menu-bar visibility.
struct ProviderHeaderCard: View {
    @EnvironmentObject var settings: SettingsStore

    let status: ProviderStatus
    /// True when this is a placeholder entry — `statuses` hasn't received
    /// real data for this provider yet. The card shows a spinner in the
    /// subtitle area so the user knows the card is loading, but the rest
    /// of the popover stays interactive.
    var isPlaceholder: Bool = false
    @EnvironmentObject var quota: QuotaService

    private var updatedAgo: String {
        L10n.relativeUpdated(from: status.lastUpdated, preference: settings.appLanguage)
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = status.accountLabel, !account.isEmpty {
            parts.append(account)
        }
        if let plan = planLabel {
            parts.append(L10n.providerText(plan, preference: settings.appLanguage))
        }
        if let source = status.sourceLabel, !source.isEmpty {
            parts.append(L10n.providerText(source, preference: settings.appLanguage))
        }
        parts.append(updatedAgo)
        return parts
    }

    private var planLabel: String? {
        if let name = status.planName, !name.isEmpty { return name }
        if let type = status.planType, !type.isEmpty { return type }
        switch status.id {
        case "minimax": return "Token Plan"
        case "hapo": return "Hapo AI Hub"
        default: return nil
        }
    }

    private var hasError: Bool { status.error != nil }

    /// Provider detail extras not surfaced as quota windows (Codex populates
    /// these): unlimited credits, CLI version, code-review %, manual-reset
    /// credits. Rendered as a dim second metadata line so they don't crowd the
    /// primary one. A finite Codex balance gets its own full-width strip below.
    private var detailParts: [String] {
        var parts: [String] = []
        if status.creditsUnlimited {
            parts.append("∞ credits")
        }
        if let v = status.version, !v.isEmpty { parts.append(v) }
        if let cr = status.codexWeb?.codeReviewRemainingPercent {
            parts.append("Code review \(cr)%")
        }
        if let rc = status.resetCreditsAvailable, rc > 0 {
            parts.append("\(rc) reset credits")
        }
        return parts
    }

    private var availableCodexCredits: Double? {
        guard status.id == "codex",
              !status.creditsUnlimited,
              let credits = status.creditsRemaining,
              credits.isFinite,
              credits > 0
        else {
            return nil
        }
        return credits
    }

    private func creditsText(_ credits: Double) -> String {
        credits.rounded() == credits
            ? String(Int(credits))
            : String(format: "%.2f", credits)
    }

    private func creditsAccessibilityLabel(_ credits: Double) -> String {
        let title = L10n.t("provider.creditsAvailable", settings.appLanguage)
        return title + ": " + creditsText(credits)
    }

    /// The Codex API exposes a balance but not a credit limit, so this is a
    /// balance strip rather than a percentage meter.
    private func availableCreditsStrip(_ credits: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 18, height: 18)
            Text(L10n.t("provider.creditsAvailable", settings.appLanguage))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)
            Spacer(minLength: 8)
            Text(creditsText(credits))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VocabbyTheme.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VocabbyTheme.blue.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(creditsAccessibilityLabel(credits))
    }

    /// Dot color for the provider service-status badge, driven by the
    /// statuspage severity ("none"/"minor"/"major"/"critical").
    private var serviceColor: Color {
        switch status.serviceStatusLevel {
        case "minor": return VocabbyTheme.warningFill
        case "major", "critical": return VocabbyTheme.critical
        default: return VocabbyTheme.success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                ProviderLogoMark(id: status.id, tint: VocabbyTheme.blue)
                    .frame(width: 24, height: 24)
                    .padding(5)
                    .background(VocabbyTheme.segment)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(VocabbyTheme.border, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(status.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                        if !isPlaceholder && quota.isRefreshing {
                            // Provider has last-known data; a refresh is in
                            // flight. Show a small inline spinner so the user
                            // knows the row is being updated, but keep the
                            // existing subtitle + quota windows visible.
                            ProgressView()
                                .controlSize(.small)
                                .tint(VocabbyTheme.blue)
                                .frame(width: 10, height: 10)
                            Text(L10n.t("popover.updating", settings.appLanguage).lowercased())
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                    }
                    HStack(spacing: 4) {
                        if isPlaceholder {
                            // First-time load for this provider — no previous
                            // data to show. Use a placeholder spinner so the
                            // popover makes clear which tab is still loading.
                            ProgressView()
                                .controlSize(.small)
                                .tint(VocabbyTheme.blue)
                                .frame(width: 12, height: 12)
                            Text(L10n.t("provider.loading", settings.appLanguage))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.secondary)
                        } else {
                            Text(metadataParts.joined(separator: " · "))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !isPlaceholder, let svc = status.serviceStatus, !svc.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(serviceColor).frame(width: 6, height: 6)
                            Text(L10n.providerText(svc, preference: settings.appLanguage))
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if !isPlaceholder, !detailParts.isEmpty {
                        Text(detailParts
                            .map { L10n.providerText($0, preference: settings.appLanguage) }
                            .joined(separator: " · "))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                MenuBarVisibilityToggle(providerId: status.id, hasError: hasError)
                    .id("menuBarVis.\(status.id)")  // force fresh @State per provider
            }
            if !isPlaceholder, let credits = availableCodexCredits {
                availableCreditsStrip(credits)
            }
        }
        // Padding is tighter than the standard vocabbyCard (12pt) so the
        // taller 48pt logo doesn't grow the card height.
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Provider Card + Window Row

/// Per-provider card: name + windows.
struct ProviderCard: View {
    @EnvironmentObject var settings: SettingsStore

    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let err = status.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(VocabbyTheme.critical)
                    Text(L10n.providerText(err, preference: settings.appLanguage))
                        .font(.system(size: 11))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(VocabbyTheme.criticalSurface.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(VocabbyTheme.critical.opacity(0.16), lineWidth: 1)
                )
            } else if status.windows.isEmpty {
                LoadingQuotaSkeleton()
            } else {
                QuotaSummaryStrip(status: status)
                Divider()
                    .overlay(VocabbyTheme.border)
                ForEach(status.windows) { win in
                    WindowRow(window: win, lastUpdated: status.lastUpdated)
                }
            }
        }
        .vocabbyCard()
    }
}

// MARK: - Codex accounts (popover)

/// Popover-native Codex account switcher: a compact "Accounts" row that
/// reveals the signed-in accounts on hover. Selecting one calls
/// `CodexAccountStore.setActive(id)`, which drives the existing
/// `.birdnionCodexAccountChanged` snapshot-then-refetch flow in
/// `QuotaService` so the quota card swaps to that account. Mirrors
/// `ProvidersPane.CodexAccountsCard` but scoped for the popover surface.
struct CodexAccountsPopoverSection: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var accounts: [CodexAccount] = []
    @State private var activeID = "system"
    @State private var cliID: String?
    @State private var revealed = false
    @State private var busy = false
    @State private var addAccountErrorText: String?
    @State private var accountActionErrorText: String?
    @State private var switchErrorText: String?
    @State private var accountPendingRemoval: CodexAccount?
    @State private var showingRemoveConfirmation = false

    var body: some View {
        // Click (not hover) toggles the account list — hover-reveal collapsed
        // the moment the pointer drifted off the card, which made the Switch
        // card unreachable and felt jumpy.
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if revealed {
                Divider()
                    .overlay(VocabbyTheme.border)
                    .padding(.vertical, 6)
                ForEach(accounts) { account in
                    accountRow(account)
                }
                if let accountActionErrorText {
                    Text(L10n.f("provider.removeAccountFailed", settings.appLanguage, accountActionErrorText))
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(2)
                        .padding(.vertical, 4)
                }
                addAccountRow
                switchRow
            }
        }
        .vocabbyCard()
        .overlay {
            if showingRemoveConfirmation, accountPendingRemoval != nil {
                removeConfirmationOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: showingRemoveConfirmation)
        .onAppear(perform: reload)
    }

    private var removeConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.42)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)

                VStack(spacing: 4) {
                    Text(removeConfirmationTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(removeConfirmationMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 7) {
                    Button(role: .destructive) {
                        if let accountPendingRemoval {
                            removeAccount(accountPendingRemoval)
                        }
                    } label: {
                        Text(removeConfirmationButtonTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.critical)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.26))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    Button {
                        dismissRemoveConfirmation()
                    } label: {
                        Text(L10n.t("ccx.pasteJSON.cancel", settings.appLanguage))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.26))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(16)
            .frame(width: 260)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 16, y: 6)
        }
    }

    private var collapsedRow: some View {
        // Mirrors the quick-apply card header: framed icon + title/subtitle,
        // so the collapsed state carries real info (which account's quota is
        // on screen) instead of a thin label with dead space.
        let lang = settings.appLanguage
        let active = accounts.first(where: { $0.id == activeID })
        let activeLabel = active?.email
            ?? L10n.t(active?.isSystem == true ? "provider.systemAccount" : "provider.accountGeneric", lang)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 30, height: 30)
                .background(VocabbyTheme.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("popover.accounts", lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(activeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(accounts.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(VocabbyTheme.segment))
            Image(systemName: revealed ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        // No extra padding: `.vocabbyCard()` already pads the whole section
        // by 10pt — stacking row padding on top was doubling the whitespace.
        .contentShape(Rectangle())
        .onTapGesture {
            revealed.toggle()
            if revealed { reload() }
        }
        .pointingHandCursor()
    }

    private func accountRow(_ account: CodexAccount) -> some View {
        let quota = accountQuotaBadge(for: account)
        return HStack(spacing: 10) {
            Image(systemName: account.id == activeID ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(account.id == activeID ? VocabbyTheme.blue : VocabbyTheme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email ?? (account.isSystem
                                       ? L10n.t("provider.systemAccount", settings.appLanguage)
                                       : L10n.t("provider.accountGeneric", settings.appLanguage)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                Text(account.isSystem
                     ? L10n.t("provider.systemManaged", settings.appLanguage)
                     : L10n.t("provider.appManaged", settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 6)
            Text(quota.text)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(quota.color)
                .lineLimit(1)
                .accessibilityLabel(quota.help)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 34)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(quota.surface)
                )
                .help(quota.help)
            if isCLIIdentity(account) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.t("popover.accountSelected", settings.appLanguage))
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(VocabbyTheme.success)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(VocabbyTheme.successSurface)
                )
            } else {
                Button {
                    Task { await switchCLI(to: account) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.blue)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(VocabbyTheme.blue.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .help(switchHelp(for: account))
                .accessibilityLabel(switchHelp(for: account))
                .disabled(busy)
            }
            if canRemove(account) {
                Button(role: .destructive) {
                    confirmRemove(account)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.critical)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(removeHelp(for: account))
                .disabled(busy)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            CodexAccountStore.setActive(account.id)
            activeID = account.id
        }
    }

    private struct AccountQuotaBadge {
        let text: String
        let color: Color
        let surface: Color
        let help: String
    }

    private func accountQuotaBadge(for account: CodexAccount) -> AccountQuotaBadge {
        guard let snapshot = CodexAccountSnapshotStore.shared.snapshot(forAccount: account.id),
              let lowest = ProviderStatusSummary.lowestWindow(snapshot)
        else {
            return AccountQuotaBadge(
                text: "—",
                color: VocabbyTheme.tertiary,
                surface: VocabbyTheme.segment,
                help: L10n.t("popover.accountQuotaMissing", settings.appLanguage)
            )
        }

        let label = L10n.windowLabel(lowest.label, preference: settings.appLanguage)
        let color = VocabbyTheme.quotaColor(remaining: lowest.remainingPct)
        return AccountQuotaBadge(
            text: "\(lowest.remainingPct)%",
            color: color,
            surface: quotaBadgeSurface(remaining: lowest.remainingPct),
            help: L10n.f("popover.accountQuotaHelp", settings.appLanguage, label, lowest.remainingPct)
        )
    }

    private func quotaBadgeSurface(remaining: Int) -> Color {
        if remaining <= 20 { return VocabbyTheme.criticalSurface }
        if remaining <= 50 { return VocabbyTheme.warningSurface }
        return VocabbyTheme.successSurface
    }

    /// Whether `account` is the one currently installed in the Codex CLI —
    /// distinct from `activeID` (which account's quota is being *viewed*).
    private func isCLIIdentity(_ account: CodexAccount) -> Bool {
        account.id == "system" ? cliID == nil : account.id == cliID
    }

    private func canRemove(_ account: CodexAccount) -> Bool {
        !account.isSystem || accounts.count > 1
    }

    private func accountLabel(_ account: CodexAccount) -> String {
        account.email ?? L10n.t(account.isSystem ? "provider.systemAccount" : "provider.accountGeneric",
                                settings.appLanguage)
    }

    private var removeConfirmationTitle: String {
        guard let accountPendingRemoval else {
            return L10n.t("provider.removeAccount", settings.appLanguage)
        }
        return L10n.f("provider.removeAccountTitle", settings.appLanguage, accountLabel(accountPendingRemoval))
    }

    private var removeConfirmationButtonTitle: String {
        guard let accountPendingRemoval, accountPendingRemoval.isSystem else {
            return L10n.t("provider.removeAccount", settings.appLanguage)
        }
        return L10n.t("provider.removeSystemAccount", settings.appLanguage)
    }

    private var removeConfirmationMessage: String {
        guard let accountPendingRemoval else { return "" }
        return L10n.t(accountPendingRemoval.isSystem
                     ? "provider.removeSystemAccountMessage"
                     : "provider.removeAccountMessage",
                     settings.appLanguage)
    }

    private func removeHelp(for account: CodexAccount) -> String {
        L10n.t(account.isSystem ? "provider.removeSystemAccount" : "provider.removeAccount",
               settings.appLanguage)
    }

    private func switchHelp(for account: CodexAccount) -> String {
        if isCLIIdentity(account) {
            return L10n.t("popover.accountSelectedHelp", settings.appLanguage)
        }
        if account.isSystem {
            return L10n.t("popover.restoreCLI", settings.appLanguage)
        }
        return L10n.f("popover.cliCard.switchTo", settings.appLanguage, accountLabel(account))
    }

    private func confirmRemove(_ account: CodexAccount) {
        accountPendingRemoval = account
        showingRemoveConfirmation = true
    }

    private func dismissRemoveConfirmation() {
        showingRemoveConfirmation = false
        accountPendingRemoval = nil
    }

    private var addAccountRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("provider.waitingLogin", settings.appLanguage))
                        .font(.system(size: 11))
                        .foregroundStyle(VocabbyTheme.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                    Text(L10n.t("provider.addAccount", settings.appLanguage))
                        .font(.system(size: 12))
                }
            }
            if let addAccountErrorText {
                Text(L10n.f("provider.addAccountFailed", settings.appLanguage, addAccountErrorText))
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.critical)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(VocabbyTheme.blue)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy else { return }
            Task { await addAccount() }
        }
        .pointingHandCursor(enabled: !busy)
    }

    /// CLI switch card: terminal context on the left, explicit account-switch
    /// button on the right. The action installs the selected account into the
    /// CLI (or restores the original system login when the system account is
    /// selected), so the control must not look like an app power toggle.
    private var switchRow: some View {
        let lang = settings.appLanguage
        let alreadyInCLI = CodexAccountStore.isAlreadyCLIIdentity(selectedID: activeID, trackedID: cliID)
        let tint = alreadyInCLI ? VocabbyTheme.success : VocabbyTheme.blue
        let selected = accounts.first(where: { $0.id == activeID })
        let selectedLabel = selected?.email
            ?? L10n.t(selected?.isSystem == true ? "provider.systemAccount" : "provider.accountGeneric", lang)
        let hint = alreadyInCLI
            ? L10n.t("popover.accountSelectedHelp", lang)
            : (activeID == "system"
               ? L10n.t("popover.restoreCLI", lang)
               : L10n.f("popover.cliCard.switchTo", lang, selectedLabel))

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.t("popover.cliCard.title", lang))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    HStack(spacing: 3) {
                        Image(systemName: alreadyInCLI ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(L10n.t(alreadyInCLI ? "popover.accountSelected" : "popover.switchReady", lang))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                }
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let switchErrorText {
                    Text(L10n.f("popover.switchFailed", lang, switchErrorText))
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(1)
                } else {
                    Text("~/.codex/auth.json")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                guard !alreadyInCLI else { return }
                Task { await switchCLI() }
            } label: {
                ZStack {
                    Circle()
                        .fill(switchButtonGradient(alreadyInCLI: alreadyInCLI))
                        .frame(width: 58, height: 58)
                        .shadow(
                            color: alreadyInCLI ? .clear : VocabbyTheme.brandBlue.opacity(0.45),
                            radius: alreadyInCLI ? 0 : 16
                        )
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        )

                    if busy && !alreadyInCLI {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    } else {
                        Image(systemName: alreadyInCLI ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy || alreadyInCLI)
            .help(hint)
            .accessibilityLabel(hint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
        .padding(.top, 6)
    }

    private func switchButtonGradient(alreadyInCLI: Bool) -> LinearGradient {
        if alreadyInCLI {
            return LinearGradient(
                colors: [VocabbyTheme.success.opacity(0.90), VocabbyTheme.success],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [VocabbyTheme.brandBlue, VocabbyTheme.blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func reload() {
        // preferManagedID keeps the switched-in managed account listed after
        // a CLI switch (the system row becomes its mirror and is hidden), so
        // the selection marker and "In CLI" badge stay attached to real rows.
        cliID = CodexAccountStore.cliSwitchedID()
        accounts = CodexAccountStore.allAccounts(preferManagedID: cliID)
        activeID = CodexAccountStore.activeID()
        if !accounts.contains(where: { $0.id == activeID }), let first = accounts.first {
            CodexAccountStore.setActive(first.id)
            activeID = first.id
        }
    }

    private func addAccount() async {
        busy = true
        addAccountErrorText = nil
        accountActionErrorText = nil
        defer { busy = false }
        do {
            _ = try await CodexAccountStore.addAccount()
            reload()
        } catch {
            addAccountErrorText = error.localizedDescription
        }
    }

    private func switchCLI(to account: CodexAccount? = nil) async {
        let targetID = account?.id ?? activeID
        busy = true
        switchErrorText = nil
        accountActionErrorText = nil
        defer { busy = false }
        do {
            if targetID == "system" {
                try CodexAccountStore.restoreSystemCLI()
            } else {
                try CodexAccountStore.switchCLI(to: targetID)
            }
            CodexAccountStore.setActive(targetID)
            activeID = targetID
            cliID = CodexAccountStore.cliSwitchedID()
            reload()
        } catch {
            switchErrorText = error.localizedDescription
        }
    }

    private func removeAccount(_ account: CodexAccount) {
        accountActionErrorText = nil
        showingRemoveConfirmation = false
        do {
            try CodexAccountStore.remove(account: account, from: accounts)
            reload()
        } catch {
            accountActionErrorText = error.localizedDescription
        }
        accountPendingRemoval = nil
    }
}

struct QuotaSummaryStrip: View {
    @EnvironmentObject var settings: SettingsStore

    let status: ProviderStatus

    private var lowest: QuotaWindow? {
        ProviderStatusSummary.lowestWindow(status)
    }

    private var tone: Color {
        VocabbyTheme.quotaColor(remaining: lowest?.remainingPct ?? 100)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("popover.lowestQuota", settings.appLanguage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
                Text(lowest.map { L10n.windowLabel($0.label, preference: settings.appLanguage) } ?? status.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(lowest?.remainingPct ?? 0)%")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone)
        }
        .padding(.vertical, 1)
    }
}

struct LoadingQuotaSkeleton: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track)
                .frame(width: 124, height: 10)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track)
                .frame(height: 8)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track.opacity(0.75))
                .frame(width: 180, height: 8)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(L10n.t("popover.loadingQuota", settings.appLanguage))
    }
}

/// Single quota window row.
struct WindowRow: View {
    @EnvironmentObject var settings: SettingsStore

    let window: QuotaWindow
    /// Fetch timestamp from the parent `ProviderStatus` — used as the
    /// anchor for the `lastUpdated + windowSeconds` reset estimate when
    /// the API didn't return an explicit reset timestamp.
    let lastUpdated: Date

    private var barFillColor: Color {
        VocabbyTheme.quotaFillColor(remaining: window.remainingPct)
    }

    private var percentTextColor: Color {
        VocabbyTheme.quotaColor(remaining: window.remainingPct)
    }

    private var subtitleText: String {
        if let s = window.subtitle, !s.isEmpty {
            return L10n.providerText(s, preference: settings.appLanguage)
        }
        return L10n.f("quota.used", settings.appLanguage, window.usedPct)
    }

    private var resetText: String {
        // 1. Use the API-provided reset timestamp when available.
        if let d = window.resetDate { return formatReset(d) }
        // 2. Fall back to `lastUpdated + windowSeconds` — the API didn't
        //    include a reset timestamp (e.g. Codex OAuth response sometimes
        //    omits it) but we know the window's nominal length. Computes
        //    against `lastUpdated` so the countdown tracks when the fetch
        //    happened rather than the absolute wall-clock at render time.
        if let secs = window.windowSeconds, secs > 0 {
            let estimate = lastUpdated.addingTimeInterval(TimeInterval(secs))
            return formatReset(estimate)
        }
        // 3. Last-resort label-based fallback for old providers that don't
        //    surface either resetDate or windowSeconds.
        if window.label.contains("Tuần") { return L10n.t("quota.resetWeekly", settings.appLanguage) }
        if window.label.contains("5 giờ") { return L10n.t("quota.resetIn5h", settings.appLanguage) }
        return ""
    }

    private func formatReset(_ date: Date) -> String {
        L10n.resetCountdown(to: date, preference: settings.appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowLabel(window.label, preference: settings.appLanguage))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                Spacer()
                Text("\(window.remainingPct)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(percentTextColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(VocabbyTheme.track)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(barFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(window.remainingPct) / 100), height: 5)
                }
            }
            .frame(height: 5)
            HStack(alignment: .firstTextBaseline) {
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text(resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
    }
}

// MARK: - ElevenLabs keys (popover)

/// ElevenLabs multi-key switcher — same collapsed-card pattern as FreeModel:
/// header (icon + active key + count + chevron) and expandable rows with radio
/// + switch/remove. Adding keys stays in Settings.
struct ElevenLabsKeysPopoverSection: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var keys: [ElevenLabsKey] = []
    @State private var activeID: String?
    @State private var revealed = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if revealed {
                Divider()
                    .overlay(VocabbyTheme.border)
                    .padding(.vertical, 6)
                if keys.isEmpty {
                    Text(L10n.t("elevenlabs.keysEmpty", settings.appLanguage))
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .padding(.vertical, 4)
                }
                ForEach(keys) { key in
                    keyRow(key)
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(2)
                        .padding(.vertical, 4)
                }
            }
        }
        .vocabbyCard()
        .onAppear(perform: reload)
        // Settings (or the other surface) may add/remove/switch keys while this
        // popover view stays alive — re-list immediately, no app restart.
        .onReceive(NotificationCenter.default.publisher(for: .birdnionElevenLabsKeysChanged)) { _ in
            reload()
        }
    }

    private func displayName(_ key: ElevenLabsKey) -> String {
        if let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return key.preview
    }

    private var collapsedRow: some View {
        let lang = settings.appLanguage
        let active = keys.first(where: { $0.id == activeID })
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 30, height: 30)
                .background(VocabbyTheme.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("elevenlabs.popoverTitle", lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(active.map(displayName) ?? L10n.t("elevenlabs.keysEmpty", lang))
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(keys.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(VocabbyTheme.segment))
            Image(systemName: revealed ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture { revealed.toggle() }
    }

    private func keyRow(_ key: ElevenLabsKey) -> some View {
        let isActive = key.id == activeID
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isActive ? VocabbyTheme.blue : VocabbyTheme.tertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(key))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(key.preview + "…")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.tertiary)
            }

            Spacer(minLength: 6)

            if !isActive {
                Button {
                    switchTo(key)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.blue)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(VocabbyTheme.blue.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(busy)
                .help(L10n.t("elevenlabs.switchKey", settings.appLanguage))
            }
            Button {
                removeKey(key)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.critical)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(busy)
        }
        .padding(.vertical, 5)
    }

    private func reload() {
        keys = ElevenLabsKeyStore.allKeys()
        activeID = ElevenLabsKeyStore.activeID()
    }

    private func switchTo(_ key: ElevenLabsKey) {
        // setActive posts keys-changed + refresh; reload keeps this surface in sync.
        ElevenLabsKeyStore.setActive(key.id)
        reload()
        errorText = nil
    }

    private func removeKey(_ key: ElevenLabsKey) {
        do {
            try ElevenLabsKeyStore.remove(key.id)
            errorText = nil
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - FreeModel accounts (popover)

/// FreeModel account switcher — same collapsed-card pattern as
/// `CodexAccountsPopoverSection`: header row (icon + active account + count +
/// chevron) and expandable rows with a radio + switch/remove. Per-browser
/// sessions are auto-detected so two browsers signed in to two accounts
/// appear as two entries. (No add-cookie form here — the popover is a fast
/// switcher; pasted-cookie accounts are managed elsewhere.)
struct FreemodelAccountsPopoverSection: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var accounts: [FreemodelAccount] = []
    @State private var activeID = FreemodelAccountStore.browserID
    @State private var revealed = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if revealed {
                Divider()
                    .overlay(VocabbyTheme.border)
                    .padding(.vertical, 6)
                ForEach(accounts) { account in
                    accountRow(account)
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 10))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(2)
                        .padding(.vertical, 4)
                }
            }
        }
        .vocabbyCard()
        .onAppear(perform: reload)
    }

    private func accountName(_ account: FreemodelAccount) -> String {
        if account.isBrowser {
            if account.id == FreemodelAccountStore.browserID {
                return L10n.t("freemodel.browserAuto", settings.appLanguage)
            }
            let browser = account.label ?? String(account.id.dropFirst(FreemodelAccountStore.browserPrefix.count))
            if let email = account.email { return "\(browser) · \(email)" }
            return browser
        }
        return account.label ?? account.email ?? String(account.id.prefix(8))
    }

    private var collapsedRow: some View {
        let lang = settings.appLanguage
        let active = accounts.first(where: { $0.id == activeID })
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 30, height: 30)
                .background(VocabbyTheme.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("popover.accounts", lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(active.map(accountName) ?? L10n.t("freemodel.browserAuto", lang))
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(accounts.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(VocabbyTheme.segment))
            Image(systemName: revealed ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture { revealed.toggle() }
    }

    private func accountRow(_ account: FreemodelAccount) -> some View {
        let isActive = account.id == activeID
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isActive ? VocabbyTheme.blue : VocabbyTheme.tertiary)

            Text(accountName(account))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(account.email ?? "")

            Spacer(minLength: 6)

            if !isActive {
                Button {
                    switchTo(account)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.blue)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(VocabbyTheme.blue.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(busy)
                .help(L10n.t("freemodel.switchAccount", settings.appLanguage))
            }
            if !account.isBrowser {
                Button {
                    removeAccount(account)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(VocabbyTheme.critical)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(busy)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: Actions

    private func reload() {
        activeID = FreemodelAccountStore.activeID()
        Task.detached(priority: .utility) {
            let all = await FreemodelAccountStore.allAccounts(emailResolver: { header in
                await FreemodelProvider.accountEmail(cookieHeader: header)
            })
            await MainActor.run {
                accounts = all
                activeID = FreemodelAccountStore.activeID()
            }
        }
    }

    private func switchTo(_ account: FreemodelAccount) {
        FreemodelAccountStore.setActive(account.id)
        activeID = account.id
        errorText = nil
    }

    private func removeAccount(_ account: FreemodelAccount) {
        do {
            try FreemodelAccountStore.remove(account.id)
            errorText = nil
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Actions List

/// Vertical action list (icon + label rows). CodexBar-style, matches the
/// footer menu of the reference app instead of the compact 4-icon row.
struct ActionsList: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "gearshape", label: L10n.t("popover.settings", settings.appLanguage),
                      shortcut: "⌘,",
                      isLoading: false) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "info.circle", label: L10n.t("popover.about", settings.appLanguage),
                      shortcut: nil,
                      isLoading: false) {
                AboutPresenter.show()
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "power", label: L10n.t("popover.quit", settings.appLanguage),
                      shortcut: "⌘Q",
                      isLoading: false) {
                NSApp.terminate(nil)
            }
        }
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
    }
}

struct ActionRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer()
                if let s = shortcut {
                    Text(s)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Claude Code quick-apply

/// Big power button in the popover, tied to the currently-selected provider
/// tab. Hidden unless the provider has an API key and can back Claude Code.
/// ON when `~/.claude/settings.json` already points Claude Code at this
/// provider; tapping toggles it (apply / deactivate). If the provider still
/// needs its 3 models, a tap opens Settings on the "Claude Code" tab instead.
struct ClaudeCodeQuickApplyButton: View {
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var settings: SettingsStore
    let providerID: String

    @State private var busy = false

    /// Whether the popover should render the button for this provider.
    static func shouldShow(providerID: String) -> Bool {
        guard ClaudeCodeBackend.isSupported(providerID) else { return false }
        let key = BirdNionConfigStore.apiKey(provider: providerID)
        return (key?.isEmpty == false)
    }

    var body: some View {
        let provider = BirdNionConfigStore.provider(id: providerID)
        let scope = provider.flatMap(currentScope)
        let configured = provider.map { ClaudeCodeConfigWriter.isFullyConfigured($0) && scope != nil } ?? false
        let sync: ClaudeCodeConfigWriter.SyncState = (configured && provider != nil && scope != nil)
            ? ClaudeCodeConfigWriter.syncState(forProvider: provider!, scope: scope!, using: config)
            : .off
        let state: ClaudeCodePowerButton.PowerState = powerState(configured: configured, sync: sync)
        let lang = settings.appLanguage
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(stateColor(state))
                .frame(width: 30, height: 30)
                .background(stateColor(state).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.t("claudeCode.quickCard.title", lang))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    HStack(spacing: 3) {
                        Image(systemName: stateIcon(state))
                            .font(.system(size: 9, weight: .bold))
                        Text(stateLabel(state, lang: lang))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(stateColor(state))
                }
                Text(subtitle(state: state, provider: provider))
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                Text(targetLabel(provider))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ClaudeCodePowerButton(
                state: state,
                subtitle: "",
                diameter: 58,
                busy: busy,
                subtitleColor: VocabbyTheme.primary,
                showsSubtitle: false,
                action: { tap(state: state, provider: provider, scope: scope) }
            )
            .help(subtitle(state: state, provider: provider))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
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

    private func subtitle(state: ClaudeCodePowerButton.PowerState,
                          provider: BirdNionConfigStore.Provider?) -> String {
        let lang = settings.appLanguage
        switch state {
        case .on: return L10n.f("claudeCode.power.on", lang, name(provider))
        case .off: return L10n.t("claudeCode.power.off", lang)
        case .stale: return L10n.t("claudeCode.power.stale", lang)
        case .needsSetup:
            if provider.map(needsProjectPath) == true {
                return L10n.t("claudeCode.project.none", lang)
            }
            return L10n.t("claudeCode.quickApply.setup", lang)
        }
    }

    private func stateLabel(_ state: ClaudeCodePowerButton.PowerState, lang: String) -> String {
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
        case .on: return VocabbyTheme.success
        case .off: return VocabbyTheme.secondary
        case .stale: return VocabbyTheme.warningFill
        case .needsSetup: return VocabbyTheme.blue
        }
    }

    private func currentScope(for provider: BirdNionConfigStore.Provider)
    -> ClaudeCodeConfigWriter.Scope? {
        guard provider.claudeCodeScope == "project" else { return .global }
        guard let path = cleaned(provider.claudeCodeProjectPath) else { return nil }
        return .project(URL(fileURLWithPath: path))
    }

    private func needsProjectPath(_ provider: BirdNionConfigStore.Provider) -> Bool {
        provider.claudeCodeScope == "project" && cleaned(provider.claudeCodeProjectPath) == nil
    }

    private func targetLabel(_ provider: BirdNionConfigStore.Provider?) -> String {
        let lang = settings.appLanguage
        guard let provider else { return L10n.t("claudeCode.quickCard.globalTarget", lang) }
        guard provider.claudeCodeScope == "project" else {
            return L10n.t("claudeCode.quickCard.globalTarget", lang)
        }
        guard let path = cleaned(provider.claudeCodeProjectPath) else {
            return L10n.t("claudeCode.quickCard.projectTargetMissing", lang)
        }
        let target = ConfigService.projectSettingsURL(projectDir: URL(fileURLWithPath: path))
        return L10n.f("claudeCode.quickCard.projectTarget", lang, displayPath(target.path))
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    private func cleaned(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private func tap(state: ClaudeCodePowerButton.PowerState,
                     provider: BirdNionConfigStore.Provider?,
                     scope: ClaudeCodeConfigWriter.Scope?) {
        guard let p = provider, let scope else { openSettings(); return }
        if state == .needsSetup { openSettings(); return }
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                if state == .on {
                    try ClaudeCodeConfigWriter.deactivate(scope: scope, using: config)
                } else {
                    // .off or .stale → merge current values in place (patches the
                    // changed key, keeps everything else; never clears the block).
                    try ClaudeCodeConfigWriter.apply(provider: p, scope: scope, using: config)
                }
            } catch {
                // Failure leaves the file unchanged; the button reverts to its
                // real state on the next render.
            }
            busy = false  // re-render re-reads settings.json → reflects new state
        }
    }

    /// Not configured: jump to Settings → Claude Code tab to finish setup.
    private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openClaudeCodeTab, object: nil)
        }
    }

    private func name(_ p: BirdNionConfigStore.Provider?) -> String {
        switch providerID {
        case "hapo": return p?.displayName ?? "Hapo AI Hub"
        case "minimax": return "MiniMax"
        case "deepseek": return "DeepSeek"
        case "zai": return "z.ai"
        default: return p?.displayName ?? providerID
        }
    }
}

// MARK: - Menu Bar Visibility Toggle

/// Toggle that controls whether this provider appears in the macOS menu
/// bar percent rotation. When the toggle is on, the provider can appear in
/// the menu-bar percent sequence; when off, it's excluded from that sequence.
/// Default state is read from `MenuBarVisibility` (UserDefaults-backed).
///
/// A small icon on the left reflects the provider's current fetch health
/// (green check when ok, red triangle when in error) so the toggle area
/// still surfaces status at a glance — this replaces the old OK pill.
struct MenuBarVisibilityToggle: View {
    @EnvironmentObject var settings: SettingsStore

    let providerId: String
    let hasError: Bool

    @State private var isOn: Bool

    init(providerId: String, hasError: Bool) {
        self.providerId = providerId
        self.hasError = hasError
        self._isOn = State(initialValue: MenuBarVisibility.isShown(providerId: providerId))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hasError ? VocabbyTheme.critical : VocabbyTheme.success)
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isOn.toggle()
                }
                MenuBarVisibility.setShown(providerId: providerId, to: isOn)
            } label: {
                ZStack {
                    Capsule()
                        .fill(isOn ? VocabbyTheme.blue : VocabbyTheme.track)
                    Capsule()
                        .strokeBorder(isOn ? VocabbyTheme.blue.opacity(0.45) : VocabbyTheme.border,
                                      lineWidth: 1)
                    HStack {
                        if isOn { Spacer(minLength: 0) }
                        Circle()
                            .fill(VocabbyTheme.card)
                            .frame(width: 12, height: 12)
                            .shadow(color: VocabbyTheme.brandNavy.opacity(isOn ? 0.18 : 0.10),
                                    radius: 1, x: 0, y: 1)
                        if !isOn { Spacer(minLength: 0) }
                    }
                    .padding(2)
                }
                .frame(width: 30, height: 16)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .help(isOn
                ? L10n.t("popover.visibilityOn", settings.appLanguage)
                : L10n.t("popover.visibilityOff", settings.appLanguage))
            .accessibilityLabel(L10n.t("popover.menuBarVisibility", settings.appLanguage))
            .accessibilityValue(isOn
                                ? L10n.t("popover.visibilityOn", settings.appLanguage)
                                : L10n.t("popover.visibilityOff", settings.appLanguage))
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
        }
    }
}

// MARK: - About

/// Shows a simple About panel via NSAlert. Avoids creating a dedicated
/// SwiftUI sheet for what amounts to a static info blob.
enum AboutPresenter {
    static func show() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        let alert = NSAlert()
        alert.messageText = "BirdNion"
        alert.informativeText = """
        Version \(version) (\(build))

        \(L10n.t("popover.aboutInfo"))
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("button.close"))
        alert.runModal()
    }
}

// MARK: - Theme

/// App color palette.
enum VocabbyTheme {
    // Fixed light macOS-style surfaces. Do not follow Dark Mode here because
    // the menu-bar popover should stay light, dense, and inspectable.
    static let brandNavy  = Color(red: 31 / 255, green: 36 / 255, blue: 51 / 255)   // #1F2433
    static let brandBlue  = Color(red: 70 / 255, green: 155 / 255, blue: 233 / 255) // #469BE9
    static let background = Color(red: 244 / 255, green: 245 / 255, blue: 247 / 255) // #F4F5F7
    static let card       = Color(red: 254 / 255, green: 254 / 255, blue: 255 / 255) // #FEFEFF
    static let group      = Color(red: 250 / 255, green: 251 / 255, blue: 252 / 255) // #FAFBFC
    static let segment    = Color(red: 238 / 255, green: 240 / 255, blue: 244 / 255) // #EEF0F4
    static let primary    = Color(red: 28 / 255, green: 31 / 255, blue: 38 / 255)    // #1C1F26
    static let secondary  = Color(red: 89 / 255, green: 97 / 255, blue: 109 / 255)   // #59616D
    static let tertiary   = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255) // #6B7280
    static let blue       = Color(red: 0 / 255, green: 87 / 255, blue: 184 / 255)    // #0057B8 action
    static let selectedSurface = Color(red: 231 / 255, green: 241 / 255, blue: 255 / 255) // #E7F1FF
    static let hoverSurface = Color(red: 231 / 255, green: 234 / 255, blue: 240 / 255) // #E7EAF0
    static let yellow     = Color(red: 168 / 255, green: 75 / 255, blue: 0 / 255)    // #A84B00 warning text
    static let warningFill = Color(red: 184 / 255, green: 106 / 255, blue: 0 / 255)  // #B86A00
    static let warningSurface = Color(red: 255 / 255, green: 241 / 255, blue: 214 / 255) // #FFF1D6
    static let success    = Color(red: 21 / 255, green: 128 / 255, blue: 61 / 255)   // #15803D
    static let successSurface = Color(red: 234 / 255, green: 247 / 255, blue: 239 / 255) // #EAF7EF
    static let critical   = Color(red: 215 / 255, green: 0 / 255, blue: 21 / 255)    // #D70015
    static let criticalSurface = Color(red: 255 / 255, green: 232 / 255, blue: 234 / 255) // #FFE8EA
    static let track      = Color(red: 227 / 255, green: 230 / 255, blue: 234 / 255) // #E3E6EA
    static let chartBar   = Color(red: 70 / 255, green: 155 / 255, blue: 233 / 255) // #469BE9
    // All-tab chart series colours — deliberately distinct from the brand
    // tints below (which keep coloring the provider logos): Codex blue,
    // Claude amber-yellow for a clearer stacked-bar split.
    static let chartCodex  = Color(red: 70 / 255, green: 155 / 255, blue: 233 / 255)  // #469BE9
    static let chartClaude = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)  // #CC7C5E (brand orange)
    // Grok product brand is black (xAI/Grok mark), not CodexBar's teal placeholder.
    static let chartGrok   = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)    // #111827 near-black
    static let badge      = group
    static let border     = Color(red: 215 / 255, green: 220 / 255, blue: 226 / 255) // #D7DCE2
    static let disabled   = Color(red: 154 / 255, green: 163 / 255, blue: 173 / 255) // #9AA3AD

    // Per-provider brand tints for the monochrome template logos.
    // Values mirror CodexBar's ProviderBranding.color exactly (see
    // docs/provider-parity). Exception: ElevenLabs' CodexBar color is near-white
    // (#EBEBE6) which is invisible on this light popover, so we keep it mono.
    static let codex      = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255) // #49A3B0
    static let minimax    = Color(red: 254 / 255, green: 96 / 255, blue: 60 / 255)  // #FE603C
    static let openRouter = Color(red: 100 / 255, green: 103 / 255, blue: 242 / 255) // #6467F2
    static let deepSeek   = Color(red: 0.32, green: 0.49, blue: 0.94)                // #527DF0
    static let zai        = Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255)  // #E85A6A
    static let claude     = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)  // #CC7C5E
    static let elevenLabs = Color.primary                                            // CodexBar #EBEBE6 invisible on light → mono
    static let deepgram   = Color(red: 100 / 255, green: 103 / 255, blue: 242 / 255) // #6467F2 (CodexBar)
    static let groq       = Color(red: 245 / 255, green: 104 / 255, blue: 68 / 255)  // #F56844
    static let grok       = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)    // #111827 near-black (Grok brand)
    // CodexBar OpenAI API branding (teal), distinct from Codex chat (#49A3B0).
    static let openAI     = Color(red: 15 / 255, green: 130 / 255, blue: 110 / 255)  // ~#0F8270
    static let ollama     = Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255) // #888888 (CodexBar)
    static let copilot    = Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)  // #A855F7
    static let kilo       = Color(red: 242 / 255, green: 112 / 255, blue: 39 / 255)  // #F27027
    static let commandCode = Color(red: 0, green: 0, blue: 0)                        // #000000 (CodexBar)
    static let freemodel  = Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)  // #22C55E (brand green)
    static let mimo       = Color(red: 255 / 255, green: 105 / 255, blue: 0 / 255)   // #FF6900 (Xiaomi)
    static let alibaba    = Color(red: 255 / 255, green: 106 / 255, blue: 0 / 255)   // #FF6A00
    static let cursor     = Color(red: 0, green: 191 / 255, blue: 165 / 255)         // #00BFA5
    static let gemini     = Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255) // #AB87EA
    static let kiro       = Color(red: 139 / 255, green: 71 / 255, blue: 249 / 255)  // #8B47F9 (Kiro violet, icon gradient mid)
    static let openCode   = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)  // #3B82F6
    static let antigravity = Color(red: 96 / 255, green: 186 / 255, blue: 126 / 255) // #60BA7E
    static let bedrock    = Color(red: 255 / 255, green: 153 / 255, blue: 0 / 255)   // #FF9900 (AWS)

    /// Brand tint for a provider id; nil → caller falls back to default styling.
    static func providerTint(_ id: String) -> Color? {
        switch id {
        case "codex": return codex
        case "minimax": return minimax
        case "openrouter": return openRouter
        case "deepseek": return deepSeek
        case "zai": return zai
        case "claude": return claude
        case "elevenlabs": return primary
        case "deepgram": return deepgram
        case "groq": return groq
        case "grok": return grok
        case "openai": return openAI
        case "ollama": return ollama
        case "copilot": return copilot
        case "kilo": return kilo
        case "commandcode": return commandCode
        case "freemodel": return freemodel
        case "mimo": return mimo
        case "alibaba": return alibaba
        case "cursor": return cursor
        case "gemini": return gemini
        case "kiro": return kiro
        case "opencode", "opencodego": return openCode
        case "antigravity": return antigravity
        case "bedrock": return bedrock
        default: return nil
        }
    }

    static func quotaColor(remaining: Int) -> Color {
        if remaining <= 20 { return critical }
        if remaining <= 50 { return yellow }
        return success
    }

    static func quotaFillColor(remaining: Int) -> Color {
        if remaining <= 20 { return critical }
        if remaining <= 50 { return warningFill }
        return success
    }

    static func usedFillColor(usedPercent: Int) -> Color {
        if usedPercent >= 90 { return critical }
        if usedPercent >= 70 { return warningFill }
        return success
    }

    /// Daily-bar fill shared by the per-provider chart cards. `tint` colors
    /// normal active days (at 72%), `currentTint` marks today's bar — the
    /// defaults keep the original blue scheme; the Claude card passes its
    /// brand orange.
    static func activityChartBarColor(isCurrent: Bool, hasActivity: Bool,
                                      tint: Color = chartBar,
                                      currentTint: Color = blue) -> Color {
        if !hasActivity { return selectedSurface.opacity(0.76) }
        return isCurrent ? currentTint : tint.opacity(0.72)
    }

    /// Heatmap cell fill for the All tab's activity grid: 0 → idle track,
    /// then four intensity steps of the chart blue.
    /// GitHub-style contribution greens, lightened one step so the popover
    /// heatmap is softer than the full GitHub calendar palette.
    /// Empty → L1 pale → L2 mid → L3 strong → L4 deepest (still soft).
    static let heatEmpty = Color(red: 235 / 255, green: 237 / 255, blue: 240 / 255) // #EBEDF0
    static let heatL1    = Color(red: 198 / 255, green: 240 / 255, blue: 205 / 255) // #C6F0CD (was #9BE9A8)
    static let heatL2    = Color(red: 140 / 255, green: 220 / 255, blue: 155 / 255) // #8CDC9B (was #40C463)
    static let heatL3    = Color(red: 90 / 255, green: 190 / 255, blue: 115 / 255)  // #5ABE73 (was #30A14E)
    static let heatL4    = Color(red: 55 / 255, green: 155 / 255, blue: 85 / 255)   // #379B55 (was #216E39)

    static func heatColor(fraction: Double) -> Color {
        guard fraction > 0 else { return heatEmpty }
        if fraction <= 0.25 { return heatL1 }
        if fraction <= 0.5 { return heatL2 }
        if fraction <= 0.75 { return heatL3 }
        return heatL4
    }
}

// MARK: - Card modifier

struct VocabbyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(VocabbyTheme.group)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
    }
}

extension View {
    func vocabbyCard() -> some View { modifier(VocabbyCard()) }
}

// MARK: - Claude usage chart

/// 30-day bar chart card sourced from `ClaudeCostScanner.usageReport()`.
/// Mirrors CodexBar's compact "Today / 30d cost / tokens / latest tokens"
/// header + a per-day USD bar series. The chart uses USD as the y-axis
/// (matches the screenshot reference) since token counts vary too wildly
/// between idle and busy days; tokens go in the top-right summary so
/// both signals are visible at a glance.
struct ClaudeUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: ClaudeUsageReport
    /// The bar the pointer is currently over — drives the hover read-out line
    /// and the column highlight.
    @State private var hoveredDay: ClaudeDailyUsage?

    /// This card keeps its 30-day scope; the report's wider (90-day) window
    /// only exists for the All tab's heatmap.
    private var daily30: [ClaudeDailyUsage] { Array(report.daily.suffix(30)) }

    private var maxBarUSD: Double {
        max(daily30.map(\.usd).max() ?? 0, 0.01)
    }

    /// Day whose per-model breakdown is shown: the hovered bar, else the most
    /// recent day with activity.
    private var detailDay: ClaudeDailyUsage? {
        hoveredDay ?? daily30.last(where: { $0.tokens > 0 })
    }

    private var latestDayTokens: Int {
        daily30.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    private var todayLabel: String {
        guard let today = daily30.last else { return L10n.t("chart.today", settings.appLanguage) }
        return L10n.f("chart.todayWithDate", settings.appLanguage, L10n.dayMonth(today.date, preference: settings.appLanguage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top summary row: today vs 30d cost + tokens.
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: todayLabel,
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: L10n.t("chart.last30Cost", settings.appLanguage),
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: L10n.t("chart.latestTokens", settings.appLanguage),
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            // Per-model breakdown for the focused day (hovered bar, else the
            // most recent active day) — mirrors CodexBar's day detail list.
            if let detail = detailDay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dayLabel(detail.date)) · \(formatUSD(detail.usd)) · \(formatTokens(detail.tokens))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.primary)
                    ForEach(detail.models) { m in
                        HStack(spacing: 8) {
                            Text(m.name)
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(formatUSD(m.usd)) · \(formatTokensShort(m.tokens))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 30-day estimated total + provenance footnote.
            Text("\(L10n.t("chart.estTotal30", settings.appLanguage)): \(formatUSD(report.last30USD))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            Text(L10n.t("chart.estimate", settings.appLanguage))
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double?, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            if let amount {
                Text(formatUSD(amount))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    /// 30 vertical bars, one per day, height proportional to USD. Inactive
    /// days render as a faint 2pt baseline so the chart doesn't look broken
    /// when usage is sparse.
    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let heightFraction = day.usd > 0
                        ? CGFloat(day.usd / maxBarUSD)
                        : 0
                    let barHeight = max(geo.size.height * heightFraction, day.usd > 0 ? 3 : 1)
                    // Full-height hover column so even tiny bars are easy to
                    // target; the bar itself sits at the bottom.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredDay?.id == day.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .help("\(dayLabel(day.date)): \(formatUSD(day.usd)) · \(formatTokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: ClaudeDailyUsage) -> Color {
        VocabbyTheme.activityChartBarColor(
            isCurrent: day.date == daily30.last?.date,
            hasActivity: day.usd > 0,
            tint: VocabbyTheme.chartClaude,
            currentTint: VocabbyTheme.chartClaude
        )
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }

    private func formatUSD(_ amount: Double) -> String {
        AllUsageFormat.usd(amount)
    }

    private func formatTokens(_ n: Int) -> String {
        AllUsageFormat.tokens(n)
    }

    /// Compact token count without the " tokens" suffix, for the dense per-model
    /// breakdown rows (e.g. "628M", "9.1M", "29M").
    private func formatTokensShort(_ n: Int) -> String {
        AllUsageFormat.tokensShort(n)
    }
}

// MARK: - Codex usage chart

/// 30-day bar chart card sourced from `CodexCostScanner.usageReport()`. Mirrors
/// `ClaudeUsageChartCard` (Today / 30d cost / latest tokens + per-day cost bars +
/// hover per-model breakdown) but the numbers are mapped to match CodexBar's own
/// inline Codex dashboard. Labels are inline VI/EN (no shared L10n keys needed).
struct CodexUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CodexUsageReport
    @State private var hoveredDay: CodexDailyUsage?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    /// This card keeps its 30-day scope; the report's wider (90-day) window
    /// only exists for the All tab's heatmap.
    private var daily30: [CodexDailyUsage] { Array(report.daily.suffix(30)) }

    private var maxBarUSD: Double {
        max(daily30.map(\.usd).max() ?? 0, 0.01)
    }

    /// Day whose per-model breakdown is shown: the hovered bar, else the most
    /// recent day with activity.
    private var detailDay: CodexDailyUsage? {
        hoveredDay ?? daily30.last(where: { $0.tokens > 0 })
    }

    private var latestDayTokens: Int {
        daily30.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top summary row: today vs 30d cost + tokens.
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: vi ? "Hôm nay" : "Today",
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "30 ngày" : "30d cost",
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "Token mới nhất" : "Latest tokens",
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            // Per-model breakdown for the focused day (hovered bar, else the
            // most recent active day) — mirrors CodexBar's day detail list.
            if let detail = detailDay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dayLabel(detail.date)) · \(formatUSD(detail.usd)) · \(formatTokens(detail.tokens))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.primary)
                    ForEach(detail.models) { m in
                        HStack(spacing: 8) {
                            Text(m.name)
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(formatUSD(m.usd)) · \(formatTokensShort(m.tokens))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 30-day estimated total + provenance footnote.
            Text("\(vi ? "Ước tính 30 ngày" : "Est. 30-day total"): \(formatUSD(report.last30USD))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            Text(vi
                 ? "Ước tính từ log phiên Codex CLI cục bộ trên máy này."
                 : "Estimated from this machine's local Codex CLI session logs.")
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double?, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            if let amount {
                Text(formatUSD(amount))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    /// 30 vertical bars, one per day, height proportional to USD.
    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let heightFraction = day.usd > 0
                        ? CGFloat(day.usd / maxBarUSD)
                        : 0
                    let barHeight = max(geo.size.height * heightFraction, day.usd > 0 ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredDay?.id == day.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .help("\(dayLabel(day.date)): \(formatUSD(day.usd)) · \(formatTokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: CodexDailyUsage) -> Color {
        VocabbyTheme.activityChartBarColor(
            isCurrent: day.date == daily30.last?.date,
            hasActivity: day.usd > 0
        )
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }

    private func formatUSD(_ amount: Double) -> String {
        AllUsageFormat.usd(amount)
    }

    private func formatTokens(_ n: Int) -> String {
        AllUsageFormat.tokens(n)
    }

    private func formatTokensShort(_ n: Int) -> String {
        AllUsageFormat.tokensShort(n)
    }
}

// MARK: - Kiro usage chart

/// 30-day bar chart for Kiro CLI local sessions (`KiroCostScanner`),
/// mirroring `GrokUsageChartCard` layout so the Kiro tab shows the same
/// Today / 30d / latest-tokens + hover model breakdown. Bar height uses
/// tokens (volume), not USD estimates.
struct KiroUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: KiroUsageReport
    @State private var hoveredDay: KiroDailyUsage?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private var daily30: [KiroDailyUsage] { Array(report.daily.suffix(30)) }

    private var maxBarTokens: Int {
        max(daily30.map(\.tokens).max() ?? 0, 1)
    }

    private var detailDay: KiroDailyUsage? {
        hoveredDay ?? daily30.last(where: { $0.tokens > 0 || $0.usd > 0 })
    }

    private var latestDayTokens: Int {
        daily30.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: vi ? "Hôm nay" : "Today",
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "30 ngày" : "30d cost",
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "Token mới nhất" : "Latest tokens",
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            if let detail = detailDay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dayLabel(detail.date)) · \(formatTokens(detail.tokens)) · \(formatUSD(detail.usd))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.primary)
                    ForEach(detail.models) { m in
                        HStack(spacing: 8) {
                            Text(m.name)
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(formatTokensShort(m.tokens)) · \(formatUSD(m.usd))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(vi ? "Ước tính 30 ngày" : "Est. 30-day total"): \(formatTokens(report.last30Tokens))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            if let top = report.topModel, !top.isEmpty {
                Text("\(vi ? "Model dùng nhiều" : "Top model"): \(top)")
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            Text(vi
                 ? "Ước tính từ log Kiro CLI cục bộ (kiro-cli sessions)."
                 : "Estimated from local Kiro CLI sessions (kiro-cli data.sqlite3).")
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double?, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            if let amount {
                Text(formatUSD(amount))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let hasTokens = day.tokens > 0
                    let heightFraction = hasTokens
                        ? CGFloat(Double(day.tokens) / Double(maxBarTokens))
                        : 0
                    let barHeight = max(geo.size.height * heightFraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredDay?.id == day.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .help("\(dayLabel(day.date)): \(formatTokens(day.tokens)) · \(formatUSD(day.usd))")
                }
            }
        }
    }

    private func barColor(for day: KiroDailyUsage) -> Color {
        if day.tokens <= 0 { return VocabbyTheme.track }
        if day.date == daily30.last?.date {
            return VocabbyTheme.kiro
        }
        return VocabbyTheme.kiro.opacity(0.78)
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }

    private func formatUSD(_ amount: Double) -> String {
        AllUsageFormat.usd(amount)
    }

    private func formatTokens(_ n: Int) -> String {
        AllUsageFormat.tokens(n)
    }

    private func formatTokensShort(_ n: Int) -> String {
        AllUsageFormat.tokensShort(n)
    }
}

// MARK: - Grok Build usage chart

/// 30-day bar chart for Grok Build local sessions (`GrokCostScanner`),
/// mirroring `CodexUsageChartCard` layout so the Grok tab shows the same
/// Today / 30d / latest-tokens + hover model breakdown as Codex/Claude.
struct GrokUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: GrokUsageReport
    @State private var hoveredDay: GrokDailyUsage?

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private var daily30: [GrokDailyUsage] { Array(report.daily.suffix(30)) }

    private var maxBarUSD: Double {
        max(daily30.map(\.usd).max() ?? 0, 0.01)
    }

    private var detailDay: GrokDailyUsage? {
        hoveredDay ?? daily30.last(where: { $0.tokens > 0 || $0.usd > 0 })
    }

    private var latestDayTokens: Int {
        daily30.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: vi ? "Hôm nay" : "Today",
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "30 ngày" : "30d cost",
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: vi ? "Token mới nhất" : "Latest tokens",
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            if let detail = detailDay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dayLabel(detail.date)) · \(formatUSD(detail.usd)) · \(formatTokens(detail.tokens))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.primary)
                    ForEach(detail.models) { m in
                        HStack(spacing: 8) {
                            Text(m.name)
                                .font(.system(size: 10))
                                .foregroundStyle(VocabbyTheme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(formatUSD(m.usd)) · \(formatTokensShort(m.tokens))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(VocabbyTheme.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(vi ? "Ước tính 30 ngày" : "Est. 30-day total"): \(formatUSD(report.last30USD))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            if let top = report.topModel, !top.isEmpty {
                Text("\(vi ? "Model dùng nhiều" : "Top model"): \(top)")
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            Text(vi
                 ? "Ước tính từ log Grok Build cục bộ (~/.grok/sessions)."
                 : "Estimated from local Grok Build logs (~/.grok/sessions).")
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double?, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            if let amount {
                Text(formatUSD(amount))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let heightFraction = day.usd > 0
                        ? CGFloat(day.usd / maxBarUSD)
                        : 0
                    let barHeight = max(geo.size.height * heightFraction, day.usd > 0 ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(hoveredDay?.id == day.id
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .help("\(dayLabel(day.date)): \(formatUSD(day.usd)) · \(formatTokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: GrokDailyUsage) -> Color {
        // Grok brand near-black; slightly lift the current day for readability.
        if day.usd <= 0 { return VocabbyTheme.track }
        if day.date == daily30.last?.date {
            return VocabbyTheme.chartGrok
        }
        return VocabbyTheme.chartGrok.opacity(0.78)
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }

    private func formatUSD(_ amount: Double) -> String {
        AllUsageFormat.usd(amount)
    }

    private func formatTokens(_ n: Int) -> String {
        AllUsageFormat.tokens(n)
    }

    private func formatTokensShort(_ n: Int) -> String {
        AllUsageFormat.tokensShort(n)
    }
}

// MARK: - Claude Admin usage chart

/// 30-day org dashboard card for the Claude Admin API source. Mirrors
/// `ClaudeUsageChartCard` but the data comes from `ClaudeAdminAPIUsageSnapshot`
/// (real billed cost from Anthropic's org Usage & Cost API, not a local
/// estimate) — so no "≈ estimate" footnote. Shows 30-day + latest-day cost +
/// tokens, a per-day cost bar series, and the top model + top cost item.
struct ClaudeAdminUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let snapshot: ClaudeAdminAPIUsageSnapshot

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var maxBarUSD: Double { max(snapshot.daily.map(\.costUSD).max() ?? 0, 0.01) }

    var body: some View {
        let last30 = snapshot.last30Days
        let latest = snapshot.latestDay
        return VStack(alignment: .leading, spacing: 8) {
            Text(vi ? "Admin API · Tổ chức (30 ngày)" : "Admin API · Org (30 days)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            HStack(alignment: .top, spacing: 16) {
                column(label: vi ? "30 ngày" : "30 days", amount: last30.costUSD, tokens: last30.totalTokens)
                Spacer(minLength: 8)
                column(label: vi ? "Mới nhất" : "Latest", amount: latest.costUSD,
                       tokens: latest.totalTokens, alignTrailing: true)
            }
            barChart.frame(height: 56)
            if let model = snapshot.topModels.first {
                Text((vi ? "Model nhiều nhất: " : "Top model: ") + model.name)
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            if let item = snapshot.topCostItems.first {
                Text((vi ? "Chi nhiều nhất: " : "Top cost: ") + "\(item.name) · \(formatUSD(item.costUSD))")
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
        .vocabbyCard()
    }

    @ViewBuilder
    private func column(label: String, amount: Double, tokens: Int,
                        alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            Text(formatUSD(amount))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(VocabbyTheme.primary)
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(snapshot.daily) { day in
                    let fraction = day.costUSD > 0 ? CGFloat(day.costUSD / maxBarUSD) : 0
                    let barHeight = max(geo.size.height * fraction, day.costUSD > 0 ? 3 : 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(VocabbyTheme.activityChartBarColor(
                            isCurrent: day.id == snapshot.daily.last?.id,
                            hasActivity: day.costUSD > 0
                        ))
                        .frame(maxWidth: .infinity, maxHeight: geo.size.height, alignment: .bottom)
                        .frame(height: barHeight, alignment: .bottom)
                        .help("\(day.day): \(formatUSD(day.costUSD)) · \(formatTokens(day.totalTokens))")
                }
            }
        }
    }

    private func formatUSD(_ amount: Double) -> String {
        AllUsageFormat.usd(amount)
    }

    private func formatTokens(_ n: Int) -> String {
        AllUsageFormat.tokens(n)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let birdnionRefresh = Notification.Name("com.local.birdnion.refresh")
    /// Posted by `CodexAccountStore.setActive` when the active Codex account
    /// changes. QuotaService swaps in that account's cached snapshot for an
    /// instant card update, then refreshes.
    static let birdnionCodexAccountChanged = Notification.Name("com.local.birdnion.codexAccountChanged")
    /// Posted by the Settings sidebar when the provider list changes
    /// (reorder, toggle, add, remove). AppDelegate listens and rebuilds
    /// QuotaService.providers from disk so the popover + menu-bar pick up
    /// the new order without a restart.
    static let birdnionProvidersChanged = Notification.Name("com.local.birdnion.providersChanged")
    /// Posted by `ElevenLabsKeyStore` when keys are added/removed/switched so
    /// Settings + the popover switcher re-list immediately (no app restart).
    static let birdnionElevenLabsKeysChanged = Notification.Name("com.local.birdnion.elevenLabsKeysChanged")
}

// MARK: - Empty State

/// Shown by `QuotaOverview` when no provider is enabled (first-run / opt-in
/// state). Intentionally one self-contained subview with a stable identity
/// so the hosting view in the NSPanel can lay it out once without
/// re-entering the NSISEngine recursion loop.
///
/// Plain macOS-style empty state:
///   - Big bird logo at the top
///   - Bold title + secondary body (no tinted card)
///   - Compact primary CTA
///
struct EmptyProvidersState: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            // Bird logo. `OriginalImage` is the same artwork bundled in
            // the menu bar icon — re-uses the asset so the empty state and
            // the menu bar look consistent.
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(L10n.t("popover.noProviders", settings.appLanguage))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("popover.noProvidersBody", settings.appLanguage))
                    .font(.system(size: 12))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            // Primary CTA. Compact (not full-width) so it doesn't
            // dominate the empty state. Posts `.openSettings` — same
            // notification the "Settings…" row below uses, so the click
            // reliably triggers `AppDelegate.openSettings(_:)`.
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Text(L10n.t("popover.openSettings", settings.appLanguage))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}
