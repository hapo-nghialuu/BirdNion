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
struct ProvidersPane: View {
    /// Drag payload type for provider reordering. Uses the system plain-text
    /// type: a custom UTType would need a UTExportedTypeDeclarations entry in
    /// Info.plist or macOS silently rejects the drop (validateDrop /
    /// hasItemsConforming never match, so onDrop stays inert). The payload is
    /// never read on drop — delegates track the dragged row via
    /// `draggedRowId` — so plain text is sufficient and external text drags
    /// are still rejected by the `draggedProviderId != nil` guard.
    private static let providerDragType = UTType.plainText

    @EnvironmentObject var quota: QuotaService
    @EnvironmentObject var settings: SettingsStore

    @State private var rows: [BirdNionConfigStore.Provider] = []
    @State private var selectedID: String?
    /// Search filter for the provider sidebar. Matches display name + id
    /// case-insensitively; empty string shows all rows.
    @State private var searchText: String = ""
    /// Codex token cost (today / 30d), scanned lazily when Codex is selected.
    @State private var codexCost: CodexCostSummary?
    /// Claude token cost (today / 30d), scanned lazily when Claude is
    /// selected — mirrors CodexCostScanner but reads Claude Code's local
    /// session jsonl files (see ClaudeCostScanner.swift).
    @State private var claudeCost: ClaudeCostSummary?
    /// Claude multi-account state (web sessionKey / Admin API key accounts).
    @State private var claudeAccounts: ClaudeTokenAccountData = ClaudeTokenAccountStore.load()
    @State private var newAccountToken: String = ""
    @State private var newAccountLabel: String = ""
    @State private var newAccountKind: ClaudeTokenAccount.Kind = .web

    // MARK: - Antigravity OAuth state
    @State private var antigravityStore: AntigravityOAuthStore.Store = AntigravityOAuthStore.load()
    @State private var antigravityNewLabel: String = ""
    @State private var antigravityNewJSON: String = ""
    @State private var antigravityLoginInProgress: Bool = false
    @State private var antigravityLoginError: String? = nil
    @State private var antigravityReloadTick: Int = 0

    // MARK: - Copilot OAuth state
    @State private var copilotStore: CopilotAccountStore.Store = CopilotAccountStore.load()
    @State private var copilotReloadTick: Int = 0
    @State private var copilotDeviceUserCode: String? = nil
    @State private var copilotLoginInProgress: Bool = false
    @State private var copilotLoginError: String? = nil
    @State private var copilotLoginTask: Task<Void, Never>? = nil

    // Kilo organizations: transient list fetched on demand for the scope picker.
    @State private var kiloKnownOrgs: [KiloOrganization] = []
    @State private var kiloOrgRefreshing: Bool = false
    @State private var kiloOrgError: String? = nil

    // Bumped to force the per-provider menu-bar-metric picker to re-read its
    // UserDefaults-backed selection after a change.
    @State private var menuBarMetricTick: Int = 0

    private var language: String { settings.appLanguage }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sidebar
            detail
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsTheme.background)
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
        }
        .task(id: antigravityReloadTick) {
            antigravityStore = AntigravityOAuthStore.load()
        }
        .task(id: copilotReloadTick) {
            copilotStore = CopilotAccountStore.load()
        }
    }

    // MARK: - Sidebar

    /// View order for the sidebar: enabled providers first (preserving the
    /// user's custom order within each group), then disabled. Search text
    /// narrows both groups by display name + id (case-insensitive). Matches
    /// CodexBar's "enabled first" ordering so the user can spot which
    /// providers are actually polling.
    private var visibleRows: [BirdNionConfigStore.Provider] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let filtered = rows.filter { row in
            guard !query.isEmpty else { return true }
            return displayName(for: row).lowercased().contains(query)
                || row.id.lowercased().contains(query)
        }
        // Stable partition: enabled first, then disabled — each preserving
        // the relative order in `rows` (so user drag-reorder survives sort).
        let active = filtered.filter { $0.enabled == true }
        let inactive = filtered.filter { $0.enabled != true }
        return active + inactive
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            searchField
            // Scrollable provider list — the roster can hold 20+ providers, so
            // it must scroll independently (search field stays pinned above).
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, row in
                        sidebarRow(row, position: idx)
                        if row.id != visibleRows.last?.id {
                            Divider()
                                .overlay(SettingsTheme.border.opacity(0.72))
                                .padding(.leading, 44)
                                .frame(height: 7)
                                .contentShape(Rectangle())
                                .onDrop(
                                    of: [Self.providerDragType],
                                    delegate: SidebarDropCompletionDelegate(
                                        draggedProviderId: $draggedRowId,
                                        dropTargetRowId: $dropTargetRowId,
                                        finish: finishRowMove))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1)
        )
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

    /// Move rows as soon as the pointer enters a sibling row. Persistence and
    /// provider rebuild happen only once in `finishRowMove`, when the user
    /// drops, so the animation stays responsive.
    private func previewRowMove(draggedId: String, toVisibleIndex targetIndex: Int) {
        let reordered = Self.reorderedProviders(
            rows,
            visibleIDs: visibleRows.map(\.id),
            draggedID: draggedId,
            targetIndex: targetIndex)
        guard reordered != rows else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            rows = reordered
        }
    }

    private func finishRowMove() {
        let originalOrder = dragStartRows?.map(\.id)
        guard originalOrder != rows.map(\.id) else {
            dragStartRows = nil
            return
        }
        saveAll()
        NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
        dragStartRows = nil
    }

    /// Search box at the top of the sidebar. Magnifying glass icon + clear
    /// button (×) appear only when there's text. Mirrors CodexBar's
    /// `ProviderSidebarSearchField` layout but uses plain SwiftUI since
    /// BirdNion doesn't have the same localization plumbing.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SettingsTheme.secondary)
                .accessibilityHidden(true)
            TextField(L10n.t("provider.search", language), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.primary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SettingsTheme.secondary)
                        .accessibilityLabel(L10n.t("provider.clearSearch", language))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SettingsTheme.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private func sidebarRow(_ row: BirdNionConfigStore.Provider, position: Int) -> some View {
        let isSelected = row.id == selectedID
        let isHovered = row.id == hoveredRowId
        let isDragged = row.id == draggedRowId
        let isDropTarget = row.id == dropTargetRowId && row.id != draggedRowId
        return HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered || isDropTarget
                                 ? SettingsTheme.accent
                                 : SettingsTheme.tertiary)
                .frame(width: 20, height: 30)
                .contentShape(Rectangle())
                .help(L10n.t("provider.reorderHelp", language))
                .accessibilityLabel(L10n.t("provider.reorderHelp", language))

            // Custom checkbox so the sidebar follows BirdNion's accent instead
            // of the user's macOS accent colour.
            sidebarCheckbox(for: row)
                .help(row.enabled == true
                      ? L10n.t("provider.enableHelp.on", language)
                      : L10n.t("provider.enableHelp.off", language))

            ProviderLogoView(id: row.id, tint: sidebarLogoTint(for: row, selected: isSelected))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: row))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.enabled == true ? SettingsTheme.primary : SettingsTheme.secondary)
                Text(statusSubtitle(for: row))
                    .font(.system(size: 10))
                    .foregroundStyle(status(for: row.id)?.error != nil
                                     ? SettingsTheme.critical
                                     : SettingsTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(statusSubtitleDetail(for: row) ?? "")
            }

            Spacer(minLength: 6)

            statusDot(for: row)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget
                      ? SettingsTheme.accent.opacity(0.12)
                      : (isSelected
                         ? SettingsTheme.selectedSurface
                         : (isHovered ? SettingsTheme.hoverSurface.opacity(0.62) : .clear)))
                .padding(.horizontal, 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isDropTarget ? SettingsTheme.accent.opacity(0.8) : .clear,
                              lineWidth: 1.5)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .opacity(isDragged ? 0.42 : 1)
        .scaleEffect(isDragged ? 0.985 : 1)
        .onTapGesture { selectedID = row.id }
        .pointingHandCursor()
        .onHover { hovering in
            if hovering {
                hoveredRowId = row.id
            } else if hoveredRowId == row.id {
                hoveredRowId = nil
            }
        }
        // The grip communicates reorder affordance, while the whole row stays
        // draggable so users do not need to hit a narrow handle precisely.
        .onDrag {
            // A system drag released outside the app window does not call any
            // drop delegate. Restore that stale preview before a new drag.
            if draggedRowId != nil, let dragStartRows {
                rows = dragStartRows
            }
            dragStartRows = rows
            draggedRowId = row.id
            dropTargetRowId = nil
            return NSItemProvider(object: row.id as NSString)
        } preview: {
            // Custom preview shows the chip with a slight scale so the user
            // sees what's moving; default preview is a faded snapshot of
            // the whole row which is hard to read in a tight sidebar.
            HStack(spacing: 8) {
                checkboxGlyph(isOn: row.enabled == true)
                ProviderLogoView(id: row.id, tint: sidebarLogoTint(for: row, selected: false))
                    .frame(width: 22, height: 22)
                Text(displayName(for: row))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsTheme.card))
        }
        // Any sibling row can receive the dragged id and becomes visibly
        // highlighted before the user releases the mouse.
        .onDrop(of: [Self.providerDragType], delegate: SidebarRowDropDelegate(
            targetRow: row,
            targetPosition: position,
            draggedProviderId: $draggedRowId,
            dropTargetRowId: $dropTargetRowId,
            movePreview: previewRowMove,
            finish: finishRowMove))
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .animation(.easeOut(duration: 0.12), value: isDragged)
    }

    private func setProviderEnabled(id: String, enabled: Bool) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].enabled = enabled
        saveAll()
        // Rebuild providers via ServicesContainer so the menu-bar popover +
        // percent rotation pick up the new state. Use the notification path so
        // the rebuild happens on the main thread via AppDelegate.
        NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
    }

    private func sidebarCheckbox(for row: BirdNionConfigStore.Provider) -> some View {
        Button {
            setProviderEnabled(id: row.id, enabled: row.enabled != true)
        } label: {
            checkboxGlyph(isOn: row.enabled == true)
        }
        .buttonStyle(.plain)
        .frame(width: 16, height: 22)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .accessibilityLabel(row.enabled == true
                            ? L10n.t("provider.enableHelp.on", language)
                            : L10n.t("provider.enableHelp.off", language))
    }

    private func checkboxGlyph(isOn: Bool) -> some View {
        SettingsCheckboxGlyph(isOn: isOn)
    }

    private func sidebarLogoTint(for row: BirdNionConfigStore.Provider, selected: Bool) -> Color {
        if row.enabled != true { return SettingsTheme.disabled.opacity(0.82) }
        return selected ? SettingsTheme.accent : SettingsTheme.secondary
    }

    /// Tracks which row is currently being dragged (used by the drop
    /// delegate to know when to activate the row's drop indicator).
    @State private var draggedRowId: String?
    @State private var dropTargetRowId: String?
    @State private var hoveredRowId: String?
    @State private var dragStartRows: [BirdNionConfigStore.Provider]?

    // makeProvider was moved to `ServicesContainer.makeProviders(keychain:)`
