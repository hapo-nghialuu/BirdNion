import Foundation

/// One model's slice of a single day for a local cost source.
struct LocalAgentDailyModel: Equatable, Identifiable, Sendable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of usage: token sum + USD spend + per-model split.
struct LocalAgentDailyUsage: Equatable, Identifiable, Sendable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [LocalAgentDailyModel]
    var id: Date { date }
}

/// Generic report shared by every local-log cost source added after the
/// original seven (opencode, gemini, copilot, antigravity, cursor, amp,
/// droid, kimi, qwen, goose) — each registers a `LocalCostSource` descriptor
/// below. Same shape as `OMPUsageReport`.
struct LocalAgentUsageReport: Equatable, Sendable {
    let todayUSD: Double
    let todayTokens: Int
    let last30USD: Double
    let last30Tokens: Int
    let daily: [LocalAgentDailyUsage]
    /// Trailing-24h hour buckets when the source's records carry per-event
    /// timestamps. Empty for day-grained/persisted reports.
    var hourly: [HourlyUsage] = []
    let topModel: String?
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool { last30Tokens == 0 && todayTokens == 0 }
}

/// One agent turn aggregated out of a source's local logs — the engine only
/// needs when, what model, how many tokens, the USD cost, and a stable key
/// for cross-file deduplication (forked sessions repeat the same turn).
struct LocalTurnRecord: Equatable, Sendable {
    let date: Date
    let model: String
    let tokens: Int
    let usd: Double
    let dedupeKey: String
}

/// Static description of a local cost source: where its session logs live
/// and how to read turns out of them. Everything else (incremental windows,
/// high-water merge, confidence, caching, reporting) is the engine's job.
struct LocalCostSource: Sendable {
    let source: CostHistoryStore.Source
    /// Human label for charts/slices (e.g. "OpenCode").
    let displayName: String
    /// Bump when the counting formula changes — same contract as the other
    /// scanners (`CostHistoryStore` never shrinks a day on its own).
    let countingRevision: Int
    /// Session log roots to scan; empty = tool not installed → report stays
    /// empty and no destructive merge runs.
    let roots: @Sendable () -> [URL]
    /// Reads turns from `roots`, optionally pruning work at `cutoff`.
    let turnReader: @Sendable (_ roots: [URL], _ cutoff: Date) async -> [LocalTurnRecord]
}

/// Shared scan engine for the post-v1 local cost sources. Mirrors
/// `OMPCostScanner`'s flow — seeded report → scan-back plan → reader →
/// per-day buckets → `CostHistoryStore` high-water merge → confidence —
/// so each source only supplies paths + a format parser.
enum LocalAgentCostEngine {

    static let chartWindowDays = 120
    /// Same routine/deep scan-back cadence as every other source.
    static let incrementalDays = CostHistoryStore.routineScanDays
    private static let cacheTTL: TimeInterval = 300

    /// Registered sources; each case's descriptor lives beside its parser.
    static let registry: [CostHistoryStore.Source: LocalCostSource] = [
        .opencode: OpenCodeCostSource.descriptor,
        .gemini: GeminiCostSource.descriptor,
        .copilot: CopilotCostSource.descriptor,
    ]

