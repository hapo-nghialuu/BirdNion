import SwiftUI
import AppKit

// MARK: - Quota Overview (CodexBar-style)

/// CodexBar-inspired popover body:
///   - Top: tabs over enabled providers (MiniMax / Hapo / ...).
///   - Below tabs: provider info card (name + plan + last updated + status pill).
///   - Then: per-window quota bars for the selected provider.
///   - Bottom: action list (Refresh · Settings · About · Quit).
struct QuotaOverview: View {
    @EnvironmentObject var quota: QuotaService
    @State private var selectedProviderId: String? = nil

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
                VStack(alignment: .leading, spacing: 8) {
                    // Default selection: first provider (kept across refreshes
                    // when the same id is still present).
                    let selected = effectiveSelectedId()
                    ProviderTabs(
                        providers: quota.statuses,
                        selectedId: Binding(
                            get: { selected },
                            set: { selectedProviderId = $0 }
                        )
                    )
                    if let s = quota.statuses.first(where: { $0.id == selected })
                        ?? quota.statuses.first {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                ProviderHeaderCard(status: s)
                                ProviderCard(status: s)
                            }
                        }
                    }
                    ActionsList()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            if selectedProviderId == nil,
               let first = quota.statuses.first {
                selectedProviderId = first.id
            }
        }
        .onChange(of: quota.statuses.map(\.id)) { ids in
            // If the previously-selected provider disappears (toggled off),
            // fall back to the first remaining one.
            if let sel = selectedProviderId, !ids.contains(sel) {
                selectedProviderId = ids.first
            } else if selectedProviderId == nil {
                selectedProviderId = ids.first
            }
        }
    }

    private func effectiveSelectedId() -> String {
        if let sel = selectedProviderId,
           quota.statuses.contains(where: { $0.id == sel }) {
            return sel
        }
        return quota.statuses.first?.id ?? ""
    }
}

// MARK: - Provider Tabs

