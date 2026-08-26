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
    @EnvironmentObject private var installedAgents: InstalledAgentCatalog
    @AppStorage(InsightsSegment.defaultsKey) private var segmentRaw = InsightsSegment.overview.rawValue
    @AppStorage(InsightsSegmentBar.daysDefaultsKey) private var days = 7
    @State private var report: ProjectInsightsReport?
    @State private var activity: AgentActivitySnapshot?
    @State private var historyCostSources: Set<CostHistoryStore.Source> = []
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
    private var agentRecords: [InstalledAgentRecord] {
        return installedAgents.records.map {
            $0.projected(
                providerStatuses: quota.displayStatuses,
                availableCostSources: historyCostSources)
        }
    }
    private var reloadKey: String {
        (enabledIDs.union(agentRecords.map { $0.id.rawValue })).sorted().joined(separator: ",")
    }
    private var vi: Bool { L10n.languageCode(settings.appLanguage) == "vi" }

    var body: some View {
        SettingsPage(maxContentWidth: 680) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("settings.tab.insights", settings.appLanguage))
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
                            (.activity, vi ? "Hoạt động" : "Activity"),
                            (.projects, vi ? "Dự án" : "Projects"),
                        ],
                        selection: segment)
                    if segment.wrappedValue == .projects {
                        Spacer(minLength: InsightsSegmentBar.gap)
                        InstrumentSegmentedControl(
                            options: [
                                (1, vi ? "Hôm nay" : "Today"),
                                (7, "7d"),
                                (30, "30d"),
                                (90, "90d"),
                            ],
                            selection: periodDays)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if segment.wrappedValue == .activity, let activity {
                    AgentActivityContent(records: agentRecords, snapshot: activity)
                } else if let report {
                    if segment.wrappedValue == .overview {
                        InsightsOverviewContent(report: report)
                    } else if segment.wrappedValue == .projects {
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
        let history = await Task.detached(priority: .utility) {
            let document = CostHistoryStore.read()
            let sources = Set(CostHistoryStore.Source.allCases.filter { source in
                document.sources?[source.rawValue]?.values.contains {
                    $0.usd > 0 || $0.tokens > 0
                } == true
            })
            return (document: document, sources: sources)
        }.value
        guard !Task.isCancelled, loadGeneration == generation else { return }
        historyCostSources = history.sources
        let projectedRecords = agentRecords
        let activityIDs = projectedRecords.compactMap { record in
            record.capabilities.contains(.localCost) ? record.id : nil
        }
        let activitySnapshot = await Task.detached(priority: .utility) {
            WeeklyActivityBucketBuilder.buildSnapshot(
                document: history.document,
                agentIDs: activityIDs)
        }.value
        guard !Task.isCancelled, loadGeneration == generation else { return }
        activity = activitySnapshot
        let enabledSources = Self.localProjectSources(
            enabledProviderIDs: enabledIDs,
            agentRecords: projectedRecords)
        let includeClaude = enabledSources.contains(.claude)
        let includeCodex = enabledSources.contains(.codex)
        let includeGrok = enabledSources.contains(.grok)
        let includeKiro = enabledSources.contains(.kiro)
        let includeOMP = enabledSources.contains(.omp)
        let includePi = enabledSources.contains(.pi)

        let seededClaude = includeClaude ? await ClaudeCostScanner.seededReport() : nil
        let seededCodex = includeCodex ? await CodexCostScanner.seededReport() : nil
        let seededGrok = includeGrok ? await GrokCostScanner.seededReport() : nil
        let seededKiro = includeKiro ? await KiroCostScanner.seededReport() : nil
        let ompReport = includeOMP ? await OMPCostScanner.loadReport() : nil
        let piReport = includePi ? await PiCostScanner.loadReport() : nil
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let seeded = await buildReport(
            claude: seededClaude, codex: seededCodex, grok: seededGrok,
            kiro: seededKiro, omp: ompReport, pi: piReport,
            includeClaude: includeClaude, includeCodex: includeCodex,
            includeGrok: includeGrok, includeKiro: includeKiro,
            includeOMP: includeOMP, includePi: includePi,
            enabledSources: enabledSources)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if let seeded { report = seeded }

        let liveClaude = includeClaude ? await ClaudeCostScanner.usageReport() : nil
        let liveCodex = includeCodex ? await CodexCostScanner.usageReport() : nil
        let liveGrok = includeGrok ? await GrokCostScanner.usageReport() : nil
        let liveKiro = includeKiro ? await KiroCostScanner.usageReport() : nil
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let live = await buildReport(
            claude: liveClaude ?? seededClaude, codex: liveCodex ?? seededCodex,
            grok: liveGrok ?? seededGrok, kiro: liveKiro ?? seededKiro,
            omp: ompReport, pi: piReport,
            includeClaude: includeClaude, includeCodex: includeCodex,
            includeGrok: includeGrok, includeKiro: includeKiro,
            includeOMP: includeOMP, includePi: includePi,
            enabledSources: enabledSources)
        guard !Task.isCancelled,
              let completion = Self.loadCompletion(
                  generation: generation,
                  currentGeneration: loadGeneration,
                  seeded: seeded,
                  live: live)
        else { return }
        report = completion.report
        loading = completion.loading
    }

    struct LoadCompletion {
        let report: ProjectInsightsReport?
        let loading: Bool
    }

    static func loadCompletion(
        generation: UUID,
        currentGeneration: UUID,
        seeded: ProjectInsightsReport?,
        live: ProjectInsightsReport?
    ) -> LoadCompletion? {
        // The wrapper distinguishes a current load that completed empty from a
        // stale load that must not mutate the newer view state.
        guard generation == currentGeneration else { return nil }
        return LoadCompletion(report: live ?? seeded, loading: false)
    }

    /// Local cost follows the safely detected agent, not only its quota-provider
    /// toggle. Detection must bootstrap the first scan even before aggregate
    /// history exists; requiring `.localCost` here creates a circular gate for
    /// a fresh Kiro/Grok/Claude/Codex installation.
    static func localProjectSources(
        enabledProviderIDs: Set<String>,
        agentRecords: [InstalledAgentRecord]
    ) -> Set<ProjectUsageSource> {
        let localAgentIDs = Set(agentRecords.compactMap { record in
            record.costHistorySource != nil ? record.id.rawValue : nil
        })
        return Set(ProjectUsageSource.allCases.filter { source in
            enabledProviderIDs.contains(source.rawValue)
                || localAgentIDs.contains(source.rawValue)
        })
    }

    private func buildReport(
        claude: ClaudeUsageReport?, codex: CodexUsageReport?, grok: GrokUsageReport?,
        kiro: KiroUsageReport?,
        omp: OMPUsageReport? = nil, pi: PiUsageReport? = nil,
        includeClaude: Bool, includeCodex: Bool, includeGrok: Bool, includeKiro: Bool,
        includeOMP: Bool = true, includePi: Bool = true,
        enabledSources: Set<ProjectUsageSource>
    ) async -> ProjectInsightsReport? {
        guard claude != nil || codex != nil || grok != nil || kiro != nil
                || omp != nil || pi != nil else { return nil }
        let combined = CombinedUsageReport.build(
            claude: claude, codex: codex, grok: grok, kiro: kiro, omp: omp, pi: pi,
            includeClaude: includeClaude, includeCodex: includeCodex,
            includeGrok: includeGrok, includeKiro: includeKiro,
            includeOMP: includeOMP, includePi: includePi)
        return await Task.detached(priority: .utility) {
            ProjectInsightsBuilder.build(
                combined: combined, history: ProjectCostHistoryStore.read(),
                enabledSources: enabledSources)
        }.value
    }
}
