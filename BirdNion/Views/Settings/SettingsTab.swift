import SwiftUI

/// Settings navigation items for the vertical sidebar (remake P2).
/// Display folded into General; Debug folded into Advanced.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, providers, aiCoding, insights, advanced, about

    var id: String { rawValue }

    func title(language: String? = nil) -> String {
        switch self {
        case .general: L10n.t("settings.tab.general", language)
        case .providers: L10n.t("settings.tab.providers", language)
        case .aiCoding: L10n.t("settings.tab.aiCoding", language)
        case .insights: L10n.t("settings.tab.insights", language)
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
        case .insights: "chart.xyaxis.line"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// All sidebar items in display order — one contiguous block; the
    /// contextual provider/AI-coding list renders below it when active.
    static let allSidebar: [SettingsTab] = [.general, .providers, .aiCoding, .insights, .advanced, .about]

    static func restored(_ raw: String?) -> SettingsTab {
        raw.flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
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
