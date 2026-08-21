import SwiftUI

/// Vertical settings sidebar: search filters nav titles, colored icon tiles,
/// optional badges, and version footer. The five nav items form one contiguous
/// block; `extra` renders a contextual list (provider roster / AI-coding
/// configs) below them, separated by a divider, while the owning pane keeps
/// that list's state. (Remake P2; file name kept for pbxproj stability.)
struct SettingsSidebar<Extra: View>: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService

    @Binding var selected: SettingsTab
    /// Single top search shared with contextual lists (providers / AI Coding).
    @Binding var searchText: String
    private let hasExtra: Bool
    private let extra: () -> Extra

    init(
        selected: Binding<SettingsTab>,
        searchText: Binding<String>,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self._selected = selected
        self._searchText = searchText
        self.extra = extra
        self.hasExtra = true
    }

    @State private var providersWithKey = 0
    @State private var activeAgentCount = 0
    @State private var hovering: SettingsTab?

    private var filteredTabs: [SettingsTab] {
        filter(SettingsTab.allSidebar)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    SettingsTheme.hairline.frame(height: 1)
                }

            // Five fixed rows — no scroll needed; the contextual list below
            // owns the remaining height instead.
            VStack(spacing: 2) {
                ForEach(filteredTabs) { tab in
                    navRow(tab)
                }
            }
            .padding(.horizontal, 8)

            if hasExtra {
                Divider()
                    .overlay(SettingsTheme.hairline)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                extra()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Spacer(minLength: 0)

            Text("BirdNion \(appVersion)")
                .font(.plexMono(10))
                .tracking(0.6)
                .foregroundStyle(SettingsTheme.tertiary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    SettingsTheme.hairline.frame(height: 1)
                }
        }
        .frame(width: 210)
        .background(SettingsTheme.toolbar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SettingsTheme.border)
                .frame(width: 1)
        }
        .onAppear { refreshBadges() }
        .onReceive(NotificationCenter.default.publisher(for: .birdnionProvidersChanged)) { _ in
            refreshBadges()
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.tertiary)
            TextField(
                L10n.t("settings.sidebar.search", settings.appLanguage),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.plexSans(12))
            .foregroundStyle(SettingsTheme.primary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SettingsTheme.tertiary)
                        .accessibilityLabel(L10n.t("provider.clearSearch", settings.appLanguage))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    // MARK: - Nav row

    private func navRow(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selected
        let isHovering = hovering == tab
        let badge = badgeText(for: tab)

        return Button {
            selected = tab
        } label: {
            HStack(spacing: 9) {
                // Plain, tile-less icon — the Instrument redesign drops the
                // colored rounded icon-tile background used by the old design;
                // the icon just inherits the row's ink/paper text color.
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? SettingsTheme.background : SettingsTheme.secondary)
                    .frame(width: 14, height: 14)

                Text(tab.title(language: settings.appLanguage))
                    .font(.plexSans(13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SettingsTheme.background : SettingsTheme.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge {
                    // Plain mono text, no pill/capsule fill — mockup shows a
                    // bare colored number/label, not a filled badge.
                    Text(badge)
                        .font(.plexMono(10, weight: .semibold))
                        .foregroundStyle(isSelected ? SettingsTheme.background : SettingsTheme.success)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(isSelected
                          ? SettingsTheme.primary
                          : (isHovering ? SettingsTheme.hoverSurface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside ? tab : (hovering == tab ? nil : hovering)
        }
        .pointingHandCursor()
        .help(tab.title(language: settings.appLanguage))
        .accessibilityLabel(tab.title(language: settings.appLanguage))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Filter / badges

    private func filter(_ tabs: [SettingsTab]) -> [SettingsTab] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tabs }
        return tabs.filter {
            $0.title(language: settings.appLanguage)
                .range(of: q, options: .caseInsensitive) != nil
        }
    }

    private func badgeText(for tab: SettingsTab) -> String? {
        switch tab {
        case .providers:
            return providersWithKey > 0 ? "\(providersWithKey)" : nil
        case .aiCoding:
            return activeAgentCount > 0 ? "\(activeAgentCount) ON" : nil
        default:
            return nil
        }
    }

    @MainActor
    private func refreshBadges() {
        providersWithKey = BirdNionConfigStore.allProviders().filter {
            Self.cleaned($0.apiKey) != nil
        }.count

        var agents = 0
        if CodexConfigWriter.activeProfileID() != nil {
            agents += 1
        }
        if hasSyncedClaudeAgent() {
            agents += 1
        }
        activeAgentCount = agents
    }

    /// True when any Claude Code provider or custom profile is currently synced
    /// to its configured scope. Reuses public `ClaudeCodeConfigWriter` APIs.
    @MainActor
    private func hasSyncedClaudeAgent() -> Bool {
        for p in BirdNionConfigStore.allProviders() where ClaudeCodeConfigWriter.isFullyConfigured(p) {
            let scope = claudeScope(scopeValue: p.claudeCodeScope, projectPath: p.claudeCodeProjectPath)
            if ClaudeCodeConfigWriter.syncState(forProvider: p, scope: scope, using: config) == .synced {
                return true
            }
        }
        for p in BirdNionConfigStore.claudeCodeProfiles() {
            let scope = claudeScope(scopeValue: p.claudeCodeScope, projectPath: p.claudeCodeProjectPath)
            if ClaudeCodeConfigWriter.syncState(forProfile: p, scope: scope, using: config) == .synced {
                return true
            }
        }
        return false
    }

    private func claudeScope(scopeValue: String?, projectPath: String?) -> ClaudeCodeConfigWriter.Scope {
        guard scopeValue == "project",
              let path = Self.cleaned(projectPath) else {
            return .global
        }
        return .project(URL(fileURLWithPath: path))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension SettingsSidebar where Extra == EmptyView {
    /// Nav-only sidebar (General / Advanced / About tabs).
    init(selected: Binding<SettingsTab>, searchText: Binding<String>) {
        self._selected = selected
        self._searchText = searchText
        self.extra = { EmptyView() }
        self.hasExtra = false
    }
}
