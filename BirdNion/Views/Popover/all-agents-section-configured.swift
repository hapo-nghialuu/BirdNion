import SwiftUI

struct AllAgentsConfiguredSection: View {
    @EnvironmentObject var settings: SettingsStore

    let rows: [AgentConfiguredRow]
    let onOpenAgent: (InstalledAgentID) -> Void

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        if !rows.isEmpty {
            Button {
                if let first = rows.first {
                    onOpenAgent(first.record.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(vi ? "ĐÃ CẤU HÌNH" : "CONFIGURED")
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                    HStack(spacing: 4) {
                        ForEach(Array(rows.prefix(4))) { row in
                            agentBadge(row.record)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(vi
                         ? "\(rows.count) AGENT · KHÔNG CÓ LOG"
                         : "\(rows.count) AGENTS · NO LOGS")
                        .font(.plexMono(10))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .lineLimit(1)
                    Text("›")
                        .font(.plexSans(12))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popoverContentInset()
            .padding(.vertical, 12)
            .overlay(alignment: .top) { PopoverInsetHairline() }
        }
    }

    private func agentBadge(_ record: InstalledAgentRecord) -> some View {
        Text(monogram(for: record.id))
            .font(.plexMono(8, weight: .semibold))
            .foregroundStyle(VocabbyTheme.tertiary)
            .frame(width: 15, height: 15)
            .overlay {
                Rectangle().stroke(VocabbyTheme.border, lineWidth: 1)
            }
    }

    private func monogram(for id: InstalledAgentID) -> String {
        switch id {
        case .aider: return "A"
        case .pi: return "P"
        case .omp: return "OM"
        case .cursor: return "C"
        case .gemini: return "G"
        case .antigravity: return "AG"
        case .copilot: return "CP"
        case .auggie: return "AU"
        case .amp: return "AM"
        case .qwen: return "Q"
        case .goose: return "GS"
        default: return String(id.displayName.prefix(1)).uppercased()
        }
    }
}
