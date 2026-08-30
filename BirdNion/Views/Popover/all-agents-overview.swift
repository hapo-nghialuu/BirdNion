import SwiftUI

struct AllAgentsOverview: View {
    @EnvironmentObject var settings: SettingsStore

    let report: CombinedUsageReport
    let pendingSources: [String]
    let visibleRecords: [InstalledAgentRecord]
    let aggregateAgentCount: Int
    let quotaRows: [AgentQuotaRow]
    let costRows: [AgentCostRow]
    let modelRows: [AgentModelRow]
    let configuredRows: [AgentConfiguredRow]
    /// Mở panel agent kèm tab theo nguồn click (quota/cost/config).
    let onOpenAgent: (InstalledAgentID, String?) -> Void
    let onOpenActivity: () -> Void
    /// Hover = panel transient; click = ghim.
    let onHoverAgent: (InstalledAgentID) -> Void
    let onHoverActivity: () -> Void
    /// Hover dòng "+N model khác" → panel liệt kê model tràn.
    let onHoverModels: ([AgentModelRow], String) -> Void
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
            modelRows: modelRows,
            onOpenAgent: { onOpenAgent($0, "cost") },
            onHoverAgent: onHoverAgent,
            onHoverModels: onHoverModels,
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

/// Panel hover liệt kê các model tràn khỏi top-5 của Cost by.
struct ModelOverflowPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let items: [AgentModelRow]
    let mode: String

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var sorted: [AgentModelRow] {
        mode == "token" ? items.sorted { $0.tokens > $1.tokens }
                        : items.sorted { $0.usd > $1.usd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((vi ? "MODEL KHÁC" : "MORE MODELS") + " (\(items.count))")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .tracking(0.8)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            VocabbyTheme.chromeRule.frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sorted) { item in
                    HStack(spacing: 8) {
                        Rectangle().fill(item.color).frame(width: 6, height: 6)
                        Text(AllUsageFormat.shortName(item.name))
                            .font(.plexSans(12))
                            .foregroundStyle(VocabbyTheme.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(AllUsageFormat.tokensShort(item.tokens)) · \(AllUsageFormat.usd(item.usd))")
                            .font(.plexMono(10, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(VocabbyTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        // Viền xám nhạt cho mọi popover (quy ước 2026-08-24).
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
    }
}

/// Một model gộp trong window đang chọn — nguồn màu theo agent chi phối.
struct AgentModelRow: Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    let source: String

    var id: String { name }
    var color: Color {
        switch source {
        case "claude": VocabbyTheme.chartClaude
        case "codex": VocabbyTheme.chartCodex
        case "grok": VocabbyTheme.chartGrok
        case "kiro": VocabbyTheme.chartKiro
        case "omp": VocabbyTheme.chartOMP
        case "pi": VocabbyTheme.chartPi
        default: VocabbyTheme.tertiary
        }
    }
}

struct AgentConfiguredRow: Identifiable {
    let record: InstalledAgentRecord
    let detail: String
    let evidence: String

    var id: InstalledAgentID { record.id }
}
