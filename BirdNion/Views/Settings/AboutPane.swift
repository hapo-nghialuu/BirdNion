import SwiftUI

/// About pane: interactive app icon, name + version, project links, copyright.
/// Mirrors the centered layout of CodexBar's About tab (minus the Sparkle
/// auto-update section, which BirdNion doesn't ship).
struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var iconHover = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return L10n.f("about.version", settings.appLanguage, short, build)
    }

    private let projectURL = "https://github.com/hapo-nghialuu/BirdNion"

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 8)

            // Interactive app icon → opens the project page.
            Button(action: openProjectHome) {
                appIcon
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(iconHover ? 1.05 : 1.0)
                    .shadow(color: iconHover ? SettingsTheme.accent.opacity(0.24) : .black.opacity(0.08),
                            radius: iconHover ? 8 : 2)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    iconHover = hovering
                }
            }
            .help(L10n.t("about.openProject", settings.appLanguage))

            // Name + version + tagline.
            VStack(spacing: 3) {
                Text("BirdNion")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                Text(versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.secondary)
                Text(L10n.t("about.tagline", settings.appLanguage))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            Divider()
                .overlay(SettingsTheme.border.opacity(0.72))
                .padding(.horizontal, 80)

            // Project links, centered.
            VStack(alignment: .leading, spacing: 4) {
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
            .frame(maxWidth: 220)

            Spacer()

            Text("© 2026 BirdNion · Hapo")
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.tertiary)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.background)
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

    private func openProjectHome() {
        if let url = URL(string: projectURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
