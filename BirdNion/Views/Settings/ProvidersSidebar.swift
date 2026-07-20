import SwiftUI
import UniformTypeIdentifiers

// MARK: - Providers sidebar (P4 module split)

extension ProvidersPane {
    // MARK: - Sidebar

    /// View order for the sidebar:
    /// 1. **Enabled (active)** first — user custom order from `rows` / drag-reorder
    /// 2. **Disabled** after — A→Z by display name so the long roster is scannable
    ///
    /// Search narrows both groups by display name + id (case-insensitive).
    var visibleRows: [BirdNionConfigStore.Provider] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let filtered = rows.filter { row in
            guard !query.isEmpty else { return true }
            return displayName(for: row).lowercased().contains(query)
                || row.id.lowercased().contains(query)
        }
        // Active: preserve relative order in `rows` (drag-reorder writes that array).
        let active = filtered.filter { $0.enabled == true }
        // Inactive: alphabetical so disabled roster is easy to find.
        let inactive = filtered
            .filter { $0.enabled != true }
            .sorted {
                displayName(for: $0)
                    .localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
            }
        return active + inactive
    }

    /// Provider roster — rendered inside the Settings sidebar column (below
    /// the nav block), so it fills the column width and scrolls on its own.
    var sidebar: some View {
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
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Move rows as soon as the pointer enters a sibling row. Persistence and
    /// provider rebuild happen only once in `finishRowMove`, when the user
    /// drops, so the animation stays responsive.
    func previewRowMove(draggedId: String, toVisibleIndex targetIndex: Int) {
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

    func finishRowMove() {
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
    var searchField: some View {
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

    func sidebarRow(_ row: BirdNionConfigStore.Provider, position: Int) -> some View {
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
                // Secondary line: remaining quota % tinted by level when available
                // (mockup P4); errors stay critical; no quota → existing status text.
                Text(statusSubtitle(for: row))
                    .font(.system(size: 10))
                    .foregroundStyle(sidebarSubtitleColor(for: row))
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

    /// Tint for the sidebar secondary line: critical on error, `quotaColor`
    /// when a remaining-% window exists, otherwise secondary.
    func sidebarSubtitleColor(for row: BirdNionConfigStore.Provider) -> Color {
        if row.enabled != true { return SettingsTheme.secondary }
        guard let s = status(for: row.id) else { return SettingsTheme.secondary }
        if s.error != nil { return SettingsTheme.critical }
        if let first = s.windows.first {
            return SettingsTheme.quotaColor(remaining: first.remainingPct)
        }
        return SettingsTheme.secondary
    }

    func setProviderEnabled(id: String, enabled: Bool) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].enabled = enabled
        saveAll()
        // Rebuild providers via ServicesContainer so the menu-bar popover +
        // percent rotation pick up the new state. Use the notification path so
        // the rebuild happens on the main thread via AppDelegate.
        NotificationCenter.default.post(name: .birdnionProvidersChanged, object: nil)
        NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
    }

    func sidebarCheckbox(for row: BirdNionConfigStore.Provider) -> some View {
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

    func checkboxGlyph(isOn: Bool) -> some View {
        SettingsCheckboxGlyph(isOn: isOn)
    }

    func sidebarLogoTint(for row: BirdNionConfigStore.Provider, selected: Bool) -> Color {
        if row.enabled != true { return SettingsTheme.disabled.opacity(0.82) }
        return selected ? SettingsTheme.accent : SettingsTheme.secondary
    }

    // MARK: - Drag & drop

    /// Drop delegate for internal provider reordering. The drag source stores
    /// its id synchronously, which avoids waiting for NSItemProvider decoding
    /// after the user releases the mouse.
    struct SidebarRowDropDelegate: DropDelegate {
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
    struct SidebarDropCompletionDelegate: DropDelegate {
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
}
