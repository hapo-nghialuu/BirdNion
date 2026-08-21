import SwiftUI

/// Shared metrics for Insights segment bars on one toolbar row.
enum InsightsSegmentBar {
    static let gap: CGFloat = 12
    static let viewWidth: CGFloat = 200
    /// Compact period chips (Today/7d/30d/90d) — shorter than the view bar.
    static let periodWidth: CGFloat = 220
    static let allowedDays = [1, 7, 30, 90]
    static let daysDefaultsKey = "birdnion.insightsDays"
}

struct InsightsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var quota: QuotaService
    @AppStorage(InsightsSegment.defaultsKey) private var segmentRaw = InsightsSegment.overview.rawValue
    @AppStorage(InsightsSegmentBar.daysDefaultsKey) private var days = 7
    @State private var report: ProjectInsightsReport?
    @State private var loading = false
    @State private var loadGeneration = UUID()

    private var segment: Binding<InsightsSegment> {
        Binding(
            get: { InsightsSegment.restored(segmentRaw) },
            set: { segmentRaw = $0.rawValue })
    }
    private var periodDays: Binding<Int> {
        Binding(
            get: { InsightsSegmentBar.allowedDays.contains(days) ? days : 7 },
            set: { days = InsightsSegmentBar.allowedDays.contains($0) ? $0 : 7 })
    }
    private var enabledIDs: Set<String> { Set(quota.displayStatuses.map(\.id)) }
    private var reloadKey: String { enabledIDs.sorted().joined(separator: ",") }
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        SettingsPage(maxContentWidth: 680) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights")
                        .font(.plexSans(24, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primary)
                    Text(vi ? "Chi phí sử dụng cục bộ, không hiển thị đường dẫn đầy đủ."
                            : "Local usage cost without exposing full project paths.")
                        .font(.plexSans(12))
                        .foregroundStyle(SettingsTheme.secondary)
                }
                // Overview: view bar only (leading). Projects: view leading + period trailing.
                HStack(alignment: .center, spacing: InsightsSegmentBar.gap) {
                    InstrumentSegmentedControl(
                        options: [
                            (.overview, vi ? "Tổng quan" : "Overview"),
                            (.projects, vi ? "Dự án" : "Projects"),
                        ],
                        selection: segment,
                        width: InsightsSegmentBar.viewWidth)
                    if segment.wrappedValue == .projects {
                        Spacer(minLength: InsightsSegmentBar.gap)
                        InstrumentSegmentedControl(
                            options: [
                                (1, vi ? "Hôm nay" : "Today"),
                                (7, "7d"),
                                (30, "30d"),
                                (90, "90d"),
                            ],
                            selection: periodDays,
                            width: InsightsSegmentBar.periodWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let report {
                    if segment.wrappedValue == .overview {
                        InsightsOverviewContent(report: report)
                    } else {
                        InsightsProjectsContent(report: report, days: periodDays)
                    }
                } else if loading {
                    ProgressView(vi ? "Đang đọc lịch sử sử dụng…" : "Reading usage history…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    Text(vi ? "Chưa có dữ liệu sử dụng cục bộ."
                            : "No local usage data yet.")
                        .font(.plexSans(13))
                        .foregroundStyle(SettingsTheme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
        }
        .task(id: reloadKey) { await load() }
    }

    @MainActor
    private func load() async {
        let generation = UUID()
        loadGeneration = generation
        loading = true
        let includeClaude = enabledIDs.contains("claude")
        let includeCodex = enabledIDs.contains("codex")
        let includeGrok = enabledIDs.contains("grok")
        let enabledSources = Set([
            includeClaude ? ProjectUsageSource.claude : nil,
            includeCodex ? ProjectUsageSource.codex : nil,
            includeGrok ? ProjectUsageSource.grok : nil,
        ].compactMap { $0 })
        guard includeClaude || includeCodex || includeGrok else {
            report = nil
            loading = false
            return
        }

        let seededClaude = includeClaude ? await ClaudeCostScanner.seededReport() : nil
        let seededCodex = includeCodex ? await CodexCostScanner.seededReport() : nil
        let seededGrok = includeGrok ? await GrokCostScanner.seededReport() : nil
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let seeded = await buildReport(
            claude: seededClaude, codex: seededCodex, grok: seededGrok,
            includeClaude: includeClaude, includeCodex: includeCodex, includeGrok: includeGrok,
            enabledSources: enabledSources)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if let seeded { report = seeded }

        let liveClaude = includeClaude ? await ClaudeCostScanner.usageReport() : nil
        let liveCodex = includeCodex ? await CodexCostScanner.usageReport() : nil
        let liveGrok = includeGrok ? await GrokCostScanner.usageReport() : nil
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let live = await buildReport(
            claude: liveClaude ?? seededClaude, codex: liveCodex ?? seededCodex,
            grok: liveGrok ?? seededGrok, includeClaude: includeClaude,
            includeCodex: includeCodex, includeGrok: includeGrok,
            enabledSources: enabledSources)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if let live { report = live }
        if loadGeneration == generation { loading = false }
    }

    private func buildReport(
        claude: ClaudeUsageReport?, codex: CodexUsageReport?, grok: GrokUsageReport?,
        includeClaude: Bool, includeCodex: Bool, includeGrok: Bool,
        enabledSources: Set<ProjectUsageSource>
    ) async -> ProjectInsightsReport? {
        guard claude != nil || codex != nil || grok != nil else { return nil }
        let combined = CombinedUsageReport.build(
            claude: claude, codex: codex, grok: grok,
            includeClaude: includeClaude, includeCodex: includeCodex, includeGrok: includeGrok)
        return await Task.detached(priority: .utility) {
            ProjectInsightsBuilder.build(
                combined: combined, history: ProjectCostHistoryStore.read(),
                enabledSources: enabledSources)
        }.value
    }
}
