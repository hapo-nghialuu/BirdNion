import Foundation

public enum CostUsageError: LocalizedError, Sendable {
    case unsupportedProvider(UsageProvider)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Cost summary is not supported for \(provider.rawValue)."
        case let .timedOut(seconds):
            if seconds >= 60, seconds % 60 == 0 {
                return "Cost refresh timed out after \(seconds / 60)m."
            }
            return "Cost refresh timed out after \(seconds)s."
        }
    }
}

public struct CodexPendingScanStatus: Sendable, Equatable {
    public let generation: String
    public let parsedBytes: Int64
    public let incompleteFiles: Int
    public let progressFingerprint: String

    public init(
        generation: String,
        parsedBytes: Int64,
        incompleteFiles: Int,
        progressFingerprint: String)
    {
        self.generation = generation
        self.parsedBytes = parsedBytes
        self.incompleteFiles = incompleteFiles
        self.progressFingerprint = progressFingerprint
    }
}

public struct CostUsageFetcher: Sendable {
    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil) {
        self.scannerOptions = cacheRoot.map { CostUsageScanner.Options(cacheRoot: $0) }
    }

    /// Removes obsolete Codex cache artifacts that could contain raw session paths.
    /// This is intentionally independent of provider enablement and log scanning.
    public static func performPrivacyMigrations(cacheRoot: URL? = nil) throws {
        try CostUsageCacheIO.removeSensitiveObsoleteCaches(
            provider: .codex, cacheRoot: cacheRoot)
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    public func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptionsOverride())
    }

    /// Returns privacy-safe progress for an unfinished local Codex scan.
    public func loadCodexPendingScanStatus() async -> CodexPendingScanStatus? {
        let options = self.scannerOptionsOverride() ?? CostUsageScanner.Options()
        return try? await CostUsageScanExecutor.run { _ in
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
            guard let generation = cache.codexPendingScanGeneration else { return nil }
            let manifest = cache.codexPendingFileManifest ?? [:]
            let pendingFiles = cache.codexPendingFiles ?? [:]
            let parentScans = cache.codexPendingParentScans ?? [:]
            let parentDiscoveries = cache.codexPendingParentDiscoveries ?? [:]
            let pendingBytes = Self.saturatingParsedBytesSum(
                pendingFiles.values.map { $0.parsedBytes ?? 0 })
            let parentBytes = Self.saturatingParsedBytesSum(
                parentScans.values.map(\.parsedBytes))
            return CodexPendingScanStatus(
                generation: CostUsageScanner.codexOpaquePendingGeneration(generation),
                parsedBytes: Self.saturatingParsedBytesSum([pendingBytes, parentBytes]),
                incompleteFiles: manifest.keys.count { path in
                    let usage = pendingFiles[path]
                    return usage?.codexScanComplete != true
                        || usage?.codexScanTargetSize != manifest[path]?.targetEOF
                }
                    + parentScans.values.count { !$0.scanComplete }
                    + parentDiscoveries.values.count { $0.resolvedRelativePath == nil },
                progressFingerprint: CostUsageScanner.codexPendingProgressFingerprint(cache))
        }
    }

    static func saturatingParsedBytesSum(_ values: [Int64]) -> Int64 {
        var total: Int64 = 0
        for value in values {
            let nonnegative = max(0, value)
            let (sum, overflowed) = total.addingReportingOverflow(nonnegative)
            if overflowed { return Int64.max }
            total = sum
        }
        return total
    }

    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground,
            scannerOptions: self.scannerOptionsOverride())
    }

    @available(*, deprecated, message: "Codex token-cost scans are uncapped; this limit is ignored.")
    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        automaticCodexScanByteLimit _: Int64?) async throws -> CostUsageTokenSnapshot
    {
        try await self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground)
    }

    private func scannerOptionsOverride() -> CostUsageScanner.Options? {
        self.scannerOptions
    }

    static func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        includePiSessions: Bool = false,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        piScannerOptions overridePiScannerOptions: PiSessionCostScanner
            .Options? = nil) async throws -> CostUsageTokenSnapshot
    {
        guard provider == .codex || provider == .claude || provider == .vertexai || provider == .bedrock else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let until = now
        let clampedHistoryDays = max(1, min(365, historyDays))
        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now

        if provider == .bedrock {
            let daily = try await Self.loadBedrockDailyReport(
                environment: environment,
                since: since,
                until: until)
            return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
        }

        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        if provider == .codex,
           let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            options.codexSessionsRoot = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        // Chống treo khi lịch sử Codex JSONL cực lớn (hàng GB): giới hạn thời
        // gian mỗi lần scan; phần còn lại resume ở lần scan sau qua cache đĩa.
        // Chỉ áp khi caller không tự đặt (override giữ nguyên hành vi test).
        if provider == .codex, overrideScannerOptions == nil, options.maxScanWallClock == nil {
            options.maxScanWallClock = 12
        }
        if provider == .codex || provider == .claude {
            let pricingCacheRoot = options.cacheRoot
            if refreshPricingInBackground {
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
                }
            } else {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
            }
        }

        if provider == .vertexai {
            options.claudeLogProviderFilter = allowVertexClaudeFallback ? .all : .vertexAIOnly
        } else if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh {
            options.refreshMinIntervalSeconds = 0
        }
        var resolvedPiOptions = overridePiScannerOptions ?? PiSessionCostScanner.Options()
        if resolvedPiOptions.cacheRoot == nil {
            resolvedPiOptions.cacheRoot = options.cacheRoot
        }
        if forceRefresh {
            resolvedPiOptions.refreshMinIntervalSeconds = 0
        }
        let piOptions = resolvedPiOptions

        try Task.checkCancellation()
        // The corpus scans below are synchronous and can run for minutes on large session
        // archives. They execute on the dedicated scan queue so they never occupy a cooperative
        // pool thread; CostUsageScanExecutor bridges this task's cancellation into the
        // scanner-level checks.
        let scanOptions = options
        let daily = try await CostUsageScanExecutor.run { checkCancellation in
            var daily = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: scanOptions,
                checkCancellation: checkCancellation)
            try checkCancellation()

            if provider == .vertexai,
               !allowVertexClaudeFallback,
               scanOptions.claudeLogProviderFilter == .vertexAIOnly,
               daily.data.isEmpty
            {
                var fallback = scanOptions
                fallback.claudeLogProviderFilter = .all
                daily = try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: fallback,
                    checkCancellation: checkCancellation)
                try checkCancellation()
            }

            if includePiSessions && (provider == .codex || provider == .claude) {
                let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: piOptions,
                    checkCancellation: checkCancellation)
                try checkCancellation()
                daily = CostUsageDailyReport.merged([daily, piReport])
            }
            if daily.scanIncomplete, daily.data.isEmpty {
                return CostUsageDailyReport(
                    data: [],
                    summary: nil,
                    scanIncomplete: true,
                    completedFiniteScanGeneration: daily.completedFiniteScanGeneration)
            }
            return daily
        }

        return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
    }

    static func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        includePiSessions: Bool = false,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CostUsageTokenSnapshot?
    {
        if let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            return nil
        }

        // Decoding the persisted scan cache parses multi-megabyte JSON; keep it off the
        // cooperative pool alongside the scans themselves.
        let cachedSnapshot: CostUsageTokenSnapshot?? = try? await CostUsageScanExecutor.run { _ in
            let clampedHistoryDays = max(1, min(365, historyDays))
            let until = now
            let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
            let options = overrideScannerOptions ?? CostUsageScanner.Options()
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
            var reports: [CostUsageDailyReport] = []

            if !cache.days.isEmpty,
               cache.roots == CostUsageScanner.codexRootsFingerprint(options: options),
               !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: cache)
            {
                let daily = CostUsageScanner.buildCodexReportFromCache(
                    cache: cache,
                    range: range,
                    modelsDevCacheRoot: options.cacheRoot)
                if !daily.data.isEmpty {
                    reports.append(daily)
                }
            }

            if includePiSessions,
               let piDaily = PiSessionCostScanner.loadCachedDailyReport(
                provider: .codex,
                since: since,
                until: until,
                now: now,
                cacheRoot: options.cacheRoot)
            {
                reports.append(piDaily)
            }

            guard !reports.isEmpty else { return nil }
            return Self.tokenSnapshot(
                from: CostUsageDailyReport.merged(reports),
                now: now,
                historyDays: clampedHistoryDays)
        }
        return cachedSnapshot.flatMap(\.self)
    }

    private static func loadBedrockDailyReport(
        environment: [String: String],
        since: Date,
        until: Date) async throws -> CostUsageDailyReport
    {
        let resolved = try await BedrockCredentialResolver.resolve(environment: environment)
        return try await BedrockUsageFetcher.fetchDailyReport(
            credentials: resolved.credentials,
            since: since,
            until: until,
            environment: environment)
    }

    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30) -> CostUsageTokenSnapshot
    {
        // Pick the most recent day; break ties by cost/tokens to keep a stable "session" row.
        let currentDay = daily.data.compactMap { entry -> (entry: CostUsageDailyReport.Entry, date: Date)? in
            guard let date = CostUsageDateParser.parse(entry.date) else { return nil }
            return (entry, date)
        }
        .max { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            let lCost = lhs.entry.costUSD ?? -1
            let rCost = rhs.entry.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.entry.totalTokens ?? -1
            let rTokens = rhs.entry.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.entry.date < rhs.entry.date
        }?.entry
        // Prefer summary totals when present; fall back to summing daily entries.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let last30DaysCostUSD = totalFromSummary ?? (totalFromEntries > 0 ? totalFromEntries : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let last30DaysTokens = totalTokensFromSummary ?? (totalTokensFromEntries > 0 ? totalTokensFromEntries : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: currentDay?.totalTokens,
            sessionCostUSD: currentDay?.costUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            daily: daily.data,
            projectBreakdown: daily.projectBreakdown,
            projectRetractions: daily.projectRetractions,
            updatedAt: now,
            scanIncomplete: daily.scanIncomplete,
            completedFiniteScanGeneration: daily.completedFiniteScanGeneration)
    }

    static func selectCurrentSession(from sessions: [CostUsageSessionReport.Entry])
        -> CostUsageSessionReport.Entry?
    {
        if sessions.isEmpty { return nil }
        return sessions.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.lastActivity) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.lastActivity) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.session < rhs.session
        }
    }

    static func selectMostRecentMonth(from months: [CostUsageMonthlyReport.Entry])
        -> CostUsageMonthlyReport.Entry?
    {
        if months.isEmpty { return nil }
        return months.max { lhs, rhs in
            let lDate = CostUsageDateParser.parseMonth(lhs.month) ?? .distantPast
            let rDate = CostUsageDateParser.parseMonth(rhs.month) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.month < rhs.month
        }
    }
}
