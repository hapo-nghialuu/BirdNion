@testable import CodexBarCore
import XCTest
@testable import BirdNion

/// Regression coverage for a real production bug (2026-07-23): a Codex CLI
/// session forked/resumed from another thread replays that thread's entire
/// history into the new rollout file with every replayed line re-stamped
/// "now". `CostUsageScanner`'s fork-baseline resolver is supposed to look up
/// the parent's cumulative totals at the fork moment and subtract them so
/// only genuinely new post-fork usage counts — but the session-id extraction
/// preferred `session_id` over `id`, and a spawned-subagent thread's
/// `session_meta` carries the ROOT conversation's id in `session_id` while
/// `id` holds its own identity. That made the file index resolve the parent
/// lookup to a random subagent transcript instead of the true parent,
/// computing a near-zero baseline and inflating the fork's counted usage by
/// its entire replayed history (561M phantom tokens on the affected account).
final class CodexForkBaselineTests: XCTestCase {
    private struct SyntheticReadError: Error {}

    private func seedFreshModelsDevPricingCache(at cacheRoot: URL) {
        ModelsDevCache.save(
            catalog: ModelsDevCatalog(providers: [:]),
            fetchedAt: Date(timeIntervalSince1970: 4_102_444_800),
            cacheRoot: cacheRoot)
    }

