import SwiftUI

struct AgentInventoryRow: View {
    let record: InstalledAgentRecord
    let isVisible: Bool
    let isSelected: Bool
    let cost90dUSD: Double?
    let language: String
    let onSelect: () -> Void
    let onVisibilityChange: (Bool) -> Void

    private var vi: Bool { L10n.languageCode(language) == "vi" }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Toggle (40px)
                Toggle("", isOn: Binding(
                    get: { isVisible },
                    set: onVisibilityChange
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 40, alignment: .leading)

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
                    .foregroundStyle(isVisible ? SettingsTheme.primary : SettingsTheme.tertiary)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)

                // Data Capability Badges (148px)
                HStack(spacing: 4) {
                    badge(title: "Quota", active: record.capabilities.contains(.quota) && isVisible)
                    badge(title: vi ? "Chi phí" : "Cost", active: record.capabilities.contains(.localCost) && isVisible)
                    badge(title: "Config", active: (record.capabilities.contains(.nativeConfig) || isConfigAgent) && isVisible)
                }
                .frame(width: 148, alignment: .leading)

                // 90 days cost (92px)
                Text(cost90dUSD.map { AllUsageFormat.usd($0) } ?? "—")
                    .font(.plexMono(12, weight: .semibold))
                    .foregroundStyle(cost90dUSD != nil && isVisible ? SettingsTheme.primary : SettingsTheme.tertiary)
                    .frame(width: 92, alignment: .trailing)

                // Chevron (14px)
                Text("›")
                    .font(.plexSans(12))
                    .foregroundStyle(isSelected ? SettingsTheme.primary : SettingsTheme.tertiary)
                    .frame(width: 14, alignment: .center)
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
        if !isVisible { return (vi ? "Config · đã tắt" : "Config · disabled") }
        switch record.id {
        case .kiro, .cursor: return "IDE"
        case .pi, .omp: return "Config"
        default: return "CLI"
        }
    }

    private var sourceLabel: String {
        switch record.id {
        case .claude, .aider: return "Claude · OAuth"
        case .codex: return "Codex · OAuth"
        case .kiro: return "Kiro · OAuth"
        case .opencode, .pi: return "OpenRouter · key"
        case .grok: return "Zero-config"
        case .omp: return isVisible ? "Custom" : (vi ? "Chưa đặt" : "Unset")
        case .cursor: return "Cursor · OAuth"
        case .gemini: return "Gemini · OAuth"
        case .antigravity: return "Antigravity · OAuth"
        case .copilot: return "Copilot · OAuth"
        case .auggie: return "Auggie · Config"
        case .amp: return "Amp · Config"
        case .qwen: return "Qwen · Config"
        case .goose: return "Goose · Config"
        }
    }

    private var isConfigAgent: Bool {
        record.id == .pi || record.id == .omp || record.capabilities.contains(.nativeConfig)
    }

    private func hasBrandLogo(_ id: InstalledAgentID) -> Bool {
        switch id {
        case .claude, .codex, .kiro, .opencode, .grok, .gemini, .cursor, .antigravity, .copilot: return true
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
