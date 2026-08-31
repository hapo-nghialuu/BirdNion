import CodexBarCore
import Foundation

/// Token cost rolled up from the local Codex logs.
///
/// Token counts are exact; the dollar amount is an estimate (tokens × a model
/// price table), so it is surfaced as "≈" in the UI.
struct CodexCostSummary: Equatable {
    let todayUSD: Double
    let todayTokens: Int
    /// Totals over the configured history window (default 30 days). The field
    /// name is kept for compatibility; the window length is `historyDays`.
    let last30USD: Double
    let last30Tokens: Int

    var isEmpty: Bool { todayTokens == 0 && last30Tokens == 0 }
}

/// One model's slice of a single Codex day — powers the hover breakdown list.
struct CodexDailyModel: Equatable, Identifiable {
    let name: String
    let usd: Double
    let tokens: Int
    var id: String { name }
}

/// One calendar day (local tz) of Codex usage: exact token sum + estimated USD,
/// plus the per-model split (top 5 by cost) shown in the hover detail row.
struct CodexDailyUsage: Equatable, Identifiable {
    let date: Date
    let usd: Double
    let tokens: Int
    let models: [CodexDailyModel]
    var id: Date { date }
}

/// Full report for the Codex usage chart. Mirrors `ClaudeUsageReport` but the
/// values are mapped to match CodexBar's own inline dashboard exactly:
/// "today" is the most recent **active** day's cost (not the live session), the
/// bars are daily cost, and the top model is the highest-cost one. The daily
/// window spans `CodexCostScanner.chartWindowDays` (120) for the combined
/// heatmap; the `last30*` totals stay strictly 30-day.
struct CodexUsageReport: Equatable {
    /// Most recent active day's estimated cost + exact tokens (CodexBar "Today").
    let todayUSD: Double
    let todayTokens: Int
    /// Strict 30-day totals (summed from the trailing 30 daily buckets).
    let last30USD: Double
    let last30Tokens: Int
    /// `chartWindowDays` daily buckets, oldest → newest; idle days render as a
    /// zero-height bar.
    let daily: [CodexDailyUsage]
    /// Highest-cost model across the window (shortened). nil when none logged.
    let topModel: String?
    /// Data Confidence Pass metadata (included/live/scannedAt) for the
    /// All-tab compact badge. Defaulted so memberwise call sites predating
    /// this pass stay source-compatible.
    var scanConfidence: CostHistoryStore.UsageScanConfidence = .unavailable

    var isEmpty: Bool { last30Tokens == 0 }
}

/// Rolls up Codex token cost for "today" and the configured history window.
///
/// Delegates to CodexBarCore's `CostUsageFetcher`, which scans the full set of
/// local Codex log sources (native `~/.codex/sessions` + `archived_sessions`,
/// plus supported pi sessions), uses `turn_context` model markers as the
/// authoritative model bucket, and prices each model. Always scans the system
/// `~/.codex` home — the only place the CLI writes session logs, whichever
/// login is installed. Results are cached briefly so toggling the Settings
/// pane doesn't rescan on every open.
enum CodexCostScanner {
    private static let cacheTTL: TimeInterval = 300
    static let historyDaysKey = "codexCostHistoryDays"
    /// Daily-bucket window for `usageReport` (feeds the 120-day heatmap on the
    /// All tab). Independent of the user-configurable `historyDays`, which
    /// only drives `summary()`.
    static let chartWindowDays = 120

    /// Rolling history window in days (1...365). Defaults to 30 when unset.
    /// `SettingsStore` writes the same key.
    static var historyDays: Int {
        let raw = UserDefaults.standard.integer(forKey: historyDaysKey)
        return raw == 0 ? 30 : max(1, min(365, raw))
    }

    /// Result of one bounded report episode. Pending results may carry the
    /// last-good history report for display, but are never memoized as live.
    struct ScanProgress: Equatable {
        let generation: String
        let parsedBytes: Int64
        let incompleteFiles: Int
        let progressFingerprint: String

