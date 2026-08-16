import KeyboardShortcuts
import SwiftUI

/// General settings: language, launch at login, refresh cadence, status/notification toggles.
/// Mirrors the three grouped sections in the CodexBar mockup: Hệ thống /
/// Sử dụng / Tự động.
struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsPaneHeader(
                title: L10n.t("settings.tab.general", settings.appLanguage),
                subtitle: L10n.t("settings.general.subtitle", settings.appLanguage)
            )

            SettingsCard(
                header: L10n.t("settings.section.system", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.display.footer", settings.appLanguage))
            ) {
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
                    title: L10n.t("settings.appearance.title", settings.appLanguage),
                    subtitle: L10n.t("settings.appearance.subtitle", settings.appLanguage)
                ) {
                    Picker("", selection: $settings.appAppearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title(language: settings.appLanguage)).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: settings.appAppearance) { _ in
                        settings.applyAppearance()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.showPercentInMenuBar.title", settings.appLanguage),
                    subtitle: L10n.t("settings.showPercentInMenuBar.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: settings.showPercentInMenuBarBinding)
                        .labelsHidden()
                        .toggleStyle(.instrument)
                        .accessibilityLabel(L10n.t("settings.showPercentInMenuBar.title", settings.appLanguage))
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.launchAtLogin.title", settings.appLanguage),
                    subtitle: L10n.t("settings.launchAtLogin.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.instrument)
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
                    Toggle("", isOn: $settings.refreshOnMenuOpen).labelsHidden().toggleStyle(.instrument)
                }
            }

            SettingsCard(
                header: L10n.t("settings.section.budget", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.monthlyBudget.subtitle", settings.appLanguage))
            ) {
                SettingsLabeledRow(
                    title: L10n.t("settings.monthlyBudget.title", settings.appLanguage)
                ) {
                    TextField("∞", text: Binding(
                        get: {
                            // Plain `String(_:)` (mirrors the Bedrock budget
                            // field below) instead of a fixed-decimal format —
                            // reformatting on every keystroke fights the
                            // user's typing and jumps the cursor.
                            settings.monthlyBudgetUSD > 0 ? String(settings.monthlyBudgetUSD) : ""
                        },
                        set: { raw in
                            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                            // Blank, unparsable, non-finite (NaN/Infinity —
                            // `Double("inf")`/`Double("nan")` both parse
                            // successfully), or non-positive all normalize to
                            // 0 ("not configured") — never persisted as-is.
                            guard let parsed = Double(trimmed), parsed.isFinite, parsed > 0 else {
                                settings.monthlyBudgetUSD = 0
                                return
                            }
                            settings.monthlyBudgetUSD = parsed
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                }
            }

            SettingsCard(
                header: L10n.t("budget.perProvider.title", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.perProviderBudget.subtitle", settings.appLanguage))
            ) {
                perProviderBudgetRow(
                    title: L10n.t("settings.claudeBudget.title", settings.appLanguage),
                    value: $settings.claudeMonthlyBudgetUSD)
                SettingsRowDivider()
                perProviderBudgetRow(
                    title: L10n.t("settings.codexBudget.title", settings.appLanguage),
                    value: $settings.codexMonthlyBudgetUSD)
                SettingsRowDivider()
                perProviderBudgetRow(
                    title: L10n.t("settings.grokBudget.title", settings.appLanguage),
                    value: $settings.grokMonthlyBudgetUSD)
            }

            SettingsCard(header: L10n.t("settings.section.notifications", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("settings.statusChecks.title", settings.appLanguage),
                    subtitle: L10n.t("settings.statusChecks.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.statusChecksEnabled).labelsHidden().toggleStyle(.instrument)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.sessionNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.sessionNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.sessionQuotaNotificationsEnabled).labelsHidden().toggleStyle(.instrument)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.providerFailureNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.providerFailureNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.providerFailureNotificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrument)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.quotaWarningNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.quotaWarningNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.quotaWarningNotificationsEnabled).labelsHidden().toggleStyle(.instrument)
                }

                if settings.quotaWarningNotificationsEnabled {
                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningThreshold.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningThreshold.subtitle", settings.appLanguage)
                    ) {
                        Stepper(value: $settings.quotaWarnLevel1, in: 5...95, step: 5) {
                            Text("\(settings.quotaWarnLevel1)%")
                                .font(.plexMono(12))
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
                                .font(.plexMono(12))
                        }
                        .fixedSize()
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningSound.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningSound.subtitle", settings.appLanguage)
                    ) {
                        Toggle("", isOn: $settings.quotaWarningSoundEnabled).labelsHidden().toggleStyle(.instrument)
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningAlert.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningAlert.subtitle", settings.appLanguage)
                    ) {
                        Toggle("", isOn: $settings.quotaWarningOnScreenAlertEnabled).labelsHidden().toggleStyle(.instrument)
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.weeklyDigest.title", settings.appLanguage),
                    subtitle: L10n.t("settings.weeklyDigest.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.weeklyDigestEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrument)
                        .onChange(of: settings.weeklyDigestEnabled) { enabled in
                            if enabled { WeeklyDigest.lastEvaluatedAt = nil }
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

            HStack {
                Spacer()
                Button(L10n.t("settings.quitApp", settings.appLanguage)) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.instrumentCritical)
            }
            .padding(.top, 18)
            .hairlineTop(SettingsTheme.hairline)
        }
    }

    /// One per-provider budget field — same blank/invalid/non-positive →
    /// "off" (0) normalization as the total budget field above, factored out
    /// so the three Claude/Codex/Grok rows share one validation path.
    private func perProviderBudgetRow(title: String, value: Binding<Double>) -> some View {
        SettingsLabeledRow(title: title) {
            TextField("∞", text: Binding(
                get: { value.wrappedValue > 0 ? String(value.wrappedValue) : "" },
                set: { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    guard let parsed = Double(trimmed), parsed.isFinite, parsed > 0 else {
                        value.wrappedValue = 0
                        return
                    }
                    value.wrappedValue = parsed
                }
            ))
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
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
