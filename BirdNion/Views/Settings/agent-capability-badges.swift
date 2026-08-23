import SwiftUI

struct AgentCapabilityBadges: View {
    let record: InstalledAgentRecord
    let language: String

    private var vi: Bool { L10n.languageCode(language) == "vi" }

    var body: some View {
        HStack(spacing: 4) {
            badge(title: "Quota", active: record.capabilities.contains(.quota))
            badge(title: vi ? "Chi phí" : "Cost", active: record.capabilities.contains(.localCost))
            badge(title: "Config", active: record.capabilities.contains(.nativeConfig))
        }
    }

    private func badge(title: String, active: Bool) -> some View {
        Text(title.uppercased())
            .font(.plexMono(9, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? VocabbyTheme.primary : VocabbyTheme.track)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                Rectangle()
                    .stroke(active ? VocabbyTheme.primary : VocabbyTheme.border, lineWidth: 1)
            )
    }
}
