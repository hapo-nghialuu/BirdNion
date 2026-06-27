import SwiftUI
import AppKit

// MARK: - Quota Overview (CodexBar-style)

/// Menu-bar popover body:
///   - Top: BirdNion identity + manual refresh.
///   - Provider chips with lowest remaining quota.
///   - Selected provider metadata and quota summary/details.
///   - Bottom: app-level actions.
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
            VStack(alignment: .leading, spacing: 7) {
                if quota.displayStatuses.isEmpty {
                    // First-run / opt-in state. The bird logo + title + body
                    // + prominent Settings button are all contained in
                    // `EmptyProvidersState` (single fixed-size subview) so
                    // SwiftUI's hosting-view autosize doesn't re-trigger
                    // the NSISEngine recursion documented in
                    // `SettingsSceneRoot`. All interactive elements are
                    // inside one stable identity; the icon is decorative
                    // (`.accessibilityHidden`) so VoiceOver doesn't trip
                    // on the hover state.
                    EmptyProvidersState()
                        .frame(maxWidth: .infinity)
                } else {
                    BirdNionHeader(isRefreshing: quota.isRefreshing)
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
                        VStack(alignment: .leading, spacing: 8) {
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
                }
                Spacer(minLength: 0)
                ActionsList()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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

// MARK: - App Header

struct BirdNionHeader: View {
    @EnvironmentObject var settings: SettingsStore

    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("BirdNion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.primary)
                Text(isRefreshing
                     ? L10n.t("popover.updating", settings.appLanguage)
                     : L10n.t("popover.ready", settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .birdnionRefresh, object: nil)
            } label: {
                ZStack {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VocabbyTheme.blue)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(L10n.t("popover.refresh", settings.appLanguage))
            .accessibilityLabel(L10n.t("popover.refresh", settings.appLanguage))
        }
    }
}

// MARK: - Provider Tabs

/// Native-feeling segmented provider selector with icon + provider name.
struct ProviderTabs: View {
    static let chipHeight: CGFloat = 30

    let providers: [ProviderStatus]
    @Binding var selectedId: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    chip(for: provider)
                    if index < providers.count - 1 {
                        Divider()
                            .frame(height: 18)
                    }
                }
            }
            .background(VocabbyTheme.segment)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func chip(for p: ProviderStatus) -> some View {
        let active = p.id == selectedId
        Button {
            selectedId = p.id
        } label: {
            HStack(spacing: 5) {
                ProviderLogoMark(id: p.id)
                    .frame(width: 16, height: 16)
                Text(p.displayName)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 72, minHeight: Self.chipHeight)
            .padding(.horizontal, 7)
            .background(active ? VocabbyTheme.selectedSurface : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())  // whole chip is the click target
        .help(p.displayName)
        .accessibilityLabel(p.displayName)
    }
}

/// Real brand logo per provider id. Falls back to a SF Symbol circle when a
/// provider has no bundled image asset.
struct ProviderLogoMark: View {
    let id: String

    var body: some View {
        logo
            .aspectRatio(contentMode: .fit)
    }

    @ViewBuilder
    private var logo: some View {
        switch id {
        case "minimax":
            Image("MiniMaxLogo").resizable().interpolation(.high)
        case "codex":
            // Codex's SVG declares itself a template image so it can be
            // recoloured by .foregroundStyle(). The chip's parent stack
            // sometimes wins over the inherited tint, leaving the logo
            // rendered against the chip background as an empty disc.
            // Pass a fixed dark tint explicitly so the mark always shows.
            Image("CodexLogo").resizable().interpolation(.high)
                .colorMultiply(VocabbyTheme.primary)
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
            Image(systemName: "circle.fill")
                .foregroundStyle(VocabbyTheme.secondary)
        }
    }
}

enum ProviderStatusSummary {
    static func lowestWindow(_ status: ProviderStatus) -> QuotaWindow? {
        status.windows.min { $0.remainingPct < $1.remainingPct }
    }
}

// MARK: - Provider Header Card

/// Provider info card: brand mark + account metadata + menu-bar visibility.
struct ProviderHeaderCard: View {
    @EnvironmentObject var settings: SettingsStore

    let status: ProviderStatus
    /// True when this is a placeholder entry — `statuses` hasn't received
    /// real data for this provider yet. The card shows a spinner in the
    /// subtitle area so the user knows the card is loading, but the rest
    /// of the popover stays interactive.
    var isPlaceholder: Bool = false
    @EnvironmentObject var quota: QuotaService

    private var updatedAgo: String {
        L10n.relativeUpdated(from: status.lastUpdated, preference: settings.appLanguage)
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let account = status.accountLabel, !account.isEmpty {
            parts.append(account)
        }
        if let plan = planLabel {
            parts.append(plan)
        }
        if let source = status.sourceLabel, !source.isEmpty {
            parts.append(source)
        }
        parts.append(updatedAgo)
        return parts
    }

    private var planLabel: String? {
        if let name = status.planName, !name.isEmpty { return name }
        if let type = status.planType, !type.isEmpty { return type }
        switch status.id {
        case "minimax": return "Token Plan"
        case "hapo": return "Hapo AI Hub"
        default: return nil
        }
    }

    private var hasError: Bool { status.error != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderLogoMark(id: status.id)
                .frame(width: 24, height: 24)
                .padding(5)
                .background(VocabbyTheme.segment)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VocabbyTheme.border, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(status.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VocabbyTheme.primary)
                    if !isPlaceholder && quota.isRefreshing {
                        // Provider has last-known data; a refresh is in
                        // flight. Show a small inline spinner so the user
                        // knows the row is being updated, but keep the
                        // existing subtitle + quota windows visible.
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                            .frame(width: 10, height: 10)
                        Text(L10n.t("popover.updating", settings.appLanguage).lowercased())
                            .font(.system(size: 10))
                            .foregroundStyle(VocabbyTheme.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if isPlaceholder {
                        // First-time load for this provider — no previous
                        // data to show. Use a placeholder spinner so the
                        // popover makes clear which tab is still loading.
                        ProgressView()
                            .controlSize(.small)
                            .tint(VocabbyTheme.blue)
                            .frame(width: 12, height: 12)
                        Text(L10n.t("provider.loading", settings.appLanguage))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.secondary)
                    } else {
                        Text(metadataParts.joined(separator: " · "))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(VocabbyTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            MenuBarVisibilityToggle(providerId: status.id, hasError: hasError)
                .id("menuBarVis.\(status.id)")  // force fresh @State per provider
        }
        // Padding is tighter than the standard vocabbyCard (12pt) so the
        // taller 48pt logo doesn't grow the card height.
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Provider Card + Window Row

/// Per-provider card: name + windows.
struct ProviderCard: View {
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let err = status.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(VocabbyTheme.critical)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(VocabbyTheme.critical)
                        .lineLimit(2)
                }
            } else if status.windows.isEmpty {
                LoadingQuotaSkeleton()
            } else {
                QuotaSummaryStrip(status: status)
                Divider()
                    .overlay(VocabbyTheme.border)
                ForEach(status.windows) { win in
                    WindowRow(window: win, lastUpdated: status.lastUpdated)
                }
            }
        }
        .vocabbyCard()
    }
}

struct QuotaSummaryStrip: View {
    @EnvironmentObject var settings: SettingsStore

    let status: ProviderStatus

    private var lowest: QuotaWindow? {
        ProviderStatusSummary.lowestWindow(status)
    }

    private var tone: Color {
        VocabbyTheme.quotaColor(remaining: lowest?.remainingPct ?? 100)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("popover.lowestQuota", settings.appLanguage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VocabbyTheme.secondary)
                Text(lowest.map { L10n.windowLabel($0.label, preference: settings.appLanguage) } ?? status.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VocabbyTheme.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(lowest?.remainingPct ?? 0)%")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone)
        }
        .padding(.vertical, 1)
    }
}

struct LoadingQuotaSkeleton: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track)
                .frame(width: 124, height: 10)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track)
                .frame(height: 8)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(VocabbyTheme.track.opacity(0.75))
                .frame(width: 180, height: 8)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(L10n.t("popover.loadingQuota", settings.appLanguage))
    }
}

