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
    /// Lazy-scanned Claude usage report (per-day buckets + top model) for
    /// the 30-day chart in the popover. Only re-scanned when the user
    /// opens Claude's tab; cached 5 min by `ClaudeCostScanner` itself.
    @State private var claudeReport: ClaudeUsageReport?
    @State private var claudeReportTaskId: String?

    var body: some View {
        ZStack {
            VocabbyTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                let selected = effectiveSelectedId()
                ProviderTabs(
                    providers: quota.displayStatuses,
                    selectedId: Binding(
                        get: { selected },
                        set: { selectedProviderId = $0 }
                    )
                )
                if let s = quota.displayStatuses.first(where: { $0.id == selected })
                    ?? quota.displayStatuses.first {
                    VStack(alignment: .leading, spacing: 6) {
                        ProviderHeaderCard(status: s, isPlaceholder: s.windows.isEmpty && s.error == nil)
                        ProviderCard(status: s)
                        // Claude-specific: 30-day chart + top-model line.
                        // Only rendered for the Claude tab so other providers
                        // don't pull in the local session scan.
                        if s.id == "claude", let report = claudeReport,
                           !report.isEmpty {
                            ClaudeUsageChartCard(report: report)
                        }
                    }
                }
                Spacer(minLength: 0)
                ActionsList()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear {
            if selectedProviderId == nil,
               let first = quota.displayStatuses.first {
                selectedProviderId = first.id
            }
        }
        .onChange(of: selectedProviderId) { id in
            triggerClaudeReportIfNeeded(providerId: id ?? "")
        }
        .onChange(of: quota.displayStatuses.map(\.id)) { ids in
            if let sel = selectedProviderId, !ids.contains(sel) {
                selectedProviderId = ids.first
                triggerClaudeReportIfNeeded(providerId: selectedProviderId ?? "")
            } else if selectedProviderId == nil {
                selectedProviderId = ids.first
                triggerClaudeReportIfNeeded(providerId: selectedProviderId ?? "")
            }
        }
        .task {
            triggerClaudeReportIfNeeded(providerId: selectedProviderId ?? effectiveSelectedId())
        }
    }

    /// Trigger the Claude 30-day scan only when the user actually views the
    /// Claude tab. The scanner is cached internally so re-opening Claude
    /// within 5 min is instant. Switching to another provider cancels any
    /// in-flight scan via the taskId guard.
    private func triggerClaudeReportIfNeeded(providerId: String) {
        guard providerId == "claude" else {
            claudeReport = nil
            return
        }
        let taskId = UUID().uuidString
        claudeReportTaskId = taskId
        Task {
            let report = await ClaudeCostScanner.usageReport()
            await MainActor.run {
                guard claudeReportTaskId == taskId else { return }
                claudeReport = report
            }
        }
    }

    private func effectiveSelectedId() -> String {
        if let sel = selectedProviderId,
           quota.displayStatuses.contains(where: { $0.id == sel }) {
            return sel
        }
        return quota.displayStatuses.first?.id ?? ""
    }
}

// MARK: - Provider Tabs

/// Tab chip over enabled providers. Layout (left-aligned rows):
///   [logo] MiniMax
///   [logo] 96% / 95%
/// Logo-only chip per provider. Fixed 44×44 so the tab row lines up
/// regardless of which provider is selected AND the hit area is large
/// enough to click reliably on macOS (36×36 was registering as a
/// near-miss on slower trackpads). Active chip gets the brand blue
/// background; inactive chips sit on a light badge background.
/// Status info (display name + quota %) used to render in the chip is
/// now in the provider header card below, so the chips stay compact.
struct ProviderTabs: View {
    static let chipSize: CGFloat = 44

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
            providerLogoView(for: p.id)
                .frame(width: 26, height: 26)
                .frame(width: Self.chipSize, height: Self.chipSize)
                .background(active ? VocabbyTheme.blue : VocabbyTheme.badge)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(active ? Color.clear : VocabbyTheme.track, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())  // whole chip is the click target
        .help(p.displayName)
        .accessibilityLabel(p.displayName)
    }

    /// Real brand logo per provider id. Falls back to a SF Symbol circle
