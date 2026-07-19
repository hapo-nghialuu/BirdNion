import XCTest
@testable import BirdNion

/// Native Claude provider tests — planner logic, OAuth usage mapping, Admin API
/// parsing, and cost-scan dedup. All pure / fixture-driven (no network, no real
/// Keychain or browser cookies), mirroring the CodexBar tests we ported from.
final class ClaudeNativeTests: XCTestCase {

    // MARK: - Source planner

    func testAutoPlanOrderAndAvailability() {
        let input = ClaudeSourcePlanningInput(
            selectedDataSource: .auto, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: false, hasOAuthCredentials: true)
        let plan = ClaudeSourcePlanner.resolve(input: input)
        // App-auto order is always OAuth → CLI → Web.
        XCTAssertEqual(plan.orderedSteps.map(\.dataSource), [.oauth, .cli, .web])
        // Only OAuth is available → it's the single execution step.
        XCTAssertEqual(plan.executionSteps.map(\.dataSource), [.oauth])
        XCTAssertEqual(plan.preferredStep?.dataSource, .oauth)
        XCTAssertFalse(plan.isNoSourceAvailable)
    }

    func testExplicitSourceIgnoresAvailability() {
        let input = ClaudeSourcePlanningInput(
            selectedDataSource: .web, webExtrasEnabled: false,
            hasWebSession: false, hasCLI: false, hasOAuthCredentials: false)
        let plan = ClaudeSourcePlanner.resolve(input: input)
        // Explicit selection runs even when "unavailable" so the user sees the
        // real error instead of a silent skip.
        XCTAssertEqual(plan.executionSteps.map(\.dataSource), [.web])
    }

    // MARK: - OAuth usage mapping

    func testMapOAuthUsageWindowsCostRoutines() throws {
        let json = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-06-28T00:00:00Z"},
         "seven_day":{"utilization":10.0},
         "seven_day_opus":{"utilization":5.0},
         "seven_day_sonnet":{"utilization":7.0},
         "seven_day_routines":{"utilization":20.0},
         "extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":500,"currency":"USD"}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let creds = ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(usage, credentials: creds)

