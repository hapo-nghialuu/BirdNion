import SwiftUI

struct AllAgentsCostBreakdownSection: View {
    @EnvironmentObject var settings: SettingsStore

    let rows: [AgentCostRow]
    let onOpenAgent: (InstalledAgentID) -> Void
    /// Hover row agent → panel transient; rời chuột → đóng.
    var onHoverAgent: (InstalledAgentID) -> Void = { _ in }
    var onHoverEnd: () -> Void = {}

    enum Mode: String, CaseIterable, Identifiable {
        case agent, model
        var id: String { rawValue }

        func label(vi: Bool) -> String {
            switch self {
            case .agent: vi ? "Agent" : "Agent"
            case .model: vi ? "Model" : "Model"
            }
        }
    }

    @State private var mode: Mode = .agent

    private static let visibleRowLimit = 5
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    struct DisplayRow: Identifiable {
        let id: String
        let name: String
        let amount: Double
        let color: Color
        let agentID: InstalledAgentID?
    }

    private var displayRows: [DisplayRow] {
        switch mode {
        case .agent:
            return rows.map {
                DisplayRow(
                    id: $0.id.rawValue,
                    name: $0.record.displayName,
                    amount: $0.periodUSD,
                    color: $0.color,
                    agentID: $0.id
                )
            }.sorted { $0.amount > $1.amount }
        case .model:
            return groupedRows { $0.topModel ?? (vi ? "Chưa rõ model" : "Unknown model") }
        }
    }

    private var totalUSD: Double { displayRows.reduce(0) { $0 + $1.amount } }

    var body: some View {
        if !displayRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    sectionTitle(vi ? "Chi phí theo" : "Cost by")
                    Spacer(minLength: 8)
                    modePicker
                }
                .padding(.bottom, 8)

                shareBar
                    .padding(.bottom, 7)

                ForEach(Array(displayRows.prefix(Self.visibleRowLimit))) { row in
                    Button {
                        if let id = row.agentID { onOpenAgent(id) }
                    } label: { rowView(row) }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside {
                            if let id = row.agentID { onHoverAgent(id) }
                        } else {
                            onHoverEnd()
                        }
                    }
                }

                let remainder = Array(displayRows.dropFirst(Self.visibleRowLimit))
                if !remainder.isEmpty {
                    summaryRow(remainder)
                }
            }
            .popoverContentInset()
            .padding(.vertical, 14)
            .overlay(alignment: .top) { PopoverInsetHairline() }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { item in
                Button { mode = item } label: {
                    Text(item.label(vi: vi).uppercased())
                        .font(.plexMono(9, weight: mode == item ? .semibold : .medium))
                        .foregroundStyle(mode == item ? VocabbyTheme.background : VocabbyTheme.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(mode == item ? VocabbyTheme.primary : Color.clear)
                }
                .buttonStyle(.plain)
                if item != Mode.allCases.last {
                    VocabbyTheme.border.frame(width: 1, height: 20)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius).stroke(VocabbyTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius))
    }

    private var shareBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(displayRows) { row in
                    Rectangle()
                        .fill(row.color)
                        .frame(width: geometry.size.width * CGFloat(row.amount / max(totalUSD, 0.01)))
                }
            }
        }
        .frame(height: 5)
        .background(VocabbyTheme.track)
    }

    private func rowView(_ row: DisplayRow) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(row.color).frame(width: 3, height: 12)
            if let id = row.agentID {
                if hasBrandLogo(id) {
                    ProviderLogoMark(id: id.rawValue).frame(width: 16, height: 16)
                } else {
                    Text(monogram(for: id))
                        .font(.plexMono(9, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Rectangle().stroke(VocabbyTheme.border, lineWidth: 1)
                        }
                }
            } else {
                Rectangle().fill(row.color).frame(width: 7, height: 7).padding(.horizontal, 4.5)
            }
            Text(row.name)
                .font(.plexSans(13, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(percent(row.amount))
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
            Text(AllUsageFormat.usd(row.amount))
                .font(.plexMono(12, weight: .semibold))
                .frame(width: 62, alignment: .trailing)
            Text("›").font(.plexSans(12)).foregroundStyle(VocabbyTheme.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func summaryRow(_ remainder: [DisplayRow]) -> some View {
        let amount = remainder.reduce(0) { $0 + $1.amount }
        return Button {
            if let first = remainder.compactMap(\.agentID).first {
                onOpenAgent(first)
            }
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(Color(red: 0.69, green: 0.68, blue: 0.64)).frame(width: 3, height: 12)
                Text("+")
                    .font(.plexMono(12))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .frame(width: 16, height: 16)
                Text(vi ? "\(remainder.count) agent khác" : "\(remainder.count) more agents")
                    .font(.plexSans(13))
                    .foregroundStyle(VocabbyTheme.secondary)
                Spacer(minLength: 8)
                Text(percent(amount)).font(.plexMono(10)).foregroundStyle(VocabbyTheme.tertiary)
                Text(AllUsageFormat.usd(amount)).font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(width: 62, alignment: .trailing)
                Text("›").font(.plexSans(12)).foregroundStyle(VocabbyTheme.tertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func hasBrandLogo(_ id: InstalledAgentID) -> Bool {
        switch id {
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor:
            return true
        default:
            return false
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

    private func percent(_ amount: Double) -> String {
        String(format: "%.0f%%", amount / max(totalUSD, 0.01) * 100)
    }

    private func groupedRows(key: (AgentCostRow) -> String) -> [DisplayRow] {
        var groups: [String: DisplayRow] = [:]
        for row in rows {
            let name = key(row)
            let current = groups[name]
            groups[name] = DisplayRow(
                id: name,
                name: name,
                amount: (current?.amount ?? 0) + row.periodUSD,
                color: current?.color ?? row.color,
                agentID: nil
            )
        }
        return groups.values.sorted { $0.amount > $1.amount }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.plexMono(10, weight: .medium))
            .foregroundStyle(VocabbyTheme.tertiary)
    }
}
