import AppKit
import SwiftUI

struct InsightsOverviewContent: View {
    @EnvironmentObject private var settings: SettingsStore
    let report: ProjectInsightsReport
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(vi ? "7 ngày hiện tại" : "Current 7 days").plexEyebrow()
                    Text(AllUsageFormat.usd(report.overview.currentUSD))
                        .font(.plexMono(30, weight: .bold))
                    Text(AllUsageFormat.tokens(report.overview.currentTokens))
                        .font(.plexMono(11)).foregroundStyle(SettingsTheme.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(vi ? "7 ngày trước" : "Previous 7 days").plexEyebrow()
                    Text(AllUsageFormat.usd(report.overview.priorUSD))
                        .font(.plexMono(20, weight: .semibold))
                    Text(changeText)
                        .font(.plexMono(12, weight: .semibold))
                        .foregroundStyle(changeColor)
                }
            }
            .padding(.vertical, 18)
            .hairlineTop(SettingsTheme.hairline)

            insightRow(vi ? "Nguồn hàng đầu" : "Top source",
                       report.overview.topSource?.displayName ?? "—")
            insightRow(vi ? "Model hàng đầu" : "Top model",
                       report.overview.topModel.map {
                           AllUsageFormat.shortName(ProjectIdentity.safeModelName($0.name))
                       } ?? "—")
            insightRow(vi ? "Độ tin cậy" : "Confidence", confidenceText)

            Button {
                let value = ProjectInsightsBuilder.copySummary(report, language: settings.appLanguage)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Label(vi ? "Sao chép tóm tắt đã ẩn đường dẫn" : "Copy redacted summary",
                      systemImage: "doc.on.doc")
            }
            .buttonStyle(.instrumentOutline)
            .pointingHandCursor()
            .padding(.top, 16)
        }
    }

    private var changeText: String {
        report.overview.changePercent.map { String(format: "%@%.0f%%", $0 >= 0 ? "+" : "", $0) } ?? "—"
    }
    private var changeColor: Color {
        guard let value = report.overview.changePercent else { return SettingsTheme.tertiary }
        return value > 0 ? SettingsTheme.warning : SettingsTheme.success
    }
    private var confidenceText: String {
        let c = report.overview.confidence
        var parts: [String] = []
        if !c.live.isEmpty { parts.append("LIVE: " + c.live.map(\.displayName).joined(separator: ", ")) }
        if !c.historyOnly.isEmpty {
            parts.append((vi ? "LỊCH SỬ: " : "HISTORY: ")
                         + c.historyOnly.map(\.displayName).joined(separator: ", "))
        }
        if !c.unavailable.isEmpty {
            parts.append((vi ? "CHƯA CÓ: " : "NO DATA: ")
                         + c.unavailable.map(\.displayName).joined(separator: ", "))
        }
        return parts.isEmpty ? (vi ? "Không khả dụng" : "Unavailable") : parts.joined(separator: " · ")
    }
    private func insightRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).font(.plexMono(12)) }
            .font(.plexSans(13)).foregroundStyle(SettingsTheme.primary)
            .padding(.vertical, 13).hairlineTop(SettingsTheme.hairline)
    }
}

