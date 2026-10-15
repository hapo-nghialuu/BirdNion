import XCTest
@testable import BirdNion

@MainActor
final class HookTests: XCTestCase {

    // MARK: - HookRule.matches

    private func event(_ type: HookEventType = .usageUpdated,
                       provider: String = "codex",
                       usage: Double? = nil) -> HookEvent {
        HookEvent(event: type, provider: provider, usagePercent: usage)
    }

    private func rule(_ type: HookEventType = .usageUpdated,
                      provider: String? = nil,
                      threshold: Double? = nil,
                      executable: String = "/usr/bin/true") -> HookRule {
        HookRule(event: type, provider: provider, threshold: threshold,
                 executable: executable)
    }

    func testMatchesDisabledRuleNeverRuns() {
        var r = rule()
        r.enabled = false
        XCTAssertFalse(r.matches(event()))
    }

    func testMatchesRequiresAbsoluteExecutablePath() {
        XCTAssertFalse(rule(executable: "true").matches(event()))
        XCTAssertTrue(rule(executable: "/usr/bin/true").matches(event()))
    }

    func testMatchesProviderFilter() {
        XCTAssertTrue(rule(provider: "codex").matches(event(provider: "codex")))
        XCTAssertFalse(rule(provider: "claude").matches(event(provider: "codex")))
    }

    func testQuotaLowThresholdGate() {
        let r = rule(.quotaLow, threshold: 0.9)
        XCTAssertFalse(r.matches(event(.quotaLow, usage: 0.8)))
        XCTAssertTrue(r.matches(event(.quotaLow, usage: 0.95)))
    }

    func testInvalidThresholdNeverMatches() {
        XCTAssertFalse(rule(.quotaLow, threshold: 1.5).matches(event(.quotaLow, usage: 0.99)))
        XCTAssertFalse(rule(.quotaLow, threshold: 0).matches(event(.quotaLow, usage: 0.99)))
    }

    // MARK: - QuotaLowHookThreshold

    func testCrossedRulesUsesRuleThresholdOrFallback() {
        let explicit = rule(.quotaLow, threshold: 0.5)
        let implicit = rule(.quotaLow, threshold: nil)
        let crossed = QuotaLowHookThreshold.crossedRules(
            [explicit, implicit], previousUsage: 0.4, currentUsage: 0.6,
            fallbackThresholds: [0.9])
        // Explicit 0.5 crossed; implicit watches fallback 0.9 — not crossed.
        XCTAssertEqual(crossed.map(\.id), [explicit.id])
    }

    // MARK: - HookEvent payload

    func testEnvironmentVariablesOmitNilFields() {
        let e = HookEvent(
            event: .quotaLow, provider: "devin", window: "Ngày",
            usagePercent: 0.92, windowMinutes: 1440,
            used: 4.6, limit: 5, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
        let env = e.environmentVariables()
        XCTAssertEqual(env["BIRDNION_EVENT"], "quota_low")
        XCTAssertEqual(env["BIRDNION_PROVIDER"], "devin")
        XCTAssertEqual(env["BIRDNION_USAGE_PERCENT"], "0.92")
        XCTAssertEqual(env["BIRDNION_USED"], "4.6")
        XCTAssertEqual(env["BIRDNION_LIMIT"], "5")
        XCTAssertNil(env["BIRDNION_ACCOUNT"])
        XCTAssertNil(env["BIRDNION_STATUS"])
    }

    func testJsonPayloadRoundTrips() throws {
        let e = event(.quotaReset, provider: "claude")
        let data = try e.jsonPayload()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HookEvent.self, from: data)
        XCTAssertEqual(decoded.event, .quotaReset)
        XCTAssertEqual(decoded.provider, "claude")
    }

    // MARK: - HooksConfig

