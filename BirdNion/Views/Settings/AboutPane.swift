import SwiftUI

/// About pane: interactive app icon, name + version, project links, update
/// check (GitHub Releases — BirdNion doesn't ship Sparkle), copyright.
/// Mirrors the centered layout of CodexBar's About tab.
struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var iconHover = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return L10n.f("about.version", settings.appLanguage, short, build)
    }

    /// Build date = executable's modification date — no build-phase plumbing.
    private var buildDateString: String? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private let projectURL = "https://github.com/hapo-nghialuu/BirdNion"

    var body: some View {
        SettingsPage(maxContentWidth: 430) {
            SettingsCard {
                VStack(spacing: 14) {
                    Button(action: openProjectHome) {
                        appIcon
                            .frame(width: 92, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .scaleEffect(iconHover ? 1.04 : 1.0)
                            .shadow(color: iconHover ? SettingsTheme.accent.opacity(0.22) : .black.opacity(0.08),
                                    radius: iconHover ? 8 : 2)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            iconHover = hovering
                        }
                    }
                    .help(L10n.t("about.openProject", settings.appLanguage))
                    .accessibilityLabel(L10n.t("about.openProject", settings.appLanguage))

                    VStack(spacing: 4) {
                        Text("BirdNion")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primary)
                        Text(versionString)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.secondary)
                        if let built = buildDateString {
                            Text(L10n.f("about.buildDate", settings.appLanguage, built))
                                .font(.system(size: 10))
                                .foregroundStyle(SettingsTheme.tertiary)
                        }
                        Text(L10n.t("about.tagline", settings.appLanguage))
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsRowDivider()
                        .padding(.leading, 0)

                    VStack(alignment: .leading, spacing: 2) {
                        AboutLinkRow(icon: "chevron.left.slash.chevron.right",
                                     title: "GitHub",
                                     url: projectURL)
                        AboutLinkRow(icon: "globe",
                                     title: "Website",
                                     url: projectURL)
                        AboutLinkRow(icon: "envelope",
                                     title: "Email",
                                     url: ProcessInfo.processInfo.environment["BIRDNION_SUPPORT_EMAIL"]
                                        ?? "mailto:support@localhost")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }

            SettingsCard(header: L10n.t("about.section.updates", settings.appLanguage)) {
                SettingsLabeledRow(
                    title: L10n.t("about.autoCheck.title", settings.appLanguage),
                    subtitle: L10n.t("about.autoCheck.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.updateAutoCheckEnabled).labelsHidden().toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: L10n.t("about.channel.title", settings.appLanguage),
                    subtitle: nil
                ) {
                    Picker("", selection: $settings.updateChannel) {
                        Text(L10n.t("about.channel.stable", settings.appLanguage)).tag("stable")
                        Text(L10n.t("about.channel.beta", settings.appLanguage)).tag("beta")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .onChange(of: settings.updateChannel) { _ in
                        Task { await checker.check() }
                    }
                }

                SettingsRowDivider()

                HStack(spacing: 10) {
                    updateStatus
                    Spacer(minLength: 8)
                    Button(L10n.t("about.checkNow", settings.appLanguage)) {
                        Task { await checker.check() }
                    }
                    .disabled(checker.state == .checking)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Text("© 2026 BirdNion · Hapo")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Inline result line next to the check button.
    @ViewBuilder
    private var updateStatus: some View {
        switch checker.state {
        case .idle:
            Text("")
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("about.checking", settings.appLanguage))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.secondary)
            }
        case .upToDate:
            Text(L10n.t("about.upToDate", settings.appLanguage))
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.secondary)
        case .available(let version, let url):
            HStack(spacing: 8) {
                Text(L10n.f("about.updateAvailable", settings.appLanguage, version))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                // Semi-auto: open Terminal running the brew upgrade so the
                // user sees progress and the cask can replace the running
                // bundle. No Sparkle / Developer ID needed.
                Button(L10n.t("about.updateNow", settings.appLanguage)) {
                    runBrewUpgrade()
                }
                .controlSize(.small)
                Button(L10n.t("about.openRelease", settings.appLanguage)) {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        case .failed:
            Text(L10n.t("about.checkFailed", settings.appLanguage))
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.warning)
        }
    }

    /// Prefer the real bundle icon; fall back to the bundled asset.
    @ViewBuilder
    private var appIcon: some View {
        if let nsIcon = NSApplication.shared.applicationIconImage {
            Image(nsImage: nsIcon)
                .resizable()
                .interpolation(.high)
        } else {
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
        }
    }

    /// Opens Terminal running the Homebrew cask upgrade. Terminal (not an
    /// in-process Process) so the user sees download/replace progress and the
    /// cask can swap the running bundle; the new version applies on relaunch.
    private func runBrewUpgrade() {
        let script = """
        tell application "Terminal"
            activate
            do script "brew upgrade --cask birdnion"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func openProjectHome() {
        if let url = URL(string: projectURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