/// Single quota window row.
struct WindowRow: View {
    @EnvironmentObject var settings: SettingsStore

    let window: QuotaWindow
    /// Fetch timestamp from the parent `ProviderStatus` — used as the
    /// anchor for the `lastUpdated + windowSeconds` reset estimate when
    /// the API didn't return an explicit reset timestamp.
    let lastUpdated: Date

    private var barColor: Color {
        VocabbyTheme.quotaColor(remaining: window.remainingPct)
    }

    private var subtitleText: String {
        if let s = window.subtitle, !s.isEmpty { return s }
        return L10n.f("quota.used", settings.appLanguage, window.usedPct)
    }

    private var resetText: String {
        // 1. Use the API-provided reset timestamp when available.
        if let d = window.resetDate { return formatReset(d) }
        // 2. Fall back to `lastUpdated + windowSeconds` — the API didn't
        //    include a reset timestamp (e.g. Codex OAuth response sometimes
        //    omits it) but we know the window's nominal length. Computes
        //    against `lastUpdated` so the countdown tracks when the fetch
        //    happened rather than the absolute wall-clock at render time.
        if let secs = window.windowSeconds, secs > 0 {
            let estimate = lastUpdated.addingTimeInterval(TimeInterval(secs))
            return formatReset(estimate)
        }
        // 3. Last-resort label-based fallback for old providers that don't
        //    surface either resetDate or windowSeconds.
        if window.label.contains("Tuần") { return L10n.t("quota.resetWeekly", settings.appLanguage) }
        if window.label.contains("5 giờ") { return L10n.t("quota.resetIn5h", settings.appLanguage) }
        return ""
    }