/// Tab chip over enabled providers. Layout (left-aligned rows):
///   [logo] MiniMax
///   [logo] 96% / 95%
/// Logo = SF Symbol per provider id (sparkles for MiniMax, bolt for
/// AIHub, circle fallback). Rounded rectangle instead of capsule so
/// the chip doesn't read as a pill — cornerRadius 8 keeps it modern
/// without going fully square.
struct ProviderTabs: View {
    let providers: [ProviderStatus]
    @Binding var selectedId: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(providers, id: \.id) { p in
                chip(for: p)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chip(for p: ProviderStatus) -> some View {
        let active = p.id == selectedId
        Button {
            selectedId = p.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    providerLogoView(for: p.id)
                        .frame(width: 17, height: 17)
                    Text(p.displayName)
                        .font(.system(size: 11, weight: .semibold))
                }
                if let s = chipSuffix(for: p) {
                    Text(s)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .opacity(0.85)
                        .padding(.leading, 16) // align under the name, past the logo
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(active ? .white : VocabbyTheme.primary)
            .background(active ? VocabbyTheme.blue : VocabbyTheme.badge)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if active {
                    Image("OriginalImage")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .offset(x: 5, y: -5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? Color.clear : VocabbyTheme.track, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Real brand logo per provider id. Falls back to a SF Symbol circle
/// when a provider has no bundled image asset.
    @ViewBuilder
    private func providerLogoView(for id: String) -> some View {
        switch id {
        case "minimax":
            Image("MiniMaxLogo").resizable().interpolation(.high)
        case "hapo":
            Image("HapoLogo").resizable().interpolation(.high)
        default:
            Image(systemName: "circle")
        }
    }

    /// Single-line quota summary. "lỗi" for error, "X% / Y%" for
    /// multi-window, just "X%" for single window, nil while loading.
    /// Labels (5h / tuần) are intentionally omitted — the chip is too
    /// compact to carry them and the colour-coded bar below already
    /// distinguishes cadence.
    private func chipSuffix(for p: ProviderStatus) -> String? {
        if p.error != nil { return "lỗi" }
        if p.windows.isEmpty { return nil }
        if p.windows.count == 1 {
            return "\(p.windows[0].remainingPct)%"
        }
        return p.windows
            .map { "\($0.remainingPct)%" }
            .joined(separator: " / ")
    }
}

// MARK: - Provider Header Card

/// Provider info card: name + plan tier + last-updated + status pill.
struct ProviderHeaderCard: View {
    let status: ProviderStatus
    @EnvironmentObject var quota: QuotaService

    private var updatedAgo: String {
        let secs = Int(Date().timeIntervalSince(status.lastUpdated))
        if secs < 5 { return "vừa cập nhật" }
        if secs < 60 { return "\(secs) giây trước" }
        if secs < 3600 { return "\(secs / 60) phút trước" }
        return "\(secs / 3600) giờ trước"
    }

    private var planTier: String {
        // Heuristic by provider id; expand when more providers are added.
        switch status.id {
        case "minimax": return "Token Plan"
        case "hapo":    return "Hapo AI Hub"
        default:        return ""
        }
    }

    private var hasError: Bool { status.error != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("ProviderLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                HStack(spacing: 4) {
                    if quota.isRefreshing {
                        ProgressView().controlSize(.mini).tint(VocabbyTheme.blue)
                    }
                    let subtitleParts = [status.accountLabel, planTier, updatedAgo]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                    Text(subtitleParts.joined(separator: " · "))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(VocabbyTheme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            StatusPill(ok: !hasError, errorCount: hasError ? 1 : 0)
        }
        // Padding is tighter than the standard vocabbyCard (12pt) so the
        // taller 50pt logo doesn't grow the card height.
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(VocabbyTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

// MARK: - Provider Card + Window Row (unchanged from before)

/// Per-provider card: name + windows.
struct ProviderCard: View {
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = status.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
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

/// Single quota window row.
struct WindowRow: View {
    let window: QuotaWindow

    private var isBlue: Bool { window.label.contains("Tuần") }
    private var barColor: Color {
        isBlue ? VocabbyTheme.blue : VocabbyTheme.yellow
    }

    private var subtitleText: String {
        if let s = window.subtitle, !s.isEmpty { return s }
        return "Còn \(window.remainingPct)%"
    }

    private var resetText: String {
        if let d = window.resetDate { return Self.formatReset(d) }
        if window.label.contains("Tuần") { return "Resets weekly" }
        if window.label.contains("5 giờ") { return "Resets in 5h" }
        return ""
    }

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

// MARK: - Actions List

/// Vertical action list (icon + label rows). CodexBar-style, matches the
/// footer menu of the reference app instead of the compact 4-icon row.
struct ActionsList: View {
    @EnvironmentObject var quota: QuotaService

    var body: some View {
        VStack(spacing: 0) {
            ActionRow(icon: quota.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                      label: "Refresh",
                      shortcut: nil,
                      isLoading: quota.isRefreshing) {
                NotificationCenter.default.post(name: .aistatusbarRefresh, object: nil)
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "gearshape", label: "Settings…",
                      shortcut: "⌘,",
                      isLoading: false) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "info.circle", label: "About BirdNion",
                      shortcut: nil,
                      isLoading: false) {
                AboutPresenter.show()
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "power", label: "Quit BirdNion",
                      shortcut: "⌘Q",
                      isLoading: false) {
                NSApp.terminate(nil)
            }
        }
        .background(VocabbyTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ActionRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer()
                if let s = shortcut {
                    Text(s)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Status Pill

/// Pill — blue "OK" or red "! N" depending on whether any provider is
/// currently in an error state.
struct StatusPill: View {
    let ok: Bool
    let errorCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(ok ? "OK" : "\(errorCount)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ok ? VocabbyTheme.blue : Color.red)
        .clipShape(Capsule())
    }
}

// MARK: - About

/// Shows a simple About panel via NSAlert. Avoids creating a dedicated
/// SwiftUI sheet for what amounts to a static info blob.
enum AboutPresenter {
    static func show() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        let alert = NSAlert()
        alert.messageText = "BirdNion"
        alert.informativeText = """
        Version \(version) (\(build))

        macOS menu bar app for tracking AI provider quota.
        Bright blue, bright yellow, near-white.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Đóng")
        alert.runModal()
    }
}

// MARK: - Theme

/// App color palette.
enum VocabbyTheme {
    static let background = Color(red: 0.898, green: 0.898, blue: 0.898)   // #E5E5E5
    static let card       = Color.white
    static let primary    = Color(red: 0.122, green: 0.122, blue: 0.180)   // #1F1F2E
    static let secondary  = Color(red: 0.420, green: 0.447, blue: 0.502)   // #6B7280
    static let tertiary   = Color(red: 0.620, green: 0.643, blue: 0.690)   // #9EA4AE
    static let blue       = Color(red: 0.282, green: 0.624, blue: 0.925)   // #489FEC
    static let blueSoft   = Color(red: 0.576, green: 0.773, blue: 0.992)   // #93C5FD
    static let yellow     = Color(red: 1.000, green: 0.804, blue: 0.298)   // #FFCD4C
    static let yellowSoft = Color(red: 1.000, green: 0.902, blue: 0.612)   // #FFE69C
    static let track      = Color(red: 0.898, green: 0.906, blue: 0.918)   // #E5E7EB
    static let badge      = Color(red: 0.976, green: 0.980, blue: 0.984)   // #F9FAFB
}

// MARK: - Card modifier

struct VocabbyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(VocabbyTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

extension View {
    func vocabbyCard() -> some View { modifier(VocabbyCard()) }
}

// MARK: - Notifications

extension Notification.Name {
    static let aistatusbarRefresh = Notification.Name("com.local.birdnion.refresh")
}