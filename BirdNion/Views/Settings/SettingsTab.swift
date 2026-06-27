import SwiftUI

/// Six Settings tabs matching the CodexBar toolbar. Debug is hidden until
/// "Show Debug Settings" is enabled (mirrors CodexBar's debugMenuEnabled).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, providers, display, advanced, about, debug

    var id: String { rawValue }

    func title(language: String? = nil) -> String {
        switch self {
        case .general: L10n.t("settings.tab.general", language)
        case .providers: L10n.t("settings.tab.providers", language)
        case .display: L10n.t("settings.tab.display", language)
        case .advanced: L10n.t("settings.tab.advanced", language)
        case .about: L10n.t("settings.tab.about", language)
        case .debug: L10n.t("settings.tab.debug", language)
        }
    }

    /// SF Symbol used in the custom tab bar. Matches the CodexBar mockup.
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .display: "eye"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        case .debug: "ladybug"
        }
    }

    /// Tabs to show given the current SettingsStore. Debug is gated.
    @MainActor static func visible(settings: SettingsStore) -> [SettingsTab] {
        var tabs: [SettingsTab] = [.general, .providers, .display, .advanced, .about]
        if settings.debugMenuEnabled { tabs.append(.debug) }
        return tabs
    }
}
