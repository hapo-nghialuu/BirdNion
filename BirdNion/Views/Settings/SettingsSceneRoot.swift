import AppKit
import SwiftUI

/// Fixed light palette for the Settings window. The app lives in the menu bar,
/// so the settings surface should stay close to the popover instead of
/// inheriting a full black dark-mode appearance from macOS.
enum SettingsTheme {
    static let background = Color(red: 0.949, green: 0.949, blue: 0.953)
    static let toolbar = Color(red: 0.925, green: 0.925, blue: 0.933)
    static let card = Color(red: 0.992, green: 0.992, blue: 0.996)
    static let control = Color(red: 0.969, green: 0.969, blue: 0.976)
    static let selectedSurface = Color(red: 0.910, green: 0.949, blue: 1.000)
    static let hoverSurface = Color(red: 0.910, green: 0.910, blue: 0.922)
    static let border = Color(red: 0.820, green: 0.820, blue: 0.840)
    static let track = Color(red: 0.898, green: 0.898, blue: 0.918)
    static let primary = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let secondary = Color(red: 0.431, green: 0.431, blue: 0.451)
    static let tertiary = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.000)
    static let success = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let warning = Color(red: 1.000, green: 0.624, blue: 0.039)
    static let critical = Color(red: 1.000, green: 0.271, blue: 0.227)
    static let disabled = Color(red: 0.650, green: 0.650, blue: 0.670)

    static func quotaColor(remaining: Int) -> Color {
        switch remaining {
        case 0..<30: return warning
        default: return success
        }
    }
}

/// Root view rendered inside AppDelegate's settings NSWindow. Hosts the custom
/// tab bar on top + a scrollable content pane. When `debugMenuEnabled` toggles,
/// the tab list rebuilds — keeping `selected` pointing at a hidden tab falls
/// back to `.general`.
struct SettingsSceneRoot: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var config: ConfigService
    @EnvironmentObject var quota: QuotaService

    @State private var selected: SettingsTab = .general

    private var visibleTabs: [SettingsTab] { SettingsTab.visible(settings: settings) }

    /// One constant window size for all tabs — wide enough for the providers
    /// sidebar + detail, still fine for the single-column tabs. This MUST stay
    /// constant: the `Settings` scene has no `.windowResizability(.contentSize)`,
    /// because a window that re-fits its content on every re-render (e.g. each
    /// QuotaService publish) drives NSHostingView's autoresizing constraints
    /// into an NSISEngine recursion that crashes the whole app.
    private let contentWidth: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selected: $selected, tabs: visibleTabs)
            Divider()
                .overlay(SettingsTheme.border)

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
        .frame(width: contentWidth, height: 620)
        // Opaque backing so AppKit always has something to clear to.
        .background(SettingsTheme.background)
        .overlay(SettingsWindowAppearanceView().frame(width: 0, height: 0))
        .tint(SettingsTheme.accent)
        .preferredColorScheme(.light)
        .onAppear {
            if !visibleTabs.contains(selected) { selected = .general }
        }
        .onChange(of: settings.debugMenuEnabled) { _ in
            if !visibleTabs.contains(selected) { selected = .general }
        }
    }
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
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(
            calibratedRed: 0.949,
            green: 0.949,
            blue: 0.953,
            alpha: 1
        )
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
        .background(SettingsTheme.background)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsTheme.border.opacity(0.75), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Thin inset divider between rows inside a `SettingsCard`.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .overlay(SettingsTheme.border.opacity(0.72))
            .padding(.leading, 14)
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
            .foregroundStyle(SettingsTheme.secondary)
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
                    .foregroundStyle(SettingsTheme.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.secondary)
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
