import SwiftUI

/// About pane: interactive app icon, name + version, project links, copyright.
/// Mirrors the centered layout of CodexBar's About tab (minus the Sparkle
/// auto-update section, which BirdNion doesn't ship).
struct AboutPane: View {
    @State private var iconHover = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "phiên bản \(short) (\(build))"
    }

    private let projectURL = "https://github.com/hapo-nghialuu/statusbar"

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 8)

            // Interactive app icon → opens the project page.
            Button(action: openProjectHome) {
                appIcon
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(iconHover ? 1.05 : 1.0)
                    .shadow(color: iconHover ? Color.accentColor.opacity(0.25) : .black.opacity(0.08),
                            radius: iconHover ? 8 : 2)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    iconHover = hovering
                }
            }
            .help("Mở trang dự án trên GitHub")

            // Name + version + tagline.
            VStack(spacing: 3) {
                Text("BirdNion")
                    .font(.system(size: 18, weight: .semibold))
                Text(versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Theo dõi quota AI ngay trên menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            Divider().padding(.horizontal, 80)

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
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
