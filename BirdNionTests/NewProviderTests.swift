import XCTest
@testable import BirdNion

/// Parser tests for the natively-authored new providers (fixture-driven, no
/// network). Cookie/OAuth/CLI providers expose their own `_parseForTesting`
/// hooks; these cover the three hand-written API-key parsers.
final class NewProviderTests: XCTestCase {

    func testElevenLabsParse() {
        let json = """
        {"tier":"creator","character_count":12000,"character_limit":100000,
         "voice_slots_used":3,"voice_limit":30,"next_character_count_reset_unix":1700000000}
        """.data(using: .utf8)!
        let s = ElevenLabsProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.first?.label, "Credits")
        XCTAssertEqual(s.windows.first?.usedPct, 12)   // 12000 / 100000
        XCTAssertEqual(s.planName, "Creator")
        XCTAssertTrue(s.windows.contains { $0.label == "Voice slots" })
    }

    func testCopilotParsePremiumAndPlaceholderSkip() {
        let json = """
        {"copilot_plan":"business","quota_reset_date":"2026-07-01",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"remaining":75,"percent_remaining":25},
           "chat":{"entitlement":0,"remaining":0,"percent_remaining":100}}}
        """.data(using: .utf8)!
        let s = CopilotProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.planName, "Business")
        // Premium: 25% remaining → 75% used. Chat is a zero-entitlement placeholder → skipped.
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows.first?.label, "Premium")
        XCTAssertEqual(s.windows.first?.usedPct, 75)
    }

    func testGroqParseScalarSumsSeries() {
        let json = """
        {"status":"success","data":{"result":[
          {"value":[1700000000,"1.5"]},
          {"value":[1700000000,2.5]}]}}
        """.data(using: .utf8)!
        XCTAssertEqual(GroqProvider.parseScalar(json), 4.0, accuracy: 0.001)
    }

    /// Grok CLI billing JSON → monthly used% + Monthly/Tuần label + $ subtitle.
    func testGrokBillingJSONMapsToProviderStatus() throws {
        let json = """
        {
          "billingCycle": {
            "billingPeriodStart": "2026-05-01T00:00:00Z",
            "billingPeriodEnd": "2026-06-01T00:00:00Z"
          },
          "monthlyLimit": { "val": 99900 },
          "onDemandCap": { "val": 0 },
          "on_demand_enabled": false,
          "disabledByConfig": false,
          "usage": {
            "includedUsed": { "val": 49950 },
            "onDemandUsed": { "val": 0 },
            "totalUsed": { "val": 49950 }
          }
        }
        """.data(using: .utf8)!
        let s = try GrokProvider._parseBillingJSONForTesting(
            json, email: "user@x.ai", loginMethod: "SuperGrok")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.id, "grok")
        XCTAssertEqual(s.accountLabel, "user@x.ai")
        XCTAssertEqual(s.planName, "SuperGrok")
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows.first?.usedPct, 50)
        XCTAssertEqual(s.windows.first?.remainingPct, 50)
        XCTAssertEqual(s.windows.first?.label, "Tháng")  // ~31d period → Monthly
        XCTAssertEqual(s.windows.first?.subtitle, "$499.50 / $999.00")
        XCTAssertEqual(s.windows.first?.windowSeconds, 31 * 24 * 60 * 60)
        XCTAssertNotNil(s.windows.first?.resetDate)
    }

    /// Grok web billing snapshot → used% + reset date (Credits / Tuần / Tháng).
    func testGrokWebBillingSnapshotMapsToProviderStatus() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let now = Date(timeIntervalSince1970: 1_799_000_000) // ~11.5 days before reset → Weekly
        let s = GrokProvider._mapWebBillingForTesting(
            usedPercent: 42.5,
            resetsAt: reset,
            email: "web@x.ai",
            now: now)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.accountLabel, "web@x.ai")
        XCTAssertEqual(s.windows.first?.usedPct, 43) // 42.5 rounded
        XCTAssertEqual(s.windows.first?.remainingPct, 57)
        XCTAssertEqual(s.windows.first?.resetDate, reset)
        XCTAssertEqual(s.windows.first?.label, "Tuần")
    }

    func testGrokLocalizeWindowLabel() {
        XCTAssertEqual(GrokProvider.localizeWindowLabel("Weekly"), "Tuần")
        XCTAssertEqual(GrokProvider.localizeWindowLabel("Monthly"), "Tháng")
        XCTAssertEqual(GrokProvider.localizeWindowLabel("Credits"), "Credits")
    }

    /// High-water merge: a lower live rescan (sessions deleted) must not
    /// erase a previously stored day; a higher live day must update the store.
    func testCostHistoryNeverShrinksDeletedSessions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // First scan: store yesterday + today.
        let w1 = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (yesterday, 10.0, 1000, [("claude-opus", 10.0, 1000)]),
                (today, 2.0, 200, [("claude-sonnet", 2.0, 200)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)
        XCTAssertEqual(w1.last?.tokens ?? -1, 200)
        XCTAssertEqual(w1[w1.count - 2].tokens, 1000)

        // User deletes sessions → live only has a smaller today, no yesterday.
        let w2 = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (today, 0.5, 50, [("claude-sonnet", 0.5, 50)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)
        // Yesterday preserved (high-water).
        XCTAssertEqual(w2[w2.count - 2].tokens, 1000)
        XCTAssertEqual(w2[w2.count - 2].usd, 10.0, accuracy: 0.001)
        // Today keeps the higher prior mark (200), not the shrunk live 50.
        XCTAssertEqual(w2.last?.tokens ?? -1, 200)

        // New usage today grows past the stored mark → update.
        let w3 = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (today, 5.0, 500, [("claude-sonnet", 5.0, 500)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)
        XCTAssertEqual(w3.last?.tokens ?? -1, 500)
        XCTAssertEqual(w3.last?.usd ?? -1, 5.0, accuracy: 0.001)
        // Yesterday still intact.
        XCTAssertEqual(w3[w3.count - 2].tokens, 1000)
    }

    func testCostHistoryPreferHigher() {
        let low = CostHistoryStore.Day(usd: 1, tokens: 10, models: [])
        let high = CostHistoryStore.Day(usd: 2, tokens: 20, models: [
            .init(name: "m", usd: 2, tokens: 20)
        ])
        XCTAssertEqual(CostHistoryStore.preferHigher(low, high).tokens, 20)
        XCTAssertEqual(CostHistoryStore.preferHigher(high, low).tokens, 20)
    }

    /// Read-only `window()` must return the same buckets `apply` produced,
    /// leave other sources zeroed, and never create a missing file.
    func testCostHistoryWindowReadOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let applied = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (yesterday, 10.0, 1000, [("claude-opus", 10.0, 1000)]),
                (today, 2.0, 200, [("claude-sonnet", 2.0, 200)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)

        let window = CostHistoryStore.window(
            source: .claude, now: now, calendar: cal, windowDays: 90, url: url)
        XCTAssertEqual(window, applied)

        // Other sources read as all-zero buckets.
        let codex = CostHistoryStore.window(
            source: .codex, now: now, calendar: cal, windowDays: 90, url: url)
        XCTAssertEqual(codex.count, 90)
        XCTAssertFalse(codex.contains { $0.tokens > 0 || $0.usd > 0 })

        // Missing file: zero window, and the read must not create the file.
        let missing = dir.appendingPathComponent("nope.json")
        let empty = CostHistoryStore.window(
            source: .claude, now: now, calendar: cal, windowDays: 90, url: missing)
        XCTAssertEqual(empty.count, 90)
        XCTAssertFalse(empty.contains { $0.tokens > 0 || $0.usd > 0 })
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
    }

    /// scanBackDays: no history → full window (first run); fresh history →
    /// min clamp; stale history → widen to cover the gap; ancient → cap.
    func testScanBackDaysStaleness() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        func store(latestDaysAgo: Int, url: URL) {
            let day = cal.date(byAdding: .day, value: -latestDaysAgo, to: today)!
            _ = CostHistoryStore.apply(
                source: .claude, liveDays: [(day, 1.0, 1, [])],
                now: now, calendar: cal, windowDays: 90, url: url)
        }

        // No file yet → full scan.
        let missing = dir.appendingPathComponent("missing.json")
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: missing), 90)

        let fresh = dir.appendingPathComponent("fresh.json")
        store(latestDaysAgo: 0, url: fresh)
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: fresh), 7)
        // Same file, source without history → still full scan.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .codex, now: now, calendar: cal, url: fresh), 90)

        let stale = dir.appendingPathComponent("stale.json")
        store(latestDaysAgo: 20, url: stale)
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: stale), 21)

        let ancient = dir.appendingPathComponent("ancient.json")
        store(latestDaysAgo: 200, url: ancient)
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: ancient), 90)
    }

    /// seededReport builds a chart-ready report straight from the persisted
    /// store (no log scan) and stays nil when the store has nothing.
    func testSeededReportFromHistoryAndEmpty() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        for source in CostHistoryStore.Source.allCases {
            _ = CostHistoryStore.apply(
                source: source,
                liveDays: [
                    (yesterday, 10.0, 1000, [("model-a", 10.0, 1000)]),
                    (today, 2.0, 200, [("model-b", 2.0, 200)]),
                ],
                now: now, calendar: cal, windowDays: 90, url: url)
        }

        let claude = await ClaudeCostScanner.seededReport(now: now, url: url)
        XCTAssertEqual(claude?.todayTokens, 200)
        XCTAssertEqual(claude?.last30Tokens, 1200)
        XCTAssertEqual(claude?.hourly.isEmpty, true)

        let codex = await CodexCostScanner.seededReport(now: now, url: url)
        XCTAssertEqual(codex?.todayTokens, 200)

        let grok = await GrokCostScanner.seededReport(now: now, url: url)
        XCTAssertEqual(grok?.todayTokens, 200)

        // Empty store → nil so the UI keeps its loading skeleton.
        let missing = dir.appendingPathComponent("nope.json")
        let empty = await ClaudeCostScanner.seededReport(now: now, url: missing)
        XCTAssertNil(empty)
    }

    func testOpenAIMapBalanceCredits() {
        // mapBalance is CodexBarCore-typed; exercise via a thin test helper.
        let s = OpenAIProvider._mapBalanceForTesting(
            granted: 100, used: 25, available: 75)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.id, "openai")
        XCTAssertEqual(s.windows.first?.label, "Credits")
        XCTAssertEqual(s.windows.first?.usedPct, 25)
        XCTAssertEqual(s.creditsRemaining ?? -1, 75, accuracy: 0.001)
    }

    func testOllamaParseSessionWeeklyHTML() throws {
        let html = """
        <div>Cloud Usage</div>
        <div>Session usage <span>42% used</span> data-time="2099-01-01T00:00:00Z"</div>
        <div>Weekly usage <span>10% used</span></div>
        """
        let s = try OllamaProvider._parseHTMLForTesting(html)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows.first { $0.label == "Session" }?.usedPct, 42)
        XCTAssertEqual(s.windows.first { $0.label == "Tuần" }?.usedPct, 10)
    }

    func testCostHistoryConcurrentSourcesDoNotOverwriteEachOther() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date()
        let sources = CostHistoryStore.Source.allCases

        for attempt in 0..<12 {
            let url = dir.appendingPathComponent("cost-history-\(attempt).json")
            await withTaskGroup(of: Void.self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        _ = CostHistoryStore.apply(
                            source: source,
                            liveDays: [(now, Double(index + 1), index + 1, [])],
                            now: now,
                            windowDays: 1,
                            url: url)
                    }
                }
            }

            let stored = Set((CostHistoryStore.read(url: url).sources ?? [:]).keys)
            XCTAssertEqual(stored, Set(sources.map(\.rawValue)))
        }
    }

    func testGrokBinaryAloneIsNotSignedIn() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertFalse(GrokProvider.isSignedIn(env: [
            "GROK_HOME": home.path,
            "GROK_CLI_PATH": "/usr/bin/false",
            "PATH": "/usr/bin",
        ]))
    }

    /// Grok 4.5 blended rate: 75% × $2 + 25% × $6 = $3 / M tokens.
    func testGrokModelPriceBlendedEstimate() {
        let usd = GrokModelPrice.estimateUSD(tokens: 1_000_000, model: "grok-4.5")
        XCTAssertEqual(usd, 3.0, accuracy: 0.001)
        let half = GrokModelPrice.estimateUSD(tokens: 500_000, model: "grok-4.5")
        XCTAssertEqual(half, 1.5, accuracy: 0.001)
        XCTAssertEqual(GrokModelPrice.estimateUSD(tokens: 0, model: "grok-4.5"), 0, accuracy: 0.001)
    }

    /// Session points fold into contiguous daily buckets + calendar-today totals.
    func testGrokCostScannerBuildReport() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let sessions: [GrokCostScanner.SessionPoint] = [
            .init(day: today, tokens: 100_000, usd: 0.30, model: "grok-4.5"),
            .init(day: today, tokens: 50_000, usd: 0.15, model: "grok-4.5"),
            .init(day: yesterday, tokens: 200_000, usd: 0.60, model: "grok-4.5"),
        ]
        let report = GrokCostScanner.buildReport(sessions: sessions, now: now, windowDays: 90, calendar: cal)
        XCTAssertEqual(report.daily.count, 90)
        XCTAssertEqual(report.todayTokens, 150_000)
        XCTAssertEqual(report.todayUSD, 0.45, accuracy: 0.001)
        XCTAssertEqual(report.last30Tokens, 350_000)
        XCTAssertEqual(report.last30USD, 1.05, accuracy: 0.001)
        XCTAssertEqual(report.topModel, "grok-4.5")
        let y = report.daily[report.daily.count - 2]
        XCTAssertEqual(y.tokens, 200_000)
        XCTAssertEqual(y.usd, 0.60, accuracy: 0.001)
    }

    /// Parse a signals.json fixture from a temp session directory.
    func testGrokCostScannerParseSignalsFixture() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent("sessions/proj/sess-1")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let signals = """
        {"totalTokensBeforeCompaction":0,"contextTokensUsed":1000000,\
        "modelsUsed":["grok-4.5"],"primaryModelId":"grok-4.5"}
        """
        try signals.write(to: session.appendingPathComponent("signals.json"),
                          atomically: true, encoding: .utf8)

        // Stamp last_active_at to "now" so calendar-today is unambiguous
        // across timezones (UTC ISO vs local startOfDay).
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = """
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))"}
        """
        try summary.write(to: session.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)

        let report = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(report.todayTokens, 1_000_000)
        XCTAssertEqual(report.todayUSD, 3.0, accuracy: 0.01) // 1M × $3 blended
        XCTAssertEqual(report.last30Tokens, 1_000_000)
        XCTAssertEqual(report.topModel, "grok-4.5")
    }

    // MARK: - Parity additions (Wave 2-3)

    func testElevenLabsProVoicesAndStatusSuffix() {
        let json = """
        {"tier":"pro","status":"canceled","character_count":0,"character_limit":100,
         "voice_slots_used":1,"voice_limit":10,
         "professional_voice_slots_used":2,"professional_voice_limit":5}
        """.data(using: .utf8)!
        let s = ElevenLabsProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.planName, "Pro · canceled")  // status != active → suffix
        XCTAssertTrue(s.windows.contains { $0.label == "Professional voices" && $0.usedPct == 40 })
    }

    func testDeepSeekGrantedBreakdownAndLowBalance() {
        let json = """
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"5.00","granted_balance":"2.00","topped_up_balance":"3.00"}]}
        """.data(using: .utf8)!
        let s = DeepSeekProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.first?.usedPct, 0)
        XCTAssertTrue(s.windows.first?.subtitle?.contains("Trả: $3.00") ?? false)
        XCTAssertTrue(s.windows.first?.subtitle?.contains("Tặng: $2.00") ?? false)

        let zero = """
        {"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0"}]}
        """.data(using: .utf8)!
        let s2 = DeepSeekProvider().parse(zero, accountLabel: "u")
        XCTAssertEqual(s2.windows.first?.usedPct, 100)  // balance ≤ 0 → red warning
    }

    func testOpenCodeRenewWindow() {
        let json = """
        {"rollingUsage":{"usagePercent":50,"resetInSec":3600},
         "weeklyUsage":{"usagePercent":20,"resetInSec":86400},
         "renewAt":"2026-07-01T00:00:00Z"}
        """
        let s = OpenCodeProvider._parseForTesting(subscriptionText: json)
        XCTAssertNil(s.error)
        XCTAssertTrue(s.windows.contains { $0.label == "Gia hạn" })
    }

    /// Kiro menu-bar display modes turn structured credits/overage into the
    /// menu-bar title; nil falls back to numeric percents, "" = hidden.
    func testKiroMenuBarDisplayModes() {
        let menu = KiroMenuUsage(
            creditsRemaining: 1234, creditsUsed: 766, creditsTotal: 2000,
            primaryRemainingPct: 62,
            overageCreditsUsed: 50, overageCostUSD: 1.5)
        let s = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [],
                               lastUpdated: Date(), kiroMenu: menu)
        func text(_ m: KiroMenuBarDisplayMode) -> String? {
            MenuBarIconRenderer.kiroDisplayText(status: s, mode: m)
        }
        XCTAssertEqual(text(.hidden), "")
        XCTAssertEqual(text(.creditsLeft), "1234")
        XCTAssertEqual(text(.percentLeft), "62%")
        XCTAssertEqual(text(.creditsAndPercent), "1234 · 62%")
        XCTAssertEqual(text(.usedAndTotal), "766 / 2000")
        XCTAssertEqual(text(.overageCostWhenExhausted), "+$1.50")
        XCTAssertEqual(text(.automatic), "1234")  // hasTotal → credits

        // No kiroMenu → nil (caller shows percents); no overage → falls back.
        let bare = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [], lastUpdated: Date())
        XCTAssertNil(MenuBarIconRenderer.kiroDisplayText(status: bare, mode: .creditsLeft))
        let noOverage = KiroMenuUsage(creditsRemaining: 10, creditsUsed: 0, creditsTotal: 10, primaryRemainingPct: 100)
        let s2 = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [], lastUpdated: Date(), kiroMenu: noOverage)
        XCTAssertEqual(MenuBarIconRenderer.kiroDisplayText(status: s2, mode: .overageCostWhenExhausted), "10")
    }

    /// Kiro session points fold into contiguous daily buckets + calendar-today totals.
    func testKiroCostScannerBuildReport() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let sessions: [KiroCostScanner.SessionPoint] = [
            .init(day: today, tokens: 100_000, usd: 0.30, model: "claude-sonnet-4"),
            .init(day: today, tokens: 50_000, usd: 0.15, model: "claude-sonnet-4"),
            .init(day: yesterday, tokens: 200_000, usd: 0.60, model: "claude-opus-4.5"),
        ]
        let report = KiroCostScanner.buildReport(sessions: sessions, now: now, windowDays: 90, calendar: cal)
        XCTAssertEqual(report.daily.count, 90)
        XCTAssertEqual(report.todayTokens, 150_000)
        XCTAssertEqual(report.todayUSD, 0.45, accuracy: 0.001)
        XCTAssertEqual(report.last30Tokens, 350_000)
        XCTAssertEqual(report.last30USD, 1.05, accuracy: 0.001)
        // Token-first top model: opus yesterday 200k > sonnet today 150k
        XCTAssertEqual(report.topModel, "claude-opus-4.5")
        let y = report.daily[report.daily.count - 2]
        XCTAssertEqual(y.tokens, 200_000)
        XCTAssertEqual(y.usd, 0.60, accuracy: 0.001)
    }

    /// Parse a conversation history fixture into daily session points.
    func testKiroCostScannerParseConversationFixture() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let tsMs = Int64(now.timeIntervalSince1970 * 1000)
        let data: [String: Any] = [
            "conversation_id": "sess-test-1",
            "history": [
                [
                    "user": ["content": String(repeating: "a", count: 400)], // ~100 tokens
                    "assistant": ["content": String(repeating: "b", count: 200)], // ~50 tokens
                    "request_metadata": [
                        "model_id": "claude-sonnet-4",
                        "request_start_timestamp_ms": tsMs,
                        "time_between_chunks": Array(repeating: 1, count: 40),
                    ],
                ] as [String: Any],
            ],
        ]
        let points = KiroCostScanner.parseConversation(
            data: data, fallbackCreatedMs: tsMs, cutoff: today, calendar: cal)
        XCTAssertFalse(points.isEmpty)
        let totalTokens = points.reduce(0) { $0 + $1.tokens }
        XCTAssertGreaterThan(totalTokens, 0)
        XCTAssertEqual(points.first?.model, "claude-sonnet-4")
        let report = KiroCostScanner.buildReport(sessions: points, now: now, windowDays: 30, calendar: cal)
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(report.todayTokens, totalTokens)
    }

    /// Kiro /usage parsing: full pipeline including whoami auth method,
    /// /context breakdown, overage status, and version.
    func testKiroParseUsageFullOutput() {
        let usage = """
        Plan: Q Developer Pro
        ████████████████ 42% (resets on 2027-01-01)
        (21.00 of 50 covered in plan)
        Bonus credits:
        10.00/100 credits used, expires in 88 days
        Overages: Enabled
        Credits used: 5.25
        Est. cost: $1.31 USD
        Manage at https://app.kiro.dev/account/usage
        """
        let whoami = """
        Logged in with AWS Builder ID
        Email: boss@example.com
        """
        let context = """
        Context window: 12.5% used
        Context files 3.0%
        Tools 4.5%
        Kiro responses 2.0%
        Your prompts 3.0%
        """
        let s = KiroProvider._parseForTesting(
            usageOutput: usage, whoamiOutput: whoami,
            contextOutput: context, version: "kiro-cli 1.23.1")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows[0].label, "Credits")
        XCTAssertEqual(s.windows[0].usedPct, 42)
        XCTAssertNotNil(s.windows[0].resetDate)
        XCTAssertEqual(s.windows[1].label, "Bonus Credits")
        XCTAssertEqual(s.windows[1].usedPct, 10)
        XCTAssertEqual(s.windows[2].label, "Vượt hạn mức")
        XCTAssertEqual(s.windows[2].subtitle, "5.25 credits · ~$1.31")
        XCTAssertEqual(s.accountLabel, "boss@example.com")
        XCTAssertEqual(s.sourceLabel, "AWS Builder ID")
        XCTAssertEqual(s.planName, "Q Developer Pro")
        XCTAssertEqual(s.version, "kiro-cli 1.23.1")
        XCTAssertEqual(s.kiroMenu?.overagesStatus, "Enabled")
        XCTAssertEqual(s.kiroMenu?.contextPercentUsed, 12.5)
        XCTAssertEqual(s.kiroMenu?.contextToolsPercent, 4.5)
        XCTAssertEqual(s.kiroMenu?.creditsRemaining, 29)
    }

    /// Managed plans hide plan credits but keep bonus/overage windows
    /// (CodexBar behavior — previously BirdNion dropped them).
    func testKiroParseManagedPlanKeepsBonusAndOverage() {
        let usage = """
        Plan: Enterprise
        Managed by Admin
        Bonus credits:
        2.00/20 credits used, expires in 10 days
        Overages: Disabled
        """
        let s = KiroProvider._parseForTesting(usageOutput: usage, whoamiOutput: nil)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.map(\.label), ["Credits", "Bonus Credits", "Vượt hạn mức"])
        XCTAssertEqual(s.windows[0].remainingPct, 100)
        XCTAssertEqual(s.windows[2].subtitle, "Disabled")
        XCTAssertEqual(s.kiroMenu?.overagesStatus, "Disabled")
    }

    /// KIRO-branded plan names get title-cased; version prefix is stripped.
    func testKiroDisplayHelpers() {
        XCTAssertEqual(KiroProvider.displayPlanName("KIRO  FREE"), "Kiro Free")
        XCTAssertEqual(KiroProvider.displayPlanName("Q Developer Pro"), "Q Developer Pro")
        XCTAssertEqual(KiroProvider.parseVersionOutput("kiro-cli 1.23.1"), "1.23.1")
        XCTAssertEqual(KiroProvider.parseVersionOutput("2.0.0"), "2.0.0")
        XCTAssertNil(KiroProvider.parseContextUsage("no context here"))
        XCTAssertTrue(KiroProvider.isLoginRequired("Error: Not logged in"))
        XCTAssertFalse(KiroProvider.isLoginRequired("Plan: Free"))
    }

    /// GUI apps miss shell PATH; resolveBinary must still find ~/.local/bin/kiro-cli
    /// and must skip the Kiro IDE launcher under Kiro.app.
    func testKiroResolveBinaryFindsLocalBinAndSkipsIDE() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kiro-resolve-\(UUID().uuidString)", isDirectory: true)
        let localBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        let appBin = root.appendingPathComponent(
            "Applications/Kiro.app/Contents/Resources/app/bin", isDirectory: true)
        try fm.createDirectory(at: localBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: appBin, withIntermediateDirectories: true)

        let cli = localBin.appendingPathComponent("kiro-cli")
        let ide = appBin.appendingPathComponent("code")
        try "#!/bin/sh\necho cli\n".write(to: cli, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho ide\n".write(to: ide, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ide.path)

        // Thin GUI PATH + well-known ~/.local/bin under a fake home.
        let found = KiroProvider.resolveBinary(
            home: root.path, pathEnv: "/usr/bin:/bin", fileManager: fm)
        XCTAssertEqual(found, cli.path)

        // IDE shim under Kiro.app must be rejected.
        XCTAssertFalse(KiroProvider.isUsableCLI(at: ide.path, fileManager: fm))
        XCTAssertTrue(KiroProvider.isUsableCLI(at: cli.path, fileManager: fm))

        // Prefer kiro-cli over a plain `kiro` sibling.
        let plain = localBin.appendingPathComponent("kiro")
        try "#!/bin/sh\necho plain\n".write(to: plain, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        let preferred = KiroProvider.resolveBinary(
            home: root.path, pathEnv: "/usr/bin:/bin", fileManager: fm)
        XCTAssertEqual(preferred, cli.path)

        try? fm.removeItem(at: root)
    }

    func testMenuBarPercentTitleIncludesUnit() {
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [76]), "76%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [93, 82]), "93%  82%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [-4, 120]), "0%  100%")
    }

    func testMenuBarProviderLogosAreMonochromeTemplates() {
        let providerIDs = [
            "minimax", "hapo", "codex", "claude", "openrouter", "deepseek", "zai",
            "elevenlabs", "deepgram", "groq", "grok", "openai", "ollama", "copilot",
            "kilo", "commandcode", "freemodel", "mimo", "cursor", "alibaba", "opencode",
            "opencodego", "gemini", "kiro", "antigravity", "bedrock",
        ]

        for id in providerIDs {
            XCTAssertTrue(MenuBarIconRenderer.providerLogo(for: id).isTemplate, id)
        }
    }

    func testMenuBarFramesFallBackToBirdWhenPercentHiddenOrNoQuota() {
        let status = ProviderStatus(
            id: "hapo", displayName: "AI Hub",
            windows: [QuotaWindow(label: "Week", usedPct: 24, remainingPct: 76)],
            lastUpdated: Date())
        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [status], showPercent: false, visibility: { _ in true }),
            [.bird])
        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [ProviderStatus(id: "hapo", displayName: "AI Hub", windows: [], lastUpdated: Date())],
                showPercent: true,
                visibility: { _ in true }),
            [.bird])
    }

    func testMenuBarFramesRotateThroughActiveProviderPercents() {
        let codex = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 hours", usedPct: 7, remainingPct: 93)],
            lastUpdated: Date())
        let hapo = ProviderStatus(
            id: "hapo", displayName: "AI Hub",
            windows: [QuotaWindow(label: "Week", usedPct: 24, remainingPct: 76)],
            lastUpdated: Date())

        // Both active → alphabetical by displayName ("AI Hub" before "Codex"),
        // independent of input order.
        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [codex, hapo], showPercent: true, visibility: { _ in true }),
            [
                .provider(id: "hapo", name: "AI Hub", percents: [76], text: nil),
                .provider(id: "codex", name: "Codex", percents: [93], text: nil),
            ])
        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [hapo, codex], showPercent: true, visibility: { _ in true }),
            [
                .provider(id: "hapo", name: "AI Hub", percents: [76], text: nil),
                .provider(id: "codex", name: "Codex", percents: [93], text: nil),
            ])
    }

    /// Active (used) providers rotate before idle full-quota ones; within each
    /// group the order is A→Z by displayName.
    func testMenuBarFramesPrioritizeActiveThenAlphabetical() {
        let idleZ = ProviderStatus(
            id: "zai", displayName: "Z.ai",
            windows: [QuotaWindow(label: "Day", usedPct: 0, remainingPct: 100)],
            lastUpdated: Date())
        let activeM = ProviderStatus(
            id: "minimax", displayName: "MiniMax",
            windows: [QuotaWindow(label: "Day", usedPct: 45, remainingPct: 55)],
            lastUpdated: Date())
        let activeA = ProviderStatus(
            id: "claude", displayName: "Claude",
            windows: [QuotaWindow(label: "5h", usedPct: 10, remainingPct: 90)],
            lastUpdated: Date())
        let idleB = ProviderStatus(
            id: "bedrock", displayName: "Bedrock",
            windows: [QuotaWindow(label: "Day", usedPct: 0, remainingPct: 100)],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [idleZ, activeM, activeA, idleB],
                showPercent: true,
                visibility: { _ in true }),
            [
                // Active, A→Z
                .provider(id: "claude", name: "Claude", percents: [90], text: nil),
                .provider(id: "minimax", name: "MiniMax", percents: [55], text: nil),
                // Idle, A→Z
                .provider(id: "bedrock", name: "Bedrock", percents: [100], text: nil),
                .provider(id: "zai", name: "Z.ai", percents: [100], text: nil),
            ])
    }

    func testHapoMenuBarFrameShowsPercentOnly() {
        let hapo = ProviderStatus(
            id: "hapo", displayName: "AI Hub",
            windows: [QuotaWindow(label: "Week",
                                  usedPct: 27,
                                  remainingPct: 73,
                                  subtitle: "$14.60 / $20.00")],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [hapo], showPercent: true, visibility: { _ in true }),
            [.provider(id: "hapo", name: "AI Hub", percents: [73], text: nil)])
    }

    /// Kilo org list comes back as a tRPC batch whose `json` is a DIRECT array
    /// of orgs (not `{organizations:[...]}`). The REST profile shape is also
    /// accepted as a fallback.
    func testKiloOrganizationsParseTRPCArrayAndREST() {
        let trpc = """
        [{"result":{"data":{"json":[
          {"id":"org_1","name":"Acme","role":"admin"},
          {"id":"org_2","name":"Beta"}]}}}]
        """.data(using: .utf8)!
        let orgs = KiloOrganization.parse(data: trpc)
        XCTAssertEqual(orgs.map(\.id), ["org_1", "org_2"])
        XCTAssertEqual(orgs.first?.name, "Acme")
        XCTAssertEqual(orgs.first?.role, "admin")
        XCTAssertNil(orgs.last?.role)  // missing role → nil

        let rest = #"{"organizations":[{"id":"org_3","name":"Gamma"}]}"#.data(using: .utf8)!
        XCTAssertEqual(KiloOrganization.parse(data: rest).map(\.id), ["org_3"])

        // Empty / unknown shape → empty array (not a crash).
        XCTAssertTrue(KiloOrganization.parse(data: Data("{}".utf8)).isEmpty)
    }

    /// FreeModel returns two dollar budgets (5h + weekly) as cents. The parser
    /// converts cents→USD, computes used%, and renders a "$used / $limit"
    /// subtitle. Account label passes through unchanged.
    func testFreemodelDollarWindows() {
        let json = """
        {"window5h":{"usedCents":2250,"limitCents":20000,"resetsAt":1782724407},
         "windowWeek":{"usedCents":8,"limitCents":132000,"resetsAt":1783321795}}
        """.data(using: .utf8)!
        let s = FreemodelProvider._parseForTesting(usageData: json, accountLabel: "me@x.com")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.accountLabel, "me@x.com")
        XCTAssertEqual(s.windows.count, 2)

        let fiveH = s.windows[0]
        XCTAssertEqual(fiveH.label, "5 giờ")
        XCTAssertEqual(fiveH.usedPct, 11)            // 2250/20000 = 11.25% → 11
        XCTAssertEqual(fiveH.remainingPct, 89)
        XCTAssertEqual(fiveH.subtitle, "$22.50 / $200.00")
        XCTAssertNotNil(fiveH.resetDate)

        let week = s.windows[1]
        XCTAssertEqual(week.label, "Tuần")
        XCTAssertEqual(week.usedPct, 0)              // 8/132000 ≈ 0.006% → 0
        XCTAssertEqual(week.subtitle, "$0.08 / $1,320.00")

        // Malformed payload → error, no windows.
        let bad = FreemodelProvider._parseForTesting(usageData: Data("{}".utf8), accountLabel: nil)
        XCTAssertNotNil(bad.error)
        XCTAssertTrue(bad.windows.isEmpty)
    }

    /// The cookie filter forwards every pair but only proceeds when `bm_session`
    /// is present, and tolerates a full "Cookie: …" header line pasted from devtools.
    func testFreemodelCookieHeaderFilter() {
        // Plain pair list with the session cookie → forwarded as-is.
        XCTAssertEqual(
            FreemodelProvider.filteredCookieHeader(from: "bm_session=abc; other=v"),
            "bm_session=abc; other=v")

        // A pasted "Cookie:" prefix is stripped so the session is still recognised.
        XCTAssertEqual(
            FreemodelProvider.filteredCookieHeader(from: "Cookie: bm_session=abc; other=v"),
            "bm_session=abc; other=v")

        // No session cookie → rejected (nil), even if other cookies exist.
        XCTAssertNil(FreemodelProvider.filteredCookieHeader(from: "_ga=1; __stripe_mid=2"))
    }

    // MARK: - FreemodelAccountStore

    func testFreemodelAccountStoreBrowserEntriesHaveNoStoredCookie() {
        // Browser entries (auto + per-browser) never resolve a stored cookie —
        // they are live-scan pointers, not persisted secrets.
        UserDefaults.standard.set("browser", forKey: FreemodelAccountStore.activeKey)
        XCTAssertNil(FreemodelAccountStore.activeCookieHeader())
        XCTAssertNil(FreemodelAccountStore.activeBrowserID())

        UserDefaults.standard.set("browser:chrome", forKey: FreemodelAccountStore.activeKey)
        XCTAssertNil(FreemodelAccountStore.activeCookieHeader())
        XCTAssertEqual(FreemodelAccountStore.activeBrowserID(), "chrome")

        UserDefaults.standard.removeObject(forKey: FreemodelAccountStore.activeKey)
    }

    func testFreemodelAccountStoreAddSwitchRemoveRoundtrip() throws {
        defer { UserDefaults.standard.removeObject(forKey: FreemodelAccountStore.activeKey) }
        let account = try FreemodelAccountStore.add(
            cookie: "bm_session=test-roundtrip", label: "Test", email: "t@x.com")
        defer { try? FreemodelAccountStore.remove(account.id) }

        XCTAssertFalse(account.isBrowser)
        XCTAssertEqual(account.label, "Test")

        FreemodelAccountStore.setActive(account.id)
        XCTAssertEqual(FreemodelAccountStore.activeCookieHeader(), "bm_session=test-roundtrip")

        try FreemodelAccountStore.remove(account.id)
        // Removing the active account falls back to the browser scan.
        XCTAssertEqual(FreemodelAccountStore.activeID(), FreemodelAccountStore.browserID)
        XCTAssertNil(FreemodelAccountStore.activeCookieHeader())
        XCTAssertFalse(FreemodelAccountStore.managedAccounts().contains(where: { $0.id == account.id }))
    }

    // MARK: - ElevenLabsKeyStore

    /// Isolated store: temp metadata file + throwaway UserDefaults suite so
    /// tests never touch the real key store or the app's active selection.
    private func makeTempElevenLabsStore() throws -> (url: URL, defaults: UserDefaults, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("el-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("elevenlabs-keys.json")
        // Pre-create an empty store so ensureLegacyImport never copies the
        // machine's real legacy apiKey into the temp store.
        try Data(#"{"accounts":[]}"#.utf8).write(to: url)
        let suite = "el-keys-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (url, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    func testElevenLabsKeyStoreAddSwitchRemoveRoundtrip() throws {
        let store = try makeTempElevenLabsStore()
        defer { store.cleanup() }
        let url = store.url, defaults = store.defaults

        XCTAssertTrue(ElevenLabsKeyStore.allKeys(url: url, defaults: defaults).isEmpty)
        XCTAssertNil(ElevenLabsKeyStore.activeApiKey(url: url, defaults: defaults))

        let k1 = try ElevenLabsKeyStore.add(apiKey: "sk-el-test-one-aaaa", label: "Work",
                                            url: url, defaults: defaults)
        XCTAssertEqual(k1.label, "Work")
        XCTAssertEqual(k1.preview, "sk-el-te")
        // First key auto-activates.
        XCTAssertEqual(ElevenLabsKeyStore.activeID(url: url, defaults: defaults), k1.id)

        let k2 = try ElevenLabsKeyStore.add(apiKey: "sk-el-test-two-bbbb", label: "Personal",
                                            url: url, defaults: defaults)
        // Adding a second key must NOT steal active.
        XCTAssertEqual(ElevenLabsKeyStore.activeID(url: url, defaults: defaults), k1.id)

        ElevenLabsKeyStore.setActive(k2.id, url: url, defaults: defaults)
        XCTAssertEqual(ElevenLabsKeyStore.activeID(url: url, defaults: defaults), k2.id)
        XCTAssertEqual(ElevenLabsKeyStore.activeApiKey(url: url, defaults: defaults), "sk-el-test-two-bbbb")
        XCTAssertEqual(ElevenLabsKeyStore.activeDisplayLabel(url: url, defaults: defaults), "Personal")

        try ElevenLabsKeyStore.remove(k2.id, url: url, defaults: defaults)
        // Active falls back to the first remaining key.
        XCTAssertEqual(ElevenLabsKeyStore.activeID(url: url, defaults: defaults), k1.id)
        XCTAssertEqual(ElevenLabsKeyStore.allKeys(url: url, defaults: defaults).count, 1)

        try ElevenLabsKeyStore.remove(k1.id, url: url, defaults: defaults)
        XCTAssertTrue(ElevenLabsKeyStore.allKeys(url: url, defaults: defaults).isEmpty)
        XCTAssertNil(ElevenLabsKeyStore.activeApiKey(url: url, defaults: defaults))
    }

    /// Regression for the bug where a wiped UserDefaults mirror silently made
    /// quota fetch fall back to the FIRST stored key instead of the selected
    /// one: the file's `activeId` is authoritative and must survive on its own.
    func testElevenLabsKeyStoreActiveSurvivesDefaultsWipe() throws {
        let store = try makeTempElevenLabsStore()
        defer { store.cleanup() }
        let url = store.url, defaults = store.defaults

        let k1 = try ElevenLabsKeyStore.add(apiKey: "sk-el-test-one-aaaa", label: nil,
                                            url: url, defaults: defaults)
        let k2 = try ElevenLabsKeyStore.add(apiKey: "sk-el-test-two-bbbb", label: nil,
                                            url: url, defaults: defaults)
        ElevenLabsKeyStore.setActive(k2.id, url: url, defaults: defaults)

        // Simulate the old landmine: the UserDefaults mirror gets wiped.
        defaults.removeObject(forKey: ElevenLabsKeyStore.activeKey)

        XCTAssertNotEqual(k1.id, k2.id)
        XCTAssertEqual(ElevenLabsKeyStore.activeID(url: url, defaults: defaults), k2.id)
        XCTAssertEqual(ElevenLabsKeyStore.activeApiKey(url: url, defaults: defaults), "sk-el-test-two-bbbb")
    }

    func testElevenLabsKeyStoreRejectsEmptyKey() throws {
        let store = try makeTempElevenLabsStore()
        defer { store.cleanup() }
        XCTAssertThrowsError(try ElevenLabsKeyStore.add(apiKey: "   ", label: nil,
                                                        url: store.url, defaults: store.defaults))
        XCTAssertTrue(ElevenLabsKeyStore.allKeys(url: store.url, defaults: store.defaults).isEmpty)
    }
}