    private func formatReset(_ date: Date) -> String {
        L10n.resetCountdown(to: date, preference: settings.appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.windowLabel(window.label, preference: settings.appLanguage))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VocabbyTheme.secondary)
                Spacer()
                Text("\(window.remainingPct)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(VocabbyTheme.track)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(window.remainingPct) / 100), height: 5)
                }
            }
            .frame(height: 5)
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
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "gearshape", label: L10n.t("popover.settings", settings.appLanguage),
                      shortcut: "⌘,",
                      isLoading: false) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "info.circle", label: L10n.t("popover.about", settings.appLanguage),
                      shortcut: nil,
                      isLoading: false) {
                AboutPresenter.show()
            }
            Divider().padding(.vertical, 2)
            ActionRow(icon: "power", label: L10n.t("popover.quit", settings.appLanguage),
                      shortcut: "⌘Q",
                      isLoading: false) {
                NSApp.terminate(nil)
            }
        }
        .background(VocabbyTheme.group)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VocabbyTheme.border, lineWidth: 1)
        )
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
            .padding(.vertical, 7)
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
    @EnvironmentObject var settings: SettingsStore

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
                .foregroundStyle(hasError ? VocabbyTheme.critical : VocabbyTheme.success)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(isOn
                    ? L10n.t("popover.visibilityOn", settings.appLanguage)
                    : L10n.t("popover.visibilityOff", settings.appLanguage))
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

        \(L10n.t("popover.aboutInfo"))
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("button.close"))
        alert.runModal()
    }
}

// MARK: - Theme

/// App color palette.
enum VocabbyTheme {
    // Fixed light macOS-style surfaces. Do not follow Dark Mode here because
    // the menu-bar popover should stay light and inspectable.
    static let background = Color(red: 0.949, green: 0.949, blue: 0.953)   // #F2F2F3
    static let card       = Color.white
    static let group      = Color(red: 0.992, green: 0.992, blue: 0.996)   // #FDFDFE
    static let segment    = Color(red: 0.925, green: 0.925, blue: 0.933)   // #ECECEF
    static let primary    = Color(red: 0.114, green: 0.114, blue: 0.122)   // #1D1D1F
    static let secondary  = Color(red: 0.431, green: 0.431, blue: 0.451)   // #6E6E73
    static let tertiary   = Color(red: 0.557, green: 0.557, blue: 0.576)   // #8E8E93
    static let blue       = Color(red: 0.039, green: 0.518, blue: 1.000)   // #0A84FF
    static let selectedSurface = Color(red: 0.910, green: 0.949, blue: 1.000) // #E8F2FF
    static let yellow     = Color(red: 1.000, green: 0.624, blue: 0.039)   // #FF9F0A
    static let success    = Color(red: 0.204, green: 0.780, blue: 0.349)   // #34C759
    static let critical   = Color(red: 1.000, green: 0.271, blue: 0.227)   // #FF453A
    static let track      = Color(red: 0.898, green: 0.898, blue: 0.918)   // #E5E5EA
    static let badge      = Color(red: 0.969, green: 0.969, blue: 0.980)   // #F7F7FA
    static let border     = Color(red: 0.827, green: 0.827, blue: 0.850)   // #D3D3D9

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

