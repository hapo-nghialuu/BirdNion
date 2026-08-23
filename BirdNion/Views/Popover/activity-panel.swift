import SwiftUI

struct ActivityPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let window: AgentActivityWindow

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    private static let colorSteps: [Color] = [
        Color(red: 0.94, green: 0.93, blue: 0.90), // #EFEDE6
        Color(red: 0.84, green: 0.87, blue: 0.95), // #D5DDF3
        Color(red: 0.66, green: 0.74, blue: 0.91), // #A9BCE8
        Color(red: 0.43, green: 0.55, blue: 0.86), // #6E8DDB
        Color(red: 0.12, green: 0.31, blue: 0.85)  // #1F4FD8
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            subHeader
            weekdayHeaderRow
            ScrollView(.vertical, showsIndicators: true) {
                weeksGrid
            }
            legendRow
            footerStats
        }
        .frame(width: 340)
        .frame(minHeight: 460, maxHeight: 600)
        .background(VocabbyTheme.background)
        .overlay(
            Rectangle()
                .stroke(VocabbyTheme.primary, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vi ? "Hoạt động" : "Activity")
                    .font(.plexSans(14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text("\(window.weeks.count) \(vi ? "TUẦN" : "WEEKS") · \(window.activeDays) \(vi ? "NGÀY ACTIVE" : "ACTIVE DAYS")")
                    .font(.plexMono(10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .birdnionCloseAgentDetail, object: nil)
            } label: {
                Text("×")
                    .font(.plexMono(16))
                    .foregroundStyle(VocabbyTheme.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { VocabbyTheme.primary.frame(height: 1) }
    }

    private var subHeader: some View {
        HStack {
            Text(vi ? "LỊCH HOẠT ĐỘNG" : "ACTIVITY LEDGER")
                .font(.plexMono(9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(VocabbyTheme.primary)
                .foregroundStyle(VocabbyTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: InstrumentShape.controlRadius))

            Spacer()
            Text(AllUsageFormat.usd(window.totalUSD))
                .font(.plexMono(10))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { VocabbyTheme.hairline.frame(height: 1) }
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 3) {
            Spacer().frame(width: 26)
            Text("T2").frame(width: 18)
            Text("T3").frame(width: 18)
            Text("T4").frame(width: 18)
            Text("T5").frame(width: 18)
            Text("T6").frame(width: 18)
            Text("T7").frame(width: 18)
            Text("CN").frame(width: 18)
            Spacer()
            Text(vi ? "TUẦN" : "WEEK")
                .font(.plexMono(8))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .font(.plexMono(8))
        .foregroundStyle(VocabbyTheme.tertiary)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var weeksGrid: some View {
        let maxTokens = max(window.weeks.map(\.tokens).max() ?? 1, 1)

        return VStack(spacing: 3) {
            ForEach(Array(window.weeks.enumerated()), id: \.offset) { index, week in
                HStack(spacing: 3) {
                    Text(monthLabel(for: week.startDate, index: index))
                        .font(.plexMono(9, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .frame(width: 26, alignment: .leading)

                    ForEach(0..<7) { dayIndex in
                        let fraction = week.hasEvidence && week.tokens > 0
                            ? Double(week.tokens) / Double(maxTokens) * (dayIndex < 5 ? 1.0 : 0.4)
                            : 0
                        Rectangle()
                            .fill(colorForFraction(fraction))
                            .frame(width: 18, height: 18)
                    }

                    Spacer()

                    Text(AllUsageFormat.usd(week.usd))
                        .font(.plexMono(10, weight: .medium))
                        .foregroundStyle(week.usd > 1000 ? Color(red: 0.56, green: 0.37, blue: 0.07) : VocabbyTheme.primary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 4)
    }

    private var legendRow: some View {
        HStack(spacing: 8) {
            Text(vi ? "ÍT" : "LESS")
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
            HStack(spacing: 2) {
                ForEach(Self.colorSteps, id: \.self) { color in
                    Rectangle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                }
            }
            Text(vi ? "NHIỀU" : "MORE")
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
            Spacer()
            Text(vi ? "cuộn xem 52 tuần" : "scroll for 52 weeks")
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { VocabbyTheme.hairline.frame(height: 1) }
    }

    private var footerStats: some View {
        let active = window.weeks.filter { $0.usd > 0 || $0.tokens > 0 }
        let peak = window.weeks.map(\.usd).max() ?? 0
        let avg = active.isEmpty ? 0 : window.totalUSD / Double(max(window.activeDays, 1))

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(vi ? "CAO NHẤT" : "PEAK")
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(AllUsageFormat.usd(peak))
                    .font(.plexMono(13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VocabbyTheme.hairline.frame(width: 1).padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(vi ? "TB/NGÀY" : "AVG/DAY")
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text(AllUsageFormat.usd(avg))
                    .font(.plexMono(13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)

            VocabbyTheme.hairline.frame(width: 1).padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("STREAK")
                    .font(.plexMono(9, weight: .medium))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Text("\(window.activeDays) " + (vi ? "ngày" : "days"))
                    .font(.plexMono(13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { VocabbyTheme.primary.frame(height: 1) }
    }

    private func colorForFraction(_ f: Double) -> Color {
        if f <= 0 { return Self.colorSteps[0] }
        if f <= 0.25 { return Self.colorSteps[1] }
        if f <= 0.50 { return Self.colorSteps[2] }
        if f <= 0.75 { return Self.colorSteps[3] }
        return Self.colorSteps[4]
    }

    private func monthLabel(for date: Date, index: Int) -> String {
        if index % 4 == 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
            formatter.dateFormat = "MMM"
            return formatter.string(from: date)
        }
        return ""
    }
}
