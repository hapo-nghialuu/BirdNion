import XCTest
@testable import BirdNion
@testable import CodexBarCore

/// Tests for `CodexCostScanner`, which delegates the actual log scan to
/// CodexBarCore's `CostUsageFetcher` and owns only the snapshot → summary
/// mapping and the history-window setting. Kept in its own file so the
/// `import CodexBarCore` (needed for `CostUsageTokenSnapshot`) doesn't clash
/// with BirdNion's own Codex types in `CodexProviderTests`.
final class CodexCostScannerTests: XCTestCase {
    private actor ReportPassProbe {
        private var forcedPasses: [Bool] = []
        private var remaining: [CodexCostScanner.ReportLoad]

        init(_ remaining: [CodexCostScanner.ReportLoad]) {
            self.remaining = remaining
        }

        func load(forceRefresh: Bool) async -> CodexCostScanner.ReportLoad {
            forcedPasses.append(forceRefresh)
            return remaining.removeFirst()
        }

        func calls() -> [Bool] { forcedPasses }
    }

    private actor SingleFlightProbe {
        private(set) var calls = 0
        private(set) var peakConcurrentCalls = 0
        private var activeCalls = 0

        func load(
            _ report: CodexUsageReport,
            completed: Bool = true) async -> CodexCostScanner.ReportLoad
        {
            calls += 1
            activeCalls += 1
            peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
            try? await Task.sleep(for: .milliseconds(50))
            activeCalls -= 1
            return .init(value: report, completed: completed)
        }

        func waitUntilCalled() async {
            while calls == 0 { await Task.yield() }
        }
    }

    private static func report(tokens: Int = 1) -> CodexUsageReport {
        CodexUsageReport(
            todayUSD: 0.01,
            todayTokens: tokens,
            last30USD: 0.01,
            last30Tokens: tokens,
            daily: [],
            topModel: "gpt-5")
    }

    private static func progress(
        generation: String = "test-generation",
        bytes: Int64,
        incompleteFiles: Int = 1,
        fingerprint: String? = nil) -> CodexCostScanner.ScanProgress
    {
        .init(
            generation: generation,
            parsedBytes: bytes,
            incompleteFiles: incompleteFiles,
            progressFingerprint: fingerprint
                ?? "\(generation)-\(bytes)-\(incompleteFiles)")
    }

    private func writeCodexFixture(
        root: URL,
        sessionID: String,
        cwds: [String?],
        directory: String = "sessions",
        fileSuffix: String = "primary"
    ) throws {
        let file = root.appendingPathComponent(
            "\(directory)/2026/08/20/rollout-2026-08-20T10-00-00-\(sessionID)-\(fileSuffix).jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = cwds.map { cwd -> String in
            let cwdField = cwd.map { ",\"cwd\":\"\($0)\"" } ?? ""
            return """
            {"timestamp":"2026-08-20T10:00:00.000Z","type":"session_meta",\
            "payload":{"id":"\(sessionID)","timestamp":"2026-08-20T10:00:00.000Z"\(cwdField)}}
            """
        }
        lines.append(
            #"{"timestamp":"2026-08-20T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5"}}"#)
        lines.append(
            #"{"timestamp":"2026-08-20T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50}}}}"#)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }

    func testMapsSnapshot() {
        // "session" totals are today's; "last30Days" totals span the window.
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 110,
            sessionCostUSD: 0.5,
            last30DaysTokens: 1050,
            last30DaysCostUSD: 4.25,
            daily: [],
            updatedAt: Date())
        let s = CodexCostScanner.map(snap)
        XCTAssertEqual(s.todayTokens, 110)
        XCTAssertEqual(s.todayUSD, 0.5)
        XCTAssertEqual(s.last30Tokens, 1050)
        XCTAssertEqual(s.last30USD, 4.25)
        XCTAssertFalse(s.isEmpty)
    }

    func testMapsNilTotalsToZero() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil,
            daily: [], updatedAt: Date())
        let s = CodexCostScanner.map(snap)
        XCTAssertEqual(s.todayTokens, 0)
        XCTAssertEqual(s.last30Tokens, 0)
        XCTAssertTrue(s.isEmpty)
    }

    func testSharedScanWindowPreventsSummaryAndChartRangeThrash() {
        XCTAssertEqual(CodexCostScanner.scanWindowDays(requestedWindowDays: 30), 120)
        XCTAssertEqual(CodexCostScanner.scanWindowDays(requestedWindowDays: 120), 120)
        XCTAssertEqual(CodexCostScanner.scanWindowDays(requestedWindowDays: 365), 365)
    }

