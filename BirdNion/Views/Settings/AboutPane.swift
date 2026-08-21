import AppKit
import SwiftUI

/// About pane: centered branding, update actions, project links + brew install
/// command, and copyright. Layout follows the remake mockup; UpdateChecker
/// behaviour is unchanged.
struct AboutPane: View {
    static var brewUpgradeCommand: String { UpdateChecker.brewUpgradeCommand }

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
                    .padding(.top, 22)
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
                    .padding(.top, 22)
                    .padding(.bottom, 4)

                SettingsLabeledRow(
                    title: L10n.t("about.autoCheck.title", settings.appLanguage),
                    subtitle: L10n.t("about.autoCheck.subtitle", settings.appLanguage)
                ) {
                    Toggle("", isOn: $settings.updateAutoCheckEnabled).labelsHidden().toggleStyle(.instrument)
                }

                SettingsLabeledRow(
                    title: L10n.t("about.channel.title", settings.appLanguage),
                    subtitle: nil
                ) {
                    InstrumentMenuSelect(
                        options: [
                            ("stable", L10n.t("about.channel.stable", settings.appLanguage)),
                            ("beta", L10n.t("about.channel.beta", settings.appLanguage)),
                        ],
                        selection: $settings.updateChannel
                    )
                    .frame(width: 110)
                    .onChange(of: settings.updateChannel) { _ in
                        Task { await checker.check() }
                    }
                }
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
            .pointingHandCursor()
            .help(L10n.t("settings.about.copyCommand", settings.appLanguage))
            .accessibilityLabel(L10n.t("settings.about.copyCommand", settings.appLanguage))
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineTop(SettingsTheme.hairline)
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
                    checker.applyAvailableUpdate()
                }
                .buttonStyle(.instrumentAccent)
                .pointingHandCursor()
                Button(L10n.t("about.openRelease", settings.appLanguage)) {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.instrumentOutline)
                .pointingHandCursor()
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

    private func openProjectHome() {
        if let url = URL(string: projectURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
