import SwiftUI

struct AllAgentsOverview: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    let pendingSources: [String]
    let visibleRecords: [InstalledAgentRecord]
    let quotaRows: [AgentQuotaRow]
    let costRows: [AgentCostRow]
    let configuredRows: [AgentConfiguredRow]
    let onOpenAgent: (InstalledAgentID) -> Void
    let onOpenActivity: () -> Void

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var insightsSources: Set<ProjectUsageSource> {
        Set(ProjectUsageSource.allCases)
    }
    var body: some View {
        if !pendingSources.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                Text((vi ? "Đang quét " : "Scanning ") + pendingSources.joined(separator: ", ") + "…")
                    .font(.plexSans(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .popoverContentInset()
            .padding(.top, 12)
        }

        // Khối 1: Tổng chi phí
        CombinedChartCard(
            report: report,
            claudeHourly: [],
            summaryAgentCount: visibleRecords.count,
            onOpenActivity: onOpenActivity
        )

        // Khối 2: Quota
        AllAgentsQuotaSection(
            rows: quotaRows,
            totalAgentCount: visibleRecords.count,
            onOpenAgent: onOpenAgent
        )

        // Khối 3: Chi phí theo
        AllAgentsCostBreakdownSection(
            rows: costRows,
            onOpenAgent: onOpenAgent
        )

        // Khối 4: Đã cấu hình
        AllAgentsConfiguredSection(
            rows: configuredRows,
            onOpenAgent: onOpenAgent
        )

        // Khối 5: Ngân sách (theo setting tuần/tháng)
        BudgetForecastCard(report: report)

        // Phụ: Confidence badges + Insights highlight card + 120d Heatmap
        SourceConfidenceBadgeRow(report: report)
        InsightsHighlightCard(combined: report, enabledSources: insightsSources)
        CombinedHeatmapCard(report: report)
    }
}

struct AgentQuotaRow: Identifiable {
    let record: InstalledAgentRecord
    let providerName: String
    let windowLabel: String
    let remainingPct: Int?

    var id: InstalledAgentID { record.id }
}

struct AgentCostRow: Identifiable {
    let record: InstalledAgentRecord
    let last30USD: Double
    let todayUSD: Double
    let tokens: Int
    let topModel: String?

    var color: Color {
        switch record.id {
        case .claude: VocabbyTheme.chartClaude
        case .codex: VocabbyTheme.chartCodex
        case .grok: VocabbyTheme.chartGrok
        case .kiro: VocabbyTheme.chartKiro
        case .omp: VocabbyTheme.chartOMP
        case .pi: VocabbyTheme.chartPi
        default: VocabbyTheme.tertiary
        }
    }

    var id: InstalledAgentID { record.id }
}

struct AgentConfiguredRow: Identifiable {
    let record: InstalledAgentRecord
    let detail: String
    let evidence: String

    var id: InstalledAgentID { record.id }
}
