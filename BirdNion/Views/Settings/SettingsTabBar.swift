import SwiftUI

/// Vertical settings sidebar: search filters nav titles, colored icon tiles,
/// optional badges, group divider, and version footer. Replaces the former
/// horizontal `SettingsTabBar` (remake P2; file name kept for pbxproj stability).
struct SettingsSidebar: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService

    @Binding var selected: SettingsTab

    @State private var searchText = ""
    @State private var providersWithKey = 0
    @State private var activeAgentCount = 0
    @State private var hovering: SettingsTab?

    private var filteredPrimary: [SettingsTab] {
        filter(SettingsTab.primaryGroup)
    }

    private var filteredSecondary: [SettingsTab] {
        filter(SettingsTab.secondaryGroup)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredPrimary) { tab in
                        navRow(tab)
                    }

                    if !filteredPrimary.isEmpty && !filteredSecondary.isEmpty {
                        Divider()
                            .overlay(SettingsTheme.border)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                    }

                    ForEach(filteredSecondary) { tab in
                        navRow(tab)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Text("BirdNion \(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SettingsTheme.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsTheme.border.opacity(0.8), lineWidth: 1)
        )
    }

    // MARK: - Nav row

    private func navRow(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selected
        let isHovering = hovering == tab
        let badge = badgeText(for: tab)

        return Button {
            selected = tab
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected
                              ? Color.white.opacity(0.22)
                              : tab.iconBackground)
                        .frame(width: 22, height: 22)
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.white)
                }

                Text(tab.title(language: settings.appLanguage))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : SettingsTheme.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.95) : SettingsTheme.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected
                                      ? Color.white.opacity(0.22)
                                      : SettingsTheme.successSurface)
                        )
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? SettingsTheme.accent
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