        func hasAdvanced(since previous: ScanProgress?) -> Bool {
            guard parsedBytes >= 0,
                  incompleteFiles >= 0,
                  !progressFingerprint.isEmpty
            else { return false }
            guard let previous else { return true }
            guard generation == previous.generation else {
                // Finishing one immutable range may atomically seed a catch-up
                // generation. A distinct durable fingerprint proves that the
                // new range has checkpointed work of its own.
                return progressFingerprint != previous.progressFingerprint
            }
            return progressFingerprint != previous.progressFingerprint
                || parsedBytes > previous.parsedBytes
                || incompleteFiles < previous.incompleteFiles
        }

        var continuationIdentity: String {
            [generation, progressFingerprint, String(parsedBytes), String(incompleteFiles)]
                .joined(separator: "|")
        }
    }

    struct ReportLoad {
        let value: CodexUsageReport?
        let completed: Bool
        let progress: ScanProgress?
        /// This episode has a publishable last-good snapshot and can yield;
        /// a durable catch-up journal may still be pending.
        let publishedSnapshot: Bool

        init(
            value: CodexUsageReport?,
            completed: Bool,
            progress: ScanProgress? = nil,
            publishedSnapshot: Bool = false)
        {
            self.value = value
            self.completed = completed
            self.progress = progress
            self.publishedSnapshot = publishedSnapshot
        }
    }

    /// Actor-isolated cache + single-flight coordinator. Internal visibility
    /// keeps the concurrency policy directly testable without public API.
    actor Cache {
        static let shared = Cache()
        private var entry: (at: Date, windowDays: Int, value: CodexCostSummary)?
        private var reportEntry: (at: Date, value: CodexUsageReport)?
        private var reportGeneration: UInt = 0
        private var reportInFlight: (
            generation: UInt,
            at: Date,
            task: Task<ReportLoad, Never>)?

        func valid(
            now: Date,
            ttl: TimeInterval,
            windowDays: Int,
            calendar: Calendar = .current) -> CodexCostSummary?
        {
            guard let entry,
                  entry.windowDays == windowDays,
                  Self.isFresh(entry.at, at: now, ttl: ttl, calendar: calendar)
            else { return nil }
            return entry.value
        }
        func store(_ value: CodexCostSummary, at: Date, windowDays: Int) {
            entry = (at, windowDays, value)
        }
        func lastSummary(
            windowDays: Int,
            now: Date,
            calendar: Calendar = .current) -> CodexCostSummary?
        {
            guard let entry,
                  entry.windowDays == windowDays,
                  calendar.isDate(entry.at, inSameDayAs: now)
            else { return nil }
            return entry.value
        }

        func validReport(
            now: Date,
            ttl: TimeInterval,
            calendar: Calendar = .current) -> CodexUsageReport?
        {
            guard let reportEntry,
                  Self.isFresh(reportEntry.at, at: now, ttl: ttl, calendar: calendar)
            else { return nil }
            return reportEntry.value
        }
        func storeReport(_ value: CodexUsageReport, at: Date) { reportEntry = (at, value) }

        func report(
            now: Date,
            ttl: TimeInterval,
            calendar: Calendar = .current,
            bypassCache: Bool = false,
            loader: @escaping () async -> ReportLoad) async -> ReportLoad
        {
            if !bypassCache,
               let cached = validReport(now: now, ttl: ttl, calendar: calendar)
            {
                return ReportLoad(value: cached, completed: true)
            }

            if let current = reportInFlight {
                let result = await current.task.value
                finish(current, result: result)
                if calendar.isDate(current.at, inSameDayAs: now) {
                    return result
                }
                // A request for a new local day must wait for the old worker,
                // then start its own generation instead of accepting old data.
                return await report(
                    now: now,
                    ttl: ttl,
                    calendar: calendar,
                    bypassCache: bypassCache,
                    loader: loader)
            }

            reportGeneration &+= 1
            let generation = reportGeneration
            let task = Task<ReportLoad, Never> { await loader() }
            let current = (generation: generation, at: now, task: task)
            reportInFlight = current
            let result = await task.value
            finish(current, result: result)
            return result
        }

        private func finish(
            _ flight: (generation: UInt, at: Date, task: Task<ReportLoad, Never>),
            result: ReportLoad)
        {
            guard reportInFlight?.generation == flight.generation else { return }
            reportInFlight = nil
            if result.completed, let value = result.value {
                reportEntry = (flight.at, value)
            }
        }

        private static func isFresh(
            _ cachedAt: Date,
            at now: Date,
            ttl: TimeInterval,
            calendar: Calendar) -> Bool
        {
            let age = now.timeIntervalSince(cachedAt)
            return age >= 0
                && age < ttl
                && calendar.isDate(cachedAt, inSameDayAs: now)
        }
    }