// so the same factory powers init() and the live rebuild path triggered
// by .birdnionProvidersChanged.

    @ViewBuilder
    private func statusDot(for row: BirdNionConfigStore.Provider) -> some View {
        let color: Color = {
            if row.enabled != true { return SettingsTheme.disabled.opacity(0.55) }
            guard let s = status(for: row.id) else { return SettingsTheme.disabled.opacity(0.55) }
            return s.error == nil ? SettingsTheme.success : SettingsTheme.warningFill
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(idx)
                    detailInfoGrid(rows[idx])
                    usageSection(rows[idx])
                    settingsSection(idx)
                    if rows[idx].id == "codex" {
                        CodexAccountsCard()
                    }
                    if rows[idx].id == "antigravity" {
                        antigravityOAuthAccountsSection()
                    }
                    if rows[idx].id == "copilot" {
                        copilotOAuthAccountsSection(idx: idx)
                    }
                    QuotaWarningCard(providerID: rows[idx].id)
                        .id(rows[idx].id)
                    linksSection(rows[idx])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            // Fill the window height so the ScrollView scrolls tall provider
            // details (e.g. Codex) instead of overflowing past the bottom edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            SettingsCard {
                Text(L10n.t("provider.choose", language))
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func detailHeader(_ idx: Int) -> some View {
        let row = rows[idx]
        return SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                ProviderLogoView(id: row.id, tint: row.enabled == true ? SettingsTheme.accent : SettingsTheme.disabled)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: row))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(headerSubtitle(for: row))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    // Manual reload: re-read `settings.json` to pick up any
                    // changes another pane (or external editor) made, then
                    // rebuild the provider list and trigger a refresh.
                    // Previously this only called `quota.refresh()` which
                    // didn't re-read the file — so saving a token in TokenField
                    // and refreshing from the detail header could show stale
                    // data because the in-memory provider list still pointed at
                    // the pre-save providers.json state.
                    rows = BirdNionConfigStore.allProviders()
                    NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
                } label: {
                    // Swap the reload glyph for a spinner while a refresh is in
                    // flight so clicking gives immediate visual feedback (the
                    // header subtitle also flips to "Đang cập nhật").
                    ZStack {
                        if quota.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .controlSize(.small)
                .disabled(quota.isRefreshing)
                .pointingHandCursor(enabled: !quota.isRefreshing)
                .help(L10n.t("provider.reloadHelp", language))

                Toggle("", isOn: enabledBinding(idx))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func detailInfoGrid(_ row: BirdNionConfigStore.Provider) -> some View {
        let s = status(for: row.id)
        return SettingsCard {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                infoRow(
                    L10n.t("provider.status", language),
                    row.enabled == true ? L10n.t("popover.ready", language) : L10n.t("provider.disabled", language)
                )
                if row.id == "codex" {
                    // Which source actually produced the data (OAuth / CLI).
                    infoRow(L10n.t("provider.source", language),
                            L10n.providerText(s?.sourceLabel ?? "OAuth", preference: language))
                } else if row.id == "claude" {
                    // OAuth token comes from the Claude Code Keychain item.
                    infoRow(L10n.t("provider.source", language), "OAuth")
                }
                if let plan = s?.planType, !plan.isEmpty {
                    infoRow(L10n.t("provider.plan", language),
                            L10n.providerText(plan.capitalized, preference: language))
                }
                if let name = s?.planName, !name.isEmpty {
                    // Plan display name (MiniMax `current_subscribe_title`) — distinct
                    // from `planType` which carries a code (`plus` / `pro`).
                    infoRow(L10n.t("provider.planName", language),
                            L10n.providerText(name, preference: language))
                }
                if let label = s?.accountLabel, !label.isEmpty {
                    infoRow(L10n.t("provider.account", language), label)
                }
                if let version = s?.version, !version.isEmpty {
                    infoRow(L10n.t("provider.version", language), version)
                }
                if let svc = s?.serviceStatus, !svc.isEmpty {
                    serviceStatusRow(svc, level: s?.serviceStatusLevel)
                }
                if row.id == "codex", let n = s?.resetCreditsAvailable {
                    infoRow(L10n.t("provider.resetCredits", language), "\(n)")
                }
                if row.id == "codex", let web = s?.codexWeb {
                    if let cr = web.codeReviewRemainingPercent {
                        infoRow(L10n.t("provider.codeReview", language), L10n.f("provider.remaining", language, cr))
                    }
                    if let n = web.creditsHistoryCount {
                        infoRow(L10n.t("provider.creditsHistory", language), "\(n)")
                    }
                    if let url = web.creditsPurchaseURL, let u = URL(string: url) {
                        GridRow {
                            Text(L10n.t("provider.buyCredits", language)).gridColumnAlignment(.leading)
                            Link(L10n.t("provider.openPage", language), destination: u)
                                .font(.system(size: 12))
                        }
                    }
                }
                if let err = s?.error {
                    infoRow(L10n.t("provider.error", language),
                            L10n.providerText(err, preference: language))
                } else {
                    infoRow(L10n.t("provider.updated", language), updatedSubtitle(for: row.id))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(SettingsTheme.primary)
                .lineLimit(2)
        }
    }

    /// Service-status row with a severity dot (green/yellow/orange/red).
    private func serviceStatusRow(_ text: String, level: String?) -> some View {
        GridRow {
            Text(L10n.t("provider.serviceStatus", language)).gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(serviceStatusColor(level))
                    .frame(width: 7, height: 7)
                Text(L10n.providerText(text, preference: language))
                    .foregroundStyle(SettingsTheme.primary)
                    .lineLimit(2)
            }
        }
    }

    private func serviceStatusColor(_ level: String?) -> Color {
        switch level {
        case "none": return SettingsTheme.success
        case "minor": return SettingsTheme.warningFill
        case "major": return SettingsTheme.warningFill
        case "critical": return SettingsTheme.critical
        default: return SettingsTheme.disabled
        }
    }

    @ViewBuilder
    private func usageSection(_ row: BirdNionConfigStore.Provider) -> some View {
        let s = status(for: row.id)
        SettingsCard(header: L10n.t("settings.section.usage", language)) {
            if let s, !s.windows.isEmpty {
                ForEach(Array(s.windows.enumerated()), id: \.element.id) { i, w in
                    quotaWindowRow(w)
                    if i < s.windows.count - 1 { SettingsRowDivider() }
                }
                if s.creditsRemaining != nil || s.creditsUnlimited {
                    SettingsRowDivider()
                    creditsRow(s.creditsRemaining, unlimited: s.creditsUnlimited)
                }
            } else if s == nil || s?.windows.isEmpty == true {
                // Empty placeholder only when there's truly no data — cost /
                // extras below can still render so the panel stays useful
                // even when OAuth fails.
                Text(row.enabled == true
                     ? L10n.t("provider.noData.enabled", language)
                     : L10n.t("provider.noData.disabled", language))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            // Provider-specific extras render regardless of OAuth window
            // presence — cost + account info stay useful even when the
            // primary fetch fails. Codex ships a local token scanner; Claude
            // ships both a local token scanner and web extras.
            if row.id == "codex", let cost = codexCost, !cost.isEmpty {
                SettingsRowDivider()
                costRows(cost)
            }
            if row.id == "claude", let cost = s?.cost {
                SettingsRowDivider()
                webCostRow(cost)
            }
            if row.id == "claude", let cost = claudeCost, !cost.isEmpty {
                SettingsRowDivider()
                costRows(cost)
            }
            if row.id == "claude", let extras = s?.webExtras {
                SettingsRowDivider()
                webExtrasRows(extras)
            }
        }
    }

    private func quotaWindowRow(_ w: QuotaWindow) -> some View {
        let isWeek = w.label.contains("Tuần")
        let barTextColor = SettingsTheme.quotaColor(remaining: w.remainingPct)
        let barFillColor = SettingsTheme.quotaFillColor(remaining: w.remainingPct)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowLabel(w.label, preference: language).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(w.remainingPct)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barTextColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(w.remainingPct) / 100), height: 8)
                }
            }
            .frame(height: 8)

            // Pace line: reserve (weekly) on the left, reset countdown on the right.
            let pace = WindowPace(window: w)
            if pace != nil || (w.subtitle?.isEmpty == false) {
                HStack(alignment: .firstTextBaseline) {
                    if isWeek, let r = pace?.reservePct, r > 0 {
                        Text(L10n.f("provider.reserve", language, r))
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                    Spacer(minLength: 6)
                    if let rt = pace?.resetText {
                        Text(L10n.f("provider.resetAfter", language, rt))
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                }
                if isWeek, let pace {
                    Text(pace.lastsUntilReset
                         ? L10n.t("provider.enoughUntilReset", language)
                         : L10n.t("provider.mayRunOut", language))
                        .font(.system(size: 10))
                        .foregroundStyle(pace.lastsUntilReset ? SettingsTheme.secondary : SettingsTheme.warning)
                }
                if let sub = w.subtitle, !sub.isEmpty {
                    Text(L10n.providerText(sub, preference: language))
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Remaining credit balance line (Codex). Shown only when the provider
    /// reports a credits figure.
    private func creditsRow(_ credits: Double?, unlimited: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("provider.credits", language))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer()
            Text(unlimited ? L10n.t("provider.unlimited", language) : creditsText(credits ?? 0))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func creditsText(_ credits: Double) -> String {
        let amount = credits.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(credits))
            : String(format: "%.2f", credits)
        return credits <= 0
            ? L10n.t("provider.outOfCredits", language)
            : L10n.f("provider.creditsLeft", language, amount)
    }

    /// Token cost rows (Codex + Claude). Dollar amounts are estimates (tokens ×
    /// price table), so they're prefixed with "≈"; token counts are exact.
    /// Both `CodexCostSummary` and `ClaudeCostSummary` carry the same 4
    /// fields, so we forward to a single renderer.
    private func costRows(_ cost: CodexCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    private func costRows(_ cost: ClaudeCostSummary) -> some View {
        costRowsImpl(todayUSD: cost.todayUSD, todayTokens: cost.todayTokens,
                     last30USD: cost.last30USD, last30Tokens: cost.last30Tokens)
    }
    private func costRowsImpl(todayUSD: Double, todayTokens: Int,
                              last30USD: Double, last30Tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            costLine(L10n.t("provider.today", language), usd: todayUSD, tokens: todayTokens)
            costLine(L10n.t("provider.last30", language), usd: last30USD, tokens: last30Tokens)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Claude cost row, CodexBar parity. Renders a progress bar (used% of
    /// monthly limit), the dollar amount on the right, a "X% used" line, and
    /// an optional "Resets in Nd" countdown sourced from `cost.resetsAt`.
    /// Matches CodexBar's `ProviderCostSection` layout: title + percent +
    /// spend line + reset countdown.
    private func webCostRow(_ cost: ProviderCostSnapshot) -> some View {
        let usedPct = cost.limit > 0
            ? Int(min(100, max(0, (cost.used / cost.limit * 100).rounded())))
            : 0
        let remaining = max(0, cost.limit - cost.used)
        let barColor = SettingsTheme.usedFillColor(usedPercent: usedPct)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("provider.cost", language))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(UsageFormatter.usdString(cost.used)) / \(UsageFormatter.usdString(cost.limit))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SettingsTheme.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(usedPct) / 100), height: 8)
                }
            }
            .frame(height: 8)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.f("provider.usedRemaining", language, usedPct, UsageFormatter.usdString(remaining)))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.secondary)
                Spacer(minLength: 6)
                if let reset = cost.resetsAt {
                    Text(L10n.f("provider.resetAfter", language, Self.resetCountdown(to: reset)))
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                } else if let period = cost.period {
                    Text(period)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Compact countdown to a future date. Mirrors `WindowPace.format` but
    /// skips the "< 1m" branch so a sub-minute reset still reads "0m".
    /// "1d 4h", "4h 12m", "12m", "<1m".
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Claude web/CLI account identity rows. Surfaces email, organization,
    /// and login method when `webExtras` carries them — replaces CodexBar's
    /// `ProviderDetailInfoGrid` "Account" + "Auth" rows so the user can
    /// confirm which Claude.ai account the cookie/CLI session belongs to
    /// when OAuth is offline.
    @ViewBuilder
    private func webExtrasRows(_ extras: ClaudeWebExtras) -> some View {
        if let email = extras.accountEmail, !email.isEmpty {
            webInfoRow(label: L10n.t("provider.email", language), value: email)
        }
        if let org = extras.accountOrganization, !org.isEmpty {
            webInfoRow(label: L10n.t("provider.organization", language), value: org)
        }
        if let method = extras.loginMethod, !method.isEmpty {
            webInfoRow(label: L10n.t("provider.login", language), value: method)
        }
        if let source = extras.sourceLabel, !source.isEmpty {
            webInfoRow(label: L10n.t("provider.source", language).uppercased(), value: source.uppercased())
        }
        // Named extra windows (e.g. "Daily Routines", "Sonnet") from the
        // web/CLI/OAuth sources. Previously plumbed but never rendered.
        ForEach(extras.extraRateWindows) { w in
            extraRateWindowRow(w)
        }
    }

    /// Compact progress row for a named extra rate window (Daily Routines, etc.).
    private func extraRateWindowRow(_ w: ClaudeExtraRateWindow) -> some View {
        let remaining = max(0, 100 - w.usedPercent)
        let barTextColor = SettingsTheme.quotaColor(remaining: remaining)
        let barFillColor = SettingsTheme.quotaFillColor(remaining: remaining)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(remaining)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barTextColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(remaining) / 100), height: 8)
                }
            }
            .frame(height: 8)
            if let reset = w.resetsAt {
                Text(L10n.f("provider.resetAfter", language, Self.resetCountdown(to: reset)))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            } else if let desc = w.resetDescription, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func webInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(SettingsTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func costLine(_ label: String, usd: Double, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .tracking(0.5)
            Spacer()
            Text("≈$\(String(format: "%.2f", usd)) · \(Self.formatTokens(tokens))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsTheme.primary)
        }
    }

    /// Compact token count: 1_234_567 → "1.2M", 12_345 → "12.3K".
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Settings section (token / account label / login status)

    @ViewBuilder
    private func settingsSection(_ idx: Int) -> some View {
        let row = rows[idx]
        SettingsCard(header: L10n.t("settings.section.setup", language)) {
            // Account label (applies to all providers)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("provider.accountLabel", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                TextField(L10n.t("provider.accountLabelPlaceholder", language), text: labelBinding(idx))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            if row.id == "codex" {
                // Zero-config: just show login status.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("provider.signIn", language))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(codexLoginStatus())
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.secondary)
                    Text(L10n.t("provider.codexSignInHint", language))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if row.id == "claude" {
                // Claude doesn't take a pasted API token — it uses OAuth
                // from the Keychain, browser cookies (Web), the `claude`
                // CLI (PTY), or an Anthropic Admin API key. The 4 pickers
                // below (Usage source / Cookie source / Manual cookie field
                // / Keychain prompt mode) live in `settingsSection` siblings;
                // here we just skip the generic TokenField.
                EmptyView()
            } else if row.id == "antigravity" {
                // Antigravity uses Google OAuth / CLI / running process.
                // No generic API token — controls rendered below via
                // antigravityUsageSourcePicker() / antigravityOAuthAccountsSection().
                EmptyView()
            } else if row.id == "gemini" {
                // Gemini uses Google OAuth from the Gemini CLI creds file,
                // not a pasted API token — show sign-in status instead.
                geminiSignInSection()
            } else if row.id == "kiro" {
                // Kiro uses the Kiro CLI (no API token) — show a sign-in hint.
                kiroSignInSection()
            } else if row.id == "bedrock" {
                // Bedrock uses AWS credentials (auth-mode picker + keys/profile/
                // region), not a generic API token.
                bedrockAuthSection(idx)
            } else if Self.cookieProviderIDs.contains(row.id) {
                // Cookie-auth providers don't take a pasted API token — they read
                // the browser session cookie. Show a Cookie-source picker (Auto /
                // Manual / Off) + an optional manual Cookie-header field, mirroring
                // CodexBar (no token box).
                cookieProviderControls(row.id)
            } else {
                TokenField(
                    providerID: row.id,
                    onSaved: {
                        // TokenField writes apiKey straight to disk, bypassing
                        // `rows`. Reload so the next saveAll() (enable toggle,
                        // drag reorder, label edit — all write the whole rows
                        // array) doesn't clobber the just-saved token with the
                        // stale in-memory entry.
                        rows = BirdNionConfigStore.allProviders()
                        Task { await quota.refresh() }
                    }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "codex" {
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(L10n.t("provider.dataSource", language))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primary)
                        Spacer(minLength: 8)
                        Picker("", selection: Binding(
                            get: { settings.codexUsageSource },
                            set: { settings.codexUsageSource = $0; Task { await quota.refresh() } }
                        )) {
                            ForEach(CodexUsageSource.allCases) { src in
                                Text(codexUsageSourceName(src)).tag(src.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    Text(codexSourceSubtitle(for: settings.codexUsageSource))
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsTheme.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "codex" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.menuBarMetric", language))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.codexMenuBarMetric },
                        set: {
                            settings.codexMenuBarMetric = $0
                            // Re-fetch so the menu bar rebuilds its frames with
                            // the newly selected window.
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    )) {
                        ForEach(CodexMenuBarMetric.allCases) { m in
                            Text(codexMenuBarMetricName(m)).tag(m.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "codex" {
                codexWebExtrasControls()
            }

            if row.id == "minimax" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.minimaxRegion },
                        set: { settings.minimaxRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(MiniMaxRegion.allCases) { r in
                            Text(miniMaxRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "zai" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.zaiRegion },
                        set: { settings.zaiRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(ZaiRegion.allCases) { r in
                            Text(zaiRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "alibaba" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text(L10n.t("provider.apiRegion", language))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.alibabaRegion },
                        set: { settings.alibabaRegion = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(AlibabaRegion.allCases) { r in
                            Text(alibabaRegionName(r)).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "bedrock" {
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Text(L10n.languageCode(language) == "vi" ? "Ngân sách tháng (USD)" : "Monthly budget (USD)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    TextField("∞", text: Binding(
                        get: {
                            guard let b = rows[idx].budget else { return "" }
                            return String(b)
                        },
                        set: { raw in
                            rows[idx].budget = Double(raw.trimmingCharacters(in: .whitespaces))
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // Menu-bar metric picker (CodexBar parity) for the 3 HARD providers.
            if row.id == "gemini" || row.id == "kiro" || row.id == "bedrock" {
                menuBarMetricPicker(for: row.id)
            }
            // Kiro-specific menu-bar value (credits/percent/used÷total/overage).
            if row.id == "kiro" {
                kiroMenuBarValuePicker()
            }

            if row.id == "deepgram" {
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project ID")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(L10n.languageCode(language) == "vi"
                         ? "Tùy chọn. Để trống = lấy & gộp tất cả project của API key."
                         : "Optional. Leave blank to discover and aggregate all projects.")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                    TextField("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: Binding(
                        get: { rows[idx].projectID ?? "" },
                        set: { raw in
                            let v = raw.trimmingCharacters(in: .whitespaces)
                            rows[idx].projectID = v.isEmpty ? nil : v
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "copilot" {
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.languageCode(language) == "vi" ? "GitHub Enterprise Host" : "GitHub Enterprise Host")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(L10n.languageCode(language) == "vi"
                         ? "Tùy chọn. Nhập GitHub Enterprise host (vd octocorp.ghe.com). Để trống = github.com."
                         : "Optional. Enter GitHub Enterprise host (e.g. octocorp.ghe.com). Leave blank = github.com.")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("github.com", text: Binding(
                        get: { rows[idx].baseURL ?? "" },
                        set: { raw in
                            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            rows[idx].baseURL = v.isEmpty ? nil : v
                            saveAll()
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            if row.id == "claude" {
                claudeUsageSourcePicker()
                claudeCookieSourcePicker()
                if settings.claudeCookieSource == "manual" {
                    SettingsRowDivider()
                    claudeManualCookieField()
                }
                claudeOAuthKeychainPromptPicker()
                claudeAccountsSection()
            }

            if row.id == "antigravity" {
                antigravityUsageSourcePicker()
            }

            if row.id == "kilo" {
                kiloUsageSourcePicker()
                kiloOrganizationsSection()
            }

            // Per-provider refresh interval — applies to every provider.
            // Stored in UserDefaults under "refreshInterval.<id>" and read
            // by QuotaService.effectiveInterval(for:) at the start of each
            // refresh cycle. 0 = use the global QuotaService interval.
            providerRefreshIntervalPicker(for: row)
        }
    }

    /// Universal "refresh every" picker. Options cover the same range as the
    /// global QuotaService interval plus a "Use global (X)" row that shows
    /// the inherited cadence so the user can tell what they're falling
    /// back to. Mirrors CodexBar's per-provider override pattern.
    @ViewBuilder
    private func providerRefreshIntervalPicker(for row: BirdNionConfigStore.Provider) -> some View {
        SettingsRowDivider()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("provider.refreshEvery", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(L10n.f("provider.defaultGlobal", language, globalIntervalLabel))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { Self.providerRefreshSeconds(row.id) },
                set: { newValue in
                    Self.setProviderRefreshSeconds(row.id, newValue)
                    NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
                    NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                }
            )) {
                ForEach(Self.providerRefreshOptions, id: \.self) { seconds in
                    Text(providerRefreshLabel(seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Pre-defined options for the per-provider refresh picker. `seconds = 0`
    /// means "use global"; the other values are absolute.
    private static let providerRefreshOptions: [Double] = [0, 30, 60, 120, 300, 600, 1800]

    private func providerRefreshLabel(_ seconds: Double) -> String {
        switch seconds {
        case 0: return L10n.t("refresh.default", language)
        case 30: return L10n.t("refresh.30s", language)
        case 60: return L10n.t("refresh.1m", language)
        case 120: return L10n.t("refresh.2m", language)
        case 300: return L10n.t("refresh.5m", language)
        case 600: return L10n.t("refresh.10m", language)
        case 1800: return L10n.t("refresh.30m", language)
        default: return L10n.duration(seconds, preference: language)
        }
    }

    private static func providerRefreshSeconds(_ id: String) -> Double {
        UserDefaults.standard.double(forKey: "refreshInterval.\(id)")
    }

    private static func setProviderRefreshSeconds(_ id: String, _ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "refreshInterval.\(id)")
    }

    /// Human-readable label for the global interval — used in the picker
    /// subtitle so the user knows what "Mặc định chung" falls back to.
    private var globalIntervalLabel: String {
        let secs = settings.refreshIntervalSeconds
        return L10n.duration(secs, preference: language)
    }

    private func codexUsageSourceName(_ source: CodexUsageSource) -> String {
        switch source {
        case .auto: return L10n.t("source.auto", language)
        case .oauth: return L10n.t("source.oauth", language)
        case .cli: return L10n.t("source.cli", language)
        }
    }

    private func codexMenuBarMetricName(_ metric: CodexMenuBarMetric) -> String {
        switch metric {
        case .automatic: return L10n.t("metric.automatic", language)
        case .session: return L10n.t("metric.session", language)
        case .weekly: return L10n.t("metric.weekly", language)
        }
    }

    private func miniMaxRegionName(_ region: MiniMaxRegion) -> String {
        switch region {
        case .io: return "Global (platform.minimax.io)"
        case .com: return L10n.t("region.china", language)
        }
    }

    private func zaiRegionName(_ region: ZaiRegion) -> String {
        switch region {
        case .global: return "Global (api.z.ai)"
        case .cn: return "BigModel CN (open.bigmodel.cn)"
        }
    }

    private func alibabaRegionName(_ region: AlibabaRegion) -> String {
        switch region {
        case .international: return "International (Singapore)"
        case .chinaMainland: return "China Mainland (Beijing)"
        }
    }

    private func claudeUsageSourceName(_ source: ClaudeUsageDataSource) -> String {
        switch source {
        case .auto: return L10n.t("source.auto", language)
        case .api: return "API (Admin key)"
        case .oauth: return "OAuth API"
        case .web: return "Web API (cookies)"
        case .cli: return "CLI (PTY)"
        }
    }

    // Native cookie-source enum drives both the Claude and Codex cookie pickers
    // (identical auto/manual/off cases). Bindings persist the rawValue string,
    // which CodexWebDashboard still maps onto its own CodexBarCore enum — so the
    // Settings UI needs no CodexBarCore import.
    private func cookieSourceName(_ source: ClaudeCookieSource) -> String {
        switch source {
        case .auto: return "Auto"
        case .manual: return L10n.languageCode(language) == "vi" ? "Thủ công" : "Manual"
        case .off: return L10n.languageCode(language) == "vi" ? "Tắt" : "Off"
        }
    }

    // MARK: - Cookie-auth providers

    /// Provider ids that authenticate via a browser session cookie (no API token).
    static let cookieProviderIDs: Set<String> = [
        "commandcode", "mimo", "alibaba", "opencode", "opencodego", "cursor", "freemodel",
    ]

    /// Cookie-source picker (Auto / Manual / Off) + manual Cookie-header field.
    /// Persists to UserDefaults `<id>CookieSource` / `<id>ManualCookie`, which
    /// `ProviderCookieReader.resolvedCookieHeader` reads. Mirrors CodexBar's
    /// cookie providers (no token box).
    @ViewBuilder
    private func cookieProviderControls(_ id: String) -> some View {
        let sourceKey = "\(id)CookieSource"
        let manualKey = "\(id)ManualCookie"
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(vi ? "Nguồn cookie" : "Cookie source")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: sourceKey) ?? "auto" },
                    set: { UserDefaults.standard.set($0, forKey: sourceKey); Task { await quota.refresh() } }
                )) {
                    ForEach(ClaudeCookieSource.allCases) { s in
                        Text(cookieSourceName(s)).tag(s.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            Text(vi
                 ? "Auto: tự đọc cookie từ trình duyệt (Brave/Chrome/Safari…). Manual: dán Cookie header bên dưới."
                 : "Auto imports browser cookies. Manual uses the pasted Cookie header below.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Cookie: name=value; name2=value2 …", text: Binding(
                get: { UserDefaults.standard.string(forKey: manualKey) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: manualKey) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            Text(vi
                 ? "Chỉ dùng khi chọn Manual. Lấy ở DevTools → Network → request → header Cookie."
                 : "Used only when source = Manual. Copy from DevTools → Network → Cookie header.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Claude parity pickers

    /// Usage source picker — mirrors CodexBar's `ClaudeUsageDataSource`.
    /// `.auto` walks OAuth → Web → CLI; `.oauth` pins to OAuth (default);
    /// `.web` uses cookies only; `.cli` spawns `claude` PTY; `.api` requires
    /// an Anthropic Admin API key (handled by the field below when picked).
    @ViewBuilder
    private func claudeUsageSourcePicker() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.claudeUsageDataSource },
                    set: { settings.claudeUsageDataSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(ClaudeUsageDataSource.allCases) { src in
                        Text(claudeUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(sourceSubtitle(for: settings.claudeUsageDataSource))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sourceSubtitle(for source: String) -> String {
        switch source {
        case "auto": return L10n.t("source.claude.auto.subtitle", language)
        case "oauth": return L10n.t("source.claude.oauth.subtitle", language)
        case "web": return L10n.t("source.claude.web.subtitle", language)
        case "cli": return L10n.t("source.claude.cli.subtitle", language)
        case "api": return L10n.t("source.claude.api.subtitle", language)
        default: return ""
        }
    }

    private func codexSourceSubtitle(for source: String) -> String {
        switch source {
        case "auto": return L10n.t("source.codex.auto.subtitle", language)
        case "oauth": return L10n.t("source.codex.oauth.subtitle", language)
        case "cli": return L10n.t("source.codex.cli.subtitle", language)
        default: return ""
        }
    }

    /// OpenAI web extras toggle + cookie source (auto/manual) for Codex.
    @ViewBuilder
    private func codexWebExtrasControls() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { settings.codexOpenAIWebEnabled },
                set: { settings.codexOpenAIWebEnabled = $0; Task { await quota.refresh() } }
            )) {
                Text(L10n.t("provider.openAIWebExtras", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
            }
            Text(L10n.t("provider.openAIWebExtrasHelp", language))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)

            if settings.codexOpenAIWebEnabled {
                HStack(spacing: 12) {
                    Text(L10n.t("provider.cookie", language))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.primary)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.codexCookieSource },
                        set: { settings.codexCookieSource = $0; Task { await quota.refresh() } }
                    )) {
                        ForEach(ClaudeCookieSource.allCases) { src in
                            Text(cookieSourceName(src)).tag(src.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                if settings.codexCookieSource == "manual" {
                    TextField(L10n.t("provider.cookiePlaceholder", language), text: Binding(
                        get: { settings.codexManualCookieHeader },
                        set: { settings.codexManualCookieHeader = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Cookie source picker — mirrors CodexBar's `ProviderCookieSource`.
    @ViewBuilder
    private func claudeCookieSourcePicker() -> some View {
        SettingsRowDivider()
        HStack(spacing: 12) {
            Text(L10n.t("provider.cookieClaude", language))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeCookieSource },
                set: { settings.claudeCookieSource = $0; Task { await quota.refresh() } }
            )) {
                ForEach(ClaudeCookieSource.allCases) { src in
                    Text(cookieSourceName(src)).tag(src.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Manual Cookie: header field (only visible when source == .manual).
    /// User pastes the value copied from DevTools → Network → claude.ai
    /// request headers. Stored plaintext (only the user sees it).
    @ViewBuilder
    private func claudeManualCookieField() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("provider.manualCookie", language))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            SecureField("sessionKey=...; cf_clearance=...", text: Binding(
                get: { settings.claudeManualCookieHeader },
                set: { settings.claudeManualCookieHeader = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            Text(L10n.t("provider.manualCookieHelp", language))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Keychain prompt policy picker — mirrors CodexBar's
    /// `ClaudeOAuthKeychainPromptMode`. `.never` skips OAuth entirely (use
    /// Web/CLI); `.onlyOnUserAction` prompts only on manual refresh;
    /// `.always` prompts on every background fetch.
    @ViewBuilder
    private func claudeOAuthKeychainPromptPicker() -> some View {
        SettingsRowDivider()
        HStack(spacing: 12) {
            Text(L10n.t("provider.keychainOAuth", language))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { settings.claudeOAuthKeychainPromptMode },
                set: { settings.claudeOAuthKeychainPromptMode = $0; Task { await quota.refresh() } }
            )) {
                Text(L10n.t("prompt.never", language)).tag(ClaudeOAuthKeychainPromptMode.never.rawValue)
                Text(L10n.t("prompt.onlyOnUserAction", language)).tag(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue)
                Text(L10n.t("prompt.always", language)).tag(ClaudeOAuthKeychainPromptMode.always.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Claude accounts (multi-account)

    /// Account switcher: lists stored Claude accounts (web sessionKey / Admin
    /// API key), lets the user pick the active one, delete, or add a new one.
    /// OAuth stays single-account (system Keychain); this governs web/admin.
    @ViewBuilder
    private func claudeAccountsSection() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.languageCode(language) == "vi" ? "Tài khoản Claude" : "Claude accounts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)

            ForEach(Array(claudeAccounts.accounts.enumerated()), id: \.element.id) { idx, acc in
                HStack(spacing: 8) {
                    Image(systemName: idx == claudeAccounts.clampedActiveIndex()
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(idx == claudeAccounts.clampedActiveIndex()
                                         ? SettingsTheme.accent : SettingsTheme.tertiary)
                        .onTapGesture {
                            claudeAccounts = ClaudeTokenAccountStore.setActive(id: acc.id)
                            Task { await quota.refresh() }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(acc.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.primary)
                        Text(acc.kind == .admin ? "Admin API key" : "Web sessionKey")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        claudeAccounts = ClaudeTokenAccountStore.remove(id: acc.id)
                        Task { await quota.refresh() }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            // Add-account form.
            HStack(spacing: 6) {
                Picker("", selection: $newAccountKind) {
                    Text("Web").tag(ClaudeTokenAccount.Kind.web)
                    Text("Admin").tag(ClaudeTokenAccount.Kind.admin)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 90)
                TextField(L10n.languageCode(language) == "vi" ? "Nhãn" : "Label", text: $newAccountLabel)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 90)
                SecureField(newAccountKind == .admin ? "sk-ant-admin..." : "sessionKey sk-ant-...",
                            text: $newAccountToken)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button(L10n.languageCode(language) == "vi" ? "Thêm" : "Add") {
                    let token = newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    claudeAccounts = ClaudeTokenAccountStore.add(ClaudeTokenAccount(
                        label: newAccountLabel, token: token, kind: newAccountKind))
                    newAccountToken = ""; newAccountLabel = ""
                    Task { await quota.refresh() }
                }
                .disabled(newAccountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Antigravity settings

    /// Usage source picker for Antigravity — mirrors CodexBar's source picker.
    // MARK: - Kilo parity (usage source + organizations)

    private func kiloUsageSourceName(_ source: KiloUsageSource) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch source {
        case .auto: return vi ? "Tự động" : "Auto"
        case .api:  return "API"
        case .cli:  return "CLI"
        }
    }

    private func kiloSourceSubtitle(for source: String) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch source {
        case "api": return vi
            ? "Dùng API key (hoặc biến môi trường KILO_API_KEY)."
            : "Use the API key (or KILO_API_KEY env var)."
        case "cli": return vi
            ? "Đọc phiên đăng nhập CLI ~/.local/share/kilo/auth.json."
            : "Read the CLI session at ~/.local/share/kilo/auth.json."
        default: return vi
            ? "API key trước, fallback sang phiên CLI."
            : "API key first, then the CLI session."
        }
    }

    @ViewBuilder
    private func kiloUsageSourcePicker() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiloUsageDataSource },
                    set: { settings.kiloUsageDataSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(KiloUsageSource.allCases) { src in
                        Text(kiloUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(kiloSourceSubtitle(for: settings.kiloUsageDataSource))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Known orgs for the scope picker. Always folds in the currently-selected
    /// org (from persisted id+name) so the selection renders before a refresh.
    private var kiloScopeOrgs: [KiloOrganization] {
        var orgs = kiloKnownOrgs
        let id = settings.kiloOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, !orgs.contains(where: { $0.id == id }) {
            let name = settings.kiloOrgName.isEmpty ? id : settings.kiloOrgName
            orgs.insert(KiloOrganization(id: id, name: name), at: 0)
        }
        return orgs
    }

    @ViewBuilder
    private func kiloOrganizationsSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        SettingsCard(header: vi ? "Tổ chức" : "Organizations") {
            // Scope picker: Personal + known orgs.
            HStack(spacing: 12) {
                Text(vi ? "Phạm vi" : "Scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiloOrgID },
                    set: { newID in
                        settings.kiloOrgID = newID
                        settings.kiloOrgName = kiloKnownOrgs.first(where: { $0.id == newID })?.name ?? ""
                        Task { await quota.refresh() }
                    }
                )) {
                    Text(vi ? "Cá nhân" : "Personal").tag("")
                    ForEach(kiloScopeOrgs) { org in
                        Text(org.name).tag(org.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 6) {
                if let err = kiloOrgError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    kiloRefreshOrganizations()
                } label: {
                    HStack(spacing: 4) {
                        if kiloOrgRefreshing { ProgressView().controlSize(.small) }
                        Text(vi ? "Tải lại tổ chức" : "Refresh organizations")
                    }
                }
                .disabled(kiloOrgRefreshing)
                Text(vi
                     ? "Lấy danh sách tổ chức của tài khoản; chọn để xem hạn mức theo tổ chức."
                     : "Fetch the account's organizations; pick one to scope quota to it.")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func kiloRefreshOrganizations() {
        kiloOrgError = nil
        let vi = L10n.languageCode(language) == "vi"
        guard let resolved = KiloProvider.resolveToken(source: KiloUsageSource.current) else {
            kiloOrgError = vi
                ? "Chưa có token Kilo (nhập API key hoặc đăng nhập CLI)."
                : "No Kilo token (enter an API key or sign in via CLI)."
            return
        }
        kiloOrgRefreshing = true
        Task {
            do {
                let orgs = try await KiloOrganization.fetchOrganizations(token: resolved.token)
                await MainActor.run {
                    kiloKnownOrgs = orgs
                    if orgs.isEmpty {
                        kiloOrgError = vi
                            ? "Tài khoản không thuộc tổ chức nào."
                            : "Account has no organizations."
                    }
                    kiloOrgRefreshing = false
                }
            } catch {
                await MainActor.run {
                    kiloOrgError = error.localizedDescription
                    kiloOrgRefreshing = false
                }
            }
        }
    }

    // MARK: - Menu-bar metric (generic) + Kiro menu-bar value

    /// Per-provider "Menu bar metric" picker (CodexBar parity): Automatic (all
    /// windows) or one named window. Options come from the current status's
    /// windows, so labels match what the menu bar shows.
    @ViewBuilder
    private func menuBarMetricPicker(for id: String) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let windows = status(for: id)?.windows ?? []
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.menuBarMetric", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { _ = menuBarMetricTick; return MenuBarMetricStore.metric(id) },
                    set: {
                        MenuBarMetricStore.setMetric(id, $0)
                        menuBarMetricTick += 1
                        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                    }
                )) {
                    Text(vi ? "Tự động" : "Automatic").tag("")
                    ForEach(windows) { w in
                        Text(w.label).tag(w.label)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            Text(vi ? "Chọn window nào lái % trên menu bar."
                    : "Choose which window drives the menu bar percent.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func kiroMenuBarValueName(_ m: KiroMenuBarDisplayMode) -> String {
        let vi = L10n.languageCode(language) == "vi"
        switch m {
        case .automatic: return vi ? "Tự động" : "Automatic"
        case .hidden: return vi ? "Ẩn" : "Hidden"
        case .creditsLeft: return vi ? "Credits còn lại" : "Credits left"
        case .percentLeft: return vi ? "Phần trăm còn lại" : "Percent left"
        case .creditsAndPercent: return vi ? "Credits + %" : "Credits + percent"
        case .usedAndTotal: return vi ? "Đã dùng / tổng" : "Used / total"
        case .overageCreditsWhenExhausted: return vi ? "Overage credits (khi hết)" : "Overage credits at zero"
        case .overageCostWhenExhausted: return vi ? "Overage $ (khi hết)" : "Overage cost at zero"
        case .overageCreditsAndCostWhenExhausted: return vi ? "Overage credits + $ (khi hết)" : "Overage credits + cost at zero"
        }
    }

    @ViewBuilder
    private func kiroMenuBarValuePicker() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(vi ? "Giá trị menu bar Kiro" : "Kiro menu bar value")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.kiroMenuBarDisplayMode },
                    set: {
                        settings.kiroMenuBarDisplayMode = $0
                        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                    }
                )) {
                    ForEach(KiroMenuBarDisplayMode.allCases) { m in
                        Text(kiroMenuBarValueName(m)).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            Text(vi ? "Hiện credits, phần trăm, hoặc cả hai cạnh icon menu bar."
                    : "Show or hide Kiro credits, percent, or both next to the menu bar icon.")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Gemini / Kiro sign-in (zero-config) + Bedrock AWS auth

    private func geminiLoginStatus() -> String {
        let vi = L10n.languageCode(language) == "vi"
        if let email = GeminiProvider.signedInEmail() {
            return vi ? "Đã đăng nhập: \(email)" : "Signed in: \(email)"
        }
        if GeminiProvider.isSignedIn() {
            return vi ? "Đã đăng nhập" : "Signed in"
        }
        return vi ? "Chưa đăng nhập" : "Not signed in"
    }

    @ViewBuilder
    private func geminiSignInSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            Text(vi ? "Đăng nhập" : "Sign in")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(geminiLoginStatus())
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondary)
            Text(vi
                 ? "Gemini dùng đăng nhập Google qua Gemini CLI (~/.gemini/oauth_creds.json). Chạy `gemini` rồi đăng nhập."
                 : "Gemini uses Google sign-in via the Gemini CLI (~/.gemini/oauth_creds.json). Run `gemini` and log in.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func kiroSignInSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        VStack(alignment: .leading, spacing: 4) {
            Text(vi ? "Đăng nhập" : "Sign in")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsTheme.primary)
            Text(vi
                 ? "Kiro dùng Kiro CLI (không cần API token). Đăng nhập bằng `kiro-cli login`; usage lấy qua CLI."
                 : "Kiro uses the Kiro CLI (no API token). Sign in with `kiro-cli login`; usage is read via the CLI.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One labeled AWS credential field bound to a config keyPath via `rows[idx]`.
    @ViewBuilder
    private func bedrockField(
        _ idx: Int, title: String, placeholder: String,
        keyPath: WritableKeyPath<BirdNionConfigStore.Provider, String?>, secure: Bool) -> some View {
        let binding = Binding<String>(
            get: { rows[idx][keyPath: keyPath] ?? "" },
            set: { raw in
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                rows[idx][keyPath: keyPath] = v.isEmpty ? nil : v
                saveAll()
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            })
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsTheme.primary)
            if secure {
                SecureField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            } else {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
        }
    }

    @ViewBuilder
    private func bedrockAuthSection(_ idx: Int) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let mode = rows[idx].awsAuthMode ?? "keys"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(vi ? "Xác thực" : "Authentication")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { rows[idx].awsAuthMode ?? "keys" },
                    set: {
                        rows[idx].awsAuthMode = $0
                        saveAll()
                        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                    }
                )) {
                    Text(vi ? "Khóa truy cập" : "Access keys").tag("keys")
                    Text("AWS profile").tag("profile")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            if mode == "profile" {
                bedrockField(idx, title: vi ? "Tên profile" : "Profile name",
                             placeholder: "default", keyPath: \.awsProfile, secure: false)
                Text(vi
                     ? "Profile trong ~/.aws/config (dùng khóa tĩnh; SSO/assume-role chưa hỗ trợ)."
                     : "Named profile from ~/.aws/config (static keys; SSO/assume-role not yet supported).")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            } else {
                bedrockField(idx, title: "Access key ID",
                             placeholder: "AKIA…", keyPath: \.apiKey, secure: true)
                bedrockField(idx, title: vi ? "Secret access key" : "Secret access key",
                             placeholder: "", keyPath: \.secretKey, secure: true)
            }
            bedrockField(idx, title: "Region", placeholder: "us-east-1",
                         keyPath: \.region, secure: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func antigravityUsageSourcePicker() -> some View {
        SettingsRowDivider()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.t("provider.dataSource", language))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { settings.antigravityUsageSource },
                    set: { settings.antigravityUsageSource = $0; Task { await quota.refresh() } }
                )) {
                    ForEach(AntigravityUsageSource.allCases) { src in
                        Text(antigravityUsageSourceName(src)).tag(src.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func antigravityUsageSourceName(_ source: AntigravityUsageSource) -> String {
        switch source {
        case .auto: return L10n.languageCode(language) == "vi" ? "Tự động" : "Auto"
        case .app:  return L10n.languageCode(language) == "vi" ? "Ứng dụng Antigravity" : "Antigravity App"
        case .ide:  return "IDE"
        case .cli:  return "agy CLI"
        case .oauth: return "Google OAuth"
        }
    }

    /// Google OAuth accounts card for Antigravity.
    @ViewBuilder
    private func antigravityOAuthAccountsSection() -> some View {
        let vi = L10n.languageCode(language) == "vi"
        SettingsCard(header: vi ? "Tài khoản Google" : "Google Accounts") {
            // Account list
            if antigravityStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(antigravityStore.accounts.enumerated()), id: \.element.label) { idx, acc in
                    let isActive = antigravityStore.activeLabel == acc.label
                        || (antigravityStore.activeLabel == nil && idx == 0)
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if let email = acc.email {
                                Text(email)
                                    .font(.system(size: 10))
                                    .foregroundStyle(SettingsTheme.tertiary)
                            }
                        }
                        Spacer()
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                var s = antigravityStore
                                AntigravityOAuthStore.setActive(in: &s, label: acc.label)
                                try? AntigravityOAuthStore.save(s)
                                antigravityStore = s
                                Task { await quota.refresh() }
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            var s = antigravityStore
                            AntigravityOAuthStore.removeAccount(from: &s, label: acc.label)
                            try? AntigravityOAuthStore.save(s)
                            antigravityStore = s
                            Task { await quota.refresh() }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if idx < antigravityStore.accounts.count - 1 { SettingsRowDivider() }
                }
            }

            SettingsRowDivider()

            // Add account via JSON paste
            VStack(alignment: .leading, spacing: 6) {
                Text(vi ? "Thêm tài khoản" : "Add account")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                HStack(spacing: 6) {
                    TextField(vi ? "Nhãn" : "Label", text: $antigravityNewLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 100)
                    SecureField(vi ? "OAuth credentials JSON" : "OAuth credentials JSON", text: $antigravityNewJSON)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(vi ? "Thêm" : "Add") {
                        antigravityAddFromJSON()
                    }
                    .disabled(antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(vi
                     ? "Dán JSON: {\"client_id\":\"…\",\"client_secret\":\"…\",\"refresh_token\":\"…\"}"
                     : "Paste JSON: {\"client_id\":\"…\",\"client_secret\":\"…\",\"refresh_token\":\"…\"}")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsRowDivider()

            // Login with Google + utility buttons
            VStack(alignment: .leading, spacing: 8) {
                if let err = antigravityLoginError {
                    Text(L10n.providerText(err, preference: language))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        antigravityLoginError = nil
                        let s = antigravityStore
                        guard let clientID = AntigravityOAuthStore.resolvedClientID(store: s),
                              let clientSecret = AntigravityOAuthStore.resolvedClientSecret(store: s) else {
                            antigravityLoginError = vi
                                ? "Cần đặt ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET hoặc dán credentials JSON trước."
                                : "Set ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET or paste credentials JSON first."
                            return
                        }
                        antigravityLoginInProgress = true
                        Task {
                            do {
                                let (refreshToken, email) = try await AntigravityOAuthLogin.login(
                                    clientID: clientID, clientSecret: clientSecret)
                                var store = AntigravityOAuthStore.load()
                                let label = email ?? (vi ? "Tài khoản" : "Account")
                                AntigravityOAuthStore.addAccount(to: &store, label: label,
                                                                  refreshToken: refreshToken, email: email)
                                try? AntigravityOAuthStore.save(store)
                                antigravityStore = store
                                await quota.refresh()
                            } catch {
                                antigravityLoginError = error.localizedDescription
                            }
                            antigravityLoginInProgress = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if antigravityLoginInProgress {
                                ProgressView().controlSize(.small)
                            }
                            Text(vi ? "Đăng nhập Google" : "Login with Google")
                        }
                    }
                    .disabled(antigravityLoginInProgress)

                    Button(vi ? "Mở file token" : "Open token file") {
                        NSWorkspace.shared.open(AntigravityOAuthStore.fileURL)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)

                    Button(vi ? "Tải lại" : "Reload") {
                        antigravityReloadTick += 1
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Copilot accounts

    /// GitHub accounts card for Copilot — Device Flow (mirrors antigravityOAuthAccountsSection).
    @ViewBuilder
    private func copilotOAuthAccountsSection(idx: Int) -> some View {
        let vi = L10n.languageCode(language) == "vi"
        let enterpriseHost: String = {
            guard rows.indices.contains(idx) else { return "github.com" }
            let raw = rows[idx].baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "github.com" : raw
        }()

        SettingsCard(header: vi ? "Tài khoản GitHub" : "GitHub Accounts") {
            // Account list
            if copilotStore.accounts.isEmpty {
                Text(vi ? "Chưa có tài khoản nào." : "No accounts.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(copilotStore.accounts.enumerated()), id: \.element.label) { i, acc in
                    let isActive = copilotStore.activeLabel == acc.label
                        || (copilotStore.activeLabel == nil && i == 0)
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? SettingsTheme.accent : SettingsTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.login ?? acc.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SettingsTheme.primary)
                            if isActive {
                                Text(vi ? "Đang dùng" : "Active")
                                    .font(.system(size: 10))
                                    .foregroundStyle(SettingsTheme.accent)
                            }
                        }
                        Spacer()
                        if !isActive {
                            Button(vi ? "Đặt mặc định" : "Set default") {
                                var s = copilotStore
                                CopilotAccountStore.setActive(in: &s, label: acc.label)
                                try? CopilotAccountStore.save(s)
                                copilotStore = s
                                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.accent)
                        }
                        Button {
                            var s = copilotStore
                            CopilotAccountStore.removeAccount(from: &s, label: acc.label)
                            try? CopilotAccountStore.save(s)
                            copilotStore = s
                            NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(SettingsTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if i < copilotStore.accounts.count - 1 { SettingsRowDivider() }
                }
            }

            SettingsRowDivider()

            // Device user code display — shown while waiting for user to enter on GitHub
            if let userCode = copilotDeviceUserCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vi
                         ? "Nhập mã XXXX-XXXX sau tại github.com/login/device:"
                         : "Enter code at github.com/login/device:")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
                    Text(userCode)
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .foregroundStyle(SettingsTheme.accent)
                        .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                SettingsRowDivider()
            }

            // Error display
            if let err = copilotLoginError {
                Text(L10n.providerText(err, preference: language))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                SettingsRowDivider()
            }

            // Action buttons
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        copilotLoginError = nil
                        copilotLoginInProgress = true
                        copilotDeviceUserCode = nil
                        copilotLoginTask?.cancel()
                        copilotLoginTask = Task {
                            do {
                                let dc = try await CopilotDeviceFlow.start(host: enterpriseHost)
                                await MainActor.run {
                                    copilotDeviceUserCode = dc.userCode
                                    if let uri = URL(string: dc.verificationURI) {
                                        NSWorkspace.shared.open(uri)
                                    }
                                }
                                let res = try await CopilotDeviceFlow.poll(
                                    host: enterpriseHost,
                                    deviceCode: dc.deviceCode,
                                    interval: dc.interval
                                )
                                await MainActor.run {
                                    let loginLabel = res.login ?? "GitHub"
                                    var s = CopilotAccountStore.load()
                                    CopilotAccountStore.addAccount(
                                        to: &s, label: loginLabel, token: res.token, login: res.login)
                                    CopilotAccountStore.setActive(in: &s, label: loginLabel)
                                    try? CopilotAccountStore.save(s)
                                    copilotStore = s
                                    copilotDeviceUserCode = nil
                                    copilotLoginInProgress = false
                                    NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
                                }
                            } catch is CancellationError {
                                await MainActor.run {
                                    copilotDeviceUserCode = nil
                                    copilotLoginInProgress = false
                                }
                            } catch {
                                await MainActor.run {
                                    copilotDeviceUserCode = nil
                                    copilotLoginError = error.localizedDescription
                                    copilotLoginInProgress = false
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if copilotLoginInProgress {
                                ProgressView().controlSize(.small)
                            }
                            Text(vi ? "Đăng nhập GitHub (Add Account)" : "Login with GitHub (Add Account)")
                        }
                    }
                    .disabled(copilotLoginInProgress)
                }
                HStack(spacing: 8) {
                    Button(vi ? "Mở file token" : "Open token file") {
                        NSWorkspace.shared.open(CopilotAccountStore.fileURL)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)

                    Button(vi ? "Tải lại" : "Reload") {
                        copilotReloadTick += 1
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Parse best-effort OAuth credentials JSON and update the store.
    private func antigravityAddFromJSON() {
        let raw = antigravityNewJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }

        var s = antigravityStore
        // Update client credentials if present
        if let cid = obj["client_id"], !cid.isEmpty { s.clientId = cid }
        if let cs = obj["client_secret"], !cs.isEmpty { s.clientSecret = cs }
        // Add account if refresh_token present
        if let rt = obj["refresh_token"], !rt.isEmpty {
            let trimmedLabel = antigravityNewLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedLabel.isEmpty
                ? (obj["email"] ?? (L10n.languageCode(language) == "vi" ? "Tài khoản" : "Account"))
                : trimmedLabel
            AntigravityOAuthStore.addAccount(to: &s, label: label, refreshToken: rt, email: obj["email"])
        }
        try? AntigravityOAuthStore.save(s)
        antigravityStore = s
        antigravityNewLabel = ""
        antigravityNewJSON = ""
        Task { await quota.refresh() }
    }

    // MARK: - Links / dashboards

    /// External management links for the selected provider. Codex also gets a
    /// status page + changelog; MiniMax's dashboard follows the chosen region.
    @ViewBuilder
    private func linksSection(_ row: BirdNionConfigStore.Provider) -> some View {
        let links = dashboardLinks(for: row.id)
        if !links.isEmpty {
            SettingsCard(header: L10n.t("settings.section.links", language)) {
                ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                    Button {
                        NSWorkspace.shared.open(link.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: link.icon)
                                .frame(width: 16)
                            Text(link.title)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SettingsTheme.tertiary)
                        }
                        .foregroundStyle(SettingsTheme.primary)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    if i < links.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private struct DashboardLink { let title: String; let icon: String; let url: URL }

    private func dashboardLinks(for id: String) -> [DashboardLink] {
        func u(_ s: String) -> URL? { URL(string: s) }
        // Generic link builders so each provider stays a one-liner. URLs mirror
        // CodexBar's descriptors exactly (see docs/provider-parity).
        func dash(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.dashboard", language), icon: "chart.bar", url: $0) }
        }
        func stat(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.status", language), icon: "waveform.path.ecg", url: $0) }
        }
        func usage(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.usage", language), icon: "chart.bar", url: $0) }
        }
        func sub(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.subscription", language), icon: "creditcard", url: $0) }
        }
        func billing(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.billing", language), icon: "creditcard", url: $0) }
        }
        func changelog(_ s: String) -> DashboardLink? {
            u(s).map { DashboardLink(title: L10n.t("provider.link.changelog", language), icon: "doc.text", url: $0) }
        }
        let googleStatus = "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history"
        let awsStatus = "https://health.aws.amazon.com/health/status"

        switch id {
        case "codex":
            return [
                u("https://chatgpt.com/codex/settings/usage").map { DashboardLink(title: L10n.t("provider.link.codexUsage", language), icon: "chart.bar", url: $0) },
                stat("https://status.openai.com/"),
                changelog("https://github.com/openai/codex/releases"),
            ].compactMap { $0 }
        case "claude":
            return [
                billing("https://console.anthropic.com/settings/billing"),
                usage("https://claude.ai/settings/usage"),
                stat("https://status.claude.com/"),
            ].compactMap { $0 }
        case "minimax":
            return [DashboardLink(title: L10n.t("provider.link.minimaxPlan", language), icon: "chart.bar", url: MiniMaxRegion.current.dashboardURL)]
        case "openrouter":
            return [
                u("https://openrouter.ai/settings/credits").map { DashboardLink(title: L10n.t("provider.link.openRouterCredits", language), icon: "chart.bar", url: $0) },
                u("https://openrouter.ai/keys").map { DashboardLink(title: L10n.t("provider.link.apiKeys", language), icon: "key", url: $0) },
                stat("https://status.openrouter.ai"),
            ].compactMap { $0 }
        case "deepseek":
            return [
                u("https://platform.deepseek.com/usage").map { DashboardLink(title: L10n.t("provider.link.deepSeekBalance", language), icon: "chart.bar", url: $0) },
                stat("https://status.deepseek.com"),
            ].compactMap { $0 }
        case "zai":
            return [DashboardLink(title: L10n.t("provider.link.codingPlan", language), icon: "chart.bar",
                                  url: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!)]
        case "elevenlabs":
            return [usage("https://elevenlabs.io/app/developers/usage"),
                    sub("https://elevenlabs.io/app/subscription"),
                    stat("https://status.elevenlabs.io")].compactMap { $0 }
        case "deepgram":
            return [dash("https://console.deepgram.com/project/"), stat("https://status.deepgram.com")].compactMap { $0 }
        case "groq":
            return [dash("https://console.groq.com/dashboard/metrics"), stat("https://status.groq.com")].compactMap { $0 }
        case "copilot":
            return [dash("https://github.com/settings/copilot"), stat("https://www.githubstatus.com/")].compactMap { $0 }
        case "kilo":
            return [dash("https://app.kilo.ai/usage")].compactMap { $0 }
        case "commandcode":
            return [dash("https://commandcode.ai/studio")].compactMap { $0 }
        case "freemodel":
            return [usage("https://freemodel.dev/dashboard/usage")].compactMap { $0 }
        case "mimo":
            return [dash("https://platform.xiaomimimo.com/#/console/balance")].compactMap { $0 }
        case "opencode", "opencodego":
            return [dash("https://opencode.ai")].compactMap { $0 }
        case "cursor":
            return [dash("https://cursor.com/dashboard?tab=usage"), stat("https://status.cursor.com")].compactMap { $0 }
        case "gemini":
            return [dash("https://gemini.google.com"),
                    stat(googleStatus),
                    changelog("https://github.com/google-gemini/gemini-cli/releases")].compactMap { $0 }
        case "kiro":
            return [dash("https://app.kiro.dev/account/usage"), stat(awsStatus)].compactMap { $0 }
        case "antigravity":
            return [stat(googleStatus)].compactMap { $0 }
        case "bedrock":
            return [dash("https://console.aws.amazon.com/bedrock"), stat(awsStatus)].compactMap { $0 }
        default:
            return []
        }
    }


    // MARK: - Drag & drop

    /// Drop delegate for internal provider reordering. The drag source stores
    /// its id synchronously, which avoids waiting for NSItemProvider decoding
    /// after the user releases the mouse.
    private struct SidebarRowDropDelegate: DropDelegate {
        let targetRow: BirdNionConfigStore.Provider
        let targetPosition: Int
        @Binding var draggedProviderId: String?
        @Binding var dropTargetRowId: String?
        let movePreview: (String, Int) -> Void
        let finish: () -> Void

        func dropEntered(info: DropInfo) {
            guard let draggedProviderId, draggedProviderId != targetRow.id else { return }
            dropTargetRowId = targetRow.id
            movePreview(draggedProviderId, targetPosition)
        }

        func dropExited(info: DropInfo) {
            if dropTargetRowId == targetRow.id {
                dropTargetRowId = nil
            }
        }

        func performDrop(info: DropInfo) -> Bool {
            guard draggedProviderId != nil else {
                dropTargetRowId = nil
                return false
            }
            finish()
            self.draggedProviderId = nil
            dropTargetRowId = nil
            return true
        }

        func validateDrop(info: DropInfo) -> Bool {
            draggedProviderId != nil
                && info.hasItemsConforming(to: [ProvidersPane.providerDragType])
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }
    }

    /// Accepts a drop in the divider/gap between rows. The nearest row has
    /// already updated the live preview, so this delegate only commits it.
    private struct SidebarDropCompletionDelegate: DropDelegate {
        @Binding var draggedProviderId: String?
        @Binding var dropTargetRowId: String?
        let finish: () -> Void

        func performDrop(info: DropInfo) -> Bool {
            guard draggedProviderId != nil else { return false }
            finish()
            draggedProviderId = nil
            dropTargetRowId = nil
            return true
        }

        func validateDrop(info: DropInfo) -> Bool {
            draggedProviderId != nil
                && info.hasItemsConforming(to: [ProvidersPane.providerDragType])
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }
    }

    // MARK: - Bindings & helpers

    private func enabledBinding(_ idx: Int) -> Binding<Bool> {
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
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            }
        )
    }

    private func labelBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { rows[idx].accountLabel ?? "" },
            set: {
                rows[idx].accountLabel = $0.isEmpty ? nil : $0
                saveAll()
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            }
        )
    }

    private func status(for id: String) -> ProviderStatus? {
        quota.statuses.first { $0.id == id }
    }

    private func displayName(for row: BirdNionConfigStore.Provider) -> String {
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
        default: row.displayName ?? row.id
        }
    }

    private func statusSubtitle(for row: BirdNionConfigStore.Provider) -> String {
        if row.enabled != true { return L10n.t("provider.disabled", language) }
        guard let s = status(for: row.id) else { return L10n.t("provider.notLoaded", language) }
        if let err = s.error, !err.isEmpty {
            // Truncate long error messages so the sidebar row stays a single
            // line. The full message is still reachable via the tooltip
            // (`statusSubtitleDetail`) and the detail pane.
            let localized = L10n.providerText(err, preference: language)
            return L10n.f("provider.errorPrefix", language, truncated(localized, max: 32))
        }
        if let first = s.windows.first {
            return L10n.f("provider.remaining", language, first.remainingPct)
        }
        return L10n.t("provider.loading", language)
    }

    /// Full error message for the sidebar row's `.help()` tooltip. Hover
    /// the row to see the entire message — useful when the truncated pill
    /// cuts off at "Lỗi: cookie is miss…".
    private func statusSubtitleDetail(for row: BirdNionConfigStore.Provider) -> String? {
        guard row.enabled == true,
              let err = status(for: row.id)?.error,
              !err.isEmpty else { return nil }
        return L10n.providerText(err, preference: language)
    }

    /// Truncate `s` to `max` characters with an ellipsis suffix when it
    /// exceeds the limit. Pure string helper.
    private func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// Header subtitle: prefix the CLI version when known (Codex), e.g.
    /// "codex-cli 0.140.0 • 2 giây trước".
    private func headerSubtitle(for row: BirdNionConfigStore.Provider) -> String {
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

    private func updatedSubtitle(for id: String) -> String {
        guard let s = status(for: id) else { return L10n.t("provider.notLoaded", language) }
        return L10n.relativeUpdated(from: s.lastUpdated, preference: language)
    }

    private func codexLoginStatus() -> String {
        guard let creds = try? CodexAuthStore.load() else {
            return L10n.languageCode(language) == "vi" ? "Chưa đăng nhập" : "Not signed in"
        }
        if let email = CodexAuthStore.emailFromIDToken(creds.idToken) {
            return L10n.languageCode(language) == "vi" ? "Đã đăng nhập: \(email)" : "Signed in: \(email)"
        }
        return L10n.languageCode(language) == "vi" ? "Đã đăng nhập" : "Signed in"
    }

    private func saveAll() {
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
            Image(systemName: "circle.dotted")
                .resizable()
                .foregroundStyle(tint ?? SettingsTheme.secondary)
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

// MARK: - Token field

/// Secure token entry + save button for providers that authenticate with a
/// bearer token (everything except zero-config Codex).
private struct TokenField: View {
    @EnvironmentObject var settings: SettingsStore

    let providerID: String
    let onSaved: () -> Void

    @State private var token = ""
    @State private var banner: String?

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

private struct SettingsCheckboxGlyph: View {
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
private struct QuotaWarningCard: View {
    @EnvironmentObject var settings: SettingsStore

    let providerID: String

    @State private var sessionCustom = false
    @State private var weeklyCustom = false
    @State private var sessionLevels: [Int] = [50, 20]
    @State private var weeklyLevels: [Int] = [50, 20]

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
    private func windowRow(title: String, window: String,
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

    private func levelStepper(_ label: String, levels: Binding<[Int]>, index: Int, window: String) -> some View {
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

    private func load() {
        sessionCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "session")
        weeklyCustom = QuotaWarnConfig.hasOverride(provider: providerID, window: "weekly")
        sessionLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "session"))
        weeklyLevels = padded(QuotaWarnConfig.thresholds(provider: providerID, window: "weekly"))
    }

    /// Ensure exactly two levels for the two steppers.
    private func padded(_ values: [Int]) -> [Int] {
        var x = values
        while x.count < 2 { x.append(x.last ?? 20) }
        return Array(x.prefix(2))
    }
}

// MARK: - Codex accounts card

/// Multi-account management for Codex. The system account (~/.codex) is shown
/// read-only; managed accounts live in their own CODEX_HOME and are added via
/// `codex login` in the browser. Selecting one switches which login the
/// provider reads.
private struct CodexAccountsCard: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var accounts: [CodexAccount] = []
    @State private var activeID = "system"
    @State private var busy = false
    @State private var errorText: String?

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
    }

    private func accountRow(_ account: CodexAccount) -> some View {
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
            } else {
                Button(role: .destructive) {
                    CodexAccountStore.remove(id: account.id)
                    reload()
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

    private var addRow: some View {
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

    private func reload() {
        accounts = CodexAccountStore.allAccounts()
        activeID = CodexAccountStore.activeID()
    }

    private func add() async {
        busy = true; errorText = nil
        defer { busy = false }
        do { _ = try await CodexAccountStore.addAccount(); reload() }
        catch { errorText = error.localizedDescription }
    }

    private func reauth(_ id: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do { try await CodexAccountStore.reauth(id: id); reload() }
        catch { errorText = error.localizedDescription }
    }

    private func promote() {
        errorText = nil
        do { _ = try CodexAccountStore.promoteSystem(); reload() }
        catch { errorText = error.localizedDescription }
    }
}
