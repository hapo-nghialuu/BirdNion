import SwiftUI

/// Single underline-on-hover link used in the About pane (ported from the
/// CodexBar `AboutLinkRow`).
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
                    .frame(width: 16)
                Text(title)
                    .underline(hovering, color: SettingsTheme.accent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundColor(SettingsTheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
