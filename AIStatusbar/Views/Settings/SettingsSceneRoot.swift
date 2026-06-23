import SwiftUI

/// Root view rendered by SwiftUI's `Settings` scene. Hosts the custom tab bar
/// on top + a scrollable content pane. When `debugMenuEnabled` toggles, the
/// tab list rebuilds — keeping `selected` pointing at a hidden tab falls back
/// to `.general`.
struct SettingsSceneRoot: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var keychain: KeychainService
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService

    @State private var selected: SettingsTab = .general

    private var visibleTabs: [SettingsTab] { SettingsTab.visible(settings: settings) }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selected: $selected, tabs: visibleTabs)
            Divider()

            Group {
                switch selected {
                case .general: GeneralPane()
                case .providers: ProvidersPane()
                case .display: DisplayPane()
                case .advanced: AdvancedPane()
                case .about: AboutPane()
                case .debug: DebugPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Use ideal-only sizing so AppKit doesn't force a re-layout every
        // pass. The original .frame(width:height:) and the .frame(minWidth:
        // minHeight:) variants both triggered an NSISEngine recursion loop
        // because updateAnimatedWindowSize kept retriggering windowDidLayout.
        .frame(idealWidth: 546, idealHeight: 620)
        .onAppear {
            if !visibleTabs.contains(selected) { selected = .general }
        }
        .onChange(of: settings.debugMenuEnabled) { _ in
            if !visibleTabs.contains(selected) { selected = .general }
        }
    }
}

/// Bold uppercase section header used inside `Form(.grouped)` panes — matches
/// the SYSTEM / USAGE / AUTOMATION style in the CodexBar mockup.
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }
}

/// Title + optional subtitle + trailing control, used inside each `Form` row.
struct SettingsLabeledRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
                .font(.system(size: 12))
        }
        .padding(.vertical, 2)
    }
}
