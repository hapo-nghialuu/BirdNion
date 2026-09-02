import XCTest
import SQLite3
@testable import BirdNion
@testable import CodexBarCore

/// Tests for `CodexCostScanner`, which delegates the actual log scan to
/// CodexBarCore's `CostUsageFetcher` and owns only the snapshot → summary
/// mapping and the history-window setting. Kept in its own file so the
/// `import CodexBarCore` (needed for `CostUsageTokenSnapshot`) doesn't clash
/// with BirdNion's own Codex types in `CodexProviderTests`.
final class CodexCostScannerTests: XCTestCase {
    private actor DelayedFailingModelsDevTransport: ModelsDevHTTPTransport {
        private var requestCount = 0

        func data(for _: URLRequest) async throws -> (Data, URLResponse) {
            self.requestCount += 1
            try await Task.sleep(for: .milliseconds(100))
            throw URLError(.cannotConnectToHost)
        }

        func calls() -> Int { self.requestCount }
    }

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
        private var finishedCalls = 0

        func load(
            _ report: CodexUsageReport,
            completed: Bool = true) async -> CodexCostScanner.ReportLoad
        {
            calls += 1
            activeCalls += 1
            peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
            try? await Task.sleep(for: .milliseconds(50))
            activeCalls -= 1
            finishedCalls += 1
            return .init(value: report, completed: completed)
        }

        func waitUntilCalled() async {
            while calls == 0 { await Task.yield() }
        }