    func testConfigRoundTripPreservesRules() throws {
        let config = HooksConfig(enabled: true, events: [
            rule(.quotaLow, provider: "devin", threshold: 0.8),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HooksConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDisabledConfigMatchesNothing() {
        let config = HooksConfig(enabled: false, events: [rule()])
        XCTAssertTrue(config.matchingRules(for: event()).isEmpty)
    }

    // MARK: - HookEngine transitions

    private func status(id: String = "codex", usedPct: Int,
                        resetAt: Date? = nil, error: String? = nil) -> ProviderStatus {
        ProviderStatus(
            id: id, displayName: id,
            windows: [QuotaWindow(
                label: "5 giờ", usedPct: usedPct, remainingPct: 100 - usedPct,
                resetDate: resetAt, windowSeconds: 18_000)],
            lastUpdated: Date(), error: error)
    }

    func testFirstPublishEmitsUsageUpdatedOnly() {
        var captured: [HookEvent] = []
        let config = HooksConfig(enabled: true, events: [rule(.usageUpdated), rule(.quotaLow)])
        let engine = HookEngine(configProvider: { config }) { _, _ in [] }
        engine.onEmit = { captured.append($0) }
        engine.observe(status(usedPct: 50))
        engine.observe(status(usedPct: 55))
        XCTAssertEqual(captured.map(\.event), [.usageUpdated, .usageUpdated])
    }

    func testQuotaLowFiresOnWarnThresholdCrossing() {
        var captured: [HookEvent] = []
        let config = HooksConfig(enabled: true, events: [rule(.quotaLow)])
        let engine = HookEngine(configProvider: { config }) { _, _ in [20] }
        engine.onEmit = { captured.append($0) }
        engine.observe(status(usedPct: 50))   // remaining 50 > warn threshold 20
        engine.observe(status(usedPct: 85))   // remaining 15 crossed 20
        let types = captured.map(\.event)
        XCTAssertTrue(types.contains(.quotaLow))
        // usage 0.85 ≥ watched 0.8 (1 − 20/100)
        XCTAssertEqual(captured.first { $0.event == .quotaLow }?.usagePercent, 0.85)
    }

    func testQuotaReachedFiresAtFullDepletion() {
        var captured: [HookEvent] = []
        let config = HooksConfig(enabled: true, events: [rule(.quotaReached)])
        let engine = HookEngine(configProvider: { config }) { _, _ in [] }
        engine.onEmit = { captured.append($0) }
        engine.observe(status(usedPct: 90))
        engine.observe(status(usedPct: 100))
        XCTAssertTrue(captured.contains { $0.event == .quotaReached })
    }

    func testQuotaResetFiresWhenResetRollsForward() {
        var captured: [HookEvent] = []
        let config = HooksConfig(enabled: true, events: [rule(.quotaReset)])
        let engine = HookEngine(configProvider: { config }) { _, _ in [] }
        engine.onEmit = { captured.append($0) }
        let past = Date().addingTimeInterval(-60)
        let future = Date().addingTimeInterval(18_000)
        engine.observe(status(usedPct: 80, resetAt: past))
        engine.observe(status(usedPct: 5, resetAt: future))
        XCTAssertTrue(captured.contains { $0.event == .quotaReset })
    }

    func testRefreshFailedThenRecovered() {
        var captured: [HookEvent] = []
        let config = HooksConfig(enabled: true, events: [
            rule(.refreshFailed), rule(.providerRecovered)])
        let engine = HookEngine(configProvider: { config }) { _, _ in [] }
        engine.onEmit = { captured.append($0) }
        engine.observe(status(usedPct: 0, error: "boom"))
        engine.observe(status(usedPct: 50))
        XCTAssertEqual(captured.map(\.event), [.refreshFailed, .providerRecovered, .usageUpdated])
    }

    func testDisabledConfigEmitsNothing() {
        var captured: [HookEvent] = []
        let engine = HookEngine(configProvider: { HooksConfig() }) { _, _ in [] }
        engine.onEmit = { captured.append($0) }
        engine.observe(status(usedPct: 50))
        XCTAssertTrue(captured.isEmpty)
    }
}
