import SwiftUI

struct AgentRosterTabs: View {
    @EnvironmentObject var settings: SettingsStore

    let pinnedRecords: [InstalledAgentRecord]
    let overflowRecords: [InstalledAgentRecord]
    let providerOnlyStatuses: [ProviderStatus]
    let providerStatuses: [ProviderStatus]
    @Binding var selectedID: String

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                allChip
                ForEach(pinnedRecords) { record in
                    chip(for: record)
                }
                if !overflowRecords.isEmpty {
                    overflowMenu
                }
                if !providerOnlyStatuses.isEmpty {
                    providerMenu
                }
            }
            .padding(.vertical, 10)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .popoverContentInset()
        .overlay(alignment: .bottom) {
            VocabbyTheme.hairline.frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var allChip: some View {
        let active = selectedID == "all"
        let label = L10n.t("popover.allTab", settings.appLanguage)
        return Button {
            selectedID = "all"
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
                .frame(width: 32, height: 32)
                .background(chipFill(active: active))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func chip(for record: InstalledAgentRecord) -> some View {
        let active = selectedID == record.id.rawValue
        let quotaInfo = agentQuotaInfo(for: record)
        let helpText = quotaInfo.map {
            vi ? "\(record.displayName) · còn \($0.pct)%" : "\(record.displayName) · \($0.pct)% left"
        } ?? record.displayName

        return Button {
            selectedID = record.id.rawValue
        } label: {
            ZStack(alignment: .topTrailing) {
                chipContent(for: record, active: active)
                    .frame(width: 32, height: 32)
                if let quota = quotaInfo, !active {
                    Rectangle()
                        .fill(quota.dotColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
            .background(chipFill(active: active))
            .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private func chipContent(for record: InstalledAgentRecord, active: Bool) -> some View {
        if hasBrandLogo(record.id) {
            ProviderLogoMark(id: record.id.rawValue, tint: active ? VocabbyTheme.background : nil)
                .frame(width: 15, height: 15)
        } else {
            Text(monogram(for: record))
                .font(.plexMono(12, weight: .semibold))
                .foregroundStyle(active ? VocabbyTheme.background : VocabbyTheme.secondary)
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowRecords) { record in
                Button(record.displayName) {
                    selectedID = record.id.rawValue
                }
            }
        } label: {
            Text("+\(overflowRecords.count)")
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .frame(height: 32)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(VocabbyTheme.border)
                )
        }
        .menuStyle(.borderlessButton)
        .help(overflowLabel)
        .accessibilityLabel(overflowLabel)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(providerOnlyStatuses, id: \.id) { status in
                Button(status.displayName) {
                    selectedID = status.id
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .frame(width: 32, height: 32)
                .background(chipFill(active: providerOnlyStatuses.contains { $0.id == selectedID }))
        }
        .menuStyle(.borderlessButton)
        .help(providerOnlyStatuses.map(\.displayName).joined(separator: ", "))
        .accessibilityLabel("More quota providers")
    }

    private var overflowLabel: String {
        let names = overflowRecords.map(\.displayName).joined(separator: ", ")
        return names.isEmpty ? "More agents" : "More agents: \(names)"
    }

    private func chipFill(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
            .fill(active ? VocabbyTheme.primary : VocabbyTheme.background)
            .overlay(
                RoundedRectangle(cornerRadius: InstrumentShape.controlRadius, style: .continuous)
                    .stroke(active ? Color.clear : VocabbyTheme.border, lineWidth: 1)
            )
    }

    private func hasBrandLogo(_ id: InstalledAgentID) -> Bool {
        switch id {
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor:
            return true
        default:
            return false
        }
    }

    private func monogram(for record: InstalledAgentRecord) -> String {
        switch record.id {
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
        default:
            let parts = record.displayName.split(separator: " ")
            if parts.count > 1 {
                return parts.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
            }
            return String(record.displayName.prefix(1)).uppercased()
        }
    }

    private func agentQuotaInfo(for record: InstalledAgentRecord) -> (pct: Int, dotColor: Color)? {
        guard record.capabilities.contains(.quota) else { return nil }
        guard let status = providerStatuses.first(where: { s in
            record.providerIDs.contains(s.id) || s.id == record.id.rawValue
        }) else { return nil }
        guard let minWindow = status.windows.min(by: { $0.remainingPct < $1.remainingPct }) else { return nil }
        let pct = minWindow.remainingPct
        let dotColor: Color
        if pct < 20 {
            dotColor = Color(red: 0.71, green: 0.25, blue: 0.18) // #B4402F (critical)
        } else if pct < 40 {
            dotColor = Color(red: 0.56, green: 0.37, blue: 0.07) // #8F5F12 (warning)
        } else {
            switch record.id {
            case .claude: dotColor = Color(red: 0.80, green: 0.49, blue: 0.37) // #CC7C5E
            case .codex: dotColor = Color(red: 0.29, green: 0.64, blue: 0.69)  // #49A3B0
            case .kiro: dotColor = Color(red: 0.55, green: 0.28, blue: 0.98)   // #8B47F9
            default: dotColor = Color(red: 0.12, green: 0.48, blue: 0.30)      // #1F7A4C
            }
        }
        return (pct, dotColor)
    }
}