        XCTAssertEqual(snap.primary?.usedPercent, 42.0)
        XCTAssertEqual(snap.secondary?.usedPercent, 10.0)
        XCTAssertEqual(snap.opus?.usedPercent, 5.0)
        // extra_usage is in cents → dollars.
        XCTAssertEqual(snap.providerCost?.used, 5.0)
        XCTAssertEqual(snap.providerCost?.limit, 20.0)
        // Sonnet + Daily Routines surface as named extra windows.
        let titles = snap.extraRateWindows.map(\.title)
        XCTAssertTrue(titles.contains("Daily Routines"))
        XCTAssertTrue(titles.contains("Sonnet"))
    }

    func testMapOAuthSpendLimitWhenNoUsageWindows() throws {
        let json = """
        {"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":250,"currency":"USD"}}
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthUsageAPI.decode(json)
        let snap = ClaudeOAuthUsageAPI.mapOAuthUsage(
            usage, credentials: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil))
        XCTAssertEqual(snap.primaryWindowKind, .spendLimit)
        XCTAssertEqual(snap.providerCost?.used, 2.5)
        XCTAssertEqual(snap.providerCost?.limit, 10.0)
    }

    // MARK: - Admin API parsing

    func testAdminSnapshotRollup() throws {
        let costs = """
        {"data":[{"starting_at":"2026-06-01T00:00:00Z","ending_at":"2026-06-02T00:00:00Z",
          "results":[{"amount":"1234","description":"Claude API"}]}]}
        """.data(using: .utf8)!
        let messages = """
        {"data":[{"starting_at":"2026-06-01T00:00:00Z","ending_at":"2026-06-02T00:00:00Z",
          "results":[{"uncached_input_tokens":100,"cache_read_input_tokens":20,
                      "output_tokens":50,"model":"claude-opus-4"}]}]}
        """.data(using: .utf8)!
        let now = ISO8601DateFormatter().date(from: "2026-06-15T00:00:00Z")!
        let snap = try ClaudeAdminAPIUsageFetcher.parseSnapshotForTesting(
            costs: costs, messages: messages, now: now)
        XCTAssertEqual(snap.daily.count, 1)
        XCTAssertEqual(snap.last30Days.costUSD, 12.34, accuracy: 0.001)   // cents → dollars
        XCTAssertEqual(snap.last30Days.totalTokens, 170)
        XCTAssertEqual(snap.topModels.first?.name, "claude-opus-4")
    }

    // MARK: - Cost-scan dedup across roots

    func testCostScanDedupsSameMessageAcrossRoots() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root1 = base.appendingPathComponent("a/projects/enc")
        let root2 = base.appendingPathComponent("b/projects/enc")
        try fm.createDirectory(at: root1, withIntermediateDirectories: true)
        try fm.createDirectory(at: root2, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        // Same message (id+requestId) logged in both a parent and a subagent
        // file — must be counted ONCE, not twice.
        let line = """
        {"type":"assistant","timestamp":"\(ts)","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        try line.write(to: root1.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: root2.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)

        let report = ClaudeCostScanner.scanFull(
            roots: [base.appendingPathComponent("a/projects"),
                    base.appendingPathComponent("b/projects")],
            now: Date())
        XCTAssertEqual(report?.last30Tokens, 150)   // 100 + 50, deduped (not 300)
    }

    /// `scanDays` narrows both the entry cutoff and the daily bucket window;
    /// the default keeps the full 90-day behaviour.
    func testCostScanFullScanDaysNarrowsWindow() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("projects/enc")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-2 * 86_400))
        let old = iso.string(from: now.addingTimeInterval(-10 * 86_400))
        let lines = """
        {"type":"assistant","timestamp":"\(recent)","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","timestamp":"\(old)","requestId":"r2",\
        "message":{"id":"m2","model":"claude-sonnet","usage":{"input_tokens":200,"output_tokens":100}}}
        """
        try lines.write(to: root.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)
        let roots = [base.appendingPathComponent("projects")]

        // Narrow scan: only the 2-day-old entry is inside the 7-day cutoff.
        let narrow = ClaudeCostScanner.scanFull(roots: roots, now: now, scanDays: 7)
        XCTAssertEqual(narrow?.daily.count, 7)
        XCTAssertEqual(narrow?.daily.map(\.tokens).reduce(0, +), 150)

        // Default window still counts both entries.
        let full = ClaudeCostScanner.scanFull(roots: roots, now: now)
        XCTAssertEqual(full?.daily.count, 90)
        XCTAssertEqual(full?.daily.map(\.tokens).reduce(0, +), 450)
    }

    func testHapoModelPricesAndPricingRevision() throws {
        let luna = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-luna"))
        XCTAssertEqual(luna.inputPerM, 1.0, accuracy: 0.0001)
        XCTAssertEqual(luna.cacheReadPerM, 0.10, accuracy: 0.0001)
        XCTAssertEqual(luna.outputPerM, 6.0, accuracy: 0.0001)
        let longLuna = try XCTUnwrap(ClaudeModelPrice.price(
            for: "openai.gpt-5.6-luna", inputSideTokens: 272_001))
        XCTAssertEqual(longLuna.inputPerM, 2.0, accuracy: 0.0001)
        XCTAssertEqual(longLuna.outputPerM, 9.0, accuracy: 0.0001)

        let terra = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-terra"))
        XCTAssertEqual(terra.inputPerM, 2.5, accuracy: 0.0001)
        XCTAssertEqual(terra.outputPerM, 15.0, accuracy: 0.0001)
        let sol = try XCTUnwrap(ClaudeModelPrice.price(for: "openai.gpt-5.6-sol"))
        XCTAssertEqual(sol.inputPerM, 5.0, accuracy: 0.0001)
        XCTAssertEqual(sol.outputPerM, 30.0, accuracy: 0.0001)

        let m25 = try XCTUnwrap(ClaudeModelPrice.price(for: "minimax.minimax-m2.5"))
        XCTAssertEqual(m25.inputPerM, 0.30, accuracy: 0.0001)
        XCTAssertEqual(m25.cacheWritePerM, 0.375, accuracy: 0.0001)
        XCTAssertEqual(m25.cacheReadPerM, 0.03, accuracy: 0.0001)
        XCTAssertEqual(m25.outputPerM, 1.20, accuracy: 0.0001)
        XCTAssertNotNil(ClaudeModelPrice.price(for: "minimax-m2.5-ultra-5"))
        XCTAssertNil(ClaudeModelPrice.price(for: "gpt-5.6-luna"))
        XCTAssertNil(ClaudeModelPrice.price(for: "openai.gpt-5.60-luna"))

        XCTAssertEqual(ClaudeCostScanner.scanDaysForHistory(
            storedPricingRevision: 0, incrementalDays: 7), ClaudeCostScanner.historyDays)
        XCTAssertEqual(ClaudeCostScanner.scanDaysForHistory(
            storedPricingRevision: ClaudeCostScanner.pricingRevision, incrementalDays: 7), 7)
    }
}
