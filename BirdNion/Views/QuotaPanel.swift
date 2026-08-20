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
    @EnvironmentObject var settings: SettingsStore
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
            // spacing 0: section hairlines own separation (no double rules
            // from VStack gap + section top hairline).
            VStack(alignment: .leading, spacing: 0) {
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
                                // Pre-expand panel to a safe seed BEFORE state
                                // mutates so NSHostingView has stable bounds
                                // while AllUsageOverview lays out (avoids
                                // NSISEngine recursion on HostingScrollView).
                                // The deferred fitting-size path then resumes
                                // normal auto-fit after the layout pass.
                                if $0 == "all", selected != "all" {
                                    NotificationCenter.default.post(
                                        name: .birdnionAllTabWillOpen, object: nil)
                                }
                                selectedProviderId = $0
                                UserDefaults.standard.set($0, forKey: Self.selectedTabKey)
                            }
                        ),
                        showAllTab: hasLocalCostSources
                    )
                    if selected == "all" {
                        // Combined Claude CLI + Codex + Grok overview (no real
                        // ProviderStatus behind it — reports only).
                        AllUsageOverview(
                            claude: claudeReport,
                            codex: codexReport,
                            grok: grokReport,
                            claudeEnabled: quota.displayStatuses.contains { $0.id == "claude" },
                            codexEnabled: quota.displayStatuses.contains { $0.id == "codex" },
                            grokEnabled: quota.displayStatuses.contains { $0.id == "grok" })
                    } else if let s = quota.displayStatuses.first(where: { $0.id == selected })
                        ?? quota.displayStatuses.first {
                        // Design provider stack: header → lowest hero → windows
                        // (+ credits) → optional charts / accounts. Spacing
                        // owned by each section's padding/rules (body pad 16).
                        VStack(alignment: .leading, spacing: 0) {
                            ProviderHeaderCard(status: s, isPlaceholder: s.windows.isEmpty && s.error == nil)
                            if s.error == nil, !s.windows.isEmpty {
                                QuotaSummaryStrip(status: s)
                            }
                            ProviderCard(status: s)
                            if s.id == "xai", let cost = s.cost {
                                XAISpendCard(cost: cost)
                            }
                            // Claude Code backend: round quick-apply / setup button,
                            // shown only for providers with a key that can back Claude Code.
                            if ClaudeCodeQuickApplyButton.shouldShow(providerID: s.id) {
                                ClaudeCodeQuickApplyButton(providerID: s.id)
                                    .id("\(s.id)-\(claudeCodeTargetRevision)")
                            }
                            if s.id == "claude" {
                                ClaudeCodeProfileSwitchSection()
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
                            // Claude-specific: own monthly budget vs. spend —
                            // only when a Claude budget is configured; renders
                            // even before the scan lands (confidence nil →
                            // "no cost data" row, never a fake status).
                            if s.id == "claude", settings.claudeMonthlyBudgetUSD.isFinite,
                               settings.claudeMonthlyBudgetUSD > 0 {
                                let claudeBudgetCombined = claudeReport.map {
                                    CombinedUsageReport.build(
                                        claude: $0, codex: nil, grok: nil,
                                        includeClaude: true, includeCodex: false, includeGrok: false)
                                }
                                ProviderBudgetCard(
                                    providerId: "claude", providerName: "Claude",
                                    color: VocabbyTheme.chartClaude,
                                    budgetUSD: settings.claudeMonthlyBudgetUSD,
                                    confidence: claudeBudgetCombined?.claudeConfidence,
                                    daily: claudeBudgetCombined?.daily ?? [],
                                    source: .claude)
                            }
                            // Codex-specific: 30-day cost chart + top-model line,
                            // scanned only when the Codex tab is open.
                            if s.id == "codex", let report = codexReport,
                               !report.isEmpty {
                                CodexUsageChartCard(report: report)
                            }
                            // Codex-specific: own monthly budget vs. spend —
                            // same gating/trust rule as the Claude card above.
                            if s.id == "codex", settings.codexMonthlyBudgetUSD.isFinite,
                               settings.codexMonthlyBudgetUSD > 0 {
                                let codexBudgetCombined = codexReport.map {
                                    CombinedUsageReport.build(
                                        claude: nil, codex: $0, grok: nil,
                                        includeClaude: false, includeCodex: true, includeGrok: false)
                                }
                                ProviderBudgetCard(
                                    providerId: "codex", providerName: "Codex",
                                    color: VocabbyTheme.chartCodex,
                                    budgetUSD: settings.codexMonthlyBudgetUSD,
                                    confidence: codexBudgetCombined?.codexConfidence,
                                    daily: codexBudgetCombined?.daily ?? [],
                                    source: .codex)
                            }
                            // Codex-specific: account list (click to reveal) +
                            // CLI switch. Below the chart per user preference.
                            if s.id == "codex" {
                                CodexProfileSwitchSection()
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
                            // Grok-specific: own monthly budget vs. spend —
                            // same gating/trust rule as the Claude/Codex cards.
                            if s.id == "grok", settings.grokMonthlyBudgetUSD.isFinite,
                               settings.grokMonthlyBudgetUSD > 0 {
                                let grokBudgetCombined = grokReport.map {
                                    CombinedUsageReport.build(
                                        claude: nil, codex: nil, grok: $0,
                                        includeClaude: false, includeCodex: false, includeGrok: true)
                                }
                                ProviderBudgetCard(
                                    providerId: "grok", providerName: "Grok",
                                    color: VocabbyTheme.chartGrok,
                                    budgetUSD: settings.grokMonthlyBudgetUSD,
                                    confidence: grokBudgetCombined?.grokConfidence,
                                    daily: grokBudgetCombined?.daily ?? [],
                                    source: .grok)
                            }
                            // Kiro: 30-day usage chart from local kiro-cli
                            // sessions (~/.kiro/sessions sidecars with real
                            // metered credits + legacy SQLite/archives).
                            if s.id == "kiro", let report = kiroReport,
                               !report.isEmpty {
                                KiroUsageChartCard(report: report)
                            }
                            // Status page at the bottom of the provider stack
                            // (flat row, same instrument language as credits/meta).
                            ServiceStatusStrip(status: s)
                        }
                    }
                }
                // No expanding Spacer: the panel height hugs content via
                // AppDelegate.fittingSize. A Spacer here absorbed leftover
                // host height (seed / prior tall tab) into a visible gap
                // between the last section (e.g. Accounts) and the footer.
                ActionsList()
            }
            // No horizontal pad here: header/tabs own full-bleed rules;
            // body sections inset content + hairlines themselves.
            .padding(.vertical, 0)
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

    private var statusTone: Color {
        isRefreshing ? VocabbyTheme.yellow : VocabbyTheme.success
    }

    private var statusSurface: Color {
        isRefreshing ? VocabbyTheme.warningSurface : VocabbyTheme.successSurface
    }

    var body: some View {
        HStack(spacing: 8) {
            // Compact brand mark replaces the duplicated wordmark text.
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 42, height: 28)
                .accessibilityLabel("BirdNion")

            HStack(spacing: 5) {
                Rectangle()
                    .fill(statusTone)
                    .frame(width: 5, height: 5)
                // Design uses CSS text-transform: uppercase on sentence case copy.
                Text((isRefreshing
                      ? L10n.t("popover.updating", settings.appLanguage)
                      : L10n.t("popover.ready", settings.appLanguage)).uppercased())
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(statusTone)
                    .tracking(0.6)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                headerIconButton(
                    systemName: isRefreshing ? nil : "arrow.clockwise",
                    spinning: isRefreshing,
                    label: L10n.t("popover.refresh", settings.appLanguage),
                    disabled: isRefreshing
                ) {
                    NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                }

                // Toggle light ↔ dark. Icon shows the *target* mode (sun → go
                // light, moon → go dark). Settings stays on the footer gear.
                headerIconButton(
                    systemName: isEffectivelyDark ? "sun.max" : "moon",
                    spinning: false,
                    label: isEffectivelyDark
                        ? L10n.t("popover.appearance.light", settings.appLanguage)
                        : L10n.t("popover.appearance.dark", settings.appLanguage),
                    disabled: false
                ) {
                    toggleAppearance()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 11)
        .overlay(alignment: .bottom) {
            VocabbyTheme.inkRule.frame(height: 1)
        }
    }

    /// Resolved dark/light for the header toggle (auto follows system).
    private var isEffectivelyDark: Bool {
        switch AppAppearance(rawValue: settings.appAppearance) ?? .auto {
        case .dark: return true
        case .light: return false
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func toggleAppearance() {
        let next: AppAppearance = isEffectivelyDark ? .light : .dark
        settings.appAppearance = next.rawValue
        settings.applyAppearance()
    }

    /// Design header actions: 26×26, r4, border #DCD8CD, icon 14.
    private func headerIconButton(systemName: String?,
                                  spinning: Bool,
                                  label: String,
                                  disabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if spinning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VocabbyTheme.muted)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(disabled ? VocabbyTheme.muted : VocabbyTheme.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(VocabbyTheme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Provider Tabs

/// Horizontal pill strip for provider selection (remake mockup).
/// Selected = accent fill + white label; unselected = segment fill + secondary.
/// Selection binding + scroll behaviour unchanged — style only.
struct ProviderTabs: View {
    static let chipHeight: CGFloat = 28

    @EnvironmentObject var settings: SettingsStore

    let providers: [ProviderStatus]
    @Binding var selectedId: String
    /// Renders the combined "All" pseudo-tab ahead of the provider chips.
    var showAllTab: Bool = false

    var body: some View {
        // Logo-only unselected chips keep a typical roster on one row, so the
        // ScrollView is a fallback for extreme rosters only (with a mouse it
        // needs Shift+wheel — acceptable for that edge case).
        //
        // The ScrollView wrapper is LOAD-BEARING, not cosmetic: hosting the
        // chip row bare (plain HStack, report 2026-07-20-141127) or in a
        // wrapping custom Layout (report 2026-07-20-140946) both recursed
        // NSISEngine ("invalid baselines") ~6s after launch, when the first
        // cost-scan publish relayouts the auto-sizing popover host. Keep the
        // strip inside a ScrollView.
        // Design strip: content inset 16 (same as body hero), gap 6,
        // one full-bleed hairline under the strip. Padding lives outside
        // the ScrollView so chips share the same left edge as TOTAL COST.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showAllTab {
                    allChip
                }
                ForEach(providers) { provider in
                    chip(for: provider)
                }
            }
            .padding(.vertical, 10)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .popoverContentInset()
        .overlay(alignment: .bottom) {
            VocabbyTheme.hairline.frame(height: 1)
        }
    }

    /// Combined-overview pseudo-tab — design: icon-only grid square; selected
    /// = ink fill (not blue pill with text).
    private var allChip: some View {
        let active = selectedId == "all"
        let label = L10n.t("popover.allTab", settings.appLanguage)
        return Button {
            selectedId = "all"
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(active ? VocabbyTheme.primary : VocabbyTheme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private func chip(for p: ProviderStatus) -> some View {
        let active = p.id == selectedId
        // Design: logo-only squares; selected = ink fill + paper logo.
        // Brand tint on idle logos; no expanded name (keeps one compact row).
        let logoTint: Color = active
            ? VocabbyTheme.background
            : (VocabbyTheme.providerTint(p.id) ?? VocabbyTheme.secondary)
        Button {
            selectedId = p.id
        } label: {
            ProviderLogoMark(id: p.id, tint: logoTint)
                .frame(width: 15, height: 15)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(active ? VocabbyTheme.primary : VocabbyTheme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    // Design: 5×5 mark at chip corner — CSS `top: -1px; right: -1px`
                    // (flush top-right, 1pt outside the border).
                    if !active, let tint = VocabbyTheme.providerTint(p.id) {
                        Rectangle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(p.displayName)
        .accessibilityLabel(p.displayName)
        .accessibilityAddTraits(active ? .isSelected : [])
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
        case "tryapi":
            logo("TryAPILogo", brand: VocabbyTheme.tryAPI)
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
        case "xai":
            logo("XAILogo", brand: VocabbyTheme.xai)
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
    /// Lowest-remaining active window across the status, ignoring supplementary
    /// bonus-credit windows (see `QuotaWindow.isSupplementary`) and inactive
    /// zero-sized windows (see `QuotaWindow.isInactive`) so neither can outrank
    /// a healthy primary quota as the "Lowest Quota" headline. Falls back to any
    /// noninactive window only when no active primary exists.
    static func lowestWindow(_ status: ProviderStatus) -> QuotaWindow? {
        let primary = status.windows.filter { !$0.isSupplementary && !$0.isInactive }
        if let lowest = primary.min(by: { $0.remainingPct < $1.remainingPct }) {
            return lowest
        }
        return status.windows
            .filter { !$0.isInactive }
            .min { $0.remainingPct < $1.remainingPct }
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

    /// Design header meta: `PLAN · SOURCE · RELATIVE` (no email clutter).
    /// Account email stays available via Settings when hide-personal is off.
    private var metadataParts: [String] {
        var parts: [String] = []
        if let plan = planLabel {
            parts.append(L10n.providerText(plan, preference: settings.appLanguage))
        }
        if let source = status.sourceLabel, !source.isEmpty {
            parts.append(L10n.providerText(source, preference: settings.appLanguage))
        }
        // Fall back to account only when plan/source are both empty (rare).
        if parts.isEmpty,
           let account = status.accountLabel, !account.isEmpty,
           !settings.hidePersonalInfo {
            parts.append(account)
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

    var body: some View {
        // Design: plate 34, logo 20, name 15/600, meta mono 11 #7A776C, TRAY.
        HStack(alignment: .center, spacing: 12) {
            ProviderLogoMark(
                id: status.id,
                tint: VocabbyTheme.providerTint(status.id) ?? VocabbyTheme.primary
            )
            .frame(width: 20, height: 20)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(VocabbyTheme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(status.displayName)
                    .font(.plexSans(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(VocabbyTheme.primary)
                if isPlaceholder {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                            .frame(width: 12, height: 12)
                        Text(L10n.t("provider.loading", settings.appLanguage))
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.muted)
                    }
                } else {
                    Text(metadataParts.joined(separator: " · ").uppercased())
                        .font(.plexMono(11))
                        .foregroundStyle(VocabbyTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MenuBarVisibilityToggle(providerId: status.id, hasError: hasError)
                .id("menuBarVis.\(status.id)")
        }
        .popoverContentInset()
        // Design body pad after tabs (16pt) — without this the name row
        // sits flush under the provider chip strip.
        .padding(.top, 16)
        .padding(.bottom, 2)
        .background(VocabbyTheme.background)
    }

    /// Design credits row (sits with window list): `CREDITS` · `$24.80 CÒN LẠI`
    static func creditsRow(credits: Double,
                           language: String,
                           creditsText: String) -> some View {
        HStack {
            Text(L10n.t("provider.creditsAvailable", language).uppercased())
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.6)
            Spacer(minLength: 8)
            Text(L10n.f("provider.creditsLeft", language, "$\(creditsText)").uppercased())
                .font(.plexMono(12, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
        }
        .popoverContentInset()
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            PopoverInsetHairline()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("provider.creditsAvailable", language) + ": " + creditsText)
    }
}

// MARK: - Service status strip

/// Flat footer row at the bottom of each provider stack — same language as
/// credits/meta rows (mono eyebrow, hairline top, no filled chip).
/// Claude / Codex: `TÌNH TRẠNG` · ● Ổn định / Sự cố · ↗
/// Grok: link only (no health claim — xAI has no public status feed).
struct ServiceStatusStrip: View {
    @EnvironmentObject var settings: SettingsStore
    let status: ProviderStatus

    private var lang: String { settings.appLanguage }

    private var strip: ProviderStatusPage.Strip? {
        ProviderStatusPage.strip(
            for: status,
            statusChecksEnabled: settings.statusChecksEnabled)
    }

    private var pageURL: URL? { ProviderStatusPage.url(for: status.id) }

    private var detailTooltip: String {
        if let detail = ProviderStatusPage.detailText(for: status) {
            return L10n.providerText(detail, preference: lang)
        }
        return pageURL?.absoluteString ?? ""
    }

    var body: some View {
        if let strip, let url = pageURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.t("provider.serviceStatus", lang).uppercased())
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.muted)
                        .tracking(0.6)
                    Spacer(minLength: 8)
                    trailing(for: strip)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popoverContentInset()
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                PopoverInsetHairline()
            }
            .accessibilityLabel(accessibilityLabel(for: strip))
            .help(detailTooltip)
        }
    }

    @ViewBuilder
    private func trailing(for strip: ProviderStatusPage.Strip) -> some View {
        switch strip {
        case .health(let health):
            HStack(spacing: 6) {
                Circle()
                    .fill(accent(for: health))
                    .frame(width: 7, height: 7)
                Text(shortLabel(for: health))
                    .font(.plexMono(11, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        case .linkOnly:
            // Grok: open status page only — no green/red claim without a feed.
            HStack(spacing: 4) {
                Text(L10n.t("provider.link.status", lang))
                    .font(.plexMono(11, weight: .medium))
                    .foregroundStyle(VocabbyTheme.blue)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.blue)
            }
        }
    }

    private func shortLabel(for health: ProviderStatusPage.Health) -> String {
        switch health {
        case .ok: return L10n.t("provider.serviceStatus.ok", lang)
        case .issue: return L10n.t("provider.serviceStatus.issue", lang)
        }
    }

    private func accent(for health: ProviderStatusPage.Health) -> Color {
        switch health {
        case .ok: return VocabbyTheme.success
        case .issue: return VocabbyTheme.critical
        }
    }

    private func accessibilityLabel(for strip: ProviderStatusPage.Strip) -> String {
        switch strip {
        case .health(let health):
            return L10n.t("provider.serviceStatus", lang) + ": " + shortLabel(for: health)
        case .linkOnly:
            return L10n.t("provider.link.status", lang)
        }
    }
}

// MARK: - xAI spend

/// xAI exposes money spend without a recurring quota limit. Keep it separate
/// from quota bars so a zero limit never renders as a fake budget.
struct XAISpendCard: View {
    @EnvironmentObject var settings: SettingsStore

    let cost: ProviderCostSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("xai.spend", settings.appLanguage))
                    .font(.plexMono(10, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .tracking(0.6)
                Spacer()
                Text(UsageFormatter.usdString(cost.used))
                    .font(.plexMono(14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(L10n.providerText(cost.period ?? "Last 30 days", preference: settings.appLanguage))
                .font(.plexSans(10))
                .foregroundStyle(VocabbyTheme.secondary)
        }
        .popoverContentInset()
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VocabbyTheme.background)
        .popoverHairlineTop()
    }
}

// MARK: - Provider Card + Window Row

/// Per-provider card: windows (or error / loading). Summary strip is rendered
/// by the parent so it can sit as its own mockup-style card above this one.
struct ProviderCard: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

    let status: ProviderStatus

    /// Finite credit balance shown as design `CREDITS` row (Codex today;
    /// any provider with remaining credits can share this chrome).
    private var creditsBalance: Double? {
        guard !status.creditsUnlimited,
              let credits = status.creditsRemaining,
              credits.isFinite,
              credits > 0
        else { return nil }
        return credits
    }

    /// Popover window list. Optional model-specific rows honor Settings toggles
    /// (Codex Spark / Claude Fable, default on); other surfaces keep full data.
    private var popoverWindows: [QuotaWindow] {
        switch status.id {
        case "codex" where !settings.codexShowSparkInPopover:
            return status.windows.filter { !CodexProvider.isSparkWindowLabel($0.label) }
        case "claude" where !settings.claudeShowFableInPopover:
            return status.windows.filter { !ClaudeProvider.isFableWindowLabel($0.label) }
        default:
            return status.windows
        }
    }

    private func creditsText(_ credits: Double) -> String {
        credits.rounded() == credits
            ? String(Int(credits))
            : String(format: "%.2f", credits)
    }

    var body: some View {
        // Design: windows list under hairline; optional CREDITS last row.
        VStack(alignment: .leading, spacing: 0) {
            if let err = status.error {
                // Same classifier semantics as the Settings self-test
                // (`ProvidersPane.classifiedMessage`): show the actionable hint,
                // not the raw string — the raw text stays reachable via
                // `.help()`. Retry is always available for a provider error;
                // Fix only shows when the kind is something Settings can
                // actually fix (config/credential/cookie), never for a
                // rate-limit or network error.
                let kind = classify(rawError: err) ?? .unknown
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(VocabbyTheme.critical)
                        Text(L10n.t(kind.hintKey, settings.appLanguage))
                            .font(.plexSans(11))
                            .foregroundStyle(VocabbyTheme.critical)
                            .lineLimit(2)
                            .help(L10n.providerText(err, preference: settings.appLanguage))
                    }
                    HStack(spacing: 8) {
                        Button(L10n.languageCode(settings.appLanguage) == "vi" ? "Thử lại" : "Retry") {
                            Task { await quota.refresh(forceProviderIDs: [status.id]) }
                        }
                        .controlSize(.small)
                        if kind.isFixable {
                            Button(L10n.languageCode(settings.appLanguage) == "vi" ? "Sửa" : "Fix") {
                                openProviderSettings(status.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .popoverContentInset()
                .padding(.vertical, 10)
            } else if status.windows.isEmpty {
                LoadingQuotaSkeleton()
                    .popoverContentInset()
                    .padding(.vertical, 8)
            } else if status.id == "antigravity" {
                if let warning = quota.staleWarning(for: status.id) {
                    StaleQuotaBanner(providerID: status.id, warning: warning)
                }
                AntigravitySemanticQuotaRows(windows: status.windows, lastUpdated: status.lastUpdated)
            } else {
                if let warning = quota.staleWarning(for: status.id) {
                    StaleQuotaBanner(providerID: status.id, warning: warning)
                }
                ForEach(popoverWindows) { win in
                    WindowRow(
                        window: win,
                        providerID: status.id,
                        lastUpdated: status.lastUpdated)
                }
            }
            if let credits = creditsBalance {
                ProviderHeaderCard.creditsRow(
                    credits: credits,
                    language: settings.appLanguage,
                    creditsText: creditsText(credits))
            }
        }
        // Error / empty rows keep content inset; window rows pad themselves.
        // Section rule is inset (only header + tabs are edge-to-edge).
        .padding(.top, 16)
        .overlay(alignment: .top) {
            PopoverInsetHairline()
        }
    }
}

/// Compact outlined action for the stale banner. The Settings pane's
/// `InstrumentInlineButtonStyle` is scoped to `SettingsTheme`, so the popover
/// carries its own warning-tinted variant rather than importing that idiom.
private struct StaleBannerActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.plexMono(9, weight: .medium))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(VocabbyTheme.warningFill)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(VocabbyTheme.warningFill.opacity(configuration.isPressed ? 0.55 : 0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

/// Shown above a provider's quota windows when the most recent refresh failed
/// while a prior last-good snapshot is still on screen — see
/// `QuotaService.staleWarning(for:)`. Reached by a transient failure
/// (network/timeout, rate-limit, genuine 5xx) or by the one free pass the
/// consecutive-failure gate grants `.notConfigured`.
///
/// Windows stay visible, so this is a *notice*, not an error: it names the
/// cause via `staleCauseKey` rather than the error card's `hintKey`, which is
/// phrased as an instruction and would tell the user to reconnect a provider
/// that is working fine. Never shows the raw provider error/response.
private struct StaleQuotaBanner: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

    let providerID: String
    let warning: StaleQuotaWarning

    private var isVietnamese: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title and action share a row so the banner reads as one block
            // instead of a text stack with a button bolted underneath.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.warningFill)
                Text(L10n.t("staleQuota.notice", settings.appLanguage))
                    .font(.plexSans(11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.warningFill)
                Spacer(minLength: 8)
                Button(isVietnamese ? "Thử lại" : "Retry") {
                    Task { await quota.refresh(forceProviderIDs: [providerID]) }
                }
                .buttonStyle(StaleBannerActionStyle())
                .pointingHandCursor()
            }

            Text(L10n.t(warning.kind.staleCauseKey, settings.appLanguage))
                .font(.plexSans(10))
                .foregroundStyle(VocabbyTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Mono/uppercase matches how the popover renders every other
            // timestamp (header status, footer "UPDATED …").
            Text(L10n.f("popover.lastUpdated", settings.appLanguage,
                        L10n.relativeUpdated(from: warning.lastGoodUpdated, preference: settings.appLanguage)))
                .font(.plexMono(9, weight: .medium))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(VocabbyTheme.warningSurface)
        )
        .overlay(
            // Hairline outline mirrors the Linux banner and the app's rule-based
            // chrome; a bare fill read as an untethered colour block.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.warningFill.opacity(0.22), lineWidth: 1)
        )
        .popoverContentInset()
        .padding(.top, 8)
        .padding(.bottom, 2)
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
                        .font(.plexSans(10))
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
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(removeConfirmationMessage)
                        .font(.plexSans(11, weight: .medium))
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
                            .font(.plexSans(12, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.critical)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                    .fill(Color.white.opacity(0.26))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    Button {
                        dismissRemoveConfirmation()
                    } label: {
                        Text(L10n.t("ccx.pasteJSON.cancel", settings.appLanguage))
                            .font(.plexSans(12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
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
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
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
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("popover.accounts", lang))
                    .font(.plexSans(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(activeLabel)
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(accounts.count)")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(VocabbyTheme.segment)
                )
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
                    .font(.plexSans(12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                Text(account.isSystem
                     ? L10n.t("provider.systemManaged", settings.appLanguage)
                     : L10n.t("provider.appManaged", settings.appLanguage))
                    .font(.plexSans(10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 6)
            Text(quota.text)
                .font(.plexMono(10, weight: .semibold))
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
                        .font(.plexMono(9, weight: .semibold))
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
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
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
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.secondary)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                    Text(L10n.t("provider.addAccount", settings.appLanguage))
                        .font(.plexSans(12))
                }
            }
            if let addAccountErrorText {
                Text(L10n.f("provider.addAccountFailed", settings.appLanguage, addAccountErrorText))
                    .font(.plexSans(10))
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
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.t("popover.cliCard.title", lang))
                        .font(.plexSans(12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    HStack(spacing: 3) {
                        Image(systemName: alreadyInCLI ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(L10n.t(alreadyInCLI ? "popover.accountSelected" : "popover.switchReady", lang))
                            .font(.plexMono(10, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                }
                Text(hint)
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let switchErrorText {
                    Text(L10n.f("popover.switchFailed", lang, switchErrorText))
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(1)
                } else {
                    Text("~/.codex/auth.json")
                        .font(.plexMono(10))
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
        .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
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

    /// Design: `QUOTA THẤP NHẤT · 5 GIỜ` (window name, not provider name).
    private var eyebrow: String {
        let base = L10n.t("popover.lowestQuota", settings.appLanguage).uppercased()
        guard let lowest else { return base }
        let label = L10n.windowLabel(lowest.label, preference: settings.appLanguage).uppercased()
        return "\(base) · \(label)"
    }

    private var resetText: String {
        guard let lowest else { return "" }
        if let d = lowest.resetDate {
            return L10n.resetCountdown(to: d, preference: settings.appLanguage).uppercased()
        }
        if let secs = lowest.windowSeconds, secs > 0 {
            let estimate = status.lastUpdated.addingTimeInterval(TimeInterval(secs))
            return L10n.resetCountdown(to: estimate, preference: settings.appLanguage).uppercased()
        }
        return ""
    }

    var body: some View {
        // Design: mt16 pt14 ink top · eyebrow · 34px % · right mono 11/1.6.
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.muted)
                .tracking(0.8)
            HStack(alignment: .bottom, spacing: 12) {
                Text("\(lowest?.remainingPct ?? 0)%")
                    .font(.plexMono(34, weight: .semibold))
                    .foregroundStyle(tone)
                    .tracking(-1.2)
                    .padding(.top, 8)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    if !resetText.isEmpty {
                        Text(resetText)
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.muted)
                    }
                    if let lowest {
                        Text(L10n.f("quota.usedPct", settings.appLanguage, lowest.usedPct).uppercased())
                            .font(.plexMono(11))
                            .foregroundStyle(VocabbyTheme.muted)
                    }
                }
                .lineSpacing(4) // ~1.6 line-height optical
            }
        }
        // Design: margin-top 16 + padding-top 14 under ink rule (inset).
        // Bottom 16 keeps RESETS/USED clear of the next section hairline.
        .popoverContentInset()
        .padding(.top, 30)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            PopoverInsetHairline(color: VocabbyTheme.inkRule)
                .padding(.top, 16)
        }
        .accessibilityElement(children: .combine)
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
    /// Provider id used to keep the quota fill aligned with the provider's
    /// brand color. The quota percentage still controls the fill length and
    /// the semantic text color remains independent.
    let providerID: String
    /// Fetch timestamp from the parent `ProviderStatus` — used as the
    /// anchor for the `lastUpdated + windowSeconds` reset estimate when
    /// the API didn't return an explicit reset timestamp.
    let lastUpdated: Date

    /// Design: bar + % use semantic remaining tone (critical / warning / success),
    /// not provider brand fill.
    private var barFillColor: Color {
        guard !window.isInactive else { return VocabbyTheme.track }
        return VocabbyTheme.quotaColor(remaining: window.remainingPct)
    }

    private var percentTextColor: Color {
        window.isInactive ? VocabbyTheme.tertiary : VocabbyTheme.quotaColor(remaining: window.remainingPct)
    }

    /// Linear pace vs the window's elapsed time — powers the CodexBar-style
    /// marker stripe on the bar and the reserve/deficit detail line.
    private var pace: WindowPace? { WindowPace(window: window, now: Date()) }

    /// "X% in reserve" / "X% in deficit" / "On pace" — CodexBar wording.
    private func paceLeftText(_ pace: WindowPace) -> String {
        if pace.isOnTrack { return L10n.t("pace.onPace", settings.appLanguage) }
        return pace.deltaPct > 0
            ? L10n.f("pace.deficit", settings.appLanguage, pace.deltaPct)
            : L10n.f("pace.reserve", settings.appLanguage, -pace.deltaPct)
    }

    /// "Lasts until reset" / "Runs out in ~X" — projection at the current rate.
    private func paceRightText(_ pace: WindowPace) -> String? {
        if pace.lastsUntilReset { return L10n.t("pace.lastsToReset", settings.appLanguage) }
        guard let eta = pace.etaSeconds else { return nil }
        return L10n.f("pace.runsOutIn", settings.appLanguage, WindowPace.format(eta))
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
        // Design MetricRow:
        //   LABEL                          18%
        //   [=========== bar ============]
        //   ĐÃ DÙNG 82%          RESET SAU …
        //   12% DỰ PHÒNG · ĐỦ ĐẾN KHI RESET   (pace, optional)
        // Design: pad 12 0 · label 10/500 · % 12/600 · bar h4 mt8 · foot 10 mt7
        let pace = self.pace
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowLabel(window.label, preference: settings.appLanguage).uppercased())
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .tracking(0.6)
                Spacer(minLength: 8)
                Text(window.isInactive ? "—" : "\(window.remainingPct)%")
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(percentTextColor)
            }
            QuotaBarWithPaceMarker(
                remainingPct: window.isInactive ? 0 : window.remainingPct,
                fillColor: barFillColor,
                // Design mock has no pace marker stripe — keep bar clean.
                markerPct: nil)
            .padding(.top, 8)
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if window.isInactive {
                        Text("—")
                    } else if let pace, !pace.isOnTrack || !pace.lastsUntilReset {
                        // Design merges pace into left foot when off-track.
                        Text(paceLine(pace).uppercased())
                    } else {
                        Text(L10n.f("quota.usedPct", settings.appLanguage, window.usedPct).uppercased())
                    }
                }
                .font(.plexMono(10))
                .foregroundStyle(
                    (pace?.lastsUntilReset == false)
                    ? VocabbyTheme.warningFill
                    : VocabbyTheme.tertiary
                )
                .lineLimit(2)
                Spacer()
                if !resetText.isEmpty {
                    Text(resetText.uppercased())
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .padding(.top, 7)
            if let sub = window.subtitle, !sub.isEmpty, pace == nil || pace?.isOnTrack == true {
                Text(L10n.providerText(sub, preference: settings.appLanguage).uppercased())
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .padding(.top, 4)
            }
        }
        .popoverContentInset()
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            PopoverInsetHairline()
        }
    }

    private func paceLine(_ pace: WindowPace) -> String {
        let left = paceLeftText(pace)
        if let right = paceRightText(pace) {
            return "\(left) · \(right)"
        }
        return left
    }
}

/// Remaining-quota capsule bar with an optional CodexBar-style pace marker: a
/// thin neutral stripe at the position usage "should" be if consumption were
/// linear over the window. Fill left of the stripe = reserve, right = deficit.
enum QuotaBarLayout {
    /// Design window track height (provider mock: `height: 4px`).
    static let compactHeight: CGFloat = 4
}

struct QuotaBarWithPaceMarker: View {
    let remainingPct: Int
    let fillColor: Color
    /// Marker position in REMAINING coordinates (0–100). nil = no marker.
    let markerPct: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Instrument redesign: thin square-cornered track/fill instead
                // of a rounded capsule (matches CSS `.window-track`).
                Rectangle()
                    .fill(VocabbyTheme.track)
                    .frame(height: QuotaBarLayout.compactHeight)
                Rectangle()
                    .fill(fillColor)
                    .frame(
                        width: max(0, geo.size.width * CGFloat(remainingPct) / 100),
                        height: QuotaBarLayout.compactHeight)
                if let marker = markerPct, marker > 0.5, marker < 99.5 {
                    // Taller-than-bar stripe like CodexBar's pace tip.
                    Rectangle()
                        .fill(VocabbyTheme.primary.opacity(0.55))
                        .frame(width: 1.5, height: 8)
                        .offset(x: geo.size.width * CGFloat(marker) / 100 - 0.75, y: -2)
                }
            }
        }
        .frame(height: QuotaBarLayout.compactHeight)
    }
}

// MARK: - Antigravity semantic quota rows

/// Semantic quota rows for Antigravity, grouped by the model pool that shares
/// each limit. Layout matches `WindowRow` (inset + hairline) so bars never
/// hug the popover edge and GeometryReader cannot float fill strips.
struct AntigravitySemanticQuotaRows: View {
    let windows: [QuotaWindow]
    let lastUpdated: Date

    private static let order = [
        "Gemini 5-hour",
        "Gemini weekly",
        "Claude/GPT 5-hour",
        "Claude/GPT weekly",
        "Gemini",
        "Claude/GPT",
    ]

    private var semanticWindows: [QuotaWindow] {
        windows
            .filter { Self.order.contains($0.label) }
            .sorted {
                guard let lhs = Self.order.firstIndex(of: $0.label),
                      let rhs = Self.order.firstIndex(of: $1.label)
                else { return false }
                return lhs < rhs
            }
            .prefix(4)
            .map { $0 }
    }

    private var geminiWindows: [QuotaWindow] {
        semanticWindows.filter { $0.label.hasPrefix("Gemini") }
    }

    private var claudeGPTWindows: [QuotaWindow] {
        semanticWindows.filter { $0.label.hasPrefix("Claude/GPT") }
    }

    @ViewBuilder
    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.plexMono(10, weight: .medium))
            .foregroundStyle(VocabbyTheme.muted)
            .tracking(0.6)
            .popoverContentInset()
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func quotaGroup(title: String, windows: [QuotaWindow]) -> some View {
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader(title)
                ForEach(windows) { window in
                    AntigravitySemanticQuotaRow(window: window, lastUpdated: lastUpdated)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quotaGroup(title: "Gemini", windows: geminiWindows)
            // No extra between-group rule: each row already draws the same
            // inset hairline as `WindowRow` (aligned to the quota bar width).
            // A second `.popoverContentInset()` rule here was shorter than the bar.
            quotaGroup(title: "Claude/GPT", windows: claudeGPTWindows)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AntigravitySemanticQuotaRow: View {
    @EnvironmentObject var settings: SettingsStore

    let window: QuotaWindow
    let lastUpdated: Date

    private var percentColor: Color {
        VocabbyTheme.quotaColor(remaining: window.remainingPct)
    }

    /// Short window label: "Gemini 5-hour" → "5 HOURS", "Claude/GPT weekly" → "WEEK".
    private var shortLabel: String {
        let raw = window.label.lowercased()
        if raw.contains("5-hour") || raw.contains("5 hour") {
            return L10n.windowLabel("5 giờ", preference: settings.appLanguage).uppercased()
        }
        if raw.contains("week") {
            return L10n.windowLabel("Tuần", preference: settings.appLanguage).uppercased()
        }
        return L10n.windowLabel(window.label, preference: settings.appLanguage).uppercased()
    }

    private var resetText: String {
        if let resetDate = window.resetDate {
            return L10n.resetCountdown(to: resetDate, preference: settings.appLanguage)
        }
        if let seconds = window.windowSeconds, seconds > 0 {
            let estimate = lastUpdated.addingTimeInterval(TimeInterval(seconds))
            return L10n.resetCountdown(to: estimate, preference: settings.appLanguage)
        }
        return ""
    }

    var body: some View {
        // Same MetricRow rhythm as `WindowRow`: label+% · bar · used/reset.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(shortLabel)
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .tracking(0.6)
                Spacer(minLength: 8)
                Text("\(window.remainingPct)%")
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(percentColor)
            }
            AntigravityQuotaBar(remainingPct: window.remainingPct)
                .padding(.top, 8)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.f("quota.usedPct", settings.appLanguage, window.usedPct).uppercased())
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer(minLength: 8)
                if !resetText.isEmpty {
                    Text(resetText.uppercased())
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .padding(.top, 7)
        }
        .popoverContentInset()
        .padding(.vertical, 12)
        // Same as `WindowRow`: overlay hairline on the full row width; the
        // hairline's own horizontal inset matches the bar/text content edges.
        .overlay(alignment: .bottom) {
            PopoverInsetHairline()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(shortLabel), \(window.remainingPct) percent left"
                + (resetText.isEmpty ? "" : ", resets \(resetText)")
        )
    }
}

private struct AntigravityQuotaBar: View {
    let remainingPct: Int

    private var googleGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                VocabbyTheme.googleBlue,
                VocabbyTheme.googleRed,
                VocabbyTheme.googleYellow,
                VocabbyTheme.googleGreen,
            ]),
            startPoint: .leading,
            endPoint: .trailing)
    }

    var body: some View {
        // Match `QuotaBarWithPaceMarker`: fixed-height GeometryReader so the
        // fill cannot float/expand into neighboring rows.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(VocabbyTheme.track)
                    .frame(height: QuotaBarLayout.compactHeight)
                Rectangle()
                    .fill(googleGradient)
                    .frame(
                        width: max(0, geo.size.width * CGFloat(max(0, min(100, remainingPct))) / 100),
                        height: QuotaBarLayout.compactHeight)
            }
        }
        .frame(height: QuotaBarLayout.compactHeight)
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
                        .font(.plexSans(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .padding(.vertical, 4)
                }
                ForEach(keys) { key in
                    keyRow(key)
                }
                if let errorText {
                    Text(errorText)
                        .font(.plexSans(10))
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
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("elevenlabs.popoverTitle", lang))
                    .font(.plexSans(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(active.map(displayName) ?? L10n.t("elevenlabs.keysEmpty", lang))
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(keys.count)")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(VocabbyTheme.segment)
                )
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
                    .font(.plexSans(12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(key.preview + "…")
                    .font(.plexMono(10))
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
                        .background(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .fill(VocabbyTheme.blue.opacity(0.10))
                        )
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
                        .font(.plexSans(10))
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
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("popover.accounts", lang))
                    .font(.plexSans(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(active.map(accountName) ?? L10n.t("freemodel.browserAuto", lang))
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(accounts.count)")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(VocabbyTheme.segment)
                )
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
                .font(.plexSans(12, weight: .medium))
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
                        .background(
                            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                                .fill(VocabbyTheme.blue.opacity(0.10))
                        )
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

/// Footer row: last-refresh caption (left) + mono text links (right).
/// Footer: "UPDATED …" left + icon buttons Settings / About / Quit.
struct ActionsList: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

    /// Most recent provider `lastUpdated` across the live display list.
    /// Nil when nothing has been fetched yet (don't invent a timestamp).
    private var lastRefreshCaption: String? {
        guard let latest = quota.displayStatuses.map(\.lastUpdated).max() else {
            return nil
        }
        let relative = L10n.relativeUpdated(from: latest, preference: settings.appLanguage)
        return L10n.f("popover.lastUpdated", settings.appLanguage, relative)
    }

    private var lang: String { settings.appLanguage }

    var body: some View {
        HStack(spacing: 8) {
            if let lastRefreshCaption {
                Text(lastRefreshCaption.uppercased())
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .tracking(0.4)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            footerIcon(
                systemName: "gearshape",
                label: L10n.t("popover.settings", lang),
                tint: VocabbyTheme.secondary
            ) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            footerIcon(
                systemName: "info.circle",
                label: L10n.t("popover.about", lang),
                tint: VocabbyTheme.secondary
            ) {
                AboutPresenter.show()
            }
            footerIcon(
                systemName: "power",
                label: L10n.t("popover.quit", lang),
                tint: VocabbyTheme.critical
            ) {
                NSApp.terminate(nil)
            }
        }
        .popoverContentInset()
        .padding(.top, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            // Body rule — inset; only header + tabs stay edge-to-edge.
            PopoverInsetHairline()
        }
    }

    /// Square icon control matching header actions (26×26, r4, hairline border).
    private func footerIcon(systemName: String,
                            label: String,
                            tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(VocabbyTheme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .stroke(VocabbyTheme.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer()
                if let s = shortcut {
                    Text(s)
                        .font(.plexMono(10, weight: .medium))
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

// MARK: - AI coding profile quick switch

/// Pure row state shared by the Claude Code and Codex profile switchers.
/// Every value is derived from the real config writers and proxy runtime;
/// there is no optimistic or separately persisted activation flag.
enum ProfileSwitchHealth: Equatable {
    case needsSetup
    case ready
    case active
    case stale

    static func claude(ready: Bool,
                       sync: ClaudeCodeConfigWriter.SyncState,
                       usesProxy: Bool,
                       proxyRunning: Bool) -> Self {
        guard ready else { return .needsSetup }
        switch sync {
        case .off:
            return .ready
        case .stale:
            return .stale
        case .synced:
            return usesProxy && !proxyRunning ? .stale : .active
        }
    }

    static func codex(ready: Bool,
                      selected: Bool,
                      applied: Bool,
                      usesProxy: Bool,
                      proxyRunning: Bool) -> Self {
        guard ready else { return .needsSetup }
        guard selected else { return applied ? .stale : .ready }
        guard applied else { return .stale }
        return usesProxy && !proxyRunning ? .stale : .active
    }

    var color: Color {
        switch self {
        case .active: return VocabbyTheme.success
        case .stale: return VocabbyTheme.warningFill
        case .needsSetup: return VocabbyTheme.blue
        case .ready: return VocabbyTheme.secondary
        }
    }

    var icon: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .stale: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsSetup: return "exclamationmark.circle.fill"
        case .ready: return "circle"
        }
    }
}

private struct AICodingProfileSwitchHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let count: Int
    @Binding var revealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VocabbyTheme.blue)
                .frame(width: 30, height: 30)
                .background(VocabbyTheme.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.plexSans(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(subtitle)
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.plexMono(11, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .fill(VocabbyTheme.segment)
                )
            Image(systemName: revealed ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { revealed.toggle() }
        .pointingHandCursor()
    }
}

private struct AICodingProfileSwitchRow: View {
    let name: String
    let target: String
    let stateText: String
    let health: ProfileSwitchHealth
    let busy: Bool
    let actionsDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: health.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(health.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.plexSans(12, weight: .medium))
                        .foregroundStyle(VocabbyTheme.primary)
                        .lineLimit(1)
                    Text(target)
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                } else {
                    Text(stateText)
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(health.color)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionsDisabled || health == .active)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(stateText), \(target)")
    }
}

/// Central switcher for custom Claude Code profiles. Preset-provider quick
/// apply cards remain on their own provider tabs; this card owns only custom
/// profiles and therefore does not duplicate an action on the Claude tab.
struct ClaudeCodeProfileSwitchSection: View {
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var localProxy = EmbeddedCLIProxyService.shared

    @State private var profiles: [BirdNionConfigStore.ClaudeCodeProfile] = []
    @State private var revealed = false
    @State private var busyID: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if !profiles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    AICodingProfileSwitchHeader(
                        icon: "terminal",
                        title: L10n.t("claudeCode.quickCard.title", settings.appLanguage),
                        subtitle: activeProfileName ?? L10n.t("ccx.custom", settings.appLanguage),
                        count: profiles.count,
                        revealed: $revealed
                    )
                    if revealed {
                        Divider().overlay(VocabbyTheme.border).padding(.vertical, 6)
                        ForEach(profiles) { profile in
                            let health = health(for: profile)
                            AICodingProfileSwitchRow(
                                name: profileName(profile),
                                target: targetLabel(for: profile),
                                stateText: stateLabel(health),
                                health: health,
                                busy: busyID == profile.id,
                                actionsDisabled: busyID != nil,
                                action: { activate(profile, health: health) }
                            )
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.plexSans(10))
                                .foregroundStyle(VocabbyTheme.critical)
                                .lineLimit(2)
                                .padding(.top, 4)
                        }
                    }
                }
                .vocabbyCard()
            }
        }
        .onAppear(perform: reload)
    }

    private var activeProfileName: String? {
        profiles.first(where: { health(for: $0) == .active }).map(profileName)
    }

    private func health(for profile: BirdNionConfigStore.ClaudeCodeProfile) -> ProfileSwitchHealth {
        guard let scope = scope(for: profile) else { return .needsSetup }
        let ready = ClaudeCodeConfigWriter.isReady(profile)
        let sync = ready
            ? ClaudeCodeConfigWriter.syncState(forProfile: profile, scope: scope, using: config)
            : .off
        return .claude(
            ready: ready,
            sync: sync,
            usesProxy: profile.usesEmbeddedCLIProxy,
            proxyRunning: EmbeddedCLIProxyService.isProfileRunning(
                profile, runtimeState: localProxy.runtimeState)
        )
    }

    private func activate(_ profile: BirdNionConfigStore.ClaudeCodeProfile,
                          health: ProfileSwitchHealth) {
        guard busyID == nil, health != .active else { return }
        guard let targetScope = scope(for: profile), health != .needsSetup else {
            openSettings()
            return
        }
        busyID = profile.id
        errorText = nil
        Task { @MainActor in
            do {
                var prepared = profile
                try EmbeddedCLIProxyService.requireCurrentActivationProfile(prepared)
                if prepared.usesEmbeddedCLIProxy,
                   !EmbeddedCLIProxyService.isProfileRunning(
                       prepared, runtimeState: localProxy.runtimeState) {
                    prepared = try await localProxy.prepare(profile: prepared)
                }
                try EmbeddedCLIProxyService.requireCurrentActivationProfile(prepared)
                try ClaudeCodeConfigWriter.apply(
                    profile: prepared, scope: targetScope, using: config)
                if !prepared.usesEmbeddedCLIProxy {
                    localProxy.deactivateForDirectUpstream()
                }
            } catch let error as EmbeddedCLIProxyService.ServiceError {
                errorText = L10n.t(error.localizationKey, settings.appLanguage)
            } catch {
                errorText = error.localizedDescription
            }
            reload()
            busyID = nil
        }
    }

    private func scope(for profile: BirdNionConfigStore.ClaudeCodeProfile)
    -> ClaudeCodeConfigWriter.Scope? {
        guard profile.claudeCodeScope == "project" else { return .global }
        guard let path = cleaned(profile.claudeCodeProjectPath) else { return nil }
        return .project(URL(fileURLWithPath: path))
    }

    private func targetLabel(for profile: BirdNionConfigStore.ClaudeCodeProfile) -> String {
        guard let targetScope = scope(for: profile) else {
            return L10n.t("claudeCode.quickCard.projectTargetMissing", settings.appLanguage)
        }
        let path = ClaudeCodeConfigWriter.targetURL(scope: targetScope, config: config).path
        return displayPath(path)
    }

    private func stateLabel(_ health: ProfileSwitchHealth) -> String {
        switch health {
        case .active: return L10n.t("codexConfig.state.active", settings.appLanguage)
        case .ready: return L10n.t("codexConfig.state.ready", settings.appLanguage)
        case .stale: return L10n.t("codexConfig.state.stale", settings.appLanguage)
        case .needsSetup: return L10n.t("codexConfig.state.setup", settings.appLanguage)
        }
    }

    private func profileName(_ profile: BirdNionConfigStore.ClaudeCodeProfile) -> String {
        cleaned(profile.name) ?? String(profile.id.prefix(8))
    }

    private func reload() {
        profiles = BirdNionConfigStore.claudeCodeProfiles()
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openClaudeCodeTab, object: nil)
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

/// Switcher for BirdNion-managed Codex CLI profiles. Native OAuth account
/// switching remains a separate card because it changes authentication,
/// whereas this card changes the CLI backend/model configuration.
struct CodexProfileSwitchSection: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var localProxy = EmbeddedCLIProxyService.shared

    @State private var profiles: [BirdNionConfigStore.CodexProfile] = []
    @State private var activeID: String?
    @State private var revealed = false
    @State private var busyID: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if !profiles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    AICodingProfileSwitchHeader(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: L10n.t("codexConfig.target", settings.appLanguage),
                        subtitle: activeProfileName ?? L10n.t("ccx.custom", settings.appLanguage),
                        count: profiles.count,
                        revealed: $revealed
                    )
                    if revealed {
                        Divider().overlay(VocabbyTheme.border).padding(.vertical, 6)
                        ForEach(profiles) { profile in
                            let health = health(for: profile)
                            AICodingProfileSwitchRow(
                                name: profileName(profile),
                                target: L10n.t("codexConfig.target.path", settings.appLanguage),
                                stateText: stateLabel(health),
                                health: health,
                                busy: busyID == profile.id,
                                actionsDisabled: busyID != nil,
                                action: { activate(profile, health: health) }
                            )
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.plexSans(10))
                                .foregroundStyle(VocabbyTheme.critical)
                                .lineLimit(2)
                                .padding(.top, 4)
                        }
                    }
                }
                .vocabbyCard()
            }
        }
        .onAppear(perform: reload)
    }

    private var activeProfileName: String? {
        profiles.first(where: { health(for: $0) == .active }).map(profileName)
    }

    private func health(for profile: BirdNionConfigStore.CodexProfile) -> ProfileSwitchHealth {
        .codex(
            ready: profile.hasUpstreamConfiguration,
            selected: activeID == profile.id,
            applied: CodexConfigWriter.isApplied(profile),
            usesProxy: profile.usesEmbeddedCLIProxy,
            proxyRunning: EmbeddedCLIProxyService.isProfileRunning(
                profile, runtimeState: localProxy.runtimeState)
        )
    }

    private func activate(_ profile: BirdNionConfigStore.CodexProfile,
                          health: ProfileSwitchHealth) {
        guard busyID == nil, health != .active else { return }
        guard health != .needsSetup else {
            openSettings()
            return
        }
        busyID = profile.id
        errorText = nil
        Task { @MainActor in
            do {
                var prepared = profile
                try EmbeddedCLIProxyService.requireCurrentActivationProfile(prepared)
                if prepared.usesEmbeddedCLIProxy {
                    prepared = try await localProxy.prepare(codexProfile: prepared)
                    try EmbeddedCLIProxyService.requireCurrentActivationProfile(prepared)
                    try CodexConfigWriter.apply(profile: prepared)
                } else {
                    prepared.cliProxyAppliedSignature = nil
                    try BirdNionConfigStore.saveCodexProfile(prepared)
                    try CodexConfigWriter.apply(profile: prepared)
                    try await localProxy.deactivateCodexProxyProfiles()
                    try EmbeddedCLIProxyService.requireCurrentActivationProfile(prepared)
                }
                _ = try? CodexConfigWriter.writeProfileFile(for: prepared)
            } catch let error as EmbeddedCLIProxyService.ServiceError {
                errorText = L10n.t(error.localizationKey, settings.appLanguage)
            } catch {
                errorText = error.localizedDescription
            }
            reload()
            busyID = nil
        }
    }

    private func stateLabel(_ health: ProfileSwitchHealth) -> String {
        switch health {
        case .active: return L10n.t("codexConfig.state.active", settings.appLanguage)
        case .ready: return L10n.t("codexConfig.state.ready", settings.appLanguage)
        case .stale: return L10n.t("codexConfig.state.stale", settings.appLanguage)
        case .needsSetup: return L10n.t("codexConfig.state.setup", settings.appLanguage)
        }
    }

    private func profileName(_ profile: BirdNionConfigStore.CodexProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(profile.id.prefix(8)) : trimmed
    }

    private func reload() {
        profiles = BirdNionConfigStore.codexProfiles()
        activeID = CodexConfigWriter.activeProfileID()
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openClaudeCodeTab, object: nil)
        }
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
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.t("claudeCode.quickCard.title", lang))
                        .font(.plexSans(12, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    HStack(spacing: 3) {
                        Image(systemName: stateIcon(state))
                            .font(.system(size: 9, weight: .bold))
                        Text(stateLabel(state, lang: lang))
                            .font(.plexMono(10, weight: .semibold))
                    }
                    .foregroundStyle(stateColor(state))
                }
                Text(subtitle(state: state, provider: provider))
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .lineLimit(1)
                Text(targetLabel(provider))
                    .font(.plexMono(10))
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
        .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
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
        case "hiyo": return "Hiyo"
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
        // Design: TRAY mono 9/500 · switch 34×18.
        // ON  = accent fill + paper knob (right).
        // OFF = track fill + ink knob (left) — never Color.clear (invisible
        //       knob + hit-testing dead zone when off).
        HStack(spacing: 8) {
            Text(L10n.t("popover.tray", settings.appLanguage).uppercased())
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(hasError ? VocabbyTheme.critical : VocabbyTheme.muted)
                .tracking(0.6)
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isOn.toggle()
                }
                MenuBarVisibility.setShown(providerId: providerId, to: isOn)
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .fill(isOn ? VocabbyTheme.blue : VocabbyTheme.track)
                        .overlay(
                            RoundedRectangle(cornerRadius: 0, style: .continuous)
                                .strokeBorder(
                                    isOn ? VocabbyTheme.blue : VocabbyTheme.border,
                                    lineWidth: 1)
                        )
                    Rectangle()
                        // Off knob is ink so it reads on paper; on knob is paper on accent.
                        .fill(isOn ? VocabbyTheme.background : VocabbyTheme.primary)
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
                .frame(width: 34, height: 18)
                // Opaque hit target for the whole track (fixes unclickable OFF).
                .contentShape(Rectangle())
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
            .accessibilityAddTraits(.isButton)
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
        alert.icon = NSImage(named: "OriginalImage")
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

// MARK: - Card modifier

struct VocabbyCard: ViewModifier {
    // Instrument redesign: no filled/rounded/shadowed card — a plain top
    // hairline divider instead (matches CSS `.card { border-radius: 0;
    // border-top: 1px solid var(--hairline); padding: 16px 0; }`). Content
    // and rule share the 16pt side inset (only header/tabs are edge-to-edge).
    func body(content: Content) -> some View {
        content
            .popoverContentInset()
            .padding(.vertical, 12)
            .background(VocabbyTheme.background)
            .popoverHairlineTop()
    }
}

extension View {
    func vocabbyCard() -> some View { modifier(VocabbyCard()) }
}

// MARK: - Usage chart scaling

enum UsageChartScaling {
    static func fraction(value: Double, maximum: Double) -> Double {
        guard value > 0 else { return 0 }
        return value / max(maximum, 1)
    }
}

// MARK: - Claude usage chart

/// 30-day cost chart — title + total, bars, axis. Model breakdown is
/// **click-to-pin** (All-tab parity): hidden by default; click a bar to
/// show that day's models; click again to hide. Hover only highlights.
struct ClaudeUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: ClaudeUsageReport
    @State private var hoveredDay: ClaudeDailyUsage?
    @State private var pinnedDay: ClaudeDailyUsage?

    private var daily30: [ClaudeDailyUsage] { Array(report.daily.suffix(30)) }
    private var maxBarTokens: Int { max(daily30.map(\.tokens).max() ?? 0, 1) }

    private var dayDetail: ProviderDayChartDetail? {
        pinnedDay.map { ProviderDayChartDetail.from(day: $0, language: settings.appLanguage) }
    }

    var body: some View {
        ProviderCostChartScaffold(
            title: L10n.f("chart.providerCost30", settings.appLanguage, "Claude"),
            totalUSD: report.last30USD,
            todayUSD: report.todayUSD,
            todayTokens: report.todayTokens,
            startLabel: daily30.first.map { dayLabel($0.date) },
            dayDetail: dayDetail,
            footnote: L10n.t("chart.estimateClaude", settings.appLanguage),
            barTint: VocabbyTheme.chartClaude
        ) {
            barChart
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let hasTokens = day.tokens > 0
                    let heightFraction = UsageChartScaling.fraction(
                        value: Double(day.tokens), maximum: Double(maxBarTokens))
                    let barHeight = max(geo.size.height * heightFraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .onTapGesture {
                        if pinnedDay?.id == day.id { pinnedDay = nil }
                        else { pinnedDay = day }
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: ClaudeDailyUsage) -> Color {
        VocabbyTheme.activityChartBarColor(
            isCurrent: day.date == daily30.last?.date,
            hasActivity: day.tokens > 0,
            tint: VocabbyTheme.chartClaude,
            currentTint: VocabbyTheme.chartClaude
        )
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }
}

// MARK: - Codex usage chart

/// 30-day bar chart from `CodexCostScanner`. Click a bar to pin that day's
/// model breakdown (hidden by default); hover only highlights.
struct CodexUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CodexUsageReport
    @State private var hoveredDay: CodexDailyUsage?
    @State private var pinnedDay: CodexDailyUsage?

    private var daily30: [CodexDailyUsage] { Array(report.daily.suffix(30)) }
    private var maxBarTokens: Int { max(daily30.map(\.tokens).max() ?? 0, 1) }

    private var dayDetail: ProviderDayChartDetail? {
        pinnedDay.map { ProviderDayChartDetail.from(day: $0, language: settings.appLanguage) }
    }

    var body: some View {
        ProviderCostChartScaffold(
            title: L10n.f("chart.providerCost30", settings.appLanguage, "Codex"),
            totalUSD: report.last30USD,
            todayUSD: report.todayUSD,
            todayTokens: report.todayTokens,
            startLabel: daily30.first.map { dayLabel($0.date) },
            dayDetail: dayDetail,
            footnote: L10n.t("chart.estimateCodex", settings.appLanguage),
            barTint: VocabbyTheme.chartCodex
        ) {
            barChart
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let hasTokens = day.tokens > 0
                    let heightFraction = UsageChartScaling.fraction(
                        value: Double(day.tokens), maximum: Double(maxBarTokens))
                    let barHeight = max(geo.size.height * heightFraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .onTapGesture {
                        if pinnedDay?.id == day.id { pinnedDay = nil }
                        else { pinnedDay = day }
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: CodexDailyUsage) -> Color {
        VocabbyTheme.activityChartBarColor(
            isCurrent: day.date == daily30.last?.date,
            hasActivity: day.tokens > 0,
            tint: VocabbyTheme.chartCodex,
            currentTint: VocabbyTheme.chartCodex
        )
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }
}

/// Pinned-day model breakdown for a single-provider chart (hidden until click).
private struct ProviderDayChartDetail {
    let header: String
    let models: [(name: String, usd: Double, tokens: Int)]

    static func from(day: ClaudeDailyUsage, language: String) -> ProviderDayChartDetail {
        make(date: day.date, usd: day.usd, tokens: day.tokens,
             models: day.models.map { ($0.name, $0.usd, $0.tokens) }, language: language)
    }

    static func from(day: CodexDailyUsage, language: String) -> ProviderDayChartDetail {
        make(date: day.date, usd: day.usd, tokens: day.tokens,
             models: day.models.map { ($0.name, $0.usd, $0.tokens) }, language: language)
    }

    static func from(day: GrokDailyUsage, language: String) -> ProviderDayChartDetail {
        make(date: day.date, usd: day.usd, tokens: day.tokens,
             models: day.models.map { ($0.name, $0.usd, $0.tokens) }, language: language)
    }

    static func from(day: KiroDailyUsage, language: String) -> ProviderDayChartDetail {
        make(date: day.date, usd: day.usd, tokens: day.tokens,
             models: day.models.map { ($0.name, $0.usd, $0.tokens) }, language: language)
    }

    private static func make(date: Date, usd: Double, tokens: Int,
                             models: [(String, Double, Int)],
                             language: String) -> ProviderDayChartDetail {
        let sorted = models
            .filter { $0.1 > 0 || $0.2 > 0 }
            .sorted { ($0.2, $0.1) > ($1.2, $1.1) }
            .prefix(6)
            .map { (name: $0.0, usd: $0.1, tokens: $0.2) }
        let header = "\(L10n.dayMonth(date, preference: language)) · \(AllUsageFormat.tokens(tokens)) · \(AllUsageFormat.usd(usd))"
        return ProviderDayChartDetail(header: header, models: Array(sorted))
    }
}

/// Shared design chrome for per-provider 30-day cost cards (Claude/Codex/Grok/Kiro).
/// Model list is only shown when `dayDetail` is set (click-pinned bar).
private struct ProviderCostChartScaffold<Bars: View>: View {
    @EnvironmentObject var settings: SettingsStore

    let title: String
    let totalUSD: Double
    let todayUSD: Double
    let todayTokens: Int
    let startLabel: String?
    let dayDetail: ProviderDayChartDetail?
    let footnote: String
    let barTint: Color
    @ViewBuilder let bars: () -> Bars

    var body: some View {
        let _ = barTint
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.plexMono(10, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .tracking(0.4)
                Spacer(minLength: 8)
                Text(AllUsageFormat.usd(totalUSD))
                    .font(.plexMono(16, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
            }
            bars()
                .frame(height: 68)
            HStack {
                if let startLabel {
                    Text(startLabel)
                        .font(.plexMono(9))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                Spacer(minLength: 8)
                Text("\(L10n.t("chart.today", settings.appLanguage).uppercased()) \(AllUsageFormat.usd(todayUSD)) · \(AllUsageFormat.tokensShort(todayTokens))")
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // Click-pinned day models only — default is hidden.
            if let dayDetail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dayDetail.header)
                        .font(.plexMono(11, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    if dayDetail.models.isEmpty {
                        Text(L10n.languageCode(settings.appLanguage) == "vi"
                             ? "Không có chi tiết model."
                             : "No model breakdown.")
                            .font(.plexSans(10))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    } else {
                        ForEach(Array(dayDetail.models.enumerated()), id: \.offset) { _, m in
                            HStack(spacing: 8) {
                                Text(AllUsageFormat.shortName(m.name))
                                    .font(.plexSans(12, weight: .medium))
                                    .foregroundStyle(VocabbyTheme.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(m.usd < 0.005
                                     ? AllUsageFormat.tokensShort(m.tokens)
                                     : "\(AllUsageFormat.tokensShort(m.tokens)) · \(AllUsageFormat.usd(m.usd))")
                                    .font(.plexMono(11))
                                    .foregroundStyle(VocabbyTheme.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(footnote.uppercased())
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .tracking(0.2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .popoverContentInset()
        .padding(.vertical, 14)
        .popoverHairlineTop()
    }
}

// MARK: - Kiro usage chart

/// 30-day bar chart for Kiro CLI. Click bar → pin day model detail.
struct KiroUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: KiroUsageReport
    @State private var hoveredDay: KiroDailyUsage?
    @State private var pinnedDay: KiroDailyUsage?

    private var daily30: [KiroDailyUsage] { Array(report.daily.suffix(30)) }
    private var maxBarTokens: Int { max(daily30.map(\.tokens).max() ?? 0, 1) }

    private var dayDetail: ProviderDayChartDetail? {
        pinnedDay.map { ProviderDayChartDetail.from(day: $0, language: settings.appLanguage) }
    }

    var body: some View {
        ProviderCostChartScaffold(
            title: L10n.f("chart.providerCost30", settings.appLanguage, "Kiro"),
            totalUSD: report.last30USD,
            todayUSD: report.todayUSD,
            todayTokens: report.todayTokens,
            startLabel: daily30.first.map { dayLabel($0.date) },
            dayDetail: dayDetail,
            footnote: L10n.t("chart.estimateKiro", settings.appLanguage),
            barTint: VocabbyTheme.primary
        ) {
            barChart
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let hasTokens = day.tokens > 0
                    let heightFraction = UsageChartScaling.fraction(
                        value: Double(day.tokens), maximum: Double(maxBarTokens))
                    let barHeight = max(geo.size.height * heightFraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .onTapGesture {
                        if pinnedDay?.id == day.id { pinnedDay = nil }
                        else { pinnedDay = day }
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))")
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
}

// MARK: - Grok Build usage chart

/// 30-day bar chart for Grok Build. Click bar → pin day model detail.
struct GrokUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let report: GrokUsageReport
    @State private var hoveredDay: GrokDailyUsage?
    @State private var pinnedDay: GrokDailyUsage?

    private var daily30: [GrokDailyUsage] { Array(report.daily.suffix(30)) }
    private var maxBarTokens: Int { max(daily30.map(\.tokens).max() ?? 0, 1) }

    private var dayDetail: ProviderDayChartDetail? {
        pinnedDay.map { ProviderDayChartDetail.from(day: $0, language: settings.appLanguage) }
    }

    var body: some View {
        ProviderCostChartScaffold(
            title: L10n.f("chart.providerCost30", settings.appLanguage, "Grok"),
            totalUSD: report.last30USD,
            todayUSD: report.todayUSD,
            todayTokens: report.todayTokens,
            startLabel: daily30.first.map { dayLabel($0.date) },
            dayDetail: dayDetail,
            footnote: L10n.t("chart.estimateGrok", settings.appLanguage),
            barTint: VocabbyTheme.chartGrok
        ) {
            barChart
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(daily30) { day in
                    let hasTokens = day.tokens > 0
                    let heightFraction = UsageChartScaling.fraction(
                        value: Double(day.tokens), maximum: Double(maxBarTokens))
                    let barHeight = max(geo.size.height * heightFraction, hasTokens ? 3 : 1)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(barColor(for: day))
                            .frame(height: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((hoveredDay?.id == day.id || pinnedDay?.id == day.id)
                                ? VocabbyTheme.selectedSurface.opacity(0.6) : Color.clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day }
                        else if hoveredDay?.id == day.id { hoveredDay = nil }
                    }
                    .onTapGesture {
                        if pinnedDay?.id == day.id { pinnedDay = nil }
                        else { pinnedDay = day }
                    }
                    .help("\(dayLabel(day.date)): \(AllUsageFormat.usd(day.usd)) · \(AllUsageFormat.tokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: GrokDailyUsage) -> Color {
        if day.tokens <= 0 { return VocabbyTheme.track }
        if day.date == daily30.last?.date { return VocabbyTheme.chartGrok }
        return VocabbyTheme.chartGrok.opacity(0.78)
    }

    private func dayLabel(_ date: Date) -> String {
        L10n.dayMonth(date, preference: settings.appLanguage)
    }
}

// MARK: - Claude Admin usage chart

/// 30-day org dashboard card for the Claude Admin API source. Mirrors
/// `ClaudeUsageChartCard` but the data comes from `ClaudeAdminAPIUsageSnapshot`
/// (real billed cost from Anthropic's org Usage & Cost API, not a local
/// estimate) — so no "≈ estimate" footnote. Shows 30-day + latest-day cost +
/// tokens, a per-day token bar series, and the top model + top cost item.
struct ClaudeAdminUsageChartCard: View {
    @EnvironmentObject var settings: SettingsStore

    let snapshot: ClaudeAdminAPIUsageSnapshot

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var maxBarTokens: Int { max(snapshot.daily.map(\.totalTokens).max() ?? 0, 1) }

    var body: some View {
        let last30 = snapshot.last30Days
        let latest = snapshot.latestDay
        return VStack(alignment: .leading, spacing: 8) {
            Text(vi ? "Admin API · Tổ chức (30 ngày)" : "Admin API · Org (30 days)")
                .font(.plexMono(9, weight: .semibold))
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
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            if let item = snapshot.topCostItems.first {
                Text((vi ? "Chi nhiều nhất: " : "Top cost: ") + "\(item.name) · \(formatUSD(item.costUSD))")
                    .font(.plexMono(10))
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
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            Text(formatUSD(amount))
                .font(.plexMono(16, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
            Text(formatTokens(tokens))
                .font(.plexMono(11))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(snapshot.daily) { day in
                    let hasTokens = day.totalTokens > 0
                    let fraction = UsageChartScaling.fraction(
                        value: Double(day.totalTokens), maximum: Double(maxBarTokens))
                    let barHeight = max(geo.size.height * fraction, hasTokens ? 3 : 1)
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .fill(VocabbyTheme.activityChartBarColor(
                            isCurrent: day.id == snapshot.daily.last?.id,
                            hasActivity: day.totalTokens > 0
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
    /// Posted by `HiyoKeyStore` when keys are added/removed/switched so
    /// Settings + the popover switcher re-list immediately (no app restart).
    static let birdnionHiyoKeysChanged = Notification.Name("com.local.birdnion.hiyoKeysChanged")
    /// Posted when the user switches the popover tab to "all", before the
    /// selected-tab state mutates. AppDelegate pre-expands the panel to
    /// a safe seed so the hosting view has stable bounds for the tall All
    /// content layout pass.
    static let birdnionAllTabWillOpen = Notification.Name("com.local.birdnion.allTabWillOpen")
}

// MARK: - Empty State

/// Shown by `QuotaOverview` when no provider is enabled (first-run / opt-in
/// state). Intentionally one self-contained subview with a stable identity
/// so the hosting view in the NSPanel can lay it out once without
/// re-entering the NSISEngine recursion loop.
///
/// Plain macOS-style empty state:
///   - Big BirdNion logo at the top
///   - Bold title + secondary body (no tinted card)
///   - Compact primary CTA
///
struct EmptyProvidersState: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            // Reuse the same gradient-preserving mark as the menu bar/header.
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(L10n.t("popover.noProviders", settings.appLanguage))
                    .font(.plexSans(16, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("popover.noProvidersBody", settings.appLanguage))
                    .font(.plexSans(12))
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
                openProviderSettings("claude")
            } label: {
                Text(L10n.languageCode(settings.appLanguage) == "vi" ? "Kết nối provider" : "Connect provider")
                    .font(.plexSans(13, weight: .semibold))
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
