import AppKit
import SwiftUI

/// About pane: centered branding, update actions, project links + brew install
/// command, and copyright. Layout follows the remake mockup; UpdateChecker
/// behaviour is unchanged.
struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var iconHover = false

    private var architectureLabel: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return L10n.f("about.version", settings.appLanguage, short, architectureLabel)
    }

    private let projectURL = "https://github.com/hapo-nghialuu/BirdNion"
    private let releasesURL = "https://github.com/hapo-nghialuu/BirdNion/releases"
    private let brewInstallCommand = "brew install --cask hapo-nghialuu/tap/birdnion"

    var body: some View {
        SettingsPage(maxContentWidth: 480) {
            SettingsPaneHeader(
                title: L10n.t("settings.tab.about", settings.appLanguage)
            )

            // MARK: Centered branding + primary actions
            VStack(spacing: 16) {
                Button(action: openProjectHome) {
                    appIcon
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .scaleEffect(iconHover ? 1.04 : 1.0)
                        .shadow(
                            color: iconHover ? SettingsTheme.accent.opacity(0.22) : .black.opacity(0.08),
                            radius: iconHover ? 8 : 2
                        )
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
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(versionString)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.secondary)
                }

                HStack(spacing: 10) {
                    Button(L10n.t("about.checkNow", settings.appLanguage)) {
                        Task { await checker.check() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checker.state == .checking)

                    Button(L10n.t("settings.about.releaseNotes", settings.appLanguage)) {
                        if let url = URL(string: releasesURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                updateStatus
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // MARK: Links (existing destinations + brew install row)
            SettingsCard(header: L10n.t("settings.section.links", settings.appLanguage)) {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: "GitHub",
                    url: projectURL
                )
                SettingsRowDivider()
                AboutLinkRow(
                    icon: "globe",
                    title: "Website",
                    url: projectURL
                )
                SettingsRowDivider()
                AboutLinkRow(
                    icon: "envelope",
                    title: "Email",
                    url: ProcessInfo.processInfo.environment["BIRDNION_SUPPORT_EMAIL"]
                        ?? "mailto:support@localhost"
                )
                SettingsRowDivider()
                brewInstallRow
            }

            // MARK: Update preferences (behaviour preserved from pre-remake)
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
            }

            Text(L10n.t("settings.about.copyright", settings.appLanguage))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
        }
    }

    /// Homebrew install command with copy button (pattern from ClaudeCodePane).
    private var brewInstallRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("settings.about.brewInstall", settings.appLanguage))
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.primary)
                Text(brewInstallCommand)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(SettingsTheme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(brewInstallCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .help(L10n.t("settings.about.copyCommand", settings.appLanguage))
            .accessibilityLabel(L10n.t("settings.about.copyCommand", settings.appLanguage))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    /// Inline result line under the check / release-notes buttons.
    @ViewBuilder
    private var updateStatus: some View {
        switch checker.state {
        case .idle:
            EmptyView()
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
