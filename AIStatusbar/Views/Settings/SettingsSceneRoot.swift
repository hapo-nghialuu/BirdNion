import SwiftUI

/// Root view rendered inside AppDelegate's settings NSWindow. Hosts the custom
/// tab bar on top + a scrollable content pane. When `debugMenuEnabled` toggles,
/// the tab list rebuilds — keeping `selected` pointing at a hidden tab falls
/// back to `.general`.
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
        // Fixed size matching AppDelegate's settings NSWindow content size.
        // This is load-bearing: a flexible (.infinity) frame lets the
        // NSHostingView think its fitting size changes on every re-render
        // (e.g. when QuotaService publishes), which calls
        // invalidateSizeConstraintsIfNecessary during the display cycle and
        // makes AppKit throw in _postWindowNeedsUpdateConstraints. A constant
        // size makes that invalidation a no-op. Content scrolls inside.
        .frame(width: 546, height: 620)
        // Opaque backing so AppKit always has something to clear to.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !visibleTabs.contains(selected) { selected = .general }
        }
        .onChange(of: settings.debugMenuEnabled) { _ in
            if !visibleTabs.contains(selected) { selected = .general }
        }
    }
}

// MARK: - Card-based layout primitives
//
// We deliberately avoid SwiftUI's `Form(.grouped)`: hosted inside our
// manually-created NSWindow it drives NSISEngine into infinite recursion on
// re-layout (autoresizing-mask constraints fight the grouped layout). These
// plain-SwiftUI containers reproduce the inset "card" look without touching
// AppKit's constraint engine.

/// Scrollable settings page — a vertical stack of `SettingsCard`s on the
/// window background. Use in place of `Form` at the root of each pane.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One titled card group: uppercase header, rounded card body, optional footer.
/// Use in place of `Section { … } header: { … } footer: { … }`.
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                SettingsSectionHeader(title: header)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Thin inset divider between rows inside a `SettingsCard`.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

// MARK: - Shared row views

/// Bold uppercase section header shown above each `SettingsCard` — matches the
/// SYSTEM / USAGE / AUTOMATION style in the CodexBar mockup.
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }
}

/// Title + optional subtitle + trailing control. Self-contained padding so it
/// sits correctly as a row inside a `SettingsCard`.
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
