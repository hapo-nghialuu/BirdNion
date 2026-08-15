import AppKit
import SwiftUI

/// Advanced settings: privacy, developer toggles, and an inline Debug section
/// (Display/Debug tabs folded in at remake P2).
struct AdvancedPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsPaneHeader(
                title: L10n.t("settings.tab.advanced", settings.appLanguage),
                subtitle: L10n.t("settings.advanced.subtitle", settings.appLanguage)
            )

            // Existing groups only (mockup DỮ LIỆU/CẬP NHẬT rows that do not
            // exist here — clear quota, update channel — are intentionally omitted).
            // Instrument redesign: hairline-divided section in place of the
            // old filled/rounded SettingsCard container.
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings.section.privacy", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.bottom, 4)

                SettingsLabeledRow(
                    title: L10n.t("settings.hidePersonalInfo.title", settings.appLanguage),
                    subtitle: L10n.t("settings.hidePersonalInfo.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.hidePersonalInfo).labelsHidden().toggleStyle(.instrument)
                }
                .hairlineTop()
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings.section.developer", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.bottom, 4)

                SettingsLabeledRow(
                    title: L10n.t("settings.disableKeychain.title", settings.appLanguage),
                    subtitle: L10n.t("settings.disableKeychain.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.debugDisableKeychainAccess).labelsHidden().toggleStyle(.instrument)
                }
                .hairlineTop()

                SettingsLabeledRow(
                    title: L10n.t("settings.storageFootprint.title", settings.appLanguage),
                    subtitle: L10n.t("settings.storageFootprint.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.providerStorageFootprintsEnabled).labelsHidden().toggleStyle(.instrument)
                }
                .hairlineTop()

                Text(LocalizedStringKey(L10n.t("settings.developer.footer", settings.appLanguage)))
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }

            // DEBUG section (formerly its own tab; content expands when enabled).
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings.tab.debug", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.bottom, 4)

                SettingsLabeledRow(
                    title: L10n.t("settings.tab.debug", settings.appLanguage),
                    subtitle: L10n.t("settings.debug.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.debugMenuEnabled).labelsHidden().toggleStyle(.instrument)
                }
                .hairlineTop()

                if settings.debugMenuEnabled {
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
                    .hairlineTop()

                    Text(LocalizedStringKey(L10n.t("settings.debug.footer", settings.appLanguage)))
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, 10)
                }
            }
        }
    }
}
