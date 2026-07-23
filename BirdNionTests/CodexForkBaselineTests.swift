import CodexBarCore
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
    private func write(_ path: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func sessionMeta(id: String, sessionId: String? = nil, forkedFrom: String? = nil,
                             parentThread: String? = nil, timestamp: String) -> String {
        var payload = "\"session_id\":\"\(sessionId ?? id)\",\"id\":\"\(id)\",\"timestamp\":\"\(timestamp)\""
        if let forkedFrom { payload += ",\"forked_from_id\":\"\(forkedFrom)\"" }
        if let parentThread { payload += ",\"parent_thread_id\":\"\(parentThread)\"" }
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
                sessionMeta(id: "fork-session", forkedFrom: "root-session",
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
}
