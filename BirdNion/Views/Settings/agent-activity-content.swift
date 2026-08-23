import SwiftUI

struct AgentActivityContent: View {
    @EnvironmentObject private var settings: SettingsStore

    let records: [InstalledAgentRecord]
    let snapshot: AgentActivitySnapshot

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private static let colorSteps: [Color] = [
        Color(red: 0.94, green: 0.93, blue: 0.90), // #EFEDE6
        Color(red: 0.84, green: 0.87, blue: 0.95), // #D5DDF3
        Color(red: 0.66, green: 0.74, blue: 0.91), // #A9BCE8
        Color(red: 0.43, green: 0.55, blue: 0.86), // #6E8DDB
        Color(red: 0.12, green: 0.31, blue: 0.85)  // #1F4FD8
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Full-year 52-week heatmap
            fullYearHeatmapSection

            // Section 2: 4 Key Metric Cards
            keyMetricsSection

            // Section 3: Per-agent micro heatmaps
            perAgentHeatmapsSection
        }
        .padding(.vertical, 8)
    }

    // MARK: - Section 1: 52-Week Heatmap

    private var fullYearHeatmapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(vi ? "HOẠT ĐỘNG 52 TUẦN" : "52-WEEK ACTIVITY")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text("\(AllUsageFormat.usd(snapshot.overall.totalUSD)) · \(snapshot.overall.activeDays) \(vi ? "ngày active" : "active days")")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }

            // Month Labels Header
            HStack(spacing: 0) {
                Spacer().frame(width: 28)
                monthLabelsRow
            }

            // Heatmap Grid: Weekdays on left + 52-week columns
            HStack(alignment: .top, spacing: 6) {
                weekdayLabelsColumn
                heatmapColumns(cellSize: 10, cellGap: 2)
            }

            // Color scale legend
            HStack(spacing: 8) {
                Text(vi ? "ÍT" : "LESS")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                HStack(spacing: 2) {
                    ForEach(Self.colorSteps, id: \.self) { color in
                        Rectangle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                    }
                }
                Text(vi ? "NHIỀU" : "MORE")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text(vi ? "ĐẬM NHẠT THEO TOKEN, KHÔNG THEO USD" : "SHADED BY TOKENS, NOT USD")
                    .font(.plexMono(9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 6)
    }

    private var monthLabelsRow: some View {
        return HStack(spacing: 0) {
            ForEach(Array(snapshot.overall.weeks.enumerated()), id: \.element.id) { index, week in
                Color.clear
                    .frame(width: 12, height: 12)
                    .overlay(alignment: .leading) {
                        Text(monthLabel(for: week.startDate, at: index))
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
            }
        }
    }

    private func monthLabel(for date: Date, at index: Int) -> String {
        let calendar = Calendar.current
        if index > 0 {
            let previous = snapshot.overall.weeks[index - 1].startDate
            guard calendar.component(.month, from: previous) != calendar.component(.month, from: date)
            else { return "" }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = vi ? "'T'M" : "MMM"
        return formatter.string(from: date)
    }

    private var weekdayLabelsColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("T2").frame(height: 10)
            Text("").frame(height: 10)
            Text("T4").frame(height: 10)
            Text("").frame(height: 10)
            Text("T6").frame(height: 10)
            Text("").frame(height: 10)
            Text("CN").frame(height: 10)
        }
        .font(.plexMono(8))
        .foregroundStyle(VocabbyTheme.tertiary)
        .frame(width: 22)
    }

    private func heatmapColumns(cellSize: CGFloat, cellGap: CGFloat) -> some View {
        let weeks = snapshot.overall.weeks
        let maxTokens = max(snapshot.overall.days.map(\.tokens).max() ?? 1, 1)

        return HStack(spacing: cellGap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: cellGap) {
                    ForEach(week.days) { day in
                        let fraction = day.hasEvidence && day.tokens > 0
                            ? Double(day.tokens) / Double(maxTokens)
                            : 0
                        Rectangle()
                            .fill(colorForFraction(fraction))
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }

    // MARK: - Section 2: Key Metric Cards

    private var keyMetricsSection: some View {
        let peakUSD = snapshot.overall.peakDay?.usd ?? 0
        let peakDay = snapshot.overall.peakDay
        let avgPerActiveDay = snapshot.overall.activeDays > 0
            ? snapshot.overall.totalUSD / Double(snapshot.overall.activeDays)
            : 0

        return HStack(spacing: 0) {
            metricCard(
                title: vi ? "NGÀY CAO NHẤT" : "PEAK DAY",
                value: AllUsageFormat.usd(peakUSD),
                sub: peakUSD > 0 ? (vi ? "Trong 52 tuần" : "In 52 weeks") : "—"
            )
            divider
            metricCard(
                title: vi ? "TB / NGÀY ACTIVE" : "AVG / ACTIVE DAY",
                value: AllUsageFormat.usd(avgPerActiveDay),
                sub: "\(snapshot.overall.activeDays) / 365 \(vi ? "ngày" : "days")"
            )
            divider
            metricCard(
                title: vi ? "STREAK HIỆN TẠI" : "CURRENT STREAK",
                value: "\(snapshot.overall.currentStreak) \(vi ? "ngày" : "days")",
                sub: vi
                    ? "Dài nhất \(snapshot.overall.longestStreak) ngày"
                    : "Longest \(snapshot.overall.longestStreak) days"
            )
            divider
            metricCard(
                title: vi ? "NGÀY BẬN NHẤT" : "BUSIEST DAY",
                value: peakDay.map { shortDate($0.date) } ?? "—",
                sub: peakDay.map { AllUsageFormat.tokens($0.tokens) } ?? "—"
            )
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { VocabbyTheme.primary.frame(height: 1) }
        .overlay(alignment: .bottom) { VocabbyTheme.hairline.frame(height: 1) }
    }

    private func metricCard(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.plexMono(9, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
            Text(value)
                .font(.plexMono(18, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
                .tracking(-0.4)
                .lineLimit(1)
            Text(sub)
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var divider: some View {
        VocabbyTheme.hairline
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    // MARK: - Section 3: Per-agent Micro Heatmaps

    private var perAgentHeatmapsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(vi ? "NHỊP THEO AGENT" : "RHYTHM BY AGENT")
                    .font(.plexMono(10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text(vi ? "cùng thang màu, 52 tuần" : "same color scale, 52 weeks")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .padding(.bottom, 2)

            ForEach(visibleCostAgents) { record in
                let window = snapshot.byAgent[record.id]
                let totalUSD = window?.totalUSD ?? 0
                let activeDays = window?.activeDays ?? 0

                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        agentMark(record.id)
                        Text(record.displayName)
                            .font(.plexSans(13, weight: .medium))
                            .foregroundStyle(VocabbyTheme.primary)
                            .lineLimit(1)
                    }
                    .frame(width: 132, alignment: .leading)

                    microHeatmap(for: window)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(AllUsageFormat.usd(totalUSD))
                            .font(.plexMono(12, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.primary)
                        Text("\(activeDays) " + (vi ? "NGÀY" : "DAYS"))
                            .font(.plexMono(9))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                    .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { VocabbyTheme.hairline.frame(height: 1) }
            }

            Text(vi
                 ? "Các agent chỉ có cấu hình không xuất hiện ở đây — không có log để dựng nhịp."
                 : "Config-only agents are omitted here — no logs to reconstruct activity rhythm.")
                .font(.plexMono(11))
                .foregroundStyle(VocabbyTheme.tertiary)
                .padding(.top, 6)
        }
    }

    private var visibleCostAgents: [InstalledAgentRecord] {
        records.filter { snapshot.byAgent[$0.id] != nil }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("ddMMM")
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func agentMark(_ id: InstalledAgentID) -> some View {
        if hasBrandLogo(id) {
            ProviderLogoMark(id: id.rawValue)
                .frame(width: 16, height: 16)
        } else {
            Text(monogram(for: id))
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .frame(width: 16, height: 16)
                .overlay {
                    Rectangle().stroke(VocabbyTheme.border, lineWidth: 1)
                }
        }
    }

    private func microHeatmap(for window: AgentActivityWindow?) -> some View {
        let weeks = window?.weeks ?? snapshot.overall.weeks
        let maxTokens = max(weeks.flatMap(\.days).map(\.tokens).max() ?? 1, 1)

        return HStack(spacing: 1) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 1) {
                    ForEach(week.days) { day in
                        let fraction = day.hasEvidence && day.tokens > 0
                            ? Double(day.tokens) / Double(maxTokens)
                            : 0
                        Rectangle()
                            .fill(colorForFraction(fraction))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    private func colorForFraction(_ f: Double) -> Color {
        if f <= 0 { return Self.colorSteps[0] }
        if f <= 0.25 { return Self.colorSteps[1] }
        if f <= 0.50 { return Self.colorSteps[2] }
        if f <= 0.75 { return Self.colorSteps[3] }
        return Self.colorSteps[4]
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