struct InsightsProjectsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    let report: ProjectInsightsReport
    @Binding var days: Int
    @State private var selectedID: String?
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    private var ranking: [ProjectRankingRow] { report.ranking(days: days) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ranking.isEmpty {
                Text(vi ? "Chưa có chi phí dự án trong kỳ này." : "No project cost in this period.")
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 0) {
                        rankingHeader
                        ForEach(ranking) { row in projectButton(row) }
                    }
                    .frame(width: 300)
                    if let detail = selectedDetail {
                        projectDetail(detail)
                    }
                }
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: days) { _, _ in selectFirstIfNeeded(force: true) }
        .onChange(of: ranking.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private var rankingTotalUSD: Double { ranking.reduce(0) { $0 + $1.usd } }

    /// Fixed columns so icon / name / share% / $ stay aligned across rows.
    private enum RankCols {
        static let icon: CGFloat = 16
        static let pct: CGFloat = 44
        static let usd: CGFloat = 72
        static let gap: CGFloat = 10
    }

    private var rankingHeader: some View {
        HStack(spacing: RankCols.gap) {
            Color.clear.frame(width: RankCols.icon, height: 1)
            Text(vi ? "DỰ ÁN" : "PROJECT")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("%")
                .frame(width: RankCols.pct, alignment: .trailing)
            Text("$")
                .frame(width: RankCols.usd, alignment: .trailing)
        }
        .font(.plexMono(9, weight: .medium))
        .foregroundStyle(SettingsTheme.tertiary)
        .tracking(0.5)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .hairlineTop(SettingsTheme.hairline)
    }

    private var selectedDetail: ProjectUsageRecord? {
        let id = selectedID ?? ranking.first?.id
        return id.flatMap { report.detail(id: $0, days: days) }
    }
    private func projectButton(_ row: ProjectRankingRow) -> some View {
        let share = rankingTotalUSD > 0
            ? Int((row.usd / rankingTotalUSD * 100).rounded())
            : 0
        let selected = row.id == (selectedID ?? ranking.first?.id)
        return Button { selectedID = row.id } label: {
            HStack(alignment: .center, spacing: RankCols.gap) {
                ProviderLogoMark(id: row.source.rawValue, tint: sourceColor(row.source))
                    .frame(width: RankCols.icon, height: RankCols.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.plexSans(13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                        .lineLimit(1)
                    Text(row.source.displayName + (row.attribution == .unknown ? " · Unknown" : ""))
                        .font(.plexMono(9))
                        .foregroundStyle(SettingsTheme.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(share)%")
                    .font(.plexMono(11, weight: .medium))
                    .foregroundStyle(SettingsTheme.secondary)
                    .frame(width: RankCols.pct, alignment: .trailing)
                    .monospacedDigit()
                Text(AllUsageFormat.usd(row.usd))
                    .font(.plexMono(11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primary)
                    .frame(width: RankCols.usd, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(selected ? SettingsTheme.selectedSurface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairlineTop(SettingsTheme.hairline)
    }
    private func projectDetail(_ project: ProjectUsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.displayName).font(.plexSans(17, weight: .semibold)).lineLimit(1)
            Text(project.source.displayName).plexEyebrow()
            ForEach(project.daily.reversed()) { day in
                HStack {
                    Text(Self.dateFormatter.string(from: day.date)).font(.plexMono(10))
                    Spacer()
                    Text(AllUsageFormat.tokensAndUSD(day.tokens, day.usd)).font(.plexMono(10))
                }
                .padding(.vertical, 5).hairlineTop(SettingsTheme.hairline)
            }
            let models = Self.foldedModels(project.daily)
            if !models.isEmpty {
                Text(vi ? "MODEL" : "MODELS").plexEyebrow().padding(.top, 8)
                ForEach(models) { model in
                    HStack {
                        Text(AllUsageFormat.shortName(ProjectIdentity.safeModelName(model.name)))
                        Spacer()
                        Text(AllUsageFormat.tokensAndUSD(model.tokens, model.usd)) }
                        .font(.plexMono(10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    static func foldedModels(_ days: [ProjectDailyUsage]) -> [ProjectModelUsage] {
        var totals: [String: (Double, Int)] = [:]
        for day in days { for model in day.models {
            let old = totals[model.name] ?? (0, 0)
            totals[model.name] = (old.0 + model.usd, old.1 + model.tokens)
        }}
        return totals.map { ProjectModelUsage(name: $0.key, usd: $0.value.0, tokens: $0.value.1) }
            .sorted {
                if $0.usd != $1.usd { return $0.usd > $1.usd }
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                return $0.name < $1.name
            }
    }
    private func selectFirstIfNeeded(force: Bool = false) {
        if force || !ranking.contains(where: { $0.id == selectedID }) { selectedID = ranking.first?.id }
    }
    private func sourceColor(_ source: ProjectUsageSource) -> Color {
        switch source { case .claude: VocabbyTheme.chartClaude; case .codex: VocabbyTheme.chartCodex; case .grok: VocabbyTheme.chartGrok }
    }
    private static let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "yyyy-MM-dd"; return value
    }()
}
