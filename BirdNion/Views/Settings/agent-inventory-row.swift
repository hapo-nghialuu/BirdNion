import SwiftUI

struct AgentInventoryRow: View {
    let record: InstalledAgentRecord
    let isVisible: Bool
    let isSelected: Bool
    let cost90dUSD: Double?
    let sourceLabel: String
    let detailSnapshot: AgentDetailSnapshot?
    let language: String
    let onSelect: () -> Void
    let onVisibilityChange: (Bool) -> Void

    private var vi: Bool { L10n.languageCode(language) == "vi" }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                // Toggle (40px)
                Toggle("", isOn: Binding(
                    get: { isVisible },
                    set: onVisibilityChange
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 40, alignment: .leading)
                .help(vi
                      ? "Chỉ ẩn hoặc hiện agent trong popover; không tắt provider hay scanner."
                      : "Only hides or shows this agent in the popover; providers and scanners keep running.")

                // Agent Icon + Name + Subtitle (flex: 1)
                HStack(spacing: 9) {
                    agentIcon
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName)
                            .font(.plexSans(13, weight: .semibold))
                            .foregroundStyle(isVisible ? SettingsTheme.primary : SettingsTheme.secondary)
                            .lineLimit(1)
                        Text(agentTypeSubtitle.uppercased())
                            .font(.plexMono(10))
                            .foregroundStyle(isVisible ? SettingsTheme.secondary : SettingsTheme.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Source (110px)
                Text(sourceLabel)
                    .font(.plexMono(11))
                    .foregroundStyle(SettingsTheme.primary)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)

                // Data Capability Badges (148px)
                HStack(spacing: 4) {
                    badge(title: "Quota", active: record.capabilities.contains(.quota))
                    badge(title: vi ? "Chi phí" : "Cost", active: record.capabilities.contains(.localCost))
                    badge(title: "Config", active: record.capabilities.contains(.nativeConfig) || isConfigAgent)
                }
                .frame(width: 148, alignment: .leading)

                // 90 days cost (92px)
                Text(cost90dUSD.map { AllUsageFormat.usd($0) } ?? "—")
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(cost90dUSD != nil ? SettingsTheme.primary : SettingsTheme.tertiary)
                    .frame(width: 92, alignment: .trailing)

                // Chevron (14px)
                Text("›")
                    .font(.plexSans(12))
                    .foregroundStyle(isSelected ? SettingsTheme.primary : SettingsTheme.tertiary)
                    .frame(width: 14, alignment: .center)
                }
                if isSelected, let detailSnapshot {
                    inlineDetail(detailSnapshot)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                isSelected
                    ? Color(red: 0.91, green: 0.90, blue: 0.86) // #E9E6DC
                    : Color.clear
            )
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                VocabbyTheme.hairline.frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var agentIcon: some View {
        if hasBrandLogo(record.id) {
            ProviderLogoMark(id: record.id.rawValue)
        } else {
            Text(monogram(for: record.id))
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(isVisible ? SettingsTheme.primary : SettingsTheme.tertiary)
                .frame(width: 18, height: 18)
                .overlay {
                    Rectangle().stroke(VocabbyTheme.border, lineWidth: 1)
                }
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

    private var agentTypeSubtitle: String {
        switch record.id {
        case .kiro, .cursor: return "IDE"
        default:
            return record.evidence.contains { $0.kind == .executable } ? "CLI" : "Config"
        }
    }

    private func inlineDetail(_ snapshot: AgentDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let status = snapshot.providerStatus,
                   let window = ProviderStatusSummary.lowestWindow(status) {
                    Text("QUOTA · \(window.label) \(window.remainingPct)%")
                }
                if let cost = snapshot.costSummary {
                    Text("90D · \(AllUsageFormat.usd(cost.periodUSD)) · \(AllUsageFormat.tokens(cost.periodTokens))")
                }
                Text("\(vi ? "NGUỒN" : "SOURCE") · \(snapshot.sourceName.isEmpty ? sourceLabel : snapshot.sourceName)")
            }
            .font(.plexMono(9, weight: .semibold))
            Text(snapshot.evidence.map(\.token).joined(separator: " · "))
                .font(.plexMono(9))
                .lineLimit(2)
        }
        .foregroundStyle(SettingsTheme.tertiary)
        .padding(.top, 8)
        .padding(.leading, 52)
    }

    private var isConfigAgent: Bool {
        record.id == .pi || record.id == .omp || record.capabilities.contains(.nativeConfig)
    }

    private func hasBrandLogo(_ id: InstalledAgentID) -> Bool {
        switch id {
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor, .antigravity, .copilot, .aider, .amp, .auggie, .goose, .qwen: return true
        default: return false
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
