import SwiftUI

struct AllAgentsOverview: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    let pendingSources: [String]
    let visibleRecords: [InstalledAgentRecord]
    let aggregateAgentCount: Int
    let quotaRows: [AgentQuotaRow]
    let costRows: [AgentCostRow]
    let configuredRows: [AgentConfiguredRow]
    /// Mở panel agent kèm tab theo nguồn click (quota/cost/config).
    let onOpenAgent: (InstalledAgentID, String?) -> Void
    let onOpenActivity: () -> Void
    /// Hover = panel transient; click = ghim.
    let onHoverAgent: (InstalledAgentID) -> Void
    let onHoverActivity: () -> Void
    let onHoverEnd: () -> Void

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

        // Khối 1: Tổng chi phí. (Confidence badges đã dời xuống footer,
        // luân phiên với dòng UPDATED.)
        CombinedChartCard(
            report: report,
            claudeHourly: [],
            summaryAgentCount: aggregateAgentCount,
            onOpenActivity: onOpenActivity,
            onHoverActivity: onHoverActivity,
            onHoverEnd: onHoverEnd
        )

        // Khối 2: Quota
        AllAgentsQuotaSection(
            rows: quotaRows,
            totalAgentCount: visibleRecords.count,
            onOpenAgent: { onOpenAgent($0, "quota") }
        )

        // Khối 3: Chi phí theo
        AllAgentsCostBreakdownSection(
            rows: costRows,
            onOpenAgent: { onOpenAgent($0, "cost") },
            onHoverAgent: onHoverAgent,
            onHoverEnd: onHoverEnd
        )

        // Khối 4: Đã cấu hình
        AllAgentsConfiguredSection(
            rows: configuredRows,
            onOpenAgent: { onOpenAgent($0, "config") }
        )

        // Khối 5: Ngân sách (theo setting tuần/tháng)
        BudgetForecastCard(report: report)

        // Heatmap 120d và InsightsHighlightCard cố tình KHÔNG nằm ở All —
        // nhịp hoạt động xem qua panel Hoạt động (stats row ›), insights xem
        // trong Settings. (Insights card tạm ẩn theo yêu cầu 2026-08-23.)
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
    /// Tổng USD trong đúng cửa sổ thời gian đang chọn ở chart (24h/7d/30d/90d/120d).
    let periodUSD: Double
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