    func testMapSummarySlicesRequestedWindowFromWiderScan() {
        let entries = [
            CostUsageDailyReport.Entry(
                date: "2026-07-01", inputTokens: 1_000, outputTokens: 0,
                totalTokens: 1_000, costUSD: 10, modelsUsed: nil, modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-08-30", inputTokens: 30, outputTokens: 0,
                totalTokens: 30, costUSD: 0.3, modelsUsed: nil, modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-08-31", inputTokens: 40, outputTokens: 0,
                totalTokens: 40, costUSD: 0.4, modelsUsed: nil, modelBreakdowns: nil),
        ]
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1_000,
            sessionCostUSD: 10,
            last30DaysTokens: 1_070,
            last30DaysCostUSD: 10.7,
            historyDays: 120,
            daily: entries,
            updatedAt: Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!

        let summary = CodexCostScanner.mapSummary(
            snapshot,
            now: now,
            windowDays: 2,
            calendar: calendar)

        XCTAssertEqual(summary.todayTokens, 40)
        XCTAssertEqual(summary.todayUSD, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(summary.last30Tokens, 70)
        XCTAssertEqual(summary.last30USD, 0.7, accuracy: 0.000_001)
    }

    func testSummaryCacheIsScopedToConfiguredWindow() async {
        let cache = CodexCostScanner.Cache()
        let now = Date(timeIntervalSince1970: 1_788_131_600)
        let summary = CodexCostSummary(
            todayUSD: 0.1,
            todayTokens: 10,
            last30USD: 0.5,
            last30Tokens: 50)
        await cache.store(summary, at: now, windowDays: 30)

        let sameWindow = await cache.valid(now: now, ttl: 300, windowDays: 30)
        let differentWindow = await cache.valid(now: now, ttl: 300, windowDays: 120)

        XCTAssertEqual(sameWindow, summary)
        XCTAssertNil(differentWindow)
    }

    func testPendingSummaryFallbackDoesNotCrossLocalDayBoundary() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-08-31T23:59:00Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-09-01T00:01:00Z")!
        let summary = CodexCostSummary(
            todayUSD: 0.1,
            todayTokens: 10,
            last30USD: 0.5,
            last30Tokens: 50)
        await cache.store(summary, at: beforeMidnight, windowDays: 30)

        let sameDay = await cache.lastSummary(
            windowDays: 30,
            now: beforeMidnight.addingTimeInterval(30),
            calendar: calendar)
        let nextDay = await cache.lastSummary(
            windowDays: 30,
            now: afterMidnight,
            calendar: calendar)

        XCTAssertEqual(sameDay, summary)
        XCTAssertNil(nextDay)
    }

    func testPopoverLifecycleRetriggersCodexOnlyForVisibleAllOrCodexViews() {
        XCTAssertTrue(QuotaPanelLifecycle.shouldRetriggerCodexAfterWindowOpened(
            isDropdown: true,
            providerID: "all"))
        XCTAssertTrue(QuotaPanelLifecycle.shouldRetriggerCodexAfterWindowOpened(
            isDropdown: true,
            providerID: "codex"))
        XCTAssertFalse(QuotaPanelLifecycle.shouldRetriggerCodexAfterWindowOpened(
            isDropdown: false,
            providerID: "codex"))
        XCTAssertFalse(QuotaPanelLifecycle.shouldRetriggerCodexAfterWindowOpened(
            isDropdown: true,
            providerID: "claude"))

        XCTAssertTrue(QuotaPanelLifecycle.shouldRetriggerCodexAfterDayChanged(
            hasVisibleDropdown: true,
            providerID: "all"))
        XCTAssertFalse(QuotaPanelLifecycle.shouldRetriggerCodexAfterDayChanged(
            hasVisibleDropdown: false,
            providerID: "all"))
        XCTAssertFalse(QuotaPanelLifecycle.shouldRetriggerCodexAfterDayChanged(
            hasVisibleDropdown: true,
            providerID: "claude"))
    }

