import SwiftUI

/// Custom horizontal tab bar with icon + 2-line label, matching the CodexBar
/// toolbar style. Selected tab uses the fixed Settings palette so it stays
/// visually aligned with the popover.
struct SettingsTabBar: View {
    @EnvironmentObject var settings: SettingsStore

    @Binding var selected: SettingsTab
    let tabs: [SettingsTab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                SettingsTabButton(
                    tab: tab,
                    language: settings.appLanguage,
                    isSelected: tab == selected,
                    action: { selected = tab }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SettingsTheme.toolbar)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let language: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .regular))
                Text(tab.title(language: language))
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 70, minHeight: 48)
            .foregroundStyle(isSelected ? SettingsTheme.accent : SettingsTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? SettingsTheme.selectedSurface
                          : (hovering ? SettingsTheme.hoverSurface : .clear))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.16), value: hovering)
            .animation(.easeOut(duration: 0.16), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(tab.title(language: language))
        .accessibilityLabel(tab.title(language: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
