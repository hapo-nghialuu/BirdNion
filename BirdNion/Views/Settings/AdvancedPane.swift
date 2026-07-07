import SwiftUI

/// Advanced settings: privacy + a debug toggle. The debug toggle gates the
/// Debug tab in the tab bar.
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
                    title: L10n.t("settings.debugMenu.title", settings.appLanguage),
                    subtitle: L10n.t("settings.debugMenu.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.debugMenuEnabled).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

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
        }
    }
}