    func testVendoredScanAttributesCWDWithoutChangingAggregateOrPersistingPath() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let namedHome = temp.appendingPathComponent("named")
        let anonymousHome = temp.appendingPathComponent("anonymous")
        let conflictHome = temp.appendingPathComponent("conflict")
        let invalidHome = temp.appendingPathComponent("invalid")
        let duplicateConflictHome = temp.appendingPathComponent("duplicate-conflict")
        let sequentialConflictHome = temp.appendingPathComponent("sequential-conflict")
        let cwd = "/Users/alice/Secret Client/birdnion"
        try writeCodexFixture(root: namedHome, sessionID: "named", cwds: [cwd])
        try writeCodexFixture(root: anonymousHome, sessionID: "anonymous", cwds: [nil])
        try writeCodexFixture(
            root: conflictHome, sessionID: "conflict",
            cwds: ["/Users/alice/work/first", "/Users/alice/work/second"])
        try writeCodexFixture(
            root: invalidHome, sessionID: "invalid",
            cwds: ["/Users/alice/work/valid", "relative/private"])
        try writeCodexFixture(
            root: duplicateConflictHome, sessionID: "duplicate",
            cwds: ["/Users/alice/work/one"], fileSuffix: "live")
        try writeCodexFixture(
            root: duplicateConflictHome, sessionID: "duplicate",
            cwds: ["/Users/alice/work/two"], directory: "archived_sessions",
            fileSuffix: "archive-a")
        try writeCodexFixture(
            root: duplicateConflictHome, sessionID: "duplicate",
            cwds: ["/Users/alice/work/three"], directory: "archived_sessions",
            fileSuffix: "archive-b")
        try writeCodexFixture(
            root: sequentialConflictHome, sessionID: "sequential",
            cwds: ["/Users/alice/work/original"], fileSuffix: "live")
        let now = ISO8601DateFormatter().date(from: "2026-08-20T18:00:00Z")!