    /// Display names for every registered source (rawValue → label).
    static var displayNames: [String: String] {
        registry.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value.displayName }
    }

    /// Sources served by this engine — everything outside the typed seven.
    static var extraSources: Set<CostHistoryStore.Source> {
        Set(registry.keys)
    }

    /// Display label for a source raw value; falls back to the raw value.
    static func displayName(sourceRawValue: String) -> String {
        guard let source = CostHistoryStore.Source(rawValue: sourceRawValue),
              let descriptor = registry[source] else { return sourceRawValue }
        return descriptor.displayName
    }

    private actor Cache {
        static let shared = Cache()
        private var reports: [CostHistoryStore.Source: (at: Date, value: LocalAgentUsageReport)] = [:]

        func validReport(source: CostHistoryStore.Source, now: Date, ttl: TimeInterval) -> LocalAgentUsageReport? {
            guard let entry = reports[source], now.timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.value
        }

        func storeReport(_ value: LocalAgentUsageReport, source: CostHistoryStore.Source, at: Date) {
            reports[source] = (at, value)
        }
    }

    /// Persisted-history report for the instant first paint — no session I/O.
    static func seededReport(
        source: CostHistoryStore.Source,
        now: Date = Date(),
        calendar: Calendar = .current,
        url: URL = CostHistoryStore.historyURL()
    ) async -> LocalAgentUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: source, now: now, calendar: calendar,
                windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            let confidence = CostHistoryStore.confidence(
                source: source, liveScanSucceeded: false, url: url)
            return CostHistoryStore.makeLocalReport(window: window, confidence: confidence)
        }.value
    }

    /// Same three-case plan as the other scanners: a newer counting revision
    /// on disk means serve history only; an older one means a full replace
    /// pass; equal means the incremental window.
    static func countingScanPlan(
        descriptor: LocalCostSource,
        storedRevision: Int,
        incrementalDays: Int
    ) -> (windowDays: Int, replacing: Bool, historyOnly: Bool) {
        if storedRevision > descriptor.countingRevision {
            return (incrementalDays, false, true)
        }
        let replacing = storedRevision < descriptor.countingRevision
        return (replacing ? chartWindowDays : incrementalDays, replacing, false)
    }

    /// Buckets raw turns into per-day totals + per-model splits, deduped by
    /// `dedupeKey` (forked sessions replay the same turns in a second file).
    static func dailyBuckets(
        turns: [LocalTurnRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [CostHistoryStore.DayBucket] {
        var seen: Set<String> = []
        var byDay: [Date: (usd: Double, tokens: Int, models: [String: (usd: Double, tokens: Int)])] = [:]
        for turn in turns where seen.insert(turn.dedupeKey).inserted {
            let day = calendar.startOfDay(for: turn.date)
            var bucket = byDay[day] ?? (0, 0, [:])
            bucket.usd += turn.usd
            bucket.tokens += turn.tokens
            var model = bucket.models[turn.model] ?? (0, 0)
            model.usd += turn.usd
            model.tokens += turn.tokens
            bucket.models[turn.model] = model
            byDay[day] = bucket
        }
        return byDay
            .sorted { $0.key < $1.key }
            .map { day, bucket in
                CostHistoryStore.DayBucket(
                    date: day,
                    usd: bucket.usd,
                    tokens: bucket.tokens,
                    models: bucket.models
                        .sorted { $0.value.tokens > $1.value.tokens }
                        .map { .init(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) })
            }
    }

    /// Full pipeline for one registered source.
    static func loadReport(
        source: CostHistoryStore.Source,
        now: Date = Date(),
        calendar: Calendar = .current,
        historyURL: URL = CostHistoryStore.historyURL(),
        forceRescan: Bool = false
    ) async -> LocalAgentUsageReport {
        guard let descriptor = registry[source] else {
            let window = CostHistoryStore.window(
                source: source, now: now, calendar: calendar,
                windowDays: chartWindowDays, url: historyURL)
            let confidence = CostHistoryStore.confidence(
                source: source, liveScanSucceeded: false, url: historyURL)
            return CostHistoryStore.makeLocalReport(window: window, confidence: confidence)
        }
        if !forceRescan,
           let report = await Cache.shared.validReport(source: source, now: now, ttl: cacheTTL) {
            return report
        }

        let resolvedRoots = descriptor.roots()
        guard !resolvedRoots.isEmpty else {
            let window = CostHistoryStore.apply(
                source: source,
                liveDays: [],
                now: now,
                calendar: calendar,
                windowDays: chartWindowDays,
                url: historyURL,
                liveScanSucceeded: false)
            let confidence = CostHistoryStore.confidence(
                source: source, liveScanSucceeded: false, url: historyURL)
            return CostHistoryStore.makeLocalReport(window: window, confidence: confidence)
        }

        let storedRevision = CostHistoryStore.storedCountingRevision(source: source, url: historyURL)
        let scanBackPlan = CostHistoryStore.scanBackPlan(
            source: source,
            now: now,
            calendar: calendar,
            minDays: incrementalDays,
            maxDays: chartWindowDays,
            url: historyURL)
        let plan = countingScanPlan(
            descriptor: descriptor,
            storedRevision: storedRevision,
            incrementalDays: scanBackPlan.days)
        if plan.historyOnly {
            let window = CostHistoryStore.window(
                source: source, now: now, calendar: calendar,
                windowDays: chartWindowDays, url: historyURL)
            let confidence = CostHistoryStore.confidence(
                source: source, liveScanSucceeded: false, url: historyURL)
            return CostHistoryStore.makeLocalReport(window: window, confidence: confidence)
        }
        let scanDays = plan.windowDays
        let cutoff = calendar.date(
            byAdding: .day, value: -scanDays, to: calendar.startOfDay(for: now)) ?? now

        let turns = await Task.detached(priority: .utility) {
            await descriptor.turnReader(resolvedRoots, cutoff)
        }.value

        let buckets = dailyBuckets(turns: turns, now: now, calendar: calendar)
        let liveDays = buckets.map {
            ($0.date, $0.usd, $0.tokens, $0.models.map { ($0.name, $0.usd, $0.tokens) })
        }
        let applied = CostHistoryStore.applyWithReceipt(
            source: source,
            liveDays: liveDays,
            now: now,
            calendar: calendar,
            windowDays: chartWindowDays,
            url: historyURL,
            replacingSource: plan.replacing,
            liveScanSucceeded: true,
            countingRevision: descriptor.countingRevision)
        if applied.persisted, scanBackPlan.isDeep {
            CostHistoryStore.markDeepScanSucceeded(source: source, at: now, url: historyURL)
        }
        let confidence = CostHistoryStore.confidence(
            source: source, liveScanSucceeded: applied.persisted, url: historyURL)
        let hourly = applied.persisted
            ? CostHistoryStore.makeHourlyBuckets(
                entries: turns.map { ($0.date, $0.usd, $0.tokens) }, now: now, calendar: calendar)
            : []
        let report = CostHistoryStore.makeLocalReport(
            window: applied.window, hourly: hourly, confidence: confidence)
        if applied.persisted {
            await Cache.shared.storeReport(report, source: source, at: now)
        }
        return report
    }

    /// Runs every requested registered source concurrently.
    static func loadReports(
        sources: Set<CostHistoryStore.Source>,
        now: Date = Date(),
        calendar: Calendar = .current,
        historyURL: URL = CostHistoryStore.historyURL()
    ) async -> [CostHistoryStore.Source: LocalAgentUsageReport] {
        await withTaskGroup(
            of: (CostHistoryStore.Source, LocalAgentUsageReport).self
        ) { group in
            for source in sources where registry[source] != nil {
                group.addTask {
                    await (source, loadReport(
                        source: source, now: now, calendar: calendar, historyURL: historyURL))
                }
            }
            var out: [CostHistoryStore.Source: LocalAgentUsageReport] = [:]
            for await (source, report) in group { out[source] = report }
            return out
        }
    }

    static func seededReports(
        sources: Set<CostHistoryStore.Source>,
        now: Date = Date(),
        calendar: Calendar = .current,
        historyURL: URL = CostHistoryStore.historyURL()
    ) async -> [CostHistoryStore.Source: LocalAgentUsageReport] {
        var out: [CostHistoryStore.Source: LocalAgentUsageReport] = [:]
        for source in sources where registry[source] != nil {
            if let report = await seededReport(
                source: source, now: now, calendar: calendar, url: historyURL) {
                out[source] = report
            }
        }
        return out
    }
}
