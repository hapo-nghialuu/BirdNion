import SwiftUI

/// About pane: app icon (clickable), version, and external links.
/// Mirrors the centered layout in the CodexBar About tab.
struct AboutPane: View {
    @State private var iconHover = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "v\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 6)

            Button {
                if let url = URL(string: "https://github.com/hapo-nghialuu/statusbar") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image("OriginalImage")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(iconHover ? 1.05 : 1.0)
                    .shadow(color: .black.opacity(iconHover ? 0.18 : 0.08),
                            radius: iconHover ? 6 : 2)
            }
            .buttonStyle(.plain)
            .onHover { iconHover = $0 }
            .help("Mở trang dự án trên GitHub")

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

            Divider().padding(.horizontal, 60)

            VStack(spacing: 0) {
                AboutLinkRow(icon: "chevron.left.slash.chevron.right",
                             title: "GitHub",
                             url: "https://github.com/hapo-nghialuu/statusbar")
                AboutLinkRow(icon: "globe",
                             title: "Website",
                             url: "https://github.com/hapo-nghialuu/statusbar")
                AboutLinkRow(icon: "envelope",
                             title: "Email",
                             url: "mailto:support@localhost")
            }
            .padding(.horizontal, 80)

            Spacer()

            Text("© 2026 BirdNion · Hapo")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
