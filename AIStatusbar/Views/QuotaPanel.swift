import SwiftUI

/// Vocabby-inspired popover body:
///   - Cream (#FBF6EE) background
///   - Header card: provider name + level + last-updated
///   - Per-provider section cards: each window = a colored bar (green for
///     "remaining", orange for "used") with 2-column data
///   - Footer: orange "ĐANG DÙNG" pill button + menu items
struct QuotaPanel: View {
    @EnvironmentObject var quota: QuotaService

    var body: some View {
        ZStack {
            VocabbyTheme.background.ignoresSafeArea()
            if quota.statuses.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                    Text("Đang tải…")
                        .font(.system(size: 12))
                        .foregroundStyle(VocabbyTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Header card
                    HeaderCard(footerText: headerTime)
                    // Per-provider cards
                    ForEach(Array(quota.statuses.enumerated()), id: \.element.id) { _, s in
                        ProviderCard(status: s)
                    }
                    // Footer
                    FooterMenu()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private var headerTime: String {
        let secs: Int
        if let last = quota.statuses.map(\.lastUpdated).max() {
            secs = Int(Date().timeIntervalSince(last))
        } else { secs = 0 }
        if secs < 5 { return "vừa cập nhật" }
        if secs < 60 { return "\(secs) giây trước" }
        if secs < 3600 { return "\(secs / 60) phút trước" }
        return "\(secs / 3600) giờ trước"
    }
}

/// App color palette.
enum VocabbyTheme {
    static let background = Color(red: 0.988, green: 0.988, blue: 0.988)   // #FCFCFC
    static let card       = Color.white
    static let primary    = Color(red: 0.122, green: 0.122, blue: 0.180)   // #1F1F2E navy text
    static let secondary  = Color(red: 0.420, green: 0.447, blue: 0.502)   // #6B7280
    static let tertiary   = Color(red: 0.620, green: 0.643, blue: 0.690)   // #9EA4AE
    static let blue       = Color(red: 0.282, green: 0.624, blue: 0.925)   // #489FEC — bright blue (primary brand)
    static let blueSoft   = Color(red: 0.576, green: 0.773, blue: 0.992)   // #93C5FD
    static let yellow     = Color(red: 1.000, green: 0.804, blue: 0.298)   // #FFCD4C — bright yellow (accent)
    static let yellowSoft = Color(red: 1.000, green: 0.902, blue: 0.612)   // #FFE69C
    static let track      = Color(red: 0.898, green: 0.906, blue: 0.918)   // #E5E7EB
    static let badge      = Color(red: 0.976, green: 0.980, blue: 0.984)   // #F9FAFB
}

/// Card modifier with rounded corners and subtle shadow.
struct VocabbyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(VocabbyTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func vocabbyCard() -> some View { modifier(VocabbyCard()) }
}

/// Header card: title + level + last-updated.
struct HeaderCard: View {
    let footerText: String
    @EnvironmentObject var quota: QuotaService

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Hexagon badge
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VocabbyTheme.blue)
                    .frame(width: 40, height: 44)
                Text("AI")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BirdNion")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                HStack(spacing: 4) {
                    if quota.isRefreshing {
                        ProgressView().controlSize(.mini).tint(VocabbyTheme.blue)
                    }
                    Text(quota.isRefreshing ? "Đang làm mới…" : footerText)
                        .font(.system(size: 11))
                        .foregroundStyle(VocabbyTheme.secondary)
                }
            }
            Spacer()
        }
        .vocabbyCard()
    }
}

/// Per-provider card: name + 2 WindowBlock(s) + provider actions.
struct ProviderCard: View {
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Circle()
                    .fill(status.error != nil ? .red : VocabbyTheme.yellow)
                    .frame(width: 8, height: 8)
                Text(status.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer()
                if let err = status.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            if let err = status.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("Không thể tải quota")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            } else {
                ForEach(status.windows) { win in
                    WindowRow(window: win)
                }
            }
        }
        .vocabbyCard()
    }
}

/// Single quota window row inside a ProviderCard.
/// Vocabby style: 2-column header (label left, % right) + colored bar +
/// 2-column footer (subtitle left, reset right).
struct WindowRow: View {
    let window: QuotaWindow

    /// Color distinguishes the *cadence*:
    ///   - "5 giờ" (rolling interval)  → yellow (#FFCD4C)
    ///   - "Tuần"  (weekly)            → blue   (#489FEC)
    /// Both rows display `remainingPct`.
    private var isBlue: Bool { window.label.contains("Tuần") }

    private var barColor: Color {
        isBlue ? VocabbyTheme.blue : VocabbyTheme.yellow
    }

    /// Footer-left text. Prefers explicit subtitle from the provider
    /// (e.g. Hapo's "$16.19 / $20.00"); falls back to "Còn X%".
    private var subtitleText: String {
        if let s = window.subtitle, !s.isEmpty { return s }
        return "Còn \(window.remainingPct)%"
    }

    /// Footer-right text. Uses dynamic `resetDate` if the provider
    /// supplied one; otherwise a label-keyed default.
    private var resetText: String {
        if let d = window.resetDate { return Self.formatReset(d) }
        if window.label.contains("Tuần") { return "Resets weekly" }
        if window.label.contains("5 giờ") { return "Resets in 5h" }
        return ""
    }

    /// "Resets in 6d 1h" / "Resets in 2h 13m" / "Resets in 45m"
    private static func formatReset(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "Resets soon" }
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let mins = (secs % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(mins)m" }
        return "Resets in \(mins)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(window.remainingPct)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(VocabbyTheme.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(window.remainingPct) / 100), height: 8)
                }
            }
            .frame(height: 8)
            HStack(alignment: .firstTextBaseline) {
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
                Spacer()
                Text(resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
        }
    }
}

/// Footer: orange pill "ĐANG DÙNG" + menu items.
struct FooterMenu: View {
    @EnvironmentObject var quota: QuotaService

    var body: some View {
        VStack(spacing: 10) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Spacer()
                    Text("ĐANG DÙNG")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(VocabbyTheme.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                FooterMenuItem(icon: "plus.circle", label: "Add") { }
                FooterMenuItem(icon: quota.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                               label: "Refresh",
                               isLoading: quota.isRefreshing) {
                    NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
                }
                FooterMenuItem(icon: "gearshape", label: "Settings") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                FooterMenuItem(icon: "power", label: "Quit") { NSApp.terminate(nil) }
            }
        }
    }
}

struct FooterMenuItem: View {
    let icon: String
    let label: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VocabbyTheme.blue)
                        .frame(height: 16)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(VocabbyTheme.secondary)
                        .frame(height: 16)
                }
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

extension Notification.Name {
    static let aistatusbarRefresh = Notification.Name("com.local.birdnion.refresh")
}