        func scan(home: URL, cacheName: String) async throws -> CostUsageTokenSnapshot {
            let cacheRoot = temp.appendingPathComponent(cacheName)
            return try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: now,
                forceRefresh: true,
                codexHomePath: home.path,
                historyDays: 7,
                refreshPricingInBackground: false,
                scannerOptions: .init(cacheRoot: cacheRoot),
                piScannerOptions: .init(
                    piSessionsRoot: temp.appendingPathComponent("empty-pi"),
                    cacheRoot: cacheRoot))
        }

        let obsoleteCacheURL = temp.appendingPathComponent(
            "named-cache/cost-usage/codex-v11.json")
        try FileManager.default.createDirectory(
            at: obsoleteCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cwd":"/Users/alice/Secret Client/birdnion"}"#.utf8)
            .write(to: obsoleteCacheURL)

        let named = try await scan(home: namedHome, cacheName: "named-cache")
        let anonymous = try await scan(home: anonymousHome, cacheName: "anonymous-cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteCacheURL.path))
        XCTAssertEqual(named.daily, anonymous.daily)
        XCTAssertEqual(named.last30DaysTokens, anonymous.last30DaysTokens)
        let project = try XCTUnwrap(named.projectBreakdown?.first)
        XCTAssertEqual(
            project.projectKey,
            "a573b0cb3866c10add42b08d0b62f970ae5b2ec62fed0037666a74a3ea01b66d")
        XCTAssertEqual(project.projectName, "birdnion")
        XCTAssertEqual(project.daily.first?.totalTokens, 150)
        XCTAssertTrue(anonymous.projectBreakdown?.isEmpty != false)

        let cacheURL = temp.appendingPathComponent(
            "named-cache/cost-usage/codex-v12.json")
        let rawCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(rawCache.contains(cwd))
        XCTAssertFalse(rawCache.contains("Secret Client"))
        XCTAssertTrue(rawCache.contains(project.projectKey))
        XCTAssertTrue(rawCache.contains("birdnion"))

        let conflict = try await scan(home: conflictHome, cacheName: "conflict-cache")
        XCTAssertEqual(conflict.last30DaysTokens, named.last30DaysTokens)
        XCTAssertTrue(conflict.projectBreakdown?.isEmpty != false)
        let conflictCache = try String(
            contentsOf: temp.appendingPathComponent(
                "conflict-cache/cost-usage/codex-v12.json"),
            encoding: .utf8)
        XCTAssertFalse(conflictCache.contains("/Users/alice/work/first"))
        XCTAssertFalse(conflictCache.contains("/Users/alice/work/second"))

        let invalid = try await scan(home: invalidHome, cacheName: "invalid-cache")
        XCTAssertEqual(invalid.last30DaysTokens, named.last30DaysTokens)
        XCTAssertTrue(invalid.projectBreakdown?.isEmpty != false)

        let duplicateConflict = try await scan(
            home: duplicateConflictHome, cacheName: "duplicate-conflict-cache")
        XCTAssertEqual(duplicateConflict.last30DaysTokens, named.last30DaysTokens)
        XCTAssertTrue(duplicateConflict.projectBreakdown?.isEmpty != false)
        let retraction = try XCTUnwrap(duplicateConflict.projectRetractions?.first)
        XCTAssertEqual(retraction.retractionID.count, 64)
        XCTAssertEqual(retraction.projectKey.count, 64)
        XCTAssertEqual(retraction.daily.first?.totalTokens, 150)
        let duplicateCache = try String(
            contentsOf: temp.appendingPathComponent(
                "duplicate-conflict-cache/cost-usage/codex-v12.json"),
            encoding: .utf8)
        XCTAssertFalse(duplicateCache.contains("/Users/alice/work/one"))
        XCTAssertFalse(duplicateCache.contains("/Users/alice/work/two"))
        XCTAssertFalse(duplicateCache.contains("/Users/alice/work/three"))

        let sequentialFirst = try await scan(
            home: sequentialConflictHome, cacheName: "sequential-conflict-cache")
        let originalProject = try XCTUnwrap(sequentialFirst.projectBreakdown?.first)
        try writeCodexFixture(
            root: sequentialConflictHome, sessionID: "sequential",
            cwds: ["/Users/alice/work/conflict"], directory: "archived_sessions",
            fileSuffix: "archive")
        let sequentialSecond = try await scan(
            home: sequentialConflictHome, cacheName: "sequential-conflict-cache")
        let sequentialRepeated = try await scan(
            home: sequentialConflictHome, cacheName: "sequential-conflict-cache")
        XCTAssertTrue(sequentialSecond.projectBreakdown?.isEmpty != false)
        let sequentialRetraction = try XCTUnwrap(sequentialSecond.projectRetractions?.first)
        XCTAssertEqual(sequentialRetraction.projectKey, originalProject.projectKey)
        XCTAssertEqual(sequentialRetraction.daily.first?.totalTokens, 150)
        XCTAssertEqual(sequentialRepeated.projectRetractions, sequentialSecond.projectRetractions)
    }

    func testPrivacyMigrationRunsWithoutScanningCodex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("cost-usage/codex-v11.json")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cwd":"/Users/alice/Private"}"#.utf8).write(to: legacy)

        try CostUsageFetcher.performPrivacyMigrations(cacheRoot: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testHistoryDaysDefaultsAndClamps() {
        let key = CodexCostScanner.historyDaysKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 30)   // unset → default
        UserDefaults.standard.set(500, forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 365)  // clamped high
        UserDefaults.standard.set(-5, forKey: key)
        XCTAssertEqual(CodexCostScanner.historyDays, 1)    // clamped low
    }

    // MARK: - Full report (chart)

    private static func dayString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// `mapReport` builds a contiguous chartWindowDays series (heatmap window), reads
    /// "today" from the most recent active day, sums the strict-30-day totals
    /// from the trailing buckets, sorts per-day models by cost, and picks the
    /// highest-cost top model — matching CodexBar.
    func testMapsReportDaily() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let snap = CostUsageTokenSnapshot(
            sessionTokens: 999, sessionCostUSD: 9.99,   // session is ignored by the report
            last30DaysTokens: 314_000_000,
            last30DaysCostUSD: 311.01,
            daily: [
                .init(date: Self.dayString(yesterday),
                      inputTokens: nil, outputTokens: nil, totalTokens: 4_000_000,
                      costUSD: 6.71, modelsUsed: ["gpt-5.5"],
                      modelBreakdowns: [.init(modelName: "gpt-5.5", costUSD: 6.71, totalTokens: 4_000_000)]),
                .init(date: Self.dayString(today),
                      inputTokens: nil, outputTokens: nil, totalTokens: 5_000_000,
                      costUSD: 3.20, modelsUsed: ["gpt-5.5", "o3"],
                      modelBreakdowns: [
                          .init(modelName: "o3", costUSD: 1.20, totalTokens: 2_000_000),
                          .init(modelName: "gpt-5.5", costUSD: 2.00, totalTokens: 3_000_000),
                      ]),
            ],
            updatedAt: now)

        let r = CodexCostScanner.mapReport(snap, now: now)

        XCTAssertEqual(r.daily.count, CodexCostScanner.chartWindowDays)
        XCTAssertFalse(r.isEmpty)
        // Strict 30-day totals are summed from the trailing daily buckets
        // (the snapshot's own last30 fields span the 90-day fetch window).
        XCTAssertEqual(r.last30Tokens, 9_000_000)
        XCTAssertEqual(r.last30USD, 9.91, accuracy: 0.001)
        // "Today" = the most recent active day (today's bucket), not the session.
        XCTAssertEqual(r.todayTokens, 5_000_000)
        XCTAssertEqual(r.todayUSD, 3.20, accuracy: 0.001)
        // Newest bucket is today; its per-model rows are sorted by cost desc.
        let last = r.daily.last!
        XCTAssertEqual(last.tokens, 5_000_000)
        XCTAssertEqual(last.models.count, 2)
        XCTAssertEqual(last.models.first?.name, "gpt-5.5")  // $2.00 > $1.20
        // Top model across the window by summed cost: gpt-5.5 (6.71+2.00) > o3 (1.20).
        XCTAssertEqual(r.topModel, "gpt-5.5")
    }

    /// Totals are summed from the daily buckets even when the snapshot omits
    /// its own window fields; no models → nil topModel.
    func testMapsReportFallbackTokens() {
        let now = Date()
        let snap = CostUsageTokenSnapshot(
            sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil,
            daily: [
                .init(date: Self.dayString(now),
                      inputTokens: nil, outputTokens: nil, totalTokens: 1_234,
                      costUSD: 1.0, modelsUsed: nil, modelBreakdowns: nil),
            ],
            updatedAt: now)

        let r = CodexCostScanner.mapReport(snap, now: now)
        XCTAssertEqual(r.daily.count, CodexCostScanner.chartWindowDays)
        XCTAssertEqual(r.last30Tokens, 1_234)   // summed from daily buckets
        XCTAssertEqual(r.last30USD, 1.0, accuracy: 0.001)
        XCTAssertNil(r.topModel)                // no model breakdowns logged
    }

    func testFrozenPrefixSampleOffsetsDoNotOverflowAtInt64Maximum() {
        let offsets = CostUsageScanner.codexFrozenPrefixSampleOffsets(
            targetEOF: Int64.max,
            sampleSize: 16 * 1024)

        XCTAssertEqual(offsets, [
            0,
            2_305_843_009_213_685_759,
            4_611_686_018_427_379_711,
            6_917_529_027_641_073_663,
            9_223_372_036_854_759_423,
        ])
    }

    func testPendingParsedBytesSumClampsNegativesAndSaturatesAtInt64Maximum() {
        XCTAssertEqual(
            CostUsageFetcher.saturatingParsedBytesSum([
                Int64.max - 2,
                -100,
                1,
                2,
            ]),
            Int64.max)
        XCTAssertEqual(
            CostUsageFetcher.saturatingParsedBytesSum([-5, 7, -3]),
            7)
    }

    func testJsonlBoundedScanResumesAtCompleteLineBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("large.jsonl")
        let first = #"{"type":"first"}"#
        let second = #"{"type":"second","payload":""# + String(repeating: "x", count: 300_000) + #""}"#
        try Data("\(first)\n\(second)\n".utf8).write(to: file)

        var stopChecks = 0
        var firstPassLines: [String] = []
        let partial = try CostUsageJsonl.scanResumable(
            fileURL: file,
            maxLineBytes: 512 * 1024,
            prefixBytes: 512 * 1024,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 2
            },
            onLine: { firstPassLines.append(String(decoding: $0.bytes, as: UTF8.self)) })

        XCTAssertTrue(partial.stoppedEarly)
        XCTAssertEqual(firstPassLines, [first])
        XCTAssertEqual(partial.parsedBytes, Int64(first.utf8.count + 1))

        var resumedLines: [String] = []
        let resumed = try CostUsageJsonl.scanResumable(
            fileURL: file,
            offset: partial.parsedBytes,
            maxLineBytes: 512 * 1024,
            prefixBytes: 512 * 1024,
            onLine: { resumedLines.append(String(decoding: $0.bytes, as: UTF8.self)) })

        XCTAssertFalse(resumed.stoppedEarly)
        XCTAssertEqual(resumedLines, [second])
        XCTAssertEqual(resumed.parsedBytes, Int64(first.utf8.count + second.utf8.count + 2))
    }

    func testJsonlOversizedLineResumesInDiscardModeWithoutEmittingItsSuffix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-oversized-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("oversized.jsonl")
        let chunkBytes = 256 * 1024
        let maxLineBytes = 256 * 1024
        let suffix = #"{"type":"must-not-emit"}"#
        let following = #"{"type":"following"}"#
        var fixture = Data(repeating: 0x78, count: chunkBytes * 2)
        fixture.append(Data("\(suffix)\n\(following)\n".utf8))
        try fixture.write(to: file)

        var stopChecks = 0
        var firstPassTruncation: [Bool] = []
        let partial = try CostUsageJsonl.scanResumable(
            fileURL: file,
            maxLineBytes: maxLineBytes,
            prefixBytes: maxLineBytes,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 4
            },
            onLine: { firstPassTruncation.append($0.wasTruncated) })

        XCTAssertEqual(stopChecks, 4)
        XCTAssertTrue(partial.stoppedEarly)
        XCTAssertGreaterThan(partial.parsedBytes, 0)
        XCTAssertEqual(partial.parsedBytes, Int64(chunkBytes * 2))
        XCTAssertTrue(partial.discardingTruncatedLine)
        XCTAssertEqual(firstPassTruncation, [true])

        var resumedLines: [String] = []
        var resumedTruncation: [Bool] = []
        let resumed = try CostUsageJsonl.scanResumable(
            fileURL: file,
            offset: partial.parsedBytes,
            maxLineBytes: maxLineBytes,
            prefixBytes: maxLineBytes,
            discardingTruncatedLine: partial.discardingTruncatedLine,
            onLine: {
                resumedLines.append(String(decoding: $0.bytes, as: UTF8.self))
                resumedTruncation.append($0.wasTruncated)
            })

        XCTAssertFalse(resumed.stoppedEarly)
        XCTAssertFalse(resumed.discardingTruncatedLine)
        XCTAssertEqual(resumed.parsedBytes, Int64(fixture.count))
        XCTAssertEqual(resumedLines, [following])
        XCTAssertEqual(resumedTruncation, [false])
    }

    func testMetadataLessOversizedCodexParseConvergesAtFrozenEOFWithoutRecounting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-metadata-less-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("metadata-less.jsonl")
        let chunkBytes = 256 * 1024

        func tokenLine(timestamp: String, input: Int) -> String {
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":0},\
            "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":0}}}}
            """
        }

        let discardedSuffix = tokenLine(
            timestamp: "2026-08-20T10:00:00.000Z", input: 999)
        let following = tokenLine(
            timestamp: "2026-08-20T10:00:01.000Z", input: 17)
        var fixture = Data(repeating: 0x78, count: chunkBytes * 2)
        fixture.append(Data("\(discardedSuffix)\n\(following)\n".utf8))
        try fixture.write(to: file)
        let targetEOF = Int64(fixture.count)
        let range = CostUsageScanner.CostUsageDayRange(
            scanSinceKey: "2026-08-19",
            scanUntilKey: "2026-08-21")

        var stopChecks = 0
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 12
            },
            endOffset: targetEOF)

        XCTAssertEqual(stopChecks, 12)
        XCTAssertFalse(partial.scanComplete)
        XCTAssertGreaterThan(partial.parsedBytes, 0)
        XCTAssertEqual(partial.parsedBytes, Int64(chunkBytes * 2))
        XCTAssertLessThan(partial.parsedBytes, targetEOF)
        XCTAssertEqual(partial.resumeState.discardingTruncatedLine, true)
        XCTAssertNil(partial.sessionId)
        XCTAssertTrue(partial.rows.isEmpty)
        XCTAssertTrue(partial.days.isEmpty)

        let resumed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: partial.parsedBytes,
            initialResumeState: partial.resumeState,
            endOffset: targetEOF)

        XCTAssertTrue(resumed.scanComplete)
        XCTAssertEqual(resumed.parsedBytes, targetEOF)
        XCTAssertEqual(resumed.resumeState.discardingTruncatedLine, false)
        XCTAssertNil(resumed.sessionId)
        XCTAssertEqual(resumed.rows.count, 1)
        XCTAssertEqual(resumed.rows.first?.input, 17)
        XCTAssertEqual(resumed.lastCountedTotals?.input, 17)
    }

    func testTruncatedScanDoesNotFinalizeGlobalCacheMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-bounded-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let traceDatabaseURL = root.appendingPathComponent("missing-codex-trace.sqlite")
        try writeCodexFixture(root: home, sessionID: "bounded", cwds: ["/tmp/bounded"])
        let now = ISO8601DateFormatter().date(from: "2026-08-20T18:00:00Z")!

        let partial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(partial.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(pending.lastScanUnixMs, 0)
        XCTAssertNil(pending.scanSinceKey)
        XCTAssertNil(pending.scanUntilKey)
        XCTAssertNotNil(pending.codexPendingScanGeneration)

        let complete = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(complete.scanIncomplete)
        var finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertGreaterThan(finalized.lastScanUnixMs, 0)
        XCTAssertNotNil(finalized.scanSinceKey)
        XCTAssertNotNil(finalized.scanUntilKey)
        XCTAssertNil(finalized.codexPendingScanGeneration)

        // Seed a valid bounded episode through the public scanner API, then
        // make only its persisted per-file completion marker stale at EOF.
        let bounded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(bounded.scanIncomplete)
        finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotNil(finalized.codexPendingScanGeneration)
        XCTAssertNotNil(finalized.codexPendingScanSinceKey)
        XCTAssertNotNil(finalized.codexPendingScanUntilKey)
        XCTAssertNotNil(finalized.codexPendingFileManifest)
        XCTAssertNotNil(finalized.codexPendingFiles)
        XCTAssertNotNil(finalized.codexPendingDays)
        let pendingManifest = try XCTUnwrap(finalized.codexPendingFileManifest)
        XCTAssertEqual(pendingManifest.count, 1)
        XCTAssertTrue(pendingManifest.keys.allSatisfy {
            $0 == URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let filePath = try XCTUnwrap(finalized.codexPendingFileManifest?.keys.first)
        let target = try XCTUnwrap(finalized.codexPendingFileManifest?[filePath])
        let pendingFile = try XCTUnwrap(finalized.codexPendingFiles?[filePath])
        XCTAssertEqual(pendingFile.parsedBytes, target.targetEOF)
        finalized.codexPendingFiles?[filePath]?.codexScanComplete = false
        CostUsageCacheIO.save(provider: .codex, cache: finalized, cacheRoot: cacheRoot)

        let resumed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(resumed.scanIncomplete)
        XCTAssertEqual(resumed.last30DaysTokens, complete.last30DaysTokens)
        let resumedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(resumedCache.files[filePath]?.codexScanComplete, true)
        XCTAssertNil(resumedCache.codexPendingScanGeneration)
    }

    func testReportEpisodeRetriesIncompleteScanExactlyOnce() async {
        let report = Self.report(tokens: 42)
        let probe = ReportPassProbe([
            .init(value: nil, completed: false, progress: Self.progress(bytes: 10)),
            .init(value: report, completed: true),
        ])

        let result = await CodexCostScanner.runReportEpisode { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 42)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [false, true])
    }

    func testReportEpisodeStopsImmediatelyAfterPublishingFiniteGenerationWithCatchUpPending() async {
        let initialProgress = Self.progress(generation: "finite", bytes: 100)
        let catchUpProgress = Self.progress(generation: "catch-up", bytes: 1)
        let probe = ReportPassProbe([
            .init(
                value: nil,
                completed: false,
                progress: catchUpProgress,
                publishedSnapshot: true),
        ])

        let result = await CodexCostScanner.runReportEpisode(initialProgress: initialProgress) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.publishedSnapshot)
        XCTAssertNil(result.value)
        XCTAssertEqual(result.progress?.generation, "catch-up")
        XCTAssertEqual(result.progress?.parsedBytes, 1)
        XCTAssertEqual(result.progress?.incompleteFiles, 1)
        XCTAssertEqual(result.progress?.progressFingerprint, "catch-up-1-1")
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true])
    }

    func testReportEpisodeContinuesUntilDurableGenerationCompletes() async {
        let history = Self.report(tokens: 7)
        let completed = Self.report(tokens: 77)
        let probe = ReportPassProbe([
            .init(value: history, completed: false, progress: Self.progress(bytes: 10)),
            .init(value: history, completed: false, progress: Self.progress(bytes: 20)),
            .init(value: history, completed: false, progress: Self.progress(bytes: 30)),
            .init(value: completed, completed: true),
        ])

        let result = await CodexCostScanner.runReportEpisode { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 77)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [false, true, true, true])
    }

    func testReportEpisodeStopsWhenLaterPassMakesNoDurableProgress() async {
        let history = Self.report(tokens: 7)
        let stalled = Self.progress(bytes: 20)
        let probe = ReportPassProbe([
            .init(value: history, completed: false, progress: Self.progress(bytes: 10)),
            .init(value: history, completed: false, progress: stalled),
            .init(value: history, completed: false, progress: stalled),
        ])

        let result = await CodexCostScanner.runReportEpisode { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 7)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [false, true, true])
    }

    func testReportEpisodeForcesAndContinuesExistingJournalOnlyAfterProgress() async {
        let initial = Self.progress(bytes: 10)
        let probe = ReportPassProbe([
            .init(value: nil, completed: false, progress: Self.progress(bytes: 20)),
            .init(value: Self.report(tokens: 8), completed: true),
        ])

        let result = await CodexCostScanner.runReportEpisode(initialProgress: initial) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 8)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true, true])
    }

    func testReportEpisodeStopsWhenExistingJournalMakesNoProgress() async {
        let history = Self.report(tokens: 6)
        let initial = Self.progress(bytes: 10)
        let probe = ReportPassProbe([
            .init(value: history, completed: false, progress: initial),
        ])

        let result = await CodexCostScanner.runReportEpisode(initialProgress: initial) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 6)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true])
    }

    func testReportEpisodeAllowsCatchUpGenerationAfterDurableProgress() async {
        let initial = Self.progress(generation: "old", bytes: 100)
        let probe = ReportPassProbe([
            .init(
                value: nil,
                completed: false,
                progress: Self.progress(generation: "catch-up", bytes: 1)),
            .init(value: Self.report(tokens: 9), completed: true),
        ])

        let result = await CodexCostScanner.runReportEpisode(initialProgress: initial) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true, true])
    }

    func testReportEpisodeRecognizesColdDiscoveryCursorProgressWithoutNewBytes() async {
        let initial = Self.progress(bytes: 0, fingerprint: "cursor-1")
        let probe = ReportPassProbe([
            .init(
                value: nil,
                completed: false,
                progress: Self.progress(bytes: 0, fingerprint: "cursor-2")),
            .init(value: Self.report(tokens: 10), completed: true),
        ])

        let result = await CodexCostScanner.runReportEpisode(initialProgress: initial) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true, true])
    }

    func testDurablePendingJournalWinsWhenScannerThrowsBeforeSnapshot() {
        XCTAssertTrue(CodexCostScanner.hasUnfinishedScan(
            snapshotIncomplete: nil,
            progress: Self.progress(bytes: 10)))
        XCTAssertTrue(CodexCostScanner.hasUnfinishedScan(
            snapshotIncomplete: false,
            progress: Self.progress(bytes: 10)))
        XCTAssertFalse(CodexCostScanner.hasUnfinishedScan(
            snapshotIncomplete: nil,
            progress: nil))
    }

    func testReportEpisodeDoesNotRetryWithoutDurablePendingProgress() async {
        let history = Self.report(tokens: 3)
        let probe = ReportPassProbe([
            .init(value: history, completed: false),
        ])

        let result = await CodexCostScanner.runReportEpisode { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 3)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [false])
    }

    func testReportCacheCoalescesConcurrentCallers() async {
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let report = Self.report(tokens: 99)
        let now = Date(timeIntervalSince1970: 1_788_131_600)

        async let first = cache.report(now: now, ttl: 300) {
            await probe.load(report)
        }
        async let second = cache.report(now: now, ttl: 300) {
            await probe.load(report)
        }
        let (firstValue, secondValue) = await (first, second)
        let values = [firstValue, secondValue]
        let callCount = await probe.calls

        XCTAssertEqual(values.compactMap(\.value?.todayTokens), [99, 99])
        XCTAssertEqual(callCount, 1)
    }

    func testReportCacheExpiresAtLocalDayBoundaryEvenWithinTTL() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-08-31T23:59:00Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-09-01T00:01:00Z")!
        let report = Self.report(tokens: 5)

        await cache.storeReport(report, at: beforeMidnight)

        let cached = await cache.validReport(
            now: beforeMidnight.addingTimeInterval(30), ttl: 300, calendar: calendar)
        let expired = await cache.validReport(now: afterMidnight, ttl: 300, calendar: calendar)
        XCTAssertEqual(cached?.todayTokens, 5)
        XCTAssertNil(expired)
    }

    func testReportCacheDoesNotMemoizePendingHistoryFallback() async {
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let report = Self.report(tokens: 11)
        let now = Date(timeIntervalSince1970: 1_788_131_600)

        _ = await cache.report(now: now, ttl: 300) {
            await probe.load(report, completed: false)
        }
        _ = await cache.report(now: now, ttl: 300) {
            await probe.load(report, completed: false)
        }
        let callCount = await probe.calls

        XCTAssertEqual(callCount, 2)
    }

    func testReportCacheBypassesFreshEntryWhenCoreJournalIsPending() async {
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let now = Date(timeIntervalSince1970: 1_788_131_600)
        await cache.storeReport(Self.report(tokens: 5), at: now)

        let result = await cache.report(
            now: now,
            ttl: 300,
            bypassCache: true)
        {
            await probe.load(Self.report(tokens: 99))
        }

        let callCount = await probe.calls
        XCTAssertEqual(result.value?.todayTokens, 99)
        XCTAssertEqual(callCount, 1)
    }

    func testReportCacheSerializesNewDayBehindOldInFlightScan() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let report = Self.report(tokens: 13)
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-08-31T23:59:59Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-09-01T00:00:01Z")!

        let oldDay = Task {
            await cache.report(now: beforeMidnight, ttl: 300, calendar: calendar) {
                await probe.load(report)
            }
        }
        await probe.waitUntilCalled()
        let newDay = Task {
            await cache.report(now: afterMidnight, ttl: 300, calendar: calendar) {
                await probe.load(report)
            }
        }
        _ = await (oldDay.value, newDay.value)
        let callCount = await probe.calls
        let peak = await probe.peakConcurrentCalls

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(peak, 1)
    }

    func testCancellingOneWaiterDoesNotCancelSharedReportScan() async {
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let report = Self.report(tokens: 17)
        let now = Date(timeIntervalSince1970: 1_788_131_600)

        let owner = Task {
            await cache.report(now: now, ttl: 300) {
                await probe.load(report)
            }
        }
        await probe.waitUntilCalled()
        let waiter = Task {
            await cache.report(now: now, ttl: 300) {
                await probe.load(report)
            }
        }
        waiter.cancel()
        let ownerResult = await owner.value
        let waiterResult = await waiter.value
        let callCount = await probe.calls

        XCTAssertEqual(ownerResult.value?.todayTokens, 17)
        XCTAssertEqual(waiterResult.value?.todayTokens, 17)
        XCTAssertEqual(callCount, 1)
    }
}