    /// Cached, off-main scan. Returns nil only when the scan throws (e.g. no
    /// readable log sources).
    static func summary(now: Date = Date()) async -> CodexCostSummary? {
        let requestedWindowDays = historyDays
        let sharedScanWindowDays = scanWindowDays(requestedWindowDays: requestedWindowDays)
        if let cached = await Cache.shared.valid(
            now: now,
            ttl: cacheTTL,
            windowDays: requestedWindowDays)
        {
            return cached
        }
        // Always scan the real CLI home (~/.codex): every terminal `codex`
        // session logs there regardless of which login is installed, and
        // managed homes only ever hold auth.json (no session history). Scoping
        // to the viewed account made freshly-added accounts show an empty
        // chart and zero out the All-tab Codex column.
        let codexHome = CodexAccountStore.systemAuthURL().deletingLastPathComponent().path
        guard let snapshot = try? await CostUsageFetcher().loadTokenSnapshot(
            provider: .codex,
            now: now,
            codexHomePath: codexHome,
            historyDays: sharedScanWindowDays)
        else { return nil }
        guard !snapshot.scanIncomplete else {
            if !snapshot.daily.isEmpty {
                return mapSummary(
                    snapshot,
                    now: now,
                    windowDays: requestedWindowDays)
            }
            return await Cache.shared.lastSummary(
                windowDays: requestedWindowDays,
                now: now)
        }
        let value = mapSummary(
            snapshot,
            now: now,
            windowDays: requestedWindowDays)
        await Cache.shared.store(value, at: now, windowDays: requestedWindowDays)
        return value
    }

    /// Both compact summary and 120-day chart share one durable core cache.
    /// Always scan the wider requested window so those callers never replace
    /// each other's pending generation (30d vs 120d by default).
    static func scanWindowDays(requestedWindowDays: Int) -> Int {
        max(chartWindowDays, max(1, min(365, requestedWindowDays)))
    }

    /// Pure mapping (snapshot → BirdNion model), unit-testable. "session" totals
    /// are today's; "last30Days" totals span the configured window.
    static func map(_ snapshot: CostUsageTokenSnapshot) -> CodexCostSummary {
        CodexCostSummary(
            todayUSD: snapshot.sessionCostUSD ?? 0,
            todayTokens: snapshot.sessionTokens ?? 0,
            last30USD: snapshot.last30DaysCostUSD ?? 0,
            last30Tokens: snapshot.last30DaysTokens ?? 0)
    }

    /// Derives the user-configured summary window from the wider shared scan.
    /// `CostUsageTokenSnapshot.last30Days*` describes the scan window itself,
    /// so it cannot be used directly when the core scan is intentionally wider.
    static func mapSummary(
        _ snapshot: CostUsageTokenSnapshot,
        now: Date,
        windowDays: Int,
        calendar: Calendar = .current) -> CodexCostSummary
    {
        let clampedDays = max(1, min(365, windowDays))
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: today)
            ?? today.addingTimeInterval(TimeInterval(-(clampedDays - 1) * 86_400))
        var byDay: [Date: (usd: Double, tokens: Int)] = [:]

