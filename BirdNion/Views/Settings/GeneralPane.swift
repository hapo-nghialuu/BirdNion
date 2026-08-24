import KeyboardShortcuts
import SwiftUI

/// General settings: language, launch at login, refresh cadence, status/notification toggles.
/// Mirrors the three grouped sections in the CodexBar mockup: Hệ thống /
/// Sử dụng / Tự động.
struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quota: QuotaService

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
                    title: L10n.t("settings.appearance.title", settings.appLanguage),
                    subtitle: L10n.t("settings.appearance.subtitle", settings.appLanguage)
                ) {
                    InstrumentMenuSelect(
                        options: AppAppearance.allCases.map {
                            ($0.rawValue, $0.title(language: settings.appLanguage))
                        },
                        selection: $settings.appAppearance)
                    .onChange(of: settings.appAppearance) { _ in
                        settings.applyAppearance()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.language.title", settings.appLanguage),
                    subtitle: L10n.t("settings.language.subtitle", settings.appLanguage)
                ) {
                    InstrumentMenuSelect(
                        options: SettingsStore.Language.allCases.map {
                            ($0.rawValue, $0.displayName(language: settings.appLanguage))
                        },
                        selection: $settings.appLanguage)
                    .onChange(of: settings.appLanguage) { _ in
                        settings.applyLanguage()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.showPercentInMenuBar.title", settings.appLanguage),
                    subtitle: L10n.t("settings.showPercentInMenuBar.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: settings.showPercentInMenuBarBinding)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                        .accessibilityLabel(L10n.t("settings.showPercentInMenuBar.title", settings.appLanguage))
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.launchAtLogin.title", settings.appLanguage),
                    subtitle: L10n.t("settings.launchAtLogin.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
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
                    InstrumentMenuSelect(
                        options: SettingsStore.RefreshFrequency.allCases.map {
                            ($0.rawValue, $0.displayName(language: settings.appLanguage))
                        },
                        selection: $settings.refreshIntervalSeconds)
                    .onChange(of: settings.refreshIntervalSeconds) { _ in
                        settings.pushRefreshInterval()
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.refreshOnOpen.title", settings.appLanguage),
                    subtitle: L10n.t("settings.refreshOnOpen.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.refreshOnMenuOpen)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                }
            }

            SettingsCard(
                header: L10n.t("settings.section.budget", settings.appLanguage),
                footer: LocalizedStringKey(L10n.t("settings.monthlyBudget.subtitle", settings.appLanguage))
            ) {
                SettingsLabeledRow(
                    title: L10n.languageCode(settings.appLanguage) == "vi" ? "Kỳ ngân sách" : "Budget period"
                ) {
                    Picker("", selection: $settings.budgetPeriod) {
                        ForEach(BudgetPeriod.allCases) { period in
                            Text(period.label(vi: L10n.languageCode(settings.appLanguage) == "vi"))
                                .tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.monthlyBudget.title", settings.appLanguage)
                ) {
                    TextField("∞", text: Binding(
                        get: {
                            settings.monthlyBudgetUSD > 0 ? String(settings.monthlyBudgetUSD) : ""
                        },
                        set: { raw in
                            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                            guard let parsed = Double(trimmed), parsed.isFinite, parsed > 0 else {
                                settings.monthlyBudgetUSD = 0
                                return
                            }
                            settings.monthlyBudgetUSD = parsed
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
                    Toggle("", isOn: $settings.statusChecksEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.sessionNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.sessionNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.sessionQuotaNotificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.providerFailureNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.providerFailureNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.providerFailureNotificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.quotaWarningNotifications.title", settings.appLanguage),
                    subtitle: L10n.t("settings.quotaWarningNotifications.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.quotaWarningNotificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
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
                        Toggle("", isOn: $settings.quotaWarningSoundEnabled)
                            .labelsHidden()
                            .toggleStyle(.instrumentSwitch)
                    }

                    SettingsRowDivider()

                    SettingsLabeledRow(
                        title: L10n.t("settings.warningAlert.title", settings.appLanguage),
                        subtitle: L10n.t("settings.warningAlert.subtitle", settings.appLanguage)
                    ) {
                        Toggle("", isOn: $settings.quotaWarningOnScreenAlertEnabled)
                            .labelsHidden()
                            .toggleStyle(.instrumentSwitch)
                    }
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("settings.weeklyDigest.title", settings.appLanguage),
                    subtitle: L10n.t("settings.weeklyDigest.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.weeklyDigestEnabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
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
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
            .frame(maxWidth: .infinity, alignment: .trailing)
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
