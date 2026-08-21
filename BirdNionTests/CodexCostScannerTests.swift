import XCTest
@testable import BirdNion
@testable import CodexBarCore

/// Tests for `CodexCostScanner`, which delegates the actual log scan to
/// CodexBarCore's `CostUsageFetcher` and owns only the snapshot → summary
/// mapping and the history-window setting. Kept in its own file so the
/// `import CodexBarCore` (needed for `CostUsageTokenSnapshot`) doesn't clash
/// with BirdNion's own Codex types in `CodexProviderTests`.
final class CodexCostScannerTests: XCTestCase {
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
}