    private func write(_ path: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func append(_ path: URL, _ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func appendRaw(_ path: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func sessionMeta(id: String, sessionId: String? = nil, forkedFrom: String? = nil,
                             parentThread: String? = nil, cliVersion: String? = nil,
                             timestamp: String) -> String {
        var payload = "\"session_id\":\"\(sessionId ?? id)\",\"id\":\"\(id)\",\"timestamp\":\"\(timestamp)\""
        if let forkedFrom { payload += ",\"forked_from_id\":\"\(forkedFrom)\"" }
        if let parentThread { payload += ",\"parent_thread_id\":\"\(parentThread)\"" }
        if let cliVersion { payload += ",\"cli_version\":\"\(cliVersion)\"" }
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{\(payload)}}"
    }

    private func tokenCount(timestamp: String, totalTokens: Int, lastTokens: Int) -> String {
        func usage(_ tokens: Int) -> String {
            "{\"input_tokens\":\(tokens),\"cached_input_tokens\":0,\"output_tokens\":0,\"total_tokens\":\(tokens)}"
        }
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\(usage(totalTokens)),"last_token_usage":\(usage(lastTokens))}}}
        """
    }

    private func totalOnlyTokenCount(timestamp: String, totalTokens: Int) -> String {
        let usage = "{\"input_tokens\":\(totalTokens),\"cached_input_tokens\":0,"
            + "\"output_tokens\":0,\"total_tokens\":\(totalTokens)}"
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\","
            + "\"payload\":{\"type\":\"token_count\",\"info\":{"
            + "\"total_token_usage\":\(usage)}}}"
    }

    private func countedTokens(
        _ days: [String: [String: [Int]]],
        day: String
    ) -> Int {
        var total = 0
        for packed in (days[day] ?? [:]).values {
            if !packed.isEmpty { total += packed[0] }
            if packed.count > 2 { total += packed[2] }
        }
        return total
    }

    /// Fork-baseline subtraction must survive a spawned-subagent file that
    /// shares the root's id in its `session_id` field — the file index must
    /// key files by their own `id`, not by that ambiguous field.
    func testForkBaselineSurvivesSubagentSessionIdCollision() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-fork-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Spawned subagent: session_id points at the ROOT (matches real
        // codex-cli subagent session_meta shape), own id is different. Its
        // path must sort BEFORE the root file's: `CodexSessionFileIndex`
        // resolves a session id with a sequential scan that returns on the
        // FIRST file whose extracted id matches, so the buggy extraction
        // (preferring `session_id`) makes THIS file satisfy a lookup for
        // "root-session" before the real root file is ever reached.
        try write(
            tmp.appendingPathComponent("sessions/2026/01/01/rollout-2026-01-01T00-00-00-subagent-session.jsonl"),
            [
                sessionMeta(id: "subagent-session", sessionId: "root-session",
                           parentThread: "root-session", timestamp: "2026-01-01T00:00:00.000Z"),
                tokenCount(timestamp: "2026-01-01T00:01:00.000Z", totalTokens: 550, lastTokens: 550),
            ])

        // Root thread: grows to 1,000,000 cumulative tokens by 2026-01-06.
        try write(
            tmp.appendingPathComponent("sessions/2026/01/05/rollout-2026-01-05T00-00-00-root-session.jsonl"),
            [
                sessionMeta(id: "root-session", timestamp: "2026-01-05T00:00:00.000Z"),
                tokenCount(timestamp: "2026-01-05T00:01:00.000Z", totalTokens: 1_100, lastTokens: 1_100),
                tokenCount(timestamp: "2026-01-06T00:00:00.000Z", totalTokens: 1_000_000, lastTokens: 998_900),
            ])

        // Fork of the root, taken 2026-01-15: replays the root's full growth
        // (1,100 -> 1,000,000, re-stamped to the fork moment like real
        // codex-cli resume/fork does) then adds one genuinely new turn
        // (+55,000). Only that +55,000 should count as 2026-01-15 usage.
        try write(
            tmp.appendingPathComponent("sessions/2026/01/15/rollout-2026-01-15T00-00-00-fork-session.jsonl"),
            [
                sessionMeta(id: "fork-session", forkedFrom: "root-session", cliVersion: "0.149.0",
                           timestamp: "2026-01-15T00:00:00.000Z"),
                tokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 1_100, lastTokens: 1_100),
                tokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_000_000, lastTokens: 998_900),
                tokenCount(timestamp: "2026-01-15T00:00:03.000Z", totalTokens: 1_055_000, lastTokens: 55_000),
            ])

        let cacheRoot = tmp.appendingPathComponent("cache")
        let snapshot = try await CostUsageFetcher(cacheRoot: cacheRoot).loadTokenSnapshot(
            provider: .codex,
            now: DateComponents(calendar: .init(identifier: .gregorian),
                                timeZone: TimeZone(identifier: "UTC"),
                                year: 2026, month: 1, day: 20).date!,
            forceRefresh: true,
            codexHomePath: tmp.path,
            historyDays: 30)

        let forkDay = snapshot.daily.first { $0.date == "2026-01-15" }
        XCTAssertNotNil(forkDay, "expected a 2026-01-15 bucket in the scan")
        // Buggy behavior counted ~1,055,000 (the entire replayed history);
        // the fix must land near the genuinely-new 55,000-token delta.
        XCTAssertEqual(forkDay?.totalTokens ?? -1, 55_000, accuracy: 1_000)
    }

    func testCompactForkCountsFirstAndLaterTurnsWithoutParentLifetimeTotal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-compact-fork-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try write(
            tmp.appendingPathComponent("sessions/2026/01/05/rollout-parent.jsonl"),
            [
                sessionMeta(id: "parent", timestamp: "2026-01-05T00:00:00.000Z"),
                tokenCount(timestamp: "2026-01-06T00:00:00.000Z", totalTokens: 10_000_000,
                           lastTokens: 10_000_000),
            ])
        try write(
            tmp.appendingPathComponent("sessions/2026/01/15/rollout-fork.jsonl"),
            [
                sessionMeta(id: "fork", forkedFrom: "parent", cliVersion: "0.150.1",
                           timestamp: "2026-01-15T00:00:00.000Z"),
                tokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 310_000,
                           lastTokens: 10_000),
                tokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 365_000,
                           lastTokens: 55_000),
            ])

        let snapshot = try await CostUsageFetcher(cacheRoot: tmp.appendingPathComponent("cache"))
            .loadTokenSnapshot(
                provider: .codex,
                now: DateComponents(calendar: .init(identifier: .gregorian),
                                    timeZone: TimeZone(identifier: "UTC"),
                                    year: 2026, month: 1, day: 20).date!,
                forceRefresh: true,
                codexHomePath: tmp.path,
                historyDays: 30)

        let forkDay = snapshot.daily.first { $0.date == "2026-01-15" }
        XCTAssertEqual(forkDay?.totalTokens ?? -1, 65_000, accuracy: 1_000)
    }

    func testForkParserContinuationMatchesSinglePassTotals() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-fork-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("fork.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:01.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(file, [
            sessionMeta(
                id: "fork", forkedFrom: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 1_010_000,
                lastTokens: 10_000),
            filler,
            totalOnlyTokenCount(
                timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_055_000),
        ])
        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        let resolver: (String, String) throws -> CostUsageScanner.CodexForkBaseline = { _, _ in
            .resolved(.init(input: 1_000_000, cached: 0, output: 0))
        }

        let full = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            inheritedTotalsResolver: resolver)
        var stopChecks = 0
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            inheritedTotalsResolver: resolver,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 2
            })
        XCTAssertFalse(partial.scanComplete)

        let resumed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: partial.parsedBytes,
            initialModel: partial.lastModel,
            initialTotals: partial.lastCountedTotals,
            initialRawTotalsBaseline: partial.lastRawTotalsBaseline,
            initialHasDivergentTotals: partial.hasDivergentTotals,
            initialCodexTurnID: partial.lastCodexTurnID,
            initialResumeState: partial.resumeState,
            inheritedTotalsResolver: resolver)

        XCTAssertGreaterThan(resumed.parsedBytes, partial.parsedBytes)
        XCTAssertTrue(resumed.scanComplete)
        let resumedTotal = countedTokens(partial.days, day: "2026-01-15")
            + countedTokens(resumed.days, day: "2026-01-15")
        XCTAssertEqual(resumedTotal, 55_000)
        XCTAssertEqual(resumedTotal, countedTokens(full.days, day: "2026-01-15"))
    }

    func testNonCancellationReadErrorRollsBackEntireChildParse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-child-io-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("active.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:02.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(file, [
            sessionMeta(id: "active", timestamp: "2026-01-15T00:00:00.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000,
                lastTokens: 10_000),
            tokenCount(
                timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 20_000,
                lastTokens: 3_000),
            filler,
            totalOnlyTokenCount(
                timestamp: "2026-01-15T00:00:03.000Z", totalTokens: 55_000),
        ])
        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        var checks = 0
        let failed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            checkCancellation: {
                checks += 1
                if checks == 4 { throw SyntheticReadError() }
            })
        XCTAssertGreaterThanOrEqual(checks, 4)
        XCTAssertFalse(failed.scanComplete)
        XCTAssertEqual(failed.parsedBytes, 0)
        XCTAssertTrue(failed.days.isEmpty)
        XCTAssertTrue(failed.rows.isEmpty)
        XCTAssertNil(failed.lastCountedTotals)
        XCTAssertNil(failed.lastRawTotalsBaseline)
        XCTAssertNil(failed.sessionId)
        XCTAssertNil(failed.resumeState.sessionId)
        XCTAssertNil(failed.resumeState.lastCountedTotals)

        let retry = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        XCTAssertTrue(retry.scanComplete)
        XCTAssertEqual(countedTokens(retry.days, day: "2026-01-15"), 48_000)
    }

    func testNonCancellationReadErrorRollsBackParentAccumulator() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-io-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:01.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(parent, [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100_000),
            filler,
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_000_000),
        ])
        let cutoff = "2026-01-15T00:00:03.000Z"
        let generation = "parent-io-rollback"
        let queryKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: cutoff)
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        var checks = 0
        let failedResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index,
            checkCancellation: {
                checks += 1
                if checks == 4 { throw SyntheticReadError() }
            },
            shouldStop: nil,
            generation: generation)
        let failed = try failedResolver.inheritedTotals(for: "parent", atOrBefore: cutoff)
        if case .stopped = failed {} else { XCTFail("Expected failed parent read to remain retryable") }
        XCTAssertEqual(checks, 4)
        XCTAssertNil(failedResolver.pendingParentScans[queryKey])

        let retryIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let retryResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: retryIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation,
            pendingParentScans: failedResolver.pendingParentScans)
        let retry = try retryResolver.inheritedTotals(for: "parent", atOrBefore: cutoff)
        guard case let .resolved(totals) = retry else {
            return XCTFail("Expected clean parent retry")
        }
        XCTAssertEqual(retryResolver.resumeOffsetsBySessionId["parent"], 0)
        XCTAssertEqual(totals?.input, 1_000_000)
    }

    func testStoppedParentBaselineRestartsChildBeforeCounting() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("fork.jsonl")
        try write(file, [
            sessionMeta(
                id: "fork", forkedFrom: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 1_055_000,
                lastTokens: 55_000),
        ])
        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        var resolverCalls = 0
        let resolver: (String, String) throws -> CostUsageScanner.CodexForkBaseline = { _, _ in
            resolverCalls += 1
            if resolverCalls == 1 { return .stopped }
            return .resolved(.init(input: 1_000_000, cached: 0, output: 0))
        }

        let stopped = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            inheritedTotalsResolver: resolver)
        XCTAssertFalse(stopped.scanComplete)
        XCTAssertEqual(stopped.parsedBytes, 0)
        XCTAssertEqual(countedTokens(stopped.days, day: "2026-01-15"), 0)
        XCTAssertFalse(stopped.resumeState.forkBaselineResolved)

        let resumed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: stopped.parsedBytes,
            initialResumeState: stopped.resumeState,
            inheritedTotalsResolver: resolver)
        XCTAssertEqual(resolverCalls, 2)
        XCTAssertTrue(resumed.scanComplete)
        XCTAssertEqual(countedTokens(resumed.days, day: "2026-01-15"), 55_000)
    }

    func testParentBaselineJournalResumesAcrossResolverPasses() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent.jsonl")
        let child = tmp.appendingPathComponent("child.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:01.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(parent, [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100_000),
            filler,
        ])
        try write(child, [
            sessionMeta(
                id: "child", forkedFrom: "parent", timestamp: "2026-01-15T00:00:03.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:04.000Z", totalTokens: 1_055_000,
                lastTokens: 55_000),
        ])
        let generation = "parent-resume-generation"
        let cutoff = "2026-01-15T00:00:03.000Z"
        let queryKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: cutoff)
        var stopChecks = 0
        let firstIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let firstResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: firstIndex,
            checkCancellation: nil,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 5
            },
            generation: generation)
        let firstBaseline = try firstResolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        if case .stopped = firstBaseline {} else { XCTFail("Expected stopped parent parse") }
        let saved = try XCTUnwrap(firstResolver.pendingParentScans[queryKey])
        XCTAssertFalse(saved.scanComplete)
        XCTAssertGreaterThan(saved.parsedBytes, 0)

        let encoded = try JSONEncoder().encode(firstResolver.pendingParentScans)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(tmp.path))
        let persisted = try JSONDecoder().decode(
            [String: CodexParentSnapshotJournal].self, from: encoded)
        try append(parent, [
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_000_000),
        ])
        let grownMetadata = CostUsageScanner.codexFileMetadata(fileURL: parent)
        XCTAssertEqual(grownMetadata.fileId, saved.fileId)
        XCTAssertGreaterThan(grownMetadata.size, saved.size)
        var progressCache = CostUsageCache()
        progressCache.codexPendingScanGeneration = generation
        progressCache.codexPendingScanSinceKey = "2026-01-01"
        progressCache.codexPendingScanUntilKey = "2026-01-31"
        progressCache.codexPendingFileManifest = [:]
        progressCache.codexPendingFiles = [:]
        progressCache.codexPendingDays = [:]
        progressCache.codexPendingParentScans = persisted
        CostUsageCacheIO.save(provider: .codex, cache: progressCache, cacheRoot: tmp)
        let status = await CostUsageFetcher(cacheRoot: tmp).loadCodexPendingScanStatus()
        XCTAssertEqual(status?.parsedBytes, saved.parsedBytes)
        XCTAssertEqual(status?.incompleteFiles, 1)
        let secondIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let secondResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: secondIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation,
            pendingParentScans: persisted)
        let secondBaseline = try secondResolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        XCTAssertEqual(secondResolver.resumeOffsetsBySessionId["parent"], saved.parsedBytes)
        guard case let .resolved(parentTotals) = secondBaseline else {
            return XCTFail("Expected resolved parent baseline")
        }
        XCTAssertEqual(parentTotals?.input, 100_000)
        XCTAssertTrue(secondResolver.pendingParentScans[queryKey]?.scanComplete == true)

        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        let parsedChild = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: child,
            range: range,
            inheritedTotalsResolver: { sessionId, timestamp in
                try secondResolver.inheritedTotals(for: sessionId, atOrBefore: timestamp)
            })
        XCTAssertTrue(parsedChild.scanComplete)
        XCTAssertEqual(countedTokens(parsedChild.days, day: "2026-01-15"), 955_000)

        let catchUpResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: secondIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: "parent-resume-catch-up-generation")
        let catchUpBaseline = try catchUpResolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        guard case let .resolved(catchUpParentTotals) = catchUpBaseline else {
            return XCTFail("Expected catch-up parent baseline")
        }
        XCTAssertEqual(catchUpParentTotals?.input, 1_000_000)
        let caughtUpChild = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: child,
            range: range,
            inheritedTotalsResolver: { sessionId, timestamp in
                try catchUpResolver.inheritedTotals(for: sessionId, atOrBefore: timestamp)
            })
        XCTAssertTrue(caughtUpChild.scanComplete)
        XCTAssertEqual(countedTokens(caughtUpChild.days, day: "2026-01-15"), 55_000)
    }

    func testForkChildJournalResumesAfterAppendWithoutDuplicateTotals() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-child-growth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let child = tmp.appendingPathComponent("child.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:01.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(child, [
            sessionMeta(
                id: "child", forkedFrom: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 1_010_000,
                lastTokens: 10_000),
            filler,
        ])
        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        let baseline: (String, String) throws -> CostUsageScanner.CodexForkBaseline = { _, _ in
            .resolved(.init(input: 1_000_000, cached: 0, output: 0))
        }
        var stopChecks = 0
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: child,
            range: range,
            inheritedTotalsResolver: baseline,
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 5
            })
        XCTAssertFalse(partial.scanComplete)
        XCTAssertGreaterThan(partial.parsedBytes, 0)
        let generation = "child-growth-generation"
        let oldMetadata = CostUsageScanner.codexFileMetadata(fileURL: child)
        let frozenBeforeAppend = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: child))
        var cache = CostUsageCache()
        cache.days = partial.days
        cache.files[child.path] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: frozenBeforeAppend.mtimeUnixMs,
            size: frozenBeforeAppend.targetEOF,
            days: partial.days,
            parsedBytes: partial.parsedBytes,
            lastModel: partial.lastModel,
            lastTotals: partial.lastTotals,
            lastCountedTotals: partial.lastCountedTotals,
            lastRawTotalsBaseline: partial.lastRawTotalsBaseline,
            hasDivergentTotals: partial.hasDivergentTotals,
            lastCodexTurnID: partial.lastCodexTurnID,
            sessionId: partial.sessionId,
            forkedFromId: partial.forkedFromId,
            codexScanFileId: frozenBeforeAppend.fileId,
            codexScanTargetSize: frozenBeforeAppend.targetEOF,
            codexScanContentFingerprint: frozenBeforeAppend.contentFingerprint,
            codexScanComplete: false,
            codexScanGeneration: generation,
            codexParseResumeState: partial.resumeState)

        try append(child, [
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_055_000),
        ])
        let newMetadata = CostUsageScanner.codexFileMetadata(fileURL: child)
        let frozenAfterAppend = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: child))
        XCTAssertEqual(newMetadata.fileId, oldMetadata.fileId)
        XCTAssertGreaterThan(newMetadata.size, oldMetadata.size)

        let fileIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [child], roots: [], cachedSessionFiles: ["child": child])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: fileIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation)
        let resources = CostUsageScanner.CodexScanResources(
            fileIndex: fileIndex,
            inheritedResolver: resolver,
            modelsDevCatalog: nil,
            modelsDevCacheRoot: nil,
            priorityTurns: [:])
        let context = CostUsageScanner.CodexFileScanContext(
            range: range,
            forceFullScan: true,
            dropDeferredCodexRows: false,
            requiresTurnIDCache: false,
            changedPriorityTurnIDs: [],
            resources: resources,
            checkCancellation: nil,
            shouldStop: nil,
            scanGeneration: generation)
        var scanState = CostUsageScanner.CodexScanState()
        let resumed = try CostUsageScanner.appendCodexFileIncrementIfPossible(
            input: .init(
                fileURL: child,
                metadata: newMetadata,
                target: frozenBeforeAppend,
                cached: cache.files[child.path]),
            context: context,
            cache: &cache,
            state: &scanState)

        XCTAssertTrue(resumed)
        let completed = try XCTUnwrap(cache.files[child.path])
        XCTAssertTrue(completed.codexScanComplete == true)
        XCTAssertEqual(completed.parsedBytes, oldMetadata.size)
        XCTAssertEqual(completed.codexScanTargetSize, oldMetadata.size)
        XCTAssertEqual(countedTokens(completed.days, day: "2026-01-15"), 10_000)
        XCTAssertEqual(countedTokens(cache.days, day: "2026-01-15"), 10_000)

        let catchUpContext = CostUsageScanner.CodexFileScanContext(
            range: range,
            forceFullScan: false,
            dropDeferredCodexRows: false,
            requiresTurnIDCache: false,
            changedPriorityTurnIDs: [],
            resources: resources,
            checkCancellation: nil,
            shouldStop: nil,
            scanGeneration: "child-growth-catch-up-generation")
        var catchUpScanState = CostUsageScanner.CodexScanState()
        let caughtUp = try CostUsageScanner.appendCodexFileIncrementIfPossible(
            input: .init(
                fileURL: child,
                metadata: newMetadata,
                target: frozenAfterAppend,
                cached: cache.files[child.path]),
            context: catchUpContext,
            cache: &cache,
            state: &catchUpScanState)
        XCTAssertTrue(caughtUp)
        let caughtUpFile = try XCTUnwrap(cache.files[child.path])
        XCTAssertTrue(caughtUpFile.codexScanComplete == true)
        XCTAssertEqual(caughtUpFile.parsedBytes, newMetadata.size)
        XCTAssertEqual(countedTokens(caughtUpFile.days, day: "2026-01-15"), 55_000)
        XCTAssertEqual(countedTokens(cache.days, day: "2026-01-15"), 55_000)
    }

    func testChildGrowthDuringPassPersistsCoveredOffsetAndResumes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-child-in-pass-growth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("active.jsonl")
        try write(file, [
            sessionMeta(id: "active", timestamp: "2026-01-15T00:00:00.000Z"),
            tokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000,
                lastTokens: 10_000),
        ])
        let initialMetadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        let frozenInitial = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: file))
        let filler = #"{"timestamp":"2026-01-15T00:00:02.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        let range = CostUsageScanner.CostUsageDayRange(
            since: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
            until: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z")!)
        let generation = "child-in-pass-growth-generation"
        let fileIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [file], roots: [], cachedSessionFiles: ["active": file])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: fileIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation)
        let resources = CostUsageScanner.CodexScanResources(
            fileIndex: fileIndex,
            inheritedResolver: resolver,
            modelsDevCatalog: nil,
            modelsDevCacheRoot: nil,
            priorityTurns: [:])
        var appended = false
        var stopChecks = 0
        let firstContext = CostUsageScanner.CodexFileScanContext(
            range: range,
            forceFullScan: true,
            dropDeferredCodexRows: false,
            requiresTurnIDCache: false,
            changedPriorityTurnIDs: [],
            resources: resources,
            checkCancellation: {
                guard !appended else { return }
                appended = true
                try self.append(file, [
                    self.totalOnlyTokenCount(
                        timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 20_000),
                    filler,
                    self.totalOnlyTokenCount(
                        timestamp: "2026-01-15T00:00:03.000Z", totalTokens: 55_000),
                ])
            },
            shouldStop: {
                stopChecks += 1
                return stopChecks >= 3
            },
            scanGeneration: generation)
        var cache = CostUsageCache()
        var state = CostUsageScanner.CodexScanState()
        try CostUsageScanner.rescanCodexFile(
            input: .init(
                fileURL: file,
                metadata: initialMetadata,
                target: frozenInitial,
                cached: nil),
            context: firstContext,
            cache: &cache,
            state: &state)

        let pending = try XCTUnwrap(cache.files[file.path])
        let savedOffset = try XCTUnwrap(pending.parsedBytes)
        XCTAssertEqual(savedOffset, initialMetadata.size)
        XCTAssertEqual(pending.size, savedOffset)
        XCTAssertEqual(pending.codexScanTargetSize, savedOffset)
        XCTAssertTrue(pending.codexScanComplete == false)

        let persistedData = try JSONEncoder().encode(cache)
        var persisted = try JSONDecoder().decode(CostUsageCache.self, from: persistedData)
        let currentMetadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        XCTAssertGreaterThan(currentMetadata.size, savedOffset)
        let secondContext = CostUsageScanner.CodexFileScanContext(
            range: range,
            forceFullScan: true,
            dropDeferredCodexRows: false,
            requiresTurnIDCache: false,
            changedPriorityTurnIDs: [],
            resources: resources,
            checkCancellation: nil,
            shouldStop: nil,
            scanGeneration: generation)
        var secondState = CostUsageScanner.CodexScanState()
        let resumed = try CostUsageScanner.appendCodexFileIncrementIfPossible(
            input: .init(
                fileURL: file,
                metadata: currentMetadata,
                target: frozenInitial,
                cached: persisted.files[file.path]),
            context: secondContext,
            cache: &persisted,
            state: &secondState)
        XCTAssertTrue(resumed)
        let completed = try XCTUnwrap(persisted.files[file.path])
        XCTAssertTrue(completed.codexScanComplete == true)
        XCTAssertEqual(completed.parsedBytes, initialMetadata.size)
        XCTAssertEqual(countedTokens(completed.days, day: "2026-01-15"), 10_000)
        XCTAssertEqual(countedTokens(persisted.days, day: "2026-01-15"), 10_000)

        let catchUpContext = CostUsageScanner.CodexFileScanContext(
            range: range,
            forceFullScan: false,
            dropDeferredCodexRows: false,
            requiresTurnIDCache: false,
            changedPriorityTurnIDs: [],
            resources: resources,
            checkCancellation: nil,
            shouldStop: nil,
            scanGeneration: "child-in-pass-growth-catch-up-generation")
        var catchUpState = CostUsageScanner.CodexScanState()
        let frozenAfterAppend = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: file))
        let caughtUp = try CostUsageScanner.appendCodexFileIncrementIfPossible(
            input: .init(
                fileURL: file,
                metadata: currentMetadata,
                target: frozenAfterAppend,
                cached: persisted.files[file.path]),
            context: catchUpContext,
            cache: &persisted,
            state: &catchUpState)
        XCTAssertTrue(caughtUp)
        let caughtUpFile = try XCTUnwrap(persisted.files[file.path])
        XCTAssertTrue(caughtUpFile.codexScanComplete == true)
        XCTAssertEqual(caughtUpFile.parsedBytes, currentMetadata.size)
        XCTAssertEqual(countedTokens(caughtUpFile.days, day: "2026-01-15"), 55_000)
        XCTAssertEqual(countedTokens(persisted.days, day: "2026-01-15"), 55_000)
    }

    func testParentGrowthDuringPassPersistsCoveredOffsetAndResumes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-in-pass-growth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent.jsonl")
        try write(parent, [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(
                timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100_000),
        ])
        let initialSize = CostUsageScanner.codexFileMetadata(fileURL: parent).size
        let filler = #"{"timestamp":"2026-01-15T00:00:02.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        let generation = "parent-in-pass-growth-generation"
        let cutoff = "2026-01-15T00:00:03.000Z"
        let queryKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: cutoff)
        var stopChecks = 0
        var appended = false
        let firstIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let firstResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: firstIndex,
            checkCancellation: nil,
            shouldStop: {
                stopChecks += 1
                if stopChecks == 3, !appended {
                    appended = true
                    try? self.append(parent, [
                        self.totalOnlyTokenCount(
                            timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_000_000),
                        filler,
                    ])
                }
                return stopChecks >= 5
            },
            generation: generation)
        let first = try firstResolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        if case .stopped = first {} else { XCTFail("Expected stopped parent parse") }
        let saved = try XCTUnwrap(firstResolver.pendingParentScans[queryKey])
        XCTAssertGreaterThan(saved.parsedBytes, initialSize)
        XCTAssertGreaterThanOrEqual(saved.size, saved.parsedBytes)
        XCTAssertFalse(saved.scanComplete)

        let data = try JSONEncoder().encode(firstResolver.pendingParentScans)
        let persisted = try JSONDecoder().decode(
            [String: CodexParentSnapshotJournal].self, from: data)
        let currentMetadata = CostUsageScanner.codexFileMetadata(fileURL: parent)
        XCTAssertGreaterThan(currentMetadata.size, saved.parsedBytes)
        let secondIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let secondResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: secondIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation,
            pendingParentScans: persisted)
        let second = try secondResolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        XCTAssertEqual(secondResolver.resumeOffsetsBySessionId["parent"], saved.parsedBytes)
        guard case let .resolved(totals) = second else {
            return XCTFail("Expected resumed parent baseline")
        }
        XCTAssertEqual(totals?.input, 1_000_000)
        XCTAssertTrue(secondResolver.pendingParentScans[queryKey]?.scanComplete == true)
    }

    func testParentJournalIsBoundedIndependentlyOfTokenTimeline() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-bounded-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent.jsonl")
        var lines = [sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z")]
        for value in 1...2_000 {
            lines.append(totalOnlyTokenCount(
                timestamp: String(format: "2026-01-15T00:%02d:%02d.000Z", (value / 60) % 60, value % 60),
                totalTokens: value * 100))
        }
        try write(parent, lines)
        let generation = "bounded-parent-journal"
        let cutoff = "2026-01-15T01:00:00.000Z"
        let queryKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: cutoff)
        var checks = 0
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index,
            checkCancellation: nil,
            shouldStop: {
                checks += 1
                return checks >= 5
            },
            generation: generation)
        let result = try resolver.inheritedTotals(
            for: "parent", atOrBefore: cutoff)
        if case .stopped = result {} else { XCTFail("Expected bounded parent parse to stop") }
        let journal = try XCTUnwrap(resolver.pendingParentScans[queryKey])
        XCTAssertGreaterThan(journal.parsedBytes, 0)
        XCTAssertNil(journal.snapshots)
        XCTAssertLessThan(try JSONEncoder().encode(journal).count, 2_048)

        var legacyTimeline = journal
        legacyTimeline.snapshots = []
        let filteredResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation,
            pendingParentScans: [queryKey: legacyTimeline])
        XCTAssertTrue(filteredResolver.pendingParentScans.isEmpty)
    }

    func testColdParentLookupConvergesAcrossPersistedBoundedPasses() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cold-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("sessions", isDirectory: true)
        for index in 0..<16 {
            try write(
                root.appendingPathComponent(String(format: "d%02d/other.jsonl", index)),
                [sessionMeta(
                    id: "other-\(index)", timestamp: "2026-01-15T00:00:00.000Z")])
        }
        let parent = root.appendingPathComponent("zz/parent.jsonl")
        let filler = #"{"timestamp":"2026-01-15T00:00:01.500Z","type":"event_msg","payload":{"type":"note","text":""#
            + String(repeating: "x", count: 300_000)
            + #""}}"#
        try write(parent, [
            sessionMeta(id: "cold-parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100_000),
            filler,
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 1_000_000),
        ])

        let generation = "cold-parent-generation"
        let cutoff = "2026-01-15T00:00:03.000Z"
        var discoveries: [String: CodexParentDiscoveryJournal] = [:]
        var parentScans: [String: CodexParentSnapshotJournal] = [:]
        var resolved: CostUsageCodexTotals?
        var passes = 0
        while passes < 80, resolved == nil {
            passes += 1
            var checks = 0
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [],
                roots: [root],
                checkCancellation: nil,
                shouldStop: {
                    checks += 1
                    return checks >= 24
                },
                generation: generation,
                pendingParentDiscoveries: discoveries)
            let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
                fileIndex: index,
                checkCancellation: nil,
                shouldStop: {
                    checks += 1
                    return checks >= 24
                },
                generation: generation,
                pendingParentScans: parentScans)
            let result = try resolver.inheritedTotals(for: "cold-parent", atOrBefore: cutoff)

            let discoveryData = try JSONEncoder().encode(index.pendingParentDiscoveries)
            let parentData = try JSONEncoder().encode(resolver.pendingParentScans)
            XCTAssertFalse(String(decoding: discoveryData, as: UTF8.self).contains(tmp.path))
            XCTAssertLessThan(discoveryData.count, 4_096)
            discoveries = try JSONDecoder().decode(
                [String: CodexParentDiscoveryJournal].self, from: discoveryData)
            parentScans = try JSONDecoder().decode(
                [String: CodexParentSnapshotJournal].self, from: parentData)
            if case let .resolved(totals) = result { resolved = totals }
        }
        XCTAssertGreaterThan(passes, 1)
        XCTAssertLessThan(passes, 80)
        XCTAssertEqual(resolved?.input, 1_000_000)
        XCTAssertEqual(discoveries["cold-parent"]?.resolvedRelativePath, "zz/parent.jsonl")
        XCTAssertFalse(try JSONEncoder().encode(parentScans).isEmpty)
    }

    func testColdParentTargetCheckpointWinsPostIdentityDeadline() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cold-target-checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("sessions", isDirectory: true)
        try write(root.appendingPathComponent("parent.jsonl"), [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100),
        ])
        var checks = 0
        let stop: () -> Bool = {
            checks += 1
            return checks >= 6
        }
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [root],
            shouldStop: stop,
            generation: "cold-target-checkpoint")
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index,
            checkCancellation: nil,
            shouldStop: stop,
            generation: "cold-target-checkpoint")
        let result = try resolver.inheritedTotals(
            for: "parent", atOrBefore: "2026-01-15T00:00:02.000Z")
        if case .stopped = result {} else { XCTFail("Expected deadline after target identity") }
        XCTAssertEqual(checks, 6)
        XCTAssertEqual(
            index.pendingParentDiscoveries["parent"]?.resolvedRelativePath,
            "parent.jsonl")
    }

    func testColdDiscoveryAdvancesPastDelayedMetadataWithinStrictPassBudget() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cold-poison-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("sessions", isDirectory: true)
        let oversizedPrefix = #"{"type":"note","text":""#
            + String(repeating: "x", count: 2 * 1024 * 1024)
            + #""}"#
        try write(root.appendingPathComponent("a-delayed.jsonl"), [
            oversizedPrefix,
            sessionMeta(id: "delayed", timestamp: "2026-01-15T00:00:00.000Z"),
        ])
        let target = root.appendingPathComponent("z-target.jsonl")
        try write(target, [
            sessionMeta(id: "target", timestamp: "2026-01-15T00:00:00.000Z"),
        ])

        let generation = "cold-poison-generation"
        var discoveries: [String: CodexParentDiscoveryJournal] = [:]
        var found: URL?
        var passes = 0
        var maximumCancellationChecks = 0
        while passes < 6, found == nil {
            passes += 1
            var stopChecks = 0
            var cancellationChecks = 0
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [],
                roots: [root],
                checkCancellation: {
                    cancellationChecks += 1
                    if cancellationChecks > 11 { throw SyntheticReadError() }
                },
                shouldStop: {
                    stopChecks += 1
                    return stopChecks >= 3
                },
                generation: generation,
                pendingParentDiscoveries: discoveries)
            found = try index.fileURL(for: "target")
            maximumCancellationChecks = max(maximumCancellationChecks, cancellationChecks)

            let encoded = try JSONEncoder().encode(index.pendingParentDiscoveries)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(tmp.path))
            XCTAssertLessThan(encoded.count, 4_096)
            discoveries = try JSONDecoder().decode(
                [String: CodexParentDiscoveryJournal].self, from: encoded)
        }

        XCTAssertEqual(passes, 2)
        XCTAssertLessThanOrEqual(maximumCancellationChecks, 11)
        XCTAssertEqual(found?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(
            discoveries["target"]?.resolvedRelativePath,
            "z-target.jsonl")
    }

    func testColdDiscoveryEnumeratesFlatDirectoryOncePerUnboundedPass() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cold-flat-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("sessions", isDirectory: true)
        for index in 0..<128 {
            try write(
                root.appendingPathComponent(String(format: "a%03d.jsonl", index)),
                [#"{"type":"note"}"#])
        }
        let target = root.appendingPathComponent("z-target.jsonl")
        try write(target, [
            sessionMeta(id: "target", timestamp: "2026-01-15T00:00:00.000Z"),
        ])

        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [], roots: [root], generation: "cold-flat-batch")
        let found = try index.fileURL(for: "target")
        XCTAssertEqual(found?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(index.directoryEnumerationCount, 1)
        let encoded = try JSONEncoder().encode(index.pendingParentDiscoveries)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(tmp.path))
    }

    func testColdParentIdentityIOFailureStaysPendingThenRetries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cold-identity-io-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("sessions", isDirectory: true)
        try write(root.appendingPathComponent("parent.jsonl"), [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 123_000),
        ])
        let generation = "cold-identity-io"
        let cutoff = "2026-01-15T00:00:02.000Z"
        var checks = 0
        let firstIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [root],
            checkCancellation: {
                checks += 1
                if checks == 5 { throw SyntheticReadError() }
            },
            generation: generation)
        let firstResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: firstIndex,
            checkCancellation: {
                checks += 1
                if checks == 5 { throw SyntheticReadError() }
            },
            shouldStop: nil,
            generation: generation)
        let first = try firstResolver.inheritedTotals(for: "parent", atOrBefore: cutoff)
        if case .stopped = first {} else {
            XCTFail("Retryable identity I/O failure must not fabricate an unresolved baseline")
        }
        XCTAssertEqual(checks, 5)
        XCTAssertTrue(firstIndex.discoveryIsPending(sessionId: "parent"))
        XCTAssertNil(firstIndex.pendingParentDiscoveries["parent"]?.directoryStack.last?.lastEntryName)

        let encoded = try JSONEncoder().encode(firstIndex.pendingParentDiscoveries)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(tmp.path))
        let persisted = try JSONDecoder().decode(
            [String: CodexParentDiscoveryJournal].self, from: encoded)
        let secondIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [root],
            generation: generation,
            pendingParentDiscoveries: persisted)
        let secondResolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: secondIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation)
        let second = try secondResolver.inheritedTotals(for: "parent", atOrBefore: cutoff)
        guard case let .resolved(totals) = second else {
            return XCTFail("Expected retry to resolve the actual cold parent")
        }
        XCTAssertEqual(totals?.input, 123_000)
        XCTAssertEqual(
            secondIndex.pendingParentDiscoveries["parent"]?.resolvedRelativePath,
            "parent.jsonl")
    }

    func testParentJournalUsesPerCutoffFileOrderAndUpdatesAfterAppend() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-parent-cutoffs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parent = tmp.appendingPathComponent("parent.jsonl")
        try write(parent, [
            sessionMeta(id: "parent", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 100),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:04.000Z", totalTokens: 200),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 300),
        ])
        let generation = "parent-two-cutoffs"
        let earlyCutoff = "2026-01-15T00:00:01.000Z"
        let laterCutoff = "2026-01-15T00:00:03.000Z"
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index, checkCancellation: nil, shouldStop: nil, generation: generation)
        let early = try resolver.inheritedTotals(for: "parent", atOrBefore: earlyCutoff)
        let later = try resolver.inheritedTotals(for: "parent", atOrBefore: laterCutoff)
        guard case let .resolved(earlyTotals) = early,
              case let .resolved(laterTotals) = later
        else { return XCTFail("Expected both parent baselines") }
        XCTAssertEqual(earlyTotals?.input, 100)
        XCTAssertEqual(laterTotals?.input, 300)
        let earlyKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: earlyCutoff)
        let laterKey = CostUsageScanner.codexParentQueryKey(
            sessionId: "parent", cutoffTimestamp: laterCutoff)
        XCTAssertNotEqual(earlyKey, laterKey)
        XCTAssertEqual(resolver.pendingParentScans.count, 2)
        XCTAssertNil(resolver.pendingParentScans[laterKey]?.snapshots)

        let persistedData = try JSONEncoder().encode(resolver.pendingParentScans)
        XCTAssertFalse(String(decoding: persistedData, as: UTF8.self).contains("\"snapshots\":["))
        let persisted = try JSONDecoder().decode(
            [String: CodexParentSnapshotJournal].self, from: persistedData)
        try append(parent, [
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:00.500Z", totalTokens: 400),
        ])
        let resumedIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedSessionFiles: ["parent": parent])
        let resumed = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: resumedIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: generation,
            pendingParentScans: persisted)
        let updated = try resumed.inheritedTotals(for: "parent", atOrBefore: laterCutoff)
        guard case let .resolved(updatedTotals) = updated else {
            return XCTFail("Expected appended parent baseline")
        }
        XCTAssertNil(resumed.resumeOffsetsBySessionId["parent"])
        XCTAssertEqual(updatedTotals?.input, 300)

        let catchUp = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: resumedIndex,
            checkCancellation: nil,
            shouldStop: nil,
            generation: "parent-two-cutoffs-catch-up")
        let appended = try catchUp.inheritedTotals(for: "parent", atOrBefore: laterCutoff)
        guard case let .resolved(appendedTotals) = appended else {
            return XCTFail("Expected catch-up parent baseline")
        }
        XCTAssertEqual(appendedTotals?.input, 400)
    }

    func testPublicPendingGenerationIsStableOpaqueIdentifier() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-opaque-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var cache = CostUsageCache()
        let internalGeneration = "pricing|priority|\(tmp.path)/private-root=0"
        cache.codexPendingScanGeneration = internalGeneration
        cache.codexPendingScanSinceKey = "2026-01-01"
        cache.codexPendingScanUntilKey = "2026-01-31"
        cache.codexPendingFileManifest = [:]
        cache.codexPendingFiles = [:]
        cache.codexPendingDays = [:]
        cache.codexPendingParentDiscoveries = [
            "private-session": CodexParentDiscoveryJournal(
                generation: internalGeneration,
                rootIndex: 0,
                directoryStack: [.init(relativePath: "2026/01", lastEntryName: "a")],
                resolvedRootIndex: nil,
                resolvedRelativePath: nil),
        ]
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: tmp)

        let fetcher = CostUsageFetcher(cacheRoot: tmp)
        let firstStatus = await fetcher.loadCodexPendingScanStatus()
        let secondStatus = await fetcher.loadCodexPendingScanStatus()
        let first = try XCTUnwrap(firstStatus)
        let second = try XCTUnwrap(secondStatus)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(first.progressFingerprint, second.progressFingerprint)
        XCTAssertTrue(first.generation.hasPrefix("codex-"))
        XCTAssertTrue(first.progressFingerprint.hasPrefix("codex-progress-"))
        XCTAssertNotEqual(first.generation, internalGeneration)
        XCTAssertFalse(first.generation.contains(tmp.path))
        XCTAssertFalse(first.progressFingerprint.contains(tmp.path))

        cache.codexPendingParentDiscoveries?["private-session"]?.directoryStack[0]
            .lastEntryName = "b"
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: tmp)
        let advancedStatus = await fetcher.loadCodexPendingScanStatus()
        let advanced = try XCTUnwrap(advancedStatus)
        XCTAssertEqual(advanced.parsedBytes, first.parsedBytes)
        XCTAssertEqual(advanced.incompleteFiles, first.incompleteFiles)
        XCTAssertNotEqual(advanced.progressFingerprint, first.progressFingerprint)
    }

    func testLegacyMixedPendingCacheWithoutManifestLosesTrustedCoverageAndNeverCachedSnapshot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-legacy-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var legacy = CostUsageCache()
        legacy.codexPendingScanGeneration = "legacy-generation"
        legacy.lastScanUnixMs = 123
        legacy.scanSinceKey = "2025-01-01"
        legacy.scanUntilKey = "2026-12-31"
        legacy.days = ["2026-01-15": ["gpt-5": [123, 0, 0]]]
        legacy.files["partial.jsonl"] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 10,
            days: legacy.days,
            parsedBytes: 10,
            sessionId: "partial",
            codexScanComplete: false,
            codexScanGeneration: "legacy-generation")
        let originalDays = legacy.days
        CostUsageCacheIO.save(provider: .codex, cache: legacy, cacheRoot: tmp)

        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(migrated.days, originalDays)
        let retained = try XCTUnwrap(migrated.files["partial.jsonl"])
        XCTAssertEqual(retained.mtimeUnixMs, 1)
        XCTAssertEqual(retained.size, 10)
        XCTAssertEqual(retained.days, originalDays)
        XCTAssertEqual(retained.parsedBytes, 10)
        XCTAssertEqual(migrated.lastScanUnixMs, 0)
        XCTAssertNil(migrated.scanSinceKey)
        XCTAssertNil(migrated.scanUntilKey)
        XCTAssertNil(migrated.codexPendingScanGeneration)
        XCTAssertNil(migrated.codexPendingFileManifest)
        XCTAssertNil(migrated.codexPendingFileOrder)
        XCTAssertNil(migrated.codexPendingFlatDiscoveryOffsets)
        XCTAssertNil(migrated.codexPendingFlatDiscoveryProgress)
        XCTAssertNil(migrated.codexPendingFiles)
        XCTAssertNil(migrated.codexPendingDays)
        XCTAssertNil(migrated.codexPendingParentScans)
        XCTAssertNil(migrated.codexPendingParentDiscoveries)
        let cached = await CostUsageFetcher(cacheRoot: tmp).loadCachedCodexTokenSnapshot()
        XCTAssertNil(cached)
    }

    func testIncompletePassLeavesCommittedCacheByteEquivalent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-committed-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        try write(
            home.appendingPathComponent("sessions/2026/01/15/rollout.jsonl"),
            [
                sessionMeta(id: "current", timestamp: "2026-01-15T00:00:00.000Z"),
                tokenCount(
                    timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 55_000,
                    lastTokens: 55_000),
            ])
        var seed = CostUsageCache()
        seed.lastScanUnixMs = 123
        seed.scanSinceKey = "2026-01-01"
        seed.scanUntilKey = "2026-01-31"
        seed.days = ["2026-01-10": ["gpt-5": [777, 0, 0]]]
        CostUsageCacheIO.save(provider: .codex, cache: seed, cacheRoot: tmp)
        let committedBefore = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(snapshot.scanIncomplete)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertNil(snapshot.sessionTokens)
        XCTAssertNil(snapshot.sessionCostUSD)
        XCTAssertNil(snapshot.last30DaysTokens)
        XCTAssertNil(snapshot.last30DaysCostUSD)
        XCTAssertNil(snapshot.projectBreakdown)
        XCTAssertNil(snapshot.projectRetractions)

        var committedAfter = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNotNil(committedAfter.codexPendingScanGeneration)
        XCTAssertNotNil(committedAfter.codexPendingScanSinceKey)
        XCTAssertNotNil(committedAfter.codexPendingScanUntilKey)
        XCTAssertNotNil(committedAfter.codexPendingFileManifest)
        XCTAssertNotNil(committedAfter.codexPendingFiles)
        XCTAssertNotNil(committedAfter.codexPendingParentScans)
        XCTAssertNotNil(committedAfter.codexPendingParentDiscoveries)
        let cached = await CostUsageFetcher(cacheRoot: tmp).loadCachedCodexTokenSnapshot()
        XCTAssertNil(cached)
        let status = await CostUsageFetcher(cacheRoot: tmp).loadCodexPendingScanStatus()
        XCTAssertNotEqual(status?.generation, committedAfter.codexPendingScanGeneration)
        XCTAssertTrue(status?.generation.hasPrefix("codex-") == true)
        committedAfter.codexPendingScanGeneration = nil
        committedAfter.codexPendingManifestContractVersion = nil
        committedAfter.codexPendingPriorityTurnsCursorPayload = nil
        committedAfter.codexPendingPriorityTurnsPayload = nil
        committedAfter.codexPendingScanSinceKey = nil
        committedAfter.codexPendingScanUntilKey = nil
        committedAfter.codexPendingManifestCapturedUnixMs = nil
        committedAfter.codexPendingNeedsFlatReconciliation = nil
        committedAfter.codexPendingTurnIDBackfillPaths = nil
        committedAfter.codexPendingFileManifest = nil
        committedAfter.codexPendingFileOrder = nil
        committedAfter.codexPendingFlatDiscoveryOffsets = nil
        committedAfter.codexPendingFlatDiscoveryProgress = nil
        committedAfter.codexPendingFiles = nil
        committedAfter.codexPendingDays = nil
        committedAfter.codexPendingParentScans = nil
        committedAfter.codexPendingParentDiscoveries = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(committedAfter), try encoder.encode(committedBefore))

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(completed.scanIncomplete)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNil(finalized.codexPendingScanGeneration)
        XCTAssertNil(finalized.codexPendingScanSinceKey)
        XCTAssertNil(finalized.codexPendingScanUntilKey)
        XCTAssertNil(finalized.codexPendingFileManifest)
        XCTAssertNil(finalized.codexPendingFiles)
        XCTAssertNil(finalized.codexPendingDays)
        XCTAssertNil(finalized.codexPendingParentScans)
        XCTAssertNil(finalized.codexPendingParentDiscoveries)
        XCTAssertFalse(finalized.files.isEmpty)
    }

    func testFrozenGenerationCompletesBeforeAppendedAndNewFilesEnterCatchUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-frozen-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let day = "2026-01-15"
        let directory = home.appendingPathComponent("sessions/2026/01/15")
        let fileA = directory.appendingPathComponent("a.jsonl")
        let fileB = directory.appendingPathComponent("b.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        try write(fileA, [
            sessionMeta(id: "A", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000),
        ])

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(first.scanIncomplete)
        XCTAssertNotNil(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp).codexPendingScanGeneration)

        try append(fileA, [
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 20_000),
        ])
        try write(fileB, [
            sessionMeta(id: "B", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 30_000),
        ])

        let catchUpSeed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertTrue(catchUpSeed.scanIncomplete)
        let committed = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(countedTokens(committed.days, day: day), 10_000)
        XCTAssertTrue(committed.files.values.contains { $0.sessionId == "A" })
        XCTAssertFalse(committed.files.values.contains { $0.sessionId == "B" })
        XCTAssertNotNil(committed.codexPendingScanGeneration)

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.daily.first { $0.date == day }?.totalTokens, 50_000)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNil(finalized.codexPendingScanGeneration)
        XCTAssertEqual(countedTokens(finalized.days, day: day), 50_000)
    }

    func testUnavailableFrozenTargetAfterPartialResumePreservesCommittedSnapshotAndSeedsCatchUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-unavailable-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let file = home.appendingPathComponent("sessions/2026/01/15/rollout.jsonl")
        let committedAliasRoot = tmp.appendingPathComponent("committed-home-alias")
        let committedAliasFile = committedAliasRoot
            .appendingPathComponent("sessions/2026/01/15/rollout.jsonl")
        let traceDatabaseURL = tmp.appendingPathComponent("missing-codex-trace.sqlite")
        let day = "2026-01-15"
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        let metadata = sessionMeta(id: "current", timestamp: "2026-01-15T00:00:00.000Z")
        let firstUsage = totalOnlyTokenCount(
            timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000)
        let finalUsage = totalOnlyTokenCount(
            timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 30_000)
        try write(file, [metadata, firstUsage, finalUsage])
        try FileManager.default.createSymbolicLink(
            at: committedAliasRoot,
            withDestinationURL: home)

        let committedSnapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(committedSnapshot.scanIncomplete)
        XCTAssertEqual(
            committedSnapshot.daily.first { $0.date == day }?.totalTokens,
            30_000)
        let committedBefore = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(countedTokens(committedBefore.days, day: day), 30_000)
        XCTAssertEqual(
            countedTokens(try XCTUnwrap(committedBefore.files[file.path]).days, day: day),
            30_000)

        let bounded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(bounded.scanIncomplete)

        var journal = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNotNil(journal.codexPendingScanGeneration)
        let frozen = try XCTUnwrap(journal.codexPendingFileManifest?[file.path])
        var partialFile = try XCTUnwrap(journal.codexPendingFiles?[file.path])
        let committedAliasPath = committedAliasFile.path
        XCTAssertNotEqual(committedAliasPath, file.path)
        let committedFile = try XCTUnwrap(journal.files.removeValue(forKey: file.path))
        journal.files[committedAliasPath] = committedFile
        let partialDays = [day: ["gpt-5": [10_000, 0, 0]]]
        let partialTotals = CostUsageCodexTotals(input: 10_000, cached: 0, output: 0)
        let partialBoundary = Int64((metadata + "\n" + firstUsage + "\n").utf8.count)
        XCTAssertLessThan(partialBoundary, frozen.targetEOF)
        partialFile.days = partialDays
        partialFile.parsedBytes = partialBoundary
        partialFile.lastTotals = partialTotals
        partialFile.lastCountedTotals = partialTotals
        partialFile.lastRawTotalsBaseline = partialTotals
        partialFile.codexScanComplete = false
        partialFile.codexParseResumeState?.lastCountedTotals = partialTotals
        partialFile.codexParseResumeState?.lastRawTotalsBaseline = partialTotals
        journal.codexPendingFiles = [file.path: partialFile]
        journal.codexPendingDays = partialDays
        XCTAssertTrue(CostUsageCacheIO.save(provider: .codex, cache: journal, cacheRoot: tmp))

        try FileManager.default.removeItem(at: file)
        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL))

        XCTAssertTrue(published.scanIncomplete)
        XCTAssertFalse(published.completedFiniteScanGeneration)
        XCTAssertEqual(published.daily.first { $0.date == day }?.totalTokens, 30_000)
        let preserved = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(countedTokens(preserved.days, day: day), 30_000)
        XCTAssertEqual(
            preserved.files[file.path].map { countedTokens($0.days, day: day) },
            30_000)
        XCTAssertNil(preserved.files[committedAliasPath])
        XCTAssertEqual(preserved.lastScanUnixMs, committedBefore.lastScanUnixMs)
        XCTAssertEqual(preserved.scanSinceKey, committedBefore.scanSinceKey)
        XCTAssertEqual(preserved.scanUntilKey, committedBefore.scanUntilKey)
        XCTAssertEqual(preserved.roots, committedBefore.roots)
        XCTAssertEqual(preserved.codexPricingKey, committedBefore.codexPricingKey)
        XCTAssertEqual(
            preserved.codexPriorityMetadataKey,
            committedBefore.codexPriorityMetadataKey)
        XCTAssertNotNil(preserved.codexPendingScanGeneration)
        XCTAssertNotNil(preserved.codexPendingFileManifest)
        XCTAssertEqual(preserved.codexPendingFiles?[file.path]?.codexScanComplete, false)
    }

    func testPendingEpisodeSurvivesMultipleMidnightsThenSeedsCatchUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-midnight-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        try write(
            home.appendingPathComponent("sessions/2026/01/15/rollout.jsonl"),
            [
                sessionMeta(id: "current", timestamp: "2026-01-15T00:00:00.000Z"),
                tokenCount(
                    timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 55_000,
                    lastTokens: 55_000),
            ])
        let firstNow = ISO8601DateFormatter().date(from: "2026-01-20T12:00:00Z")!
        let movedNow = ISO8601DateFormatter().date(from: "2026-01-25T12:00:00Z")!

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: firstNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(first.scanIncomplete)
        var originalPending = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        let originalGeneration = try XCTUnwrap(originalPending.codexPendingScanGeneration)
        let originalSince = try XCTUnwrap(originalPending.codexPendingScanSinceKey)
        let originalUntil = try XCTUnwrap(originalPending.codexPendingScanUntilKey)
        originalPending.codexPendingFiles?["sentinel"] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [:],
            parsedBytes: 1,
            sessionId: "sentinel",
            codexScanComplete: true,
            codexScanGeneration: originalGeneration)
        CostUsageCacheIO.save(provider: .codex, cache: originalPending, cacheRoot: tmp)

        let stillPending = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: movedNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(stillPending.scanIncomplete)
        let afterMidnights = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(afterMidnights.codexPendingScanGeneration, originalGeneration)
        XCTAssertEqual(afterMidnights.codexPendingScanSinceKey, originalSince)
        XCTAssertEqual(afterMidnights.codexPendingScanUntilKey, originalUntil)
        XCTAssertNotNil(afterMidnights.codexPendingFiles?["sentinel"])

        let catchUpSeed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: movedNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertTrue(catchUpSeed.scanIncomplete)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(catchUp.codexPendingScanGeneration, originalGeneration)
        XCTAssertEqual(catchUp.scanUntilKey, originalUntil)
        XCTAssertGreaterThan(catchUp.codexPendingScanUntilKey ?? "", originalUntil)
        XCTAssertFalse(catchUp.files.isEmpty)
        XCTAssertNil(catchUp.codexPendingFiles?.values.first?.codexScanGeneration)

        let completed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: movedNow,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 120,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(completed.scanIncomplete)
        XCTAssertEqual(completed.daily.first { $0.date == "2026-01-15" }?.totalTokens, 55_000)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNil(finalized.codexPendingScanGeneration)
        XCTAssertNil(finalized.codexPendingScanSinceKey)
        XCTAssertNil(finalized.codexPendingScanUntilKey)
    }

    func testGenerationChangeDiscardsStaleContinuation() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-stale-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        try write(
            home.appendingPathComponent("sessions/2026/01/15/rollout.jsonl"),
            [sessionMeta(id: "current", timestamp: "2026-01-15T00:00:00.000Z")])
        var cache = CostUsageCache()
        cache.codexPendingScanGeneration = "stale-generation"
        cache.codexPendingScanSinceKey = "2025-11-30"
        cache.codexPendingScanUntilKey = "2025-12-02"
        cache.codexPendingDays = ["2025-12-01": ["gpt-5": [999, 0, 0]]]
        cache.codexPendingFiles = [
            "stale.jsonl": CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 10,
                days: cache.codexPendingDays ?? [:],
                parsedBytes: 10,
                sessionId: "stale",
                codexScanComplete: false,
                codexScanGeneration: "stale-generation"),
        ]
        cache.codexPendingParentScans = [
            "stale-parent": CodexParentSnapshotJournal(
                generation: "stale-generation",
                sessionId: "stale-parent",
                fileId: "1:1",
                mtimeUnixMs: 1,
                size: 10,
                parsedBytes: 5,
                previousTotals: nil,
                rawTotalsBaseline: nil,
                hasDivergentTotals: false,
                cutoffTimestamp: "2025-12-01T00:00:00.000Z",
                cutoffTotals: nil,
                snapshots: [],
                scanComplete: false),
        ]
        cache.codexPendingParentDiscoveries = [
            "stale-parent": CodexParentDiscoveryJournal(
                generation: "stale-generation",
                rootIndex: 0,
                directoryStack: [.init(relativePath: "2025/12", lastEntryName: nil)],
                resolvedRootIndex: nil,
                resolvedRelativePath: nil),
        ]
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: tmp)

        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        let refreshed = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNotEqual(refreshed.codexPendingScanGeneration, "stale-generation")
        XCTAssertNil(refreshed.codexPendingFiles?["stale.jsonl"])
        XCTAssertNil(refreshed.codexPendingDays?["2025-12-01"])
        XCTAssertNil(refreshed.codexPendingParentScans?["stale-parent"])
        XCTAssertNil(refreshed.codexPendingParentDiscoveries?["stale-parent"])
    }

    func testTrailingPartialAppendAtFrozenEOFDoesNotSeedCatchUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-trailing-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let file = home.appendingPathComponent("sessions/2026/01/15/a.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        try write(file, [
            sessionMeta(id: "A", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000),
        ])

        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(seeded.scanIncomplete)
        let frozen = try XCTUnwrap(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
                .codexPendingFileManifest?[file.path])

        try appendRaw(file, #"{"timestamp":"2026-01-15T00:00:02.000Z","type":"event_msg""#)
        let recaptured = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: file))
        XCTAssertEqual(recaptured.targetEOF, frozen.targetEOF)
        XCTAssertGreaterThan(recaptured.observedSize, frozen.observedSize)

        let resumed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(resumed.scanIncomplete)
        XCTAssertFalse(resumed.completedFiniteScanGeneration)
        XCTAssertEqual(resumed.daily.first { $0.date == "2026-01-15" }?.totalTokens, 10_000)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNil(finalized.codexPendingScanGeneration)
        XCTAssertNil(finalized.codexPendingFileManifest)
        XCTAssertEqual(countedTokens(finalized.days, day: "2026-01-15"), 10_000)
    }

    func testCompleteAppendSeedsCatchUpAndPreservesCompletionReceipt() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-complete-append-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let file = home.appendingPathComponent("sessions/2026/01/15/a.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        try write(file, [
            sessionMeta(id: "A", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 10_000),
        ])

        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp, maxScanWallClock: 0))
        XCTAssertTrue(seeded.scanIncomplete)
        try append(file, [
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:02.000Z", totalTokens: 20_000),
        ])

        let completedFiniteGeneration = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertTrue(completedFiniteGeneration.scanIncomplete)
        XCTAssertTrue(completedFiniteGeneration.completedFiniteScanGeneration)
        XCTAssertEqual(
            completedFiniteGeneration.daily.first { $0.date == "2026-01-15" }?.totalTokens,
            10_000)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNotNil(catchUp.codexPendingScanGeneration)
        XCTAssertNotNil(catchUp.codexPendingFileManifest?[file.path])

        let finalizedSnapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(finalizedSnapshot.scanIncomplete)
        XCTAssertFalse(finalizedSnapshot.completedFiniteScanGeneration)
        XCTAssertEqual(finalizedSnapshot.daily.first { $0.date == "2026-01-15" }?.totalTokens, 20_000)
        let finalized = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertNil(finalized.codexPendingScanGeneration)
        XCTAssertNil(finalized.codexPendingFileManifest)
    }

    func testMergedDailyReportPreservesCompletedFiniteScanGeneration() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-01-15",
            inputTokens: 1,
            outputTokens: 0,
            totalTokens: 1,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let nonEmpty = CostUsageDailyReport(
            data: [entry], summary: nil, completedFiniteScanGeneration: true)
        let empty = CostUsageDailyReport(
            data: [],
            summary: nil,
            scanIncomplete: true,
            completedFiniteScanGeneration: true)

        XCTAssertTrue(CostUsageDailyReport.merged([nonEmpty]).completedFiniteScanGeneration)
        let mergedEmpty = CostUsageDailyReport.merged([empty])
        XCTAssertTrue(mergedEmpty.completedFiniteScanGeneration)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: mergedEmpty,
            now: Date(timeIntervalSince1970: 0),
            historyDays: 30)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertTrue(snapshot.scanIncomplete)
        XCTAssertTrue(snapshot.completedFiniteScanGeneration)
    }

    func testV12SplitPendingCacheWithoutManifestPreservesCommittedCacheAndDiscardsPendingJournal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-v12-split-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(
            CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: tmp).lastPathComponent,
            "codex-v12.json")

        let committedDays = ["2026-01-10": ["gpt-5": [777, 0, 0]]]
        let pendingDays = ["2026-01-15": ["gpt-5": [123, 0, 0]]]
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 456
        cache.scanSinceKey = "2026-01-01"
        cache.scanUntilKey = "2026-01-31"
        cache.days = committedDays
        cache.files["committed.jsonl"] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 11,
            size: 22,
            days: committedDays,
            parsedBytes: 22,
            sessionId: "committed")
        cache.codexPendingScanGeneration = "v12-pending-generation"
        cache.codexPendingScanSinceKey = "2026-01-15"
        cache.codexPendingScanUntilKey = "2026-01-20"
        cache.codexPendingFiles = [
            "pending.jsonl": CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 33,
                size: 44,
                days: pendingDays,
                parsedBytes: 5,
                sessionId: "pending",
                codexScanComplete: false,
                codexScanGeneration: "v12-pending-generation"),
        ]
        cache.codexPendingDays = pendingDays
        cache.codexPendingParentScans = [
            "pending-parent": CodexParentSnapshotJournal(
                generation: "v12-pending-generation",
                sessionId: "pending-parent",
                fileId: "1:1",
                mtimeUnixMs: 1,
                size: 44,
                parsedBytes: 5,
                previousTotals: nil,
                rawTotalsBaseline: nil,
                hasDivergentTotals: false,
                cutoffTimestamp: "2026-01-15T00:00:00.000Z",
                cutoffTotals: nil,
                snapshots: nil,
                scanComplete: false),
        ]
        cache.codexPendingParentDiscoveries = [
            "pending-parent": CodexParentDiscoveryJournal(
                generation: "v12-pending-generation",
                rootIndex: 0,
                directoryStack: [.init(relativePath: "2026/01", lastEntryName: "a")],
                resolvedRootIndex: nil,
                resolvedRelativePath: nil),
        ]
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: tmp)

        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(migrated.lastScanUnixMs, 456)
        XCTAssertEqual(migrated.scanSinceKey, "2026-01-01")
        XCTAssertEqual(migrated.scanUntilKey, "2026-01-31")
        XCTAssertEqual(migrated.days, committedDays)
        let committed = try XCTUnwrap(migrated.files["committed.jsonl"])
        XCTAssertEqual(committed.mtimeUnixMs, 11)
        XCTAssertEqual(committed.size, 22)
        XCTAssertEqual(committed.parsedBytes, 22)
        XCTAssertEqual(committed.days, committedDays)
        XCTAssertNil(migrated.codexPendingScanGeneration)
        XCTAssertNil(migrated.codexPendingScanSinceKey)
        XCTAssertNil(migrated.codexPendingScanUntilKey)
        XCTAssertNil(migrated.codexPendingFileManifest)
        XCTAssertNil(migrated.codexPendingFiles)
        XCTAssertNil(migrated.codexPendingDays)
        XCTAssertNil(migrated.codexPendingParentScans)
        XCTAssertNil(migrated.codexPendingParentDiscoveries)
        let status = await CostUsageFetcher(cacheRoot: tmp).loadCodexPendingScanStatus()
        XCTAssertNil(status)
    }

    func testCacheSaveReturnsFalseWhenCacheRootIsARegularFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-cache-save-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cacheRoot = tmp.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("regular file".utf8).write(to: cacheRoot)

        let artifact = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
        XCTAssertFalse(CostUsageCacheIO.save(
            provider: .codex,
            cache: CostUsageCache(),
            cacheRoot: cacheRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testV12SplitPendingManifestWithoutFingerprintPreservesCommittedCacheAndDiscardsJournal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-v12-missing-fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let committedDays = ["2026-01-10": ["gpt-5": [777, 0, 0]]]
        let pendingDays = ["2026-01-15": ["gpt-5": [123, 0, 0]]]
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 456
        cache.scanSinceKey = "2026-01-01"
        cache.scanUntilKey = "2026-01-31"
        cache.days = committedDays
        cache.files["committed.jsonl"] = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 11,
            size: 22,
            days: committedDays,
            parsedBytes: 22,
            sessionId: "committed")
        cache.codexPendingScanGeneration = "v12-pending-generation"
        cache.codexPendingScanSinceKey = "2026-01-15"
        cache.codexPendingScanUntilKey = "2026-01-20"
        cache.codexPendingFileManifest = [
            "pending.jsonl": CodexFrozenFile(
                fileId: "1:1",
                mtimeUnixMs: 33,
                observedSize: 44,
                targetEOF: 44,
                contentFingerprint: nil),
        ]
        cache.codexPendingFiles = [
            "pending.jsonl": CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 33,
                size: 44,
                days: pendingDays,
                parsedBytes: 5,
                sessionId: "pending",
                codexScanComplete: false,
                codexScanGeneration: "v12-pending-generation"),
        ]
        cache.codexPendingDays = pendingDays
        cache.codexPendingParentScans = [
            "pending-parent": CodexParentSnapshotJournal(
                generation: "v12-pending-generation",
                sessionId: "pending-parent",
                fileId: "1:1",
                mtimeUnixMs: 33,
                size: 44,
                parsedBytes: 5,
                previousTotals: nil,
                rawTotalsBaseline: nil,
                hasDivergentTotals: false,
                cutoffTimestamp: "2026-01-15T00:00:00.000Z",
                cutoffTotals: nil,
                snapshots: nil,
                scanComplete: false),
        ]
        cache.codexPendingParentDiscoveries = [
            "pending-parent": CodexParentDiscoveryJournal(
                generation: "v12-pending-generation",
                rootIndex: 0,
                directoryStack: [.init(relativePath: "2026/01", lastEntryName: "a")],
                resolvedRootIndex: nil,
                resolvedRelativePath: nil),
        ]
        XCTAssertTrue(CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: tmp))

        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(migrated.lastScanUnixMs, 456)
        XCTAssertEqual(migrated.scanSinceKey, "2026-01-01")
        XCTAssertEqual(migrated.scanUntilKey, "2026-01-31")
        XCTAssertEqual(migrated.days, committedDays)
        let committed = try XCTUnwrap(migrated.files["committed.jsonl"])
        XCTAssertEqual(committed.mtimeUnixMs, 11)
        XCTAssertEqual(committed.size, 22)
        XCTAssertEqual(committed.parsedBytes, 22)
        XCTAssertEqual(committed.days, committedDays)
        XCTAssertNil(migrated.codexPendingScanGeneration)
        XCTAssertNil(migrated.codexPendingScanSinceKey)
        XCTAssertNil(migrated.codexPendingScanUntilKey)
        XCTAssertNil(migrated.codexPendingFileManifest)
        XCTAssertNil(migrated.codexPendingFiles)
        XCTAssertNil(migrated.codexPendingDays)
        XCTAssertNil(migrated.codexPendingParentScans)
        XCTAssertNil(migrated.codexPendingParentDiscoveries)
    }

    func testFrozenFileFingerprintRejectsSameInodeRewriteAndRegrow() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-fingerprint-regrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("rollout.jsonl")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data((String(repeating: "A", count: 64 * 1024) + "\n").utf8).write(to: file)
        let frozen = try XCTUnwrap(CostUsageScanner.codexFrozenFile(fileURL: file))
        XCTAssertNotNil(frozen.contentFingerprint)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data((String(repeating: "B", count: 96 * 1024) + "\n").utf8))
        try handle.close()

        let current = CostUsageScanner.codexFileMetadata(fileURL: file)
        XCTAssertEqual(current.fileId, frozen.fileId)
        XCTAssertGreaterThan(current.size, frozen.observedSize)
        XCTAssertFalse(CostUsageScanner.codexFrozenFileIsReadable(
            frozen,
            current: current,
            fileURL: file))
    }

    func testCodexScannerDoesNotFollowJsonlSymlinkTargets() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-symlink-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let target = tmp.appendingPathComponent("outside-target.jsonl")
        let link = home.appendingPathComponent("sessions/2026/01/15/link.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        try write(target, [
            sessionMeta(id: "outside", timestamp: "2026-01-15T00:00:00.000Z"),
            totalOnlyTokenCount(timestamp: "2026-01-15T00:00:01.000Z", totalTokens: 99_999),
        ])
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(cacheRoot: tmp))
        XCTAssertFalse(snapshot.scanIncomplete)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertNil(snapshot.sessionTokens)
        XCTAssertNil(snapshot.last30DaysTokens)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertTrue(cache.files.isEmpty)
        XCTAssertNil(cache.codexPendingScanGeneration)
    }

    func testLargePartialLogicalLineResumesFromItsStartWithoutCountingSuffix() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-codex-large-partial-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        seedFreshModelsDevPricingCache(at: tmp)
        let home = tmp.appendingPathComponent("home")
        let file = home.appendingPathComponent("sessions/2026/01/15/rollout.jsonl")
        let traceDatabaseURL = tmp.appendingPathComponent("missing-codex-trace.sqlite")
        let now = ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z")!
        let metadata = sessionMeta(id: "large", timestamp: "2026-01-15T00:00:00.000Z")
        let partialPrefix = #"{"timestamp":"2026-01-15T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":0,"total_tokens":999},"last_token_usage":{"input_tokens":999,"cached_input_tokens":0,"output_tokens":0,"total_tokens":999}},"padding":""#
            + String(repeating: "x", count: 512 * 1024 + 1)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((metadata + "\n" + partialPrefix).utf8).write(to: file)
        let firstBoundary = Int64(metadata.utf8.count + 1)

        let seeded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL,
                maxScanWallClock: 0))
        XCTAssertTrue(seeded.scanIncomplete)
        let firstTarget = try XCTUnwrap(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
                .codexPendingFileManifest?[file.path])
        XCTAssertEqual(firstTarget.targetEOF, firstBoundary)
        XCTAssertGreaterThan(firstTarget.observedSize, firstBoundary)

        try appendRaw(file, "\"}}\n")
        let expandedMetadata = CostUsageScanner.codexFileMetadata(fileURL: file)
        XCTAssertGreaterThan(expandedMetadata.size, firstTarget.targetEOF)
        let published = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertTrue(published.scanIncomplete)
        XCTAssertTrue(published.completedFiniteScanGeneration)
        XCTAssertTrue(published.daily.isEmpty)
        let catchUp = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        let catchUpTarget = try XCTUnwrap(catchUp.codexPendingFileManifest?[file.path])
        XCTAssertEqual(catchUpTarget.targetEOF, expandedMetadata.size)
        XCTAssertEqual(catchUp.codexPendingFiles?[file.path]?.parsedBytes, firstBoundary)

        let finalized = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: home.path,
            historyDays: 30,
            refreshPricingInBackground: false,
            scannerOptions: .init(
                cacheRoot: tmp,
                codexTraceDatabaseURL: traceDatabaseURL))
        XCTAssertFalse(finalized.scanIncomplete)
        XCTAssertFalse(finalized.completedFiniteScanGeneration)
        XCTAssertTrue(finalized.daily.isEmpty)
        XCTAssertNil(finalized.last30DaysTokens)
        let completedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: tmp)
        XCTAssertEqual(completedCache.files[file.path]?.parsedBytes, catchUpTarget.targetEOF)
        XCTAssertEqual(completedCache.files[file.path]?.codexScanComplete, true)
        XCTAssertNil(completedCache.codexPendingScanGeneration)
    }

    func testMergedDailyReportPreservesIncompleteScan() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-01-15",
            inputTokens: 1,
            outputTokens: 0,
            totalTokens: 1,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let complete = CostUsageDailyReport(data: [entry], summary: nil)
        let incomplete = CostUsageDailyReport(data: [entry], summary: nil, scanIncomplete: true)

        XCTAssertTrue(CostUsageDailyReport.merged([complete, incomplete]).scanIncomplete)
    }
}
