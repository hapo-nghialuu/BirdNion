import AppKit
import SwiftUI

/// Semantic Settings palette (aliases onto VocabbyTheme light/dark tokens).
enum SettingsTheme {
    static let background = VocabbyTheme.background
    static let toolbar = VocabbyTheme.segment
    static let card = VocabbyTheme.card
    static let control = VocabbyTheme.group
    static let selectedSurface = VocabbyTheme.selectedSurface
    static let hoverSurface = VocabbyTheme.hoverSurface
    static let border = VocabbyTheme.border
    static let track = VocabbyTheme.track
    static let primary = VocabbyTheme.primary
    static let secondary = VocabbyTheme.secondary
    static let tertiary = VocabbyTheme.tertiary
    static let accent = VocabbyTheme.blue
    static let success = VocabbyTheme.success
    static let successSurface = VocabbyTheme.successSurface
    static let warning = VocabbyTheme.yellow
    static let warningFill = VocabbyTheme.warningFill
    static let warningSurface = VocabbyTheme.warningSurface
    static let critical = VocabbyTheme.critical
    static let criticalSurface = VocabbyTheme.criticalSurface
    static let disabled = VocabbyTheme.disabled
    static let hairline = VocabbyTheme.hairline
    static let inkRule = VocabbyTheme.inkRule

    static func quotaColor(remaining: Int) -> Color {
        VocabbyTheme.quotaColor(remaining: remaining)
    }

    static func quotaFillColor(remaining: Int) -> Color {
        VocabbyTheme.quotaFillColor(remaining: remaining)
    }

    static func usedFillColor(usedPercent: Int) -> Color {
        VocabbyTheme.usedFillColor(usedPercent: usedPercent)
    }
}

/// Root view rendered inside AppDelegate's settings NSWindow. Hosts the vertical
/// sidebar on the left + a scrollable content pane on the right (remake P2).
struct SettingsSceneRoot: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService

    @State private var selected = SettingsTab.restored(
        UserDefaults.standard.string(forKey: "birdnion.settingsSection"))
    /// One Settings-wide search (nav + contextual roster). Owned here so
    /// Providers/AI Coding don't mount a second search field.
    @State private var sidebarSearch = ""

    /// One constant window size for all tabs — wide enough for the providers
    /// sidebar + detail, still fine for the single-column tabs. This MUST stay
    /// constant: the `Settings` scene has no `.windowResizability(.contentSize)`,
    /// because a window that re-fits its content on every re-render (e.g. each
    /// QuotaService publish) drives NSHostingView's autoresizing constraints
    /// into an NSISEngine recursion that crashes the whole app.
    private let contentWidth: CGFloat = 920
    private let contentHeight: CGFloat = 620

    var body: some View {
        Group {
            switch selected {
            // Providers / AI Coding render the whole row themselves: their
            // roster list lives inside the sidebar column (below the nav),
            // so the pane owns both the embedded list state and the detail.
            case .providers: ProvidersPane(tab: $selected, searchText: $sidebarSearch)
            case .aiCoding: AICodingPane(tab: $selected, searchText: $sidebarSearch)
            case .insights: navAndContent { InsightsPane() }
            case .general: navAndContent { GeneralPane() }
            case .advanced: navAndContent { AdvancedPane() }
            case .about: navAndContent { AboutPane() }
            }
        }
        .frame(width: contentWidth, height: contentHeight)
        // Opaque backing so AppKit always has something to clear to.
        .background(SettingsTheme.background)
        .overlay(SettingsWindowAppearanceView().frame(width: 0, height: 0))
        .tint(SettingsTheme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openClaudeCodeTab)) { _ in
            selected = .aiCoding
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProvidersTab)) { _ in
            selected = .providers
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInsightsTab)) { _ in
            selected = .insights
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSetup)) { _ in
            UserDefaults.standard.set("providers", forKey: "birdnion.settingsSection")
            selected = .providers
        }
        .onChange(of: selected) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: "birdnion.settingsSection")
        }
    }

    /// Standard row for single-column tabs: nav-only sidebar + content pane.
    private func navAndContent<Pane: View>(@ViewBuilder _ pane: () -> Pane) -> some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $selected, searchText: $sidebarSearch)
            pane()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension Notification.Name {
    /// Kept for existing quick-apply callers; the route now opens AI Coding.
    static let openClaudeCodeTab = Notification.Name("birdnion.openClaudeCodeTab")
    static let openProviderSetup = Notification.Name("birdnion.openProviderSetup")
    static let openInsightsTab = Notification.Name("birdnion.openInsightsTab")
}

