import AppKit
import SwiftUI

/// Advanced settings: privacy, developer toggles, and an inline Debug section
/// (Display/Debug tabs folded in at remake P2).
struct AdvancedPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(header: L10n.t("settings.section.privacy", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("settings.hidePersonalInfo.title", settings.appLanguage),
                    subtitle: L10n.t("settings.hidePersonalInfo.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.hidePersonalInfo).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                header: L10n.t("settings.section.developer", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.developer.footer", settings.appLanguage))
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.disableKeychain.title", settings.appLanguage),
                    subtitle: L10n.t("settings.disableKeychain.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.debugDisableKeychainAccess).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.storageFootprint.title", settings.appLanguage),
                    subtitle: L10n.t("settings.storageFootprint.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.providerStorageFootprintsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }

            // DEBUG section (formerly its own tab; content expands when enabled).
            SettingsCard(
                header: L10n.t("settings.tab.debug", settings.appLanguage),
                footer: settings.debugMenuEnabled
                    ? LocalizedStringKey(L10n.t("settings.debug.footer", settings.appLanguage))
                    : nil
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.tab.debug", settings.appLanguage),
                    subtitle: L10n.t("settings.debug.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.debugMenuEnabled).labelsHidden().toggleStyle(.switch)
                }

                if settings.debugMenuEnabled {
                    SettingsRowDivider()

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
                        .pointingHandCursor()
                    }
                }
            }
        }
    }
}
