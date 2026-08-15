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
                // Preserve the mark's own progress gradient.
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
                        .font(.plexSans(24, weight: .bold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(versionString)
                        .font(.plexMono(12))
                        .textCase(.uppercase)
                        .foregroundStyle(SettingsTheme.secondary)
                }

                HStack(spacing: 10) {
                    Button(L10n.t("about.checkNow", settings.appLanguage)) {
                        Task { await checker.check() }
                    }
                    .buttonStyle(.instrumentPrimary)
                    .disabled(checker.state == .checking)

                    Button(L10n.t("settings.about.releaseNotes", settings.appLanguage)) {
                        if let url = URL(string: releasesURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.instrumentOutline)
                }

                updateStatus
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // MARK: Links (existing destinations + brew install row)
            // Instrument redesign: hairline-divided section in place of the
            // old filled/rounded SettingsCard container.
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings.section.links", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.bottom, 4)

                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: "GitHub",
                    url: projectURL
                )
                AboutLinkRow(
                    icon: "globe",
                    title: "Website",
                    url: projectURL
                )
                AboutLinkRow(
                    icon: "envelope",
                    title: "Email",
                    url: ProcessInfo.processInfo.environment["BIRDNION_SUPPORT_EMAIL"]
                        ?? "mailto:support@localhost"
                )
                brewInstallRow
            }

            // MARK: Update preferences (behaviour preserved from pre-remake)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("about.section.updates", settings.appLanguage))
                    .plexEyebrow()
                    .padding(.bottom, 4)

                SettingsLabeledRow(
                    title: L10n.t("about.autoCheck.title", settings.appLanguage),
                    subtitle: L10n.t("about.autoCheck.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.updateAutoCheckEnabled).labelsHidden().toggleStyle(.instrument)
                }
                .hairlineTop()

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
                .hairlineTop()
            }

            Text(L10n.t("settings.about.copyright", settings.appLanguage))
                .font(.plexMono(10))
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
                    .font(.plexSans(13))
                    .foregroundStyle(SettingsTheme.primary)
                Text(brewInstallCommand)
                    .font(.plexMono(11))
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
                Text(L10n.t("settings.about.copyCommand", settings.appLanguage))
            }
            .buttonStyle(.instrumentAccent)
            .controlSize(.small)
            .pointingHandCursor()
            .help(L10n.t("settings.about.copyCommand", settings.appLanguage))
            .accessibilityLabel(L10n.t("settings.about.copyCommand", settings.appLanguage))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .hairlineTop()
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
                    .font(.plexSans(11))
                    .foregroundStyle(SettingsTheme.secondary)
            }
        case .upToDate:
            Text(L10n.t("about.upToDate", settings.appLanguage))
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.secondary)
        case .available(let version, let url):
            HStack(spacing: 8) {
                Text(L10n.f("about.updateAvailable", settings.appLanguage, version))
                    .font(.plexMono(11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                // macOS only: open Terminal with brew upgrade, then quit so
                // the formula can replace bits without a running app lock.
                // No Sparkle / Developer ID needed.
                Button(L10n.t("about.updateNow", settings.appLanguage)) {
                    runBrewUpgradeAndQuit()
                }
                .controlSize(.small)
                Button(L10n.t("about.openRelease", settings.appLanguage)) {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        case .failed:
            Text(L10n.t("about.checkFailed", settings.appLanguage))
                .font(.plexSans(11))
                .foregroundStyle(SettingsTheme.warning)
        }
    }

    /// Use the dedicated brand mark instead of inheriting Finder's app-icon
    /// presentation, which may include platform-specific framing.
    private var appIcon: some View {
        Image("OriginalImage")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(6)
            .accessibilityHidden(true)
    }

    /// Opens Terminal with `brew update && brew upgrade herdr`, waits until
    /// Terminal has been handed the script, then quits BirdNion so the upgrade
    /// is not blocked by a running app. macOS-only path (About pane).
    private func runBrewUpgradeAndQuit() {
        let upgradeCommand = "brew update && brew upgrade herdr"
        let script = """
        tell application "Terminal"
            activate
            do script "\(upgradeCommand)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // Wait for osascript to finish launching Terminal before we exit;
        // otherwise the child can die with the app and the tab never opens.
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Still quit below so the user is not stuck mid-update flow.
        }
        NSApplication.shared.terminate(nil)
    }

    private func openProjectHome() {
        if let url = URL(string: projectURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Instrument button style
//
// Outlined, square-cornered button (`InstrumentShape.controlRadius`) with an
// uppercase mono label — replaces `.borderedProminent` / `.bordered` for the
// About pane's primary actions and copy button. Mirrors `.sw-pill-btn` in the
// CSS: transparent fill, 1px border, fill only while pressed (kept close to
// the existing press-highlight interaction of the native styles it replaces).
private struct InstrumentButtonStyle: ButtonStyle {
    var textColor: Color = VocabbyTheme.secondary
    var borderColor: Color = VocabbyTheme.border

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.plexMono(10, weight: .medium))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(textColor)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? VocabbyTheme.hoverSurface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

private extension ButtonStyle where Self == InstrumentButtonStyle {
    /// "KIỂM TRA CẬP NHẬT" — the primary action: ink border + ink text.
    static var instrumentPrimary: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.primary, borderColor: VocabbyTheme.primary)
    }
    /// "GHI CHÚ PHÁT HÀNH" — secondary action: muted border + secondary text.
    static var instrumentOutline: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.secondary, borderColor: VocabbyTheme.border)
    }
    /// "SAO CHÉP" — accent-colored label, muted border.
    static var instrumentAccent: InstrumentButtonStyle {
        InstrumentButtonStyle(textColor: VocabbyTheme.blue, borderColor: VocabbyTheme.border)
    }
}