@MainActor
func openInsightsSettings(segment: InsightsSegment = .overview) {
    UserDefaults.standard.set(SettingsTab.insights.rawValue, forKey: "birdnion.settingsSection")
    UserDefaults.standard.set(segment.rawValue, forKey: InsightsSegment.defaultsKey)
    NotificationCenter.default.post(name: .openInsightsTab, object: nil)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

@MainActor
func openProviderSettings(_ id: String) {
    UserDefaults.standard.set("providers", forKey: "birdnion.settingsSection")
    UserDefaults.standard.set(id, forKey: "birdnion.selectedProvider")
    NotificationCenter.default.post(name: .openProviderSetup, object: id)
    NotificationCenter.default.post(name: .openSettings, object: nil)
}

private struct SettingsWindowAppearanceView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        // Appearance is app-wide (SettingsStore.applyAppearance); here we only
        // keep the window background matched to Instrument paper/ink so
        // AppKit clears to the right color during live resize in both modes.
        window.appearance = nil
        // VocabbyTheme.background: light #FBFAF7 / dark #17170F
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 15 / 255, alpha: 1)
                : NSColor(srgbRed: 251 / 255, green: 250 / 255, blue: 247 / 255, alpha: 1)
        }
    }
}

// MARK: - Instrument layout primitives
//
// Avoid SwiftUI's `Form(.grouped)` — inside our NSWindow it can drive
// NSISEngine recursion. These plain containers mirror the Linux instrument
// Settings CSS (`.settings-page` / `.sw-card` transparent / `.sw-row`
// hairline-top) so macOS Settings matches the popover redesign language.

/// Scrollable settings page — stack of section groups on paper background.
struct SettingsPage<Content: View>: View {
    var maxContentWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 30)
            .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: maxContentWidth == nil ? .leading : .top)
        }
        .background(SettingsTheme.background)
    }
}

/// Section group: uppercase eyebrow + hairline-divided rows (no filled card).
/// Rows supply their own top hairline via `SettingsLabeledRow` /
/// `SettingsRowDivider` no longer draws a second rule.
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                SettingsSectionHeader(title: header)
            }
            VStack(spacing: 0) { content() }
            if let footer {
                Text(footer)
                    .font(.plexSans(12))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.top, 10)
            }
        }
    }
}

/// Legacy separator between rows. Instrument rows already draw a top hairline
/// on `SettingsLabeledRow`, so this is a no-op kept for call-site compatibility.
struct SettingsRowDivider: View {
    var body: some View { EmptyView() }
}

// MARK: - Shared row views

/// Pane title + optional subtitle, underlined by the strong ink rule.
struct SettingsPaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.plexSans(22, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(SettingsTheme.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.plexSans(13))
                    .foregroundStyle(SettingsTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .inkRuleBottom()
        .padding(.bottom, 4)
    }
}

/// Uppercase mono eyebrow above each settings group (HỆ THỐNG / SỬ DỤNG / …).
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .plexEyebrow()
            .padding(.top, 22)
            .padding(.bottom, 4)
    }
}

/// Title + optional subtitle + trailing control. Top hairline replaces the
/// old card-internal divider (Linux `.sw-row { border-top: hairline }`).
struct SettingsLabeledRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.plexSans(14, weight: .medium))
                    .foregroundStyle(SettingsTheme.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.plexSans(12))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
                .font(.plexSans(12))
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hairlineTop(SettingsTheme.hairline)
    }
}
