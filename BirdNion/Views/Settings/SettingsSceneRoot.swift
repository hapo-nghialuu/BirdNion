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

    @State private var selected: SettingsTab = .general

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
            case .providers: ProvidersPane(tab: $selected)
            case .aiCoding: AICodingPane(tab: $selected)
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
    }

    /// Standard row for single-column tabs: nav-only sidebar + content pane.
    private func navAndContent<Pane: View>(@ViewBuilder _ pane: () -> Pane) -> some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $selected)
            pane()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension Notification.Name {
    /// Kept for existing quick-apply callers; the route now opens AI Coding.
    static let openClaudeCodeTab = Notification.Name("birdnion.openClaudeCodeTab")
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
        // keep the window background matched to the theme's base surface so
        // AppKit clears to the right color during live resize in both modes.
        window.appearance = nil
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1)
                : NSColor(srgbRed: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
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
    var maxContentWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: maxContentWidth == nil ? .leading : .top)
        }
        .background(SettingsTheme.background)
    }
}

/// One titled card group: uppercase eyebrow header, hairline-divided body
/// (no filled/rounded card surface — Instrument redesign), optional footer.
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
                .hairlineTop(SettingsTheme.hairline)
            if let footer {
                Text(footer)
                    .font(.plexSans(11))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Thin divider between rows inside a `SettingsCard` — a plain hairline,
/// full-width (no leading inset/card padding).
struct SettingsRowDivider: View {
    var body: some View {
        HairlineRule(color: SettingsTheme.hairline)
    }
}

// MARK: - Shared row views

/// Pane-level title + optional subtitle (mockup: "Chung" / "Nâng cao" / …),
/// underlined by the strong ink rule that replaces the old card container.
struct SettingsPaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.plexSans(17, weight: .bold))
                .foregroundStyle(SettingsTheme.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.plexSans(12))
                    .foregroundStyle(SettingsTheme.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 14)
        .inkRuleBottom()
    }
}

/// Uppercase mono eyebrow header shown above each `SettingsCard` — matches the
/// HỆ THỐNG / SỬ DỤNG / TỰ ĐỘNG style in the Instrument mockup.
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .plexEyebrow()
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
                    .font(.plexSans(13))
                    .foregroundStyle(SettingsTheme.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.plexSans(11))
                        .foregroundStyle(SettingsTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
                .font(.plexSans(12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