/// when a provider has no bundled image asset.
    @ViewBuilder
    private func providerLogoView(for id: String) -> some View {
        switch id {
        case "minimax":
            Image("MiniMaxLogo").resizable().interpolation(.high)
        case "codex":
            Image("CodexLogo").resizable().interpolation(.high)
        case "hapo":
            Image("HapoLogo").resizable().interpolation(.high)
        case "openrouter":
            Image("OpenRouterLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.openRouter)
        case "deepseek":
            Image("DeepSeekLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.deepSeek)
        case "zai":
            Image("ZaiLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.zai)
        case "claude":
            Image("ClaudeLogo").resizable().interpolation(.high)
                .foregroundStyle(VocabbyTheme.claude)
        default:
            Image(systemName: "circle")
        }
    }
}

// MARK: - Provider Header Card

/// Provider info card: name + plan tier + last-updated + status pill.
struct ProviderHeaderCard: View {
    let status: ProviderStatus
    /// True when this is a placeholder entry — `statuses` hasn't received
    /// real data for this provider yet. The card shows a spinner in the
    /// subtitle area so the user knows the card is loading, but the rest
    /// of the popover stays interactive.
    var isPlaceholder: Bool = false
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
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                HStack(spacing: 4) {
                    if isPlaceholder {
                        // Only the provider whose data hasn't arrived yet
                        // shows the spinner — once its windows or error land
                        // in `statuses`, switch to the real subtitle even if
                        // other providers in the popover are still loading.
                        // The spinner is pinned to 12×12 because SwiftUI's
                        // macOS ProgressView otherwise stretches to fill its
                        // HStack slot (rendering a 50pt white disc behind the
                        // header card — observed in the wild).
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                            .frame(width: 12, height: 12)
                        Text("Đang tải…")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.secondary)
                    } else {
                        let subtitleParts = [status.accountLabel, planTier, updatedAgo]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                        Text(subtitleParts.joined(separator: " · "))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            MenuBarVisibilityToggle(providerId: status.id, hasError: hasError)
        }
        // Padding is tighter than the standard vocabbyCard (12pt) so the
        // taller 48pt logo doesn't grow the card height.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            Divider().padding(.vertical, 1)
            ActionRow(icon: "gearshape", label: "Settings…",
                      shortcut: "⌘,",
                      isLoading: false) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            Divider().padding(.vertical, 1)
            ActionRow(icon: "info.circle", label: "About BirdNion",
                      shortcut: nil,
                      isLoading: false) {
                AboutPresenter.show()
            }
            Divider().padding(.vertical, 1)
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
            HStack(spacing: 8) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small).tint(VocabbyTheme.blue)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(VocabbyTheme.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(VocabbyTheme.primary)
                Spacer()
                if let s = shortcut {
                    Text(s)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(VocabbyTheme.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Menu Bar Visibility Toggle

/// Toggle that controls whether this provider appears in the macOS menu
/// bar rotation. When the toggle is on, the provider's frame cycles
/// through the status bar; when off, it's hidden from the rotation.
/// Default state is read from `MenuBarVisibility` (UserDefaults-backed).
///
/// A small icon on the left reflects the provider's current fetch health
/// (green check when ok, red triangle when in error) so the toggle area
/// still surfaces status at a glance — this replaces the old OK pill.
struct MenuBarVisibilityToggle: View {
    let providerId: String
    let hasError: Bool

    @State private var isOn: Bool

    init(providerId: String, hasError: Bool) {
        self.providerId = providerId
        self.hasError = hasError
        self._isOn = State(initialValue: MenuBarVisibility.isShown(providerId: providerId))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hasError ? Color.red : VocabbyTheme.blue)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(isOn
                    ? "Provider này đang hiển thị trên menu bar. Tắt để ẩn."
                    : "Provider này đang ẩn khỏi menu bar. Bật để hiển thị.")
                .onChange(of: isOn) { newValue in
                    MenuBarVisibility.setShown(providerId: providerId, to: newValue)
                }
        }
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

    // Per-provider brand tints for the monochrome template logos.
    // Values mirror CodexBar's ProviderBranding.color.
    static let openRouter = Color(red: 100 / 255, green: 103 / 255, blue: 242 / 255) // #6467F2
    static let deepSeek   = Color(red: 0.32, green: 0.49, blue: 0.94)                // #527DF0
    static let zai        = Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255)  // #E85A6A
    static let claude     = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)  // #CC7C5E

    /// Brand tint for a provider id; nil → caller falls back to default styling.
    static func providerTint(_ id: String) -> Color? {
        switch id {
        case "codex": return blue
        case "openrouter": return openRouter
        case "deepseek": return deepSeek
        case "zai": return zai
        case "claude": return claude
        default: return nil
        }
    }
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

// MARK: - Claude usage chart

/// 30-day bar chart card sourced from `ClaudeCostScanner.usageReport()`.
/// Mirrors CodexBar's compact "Today / 30d cost / tokens / latest tokens"
/// header + a per-day USD bar series. The chart uses USD as the y-axis
/// (matches the screenshot reference) since token counts vary too wildly
/// between idle and busy days; tokens go in the top-right summary so
/// both signals are visible at a glance.
struct ClaudeUsageChartCard: View {
    let report: ClaudeUsageReport

    private var maxBarUSD: Double {
        max(report.daily.map(\.usd).max() ?? 0, 0.01)
    }

    private var latestDayTokens: Int {
        report.daily.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    private var todayLabel: String {
        guard let today = report.daily.last else { return "Hôm nay" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "d MMM"
        return "Hôm nay (\(f.string(from: today.date)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top summary row: today vs 30d cost + tokens.
            HStack(alignment: .top, spacing: 16) {
                summaryColumn(
                    label: todayLabel,
                    amount: report.todayUSD,
                    tokens: report.todayTokens)
                Spacer(minLength: 8)
                summaryColumn(
                    label: "30d cost",
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: "Latest tokens",
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            if let model = report.topModel {
                Text("Top model: \(model)")
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Text("Estimated from local Claude logs at API rates; token totals are exact, USD are approximate.")
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(VocabbyTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    @ViewBuilder
    private func summaryColumn(label: String, amount: Double?, tokens: Int,
                               alignTrailing: Bool = false) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VocabbyTheme.secondary)
                .tracking(0.3)
            if let amount {
                Text(formatUSD(amount))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VocabbyTheme.primary)
            }
            Text(formatTokens(tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(VocabbyTheme.tertiary)
        }
    }

    /// 30 vertical bars, one per day, height proportional to USD. Inactive
    /// days render as a faint 2pt baseline so the chart doesn't look broken
    /// when usage is sparse.
    private var barChart: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(report.daily) { day in
                    let heightFraction = day.usd > 0
                        ? CGFloat(day.usd / maxBarUSD)
                        : 0
                    let barHeight = max(geo.size.height * heightFraction, day.usd > 0 ? 3 : 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(for: day))
                        .frame(maxWidth: .infinity, maxHeight: geo.size.height, alignment: .bottom)
                        .frame(height: barHeight, alignment: .bottom)
                        .help("\(dayLabel(day.date)): \(formatUSD(day.usd)) · \(formatTokens(day.tokens))")
                }
            }
        }
    }

    private func barColor(for day: ClaudeDailyUsage) -> Color {
        let last30 = report.daily.last
        if day.date == last30?.date {
            // Today gets the brand blue so it stands out from the historical bars.
            return VocabbyTheme.blue
        }
        if day.usd == 0 {
            return VocabbyTheme.track.opacity(0.6)
        }
        return VocabbyTheme.yellow
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private func formatUSD(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "$%.0f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) + " tokens" }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) + " tokens" }
        return "\(n) tokens"
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let aistatusbarRefresh = Notification.Name("com.local.birdnion.refresh")
    /// Posted by the Settings sidebar when the provider list changes
    /// (reorder, toggle, add, remove). AppDelegate listens and rebuilds
    /// QuotaService.providers from disk so the popover + menu-bar pick up
    /// the new order without a restart.
    static let aistatusbarProvidersChanged = Notification.Name("com.local.birdnion.providersChanged")
}