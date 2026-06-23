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
                    ProgressView().controlSize(.small).tint(VocabbyTheme.orange)
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

/// Vocabby color palette + reusable card style.
enum VocabbyTheme {
    static let background = Color(red: 0.984, green: 0.965, blue: 0.933)  // #FBF6EE
    static let card       = Color.white
    static let primary    = Color(red: 0.122, green: 0.122, blue: 0.180)   // #1F1F2E navy
    static let secondary  = Color(red: 0.420, green: 0.447, blue: 0.502)   // #6B7280
    static let tertiary   = Color(red: 0.620, green: 0.643, blue: 0.690)   // #9EA4AE
    static let orange     = Color(red: 0.976, green: 0.451, blue: 0.086)   // #F97316
    static let orangeSoft = Color(red: 0.984, green: 0.572, blue: 0.235)   // #FB923C
    static let green      = Color(red: 0.063, green: 0.725, blue: 0.506)   // #10B981
    static let track      = Color(red: 0.890, green: 0.906, blue: 0.918)   // #E3E7EA
    static let badge      = Color(red: 0.984, green: 0.973, blue: 0.949)   // #FBF8F2
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Hexagon badge
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VocabbyTheme.orange)
                    .frame(width: 40, height: 44)
                Text("AI")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Statusbar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text("Lv. 1 · \(footerText)")
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.secondary)
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
                    .fill(status.error != nil ? .red : VocabbyTheme.green)
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
/// 2-column footer (used left, reset right).
struct WindowRow: View {
    let window: QuotaWindow

    /// Vocabby uses GREEN for "remaining/progress" (e.g. "ĐỘ ĐỔI 90%")
    /// and ORANGE for "usage/EXP" (e.g. "EXP 147/300"). We map:
    ///   - "5 giờ" (session, remaining)  → green
    ///   - "Tuần"  (weekly, used)        → orange
    /// Multi-model labels (e.g. "general Tuần") use `contains` instead of
    /// exact match so the same color mapping applies per-model.
    private var isOrange: Bool { window.label.contains("Tuần") }

    private var barColor: Color {
        isOrange ? VocabbyTheme.orange : VocabbyTheme.green
    }
    private var barFill: Double { isOrange ? Double(window.usedPct) : Double(window.remainingPct) }

    private var resetText: String {
        if window.label.contains("Tuần") { return "Resets weekly" }
        if window.label.contains("5 giờ") { return "Resets in 5h" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .tracking(0.5)
                Spacer()
                Text(isOrange
                     ? "\(window.usedPct)%"
                     : "\(window.remainingPct)%")
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
                        .frame(width: max(0, geo.size.width * CGFloat(barFill) / 100), height: 8)
                }
            }
            .frame(height: 8)
            HStack(alignment: .firstTextBaseline) {
                Text(isOrange
                     ? "Đã dùng \(window.usedPct)%"
                     : "Đã dùng \(window.usedPct)%")
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
                .background(VocabbyTheme.orange)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                FooterMenuItem(icon: "plus.circle", label: "Add") { }
                FooterMenuItem(icon: "arrow.clockwise", label: "Refresh") {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(VocabbyTheme.secondary)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(VocabbyTheme.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let aistatusbarRefresh = Notification.Name("com.local.aistatusbar.refresh")
}
