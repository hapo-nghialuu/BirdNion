import SwiftUI

/// Display settings: how icons are merged/rotated in the menu bar.
/// Today the renderer always uses a single bird icon — these settings are
/// persisted but have no visual effect yet (YAGNI wiring).
struct DisplayPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(
                header: L10n.t("settings.section.menuBar", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.display.footer", settings.appLanguage))
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.mergeIcons.title", settings.appLanguage),
                    subtitle: L10n.t("settings.mergeIcons.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.mergeIcons).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.switcherShowsIcons.title", settings.appLanguage),
                    subtitle: settings.mergeIcons
                        ? L10n.t("settings.switcherShowsIcons.subtitle.on", settings.appLanguage)
                        : L10n.t("settings.switcherShowsIcons.subtitle.off", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.switcherShowsIcons)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!settings.mergeIcons)
                }
            }
        }
    }
}