        func waitUntilFinished(_ count: Int = 1) async {
            while finishedCalls < count { await Task.yield() }
        }
    }

    private actor CatchUpRaceProbe {
        private var started = false
        private var released = false
        private var finished = false

        func load(_ report: CodexUsageReport) async -> CodexCostScanner.ReportLoad {
            await load(.init(value: report, completed: true))
        }

        func load(
            _ result: CodexCostScanner.ReportLoad) async -> CodexCostScanner.ReportLoad
        {
            started = true
            while !released { await Task.yield() }
            finished = true
            return result
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func release() { released = true }

        func waitUntilFinished() async {
            while !finished { await Task.yield() }
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

    private func waitForCachedReport(
        _ cache: CodexCostScanner.Cache,
        now: Date,
        calendar: Calendar = .current,
        expectedTokens: Int) async -> CodexUsageReport?
    {
        for _ in 0..<200 {
            if let report = await cache.validReport(now: now, ttl: 300, calendar: calendar),
               report.todayTokens == expectedTokens
            {
                return report
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await cache.validReport(now: now, ttl: 300, calendar: calendar)
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

    private func writeIncrementalCodexFixture(
        root: URL,
        partition: String,
        sessionID: String,
        timestamp: String,
        totalTokens: Int) throws -> URL
    {
        let file = root.appendingPathComponent(
            "sessions/\(partition)/rollout-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            """
            {"timestamp":"\(timestamp)","type":"session_meta",\
            "payload":{"id":"\(sessionID)","timestamp":"\(timestamp)"}}
            """,
            #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":\(totalTokens),"cached_input_tokens":0,"output_tokens":0},\
            "last_token_usage":{"input_tokens":\(totalTokens),"cached_input_tokens":0,"output_tokens":0}}}}
            """,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    private func appendIncrementalCodexUsage(
        to file: URL,
        timestamp: String,
        totalTokens: Int,
        lastTokens: Int) throws
    {
        let line = """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":\(totalTokens),"cached_input_tokens":0,"output_tokens":0},\
        "last_token_usage":{"input_tokens":\(lastTokens),"cached_input_tokens":0,"output_tokens":0}}}}
        """
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func writePriorityTurnCodexFixture(
        root: URL,
        partition: String,
        sessionID: String,
        turnID: String,
        timestamp: String,
        inputTokens: Int) throws -> URL
    {
        let file = root.appendingPathComponent(
            "sessions/\(partition)/rollout-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            """
            {"timestamp":"\(timestamp)","type":"session_meta",\
            "payload":{"id":"\(sessionID)","timestamp":"\(timestamp)"}}
            """,
            #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turnID)"}}"#,
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":\(inputTokens),"cached_input_tokens":0,"output_tokens":0},\
            "last_token_usage":{"input_tokens":\(inputTokens),"cached_input_tokens":0,"output_tokens":0}}}}
            """,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file.standardizedFileURL
    }

    private func createCodexPriorityTraceDatabase(at databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        let openCode = sqlite3_open(databaseURL.path, &database)
        guard openCode == SQLITE_OK, let opened = database else {
            sqlite3_close(database)
            throw NSError(
                domain: "CodexCostScannerTests.SQLite",
                code: Int(openCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not create priority trace database"])
        }
        defer { sqlite3_close(opened) }
        for statement in [
            "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, feedback_log_body TEXT NOT NULL)",
            "CREATE INDEX idx_logs_ts ON logs(ts)",
        ] {
            let code = sqlite3_exec(opened, statement, nil, nil, nil)
            guard code == SQLITE_OK else {
                throw NSError(
                    domain: "CodexCostScannerTests.SQLite",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
            }
        }
    }

    private func enableCodexPriorityTraceWAL(at databaseURL: URL) throws {
        var database: OpaquePointer?
        let openCode = sqlite3_open(databaseURL.path, &database)
        guard openCode == SQLITE_OK, let opened = database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexCostScannerTests.SQLite", code: Int(openCode))
        }
        defer { sqlite3_close(opened) }
        let pragmaCode = sqlite3_exec(opened, "PRAGMA journal_mode=WAL", nil, nil, nil)
        guard pragmaCode == SQLITE_OK else {
            throw NSError(domain: "CodexCostScannerTests.SQLite", code: Int(pragmaCode))
        }
    }

    private func appendCodexPriorityTurn(
        to databaseURL: URL,
        turnID: String,
        timestamp: Date,
        model: String = "gpt-5") throws
    {
        let body = """
        thread_id=test-thread turn.id=\(turnID) websocket request: \
        {"type":"response.create","service_tier":"priority","model":"\(model)"}
        """
        try insertCodexTraceBodies([body], into: databaseURL, timestamp: timestamp)
    }

    private func appendCodexCompletedTurn(
        to databaseURL: URL,
        turnID: String,
        timestamp: Date,
        model: String) throws
    {
        let body = """
        turn.id=\(turnID) websocket event: \
        {"type":"response.completed","response":{"model":"\(model)"}}
        """
        try insertCodexTraceBodies([body], into: databaseURL, timestamp: timestamp)
    }

    private func deleteAllCodexPriorityTurns(from databaseURL: URL) throws {
        var database: OpaquePointer?
        let openCode = sqlite3_open(databaseURL.path, &database)
        guard openCode == SQLITE_OK, let opened = database else {
            sqlite3_close(database)
            throw NSError(
                domain: "CodexCostScannerTests.SQLite",
                code: Int(openCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not open priority trace database"])
        }
        defer { sqlite3_close(opened) }
        let deleteCode = sqlite3_exec(opened, "DELETE FROM logs", nil, nil, nil)
        guard deleteCode == SQLITE_OK else {
            throw NSError(
                domain: "CodexCostScannerTests.SQLite",
                code: Int(deleteCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
        }
    }

    private func seedFreshModelsDevPricingCache(at cacheRoot: URL) {
        ModelsDevCache.save(
            catalog: ModelsDevCatalog(providers: [:]),
            fetchedAt: Date(timeIntervalSince1970: 4_102_444_800),
            cacheRoot: cacheRoot)
    }

    func testModelsDevPricingRefreshIsSingleFlightPerCache() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-models-dev-singleflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let transport = DelayedFailingModelsDevTransport()
        let client = ModelsDevClient(transport: transport)

        async let first: Void = ModelsDevPricingPipeline.refreshIfNeeded(
            cacheRoot: cacheRoot,
            client: client)
        async let second: Void = ModelsDevPricingPipeline.refreshIfNeeded(
            cacheRoot: cacheRoot,
            client: client)
        _ = await (first, second)

        let requestCount = await transport.calls()
        XCTAssertEqual(requestCount, 1)
    }

    private func codexUsagePayloadExcludingTurnIDBackfillReceipt(
        _ usage: CostUsageFileUsage) throws -> Data
    {
        let encoded = try JSONEncoder().encode(usage)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in [
            "codexTurnIDs",
            "codexScanGeneration",
            "codexScanComplete",
            "codexScanTargetSize",
            "codexScanFileId",
            "codexScanContentFingerprint",
            "codexTurnIDBackfillDiscardingTruncatedLine",
        ] {
            object.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func insertCodexTraceBodies(
        _ bodies: [String],
        into databaseURL: URL,
        timestamp: Date) throws
    {
        var database: OpaquePointer?
        let openCode = sqlite3_open(databaseURL.path, &database)
        guard openCode == SQLITE_OK, let opened = database else {
            sqlite3_close(database)
            throw NSError(
                domain: "CodexCostScannerTests.SQLite",
                code: Int(openCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not open priority trace database"])
        }
        defer { sqlite3_close(opened) }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(
            opened,
            "INSERT INTO logs(ts, feedback_log_body) VALUES (?, ?)",
            -1,
            &statement,
            nil)
        guard prepareCode == SQLITE_OK, let prepared = statement else {
            throw NSError(
                domain: "CodexCostScannerTests.SQLite",
                code: Int(prepareCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
        }
        defer { sqlite3_finalize(prepared) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for body in bodies {
            sqlite3_reset(prepared)
            sqlite3_clear_bindings(prepared)
            sqlite3_bind_int64(prepared, 1, Int64(timestamp.timeIntervalSince1970))
            sqlite3_bind_text(prepared, 2, body, -1, transient)
            let stepCode = sqlite3_step(prepared)
            guard stepCode == SQLITE_DONE else {
                throw NSError(
                    domain: "CodexCostScannerTests.SQLite",
                    code: Int(stepCode),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(opened))])
            }
        }
    }

    private func updateCodexTraceBody(
        rowID: Int64,
        body: String,
        in databaseURL: URL) throws
    {
        var database: OpaquePointer?
        let openCode = sqlite3_open(databaseURL.path, &database)
        guard openCode == SQLITE_OK, let opened = database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexCostScannerTests.SQLite", code: Int(openCode))
        }
        defer { sqlite3_close(opened) }
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(
            opened,
            "UPDATE logs SET feedback_log_body = ? WHERE rowid = ?",
            -1,
            &statement,
            nil)
        guard prepareCode == SQLITE_OK, let prepared = statement else {
            throw NSError(domain: "CodexCostScannerTests.SQLite", code: Int(prepareCode))
        }
        defer { sqlite3_finalize(prepared) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(prepared, 1, body, -1, transient)
        sqlite3_bind_int64(prepared, 2, rowID)
        let stepCode = sqlite3_step(prepared)
        guard stepCode == SQLITE_DONE else {
            throw NSError(domain: "CodexCostScannerTests.SQLite", code: Int(stepCode))
        }
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
            seedFreshModelsDevPricingCache(at: cacheRoot)
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
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("missing-codex-trace.sqlite")
        try writeCodexFixture(root: home, sessionID: "bounded", cwds: ["/tmp/bounded"])
        let sessionFile = home.appendingPathComponent(
            "sessions/2026/08/20/rollout-2026-08-20T10-00-00-bounded-primary.jsonl")
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
        XCTAssertEqual(
            pending.codexPendingManifestContractVersion,
            CostUsageScanner.codexPendingManifestContractVersion)

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
        // make only its persisted per-file completion marker absent at EOF.
        // Older catch-up journals used this exact nil state, which the scanner
        // accepted as fresh without durably recording traversal progress.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: sessionFile.path)
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
        finalized.codexPendingFiles?[filePath]?.codexScanComplete = nil
        CostUsageCacheIO.save(provider: .codex, cache: finalized, cacheRoot: cacheRoot)
        let nilMarkerStatus = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        XCTAssertEqual(nilMarkerStatus?.incompleteFiles, 1)

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
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

    func testWarmRefreshQueuesOnlyChangedSessionAndRetainsHistoricalTotal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-warm-delta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let historical = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "historical",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let active = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "cross-midnight-active",
            timestamp: "2026-08-19T10:00:00.000Z",
            totalTokens: 200)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-3600)],
            ofItemAtPath: historical.path)
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-72 * 60 * 60)],
            ofItemAtPath: active.path)

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(baseline.last30DaysTokens, 300)

        let updateNow = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        try appendIncrementalCodexUsage(
            to: active,
            timestamp: "2026-08-20T11:00:00.000Z",
            totalTokens: 250,
            lastTokens: 50)
        try FileManager.default.setAttributes(
            [.modificationDate: updateNow.addingTimeInterval(-1800)],
            ofItemAtPath: active.path)
        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: updateNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot, maxScanWallClock: 0))
        XCTAssertTrue(seeded.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [active.path])
        XCTAssertNotNil(pending.codexPendingFiles?[historical.path])
        let status = await CostUsageFetcher(cacheRoot: cacheRoot).loadCodexPendingScanStatus()
        XCTAssertEqual(status?.incompleteFiles, 1)

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: updateNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: updateNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.sessionTokens, 50)
        XCTAssertEqual(completed.last30DaysTokens, 350)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotNil(finalized.files[historical.path])
        XCTAssertNil(finalized.codexPendingScanGeneration)
    }

    func testDayRolloverUsesWarmDeltaButEarlierHistoryExpansionUsesColdManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-rollover-delta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let archived = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/10",
            sessionID: "archived-before-initial-window",
            timestamp: "2026-08-10T10:00:00.000Z",
            totalTokens: 50)
        let historical = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "historical-in-window",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let oldMtime = baselineNow.addingTimeInterval(-72 * 60 * 60)
        for file in [archived, historical] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldMtime],
                ofItemAtPath: file.path)
        }

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(baseline.last30DaysTokens, 100)
        let baselineCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)

        let rolloverNow = ISO8601DateFormatter().date(from: "2026-08-21T10:00:00Z")!
        let current = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/21",
            sessionID: "new-day-session",
            timestamp: "2026-08-21T09:00:00.000Z",
            totalTokens: 200)
        try FileManager.default.setAttributes(
            [.modificationDate: rolloverNow],
            ofItemAtPath: current.path)

        let rolloverSeed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: rolloverNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(rolloverSeed.scanIncomplete)
        let rolloverPending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(rolloverPending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [current.path],
            "Advancing to a new day must not reopen unchanged historical files")
        XCTAssertGreaterThan(
            try XCTUnwrap(rolloverPending.codexPendingScanSinceKey),
            try XCTUnwrap(baselineCache.codexLastSuccessfulRequestScanSinceKey))
        XCTAssertGreaterThan(
            try XCTUnwrap(rolloverPending.codexPendingScanUntilKey),
            try XCTUnwrap(baselineCache.codexLastSuccessfulRequestScanUntilKey))

        let rolloverPublished = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: rolloverNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(rolloverPublished.scanIncomplete)
        XCTAssertTrue(rolloverPublished.completedFiniteScanGeneration)
        let rolloverComplete = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: rolloverNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(rolloverComplete.scanIncomplete)
        XCTAssertEqual(rolloverComplete.last30DaysTokens, 300)
        let rolloverFinalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)

        let expandedSeed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: rolloverNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 14,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(expandedSeed.scanIncomplete)
        let expandedPending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(expandedPending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [archived.path, historical.path, current.path],
            "Expanding backward must inventory the newly requested history")
        XCTAssertLessThan(
            try XCTUnwrap(expandedPending.codexPendingScanSinceKey),
            try XCTUnwrap(rolloverFinalCache.codexLastSuccessfulRequestScanSinceKey))
    }

    func testPendingEpisodeCrossesOneLocalMidnightAndQueuesNewDayFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-one-midnight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let waiter = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/20",
            sessionID: "one-midnight-waiter",
            timestamp: "2026-08-20T10:00:00.000Z",
            totalTokens: 100)
        let formatter = ISO8601DateFormatter()
        let baselineNow = try XCTUnwrap(
            formatter.date(from: "2026-08-20T23:58:00+07:00"))
        let captureNow = try XCTUnwrap(
            formatter.date(from: "2026-08-20T23:59:00+07:00"))
        let afterMidnight = try XCTUnwrap(
            formatter.date(from: "2026-08-21T00:01:00+07:00"))
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-60)],
            ofItemAtPath: waiter.path)
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(baseline.scanIncomplete)

        try FileManager.default.setAttributes(
            [.modificationDate: captureNow],
            ofItemAtPath: waiter.path)
        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(pending.scanIncomplete)
        let original = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let originalUntil = try XCTUnwrap(original.codexPendingScanUntilKey)

        let newDay = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/21",
            sessionID: "one-midnight-new-day",
            timestamp: "2026-08-20T17:00:30.000Z",
            totalTokens: 200)
        try FileManager.default.setAttributes(
            [.modificationDate: afterMidnight],
            ofItemAtPath: newDay.path)
        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: afterMidnight,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertGreaterThan(
            try XCTUnwrap(catchUp.codexPendingScanUntilKey),
            originalUntil)
        XCTAssertNotNil(catchUp.codexPendingFileManifest?[newDay.path])

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: afterMidnight,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 300)
    }

    func testReexpandingRetainedWindowColdInventoriesLateArchivedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-retained-window-frontier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        _ = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/10",
            sessionID: "initial-wide-session",
            timestamp: "2026-08-10T10:00:00.000Z",
            totalTokens: 50)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!

        let wide = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 14,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(wide.scanIncomplete)

        let narrowNow = ISO8601DateFormatter().date(from: "2026-08-21T10:00:00Z")!
        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: narrowNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(narrow.scanIncomplete)
        let narrowedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertLessThan(
            try XCTUnwrap(narrowedCache.scanSinceKey),
            try XCTUnwrap(narrowedCache.codexLastSuccessfulRequestScanSinceKey),
            "Retained data coverage should remain wider than the last exact request")

        let lateArchived = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/11",
            sessionID: "late-old-mtime-session",
            timestamp: "2026-08-11T10:00:00.000Z",
            totalTokens: 75)
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: lateArchived.path)

        let expanded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: narrowNow.addingTimeInterval(10),
            forceRefresh: false,
            codexHomePath: home.path,
            historyDays: 14,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(expanded.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertTrue(
            pending.codexPendingFileManifest?[lateArchived.path] != nil,
            "A wider retained cache must not hide a late archived file from re-expansion")
    }

    func testWidePendingEpisodeKeepsExpansionSemanticsWhenCallerNarrowsWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-wide-pending-narrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let file = home.appendingPathComponent(
            "sessions/2026/08/20/rollout-cross-window-session.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"cross-window-session","timestamp":"2026-01-01T10:00:00.000Z"}}"#,
            #"{"timestamp":"2026-01-01T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-01-01T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            #"{"timestamp":"2026-08-20T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-08-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let now = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: file.path)

        let narrowBaseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(narrowBaseline.scanIncomplete)
        XCTAssertEqual(narrowBaseline.last30DaysTokens, 100)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .days["2026-01-01"])

        let widePending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 365,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(widePending.scanIncomplete)
        let frozen = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(frozen.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [file.path])

        let narrowedCaller = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(narrowedCaller.scanIncomplete)
        XCTAssertTrue(narrowedCaller.completedFiniteScanGeneration)
        let committedWide = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotNil(committedWide.days["2026-01-01"])
    }

    func testPendingEpisodeQueuesFileChangedAfterOriginalManifestCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-pending-capture-frontier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let changedDuringEpisode = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "changed-during-episode",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let initialWaiter = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "initial-waiter",
            timestamp: "2026-08-19T10:00:00.000Z",
            totalTokens: 200)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let settledMtime = baselineNow.addingTimeInterval(-60)
        try FileManager.default.setAttributes(
            [.modificationDate: settledMtime],
            ofItemAtPath: changedDuringEpisode.path)
        try FileManager.default.setAttributes(
            [.modificationDate: settledMtime],
            ofItemAtPath: initialWaiter.path)
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(baseline.scanIncomplete)

        let captureNow = baselineNow.addingTimeInterval(60)
        try FileManager.default.setAttributes(
            [.modificationDate: captureNow],
            ofItemAtPath: initialWaiter.path)
        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(seeded.scanIncomplete)
        let seededCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(seededCache.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [initialWaiter.path])
        XCTAssertNotNil(seededCache.codexPendingManifestCapturedUnixMs)

        try appendIncrementalCodexUsage(
            to: changedDuringEpisode,
            timestamp: "2026-08-20T10:01:01.000Z",
            totalTokens: 150,
            lastTokens: 50)
        try FileManager.default.setAttributes(
            [.modificationDate: captureNow.addingTimeInterval(1)],
            ofItemAtPath: changedDuringEpisode.path)

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(catchUp.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [changedDuringEpisode.path],
            "The post-publish delta must start from the original capture time")

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 350)
    }

    func testPendingWarmEpisodeReconcilesArchivedFlatFileChangedAfterCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-flat-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let sessionFile = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "flat-changed-during-episode",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let archiveDirectory = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true)
        let archived = archiveDirectory.appendingPathComponent(sessionFile.lastPathComponent)
        try FileManager.default.moveItem(at: sessionFile, to: archived)
        let waiter = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "flat-reconcile-waiter",
            timestamp: "2026-08-19T10:00:00.000Z",
            totalTokens: 200)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let settledMtime = baselineNow.addingTimeInterval(-60)
        for file in [archived, waiter] {
            try FileManager.default.setAttributes(
                [.modificationDate: settledMtime],
                ofItemAtPath: file.path)
        }
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(baseline.last30DaysTokens, 300)

        let captureNow = baselineNow.addingTimeInterval(60)
        try FileManager.default.setAttributes(
            [.modificationDate: captureNow],
            ofItemAtPath: waiter.path)
        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(pending.scanIncomplete)
        let frozen = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(frozen.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [waiter.path])
        XCTAssertEqual(frozen.codexPendingNeedsFlatReconciliation, true)

        try appendIncrementalCodexUsage(
            to: archived,
            timestamp: "2026-08-20T10:01:01.000Z",
            totalTokens: 150,
            lastTokens: 50)
        try FileManager.default.setAttributes(
            [.modificationDate: captureNow.addingTimeInterval(1)],
            ofItemAtPath: archived.path)

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let reconciliation = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(reconciliation.codexPendingNeedsFlatReconciliation, false)
        XCTAssertNotNil(reconciliation.codexPendingFlatDiscoveryOffsets)

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: captureNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 350)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingScanGeneration)
    }

    func testWideRequestAfterNarrowPendingColdQueuesLateArchivedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-pending-range-reexpand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let missingTraceDatabase = root.appendingPathComponent("missing-trace.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        _ = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/10",
            sessionID: "wide-baseline-archive",
            timestamp: "2026-08-10T10:00:00.000Z",
            totalTokens: 50)
        let narrowWaiter = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "narrow-pending-waiter",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 14,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertFalse(baseline.scanIncomplete)

        let narrowNow = ISO8601DateFormatter().date(from: "2026-08-21T10:00:00Z")!
        try FileManager.default.setAttributes(
            [.modificationDate: narrowNow],
            ofItemAtPath: narrowWaiter.path)
        let narrowSeed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: narrowNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase,
                maxScanWallClock: 0))
        XCTAssertTrue(narrowSeed.scanIncomplete)

        let lateArchived = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/11",
            sessionID: "late-during-narrow-pending",
            timestamp: "2026-08-11T10:00:00.000Z",
            totalTokens: 75)
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: lateArchived.path)

        let wideResume = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: narrowNow.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 14,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: missingTraceDatabase))
        XCTAssertTrue(wideResume.scanIncomplete)
        XCTAssertTrue(wideResume.completedFiniteScanGeneration)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertTrue(
            catchUp.codexPendingFileManifest?[lateArchived.path] != nil,
            "Re-expanding while a narrow episode completes must cold-inventory old-mtime files")
    }

    func testWarmPriorityDeltaQueuesOnlyAffectedTurnOwnerAndRepricesFinalReport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-delta-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)

        let ownerA = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "priority-owner-a",
            turnID: "turn-a",
            timestamp: "2026-08-18T10:00:00.000Z",
            inputTokens: 100)
        let ownerB = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "priority-owner-b",
            turnID: "turn-b",
            timestamp: "2026-08-19T10:00:00.000Z",
            inputTokens: 200)
        let fixedMtime = ISO8601DateFormatter().date(from: "2026-08-17T00:00:00Z")!
        for file in [ownerA, ownerB] {
            try FileManager.default.setAttributes(
                [.modificationDate: fixedMtime],
                ofItemAtPath: file.path)
        }
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-b",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!)

        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(baseline.last30DaysTokens, 300)
        let baselineCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(baselineCache.files[ownerA.path]?.codexTurnIDs, ["turn-a"])
        XCTAssertEqual(baselineCache.files[ownerB.path]?.codexTurnIDs, ["turn-b"])

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-a",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-18T10:00:00Z")!)
        let refreshNow = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        let bounded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(bounded.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerA.path],
            "A priority-only turn change must not queue unrelated historical owner B")

        // Simulate the oversized priority-only journal written by the prior
        // full-manifest gate. It has no admission-contract marker, so a fixed
        // build must reseed from the committed snapshot instead of draining it.
        var legacyPending = pending
        let ownerBTarget = try XCTUnwrap(CostUsageScanner.codexFrozenFile(
            fileURL: ownerB,
            withinRoot: home.appendingPathComponent("sessions", isDirectory: true),
            minimumKnownCompleteEOF: baselineCache.files[ownerB.path]?.size ?? 0))
        legacyPending.codexPendingFileManifest?[ownerB.path] = ownerBTarget
        legacyPending.codexPendingFileOrder?.append(ownerB.path)
        legacyPending.codexPendingManifestContractVersion = nil
        CostUsageCacheIO.save(provider: .codex, cache: legacyPending, cacheRoot: cacheRoot)

        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        let prunedPending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(prunedPending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerA.path],
            "An unversioned legacy manifest must be reseeded from committed state")

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, baseline.last30DaysTokens)
        let baselinePriorityTokens = baseline.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        let completedPriorityTokens = completed.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(baselinePriorityTokens, 200)
        XCTAssertEqual(completedPriorityTokens, 300)
    }

    func testPendingWarmManifestFreezesPriorityAdmissionAndQueuesLaterChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-pending-race-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)
        let ownerA = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "priority-race-owner-a",
            turnID: "turn-a",
            timestamp: "2026-08-18T10:00:00.000Z",
            inputTokens: 100)
        let ownerB = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "priority-race-owner-b",
            turnID: "turn-b",
            timestamp: "2026-08-19T10:00:00.000Z",
            inputTokens: 200)
        let ownerC = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/17",
            sessionID: "priority-race-owner-c",
            turnID: "turn-c",
            timestamp: "2026-08-17T10:00:00.000Z",
            inputTokens: 300)
        let oldMtime = ISO8601DateFormatter().date(from: "2026-08-16T00:00:00Z")!
        for file in [ownerA, ownerB, ownerC] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldMtime],
                ofItemAtPath: file.path)
        }
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-b",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!)

        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)

        let refreshNow = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        try FileManager.default.setAttributes(
            [.modificationDate: refreshNow],
            ofItemAtPath: ownerB.path)
        let firstPending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(firstPending.scanIncomplete)
        let pendingBeforePriorityChange = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pendingBeforePriorityChange.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerB.path])
        let firstGeneration = try XCTUnwrap(
            pendingBeforePriorityChange.codexPendingScanGeneration)
        XCTAssertNotNil(pendingBeforePriorityChange.codexPendingPriorityTurnsPayload)

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-a",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-18T10:00:00Z")!)
        let resumedAfterFirstChange = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(resumedAfterFirstChange.scanIncomplete)
        let pendingAfterFirstChange = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: cacheRoot)
        XCTAssertEqual(
            pendingAfterFirstChange.codexPendingScanGeneration,
            firstGeneration)
        XCTAssertEqual(
            Set(pendingAfterFirstChange.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerB.path],
            "Live Priority changes must not reset the finite in-progress manifest")

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-c",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-17T10:00:00Z")!)
        let resumedAfterSecondChange = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(resumedAfterSecondChange.scanIncomplete)
        let pendingAfterSecondChange = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: cacheRoot)
        XCTAssertEqual(pendingAfterSecondChange.codexPendingScanGeneration, firstGeneration)
        XCTAssertEqual(
            Set(pendingAfterSecondChange.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerB.path],
            "Repeated live Priority changes must preserve checkpointed progress")

        let completedFrozenEpisode = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(completedFrozenEpisode.scanIncomplete)
        XCTAssertTrue(completedFrozenEpisode.completedFiniteScanGeneration)
        let queuedCatchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(queuedCatchUp.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [ownerA.path, ownerC.path],
            "Only Priority owners changed after the frozen episode need catch-up")

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(completed.scanIncomplete)
        let priorityTokens = completed.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(priorityTokens, 600)
    }

    func testPendingPriorityEpisodeKeepsFrozenAdmissionWhenDatabaseDisappearsBetweenPlans()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-db-race-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        let movedDatabaseURL = root.appendingPathComponent("logs_2-moved.sqlite")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)
        let owner = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "priority-db-race-owner",
            turnID: "turn-priority",
            timestamp: "2026-08-19T10:00:00.000Z",
            inputTokens: 100)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-priority",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!)
        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        try FileManager.default.setAttributes(
            [.modificationDate: baselineNow.addingTimeInterval(-60)],
            ofItemAtPath: owner.path)

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)
        let baselinePriorityTokens = baseline.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(baselinePriorityTokens, 100)

        let refreshNow = baselineNow.addingTimeInterval(60)
        try FileManager.default.setAttributes(
            [.modificationDate: refreshNow],
            ofItemAtPath: owner.path)
        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(pending.scanIncomplete)
        let frozen = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let frozenGeneration = try XCTUnwrap(frozen.codexPendingScanGeneration)
        let frozenPriorityPayload = try XCTUnwrap(frozen.codexPendingPriorityTurnsPayload)

        var resumeOptions = CostUsageScanner.Options(
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: traceDatabaseURL)
        resumeOptions._testAfterCodexRequestedPlan = {
            try? FileManager.default.moveItem(
                at: traceDatabaseURL,
                to: movedDatabaseURL)
        }
        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: resumeOptions)

        XCTAssertFalse(FileManager.default.fileExists(atPath: traceDatabaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDatabaseURL.path))
        XCTAssertTrue(completed.scanIncomplete)
        XCTAssertTrue(completed.completedFiniteScanGeneration)
        let completedPriorityTokens = completed.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(completedPriorityTokens, 100)
        let committed = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(committed.codexPendingScanGeneration, frozenGeneration)
        XCTAssertEqual(committed.codexPendingPriorityTurnsPayload, frozenPriorityPayload)
        XCTAssertEqual(committed.codexPendingNeedsFlatReconciliation, false)
        XCTAssertFalse(frozenPriorityPayload.isEmpty)
        XCTAssertEqual(committed.codexPriorityMetadataKey, frozen.codexPriorityMetadataKey)

        try FileManager.default.moveItem(at: movedDatabaseURL, to: traceDatabaseURL)
        let recovered = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(recovered.scanIncomplete)
        let recoveredPriorityTokens = recovered.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(recoveredPriorityTokens, 100)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingScanGeneration)
    }

    func testPriorityOutageDuringCatchUpKeepsCommittedAdmissionForLegacyRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-outage-catch-up-\(UUID().uuidString)")
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        let movedDatabaseURL = root.appendingPathComponent("logs_2-moved.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)
        let now = Date()
        let partitionFormatter = DateFormatter()
        partitionFormatter.calendar = .current
        partitionFormatter.locale = Locale(identifier: "en_US_POSIX")
        partitionFormatter.dateFormat = "yyyy/MM/dd"
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let owner = try writePriorityTurnCodexFixture(
            root: home,
            partition: partitionFormatter.string(from: now),
            sessionID: "priority-outage-owner",
            turnID: "turn-committed",
            timestamp: timestamp,
            inputTokens: 100)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-committed",
            timestamp: now.addingTimeInterval(-3600))

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(
            baseline.daily.flatMap { $0.modelBreakdowns ?? [] }
                .reduce(0) { $0 + ($1.priorityTokens ?? 0) },
            100)

        var legacy = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let committedCursor = try XCTUnwrap(legacy.codexPriorityTurnsCursorPayload)
        legacy.files[owner.path]?.codexCostCacheComplete = nil
        legacy.files[owner.path]?.codexCostNanos = nil
        legacy.files[owner.path]?.codexPrioritySurchargeNanos = nil
        legacy.files[owner.path]?.codexStandardCostNanos = nil
        legacy.files[owner.path]?.codexPriorityCostNanos = nil
        legacy.files[owner.path]?.codexStandardTokens = nil
        legacy.files[owner.path]?.codexPriorityTokens = nil
        legacy.files[owner.path]?.codexRows = [CostUsageScanner.CodexUsageRow(
            day: CostUsageScanner.CostUsageDayRange.dayKey(from: now),
            model: "gpt-5",
            turnID: "turn-committed",
            input: 100,
            cached: 0,
            output: 0)]
        XCTAssertTrue(CostUsageCacheIO.save(
            provider: .codex,
            cache: legacy,
            cacheRoot: cacheRoot))

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-live-only",
            timestamp: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(60)],
            ofItemAtPath: owner.path)
        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(pending.scanIncomplete)
        let pendingCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(pendingCache.codexPriorityTurnsCursorPayload, committedCursor)
        XCTAssertNotEqual(pendingCache.codexPendingPriorityTurnsCursorPayload, committedCursor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pendingBytes = try encoder.encode(pendingCache)

        try FileManager.default.moveItem(at: traceDatabaseURL, to: movedDatabaseURL)
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
        let failed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(61),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(failed.scanIncomplete)
        XCTAssertEqual(
            failed.daily.flatMap { $0.modelBreakdowns ?? [] }
                .reduce(0) { $0 + ($1.priorityTokens ?? 0) },
            100)
        XCTAssertEqual(
            try encoder.encode(CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)),
            pendingBytes,
            "A validation outage must not mutate the committed or pending journal")
    }

    func testPendingWarmManifestQueuesOwnerWhenPriorityTurnIsDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-delete-race-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)
        let owner = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "priority-delete-owner",
            turnID: "turn-b",
            timestamp: "2026-08-19T10:00:00.000Z",
            inputTokens: 200)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-08-16T00:00:00Z")!],
            ofItemAtPath: owner.path)

        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-b",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!)
        let refreshNow = baselineNow.addingTimeInterval(60)
        let pending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(pending.scanIncomplete)
        let pendingCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pendingCache.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [owner.path])

        try deleteAllCodexPriorityTurns(from: traceDatabaseURL)
        let completedFrozenEpisode = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(completedFrozenEpisode.scanIncomplete)
        XCTAssertTrue(completedFrozenEpisode.completedFiniteScanGeneration)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(catchUp.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [owner.path],
            "A removed Priority turn must re-scan its owner in the catch-up episode")

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: refreshNow.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(completed.scanIncomplete)
        let priorityTokens = completed.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(priorityTokens, 0)
        XCTAssertEqual(completed.last30DaysTokens, 200)
    }

    func testWarmPriorityRefreshDoesNotShortcutLegacyEntryMissingTurnIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-migration-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)

        let legacyOwner = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "legacy-owner",
            turnID: "turn-legacy",
            timestamp: "2026-08-18T10:00:00.000Z",
            inputTokens: 100)
        let completeOwner = try writePriorityTurnCodexFixture(
            root: home,
            partition: "2026/08/19",
            sessionID: "complete-owner",
            turnID: "turn-complete",
            timestamp: "2026-08-19T10:00:00.000Z",
            inputTokens: 200)
        let fixedMtime = ISO8601DateFormatter().date(from: "2026-08-17T00:00:00Z")!
        for file in [legacyOwner, completeOwner] {
            try FileManager.default.setAttributes(
                [.modificationDate: fixedMtime],
                ofItemAtPath: file.path)
        }
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-complete",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!)

        let baselineNow = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)

        var legacyCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        legacyCache.files[legacyOwner.path]?.codexTurnIDs = nil
        CostUsageCacheIO.save(provider: .codex, cache: legacyCache, cacheRoot: cacheRoot)

        let bounded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: baselineNow.addingTimeInterval(2 * 60 * 60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(bounded.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [legacyOwner.path],
            "Turn-ID backfill must not reopen numerically complete siblings")
        XCTAssertNil(pending.files[legacyOwner.path]?.codexTurnIDs)
        XCTAssertEqual(pending.files[completeOwner.path]?.codexTurnIDs, ["turn-complete"])

        var completed = bounded
        for pass in 1...6 where completed.scanIncomplete {
            completed = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: baselineNow.addingTimeInterval(TimeInterval((pass + 2) * 60 * 60)),
                forceRefresh: true,
                codexHomePath: home.path,
                historyDays: 7,
                refreshPricingInBackground: false,
                scannerOptions: .init(
                    cacheRoot: cacheRoot,
                    codexTraceDatabaseURL: traceDatabaseURL))
        }
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 300)
        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(migrated.files[legacyOwner.path]?.codexTurnIDs, ["turn-legacy"])
        XCTAssertEqual(migrated.files[completeOwner.path]?.codexTurnIDs, ["turn-complete"])
    }

    func testTurnIDBackfillUsesFiniteMetadataOnlyBatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-turn-id-batches-\(UUID().uuidString)")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo()
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo()
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)
        let fileCount = CostUsageScanner.codexTurnIDBackfillFileLimit + 2
        var owners: [URL] = []
        for index in 0..<fileCount {
            owners.append(try writePriorityTurnCodexFixture(
                root: home,
                partition: "2026/08/18",
                sessionID: "backfill-\(String(format: "%03d", index))",
                turnID: "turn-backfill-\(index)",
                timestamp: "2026-08-18T10:00:00.000Z",
                inputTokens: index + 1))
        }
        let fixedMtime = ISO8601DateFormatter().date(from: "2026-08-17T00:00:00Z")!
        for owner in owners {
            try FileManager.default.setAttributes(
                [.modificationDate: fixedMtime],
                ofItemAtPath: owner.path)
        }

        let now = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let options = CostUsageScanner.Options(
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: traceDatabaseURL)
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        XCTAssertFalse(baseline.scanIncomplete)

        var legacy = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        for owner in owners {
            legacy.files[owner.path]?.codexTurnIDs = nil
        }
        legacy.codexLastSuccessfulRequestScanSinceKey = nil
        legacy.codexLastSuccessfulRequestScanUntilKey = nil
        let originalDays = legacy.days
        let originalPayloads = try Dictionary(uniqueKeysWithValues: owners.map { owner in
            let usage = try XCTUnwrap(legacy.files[owner.path])
            return (owner.path, try codexUsagePayloadExcludingTurnIDBackfillReceipt(usage))
        })
        XCTAssertTrue(CostUsageCacheIO.save(
            provider: .codex,
            cache: legacy,
            cacheRoot: cacheRoot))
        let liveToday = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/20",
            sessionID: "live-before-legacy-inventory",
            timestamp: "2026-08-20T10:30:00.000Z",
            totalTokens: 400)

        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0.5))
        XCTAssertTrue(seeded.scanIncomplete)
        XCTAssertTrue(
            seeded.completedFiniteScanGeneration,
            "The retained live delta must publish before legacy inventory starts")
        XCTAssertEqual(
            seeded.last30DaysTokens,
            fileCount * (fileCount + 1) / 2 + 400)
        let livePublished = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotNil(livePublished.files[liveToday.path])
        XCTAssertTrue(livePublished.codexNeedsLegacyColdInventory == true)
        XCTAssertNil(livePublished.codexLastSuccessfulRequestScanSinceKey)
        XCTAssertNil(livePublished.codexPendingScanGeneration)
        let migrationStatus = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        XCTAssertEqual(migrationStatus?.incompleteFiles, 1)

        let coldQueued = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(120),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(coldQueued.scanIncomplete)
        let firstPending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            firstPending.codexPendingFileManifest?.count,
            CostUsageScanner.codexTurnIDBackfillFileLimit)
        XCTAssertEqual(
            firstPending.codexPendingTurnIDBackfillPaths?.count,
            CostUsageScanner.codexTurnIDBackfillFileLimit)

        let firstBatch = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(180),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        XCTAssertTrue(firstBatch.scanIncomplete)
        XCTAssertFalse(firstBatch.completedFiniteScanGeneration)
        let afterFirstBatch = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            owners.filter { afterFirstBatch.files[$0.path]?.codexTurnIDs != nil }.count,
            CostUsageScanner.codexTurnIDBackfillFileLimit)
        XCTAssertEqual(afterFirstBatch.days["2026-08-18"], originalDays["2026-08-18"])
        for owner in owners {
            let usage = try XCTUnwrap(afterFirstBatch.files[owner.path])
            XCTAssertEqual(
                try codexUsagePayloadExcludingTurnIDBackfillReceipt(usage),
                originalPayloads[owner.path])
        }

        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-backfill-\(fileCount - 1)",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-18T10:00:00Z")!)

        let lateToday = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/20",
            sessionID: "late-during-turn-id-backfill",
            timestamp: "2026-08-20T11:00:00.000Z",
            totalTokens: 500)

        let deferredPriority = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(240),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        XCTAssertTrue(deferredPriority.scanIncomplete)
        let deferredCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertLessThan(
            deferredCache.codexPendingFileManifest?.count ?? Int.max,
            fileCount,
            "A live Priority append must not reopen the numeric legacy corpus")
        XCTAssertEqual(deferredCache.days["2026-08-18"], originalDays["2026-08-18"])

        var completed = deferredPriority
        for pass in 1...8 where completed.scanIncomplete {
            completed = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: now.addingTimeInterval(TimeInterval((pass + 4) * 60)),
                forceRefresh: true,
                codexHomePath: home.path,
                historyDays: 7,
                refreshPricingInBackground: false,
                scannerOptions: options)
        }
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(
            completed.last30DaysTokens,
            fileCount * (fileCount + 1) / 2 + 400 + 500)
        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(migrated.days["2026-08-18"], originalDays["2026-08-18"])
        for (index, owner) in owners.enumerated() {
            let usage = try XCTUnwrap(migrated.files[owner.path])
            XCTAssertEqual(usage.codexTurnIDs, ["turn-backfill-\(index)"])
            if index == fileCount - 1 {
                XCTAssertEqual(usage.days, legacy.files[owner.path]?.days)
            } else {
                XCTAssertEqual(
                    try codexUsagePayloadExcludingTurnIDBackfillReceipt(usage),
                    originalPayloads[owner.path])
            }
        }
        XCTAssertNotNil(migrated.files[lateToday.path])
        XCTAssertNil(migrated.codexPendingScanGeneration)
        let priorityTokens = completed.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(priorityTokens, fileCount)
    }

    func testPriorityCursorSurvivesRelaunchAndReadsOnlyAppendedTraceRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-cursor-\(UUID().uuidString)")
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)

        let now = Date()
        let partitionFormatter = DateFormatter()
        partitionFormatter.calendar = .current
        partitionFormatter.locale = Locale(identifier: "en_US_POSIX")
        partitionFormatter.dateFormat = "yyyy/MM/dd"
        let timestamp = ISO8601DateFormatter().string(from: now)
        _ = try writePriorityTurnCodexFixture(
            root: home,
            partition: partitionFormatter.string(from: now),
            sessionID: "priority-cursor-owner",
            turnID: "turn-a",
            timestamp: timestamp,
            inputTokens: 100)
        try insertCodexTraceBodies(
            (0..<50).map { "routine trace row \($0)" },
            into: traceDatabaseURL,
            timestamp: now)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-a",
            timestamp: now)

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(first.scanIncomplete)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let firstPayload = try XCTUnwrap(firstCache.codexPriorityTurnsCursorPayload)
        let firstCursor = try JSONDecoder().decode(
            CostUsageScanner.CodexPriorityTurnsPersistedCursor.self,
            from: Data(firstPayload.utf8))
        XCTAssertEqual(firstCursor.lastRowID, 51)
        XCTAssertEqual(Set(firstCursor.turns.keys), ["turn-a"])
        XCTAssertFalse(firstCursor.anchorDigest.isEmpty)

        // Simulate a new process. Mutating an untracked pre-cursor row is an
        // instrumentation sentinel: an incremental resume must not discover
        // it, while a cold body-column scan would.
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
        try updateCodexTraceBody(
            rowID: 1,
            body: "thread_id=old turn.id=mutated-old websocket request: "
                + #"{"type":"response.create","service_tier":"priority","model":"gpt-5"}"#,
            in: traceDatabaseURL)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-b",
            timestamp: now.addingTimeInterval(1))

        let resumed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(resumed.scanIncomplete)
        let memo = try XCTUnwrap(
            CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: traceDatabaseURL.path))
        XCTAssertEqual(memo.lastRowID, 52)
        XCTAssertEqual(Set(memo.turns.keys), ["turn-a", "turn-b"])
        XCTAssertNil(memo.turns["mutated-old"])

        let resumedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let resumedPayload = try XCTUnwrap(resumedCache.codexPriorityTurnsCursorPayload)
        let resumedCursor = try JSONDecoder().decode(
            CostUsageScanner.CodexPriorityTurnsPersistedCursor.self,
            from: Data(resumedPayload.utf8))
        XCTAssertEqual(resumedCursor.lastRowID, 52)
        XCTAssertEqual(Set(resumedCursor.turns.keys), ["turn-a", "turn-b"])
    }

    func testPriorityLiveScanRejectsDatabaseReplacementBeforeMemoCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-live-race-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        let replacementURL = root.appendingPathComponent("replacement.sqlite")
        let displacedURL = root.appendingPathComponent("displaced.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        try createCodexPriorityTraceDatabase(at: databaseURL)
        let now = Date()
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "stable-turn",
            timestamp: now)
        let baseline = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: databaseURL)
        XCTAssertFalse(baseline.validationPending)
        XCTAssertEqual(Set(baseline.turns.keys), ["stable-turn"])

        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "stale-tail-turn",
            timestamp: now.addingTimeInterval(1))
        try createCodexPriorityTraceDatabase(at: replacementURL)
        try appendCodexPriorityTurn(
            to: replacementURL,
            turnID: "replacement-turn",
            timestamp: now.addingTimeInterval(2))

        var replacementError: Error?
        let raced = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            beforeFinalIdentityValidation: {
                do {
                    try FileManager.default.moveItem(at: databaseURL, to: displacedURL)
                    try FileManager.default.moveItem(at: replacementURL, to: databaseURL)
                } catch {
                    replacementError = error
                }
            })
        XCTAssertNil(replacementError)
        XCTAssertTrue(raced.validationPending)
        XCTAssertEqual(Set(raced.turns.keys), ["stable-turn"])
        XCTAssertEqual(
            Set(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: databaseURL.path)?
                .turns.keys.map(\.self) ?? []),
            ["stable-turn"],
            "The stale file descriptor must never advance the memo")

        let retried = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: databaseURL)
        XCTAssertFalse(retried.validationPending)
        XCTAssertEqual(Set(retried.turns.keys), ["replacement-turn"])
    }

    func testPriorityLiveScanDefersRowsAppendedAfterCapturedHighWater() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-row-race-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        try createCodexPriorityTraceDatabase(at: databaseURL)
        try enableCodexPriorityTraceWAL(at: databaseURL)
        let now = Date()
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "captured-turn",
            timestamp: now)

        var appendError: Error?
        let captured = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            afterMaxRowIDCapture: {
                do {
                    try self.appendCodexPriorityTurn(
                        to: databaseURL,
                        turnID: "later-turn",
                        timestamp: now.addingTimeInterval(1))
                } catch {
                    appendError = error
                }
            })
        XCTAssertNil(appendError)
        XCTAssertFalse(captured.validationPending)
        XCTAssertEqual(Set(captured.turns.keys), ["captured-turn"])
        let firstCursor = try XCTUnwrap(
            CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: databaseURL))
        XCTAssertEqual(firstCursor.lastRowID, 1)
        XCTAssertTrue(CostUsageScanner.codexPriorityTurnsCursorIsValid(firstCursor))

        let advanced = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: databaseURL)
        XCTAssertFalse(advanced.validationPending)
        XCTAssertEqual(Set(advanced.turns.keys), ["captured-turn", "later-turn"])
        XCTAssertEqual(
            CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: databaseURL)?
                .lastRowID,
            2)
    }

    func testPriorityBoundedScanRejectsDatabaseReplacementBeforeReturn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-bounded-race-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        let replacementURL = root.appendingPathComponent("replacement.sqlite")
        let displacedURL = root.appendingPathComponent("displaced.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2020-01-15T12:00:00Z"))
        try createCodexPriorityTraceDatabase(at: databaseURL)
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "stale-bounded-turn",
            timestamp: timestamp)
        try createCodexPriorityTraceDatabase(at: replacementURL)
        try appendCodexPriorityTurn(
            to: replacementURL,
            turnID: "replacement-bounded-turn",
            timestamp: timestamp)

        var replacementError: Error?
        let raced = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: "2020-01-01",
            untilDayKey: "2020-01-31",
            beforeFinalIdentityValidation: {
                do {
                    try FileManager.default.moveItem(at: databaseURL, to: displacedURL)
                    try FileManager.default.moveItem(at: replacementURL, to: databaseURL)
                } catch {
                    replacementError = error
                }
            })
        XCTAssertNil(replacementError)
        XCTAssertTrue(raced.validationPending)
        XCTAssertTrue(raced.turns.isEmpty)

        let retried = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: "2020-01-01",
            untilDayKey: "2020-01-31")
        XCTAssertFalse(retried.validationPending)
        XCTAssertEqual(Set(retried.turns.keys), ["replacement-bounded-turn"])
    }

    func testPriorityBoundedScanUsesRowIDOrderForLatestCompletionModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-bounded-order-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try createCodexPriorityTraceDatabase(at: databaseURL)
        let formatter = ISO8601DateFormatter()
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "ordered-turn",
            timestamp: try XCTUnwrap(formatter.date(from: "2020-01-15T12:00:00Z")))
        try appendCodexCompletedTurn(
            to: databaseURL,
            turnID: "ordered-turn",
            timestamp: try XCTUnwrap(formatter.date(from: "2020-01-20T12:00:00Z")),
            model: "earlier-row-model")
        try appendCodexCompletedTurn(
            to: databaseURL,
            turnID: "ordered-turn",
            timestamp: try XCTUnwrap(formatter.date(from: "2020-01-10T12:00:00Z")),
            model: "latest-row-model")

        let resolved = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: "2020-01-01",
            untilDayKey: "2020-01-31")

        XCTAssertFalse(resolved.validationPending)
        XCTAssertEqual(resolved.turns["ordered-turn"]?.model, "latest-row-model")
    }

    func testPriorityCursorPrunesOwnersBeforeAdvancedRollingWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-window-prune-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
        try createCodexPriorityTraceDatabase(at: databaseURL)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let oldDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: today))
        let oldDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: oldDate)
        let todayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: today)
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "old-turn",
            timestamp: oldDate.addingTimeInterval(60))
        try appendCodexPriorityTurn(
            to: databaseURL,
            turnID: "current-turn",
            timestamp: today.addingTimeInterval(60))

        let wide = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: oldDayKey,
            untilDayKey: todayKey)
        XCTAssertEqual(Set(wide.turns.keys), ["old-turn", "current-turn"])

        let narrow = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: todayKey,
            untilDayKey: todayKey)
        XCTAssertEqual(Set(narrow.turns.keys), ["current-turn"])
        let pruned = try XCTUnwrap(
            CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: databaseURL.path))
        XCTAssertEqual(pruned.coverageSinceEpoch, Int64(today.timeIntervalSince1970))
        XCTAssertEqual(Set(pruned.turns.keys), ["current-turn"])
        XCTAssertNil(pruned.requestSourcesByTurnID["old-turn"])
        XCTAssertNil(pruned.priorityCompletedModelsByTurnID["old-turn"])

        let expanded = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: oldDayKey,
            untilDayKey: todayKey)
        XCTAssertEqual(
            Set(expanded.turns.keys),
            ["old-turn", "current-turn"],
            "Expanding backward must rebuild owners pruned by the narrower cursor")
    }

    func testMalformedPriorityCursorPayloadDoesNotInvalidateUsageCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-payload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 123
        cache.codexPriorityTurnsCursorPayload = "{not-valid-json"
        XCTAssertTrue(CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: root))

        let restored = CostUsageCacheIO.load(provider: .codex, cacheRoot: root)
        XCTAssertEqual(restored.lastScanUnixMs, 123)
        XCTAssertEqual(restored.codexPriorityTurnsCursorPayload, "{not-valid-json")
    }

    func testSemanticallyCorruptPriorityCursorIsRejectedBeforeMemoSeed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-invalid-cursor-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: databaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let cursor = CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databaseURL.path,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 999)

        XCTAssertFalse(CostUsageScanner.codexPriorityTurnsCursorIsValid(cursor))
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(cursor, databaseURL: databaseURL)
        XCTAssertNil(
            CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: databaseURL.path))

        let source = CostUsageScanner.CodexPriorityTurnMetadata(
            threadID: "thread-a",
            turnID: "turn-a",
            model: "gpt-5",
            timestamp: "2026-08-20T10:00:00Z")
        var valid = CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databaseURL.path,
            coverageSinceEpoch: 0,
            lastRowID: 1,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: ["turn-a": source],
            requestSourcesByTurnID: ["turn-a": [1: source]],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
        XCTAssertTrue(CostUsageScanner.codexPriorityTurnsCursorIsValid(valid))

        valid.requestSourcesByTurnID = [:]
        XCTAssertFalse(
            CostUsageScanner.codexPriorityTurnsCursorIsValid(valid),
            "A persisted Priority turn without its source row must fail closed")

        let newer = CostUsageScanner.CodexPriorityTurnMetadata(
            threadID: "thread-a",
            turnID: "turn-a",
            model: "gpt-5.1",
            timestamp: "2026-08-20T10:01:00Z")
        valid.lastRowID = 2
        valid.requestSourcesByTurnID = ["turn-a": [1: source, 2: newer]]
        XCTAssertFalse(
            CostUsageScanner.codexPriorityTurnsCursorIsValid(valid),
            "The published turn must equal its latest persisted source")
    }

    func testPriorityDatabaseFailureKeepsCommittedCacheAndLastGoodSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-fail-closed-\(UUID().uuidString)")
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)

        let now = Date()
        let partitionFormatter = DateFormatter()
        partitionFormatter.calendar = .current
        partitionFormatter.locale = Locale(identifier: "en_US_POSIX")
        partitionFormatter.dateFormat = "yyyy/MM/dd"
        let timestamp = ISO8601DateFormatter().string(from: now)
        _ = try writePriorityTurnCodexFixture(
            root: home,
            partition: partitionFormatter.string(from: now),
            sessionID: "priority-fail-closed-owner",
            turnID: "turn-priority",
            timestamp: timestamp,
            inputTokens: 100)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-priority",
            timestamp: now)
        try appendCodexCompletedTurn(
            to: traceDatabaseURL,
            turnID: "turn-priority",
            timestamp: now.addingTimeInterval(1),
            model: "gpt-5.1-codex")

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)
        let baselinePriorityTokens = baseline.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(baselinePriorityTokens, 100)

        let committedBefore = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let committedBytes = try encoder.encode(committedBefore)
        try FileManager.default.removeItem(at: traceDatabaseURL)
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)

        let failedRefresh = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))

        XCTAssertTrue(failedRefresh.scanIncomplete)
        let failedPriorityTokens = failedRefresh.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .reduce(0) { $0 + ($1.priorityTokens ?? 0) }
        XCTAssertEqual(failedPriorityTokens, baselinePriorityTokens)
        let committedAfter = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(try encoder.encode(committedAfter), committedBytes)
    }

    func testPriorityDatabaseFailureBeforeCursorMigrationReturnsEmptyLastGoodHandoff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-priority-pre-cursor-outage-\(UUID().uuidString)")
        let traceDatabaseURL = root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        try createCodexPriorityTraceDatabase(at: traceDatabaseURL)

        let now = Date()
        let partitionFormatter = DateFormatter()
        partitionFormatter.calendar = .current
        partitionFormatter.locale = Locale(identifier: "en_US_POSIX")
        partitionFormatter.dateFormat = "yyyy/MM/dd"
        let owner = try writePriorityTurnCodexFixture(
            root: home,
            partition: partitionFormatter.string(from: now),
            sessionID: "priority-pre-cursor-owner",
            turnID: "turn-pre-cursor",
            timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            inputTokens: 100)
        try appendCodexPriorityTurn(
            to: traceDatabaseURL,
            turnID: "turn-pre-cursor",
            timestamp: now.addingTimeInterval(-60))

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(baseline.scanIncomplete)

        var legacy = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let migratedBaseline = legacy
        legacy.codexPriorityTurnsCursorPayload = nil
        legacy.files[owner.path]?.codexCostCacheComplete = nil
        legacy.files[owner.path]?.codexCostNanos = nil
        legacy.files[owner.path]?.codexPrioritySurchargeNanos = nil
        legacy.files[owner.path]?.codexStandardCostNanos = nil
        legacy.files[owner.path]?.codexPriorityCostNanos = nil
        legacy.files[owner.path]?.codexStandardTokens = nil
        legacy.files[owner.path]?.codexPriorityTokens = nil
        legacy.files[owner.path]?.codexRows = [CostUsageScanner.CodexUsageRow(
            day: CostUsageScanner.CostUsageDayRange.dayKey(from: now),
            model: "gpt-5",
            turnID: "turn-pre-cursor",
            input: 100,
            cached: 0,
            output: 0)]
        XCTAssertTrue(CostUsageCacheIO.save(
            provider: .codex,
            cache: legacy,
            cacheRoot: cacheRoot))
        let committedBefore = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let committedBytes = try encoder.encode(committedBefore)

        try FileManager.default.removeItem(at: traceDatabaseURL)
        CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: traceDatabaseURL.path)
        let failedRefresh = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(1),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))

        XCTAssertTrue(failedRefresh.scanIncomplete)
        XCTAssertTrue(failedRefresh.daily.isEmpty)
        XCTAssertEqual(
            try encoder.encode(CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)),
            committedBytes,
            "A pre-cursor outage must hand off to last-good history without repricing or mutation")

        // A narrow migration can leave older raw rows beside non-nil cost
        // maps. Expanding the window during the same outage must still avoid
        // rebuilding those newly visible rows without trusted admission.
        var expandedLegacy = migratedBaseline
        expandedLegacy.codexPriorityTurnsCursorPayload = nil
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -60, to: now))
        let oldDay = CostUsageScanner.CostUsageDayRange.dayKey(from: oldDate)
        var expandedUsage = try XCTUnwrap(expandedLegacy.files[owner.path])
        expandedUsage.codexCostCacheComplete = true
        expandedUsage.codexStandardCostNanos = expandedUsage.codexStandardCostNanos ?? [:]
        expandedUsage.codexPriorityCostNanos = expandedUsage.codexPriorityCostNanos ?? [:]
        expandedUsage.codexStandardTokens = expandedUsage.codexStandardTokens ?? [:]
        expandedUsage.codexPriorityTokens = expandedUsage.codexPriorityTokens ?? [:]
        XCTAssertNotNil(expandedUsage.codexCostNanos)
        XCTAssertNotNil(expandedUsage.codexStandardCostNanos)
        XCTAssertNotNil(expandedUsage.codexPriorityCostNanos)
        expandedLegacy.days[oldDay] = ["gpt-5": [100, 0, 0]]
        expandedUsage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: oldDay,
            model: "gpt-5",
            turnID: "turn-old-pre-cursor",
            input: 100,
            cached: 0,
            output: 0)]
        expandedLegacy.files[owner.path] = expandedUsage
        XCTAssertTrue(CostUsageCacheIO.save(
            provider: .codex,
            cache: expandedLegacy,
            cacheRoot: cacheRoot))
        let expandedCommitted = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let expandedBytes = try encoder.encode(expandedCommitted)

        let expandedFailure = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(2),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: cacheRoot,
                codexTraceDatabaseURL: traceDatabaseURL))

        XCTAssertTrue(expandedFailure.scanIncomplete)
        XCTAssertTrue(expandedFailure.daily.isEmpty)
        XCTAssertEqual(
            try encoder.encode(CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)),
            expandedBytes,
            "Window expansion must not reprice retained raw rows during a Priority outage")
    }

    func testWarmRefreshReconcilesArchivedRenameWithoutLosingUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-archive-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let session = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/18",
            sessionID: "archived-preserved-mtime",
            timestamp: "2026-08-18T10:00:00.000Z",
            totalTokens: 100)
        let now = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        let oldMtime = now.addingTimeInterval(-24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldMtime],
            ofItemAtPath: session.path)

        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertFalse(baseline.scanIncomplete)
        XCTAssertEqual(baseline.last30DaysTokens, 100)
        let baselineCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let baselineFileID = try XCTUnwrap(baselineCache.files[session.path]?.codexScanFileId)

        let archiveDirectory = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true)
        let archived = archiveDirectory.appendingPathComponent(session.lastPathComponent)
        try FileManager.default.moveItem(at: session, to: archived)
        let archivedMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archived.path)[.modificationDate] as? Date)
        XCTAssertEqual(archivedMtime.timeIntervalSince1970, oldMtime.timeIntervalSince1970, accuracy: 1)

        let bounded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot, maxScanWallClock: 0))
        XCTAssertTrue(bounded.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(
            Set(pending.codexPendingFileManifest?.keys.map(\.self) ?? []),
            [archived.path])

        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 100)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(finalized.files.count, 1)
        XCTAssertNil(finalized.files[session.path])
        XCTAssertNotNil(finalized.files[archived.path])
        XCTAssertEqual(finalized.files[archived.path]?.codexScanFileId, baselineFileID)
        XCTAssertEqual(finalized.days, baselineCache.days)
        XCTAssertNil(finalized.codexPendingScanGeneration)
    }

    func testWarmFlatDiscoveryResumesAfterInMemoryCursorIsLost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-flat-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        _ = try writeIncrementalCodexFixture(
            root: home,
            partition: "2026/08/20",
            sessionID: "flat-page-baseline",
            timestamp: "2026-08-20T10:00:00.000Z",
            totalTokens: 100)
        let now = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!
        let baseline = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertEqual(baseline.last30DaysTokens, 100)

        let archiveDirectory = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true)
        for index in 0..<1300 {
            let file = archiveDirectory.appendingPathComponent("ignored-\(index).txt")
            _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(first.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertNotNil(pending.codexPendingFlatDiscoveryOffsets)
        XCTAssertFalse(pending.codexPendingFlatDiscoveryOffsets?.isEmpty ?? true)
        let firstPendingStatus = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        let firstStatus = try XCTUnwrap(firstPendingStatus)

        let second = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(second.scanIncomplete)
        let beforeRestart = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let archivePath = archiveDirectory.standardizedFileURL.path
        XCTAssertEqual(beforeRestart.codexPendingFlatDiscoveryOffsets?[archivePath], 1024)
        let pendingStatusBeforeRestart = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        let beforeRestartStatus = try XCTUnwrap(pendingStatusBeforeRestart)
        XCTAssertNotEqual(beforeRestartStatus.progressFingerprint, firstStatus.progressFingerprint)

        // Simulate an app restart: the durable ordinal remains, but every DIR
        // cursor disappears. Replay must advertise bounded progress until it
        // catches the ordinal, otherwise the background no-progress guard
        // stops before entry 1025.
        CostUsageScanner.resetCodexFlatDirectoryCursorsForTesting()
        let firstReplay = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(firstReplay.scanIncomplete)
        XCTAssertEqual(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingFlatDiscoveryOffsets?[archivePath],
            1024)
        let pendingStatusAfterFirstReplay = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        let firstReplayStatus = try XCTUnwrap(pendingStatusAfterFirstReplay)
        XCTAssertNotEqual(
            firstReplayStatus.progressFingerprint,
            beforeRestartStatus.progressFingerprint)

        let secondReplay = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now.addingTimeInterval(60),
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: cacheRoot))
        XCTAssertTrue(secondReplay.scanIncomplete)
        XCTAssertEqual(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingFlatDiscoveryOffsets?[archivePath],
            1024)
        let pendingStatusAfterSecondReplay = await CostUsageFetcher(cacheRoot: cacheRoot)
            .loadCodexPendingScanStatus()
        let secondReplayStatus = try XCTUnwrap(pendingStatusAfterSecondReplay)
        XCTAssertNotEqual(
            secondReplayStatus.progressFingerprint,
            firstReplayStatus.progressFingerprint)

        var completed = secondReplay
        for _ in 0..<4 where completed.scanIncomplete {
            completed = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: now.addingTimeInterval(60),
                forceRefresh: true,
                codexHomePath: home.path,
                historyDays: 7,
                refreshPricingInBackground: false,
                scannerOptions: .init(cacheRoot: cacheRoot))
        }
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.last30DaysTokens, 100)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingFlatDiscoveryOffsets)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingFlatDiscoveryProgress)
    }

    func testBoundedCandidateQueueDrainsWithoutStarvingTailFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-fair-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cacheRoot = root.appendingPathComponent("cache")
        seedFreshModelsDevPricingCache(at: cacheRoot)
        let now = ISO8601DateFormatter().date(from: "2026-08-20T18:00:00Z")!
        for index in 0...CostUsageScanner.codexCatchUpScanCandidateLimit {
            _ = try writeIncrementalCodexFixture(
                root: home,
                partition: "2026/08/20",
                sessionID: "queue-\(String(format: "%04d", index))",
                timestamp: "2026-08-20T10:00:00.000Z",
                totalTokens: 1)
        }
        let options = CostUsageScanner.Options(
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: root.appendingPathComponent("missing-codex-trace.sqlite"))

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        XCTAssertTrue(first.scanIncomplete)
        let pending = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertEqual(pending.codexPendingFileOrder?.count, 1)
        let status = await CostUsageFetcher(cacheRoot: cacheRoot).loadCodexPendingScanStatus()
        XCTAssertEqual(status?.incompleteFiles, 1)

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(
            completed.last30DaysTokens,
            CostUsageScanner.codexCatchUpScanCandidateLimit + 1)
        XCTAssertNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
                .codexPendingFileOrder)
    }

    func testPendingFileOrderPreservesWaitersAndExistingAdmissionSemantics() {
        let oldWaiter = "/tmp/birdnion-codex-old-waiter.jsonl"
        let newest = "/tmp/birdnion-codex-newest.jsonl"
        let smaller = "/tmp/birdnion-codex-smaller.jsonl"
        let larger = "/tmp/birdnion-codex-larger.jsonl"
        let eligible = Set([oldWaiter, newest, smaller, larger])

        let order = CostUsageScanner.reconciledCodexPendingFileOrder(
            persistedOrder: [oldWaiter, oldWaiter, "/tmp/no-longer-eligible.jsonl"],
            eligiblePaths: eligible)

        XCTAssertEqual(order, [oldWaiter, smaller, newest, larger])
    }

    func testPendingFileOrderRotatesServicedPartialBehindEveryWaiter() {
        let order = (0...512).map { "/tmp/birdnion-codex-waiter-\($0).jsonl" }
        let result = CostUsageScanner.finalizedCodexPendingFileOrder(
            order,
            completedPaths: [order[1]],
            servicedIncompletePaths: [order[0]])

        XCTAssertEqual(result.first, order[2])
        XCTAssertEqual(result.last, order[0])
        XCTAssertFalse(result.contains(order[1]))
        XCTAssertEqual(result.count, 512)
    }

    func testPendingProgressIgnoresQueueRotationButTracksMembership() {
        var cache = CostUsageCache()
        cache.codexPendingScanGeneration = "generation"
        cache.codexPendingScanSinceKey = "2026-08-01"
        cache.codexPendingScanUntilKey = "2026-08-31"
        cache.codexPendingPriorityTurnsPayload = "{}"
        cache.codexPendingFileOrder = ["/tmp/a.jsonl", "/tmp/b.jsonl"]
        let baseline = CostUsageScanner.codexPendingProgressFingerprint(cache)

        cache.codexPendingFileOrder = ["/tmp/b.jsonl", "/tmp/a.jsonl"]
        XCTAssertEqual(CostUsageScanner.codexPendingProgressFingerprint(cache), baseline)

        cache.codexPendingFileOrder = ["/tmp/b.jsonl"]
        XCTAssertNotEqual(CostUsageScanner.codexPendingProgressFingerprint(cache), baseline)
    }

    func testPendingProgressTracksRangeAndPriorityAdmissionWithoutExposingPayload() {
        var cache = CostUsageCache()
        cache.codexPendingScanGeneration = "generation"
        cache.codexPendingScanSinceKey = "2026-08-01"
        cache.codexPendingScanUntilKey = "2026-08-31"
        cache.codexPendingPriorityTurnsPayload = #"{"private-turn":{"timestamp":"2026-08-20"}}"#
        let baseline = CostUsageScanner.codexPendingProgressFingerprint(cache)
        XCTAssertFalse(baseline.contains("private-turn"))

        cache.codexPendingScanUntilKey = "2026-09-01"
        let movedRange = CostUsageScanner.codexPendingProgressFingerprint(cache)
        XCTAssertNotEqual(movedRange, baseline)

        cache.codexPendingScanUntilKey = "2026-08-31"
        cache.codexPendingPriorityTurnsPayload = #"{"other-private-turn":{}}"#
        XCTAssertNotEqual(CostUsageScanner.codexPendingProgressFingerprint(cache), baseline)
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

    func testForegroundReportEpisodeYieldsAfterOneBoundedPass() async {
        let pending = CodexCostScanner.ReportLoad(
            value: nil,
            completed: false,
            progress: Self.progress(bytes: 10))
        let probe = ReportPassProbe([pending])

        let result = await CodexCostScanner.runReportEpisode(yieldAfterFirstPass: true) {
            forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertNil(result.value)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [false])
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

    func testBackgroundReportEpisodeContinuesPastPublishedSnapshot() async {
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 7),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        let probe = ReportPassProbe([
            .init(
                value: Self.report(tokens: 7),
                completed: false,
                progress: Self.progress(bytes: 20),
                publishedSnapshot: true),
            .init(value: Self.report(tokens: 77), completed: true),
        ])

        let result = await CodexCostScanner.runBackgroundReportEpisode(
            initial: initial,
            continuationDelay: .zero)
        { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.value?.todayTokens, 77)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true, true])
    }

    func testBackgroundReportEpisodePausesWhenCheckpointDoesNotAdvance() async {
        let progress = Self.progress(bytes: 10)
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 7),
            completed: false,
            progress: progress,
            publishedSnapshot: true)
        let probe = ReportPassProbe([
            .init(
                value: Self.report(tokens: 7),
                completed: false,
                progress: progress,
                publishedSnapshot: true),
        ])

        let result = await CodexCostScanner.runBackgroundReportEpisode(
            initial: initial,
            continuationDelay: .zero)
        { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true])
    }

    func testBackgroundReportEpisodePreservesPublishedSnapshotWhenLaterPassStalls() async {
        let published = Self.report(tokens: 41)
        let initial = CodexCostScanner.ReportLoad(
            value: published,
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        let probe = ReportPassProbe([
            .init(
                value: Self.report(tokens: 5),
                completed: false,
                progress: Self.progress(bytes: 10)),
        ])

        let result = await CodexCostScanner.runBackgroundReportEpisode(
            initial: initial,
            continuationDelay: .zero)
        { forceRefresh in
            await probe.load(forceRefresh: forceRefresh)
        }

        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.publishedSnapshot)
        XCTAssertEqual(result.value?.todayTokens, 41)
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

    func testSeedFirstReportReturnsFallbackAndPublishesLiveResultLater() async {
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let now = Date()

        let visible = await cache.seedFirstReport(
            now: now,
            ttl: 300,
            fallback: Self.report(tokens: 5))
        {
            await probe.load(Self.report(tokens: 50))
        }

        XCTAssertEqual(visible.value?.todayTokens, 5)
        XCTAssertFalse(visible.completed)
        await probe.waitUntilStarted()
        await probe.release()
        await probe.waitUntilFinished()
        let published = await waitForCachedReport(cache, now: now, expectedTokens: 50)
        XCTAssertEqual(published?.todayTokens, 50)
    }

    func testSeedFirstReportWithoutFallbackStillPublishesLiveResult() async {
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let now = Date()

        let visible = await cache.seedFirstReport(
            now: now,
            ttl: 300,
            fallback: nil)
        {
            await probe.load(Self.report(tokens: 60))
        }

        XCTAssertNil(visible.value)
        XCTAssertFalse(visible.completed)
        await probe.waitUntilStarted()
        await probe.release()
        await probe.waitUntilFinished()
        let published = await waitForCachedReport(cache, now: now, expectedTokens: 60)
        XCTAssertEqual(published?.todayTokens, 60)
    }

    func testSeedFirstReportPublishesFiniteSnapshotEvenWhenCatchUpRemainsPending() async {
        let cache = CodexCostScanner.Cache()
        let now = Date()

        let visible = await cache.seedFirstReport(
            now: now,
            ttl: 300,
            fallback: Self.report(tokens: 5))
        {
            return .init(
                value: Self.report(tokens: 55),
                completed: false,
                progress: Self.progress(generation: "catch-up", bytes: 10),
                publishedSnapshot: true)
        }

        XCTAssertEqual(visible.value?.todayTokens, 5)
        XCTAssertFalse(visible.completed)
        let published = await waitForCachedReport(cache, now: now, expectedTokens: 55)
        XCTAssertEqual(published?.todayTokens, 55)
    }

    func testSeedFirstContinuationPublishesNewestFiniteSnapshotWhenLaterPassStalls() async {
        let cache = CodexCostScanner.Cache()
        let now = Date()
        let continued = Self.progress(generation: "continued", bytes: 20)
        let probe = ReportPassProbe([
            .init(
                value: Self.report(tokens: 77),
                completed: false,
                progress: continued,
                publishedSnapshot: true),
            .init(
                value: Self.report(tokens: 77),
                completed: false,
                progress: continued,
                publishedSnapshot: true),
        ])

        _ = await cache.seedFirstReport(
            now: now,
            ttl: 300,
            fallback: Self.report(tokens: 5),
            continuationDelay: .zero,
            continuationLoader: { forceRefresh in
                await probe.load(forceRefresh: forceRefresh)
            })
        {
            .init(
                value: Self.report(tokens: 55),
                completed: false,
                progress: Self.progress(generation: "seed", bytes: 10),
                publishedSnapshot: true)
        }

        let published = await waitForCachedReport(cache, now: now, expectedTokens: 77)
        XCTAssertEqual(published?.todayTokens, 77)
        let calls = await probe.calls()
        XCTAssertEqual(calls, [true, true])
    }

    func testSeedFirstReportCoalescesConcurrentCallers() async {
        let cache = CodexCostScanner.Cache()
        let probe = SingleFlightProbe()
        let now = Date()
        let fallback = Self.report(tokens: 7)

        let first = Task {
            await cache.seedFirstReport(
                now: now,
                ttl: 300,
                fallback: fallback)
            {
                await probe.load(Self.report(tokens: 70))
            }
        }
        await probe.waitUntilCalled()
        let secondVisible = await cache.seedFirstReport(
            now: now,
            ttl: 300,
            fallback: fallback)
        {
            await probe.load(Self.report(tokens: 700))
        }
        let firstVisible = await first.value
        await probe.waitUntilFinished()

        XCTAssertEqual(
            [firstVisible, secondVisible].compactMap(\.value?.todayTokens),
            [7, 7])
        let callCount = await probe.calls
        XCTAssertEqual(callCount, 1)
        let published = await waitForCachedReport(cache, now: now, expectedTokens: 70)
        XCTAssertEqual(published?.todayTokens, 70)
    }

    func testSeedFirstReportDoesNotPublishOldDayOverQueuedNewDay() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let oldProbe = CatchUpRaceProbe()
        let newProbe = CatchUpRaceProbe()
        let oldDay = ISO8601DateFormatter().date(from: "2026-08-31T23:59:59Z")!
        let newDay = ISO8601DateFormatter().date(from: "2026-09-01T00:00:01Z")!

        _ = await cache.seedFirstReport(
            now: oldDay,
            ttl: 300,
            calendar: calendar,
            fallback: Self.report(tokens: 1))
        {
            await oldProbe.load(Self.report(tokens: 10))
        }
        await oldProbe.waitUntilStarted()
        let newVisible = await cache.seedFirstReport(
            now: newDay,
            ttl: 300,
            calendar: calendar,
            fallback: Self.report(tokens: 2))
        {
            await newProbe.load(Self.report(tokens: 20))
        }
        XCTAssertEqual(newVisible.value?.todayTokens, 2)

        await oldProbe.release()
        await oldProbe.waitUntilFinished()
        await newProbe.waitUntilStarted()
        let oldPublication = await cache.validReport(
            now: newDay, ttl: 300, calendar: calendar)
        XCTAssertNil(oldPublication)

        await newProbe.release()
        await newProbe.waitUntilFinished()
        let published = await waitForCachedReport(
            cache,
            now: newDay,
            calendar: calendar,
            expectedTokens: 20)
        XCTAssertEqual(published?.todayTokens, 20)
    }

    func testSeedFirstReportKeepsNewestQueuedDayWhenRequestsArriveOutOfOrder() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let oldProbe = CatchUpRaceProbe()
        let queuedProbe = SingleFlightProbe()
        let day1 = ISO8601DateFormatter().date(from: "2026-08-30T12:00:00Z")!
        let day2 = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!
        let day3 = ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")!

        _ = await cache.seedFirstReport(
            now: day1,
            ttl: 300,
            calendar: calendar,
            fallback: nil)
        {
            await oldProbe.load(Self.report(tokens: 10))
        }
        await oldProbe.waitUntilStarted()
        _ = await cache.seedFirstReport(
            now: day3,
            ttl: 300,
            calendar: calendar,
            fallback: nil)
        {
            await queuedProbe.load(Self.report(tokens: 30))
        }
        _ = await cache.seedFirstReport(
            now: day2,
            ttl: 300,
            calendar: calendar,
            fallback: nil)
        {
            await queuedProbe.load(Self.report(tokens: 20))
        }

        await oldProbe.release()
        await oldProbe.waitUntilFinished()
        await queuedProbe.waitUntilCalled()
        await queuedProbe.waitUntilFinished()
        let published = await waitForCachedReport(
            cache,
            now: day3,
            calendar: calendar,
            expectedTokens: 30)
        XCTAssertEqual(published?.todayTokens, 30)
        let queuedCalls = await queuedProbe.calls
        XCTAssertEqual(queuedCalls, 1)
    }

    func testCompletedBackgroundCatchUpCannotOverwriteNewerCompletedForeground() async {
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let now = Date()
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            continuationDelay: .zero)
        { _ in
            await probe.load(Self.report(tokens: 50))
        }
        await probe.waitUntilStarted()

        let foreground = await cache.report(
            now: now,
            ttl: 300,
            bypassCache: true)
        {
            .init(value: Self.report(tokens: 99), completed: true)
        }
        XCTAssertEqual(foreground.value?.todayTokens, 99)

        await probe.release()
        await probe.waitUntilFinished()
        let cached = await waitForCachedReport(
            cache,
            now: Date(),
            expectedTokens: 99)
        XCTAssertEqual(cached?.todayTokens, 99)
    }

    func testIncompleteForegroundHandsOffWithoutSuppressingCatchUpCompletion() async {
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let now = Date()
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            requestedAt: now,
            continuationDelay: .zero)
        { _ in
            await probe.load(Self.report(tokens: 50))
        }
        await probe.waitUntilStarted()

        let foreground = await cache.report(
            now: now.addingTimeInterval(1),
            ttl: 300,
            bypassCache: true)
        {
            .init(
                value: Self.report(tokens: 25),
                completed: false,
                progress: Self.progress(bytes: 10),
                publishedSnapshot: true)
        }
        await cache.scheduleReportCatchUp(
            initial: foreground,
            requestedAt: now.addingTimeInterval(1),
            continuationDelay: .zero)
        { _ in
            .init(value: Self.report(tokens: 999), completed: true)
        }

        await probe.release()
        await probe.waitUntilFinished()
        let cached = await waitForCachedReport(
            cache,
            now: Date(),
            expectedTokens: 50)
        XCTAssertEqual(cached?.todayTokens, 50)
    }

    func testIncompleteSeedPublicationCannotSuppressSameCheckpointCatchUpCompletion() async {
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let now = Date()
        let checkpoint = Self.progress(bytes: 10)
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: checkpoint,
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            requestedAt: now,
            continuationDelay: .zero)
        { _ in
            await probe.load(Self.report(tokens: 50))
        }
        await probe.waitUntilStarted()

        _ = await cache.seedFirstReport(
            now: now.addingTimeInterval(1),
            ttl: 300,
            bypassCache: true,
            fallback: Self.report(tokens: 5),
            continuationDelay: .zero,
            continuationLoader: { _ in
                .init(value: Self.report(tokens: 999), completed: true)
            })
        {
            .init(
                value: Self.report(tokens: 25),
                completed: false,
                progress: checkpoint,
                publishedSnapshot: true)
        }
        let partial = await waitForCachedReport(
            cache,
            now: now.addingTimeInterval(1),
            expectedTokens: 25)
        XCTAssertEqual(partial?.todayTokens, 25)

        await probe.release()
        await probe.waitUntilFinished()
        let completed = await waitForCachedReport(
            cache,
            now: now.addingTimeInterval(1),
            expectedTokens: 50)
        XCTAssertEqual(completed?.todayTokens, 50)
    }

    func testIncompleteSeedCannotOverwriteCatchUpCompletedAfterItStarted() async {
        let cache = CodexCostScanner.Cache()
        let catchUpProbe = CatchUpRaceProbe()
        let seedProbe = CatchUpRaceProbe()
        let now = Date()
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            requestedAt: now,
            continuationDelay: .zero)
        { _ in
            await catchUpProbe.load(Self.report(tokens: 50))
        }
        await catchUpProbe.waitUntilStarted()

        _ = await cache.seedFirstReport(
            now: now.addingTimeInterval(1),
            ttl: 300,
            bypassCache: true,
            fallback: Self.report(tokens: 5))
        {
            await seedProbe.load(.init(
                value: Self.report(tokens: 25),
                completed: false,
                progress: Self.progress(bytes: 20),
                publishedSnapshot: true))
        }
        await seedProbe.waitUntilStarted()

        await catchUpProbe.release()
        await catchUpProbe.waitUntilFinished()
        let completed = await waitForCachedReport(
            cache,
            now: now.addingTimeInterval(1),
            expectedTokens: 50)
        XCTAssertEqual(completed?.todayTokens, 50)

        await seedProbe.release()
        await seedProbe.waitUntilFinished()
        try? await Task.sleep(for: .milliseconds(50))
        let cached = await cache.validReport(
            now: now.addingTimeInterval(1),
            ttl: 300)
        XCTAssertEqual(cached?.todayTokens, 50)
    }

    func testCompletedSeedCannotOverwriteCatchUpCompletedAfterItStarted() async {
        let cache = CodexCostScanner.Cache()
        let catchUpProbe = CatchUpRaceProbe()
        let seedProbe = CatchUpRaceProbe()
        let now = Date()
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            requestedAt: now,
            continuationDelay: .zero)
        { _ in
            await catchUpProbe.load(Self.report(tokens: 50))
        }
        await catchUpProbe.waitUntilStarted()

        _ = await cache.seedFirstReport(
            now: now.addingTimeInterval(1),
            ttl: 300,
            bypassCache: true,
            fallback: Self.report(tokens: 5))
        {
            await seedProbe.load(Self.report(tokens: 25))
        }
        await seedProbe.waitUntilStarted()

        await catchUpProbe.release()
        await catchUpProbe.waitUntilFinished()
        let completed = await waitForCachedReport(
            cache,
            now: now.addingTimeInterval(1),
            expectedTokens: 50)
        XCTAssertEqual(completed?.todayTokens, 50)

        await seedProbe.release()
        await seedProbe.waitUntilFinished()
        try? await Task.sleep(for: .milliseconds(50))
        let cached = await cache.validReport(
            now: now.addingTimeInterval(1),
            ttl: 300)
        XCTAssertEqual(cached?.todayTokens, 50)
    }

    func testCompletedCatchUpKeepsRequestDayTimestampAcrossMidnight() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cache = CodexCostScanner.Cache()
        let probe = CatchUpRaceProbe()
        let beforeMidnight = ISO8601DateFormatter().date(
            from: "2026-08-31T23:59:59Z")!
        let afterMidnight = ISO8601DateFormatter().date(
            from: "2026-09-01T00:00:01Z")!
        let initial = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(bytes: 10),
            publishedSnapshot: true)
        await cache.scheduleReportCatchUp(
            initial: initial,
            requestedAt: beforeMidnight,
            calendar: calendar,
            continuationDelay: .zero)
        { _ in
            await probe.load(Self.report(tokens: 50))
        }
        await probe.waitUntilStarted()
        await probe.release()
        await probe.waitUntilFinished()

        let oldDay = await waitForCachedReport(
            cache,
            now: beforeMidnight,
            calendar: calendar,
            expectedTokens: 50)
        let newDay = await cache.validReport(
            now: afterMidnight,
            ttl: 300,
            calendar: calendar)
        XCTAssertEqual(oldDay?.todayTokens, 50)
        XCTAssertNil(newDay)
    }

    func testCompletedCatchUpHandsOffNewCheckpointWithSameSemanticGeneration() async {
        let cache = CodexCostScanner.Cache()
        let queuedProbe = SingleFlightProbe()
        let now = Date()
        let firstCheckpoint = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 5),
            completed: false,
            progress: Self.progress(generation: "same-semantic-generation", bytes: 10),
            publishedSnapshot: true)
        let nextCheckpoint = CodexCostScanner.ReportLoad(
            value: Self.report(tokens: 25),
            completed: false,
            progress: Self.progress(generation: "same-semantic-generation", bytes: 20),
            publishedSnapshot: true)

        await cache.scheduleReportCatchUp(
            initial: firstCheckpoint,
            requestedAt: now,
            continuationDelay: .zero)
        { _ in
            let completedCoreResult = CodexCostScanner.ReportLoad(
                value: Self.report(tokens: 50),
                completed: true)

            // The first core pass has produced its completed result, but its
            // actor callback has not run yet. Queue a newer durable checkpoint
            // from another foreground refresh in exactly that handoff window.
            await cache.scheduleReportCatchUp(
                initial: nextCheckpoint,
                requestedAt: now.addingTimeInterval(1),
                continuationDelay: .zero)
            { _ in
                await queuedProbe.load(Self.report(tokens: 99))
            }
            return completedCoreResult
        }

        await queuedProbe.waitUntilCalled()
        await queuedProbe.waitUntilFinished()
        let cached = await waitForCachedReport(
            cache,
            now: now.addingTimeInterval(1),
            expectedTokens: 99)
        XCTAssertEqual(cached?.todayTokens, 99)
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