        for entry in snapshot.daily {
            guard let parsed = parseDay(entry.date, calendar: calendar) else { continue }
            let day = calendar.startOfDay(for: parsed)
            guard day >= firstDay, day <= today else { continue }
            var total = byDay[day] ?? (usd: 0, tokens: 0)
            total.usd += entry.costUSD ?? 0
            total.tokens += entry.totalTokens ?? 0
            byDay[day] = total
        }

        let latest = byDay
            .filter { $0.value.tokens > 0 || $0.value.usd > 0 }
            .max { $0.key < $1.key }?
            .value
        return CodexCostSummary(
            todayUSD: latest?.usd ?? 0,
            todayTokens: latest?.tokens ?? 0,
            last30USD: byDay.values.reduce(0) { $0 + $1.usd },
            last30Tokens: byDay.values.reduce(0) { $0 + $1.tokens })
    }

    // MARK: - Full report (chart)

    /// Cached, off-main full report: 30-day totals + 120-day per-day series for
    /// the usage chart/heatmap. Returns nil only when the scan throws.
    static func usageReport(now: Date = Date()) async -> CodexUsageReport? {
        // Another consumer (for example `summary()`) can create a durable
        // pending journal while this report's 5-minute cache is still fresh.
        // Observe it before the fast-path so reopening continues real work.
        let initialProgress = await pendingScanProgress()
        let load = await Cache.shared.report(
            now: now,
            ttl: cacheTTL,
            bypassCache: initialProgress != nil)
        {
            return await runReportEpisode(
                initialProgress: initialProgress,
                continuationDelay: .milliseconds(250))
            { forceRefresh in
                await performReportScan(now: now, forceRefresh: forceRefresh)
            }
        }
        return load.value
    }

    /// One progress-driven convergence episode. Every core pass remains
    /// bounded, while a finite durable generation continues automatically
    /// until it completes or stops making checkpoint progress. Singleflight
    /// ensures all callers share this worker; the delay yields CPU between
    /// passes without making the user reopen the popover.
    static func runReportEpisode(
        initialProgress: ScanProgress? = nil,
        continuationDelay: Duration = .zero,
        scanPass: @escaping (_ forceRefresh: Bool) async -> ReportLoad) async -> ReportLoad
    {
        // A durable pending journal bypasses the core refresh throttle so a
        // reopen actually continues it instead of returning the same snapshot.
        var current = await scanPass(initialProgress != nil)
        guard !current.completed, !current.publishedSnapshot else { return current }

        var previousProgress = initialProgress
        var seenProgress = Set(initialProgress.map { [$0.continuationIdentity] } ?? [])
        while !current.completed {
            // `incomplete` without a durable journal is an error/fallback, not
            // evidence that another forced pass can make progress. Repeated or
            // cyclic checkpoints stop here instead of creating a CPU loop.
            guard let progress = current.progress,
                  progress.hasAdvanced(since: previousProgress),
                  seenProgress.insert(progress.continuationIdentity).inserted
            else { return current }
            previousProgress = progress

            guard !Task.isCancelled else { return current }
            if continuationDelay == .zero {
                await Task.yield()
            } else {
                do {
                    try await Task.sleep(for: continuationDelay)
                } catch {
                    return current
                }
            }

            let next = await scanPass(true)
            if next.completed || next.publishedSnapshot { return next }
            current = ReportLoad(
                value: next.value ?? current.value,
                completed: false,
                progress: next.progress,
                publishedSnapshot: next.publishedSnapshot)
        }
        return current
    }

    private static func pendingScanProgress() async -> ScanProgress? {
        let status = await CostUsageFetcher().loadCodexPendingScanStatus()
        return status.map {
            ScanProgress(
                generation: $0.generation,
                parsedBytes: $0.parsedBytes,
                incompleteFiles: $0.incompleteFiles,
                progressFingerprint: $0.progressFingerprint)
        }
    }

    /// Một bounded pass không đụng `Cache.shared`; pending trả last-good
    /// history kèm progress journal, complete mới được publish/persist.
    private static func performReportScan(
        now: Date,
        forceRefresh: Bool = false) async -> ReportLoad {
        // Same as `summary()`: the machine-wide ~/.codex is the only place
        // session logs actually accumulate.
        let codexHome = CodexAccountStore.systemAuthURL().deletingLastPathComponent().path
        let fetcher = CostUsageFetcher()
        let sharedScanWindowDays = scanWindowDays(requestedWindowDays: historyDays)
        let snapshot = try? await fetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: forceRefresh,
            codexHomePath: codexHome,
            historyDays: sharedScanWindowDays)
        // A non-cancellation parser I/O failure intentionally throws without
        // mutating its checkpoint. The snapshot is then nil, so the durable
        // journal—not `snapshot?.scanIncomplete` alone—is authoritative.
        let pendingStatus = await fetcher.loadCodexPendingScanStatus()
        let progress = pendingStatus.map {
            ScanProgress(
                generation: $0.generation,
                parsedBytes: $0.parsedBytes,
                incompleteFiles: $0.incompleteFiles,
                progressFingerprint: $0.progressFingerprint)
        }
        let incomplete = hasUnfinishedScan(
            snapshotIncomplete: snapshot?.scanIncomplete,
            progress: progress)
        let live = snapshot.map { mapReport($0, now: now) }
        let liveDays = (live?.daily ?? []).map {
            ($0.date, $0.usd, $0.tokens,
             $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
        }
        if incomplete {
            if let snapshot,
               snapshot.completedFiniteScanGeneration || !snapshot.daily.isEmpty
            {
                _ = ProjectCostHistoryStore.apply(
                    source: .codex,
                    liveProjects: mapProjects(snapshot),
                    now: now,
                    retractions: mapRetractions(snapshot))
                let receipt = CostHistoryStore.applyWithReceipt(
                    source: .codex,
                    liveDays: liveDays,
                    now: now,
                    windowDays: chartWindowDays,
                    liveScanSucceeded: snapshot.completedFiniteScanGeneration)
                let confidence = CostHistoryStore.confidence(
                    source: .codex,
                    liveScanSucceeded: snapshot.completedFiniteScanGeneration
                        && receipt.persisted)
                return ReportLoad(
                    value: CostHistoryStore.makeCodexReport(
                        window: receipt.window, now: now, confidence: confidence),
                    completed: false,
                    progress: progress,
                    publishedSnapshot: true)
            }
            let window = CostHistoryStore.window(
                source: .codex, now: now, windowDays: chartWindowDays)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else {
                return ReportLoad(value: nil, completed: false, progress: progress)
            }
            let confidence = CostHistoryStore.confidence(
                source: .codex, liveScanSucceeded: false)
            return ReportLoad(
                value: CostHistoryStore.makeCodexReport(
                    window: window, now: now, confidence: confidence),
                completed: false,
                progress: progress)
        }
        let liveScanSucceeded = live != nil
        if let snapshot {
            _ = ProjectCostHistoryStore.apply(
                source: .codex,
                liveProjects: mapProjects(snapshot),
                now: now,
                retractions: mapRetractions(snapshot))
        }
        let receipt = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: liveDays,
            now: now,
            windowDays: chartWindowDays,
            liveScanSucceeded: liveScanSucceeded)
        let confidence = CostHistoryStore.confidence(
            source: .codex,
            liveScanSucceeded: liveScanSucceeded && receipt.persisted)
        let value = CostHistoryStore.makeCodexReport(
            window: receipt.window,
            now: now,
            confidence: confidence)
        // Persist high-water days even when the live snapshot fails / is empty
        // (e.g. user deleted ~/.codex/sessions after a prior successful scan).
        if value.isEmpty && live == nil {
            return ReportLoad(value: nil, completed: true)
        }
        return ReportLoad(value: value, completed: true)
    }

    static func hasUnfinishedScan(
        snapshotIncomplete: Bool?,
        progress: ScanProgress?) -> Bool
    {
        snapshotIncomplete == true || progress != nil
    }

    /// Instant chart seed from persisted history — no log scan. Nil when the
    /// store has nothing for Codex so callers keep their loading skeleton.
    /// Deliberately not stored in `Cache`: a cached seed would mask the live
    /// scan for the whole TTL.
    static func seededReport(now: Date = Date(),
                             url: URL = CostHistoryStore.historyURL()) async -> CodexUsageReport? {
        await Task.detached(priority: .userInitiated) {
            let window = CostHistoryStore.window(
                source: .codex, now: now, windowDays: chartWindowDays, url: url)
            guard window.contains(where: { $0.tokens > 0 || $0.usd > 0 }) else { return nil }
            let confidence = CostHistoryStore.confidence(
                source: .codex, liveScanSucceeded: false, url: url)
            return CostHistoryStore.makeCodexReport(window: window, now: now, confidence: confidence)
        }.value
    }

    /// Pure mapping (snapshot → chart report), unit-testable. Mirrors CodexBar's
    /// inline dashboard: bars + per-model breakdown are rolled up from
    /// `snapshot.daily` (cost per day), "today" is the most recent active day,
    /// the 30-day token total falls back to the daily sum, and the top model is
    /// the highest-cost one.
    static func mapReport(_ snapshot: CostUsageTokenSnapshot, now: Date = Date()) -> CodexUsageReport {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // First day of the strict-30 window (today counts as day 30).
        let last30Start = calendar.date(byAdding: .day, value: -29, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-29 * 86_400)

        var buckets: [Date: DailyAccumulator] = [:]
        // Summed cost+tokens per model over the trailing 30 days → top model.
        // Gated to 30d (not the full 120d bucket window) so the Codex tab's
        // top-model line keeps its pre-heatmap value.
        var modelTotals: [String: (cost: Double, tokens: Int)] = [:]

        for entry in snapshot.daily {
            guard let parsed = parseDay(entry.date) else { continue }
            let day = calendar.startOfDay(for: parsed)
            let acc = buckets[day] ?? DailyAccumulator()
            acc.usd += entry.costUSD ?? 0
            acc.tokens += entry.totalTokens ?? 0
            for mb in entry.modelBreakdowns ?? [] {
                var m = acc.models[mb.modelName] ?? (usd: 0, tokens: 0)
                m.usd += mb.costUSD ?? 0
                m.tokens += mb.totalTokens ?? 0
                acc.models[mb.modelName] = m
                guard day >= last30Start else { continue }
                var total = modelTotals[mb.modelName] ?? (cost: 0, tokens: 0)
                total.cost += mb.costUSD ?? 0
                total.tokens += mb.totalTokens ?? 0
                modelTotals[mb.modelName] = total
            }
            buckets[day] = acc
        }

        let daily = makeDailyBuckets(buckets: buckets, endDay: startOfToday, count: chartWindowDays)
        // Strict 30-day slice for the totals + "today" — the wider window only
        // exists for the heatmap, the Codex tab numbers must not move with it.
        let last30 = daily.suffix(30)
        let latest = last30.last(where: { $0.tokens > 0 })
        let topModel = modelTotals.max {
            $0.value.cost == $1.value.cost
                ? $0.value.tokens < $1.value.tokens
                : $0.value.cost < $1.value.cost
        }?.key

        return CodexUsageReport(
            todayUSD: latest?.usd ?? 0,
            todayTokens: latest?.tokens ?? 0,
            last30USD: last30.map(\.usd).reduce(0, +),
            last30Tokens: last30.map(\.tokens).reduce(0, +),
            daily: daily,
            topModel: topModel.map(shortModelName))
    }

    static func mapProjects(
        _ snapshot: CostUsageTokenSnapshot,
        calendar: Calendar = .current
    ) -> [ProjectUsageRecord] {
        (snapshot.projectBreakdown ?? []).compactMap { project in
            let key = ProjectIdentity.safeKey(project.projectKey)
            guard key == project.projectKey else { return nil }
            let daily = project.daily.compactMap { row -> ProjectDailyUsage? in
                guard let parsed = parseDay(row.date) else { return nil }
                return ProjectDailyUsage(
                    date: calendar.startOfDay(for: parsed),
                    usd: row.costUSD,
                    tokens: row.totalTokens,
                    models: row.models.map {
                        ProjectModelUsage(
                            name: ProjectIdentity.safeModelName($0.name),
                            usd: $0.costUSD,
                            tokens: $0.totalTokens)
                    })
            }
            guard !daily.isEmpty else { return nil }
            return ProjectUsageRecord(
                source: .codex,
                projectKey: key,
                displayName: ProjectIdentity.safeDisplayName(project.projectName, key: key),
                attribution: .exact,
                daily: daily)
        }
    }

    static func mapRetractions(
        _ snapshot: CostUsageTokenSnapshot,
        calendar: Calendar = .current
    ) -> [ProjectCostHistoryStore.Retraction] {
        (snapshot.projectRetractions ?? []).compactMap { retraction in
            guard retraction.retractionID.count == 64,
                  retraction.projectKey.count == 64
            else { return nil }
            let daily = retraction.daily.compactMap { row -> ProjectDailyUsage? in
                guard let parsed = parseDay(row.date) else { return nil }
                return ProjectDailyUsage(
                    date: calendar.startOfDay(for: parsed),
                    usd: row.costUSD,
                    tokens: row.totalTokens,
                    models: row.models.map {
                        ProjectModelUsage(
                            name: ProjectIdentity.safeModelName($0.name),
                            usd: $0.costUSD,
                            tokens: $0.totalTokens)
                    })
            }
            guard !daily.isEmpty else { return nil }
            return ProjectCostHistoryStore.Retraction(
                id: retraction.retractionID,
                projectKey: retraction.projectKey,
                daily: daily)
        }
    }

    /// In-place per-day accumulator (reference type so dictionary updates don't
    /// re-box on every entry).
    private final class DailyAccumulator {
        var usd: Double = 0
        var tokens: Int = 0
        var models: [String: (usd: Double, tokens: Int)] = [:]
    }

    /// Contiguous N-day bucket array (oldest → newest) so the chart has a slot
    /// for every day even when no activity was logged. Per-model rows are sorted
    /// by cost (top 5), matching CodexBar's day detail.
    private static func makeDailyBuckets(
        buckets: [Date: DailyAccumulator], endDay: Date, count: Int
    ) -> [CodexDailyUsage] {
        let calendar = Calendar.current
        var result: [CodexDailyUsage] = []
        var cursor = endDay
        for _ in 0..<count {
            let acc = buckets[cursor]
            let models: [CodexDailyModel] = (acc?.models ?? [:])
                .filter { $0.value.tokens > 0 || $0.value.usd > 0 }
                .map { CodexDailyModel(name: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
                .sorted { $0.usd > $1.usd }
                .prefix(5)
                .map { $0 }
            result.append(CodexDailyUsage(
                date: cursor, usd: acc?.usd ?? 0, tokens: acc?.tokens ?? 0, models: models))
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)
                ?? cursor.addingTimeInterval(-86_400)
        }
        return result.reversed()
    }

    /// CodexBar's daily `date` is a "yyyy-MM-dd" day string; fall back to ISO8601
    /// for any source that carries a time component. nil when neither parses.
    private static func parseDay(_ text: String, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           let day = Int(parts[2])
        {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            if let date = calendar.date(from: components) { return date }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// Trim very long model names for the top-model line (CodexBar parity).
    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }
}
