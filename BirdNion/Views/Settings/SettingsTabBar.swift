import SwiftUI

/// Vertical settings sidebar: pinned search + always-visible page nav, optional
/// contextual roster (or unified search hits), pinned version footer.
struct SettingsSidebar<Extra: View>: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService

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

    @ObservedObject private var updater = UpdateChecker.shared
    @State private var providersWithKey = 0
    @State private var activeAgentCount = 0
    @State private var hovering: SettingsTab?

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !searchQuery.isEmpty }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned search.
            searchField
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    SettingsTheme.hairline.frame(height: 1)
                }

            // Page nav always stays visible; below it either search hits or
            // the contextual Providers / AI Coding roster.
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 2) {
                        ForEach(SettingsTab.allSidebar) { tab in
                            navRow(tab)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)

                    Divider()
                        .overlay(SettingsTheme.hairline)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)

                    if isSearching {
                        searchResults
                            .padding(.horizontal, 8)
                    } else if hasExtra {
                        extra()
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Pinned footer — does not scroll with nav / results.
            versionFooter
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

    // MARK: - Version / update footer

    /// Default: `BirdNion 0.x.y`. When an update is available, show a
    /// clickable prompt that runs brew upgrade (macOS) / opens the release.
    @ViewBuilder
    private var versionFooter: some View {
        Group {
            if case .available(let version, _) = updater.state {
                Button {
                    updater.applyAvailableUpdate()
                } label: {
                    VStack(spacing: 2) {
                        Text(L10n.f("about.updateAvailable", settings.appLanguage, version))
                            .font(.plexMono(10, weight: .semibold))
                            .foregroundStyle(SettingsTheme.accent)
                            .multilineTextAlignment(.center)
                        Text(L10n.t("about.updateNow", settings.appLanguage))
                            .font(.plexMono(9, weight: .medium))
                            .foregroundStyle(SettingsTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L10n.t("about.updateNow", settings.appLanguage))
                .accessibilityLabel(L10n.f("about.updateAvailable", settings.appLanguage, version))
            } else {
                Text("BirdNion \(appVersion)")
                    .font(.plexMono(10))
                    .tracking(0.6)
                    .foregroundStyle(SettingsTheme.tertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .overlay(alignment: .top) {
            SettingsTheme.hairline.frame(height: 1)
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

    // MARK: - Unified search results (sidebar)

    private struct ProviderHit: Identifiable {
        let id: String
        let title: String
    }

    private struct ProfileHit: Identifiable {
        let id: String
        let title: String
    }

    private struct PageHit: Identifiable {
        let id: String
        let tab: SettingsTab
        let title: String
        let subtitle: String
    }

    private var providerHits: [ProviderHit] {
        let q = searchQuery.lowercased()
        return BirdNionConfigStore.allProviders().compactMap { row in
            let title = SettingsSearchIndex.providerTitle(id: row.id, fallback: row.displayName)
            guard SettingsSearchIndex.providerMatches(id: row.id, title: title, query: q) else { return nil }
            return ProviderHit(id: row.id, title: title)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var profileHits: [ProfileHit] {
        let q = searchQuery.lowercased()
        return BirdNionConfigStore.claudeCodeProfiles().compactMap { profile in
            let title = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title.isEmpty ? profile.id : title
            let hay = "\(label) \(profile.id) claude code codex custom profile config".lowercased()
            guard hay.contains(q) else { return nil }
            return ProfileHit(id: profile.id, title: label)
        }
    }

    private var pageHits: [PageHit] {
        let q = searchQuery.lowercased()
        let lang = settings.appLanguage
        return SettingsTab.allSidebar.compactMap { tab in
            let title = tab.title(language: lang)
            let keywords = SettingsSearchIndex.pageKeywords(tab, language: lang)
            let hay = ([title] + keywords).joined(separator: " ").lowercased()
            guard hay.contains(q) else { return nil }
            return PageHit(
                id: tab.rawValue,
                tab: tab,
                title: title,
                subtitle: L10n.t("settings.sidebar.search.page", lang))
        }
    }

    private var hasSearchHits: Bool {
        !providerHits.isEmpty || !profileHits.isEmpty || !pageHits.isEmpty
    }

    @ViewBuilder
    private var searchResults: some View {
        let lang = settings.appLanguage
        VStack(alignment: .leading, spacing: 10) {
            if !hasSearchHits {
                Text(L10n.t("settings.sidebar.search.empty", lang))
                    .font(.plexSans(11))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if !providerHits.isEmpty {
                searchSection(title: L10n.t("settings.tab.providers", lang)) {
                    ForEach(providerHits) { hit in
                        searchHitRow(
                            title: hit.title,
                            subtitle: L10n.t("settings.sidebar.search.provider", lang),
                            systemImage: "square.grid.2x2") {
                                searchText = ""
                                openProviderSettings(hit.id)
                            }
                    }
                }
            }

            if !profileHits.isEmpty {
                searchSection(title: L10n.t("settings.tab.aiCoding", lang)) {
                    ForEach(profileHits) { hit in
                        searchHitRow(
                            title: hit.title,
                            subtitle: L10n.t("settings.sidebar.search.profile", lang),
                            systemImage: "terminal") {
                                searchText = ""
                                openAICodingSettings(profileID: hit.id)
                            }
                    }
                }
            }

            if !pageHits.isEmpty {
                searchSection(title: L10n.t("settings.sidebar.search.pages", lang)) {
                    ForEach(pageHits) { hit in
                        searchHitRow(
                            title: hit.title,
                            subtitle: hit.subtitle,
                            systemImage: hit.tab.icon) {
                                searchText = ""
                                selected = hit.tab
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.plexMono(10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(SettingsTheme.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            VStack(spacing: 2) {
                content()
            }
        }
    }

    private func searchHitRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.plexSans(12, weight: .medium))
                        .foregroundStyle(SettingsTheme.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.plexSans(10))
                        .foregroundStyle(SettingsTheme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // No always-on fill — a permanent hoverSurface card read as a
            // faint square beside each hit. Match nav rows: plain until hover.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Badges

    private func badgeText(for tab: SettingsTab) -> String? {
        switch tab {
        case .actionCenter:
            let count = ActionCenterIssue.current(
                statuses: quota.displayStatuses,
                staleWarning: { quota.staleWarning(for: $0) }).count
            return count > 0 ? "\(count)" : nil
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
