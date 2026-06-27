import SwiftUI
import AppKit

/// Debug pane. Kept intentionally small — the real diagnostic tools live in
/// CodexBar's full DebugPane (probe logs, fetch strategy, error simulation,
/// caches). This implementation gives BOSS a couple of useful shortcuts:
/// open the config directory and reveal the settings file in Finder.
struct DebugPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(
                header: L10n.t("settings.section.files", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.debug.footer", settings.appLanguage))
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.configFile.title", settings.appLanguage),
                    subtitle: BirdNionConfigStore.configURL().path
                ) {
                    Button(L10n.t("settings.openFinder", settings.appLanguage)) {
                        let url = BirdNionConfigStore.configURL()
                        // Ensure the parent directory exists so Finder shows
                        // the right folder even on a fresh install.
                        try? FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
