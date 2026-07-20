import SwiftUI

/// Five Settings navigation items for the vertical sidebar (remake P2).
/// Display folded into General; Debug folded into Advanced.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, providers, aiCoding, advanced, about

    var id: String { rawValue }

    func title(language: String? = nil) -> String {
        switch self {
        case .general: L10n.t("settings.tab.general", language)
        case .providers: L10n.t("settings.tab.providers", language)
        case .aiCoding: L10n.t("settings.tab.aiCoding", language)
        case .advanced: L10n.t("settings.tab.advanced", language)
        case .about: L10n.t("settings.tab.about", language)
        }
    }

    /// SF Symbol used in the sidebar nav row.
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .aiCoding: "terminal"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// Fixed icon-tile colors from the approved remake mockup (hardcoded hex OK).
    var iconBackground: Color {
        switch self {
        case .general:
            return Color(red: 0.55, green: 0.55, blue: 0.58) // gray gear
        case .providers:
            return Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255) // #2563eb
        case .aiCoding:
            return Color(red: 0.55, green: 0.35, blue: 0.85) // purple terminal
        case .advanced:
            return Color(red: 0.55, green: 0.55, blue: 0.58) // gray sliders
        case .about:
            return Color(red: 0.20, green: 0.65, blue: 0.35) // green info
        }
    }

    /// Primary nav group (above the divider).
    static let primaryGroup: [SettingsTab] = [.general, .providers, .aiCoding]

    /// Secondary nav group (below the divider).
    static let secondaryGroup: [SettingsTab] = [.advanced, .about]

    /// All sidebar items in display order.
    static let allSidebar: [SettingsTab] = primaryGroup + secondaryGroup
}

/// The coding CLI that consumes a custom upstream configuration. Profiles keep
/// agent-specific model and output-file settings, while the target picker can
/// carry their shared upstream credentials to the other CLI on demand.
enum AICodingAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    func title(language: String? = nil) -> String {
        switch self {
        case .claudeCode: L10n.t("aiCoding.agent.claudeCode", language)
        case .codex: L10n.t("aiCoding.agent.codex", language)
        }
    }
}
