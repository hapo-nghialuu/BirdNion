import SwiftUI

/// Single link row used in the About pane (ported from the CodexBar
/// `AboutLinkRow`). Instrument redesign: uppercase mono label in the accent
/// color with a hairline top divider — no filled/rounded button chrome; hover
/// state is an underline instead of a background fill (`.about-link-row`,
/// `.pp-link-row` in the CSS).
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.blue)
                    .frame(width: 16)
                Text(title)
                    .font(.plexMono(11, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(VocabbyTheme.blue)
                    .underline(hovering)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.plexMono(9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.blue)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairlineTop()
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