    static func quotaColor(remaining: Int) -> Color {
        if remaining <= 20 { return critical }
        if remaining <= 50 { return yellow }
        return success
    }
}

// MARK: - Card modifier

struct VocabbyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(VocabbyTheme.group)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(VocabbyTheme.border, lineWidth: 1)
            )
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
    @EnvironmentObject var settings: SettingsStore

    let report: ClaudeUsageReport

    private var maxBarUSD: Double {
        max(report.daily.map(\.usd).max() ?? 0, 0.01)
    }

    private var latestDayTokens: Int {
        report.daily.last(where: { $0.tokens > 0 })?.tokens ?? 0
    }

    private var todayLabel: String {
        guard let today = report.daily.last else { return L10n.t("chart.today", settings.appLanguage) }
        return L10n.f("chart.todayWithDate", settings.appLanguage, L10n.dayMonth(today.date, preference: settings.appLanguage))
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
                    label: L10n.t("chart.last30Cost", settings.appLanguage),
                    amount: report.last30USD,
                    tokens: report.last30Tokens,
                    alignTrailing: true)
                Spacer(minLength: 8)
                summaryColumn(
                    label: L10n.t("chart.latestTokens", settings.appLanguage),
                    amount: nil,
                    tokens: latestDayTokens,
                    alignTrailing: true)
            }
            barChart
                .frame(height: 56)
            if let model = report.topModel {
                Text(L10n.f("chart.topModel", settings.appLanguage, model))
                    .font(.system(size: 10))
                    .foregroundStyle(VocabbyTheme.secondary)
            }
            Text(L10n.t("chart.estimate", settings.appLanguage))
                .font(.system(size: 9))
                .foregroundStyle(VocabbyTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .vocabbyCard()
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
        L10n.dayMonth(date, preference: settings.appLanguage)
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
    static let birdnionRefresh = Notification.Name("com.local.birdnion.refresh")
    /// Posted by `CodexAccountStore.setActive` when the active Codex account
    /// changes. QuotaService swaps in that account's cached snapshot for an
    /// instant card update, then refreshes.
    static let birdnionCodexAccountChanged = Notification.Name("com.local.birdnion.codexAccountChanged")
    /// Posted by the Settings sidebar when the provider list changes
    /// (reorder, toggle, add, remove). AppDelegate listens and rebuilds
    /// QuotaService.providers from disk so the popover + menu-bar pick up
    /// the new order without a restart.
    static let birdnionProvidersChanged = Notification.Name("com.local.birdnion.providersChanged")
}

// MARK: - Empty State

/// Shown by `QuotaOverview` when no provider is enabled (first-run / opt-in
/// state). Intentionally one self-contained subview with a stable identity
/// so the hosting view in the NSPanel can lay it out once without
/// re-entering the NSISEngine recursion loop.
///
/// Plain macOS-style empty state:
///   - Big bird logo at the top
///   - Bold title + secondary body (no tinted card)
///   - Compact primary CTA
///
struct EmptyProvidersState: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            // Bird logo. `OriginalImage` is the same artwork bundled in
            // the menu bar icon — re-uses the asset so the empty state and
            // the menu bar look consistent.
            Image("OriginalImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(L10n.t("popover.noProviders", settings.appLanguage))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(VocabbyTheme.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("popover.noProvidersBody", settings.appLanguage))
                    .font(.system(size: 12))
                    .foregroundStyle(VocabbyTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            // Primary CTA. Compact (not full-width) so it doesn't
            // dominate the empty state. Posts `.openSettings` — same
            // notification the "Settings…" row below uses, so the click
            // reliably triggers `AppDelegate.openSettings(_:)`.
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Text(L10n.t("popover.openSettings", settings.appLanguage))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}
