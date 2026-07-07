import KeyboardShortcuts
import SwiftUI

/// General settings: language, launch at login, refresh cadence, status/notification toggles.
/// Mirrors the three grouped sections in the CodexBar mockup: Hệ thống /
/// Sử dụng / Tự động.
struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(header: L10n.t("settings.section.system", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("settings.language.title", settings.appLanguage),
                    subtitle: L10n.t("settings.language.subtitle", settings.appLanguage)
                ) {
                    Picker("", selection: $settings.appLanguage) {
                        ForEach(SettingsStore.Language.allCases) { lang in
                            Text(lang.displayName(language: settings.appLanguage)).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .onChange(of: settings.appLanguage) { _ in
                        settings.applyLanguage()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.launchAtLogin.title", settings.appLanguage),
                    subtitle: L10n.t("settings.launchAtLogin.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: settings.launchAtLogin) { _ in
                            settings.applyLaunchAtLogin()
                        }
                }
            }

            SettingsCard(
                header: L10n.t("settings.section.usage", settings.appLanguage),
                footer: settings.refreshIntervalSeconds <= 0
                    ? LocalizedStringKey(L10n.t("settings.manualRefreshHint", settings.appLanguage))
                    : nil
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.refreshFrequency.title", settings.appLanguage),
                    subtitle: L10n.t("settings.refreshFrequency.subtitle", settings.appLanguage)
                ) {
                    Picker("", selection: $settings.refreshIntervalSeconds) {
                        ForEach(SettingsStore.RefreshFrequency.allCases) { f in
                            Text(f.displayName(language: settings.appLanguage)).tag(f.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .onChange(of: settings.refreshIntervalSeconds) { _ in
                        settings.pushRefreshInterval()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.refreshOnOpen.title", settings.appLanguage),
                    subtitle: L10n.t("settings.refreshOnOpen.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.refreshOnMenuOpen).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(header: L10n.t("settings.section.automation", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("settings.statusChecks.title", settings.appLanguage),
                    subtitle: L10n.t("settings.statusChecks.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.statusChecksEnabled).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.sessionNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.sessionNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.sessionQuotaNotificationsEnabled).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.quotaWarningNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.quotaWarningNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.quotaWarningNotificationsEnabled).labelsHidden().toggleStyle(.switch)
                }

                if settings.quotaWarningNotificationsEnabled {
                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningThreshold.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningThreshold.subtitle", settings.appLanguage)
                    ) {
                        Stepper(value: $settings.quotaWarnLevel1, in: 5...95, step: 5) {
                            Text("\(settings.quotaWarnLevel1)%")
                                .font(.system(size: 12).monospacedDigit())
                        }
                        .fixedSize()
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.criticalThreshold.title", settings.appLanguage),
                        subtitle: L10n.t("settings.criticalThreshold.subtitle", settings.appLanguage)
                    ) {
                        Stepper(value: $settings.quotaWarnLevel2, in: 1...90, step: 5) {
                            Text("\(settings.quotaWarnLevel2)%")
                                .font(.system(size: 12).monospacedDigit())
                        }
                        .fixedSize()
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningSound.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningSound.subtitle", settings.appLanguage)
                    ) {
                        Toggle("", isOn: $settings.quotaWarningSoundEnabled).labelsHidden().toggleStyle(.switch)
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningAlert.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningAlert.subtitle", settings.appLanguage)
                    ) {
                        Toggle("", isOn: $settings.quotaWarningOnScreenAlertEnabled).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsCard(header: L10n.t("settings.section.shortcut", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("settings.hotkey.title", settings.appLanguage),
                    subtitle: L10n.t("settings.hotkey.subtitle", settings.appLanguage)
                ) {
                    OpenPopoverShortcutRecorder()
                        .frame(width: 160)
                }
            }

            SettingsCard {
                HStack {
                    Spacer()
                    Button(L10n.t("settings.quitApp", settings.appLanguage)) {
                        NSApp.terminate(nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}

/// Global-hotkey recorder for the "open popover" shortcut. Wraps the
/// KeyboardShortcuts Cocoa recorder — the SwiftUI `Recorder` view needs the
/// package's own localization bundle context, and the Cocoa one matches
/// CodexBar's usage (`OpenMenuShortcutRecorder`).
private struct OpenPopoverShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: .openPopover)
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
        nsView.shortcutName = .openPopover
    }
}
