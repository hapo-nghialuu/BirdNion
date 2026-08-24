import SwiftUI

struct ActivityPanelRoot: View {
    @EnvironmentObject var settings: SettingsStore
    let window: AgentActivityWindow

    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }
    /// Ô ngày được click — hiện dòng chi tiết dưới heatmap.
    @State private var selectedDay: AgentActivityDay?

    private static let colorSteps: [Color] = [
        Color(red: 0.94, green: 0.93, blue: 0.90), // #EFEDE6
        Color(red: 0.84, green: 0.87, blue: 0.95), // #D5DDF3
        Color(red: 0.66, green: 0.74, blue: 0.91), // #A9BCE8
        Color(red: 0.43, green: 0.55, blue: 0.86), // #6E8DDB
        Color(red: 0.12, green: 0.31, blue: 0.85)  // #1F4FD8
    ]

    /// Heatmap ngang kiểu GitHub: tuần = cột, 7 hàng thứ — gọn, không cột
    /// tiền chiếm chỗ; giá trị từng ô nằm ở tooltip, tổng ở subheader/footer.
    private static let cellSize: CGFloat = 10
    private static let cellGap: CGFloat = 2
    /// Số cột tuần vừa khít 340 − 2×14 inset − cột nhãn thứ (26).
    private static let maxWeekColumns = 23

    var body: some View {
        VStack(spacing: 0) {
            header
            subHeader
            // Vượt quá 23 cột thì wrap xuống band heatmap tiếp theo bên dưới,
            // tất cả band dùng chung thang màu.
            ForEach(Array(weekBands.enumerated()), id: \.offset) { _, band in
                heatmapBlock(weeks: band)
                rangeRow(weeks: band)
            }
            if let day = selectedDay {
                selectedDayRow(day)
            }
            legendRow
            footerStats
        }
        .frame(width: 340)
        .background(VocabbyTheme.background)
        // Không viền ngoài — đồng bộ style với các panel con khác.
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: InstrumentShape.controlRadius)
                            .stroke(VocabbyTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { VocabbyTheme.chromeRule.frame(height: 1) }
    }

    /// Heatmap bắt đầu từ tuần có dữ liệu đầu tiên — không vẽ cả năm trống.
    private var meaningfulWeeks: [AgentActivityWeek] {
        guard let first = window.weeks.firstIndex(where: { $0.hasEvidence }) else {
            return Array(window.weeks.suffix(Self.maxWeekColumns))
        }
        return Array(window.weeks[first...])
    }

    /// Cắt thành các band 23 cột — band sau (mới hơn) nằm dưới band trước.
    private var weekBands: [[AgentActivityWeek]] {
        stride(from: 0, to: meaningfulWeeks.count, by: Self.maxWeekColumns).map { start in
            Array(meaningfulWeeks[start..<min(start + Self.maxWeekColumns, meaningfulWeeks.count)])
        }
    }

    private var subHeader: some View {
        HStack {
            // Eyebrow thường — badge nền đen cũ render chữ đen trên nền đen.
            Text((vi ? "LỊCH HOẠT ĐỘNG · " : "ACTIVITY · ") + "\(meaningfulWeeks.count) " + (vi ? "TUẦN" : "WEEKS"))
                .font(.plexMono(10, weight: .medium))
                .foregroundStyle(VocabbyTheme.tertiary)
                .tracking(0.6)
            Spacer()
            Text(AllUsageFormat.usd(window.totalUSD))
                .font(.plexMono(12, weight: .semibold))
                .foregroundStyle(VocabbyTheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            VocabbyTheme.hairline.frame(height: 1).padding(.horizontal, 14)
        }
    }

    /// Grid ngang: cột nhãn thứ bên trái (T2/T4/T6/CN) + mỗi tuần một cột 7 ô.
    private func heatmapBlock(weeks: [AgentActivityWeek]) -> some View {
        // Thang màu chung cho MỌI band — so sánh được giữa các band.
        let maxTokens = max(window.days.map(\.tokens).max() ?? 1, 1)

        return HStack(alignment: .top, spacing: Self.cellGap) {
            VStack(alignment: .leading, spacing: Self.cellGap) {
                ForEach(0..<7, id: \.self) { row in
                    Text([0: "T2", 2: "T4", 4: "T6", 6: "CN"][row] ?? "")
                        .font(.plexMono(8))
                        .foregroundStyle(VocabbyTheme.tertiary)
                        .frame(width: 22, height: Self.cellSize, alignment: .leading)
                }
            }
            ForEach(weeks) { week in
                VStack(spacing: Self.cellGap) {
                    ForEach(week.days) { day in
                        let fraction = day.hasEvidence && day.tokens > 0
                            ? Double(day.tokens) / Double(maxTokens)
                            : 0
                        Rectangle()
                            .fill(colorForFraction(fraction))
                            .frame(width: Self.cellSize, height: Self.cellSize)
                            .overlay(
                                Rectangle().stroke(
                                    selectedDay?.date == day.date ? VocabbyTheme.primary : Color.clear,
                                    lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedDay = (selectedDay?.date == day.date) ? nil : day
                                NotificationCenter.default.post(name: .birdnionAgentPanelRefit, object: nil)
                            }
                            .help(dayHelp(day))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Mốc thời gian 2 đầu của band.
    private func rangeRow(weeks: [AgentActivityWeek]) -> some View {
        HStack {
            if let first = weeks.first?.days.first {
                Text(dayLabel(first.date))
            }
            Spacer(minLength: 8)
            if let last = weeks.last?.days.last {
                Text(dayLabel(last.date))
            }
        }
        .font(.plexMono(9))
        .foregroundStyle(VocabbyTheme.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// Chi tiết ngày được click: thứ + ngày, token, tiền.
    private func selectedDayRow(_ day: AgentActivityDay) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(VocabbyTheme.blue).frame(width: 3, height: 12)
            Text(fullDayLabel(day.date))
                .font(.plexSans(12, weight: .medium))
                .foregroundStyle(VocabbyTheme.primary)
            Spacer(minLength: 8)
            if day.isActive {
                Text("\(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))")
                    .font(.plexMono(11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
            } else {
                Text(vi ? "Không hoạt động" : "No activity")
                    .font(.plexMono(11))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            VocabbyTheme.hairline.frame(height: 1).padding(.horizontal, 14)
        }
    }

    private func fullDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = "EEEE, d MMM"
        return formatter.string(from: date).capitalized
    }

    private func dayHelp(_ day: AgentActivityDay) -> String {
        let date = dayLabel(day.date)
        guard day.isActive else { return date + (vi ? ": không hoạt động" : ": no activity") }
        return "\(date): \(AllUsageFormat.tokens(day.tokens)) · \(AllUsageFormat.usd(day.usd))"
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: vi ? "vi_VN" : "en_US")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
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
            Text(vi ? "đậm nhạt theo token" : "intensity by tokens")
                .font(.plexMono(9))
                .foregroundStyle(VocabbyTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            VocabbyTheme.hairline.frame(height: 1).padding(.horizontal, 14)
        }
    }

    private var footerStats: some View {
        let peak = window.peakDay?.usd ?? 0
        let avg = window.activeDays == 0 ? 0 : window.totalUSD / Double(window.activeDays)

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
                // Nổi bật streak bằng màu accent + đếm ngược tới kỷ lục.
                Text("\(window.currentStreak) " + (vi ? "ngày" : "days"))
                    .font(.plexMono(13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.blue)
                if window.currentStreak > 0 {
                    if window.currentStreak >= window.longestStreak {
                        Text(vi ? "ĐANG LÀ KỶ LỤC" : "RECORD PACE")
                            .font(.plexMono(8, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.success)
                            .tracking(0.4)
                    } else {
                        let remain = window.longestStreak - window.currentStreak + 1
                        Text(vi
                             ? "CÒN \(remain) NGÀY VƯỢT KỶ LỤC \(window.longestStreak)"
                             : "\(remain)D TO BEAT \(window.longestStreak)D BEST")
                            .font(.plexMono(8, weight: .medium))
                            .foregroundStyle(VocabbyTheme.tertiary)
                            .tracking(0.3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { VocabbyTheme.chromeRule.frame(height: 1) }
    }

    private func colorForFraction(_ f: Double) -> Color {
        if f <= 0 { return Self.colorSteps[0] }
        if f <= 0.25 { return Self.colorSteps[1] }
        if f <= 0.50 { return Self.colorSteps[2] }
        if f <= 0.75 { return Self.colorSteps[3] }
        return Self.colorSteps[4]
    }

}
