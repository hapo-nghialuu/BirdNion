import SwiftUI

/// Hooks settings: master toggle + editor for `HooksConfig` rules persisted
/// in `settings.json`. Commands run via `HookEngine`/`HookRunner` — absolute
/// executable paths only, no shell.
struct HooksPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var config: HooksConfig = BirdNionConfigStore.hooks() ?? HooksConfig()

    var body: some View {
        SettingsPage {
            SettingsPaneHeader(
                title: L10n.t("settings.tab.hooks", settings.appLanguage),
                subtitle: L10n.t("settings.hooks.subtitle", settings.appLanguage)
            )

            VStack(alignment: .leading, spacing: 0) {
                SettingsLabeledRow(
                    title: L10n.t("settings.hooks.enable.title", settings.appLanguage),
                    subtitle: L10n.t("settings.hooks.enable.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $config.enabled)
                        .labelsHidden()
                        .toggleStyle(.instrumentSwitch)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings.hooks.rules", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.top, 22)
                    .padding(.bottom, 4)

                if config.events.isEmpty {
                    Text(L10n.t("settings.hooks.empty", settings.appLanguage))
                        .font(.plexSans(12))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .padding(.vertical, 8)
                }

                ForEach($config.events) { $rule in
                    HookRuleEditor(rule: $rule, language: settings.appLanguage) {
                        config.events.removeAll { $0.id == rule.id }
                    }
                }

                Button(L10n.t("settings.hooks.add", settings.appLanguage)) {
                    config.events.append(HookRule(
                        event: .quotaLow,
                        executable: "/usr/bin/true"))
                }
                .buttonStyle(.instrumentOutline)
                .pointingHandCursor()
                .padding(.top, 10)

                Text(LocalizedStringKey(L10n.t("settings.hooks.footer", settings.appLanguage)))
                    .font(.plexSans(12))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .padding(.top, 10)
            }
        }
        .onChange(of: config) { _, newValue in
            try? BirdNionConfigStore.saveHooks(newValue)
        }
    }
}

private struct HookRuleEditor: View {
    @Binding var rule: HookRule
    let language: String?
    let onDelete: () -> Void

    /// Provider options from the configured roster (builtin + plugin ids).
    private var providerOptions: [(id: String, name: String)] {
        BirdNionConfigStore.allProviders()
            .map { ($0.id, $0.displayName ?? $0.id) }
            .sorted { $0.1 < $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: $rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.instrumentSwitch)

                Picker("", selection: $rule.event) {
                    ForEach(HookEventType.allCases, id: \.self) { event in
                        Text(event.rawValue).tag(event)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)

                Picker("", selection: providerBinding) {
                    Text(L10n.t("settings.hooks.provider.any", language)).tag("")
                    ForEach(providerOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)

                Spacer()

                Button(L10n.t("settings.hooks.delete", language), role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.instrumentOutline)
                .pointingHandCursor()
            }

            HStack(spacing: 10) {
                TextField(
                    L10n.t("settings.hooks.executable", language),
                    text: $rule.executable)
                    .textFieldStyle(.roundedBorder)
                    .font(.plexMono(11))
                    .frame(maxWidth: 320)

                TextField(
                    L10n.t("settings.hooks.args", language),
                    text: argumentsBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.plexMono(11))
            }

            HStack(spacing: 10) {
                if rule.event == .quotaLow {
                    Text(L10n.t("settings.hooks.threshold", language))
                        .font(.plexSans(11))
                        .foregroundStyle(VocabbyTheme.secondary)
                    TextField("", value: thresholdBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                Spacer()
                Text(L10n.t("settings.hooks.timeout", language))
                    .font(.plexSans(11))
                    .foregroundStyle(VocabbyTheme.secondary)
                TextField("", value: $rule.timeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VocabbyTheme.group))
        .padding(.vertical, 4)
    }

    /// Space-joined arguments field — a scalar String can't bind to [String].
    private var argumentsBinding: Binding<String> {
        Binding(
            get: { rule.arguments.joined(separator: " ") },
            set: { rule.arguments = $0
                .split(separator: " ")
                .map(String.init) })
    }

    /// Provider picker stores "" for the "any" option.
    private var providerBinding: Binding<String> {
        Binding(
            get: { rule.provider ?? "" },
            set: { rule.provider = $0.isEmpty ? nil : $0 })
    }

    /// Threshold edited as integer percent (0...100), stored as 0...1 fraction.
    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { (rule.threshold ?? 0.9) * 100 },
            set: { rule.threshold = max(0, min(100, $0)) / 100 })
    }
}
