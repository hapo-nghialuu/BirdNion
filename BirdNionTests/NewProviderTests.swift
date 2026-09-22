import AppKit
@testable import CodexBarCore
import SQLite3
import XCTest
@testable import BirdNion

private actor KiroScanInvocationCounter {
    private var count = 0
    func increment() { count += 1 }
    func current() -> Int { count }
}

/// Parser tests for the natively-authored new providers (fixture-driven, no
/// network). Cookie/OAuth/CLI providers expose their own `_parseForTesting`
/// hooks; these cover the three hand-written API-key parsers.
@MainActor
final class NewProviderTests: XCTestCase {
    private func withCodexMenuBarPreferences(
        metric: CodexMenuBarMetric,
        genericPreference: MenuBarMetricPreference? = nil,
        _ body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let metricKey = CodexMenuBarMetric.defaultsKey
        let preferencesKey = "menuBarMetricPreferencesJSON"
        let previousMetric = defaults.object(forKey: metricKey)
        let previousPreferences = defaults.object(forKey: preferencesKey)

        defer {
            if let previousMetric {
                defaults.set(previousMetric, forKey: metricKey)
            } else {
                defaults.removeObject(forKey: metricKey)
            }
            if let previousPreferences {
                defaults.set(previousPreferences, forKey: preferencesKey)
            } else {
                defaults.removeObject(forKey: preferencesKey)
            }
        }

        defaults.set(metric.rawValue, forKey: metricKey)
        if let genericPreference {
            defaults.set("{\"codex\":\"\(genericPreference.rawValue)\"}", forKey: preferencesKey)
        } else {
            defaults.set("{}", forKey: preferencesKey)
        }
        body()
    }

    private func codexMenuBarFrames(for windows: [QuotaWindow]) -> [MenuBarIconRenderer.Frame] {
        let status = ProviderStatus(
            id: "codex",
            displayName: "Codex",
            windows: windows,
            lastUpdated: Date())
        return MenuBarIconRenderer.frames(
            from: [status],
            showPercent: true,
            visibility: { _ in true })
    }

    private func withAntigravityMenuBarMetric(
        _ metric: AntigravityMenuBarMetric,
        genericPreference: MenuBarMetricPreference? = nil,
        _ body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let metricKey = AntigravityMenuBarMetric.defaultsKey
        let preferencesKey = "menuBarMetricPreferencesJSON"
        let previousMetric = defaults.object(forKey: metricKey)
        let previousPreferences = defaults.object(forKey: preferencesKey)

        defer {
            if let previousMetric {
                defaults.set(previousMetric, forKey: metricKey)
            } else {
                defaults.removeObject(forKey: metricKey)
            }
            if let previousPreferences {
                defaults.set(previousPreferences, forKey: preferencesKey)
            } else {
                defaults.removeObject(forKey: preferencesKey)
            }
        }

        defaults.set(metric.rawValue, forKey: metricKey)
        if let genericPreference {
            defaults.set(
                "{\"antigravity\":\"\(genericPreference.rawValue)\"}",
                forKey: preferencesKey)
        }
        body()
    }

    private func antigravityMenuBarFrames(
        for windows: [QuotaWindow]
    ) -> [MenuBarIconRenderer.Frame] {
        let status = ProviderStatus(
            id: "antigravity",
            displayName: "Antigravity",
            windows: windows,
            lastUpdated: Date())
        return MenuBarIconRenderer.frames(
            from: [status],
            showPercent: true,
            visibility: { _ in true })
    }

    func testKiroReportCacheCoalescesConcurrentLoads() async {
        let cache = KiroCostScanner.Cache()
        let counter = KiroScanInvocationCounter()
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = await cache.report(now: now, ttl: 300) {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return nil
                    }
                }
            }
        }
        let invocationCount = await counter.current()
        XCTAssertEqual(invocationCount, 1)
    }

    func testKiroReportCacheRetainsFailClosedProjectionWithinTTL() async {
        let cache = KiroCostScanner.Cache()
        let counter = KiroScanInvocationCounter()
        let now = Date()
        let unavailable = KiroUsageReport(
            todayUSD: 0,
            todayTokens: 0,
            last30USD: 0,
            last30Tokens: 0,
            daily: [],
            topModel: nil)

        for _ in 0..<2 {
            _ = await cache.report(now: now, ttl: 300) {
                await counter.increment()
                return unavailable
            }
        }

        let invocationCount = await counter.current()
        XCTAssertEqual(invocationCount, 1)
    }

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

    func testCostHistoryApplyReceiptFailsClosedWhenPersistenceFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-write-failure-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let receipt = CostHistoryStore.applyWithReceipt(
            source: .omp,
            liveDays: [(now, 9.0, 900, [("model", 9.0, 900)])],
            now: now,
            windowDays: 7,
            url: root.appendingPathComponent("cost-history.json"),
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        XCTAssertEqual(receipt.window.reduce(0) { $0 + $1.tokens }, 0)
        XCTAssertEqual(receipt.window.reduce(0.0) { $0 + $1.usd }, 0, accuracy: 0.001)
    }

    func testCostHistoryApplyReceiptDoesNotOverwriteMalformedHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let malformed = Data(#"{"version":1,"sources":{"claude":BROKEN}}"#.utf8)
        try malformed.write(to: url)

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .omp,
            liveDays: [(Date(), 9.0, 900, [("model", 9.0, 900)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        XCTAssertTrue(receipt.window.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testCostHistorySemanticPoisonIsNotPublishedOrOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-semantic-poison-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let day = CostHistoryStore.dayKey(Date())
        let poison: [String: Any] = [
            "version": 1,
            "sources": [
                "claude": [day: ["usd": -1.0, "tokens": -10, "models": []]],
                "codex": [day: ["usd": 2.0, "tokens": 200, "models": []]],
            ],
        ]
        let original = try JSONSerialization.data(
            withJSONObject: poison, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: url)

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .omp,
            liveDays: [(Date(), 9.0, 900, [("model", 9.0, 900)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        XCTAssertTrue(receipt.window.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(CostHistoryStore.confidence(
            source: .codex, liveScanSucceeded: false, url: url).included)
        XCTAssertTrue(CostHistoryStore.window(
            source: .codex, windowDays: 7, url: url).allSatisfy {
                $0.tokens == 0 && $0.usd == 0
            })
    }

    func testCostHistoryDanglingSymlinkIsNotTreatedAsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-dangling-link-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let missingTarget = root.appendingPathComponent("missing-target.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: missingTarget)

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(Date(), 1.0, 100, [("model", 1.0, 100)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        XCTAssertTrue(receipt.window.isEmpty)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
            missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testCostHistoryOversizedSparseFileFailsClosedWithoutOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-oversized-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(8 * 1024 * 1024 + 1))
        try handle.close()

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(Date(), 1.0, 100, [("model", 1.0, 100)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        XCTAssertTrue(receipt.window.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.size] as? UInt64, UInt64(8 * 1024 * 1024 + 1))
    }

    func testCostHistoryFutureVersionAndOversizedCardinalityRemainUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-forward-version-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let today = CostHistoryStore.dayKey(Date())

        let futureVersion = Data(
            #"{"version":2,"sources":{},"newCriticalMetadata":{"keep":true}}"#.utf8)
        try futureVersion.write(to: url)
        var receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(Date(), 1.0, 100, [("model", 1.0, 100)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)
        XCTAssertFalse(receipt.persisted)
        XCTAssertEqual(try Data(contentsOf: url), futureVersion)

        let models = (0..<33).map {
            ["name": "model-\($0)", "usd": 0.0, "tokens": 1] as [String: Any]
        }
        let excessive: [String: Any] = [
            "version": 1,
            "sources": [
                "kiro": [today: ["usd": 0.0, "tokens": 33, "models": models]],
            ],
        ]
        let excessiveData = try JSONSerialization.data(
            withJSONObject: excessive, options: [.sortedKeys])
        try excessiveData.write(to: url)
        receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(Date(), 1.0, 100, [("model", 1.0, 100)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)
        XCTAssertFalse(receipt.persisted)
        XCTAssertEqual(try Data(contentsOf: url), excessiveData)
    }

    func testCostHistoryAcceptsAndPersistsNineRealModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-nine-models-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let models = (0..<9).map { index in
            (name: "model-\(index)", usd: Double(index), tokens: index + 1)
        }

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [(Date(), 36, 45, models)],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertTrue(receipt.persisted)
        let stored = CostHistoryStore.read(url: url)
        XCTAssertEqual(stored.sources?["codex"]?.values.first?.models.count, 9)
    }

    func testCostHistoryFIFOFailsClosedWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-fifo-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        XCTAssertEqual(url.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(Date(), 1, 100, [("model", 1, 100)])],
            windowDays: 7,
            url: url,
            liveScanSucceeded: true)

        XCTAssertFalse(receipt.persisted)
        var info = stat()
        XCTAssertEqual(url.path.withCString { lstat($0, &info) }, 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFIFO))
    }

    func testCostHistoryWriterRejectsDocumentItsBoundedReaderCannotRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-writer-bound-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let original = Data(#"{"version":1,"sources":{}}"#.utf8)
        try original.write(to: url)
        let now = Date()
        let cal = Calendar.current
        let models = (0..<8).map { index in
            CostHistoryStore.Model(
                name: String(repeating: "😀", count: 127) + "\(index)",
                usd: 0,
                tokens: 1)
        }
        var days: [String: CostHistoryStore.Day] = [:]
        for offset in 0..<400 {
            let date = cal.date(byAdding: .day, value: -offset, to: now)!
            days[CostHistoryStore.dayKey(date, calendar: cal)] = .init(
                usd: 0,
                tokens: 8,
                models: models)
        }
        let sources = Dictionary(uniqueKeysWithValues: CostHistoryStore.Source.allCases.map {
            ($0.rawValue, days)
        })
        let document = CostHistoryStore.Document(version: 1, sources: sources)
        XCTAssertTrue(CostHistoryStore.validateDocument(document, now: now))

        XCTAssertThrowsError(try CostHistoryStore.write(document, url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCostHistoryTopModelUsesMergedTrailingWindowAndSurvivesEmptyScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-top-model-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let now = Date()
        let cal = Calendar.current
        let historical = (1...29).map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: now)!
            return (date, 1.0, 100, [("model-a", 1.0, 100)])
        }
        var receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: historical,
            now: now,
            calendar: cal,
            windowDays: 120,
            url: url,
            liveScanSucceeded: true,
            updateTopModel: true,
            topModel: "model-a")
        XCTAssertTrue(receipt.persisted)

        receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(now, 1.0, 10, [("model-b", 1.0, 10)])],
            now: now,
            calendar: cal,
            windowDays: 120,
            url: url,
            liveScanSucceeded: true,
            updateTopModel: true,
            topModel: "model-b")
        XCTAssertTrue(receipt.persisted)
        XCTAssertEqual(CostHistoryStore.storedTopModel(source: .kiro, url: url), "model-a")

        receipt = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [],
            now: now,
            calendar: cal,
            windowDays: 120,
            url: url,
            liveScanSucceeded: true,
            updateTopModel: true,
            topModel: nil)
        XCTAssertTrue(receipt.persisted)
        XCTAssertEqual(CostHistoryStore.storedTopModel(source: .kiro, url: url), "model-a")
    }

    func testCostHistorySemanticValidatorRejectsEveryPersistedPoisonClass() {
        let now = Date()
        let cal = Calendar.current
        let today = CostHistoryStore.dayKey(now, calendar: cal)
        let yesterday = CostHistoryStore.dayKey(
            cal.date(byAdding: .day, value: -1, to: now)!, calendar: cal)
        let validDay = CostHistoryStore.Day(
            usd: 1,
            tokens: 10,
            models: [.init(name: "model", usd: 1, tokens: 10)])
        let valid = CostHistoryStore.Document(
            version: 1,
            sources: ["kiro": [today: validDay]],
            scannedAt: ["kiro": Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))])
        XCTAssertTrue(CostHistoryStore.validateDocument(valid, now: now))

        var badDayKey = valid
        badDayKey.sources = ["kiro": ["2026-8-1": validDay]]
        XCTAssertFalse(CostHistoryStore.validateDocument(badDayKey, now: now))

        var futureDay = valid
        futureDay.sources = ["kiro": ["9999-01-01": validDay]]
        XCTAssertFalse(CostHistoryStore.validateDocument(futureDay, now: now))

        var badModel = valid
        badModel.sources?["kiro"]?[today]?.models[0].name = "bad\nmodel"
        XCTAssertFalse(CostHistoryStore.validateDocument(badModel, now: now))

        var trailingControlModel = valid
        trailingControlModel.sources?["kiro"]?[today]?.models[0].name = "model\n"
        XCTAssertFalse(CostHistoryStore.validateDocument(trailingControlModel, now: now))

        var oversizedDecomposedModel = valid
        let decomposedName = String(repeating: "e\u{0301}", count: 128)
        XCTAssertEqual(decomposedName.count, 128)
        XCTAssertEqual(decomposedName.unicodeScalars.count, 256)
        oversizedDecomposedModel.sources?["kiro"]?[today]?.models[0].name = decomposedName
        XCTAssertFalse(CostHistoryStore.validateDocument(oversizedDecomposedModel, now: now))

        var futureScan = valid
        futureScan.scannedAt?["kiro"] = Int64(
            (now.addingTimeInterval(301).timeIntervalSince1970 * 1_000).rounded(.towardZero))
        XCTAssertFalse(CostHistoryStore.validateDocument(futureScan, now: now))

        var tokenOverflow = valid
        tokenOverflow.sources = [
            "kiro": [
                today: .init(usd: 0, tokens: Int.max, models: []),
                yesterday: .init(usd: 0, tokens: 1, models: []),
            ],
        ]
        XCTAssertFalse(CostHistoryStore.validateDocument(tokenOverflow, now: now))

        var usdOverflow = valid
        usdOverflow.sources = [
            "kiro": [
                today: .init(usd: Double.greatestFiniteMagnitude, tokens: 0, models: []),
                yesterday: .init(usd: Double.greatestFiniteMagnitude, tokens: 0, models: []),
            ],
        ]
        XCTAssertFalse(CostHistoryStore.validateDocument(usdOverflow, now: now))
    }

    // MARK: - Data Confidence Pass

    /// Legacy `cost-history.json` files (written before the Data Confidence
    /// Pass) have no `scannedAt` key — decoding must not fail, and the field
    /// reads back as `nil` rather than an empty dictionary.
    func testCostHistoryDocumentDecodesLegacyMissingScannedAt() throws {
        let legacyJSON = """
        {"version":1,"sources":{"claude":{"2026-08-01":{"usd":1.5,"tokens":150,"models":[]}}}}
        """
        let doc = try JSONDecoder().decode(CostHistoryStore.Document.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(doc.scannedAt)
        XCTAssertEqual(doc.sources?["claude"]?["2026-08-01"]?.tokens, 150)
    }

    /// `scannedAt` persists as epoch millis (matches the Linux Tauri port's
    /// `cost-history.json` schema) and round-trips exactly through encode/decode.
    func testCostHistoryDocumentScannedAtEpochMillisRoundtrip() throws {
        let millis: Int64 = 1_755_555_555_123
        let doc = CostHistoryStore.Document(version: 1, sources: [:], scannedAt: ["claude": millis])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(CostHistoryStore.Document.self, from: data)
        XCTAssertEqual(decoded.scannedAt?["claude"], millis)
    }

    func testCostHistoryMigratesFractionalMacTimestampToSharedIntegerSchema() throws {
        let legacyJSON = """
        {"version":1,"sources":{},"scanned_at":{"kiro":1787651040100.229}}
        """
        let migrated = try JSONDecoder().decode(
            CostHistoryStore.Document.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(migrated.scannedAt?["kiro"], 1_787_651_040_100)

        let canonical = try JSONEncoder().encode(migrated)
        let canonicalText = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        XCTAssertTrue(canonicalText.contains("1787651040100"))
        XCTAssertFalse(canonicalText.contains("1787651040100.229"))
        XCTAssertEqual(
            try JSONDecoder().decode(CostHistoryStore.Document.self, from: canonical),
            migrated)
    }

    func testCostHistoryDaySchemaStaysGregorianUnderNonGregorianUserCalendars() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let now = try XCTUnwrap(gregorian.date(
            from: DateComponents(year: 2026, month: 8, day: 25, hour: 12)))
        let day = CostHistoryStore.Day(
            usd: 1, tokens: 10,
            models: [.init(name: "kiro-model", usd: 1, tokens: 10)])

        for identifier in [Calendar.Identifier.buddhist, .islamicCivil] {
            var userCalendar = Calendar(identifier: identifier)
            userCalendar.timeZone = zone
            XCTAssertEqual(
                CostHistoryStore.dayKey(now, calendar: userCalendar),
                "2026-08-25")
            let parsed = try XCTUnwrap(
                CostHistoryStore.parseDayKey("2026-08-25", calendar: userCalendar))
            XCTAssertEqual(
                CostHistoryStore.dayKey(parsed, calendar: userCalendar),
                "2026-08-25")
            let document = CostHistoryStore.Document(
                version: 1,
                sources: ["kiro": ["2026-08-25": day]],
                scannedAt: nil)
            XCTAssertTrue(CostHistoryStore.validateDocument(
                document, now: now, calendar: userCalendar))
        }
    }

    func testClaudeAccountMutationDoesNotPublishUndurableState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let impossibleURL = blockingFile.appendingPathComponent("claude-accounts.json")
        let account = ClaudeTokenAccount(
            label: "B", token: "sk-ant-test", kind: .admin)

        switch ClaudeTokenAccountStore.add(account, url: impossibleURL) {
        case .success:
            XCTFail("undurable mutation must not publish success state")
        case .failure(let error):
            XCTAssertEqual(error, .persistenceFailed)
        }
        XCTAssertTrue(ClaudeTokenAccountStore.load(url: impossibleURL).accounts.isEmpty)
    }

    func testClaudeAccountMutationRefusesMalformedExistingStoreWithoutOverwritingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let malformed = Data("{ truncated credential store".utf8)
        try malformed.write(to: url)

        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(label: "B", token: "sk-ant-test", kind: .admin),
            url: url)

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testClaudeAccountMutationRefusesDanglingSymlinkStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let missingTarget = root.appendingPathComponent("missing-target.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: missingTarget)

        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(label: "B", token: "sk-ant-test", kind: .admin),
            url: url)

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
                       missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testClaudeAccountMutationRefusesFIFOStoreWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        XCTAssertEqual(url.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        let startedAt = Date()
        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(label: "B", token: "sk-ant-test", kind: .admin),
            url: url)

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        var info = stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &info) }, 0)
        XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFIFO))
    }

    func testClaudeAccountMutationRefusesOversizedStoreWithoutOverwritingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-oversized-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let oversized = Data(repeating: 0x7b, count: ClaudeTokenAccountStore.maxStoredBytes + 1)
        try oversized.write(to: url)

        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(label: "B", token: "sk-ant-test", kind: .admin),
            url: url)

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertEqual(try Data(contentsOf: url), oversized)
    }

    func testClaudeAccountMutationRejectsOversizedEncodedStoreWithoutOverwritingValidStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-oversized-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let originalAccount = ClaudeTokenAccount(
            label: "Existing", token: "sk-ant-existing", kind: .admin)

        let initialResult = ClaudeTokenAccountStore.add(originalAccount, url: url)
        guard case .success(let initialStore) = initialResult else {
            return XCTFail("valid credential store should save successfully")
        }
        let originalBytes = try Data(contentsOf: url)

        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(
                label: "Oversized",
                token: String(repeating: "x", count: ClaudeTokenAccountStore.maxStoredBytes),
                kind: .admin),
            url: url)

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(ClaudeTokenAccountStore.load(url: url), initialStore)
    }

    func testClaudeAccountStorePersistsCredentialsWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-claude-account-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")

        let result = ClaudeTokenAccountStore.add(
            ClaudeTokenAccount(label: "B", token: "sk-ant-test", kind: .admin),
            url: url)

        guard case .success = result else {
            return XCTFail("credential store should save successfully")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testCostHistoryMetadataUsesSharedSnakeCaseAndPreservesLinuxMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-linux-metadata-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cost-history.json")
        let now = Date()
        let millis = Int64((now.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let linuxJSON = """
        {"version":1,"sources":{"kiro":{}},"scanned_at":{"kiro":\(millis)},
         "counting_revision":{"kiro":2},"top_models":{"kiro":"real-model"}}
        """
        try Data(linuxJSON.utf8).write(to: url)

        let decoded = CostHistoryStore.read(url: url)
        XCTAssertEqual(decoded.scannedAt?["kiro"], millis)
        XCTAssertEqual(decoded.countingRevision?["kiro"], 2)
        XCTAssertEqual(decoded.topModels?["kiro"], "real-model")

        let receipt = CostHistoryStore.applyWithReceipt(
            source: .claude,
            liveDays: [(now, 1, 10, [("claude-model", 1, 10)])],
            now: now,
            url: url,
            liveScanSucceeded: true)
        XCTAssertTrue(receipt.persisted)
        let rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(rootObject["scanned_at"])
        XCTAssertNotNil(rootObject["counting_revision"])
        XCTAssertNotNil(rootObject["top_models"])
        XCTAssertNil(rootObject["scannedAt"])
        XCTAssertNil(rootObject["countingRevision"])
        XCTAssertNil(rootObject["topModels"])
        XCTAssertEqual(
            (rootObject["counting_revision"] as? [String: Int])?["kiro"], 2)

        let legacyJSON = """
        {"version":1,"sources":{},"scannedAt":{"grok":1},
         "countingRevision":{"grok":3},"topModels":{"grok":"grok-model"}}
        """
        let legacy = try JSONDecoder().decode(
            CostHistoryStore.Document.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.scannedAt?["grok"], 1)
        XCTAssertEqual(legacy.countingRevision?["grok"], 3)
        XCTAssertEqual(legacy.topModels?["grok"], "grok-model")
        let canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNotNil(canonical["scanned_at"])
        XCTAssertNotNil(canonical["counting_revision"])
        XCTAssertNotNil(canonical["top_models"])
    }

    /// `apply(liveScanSucceeded: true)` stamps `scannedAt`; a later
    /// history-only cycle (`liveScanSucceeded: false`, e.g. the popover's
    /// `seededReport`) must see the SAME stamp and report `live == false`,
    /// `included == true` — never a fresh timestamp, never unavailable.
    func testCostHistoryConfidenceLiveApplyThenHistoryOnlyKeepsTimestamp() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let now = Date()

        _ = CostHistoryStore.apply(
            source: .codex,
            liveDays: [(now, 1.0, 100, [("gpt-5", 1.0, 100)])],
            now: now, url: url, liveScanSucceeded: true)
        let live = CostHistoryStore.confidence(source: .codex, liveScanSucceeded: true, url: url)
        XCTAssertTrue(live.included)
        XCTAssertTrue(live.live)
        let stampedAt = try XCTUnwrap(live.scannedAt)

        // Next cycle's scanner found nothing readable — history-only fallback.
        let historyOnly = CostHistoryStore.confidence(source: .codex, liveScanSucceeded: false, url: url)
        XCTAssertTrue(historyOnly.included, "prior history keeps the source included")
        XCTAssertFalse(historyOnly.live, "no scan ran this cycle")
        XCTAssertEqual(historyOnly.scannedAt, stampedAt)
    }

    /// A source untouched by any scan (never live, no persisted history)
    /// reads back as fully unavailable — not merely history-only.
    func testCostHistoryConfidenceUnavailableWithoutHistory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")

        let confidence = CostHistoryStore.confidence(source: .grok, liveScanSucceeded: false, url: url)
        XCTAssertFalse(confidence.included)
        XCTAssertFalse(confidence.live)
        XCTAssertNil(confidence.scannedAt)
    }

    /// `replacingSource: true` writes live totals even when lower than the
    /// stored high-water mark, and drops stored days absent from live —
    /// without an intermediate empty-source file write.
    func testCostHistoryApplyReplacingSourceOverwritesLowerTotals() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        _ = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (yesterday, 10.0, 1000, [("claude-opus", 10.0, 1000)]),
                (today, 5.0, 1000, [("claude-sonnet", 5.0, 1000)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)

        // Replace with lower today; omit yesterday entirely.
        let window = CostHistoryStore.apply(
            source: .claude,
            liveDays: [
                (today, 1.0, 100, [("claude-sonnet", 1.0, 100)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url,
            replacingSource: true)

        // Lower live totals win (not preferHigher's 1000).
        XCTAssertEqual(window.last?.tokens ?? -1, 100)
        XCTAssertEqual(window.last?.usd ?? -1, 1.0, accuracy: 0.001)
        // Day absent from live is gone (not kept as high-water).
        XCTAssertEqual(window[window.count - 2].tokens, 0)
        XCTAssertEqual(window[window.count - 2].usd, 0, accuracy: 0.001)

        // Disk matches: only today under claude; other sources untouched.
        let stored = CostHistoryStore.read(url: url).sources?["claude"] ?? [:]
        XCTAssertEqual(stored[CostHistoryStore.dayKey(today, calendar: cal)]?.tokens, 100)
        XCTAssertNil(stored[CostHistoryStore.dayKey(yesterday, calendar: cal)])
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
        // Lần đầu trên một kho chưa từng quét sâu → nới rộng để bắt ghi trễ.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: fresh),
            CostHistoryStore.deepScanDays)
        // Lập plan không được tiêu nhịp khi scan/persist chưa thành công.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: fresh),
            CostHistoryStore.deepScanDays)
        CostHistoryStore.markDeepScanSucceeded(source: .claude, at: now, url: fresh)
        // Chỉ sau acknowledgement thành công mới về cửa sổ thường ngày.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: fresh),
            CostHistoryStore.routineScanDays)
        // Same file, source without history → still full scan.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .codex, now: now, calendar: cal, url: fresh), 90)

        let stale = dir.appendingPathComponent("stale.json")
        store(latestDaysAgo: 20, url: stale)
        // Lần đầu là quét sâu: 30 đã phủ trọn khoảng trống 20 ngày.
        XCTAssertEqual(
            CostHistoryStore.scanBackDays(source: .claude, now: now, calendar: cal, url: stale),
            CostHistoryStore.deepScanDays)
        CostHistoryStore.markDeepScanSucceeded(source: .claude, at: now, url: stale)
        // Sau khi đã quét sâu, khoảng trống thật quyết định — không bị bóp về sàn.
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
    /// Full lifetime T = before + context (CodexBar / Linux semantics).
    func testGrokCostScannerParseSignalsFixture() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent(
            "sessions/-Users-alice-work-birdnion/sess-1")
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
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))",\
        "git_root_dir":"/Users/alice/work/birdnion"}
        """
        try summary.write(to: session.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)

        let result = GrokCostScanner.scanFullWithProjects(
            homeURL: base, now: now, windowDays: 90)
        let report = result.report
        XCTAssertEqual(report.todayTokens, 1_000_000)
        XCTAssertEqual(report.todayUSD, 3.0, accuracy: 0.01) // 1M × $3 blended
        XCTAssertEqual(report.last30Tokens, 1_000_000)
        XCTAssertEqual(report.topModel, "grok-4.5")
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(
            result.projects.first?.projectKey,
            "14831731d7a097d36f08d9c315a0c126f9d3b71f2c9ba621c6797916bd91c248")
        XCTAssertEqual(result.projects.first?.displayName, "birdnion")
        XCTAssertEqual(result.projects.first?.attribution, .derived)
        XCTAssertEqual(result.projects.first?.daily.first?.tokens, report.last30Tokens)
        XCTAssertFalse(result.projects.first?.displayName.contains("/Users/alice") == true)
        XCTAssertTrue(result.completed)
    }

    /// events.jsonl bị từ chối không phải là "không có event". Không được
    /// dồn toàn bộ lifetime token vào ngày active rồi công bố scan complete.
    func testGrokOversizedEventsMarksScanIncompleteWithoutLifetimeFallback() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent("sessions/project/session")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        try Data("""
        {"contextTokensUsed":1000000,"primaryModelId":"grok-4.5"}
        """.utf8).write(to: session.appendingPathComponent("signals.json"))
        try Data("""
        {"last_active_at":"\(iso)","git_root_dir":"/tmp/project"}
        """.utf8).write(to: session.appendingPathComponent("summary.json"))

        let events = session.appendingPathComponent("events.jsonl")
        XCTAssertTrue(fm.createFile(atPath: events.path, contents: nil))
        let handle = try FileHandle(forWritingTo: events)
        try handle.truncate(atOffset: UInt64(GrokCostScanner.maxSessionFileBytes + 1))
        try handle.close()

        let result = GrokCostScanner.scanFullWithProjects(
            homeURL: base, now: now, windowDays: 30)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.report.last30Tokens, 0)
        XCTAssertTrue(result.projects.isEmpty)
    }

    /// Claude phải trả partial/incomplete nếu transcript vượt giới hạn,
    /// không được coi projection rỗng là một full scan thành công.
    func testClaudeOversizedTranscriptMarksScanIncomplete() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let transcript = root.appendingPathComponent("oversized.jsonl")
        XCTAssertTrue(fm.createFile(atPath: transcript.path, contents: nil))
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: UInt64(ClaudeCostScanner.maxSessionFileBytes + 1))
        try handle.close()

        let result = try XCTUnwrap(
            ClaudeCostScanner.scanFullWithProjects(roots: [root], now: Date(), scanDays: 30))
        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.report.isEmpty)
        XCTAssertTrue(result.projects.isEmpty)
    }

    /// Traversal budget phải đếm mọi entry, kể cả file không phải JSONL;
    /// nếu không một cây rác lớn vẫn có thể walk vô hạn.
    func testClaudeTraversalBudgetCountsNonTranscriptEntries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("first.txt"))
        try Data().write(to: root.appendingPathComponent("second.txt"))

        let result = try XCTUnwrap(ClaudeCostScanner.scanFullWithProjects(
            roots: [root], now: Date(), scanDays: 30, maxWalkEntries: 1))

        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.report.isEmpty)
    }

    func testGrokProjectFallbackKeepsAggregateAndHidesEncodedDirectory() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let encoded = "-Users-alice-Secret-Client"
        let session = base.appendingPathComponent("sessions/\(encoded)/sess-1")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let now = Date()
        let iso = ISO8601DateFormatter()
        let summary = """
        {"last_active_at":"\(iso.string(from: now))","git_root_dir":"relative/private"}
        """
        try summary.write(
            to: session.appendingPathComponent("summary.json"),
            atomically: true, encoding: .utf8)
        try Data("""
        {"contextTokensUsed":250000,"primaryModelId":"grok-4.5"}
        """.utf8).write(to: session.appendingPathComponent("signals.json"))

        let result = GrokCostScanner.scanFullWithProjects(
            homeURL: base, now: now, windowDays: 30)

        XCTAssertEqual(result.report.last30Tokens, 250_000)
        XCTAssertEqual(result.projects.first?.daily.first?.tokens, 250_000)
        XCTAssertTrue(result.projects.first?.displayName.hasPrefix("Grok Project ") == true)
        XCTAssertFalse(result.projects.first?.displayName.contains("alice") == true)
        XCTAssertFalse(result.projects.first?.projectKey.contains(encoded) == true)
    }

    func testGrokMalformedSessionShapesStayInUnknownResidual() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let malformedSessions = [
            base.appendingPathComponent("sessions/token/nested/session"),
            base.appendingPathComponent("sessions/token\\private/session"),
        ]
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        for (index, session) in malformedSessions.enumerated() {
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            try Data("""
            {"contextTokensUsed":\((index + 1) * 100000),"primaryModelId":"grok-4.5"}
            """.utf8).write(to: session.appendingPathComponent("signals.json"))
            try Data("""
            {"last_active_at":"\(iso)","git_root_dir":"/Users/alice/private"}
            """.utf8).write(to: session.appendingPathComponent("summary.json"))
        }

        let result = GrokCostScanner.scanFullWithProjects(
            homeURL: base, now: now, windowDays: 30)

        XCTAssertEqual(result.report.last30Tokens, 300_000)
        XCTAssertTrue(result.projects.isEmpty)
    }

    // MARK: - scanFullIfAvailable: missing root vs genuinely-empty (reviewer Finding 1)
    //
    // Root cause: `usageReport` hardcoded `liveScanSucceeded: true` because
    // `scanFull` never returns nil — so when `~/.grok/sessions` doesn't exist
    // at all (Grok never installed), the UI showed a false "Live" badge.
    // `scanFullIfAvailable` distinguishes "root missing" (nil) from "root
    // exists but has zero sessions" (a real, live-eligible zero report).

    /// A completely missing sessions root must return `nil` — not a
    /// zero-value report — so the caller can report `liveScanSucceeded: false`
    /// instead of a false "Live" badge.
    func testScanFullIfAvailableReturnsNilWhenSessionsRootMissing() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Intentionally never created — simulates Grok never having been
        // installed (or `GROK_HOME` pointing at a home that doesn't exist).
        defer { try? fm.removeItem(at: home) }

        XCTAssertNil(GrokCostScanner.scanFullIfAvailable(homeURL: home, now: Date()))
    }

    /// A sessions directory that exists but genuinely has no session files
    /// is a valid, completed live scan (a zero-value report) — not an
    /// unavailable one.
    func testScanFullIfAvailableReturnsReportWhenSessionsDirEmpty() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsDir = home.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let report = GrokCostScanner.scanFullIfAvailable(homeURL: home, now: Date())
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.todayTokens, 0)
        XCTAssertEqual(report?.isEmpty, true)
    }

    /// Full-T attribution (CodexBar/Linux): each scan reports the current
    /// lifetime total, is idempotent across rescans, grows with T, and
    /// follows compaction dips to the new snapshot T.
    func testGrokCostScannerFullTIdempotentAndGrowth() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent("sessions/proj/sess-full")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = """
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))"}
        """
        try summary.write(to: session.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)

        func writeSignals(before: Int, context: Int) throws {
            let signals = """
            {"totalTokensBeforeCompaction":\(before),"contextTokensUsed":\(context),\
            "modelsUsed":["grok-4.5"],"primaryModelId":"grok-4.5"}
            """
            try signals.write(to: session.appendingPathComponent("signals.json"),
                              atomically: true, encoding: .utf8)
        }

        try writeSignals(before: 800_000, context: 200_000)
        let first = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(first.todayTokens, 1_000_000)

        // Second scan, same T → same full lifetime (idempotent live report).
        let second = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(second.todayTokens, 1_000_000)
        XCTAssertEqual(second.last30Tokens, 1_000_000)

        // Growth: full current T, not only the increase.
        try writeSignals(before: 900_000, context: 300_000) // T = 1_200_000
        let growth = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(growth.todayTokens, 1_200_000)

        // Dip after compaction: report current snapshot T (CodexBar).
        try writeSignals(before: 1_100_000, context: 50_000) // T = 1_150_000
        let dip = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(dip.todayTokens, 1_150_000)

        // preferHigher on history keeps the prior high-water when live dips.
        let histURL = base.appendingPathComponent("cost-history.json")
        _ = CostHistoryStore.apply(
            source: .grok,
            liveDays: growth.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            },
            now: now, windowDays: 90, url: histURL)
        let afterDip = CostHistoryStore.apply(
            source: .grok,
            liveDays: dip.daily.map {
                ($0.date, $0.usd, $0.tokens,
                 $0.models.map { (name: $0.name, usd: $0.usd, tokens: $0.tokens) })
            },
            now: now, windowDays: 90, url: histURL)
        XCTAssertEqual(afterDip.last?.tokens, 1_200_000)
    }

    /// Sum of two sessions' full T on the same last-active day.
    func testGrokCostScannerSumsMultipleSessionsFullT() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = """
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))"}
        """

        for (name, before, context) in [("a", 500_000, 100_000), ("b", 200_000, 50_000)] {
            let session = base.appendingPathComponent("sessions/proj/\(name)")
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            try summary.write(to: session.appendingPathComponent("summary.json"),
                              atomically: true, encoding: .utf8)
            let signals = """
            {"totalTokensBeforeCompaction":\(before),"contextTokensUsed":\(context),\
            "modelsUsed":["grok-4.5"],"primaryModelId":"grok-4.5"}
            """
            try signals.write(to: session.appendingPathComponent("signals.json"),
                              atomically: true, encoding: .utf8)
        }

        let report = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)
        XCTAssertEqual(report.todayTokens, 850_000)
    }

    /// `replacingSource: true` on Grok clears inflated multi-day double-count
    /// days (pattern matches Claude revision reset).
    func testGrokCostHistoryReplacingSourceClearsInflatedDays() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Simulate pre-fix double-count: full lifetime on both days.
        _ = CostHistoryStore.apply(
            source: .grok,
            liveDays: [
                (yesterday, 7.71, 2_570_000, [("grok-4.5", 7.71, 2_570_000)]),
                (today, 7.71, 2_570_000, [("grok-4.5", 7.71, 2_570_000)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url)

        // One-shot reset: full-T once at last-active (today only).
        // Atomic replace, no empty intermediate.
        let window = CostHistoryStore.apply(
            source: .grok,
            liveDays: [
                (today, 7.71, 2_570_000, [("grok-4.5", 7.71, 2_570_000)]),
            ],
            now: now, calendar: cal, windowDays: 90, url: url,
            replacingSource: true)

        XCTAssertEqual(window.last?.tokens ?? -1, 2_570_000)
        XCTAssertEqual(window[window.count - 2].tokens, 0)

        let stored = CostHistoryStore.read(url: url).sources?["grok"] ?? [:]
        XCTAssertEqual(stored[CostHistoryStore.dayKey(today, calendar: cal)]?.tokens, 2_570_000)
        XCTAssertNil(stored[CostHistoryStore.dayKey(yesterday, calendar: cal)])
    }

    /// Rev 3 regression (2026-08-25): a session merely OPENED today (bumping
    /// `last_active_at`) but whose real turns happened on earlier days must
    /// not dump its whole lifetime total onto today. `events.jsonl`
    /// (`first_token` timestamps) gives real per-day evidence to split the
    /// total instead — today gets exactly zero, the earlier days get the
    /// split, and the parts still sum to exactly the lifetime total. Fails
    /// under the pre-fix "attribute T to the last-active day" behavior,
    /// which would put all 100,000 tokens on today instead.
    func testGrokEventsApportionTokensAcrossTheirOwnDaysNotLastActiveDay() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent("sessions/proj/sess-timeline")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let fiveDaysAgo = cal.date(byAdding: .day, value: -5, to: today)!
        let fourDaysAgo = cal.date(byAdding: .day, value: -4, to: today)!

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // last_active_at is "now" (today), but T = 100_000 was earned on two
        // earlier days: 75% five days ago, 25% four days ago.
        let summary = """
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))"}
        """
        try summary.write(to: session.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)
        let signals = """
        {"totalTokensBeforeCompaction":75000,"contextTokensUsed":25000,"primaryModelId":"grok-4.5"}
        """
        try signals.write(to: session.appendingPathComponent("signals.json"),
                          atomically: true, encoding: .utf8)

        var events = ""
        let t5 = fiveDaysAgo.addingTimeInterval(10 * 3600)
        let t4 = fourDaysAgo.addingTimeInterval(10 * 3600)
        for _ in 0..<75 {
            events += "{\"ts\":\"\(iso.string(from: t5))\",\"type\":\"first_token\"}\n"
        }
        for _ in 0..<25 {
            events += "{\"ts\":\"\(iso.string(from: t4))\",\"type\":\"first_token\"}\n"
        }
        try events.write(to: session.appendingPathComponent("events.jsonl"),
                         atomically: true, encoding: .utf8)

        let report = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)

        XCTAssertEqual(report.todayTokens, 0, "today has zero first_token events, so it must get zero tokens")
        func tokens(daysAgo: Int) -> Int {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            return report.daily.first { $0.date == day }?.tokens ?? 0
        }
        XCTAssertEqual(tokens(daysAgo: 5), 75_000)
        XCTAssertEqual(tokens(daysAgo: 4), 25_000)
        let total = report.daily.map(\.tokens).reduce(0, +)
        XCTAssertEqual(total, 100_000, "split must sum to exactly the lifetime total")
    }

    /// Rev 3 companion: without `events.jsonl` there is no evidence better
    /// than "last active day" — the full lifetime total must still land
    /// there entirely rather than inventing a distribution.
    func testGrokSessionWithoutEventsFileStillLandsOnLastActiveDay() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = base.appendingPathComponent("sessions/proj/sess-no-events")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = """
        {"current_model_id":"grok-4.5","last_active_at":"\(iso.string(from: now))"}
        """
        try summary.write(to: session.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)
        let signals = """
        {"totalTokensBeforeCompaction":75000,"contextTokensUsed":25000,"primaryModelId":"grok-4.5"}
        """
        try signals.write(to: session.appendingPathComponent("signals.json"),
                          atomically: true, encoding: .utf8)
        // Deliberately no events.jsonl written.

        let report = GrokCostScanner.scanFull(homeURL: base, now: now, windowDays: 90)

        XCTAssertEqual(report.todayTokens, 100_000)
        XCTAssertEqual(report.last30Tokens, 100_000)
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
        let report = KiroCostScanner.buildReport(sessions: sessions, now: now, calendar: cal)
        XCTAssertEqual(KiroCostScanner.chartWindowDays, 120)
        XCTAssertEqual(report.daily.count, 120)
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

    func testKiroBuildReportPreservesGlobalTopAndDailyModelTotals() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        var sessions: [KiroCostScanner.SessionPoint] = []
        for offset in 0..<30 {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            for rank in 0..<7 {
                sessions.append(.init(
                    day: day,
                    tokens: 100,
                    usd: 0.01,
                    model: "burst-\(offset)-\(rank)"))
            }
            sessions.append(.init(day: day, tokens: 90, usd: 0.009, model: "steady"))
        }

        let report = KiroCostScanner.buildReport(
            sessions: sessions, now: now, windowDays: 120, calendar: cal)

        XCTAssertEqual(report.topModel, "steady")
        for day in report.daily.suffix(30) {
            XCTAssertEqual(day.tokens, 790)
            XCTAssertEqual(day.models.map(\.tokens).reduce(0, +), day.tokens)
            XCTAssertEqual(day.models.map(\.usd).reduce(0, +), day.usd, accuracy: 0.000_001)
            XCTAssertTrue(day.models.contains(where: { $0.name == "steady" }))
            XCTAssertTrue(day.models.contains(where: { $0.name == "Other" }))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-top-model-\(UUID().uuidString)",
            isDirectory: true)
        let historyURL = root.appendingPathComponent("cost-history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let merged = KiroCostScanner.mergeLiveReport(
            report, now: now, historyURL: historyURL)
        XCTAssertEqual(merged.topModel, "steady")
        XCTAssertEqual(CostHistoryStore.storedTopModel(
            source: .kiro, url: historyURL), "steady")
    }

    func testKiroRejectsUsageBeyondClockSkewOnSameCalendarDay() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = try XCTUnwrap(cal.date(byAdding: .hour, value: 9, to: today))
        let future = try XCTUnwrap(cal.date(byAdding: .hour, value: 2, to: now))
        XCTAssertTrue(cal.isDate(future, inSameDayAs: now))
        let iso = ISO8601DateFormatter()
        let nowISO = iso.string(from: now)
        let futureISO = iso.string(from: future)
        let sidecar: [String: Any] = [
            "session_id": "same-day-future",
            "created_at": nowISO,
            "session_state": [
                "rts_model_state": ["model_info": ["model_id": "claude-sonnet-4-5"]],
                "conversation_metadata": ["user_turn_metadatas": [[
                    "metering_usage": [["unit": "credit", "value": 1.0]],
                    "input_token_count": 10,
                    "output_token_count": 5,
                    "end_timestamp": futureISO,
                ]]],
            ],
        ]
        XCTAssertTrue(KiroCostScanner.parseCLISessionSidecar(
            sidecar, cutoff: today, now: now, calendar: cal).isEmpty)

        let futureMs = Int64(future.timeIntervalSince1970 * 1_000)
        let conversation: [String: Any] = [
            "history": [[
                "user": "future request",
                "request_metadata": [
                    "model_id": "claude-sonnet-4-5",
                    "request_start_timestamp_ms": futureMs,
                ],
            ]],
        ]
        XCTAssertNil(KiroCostScanner.parseConversation(
            data: conversation,
            fallbackCreatedMs: Int64(now.timeIntervalSince1970 * 1_000),
            cutoff: today,
            now: now,
            calendar: cal))
    }

    func testKiroRejectsSQLiteStorageBeyondGlobalScanBudgetBeforeQuery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-sqlite-budget-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("data.sqlite3")
        XCTAssertTrue(FileManager.default.createFile(atPath: dbURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: dbURL)
        try handle.truncate(atOffset: UInt64(256 * 1024 * 1024 + 1))
        try handle.close()

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: dbURL,
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: Date())

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["sqlite"])
        XCTAssertEqual(result.report.last30Tokens, 0)
    }

    func testKiroRejectsSymlinkedSQLiteDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-sqlite-symlink-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("outside.sqlite3")
        let dbURL = root.appendingPathComponent("data.sqlite3")
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let payload = """
        {"conversation_id":"redirected-sqlite","history":[{"user":"redirected usage","request_metadata":{"request_start_timestamp_ms":\(nowMs)}}]}
        """
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(target.path, &db), SQLITE_OK)
        let opened = try XCTUnwrap(db)
        for statement in [
            "CREATE TABLE conversations (value TEXT NOT NULL)",
            "INSERT INTO conversations (value) VALUES ('\(payload)')",
        ] {
            XCTAssertEqual(sqlite3_exec(opened, statement, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(opened)
        try FileManager.default.createSymbolicLink(at: dbURL, withDestinationURL: target)

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: dbURL,
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["sqlite"])
        XCTAssertEqual(result.report.last30Tokens, 0)
    }

    func testKiroRejectsSymlinkedArchiveAndCLIRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-root-symlinks-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveTarget = root.appendingPathComponent("outside-archive", isDirectory: true)
        let cliTarget = root.appendingPathComponent("outside-cli", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try JSONSerialization.data(withJSONObject: [
            "conversation_id": "redirected-archive",
            "created_at": nowMs,
            "updated_at": nowMs,
            "history": [[
                "user": "redirected archive usage",
                "request_metadata": ["request_start_timestamp_ms": nowMs],
            ]],
        ]).write(to: archiveTarget.appendingPathComponent("redirected.json"))
        let timestamp = ISO8601DateFormatter().string(from: now)
        try JSONSerialization.data(withJSONObject: [
            "session_id": "redirected-cli",
            "created_at": timestamp,
            "updated_at": timestamp,
            "session_state": [
                "conversation_metadata": ["user_turn_metadatas": [[
                    "metering_usage": [["unit": "credit", "value": 1.0]],
                    "input_token_count": 10,
                    "output_token_count": 5,
                    "end_timestamp": timestamp,
                ]]],
            ],
        ]).write(to: cliTarget.appendingPathComponent("redirected.json"))
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: archiveTarget)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("cli", isDirectory: true),
            withDestinationURL: cliTarget)

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: sessions,
            now: now)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["archive", "cli"])
        XCTAssertEqual(result.report.last30Tokens, 0)
    }

    func testKiroLiveMergePersistsFreshnessTimestamp() throws {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let live = KiroCostScanner.buildReport(
            sessions: [.init(day: today, tokens: 1_000, usd: 0.04, model: "kiro/model")],
            now: now,
            windowDays: 90,
            calendar: cal)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-confidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("cost-history.json")

        let merged = KiroCostScanner.mergeLiveReport(live, now: now, historyURL: historyURL)

        XCTAssertTrue(merged.scanConfidence.included)
        XCTAssertTrue(merged.scanConfidence.live)
        XCTAssertEqual(try XCTUnwrap(merged.scanConfidence.scannedAt).timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testKiroCountingMigrationRescans120DaysAndReplacesLegacyTokenMath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-counting-migration-\(UUID().uuidString)",
                                   isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("cost-history.json")
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let oldDay = calendar.date(byAdding: .day, value: -100, to: today)!
        let oldActivity = calendar.date(byAdding: .hour, value: 12, to: oldDay)!
        let oldMs = Int64(oldActivity.timeIntervalSince1970 * 1_000)

        _ = CostHistoryStore.apply(
            source: .kiro,
            liveDays: [(today, 1, 999, [("legacy", 1, 999)])],
            now: now,
            calendar: calendar,
            windowDays: KiroCostScanner.chartWindowDays,
            url: historyURL,
            liveScanSucceeded: true)
        let incrementalDays = CostHistoryStore.scanBackDays(
            source: .kiro,
            now: now,
            calendar: calendar,
            maxDays: KiroCostScanner.chartWindowDays,
            url: historyURL)
        // Kho tạm chưa có dấu quét sâu nên lần gọi đầu nới rộng; điều test quan
        // tâm là `replacing`, không phải con số cửa sổ.
        XCTAssertEqual(incrementalDays, CostHistoryStore.deepScanDays)
        let plan = KiroCostScanner.countingScanPlan(
            storedRevision: KiroCostScanner.countingRevision - 1,
            incrementalDays: incrementalDays)
        XCTAssertTrue(plan.replacing)
        XCTAssertFalse(plan.historyOnly)
        XCTAssertEqual(plan.windowDays, 120)

        try JSONSerialization.data(withJSONObject: [
            "conversation_id": "old-utf8-session",
            "created_at": oldMs,
            "updated_at": oldMs,
            "history": [[
                "user": String(repeating: "👨‍👩‍👧‍👦", count: 4),
                "request_metadata": ["request_start_timestamp_ms": oldMs],
            ]],
        ]).write(to: archive.appendingPathComponent("old-utf8-session.json"))
        let scan = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now,
            windowDays: plan.windowDays,
            calendar: calendar)
        XCTAssertTrue(scan.completed)

        let merged = KiroCostScanner.mergeLiveReport(
            scan.report,
            now: now,
            historyURL: historyURL,
            replacingSource: plan.replacing,
            liveScanSucceeded: scan.completed)
        let migratedDay = try XCTUnwrap(merged.daily.first {
            calendar.isDate($0.date, inSameDayAs: oldDay)
        })
        XCTAssertEqual(migratedDay.tokens, 25)
        XCTAssertEqual(merged.todayTokens, 0)
        let stored = CostHistoryStore.read(url: historyURL).sources?["kiro"] ?? [:]
        XCTAssertNil(stored[CostHistoryStore.dayKey(today, calendar: calendar)])
        XCTAssertEqual(stored[CostHistoryStore.dayKey(oldDay, calendar: calendar)]?.tokens, 25)
    }

    func testKiroFutureCountingRevisionIsHistoryOnlyAndNeverDowngraded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-future-revision-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("cost-history.json")
        let now = Date()
        let futureRevision = KiroCostScanner.countingRevision + 1

        let seeded = CostHistoryStore.applyWithReceipt(
            source: .kiro,
            liveDays: [(now, 9, 900, [("future-model", 9, 900)])],
            now: now,
            windowDays: KiroCostScanner.chartWindowDays,
            url: historyURL,
            replacingSource: true,
            liveScanSucceeded: true,
            updateTopModel: true,
            topModel: "future-model",
            countingRevision: futureRevision)
        XCTAssertTrue(seeded.persisted)

        let plan = KiroCostScanner.countingScanPlan(
            storedRevision: futureRevision,
            incrementalDays: 7)
        XCTAssertTrue(plan.historyOnly)
        XCTAssertFalse(plan.replacing)
        XCTAssertEqual(plan.windowDays, 7)

        let olderLive = KiroCostScanner.buildReport(
            sessions: [.init(day: now, tokens: 1, usd: 0.01, model: "older-model")],
            now: now,
            windowDays: KiroCostScanner.chartWindowDays,
            calendar: .current)
        let merged = KiroCostScanner.mergeLiveReport(
            olderLive,
            now: now,
            historyURL: historyURL,
            replacingSource: false,
            liveScanSucceeded: true)

        XCTAssertEqual(merged.todayTokens, 900)
        XCTAssertEqual(merged.topModel, "future-model")
        XCTAssertFalse(merged.scanConfidence.live)
        XCTAssertEqual(
            CostHistoryStore.storedCountingRevision(source: .kiro, url: historyURL),
            futureRevision)
        let stored = CostHistoryStore.read(url: historyURL)
        XCTAssertFalse(stored.sources?["kiro"]?.values.contains {
            $0.models.contains(where: { $0.name == "older-model" })
        } ?? false)
    }

    func testKiroHistoryOnlyIgnoresSyntheticOtherTopModelMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-other-metadata-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let dayKey = CostHistoryStore.dayKey(now, calendar: .current)

        for metadataKey in ["top_models", "topModels"] {
            let historyURL = root.appendingPathComponent("\(metadataKey).json")
            let document: [String: Any] = [
                "version": 1,
                "sources": [
                    "kiro": [
                        dayKey: [
                            "usd": 2.8,
                            "tokens": 280,
                            "models": [
                                ["name": "real-model", "usd": 1.0, "tokens": 100],
                                ["name": "Other", "usd": 1.8, "tokens": 180],
                            ],
                        ],
                    ],
                ],
                metadataKey: ["kiro": "Other"],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: historyURL)

            let seeded = await KiroCostScanner.seededReport(now: now, url: historyURL)
            let report = try XCTUnwrap(seeded)
            XCTAssertEqual(report.topModel, "real-model", metadataKey)
            XCTAssertFalse(report.scanConfidence.live)
        }
    }

    func testNonKiroOtherModelRemainsEligibleForTopModel() {
        let day = Date()
        let window = [CostHistoryStore.DayBucket(
            date: day,
            usd: 2,
            tokens: 200,
            models: [
                .init(name: "Other", usd: 1.8, tokens: 180),
                .init(name: "named-model", usd: 0.2, tokens: 20),
            ])]

        XCTAssertEqual(CostHistoryStore.makeCodexReport(window: window).topModel, "Other")
        XCTAssertEqual(CostHistoryStore.makeGrokReport(window: window).topModel, "Other")
        XCTAssertEqual(CostHistoryStore.makeKiroReport(window: window).topModel, "named-model")
    }

    func testKiroReadableEmptyRecordsAreNotLiveEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-empty-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cli = sessions.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let emptyConversation: [String: Any] = [
            "conversation_id": "empty-archive",
            "updated_at": Int64(now.timeIntervalSince1970 * 1_000),
            "history": [Any](),
        ]
        try JSONSerialization.data(withJSONObject: emptyConversation)
            .write(to: archive.appendingPathComponent("empty.json"))
        let emptySidecar: [String: Any] = [
            "session_id": "empty-cli",
            "session_state": [
                "conversation_metadata": ["user_turn_metadatas": [Any]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: emptySidecar)
            .write(to: cli.appendingPathComponent("empty.json"))

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: sessions,
            now: now)

        XCTAssertTrue(result.report.isEmpty)
        XCTAssertTrue(result.report.daily.allSatisfy { $0.tokens == 0 && $0.usd == 0 })
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.availableSources, ["archive", "cli"])
        XCTAssertEqual(result.failures, ["archive", "cli"])
    }

    func testKiroFIFOJSONFailsClosedWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-fifo-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = archive.appendingPathComponent("hang.json")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        let started = Date()
        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: Date())

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.availableSources, ["archive"])
        XCTAssertEqual(result.failures, ["archive"])
    }

    func testKiroEmptyContainersCannotMintCompletedLiveScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-empty-evidence-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()

        var result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.availableSources.isEmpty)

        let emptyConversation: [String: Any] = [
            "conversation_id": "empty-history",
            "created_at": Int64(now.timeIntervalSince1970 * 1_000),
            "updated_at": Int64(now.timeIntervalSince1970 * 1_000),
            "history": [],
        ]
        try JSONSerialization.data(withJSONObject: emptyConversation)
            .write(to: archive.appendingPathComponent("empty.json"))
        result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["archive"])
    }

    func testKiroLargeValidTurnWorkloadStaysWithinStructureBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-valid-large-workload-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let turns: [[String: Any]] = (0..<5_000).map { _ in
            [
                "end_timestamp": timestamp,
                "input_token_count": 1,
                "output_token_count": 0,
            ]
        }
        let sidecar: [String: Any] = [
            "session_id": "large-valid-workload",
            "session_state": [
                "conversation_metadata": ["user_turn_metadatas": turns],
            ],
        ]
        try JSONSerialization.data(withJSONObject: sidecar)
            .write(to: cli.appendingPathComponent("large.json"))

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.report.todayTokens, 5_000)
    }

    func testKiroReservesSyntheticOtherModelIdentity() {
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let sidecar: [String: Any] = [
            "session_id": "reserved-other",
            "session_state": [
                "rts_model_state": [
                    "model_info": ["model_id": KiroCostScanner.aggregateModelName],
                ],
                "conversation_metadata": [
                    "user_turn_metadatas": [[
                        "end_timestamp": timestamp,
                        "input_token_count": 1,
                    ]],
                ],
            ],
        ]
        XCTAssertTrue(KiroCostScanner.parseCLISessionSidecar(
            sidecar,
            cutoff: Calendar.current.startOfDay(for: now),
            now: now).isEmpty)
    }

    func testKiroCurrentCLISessionWithoutUpdatedAtWinsLegacyDuplicate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-cross-generation-\(UUID().uuidString)",
                                   isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cli = sessions.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let legacyDate = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let legacyMs = Int64(legacyDate.timeIntervalSince1970 * 1_000)
        try JSONSerialization.data(withJSONObject: [
            "conversation_id": "shared-session",
            "created_at": legacyMs,
            "updated_at": legacyMs,
            "history": [[
                "user": "stale legacy estimate",
                "request_metadata": ["request_start_timestamp_ms": legacyMs],
            ]],
        ]).write(to: archive.appendingPathComponent("shared-session.json"))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let currentTimestamp = iso.string(from: now.addingTimeInterval(-1))
        try JSONSerialization.data(withJSONObject: [
            "session_id": "shared-session",
            "created_at": currentTimestamp,
            "session_state": [
                "rts_model_state": [
                    "model_info": ["model_id": "claude-sonnet-4-5"],
                ],
                "conversation_metadata": [
                    "user_turn_metadatas": [[
                        "metering_usage": [["unit": "credit", "value": 10.0]],
                        "input_token_count": 100,
                        "output_token_count": 50,
                        "end_timestamp": currentTimestamp,
                    ]],
                ],
            ],
        ]).write(to: cli.appendingPathComponent("shared-session.json"))

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: sessions,
            now: now)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.report.todayTokens, 150)
        XCTAssertEqual(result.report.todayUSD, 0.4, accuracy: 0.000_001)
    }

    func testKiroMalformedAvailableSourceDowngradesCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-malformed-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: archive.appendingPathComponent("bad.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: Date())

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["archive"])
    }

    func testKiroSchemaInvalidArchiveDowngradesCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-schema-invalid-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let invalidConversation: [String: Any] = [
            "conversation_id": "empty-turn",
            "updated_at": Int64(now.timeIntervalSince1970 * 1_000),
            "history": [[String: Any]()],
        ]
        try JSONSerialization.data(withJSONObject: invalidConversation)
            .write(to: archive.appendingPathComponent("bad.json"))

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        let historyURL = root.appendingPathComponent("cost-history.json")
        let merged = KiroCostScanner.mergeLiveReport(
            result.report,
            now: now,
            historyURL: historyURL,
            liveScanSucceeded: result.completed)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["archive"])
        XCTAssertTrue(result.report.isEmpty)
        XCTAssertTrue(result.report.daily.allSatisfy { $0.tokens == 0 && $0.usd == 0 })
        XCTAssertTrue(merged.isEmpty)
        XCTAssertFalse(merged.scanConfidence.live)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testKiroSchemaInvalidCLISidecarDowngradesCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-cli-schema-invalid-\(UUID().uuidString)", isDirectory: true)
        let cli = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidSidecar: [String: Any] = [
            "session_id": "empty-session-state",
            "session_state": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: invalidSidecar)
            .write(to: cli.appendingPathComponent("bad.json"))
        let now = Date()

        let result = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        let historyURL = root.appendingPathComponent("cost-history.json")
        let merged = KiroCostScanner.mergeLiveReport(
            result.report,
            now: now,
            historyURL: historyURL,
            liveScanSucceeded: result.completed)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failures, ["cli"])
        XCTAssertTrue(result.report.isEmpty)
        XCTAssertTrue(result.report.daily.allSatisfy { $0.tokens == 0 && $0.usd == 0 })
        XCTAssertTrue(merged.isEmpty)
        XCTAssertFalse(merged.scanConfidence.live)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testKiroSemanticFieldTypesMatchParserContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-wrong-types-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try JSONSerialization.data(withJSONObject: [
            "conversation_id": "wrong-metadata-type",
            "updated_at": Int64(now.timeIntervalSince1970 * 1_000),
            "history": [["request_metadata": 1]],
        ]).write(to: archive.appendingPathComponent("bad.json"))

        let archiveResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(archiveResult.completed)
        XCTAssertEqual(archiveResult.failures, ["archive"])

        try FileManager.default.removeItem(at: archive)
        let cli = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "session_id": "wrong-timestamp-type",
            "session_state": [
                "conversation_metadata": [
                    "user_turn_metadatas": [["end_timestamp": 123]],
                ],
            ],
        ]).write(to: cli.appendingPathComponent("bad.json"))

        let cliResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(cliResult.completed)
        XCTAssertEqual(cliResult.failures, ["cli"])

        try FileManager.default.removeItem(at: cli.appendingPathComponent("bad.json"))
        let timestamp = ISO8601DateFormatter().string(from: now)
        let validIntegralFloat = """
        {
          "session_id": "integral-float",
          "session_state": {
            "conversation_metadata": {
              "user_turn_metadatas": [{
                "end_timestamp": "\(timestamp)",
                "input_token_count": 1.0,
                "output_token_count": 0
              }]
            },
            "rts_model_state": {
              "model_info": { "context_window_tokens": 0 }
            }
          }
        }
        """
        try Data(validIntegralFloat.utf8).write(to: cli.appendingPathComponent("valid.json"))
        let validResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertTrue(validResult.completed)
        XCTAssertEqual(validResult.report.todayTokens, 1)

        var consumedBytes = 0
        XCTAssertTrue(KiroCostScanner.admitSourceBytes(3, consumed: &consumedBytes, maximum: 5))
        XCTAssertTrue(KiroCostScanner.admitSourceBytes(2, consumed: &consumedBytes, maximum: 5))
        XCTAssertFalse(KiroCostScanner.admitSourceBytes(1, consumed: &consumedBytes, maximum: 5))

        try FileManager.default.removeItem(at: cli.appendingPathComponent("valid.json"))
        let oversizedModel: [String: Any] = [
            "session_id": "oversized-model",
            "session_state": [
                "rts_model_state": [
                    "model_info": ["model_id": String(repeating: "x", count: 513)],
                ],
                "conversation_metadata": [
                    "user_turn_metadatas": [[
                        "end_timestamp": timestamp,
                        "input_token_count": 1,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: oversizedModel)
            .write(to: cli.appendingPathComponent("oversized-model.json"))
        let oversizedModelResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(oversizedModelResult.completed)
        XCTAssertEqual(oversizedModelResult.failures, ["cli"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions"))
        let semanticArchive = root.appendingPathComponent("semantic-archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: semanticArchive, withIntermediateDirectories: true)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let emptyTurns: [[String: Any]] = [
            ["request_metadata": [:]],
            ["request_metadata": ["time_between_chunks": [Any]()]],
            ["request_metadata": ["model_id": ""]],
            ["request_metadata": ["request_start_timestamp_ms": nowMs]],
            ["user": ""],
            ["assistant": []],
            ["user": [:]],
        ]
        for (index, turn) in emptyTurns.enumerated() {
            let archiveValue: [String: Any] = [
                "conversation_id": "empty-semantic-\(index)",
                "created_at": nowMs,
                "updated_at": nowMs,
                "history": [turn],
            ]
            try JSONSerialization.data(withJSONObject: archiveValue)
                .write(to: semanticArchive.appendingPathComponent("fixture.json"))
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: root.appendingPathComponent("missing.sqlite3"),
                archiveURL: semanticArchive,
                sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
                now: now)
            XCTAssertFalse(result.completed, "empty semantic turn \(index)")
            XCTAssertEqual(result.failures, ["archive"], "empty semantic turn \(index)")
        }
        let validMixedTurns: [[String: Any]] = [
            [
                "user": "meaningful user request",
                "assistant": [Any](),
                "request_metadata": ["request_start_timestamp_ms": nowMs],
            ],
            [
                "user": [Any](),
                "assistant": "meaningful assistant response",
                "request_metadata": ["request_start_timestamp_ms": nowMs],
            ],
        ]
        for (index, turn) in validMixedTurns.enumerated() {
            let archiveValue: [String: Any] = [
                "conversation_id": "mixed-semantic-\(index)",
                "created_at": nowMs,
                "updated_at": nowMs,
                "history": [turn],
            ]
            try JSONSerialization.data(withJSONObject: archiveValue)
                .write(to: semanticArchive.appendingPathComponent("fixture.json"))
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: root.appendingPathComponent("missing.sqlite3"),
                archiveURL: semanticArchive,
                sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
                now: now)
            XCTAssertTrue(result.completed, "mixed semantic turn \(index)")
            XCTAssertGreaterThan(result.report.last30Tokens, 0, "mixed semantic turn \(index)")
        }
    }

    func testKiroRejectsCorruptCLISidecarsAndLegacyTimestamps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-numeric-corruption-\(UUID().uuidString)",
                                   isDirectory: true)
        let cli = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let future = ISO8601DateFormatter().string(
            from: Calendar.current.date(byAdding: .day, value: 2, to: now)!)
        let fixtures: [(String, [String: Any], [String: Any]?)] = [
            (
                "token-overflow",
                [
                    "end_timestamp": timestamp,
                    "input_token_count": 5.0e18,
                    "output_token_count": 5.0e18,
                ],
                nil
            ),
            (
                "percentage-overflow",
                [
                    "end_timestamp": timestamp,
                    "input_token_count": 0,
                    "output_token_count": 0,
                    "context_usage_percentage": 1.0e308,
                ],
                ["context_window_tokens": 10_000_000_000]
            ),
            (
                "context-window-overflow",
                [
                    "end_timestamp": timestamp,
                    "input_token_count": 0,
                    "output_token_count": 0,
                    "context_usage_percentage": 1,
                ],
                ["context_window_tokens": 10_000_000_001]
            ),
            (
                "credit-aggregate-overflow",
                [
                    "end_timestamp": timestamp,
                    "metering_usage": [
                        ["value": 750_000_000, "unit": "credit"],
                        ["value": 750_000_000, "unit": "credit"],
                    ],
                ],
                nil
            ),
            (
                "unsupported-token-aliases",
                [
                    "end_timestamp": timestamp,
                    "input_tokens_count": 100,
                    "output_tokens_count": 50,
                ],
                nil
            ),
            (
                "usage-without-timestamp",
                ["input_token_count": 100, "output_token_count": 0],
                nil
            ),
            (
                "future-usage-timestamp",
                [
                    "end_timestamp": future,
                    "input_token_count": 100,
                    "output_token_count": 0,
                ],
                nil
            ),
        ]

        for (name, turn, modelInfo) in fixtures {
            var state: [String: Any] = [
                "conversation_metadata": ["user_turn_metadatas": [turn]],
            ]
            if let modelInfo {
                state["rts_model_state"] = ["model_info": modelInfo]
            }
            let sidecar: [String: Any] = [
                "session_id": name,
                "session_state": state,
            ]
            let file = cli.appendingPathComponent("bad.json")
            try JSONSerialization.data(withJSONObject: sidecar).write(to: file)

            XCTAssertTrue(
                KiroCostScanner.parseCLISessionSidecar(sidecar, cutoff: now).isEmpty,
                name)
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: root.appendingPathComponent("missing.sqlite3"),
                archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
                sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
                now: now)
            XCTAssertFalse(result.completed, name)
            XCTAssertEqual(result.failures, ["cli"], name)
            try FileManager.default.removeItem(at: file)
        }

        let fallbackSidecar: [String: Any] = [
            "session_id": "valid-created-at-fallback",
            "created_at": timestamp,
            "session_state": [
                "conversation_metadata": [
                    "user_turn_metadatas": [[
                        "input_token_count": 7,
                        "output_token_count": 0,
                    ]],
                ],
            ],
        ]
        let fallbackFile = cli.appendingPathComponent("fallback.json")
        try JSONSerialization.data(withJSONObject: fallbackSidecar).write(to: fallbackFile)
        let fallbackResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertTrue(fallbackResult.completed)
        XCTAssertEqual(fallbackResult.report.todayTokens, 7)

        try FileManager.default.removeItem(at: fallbackFile)
        for (name, invalidUpdatedAt) in [
            ("malformed-cli-updated-at", "broken"),
            ("future-cli-updated-at", future),
        ] {
            var invalidUpdated = fallbackSidecar
            invalidUpdated["session_id"] = name
            invalidUpdated["updated_at"] = invalidUpdatedAt
            let invalidFile = cli.appendingPathComponent("invalid-updated.json")
            try JSONSerialization.data(withJSONObject: invalidUpdated).write(to: invalidFile)
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: root.appendingPathComponent("missing.sqlite3"),
                archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
                sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
                now: now)
            XCTAssertFalse(result.completed, name)
            XCTAssertEqual(result.failures, ["cli"], name)
            try FileManager.default.removeItem(at: invalidFile)
        }

        let oversizedCLI = cli.appendingPathComponent("oversized.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedCLI.path, contents: nil))
        let oversizedCLIHandle = try FileHandle(forWritingTo: oversizedCLI)
        try oversizedCLIHandle.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1))
        try oversizedCLIHandle.close()
        let oversizedCLIResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(oversizedCLIResult.completed)
        XCTAssertEqual(oversizedCLIResult.failures, ["cli"])

        try FileManager.default.removeItem(at: oversizedCLI)
        let excessiveTurns: [[String: Any]] = (0..<30_001).map { _ in
            [
                "end_timestamp": timestamp,
                "input_token_count": 1,
                "output_token_count": 0,
            ]
        }
        let excessiveStructure: [String: Any] = [
            "session_id": "excessive-structure",
            "session_state": [
                "conversation_metadata": ["user_turn_metadatas": excessiveTurns],
            ],
        ]
        let excessiveStructureURL = cli.appendingPathComponent("excessive-structure.json")
        try JSONSerialization.data(withJSONObject: excessiveStructure)
            .write(to: excessiveStructureURL)
        let excessiveStructureResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(excessiveStructureResult.completed)
        XCTAssertEqual(excessiveStructureResult.failures, ["cli"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions"))
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let archiveFile = archive.appendingPathComponent("legacy.json")
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let missingArchiveUpdatedAt: [String: Any] = [
            "conversation_id": "missing-archive-updated-at",
            "created_at": nowMs,
            "history": [[
                "user": "usage with request time",
                "request_metadata": ["request_start_timestamp_ms": nowMs],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: missingArchiveUpdatedAt).write(to: archiveFile)
        let missingArchiveUpdatedResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(missingArchiveUpdatedResult.completed)
        XCTAssertEqual(missingArchiveUpdatedResult.failures, ["archive"])

        let invalidArchiveUpdatedAt: [String: Any] = [
            "conversation_id": "invalid-archive-updated-at",
            "created_at": nowMs,
            "updated_at": "broken",
            "history": [[
                "user": "usage with request time",
                "request_metadata": ["request_start_timestamp_ms": nowMs],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: invalidArchiveUpdatedAt).write(to: archiveFile)
        let invalidArchiveUpdatedResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(invalidArchiveUpdatedResult.completed)
        XCTAssertEqual(invalidArchiveUpdatedResult.failures, ["archive"])

        let futureLegacyMs = Int64(
            Calendar.current.date(byAdding: .day, value: 2, to: now)!.timeIntervalSince1970
                * 1_000)
        for (name, timestampValue) in [
            ("invalid-zero-usage-timestamp", "broken" as Any),
            ("future-zero-usage-timestamp", futureLegacyMs as Any),
        ] {
            let invalidZeroUsageTimestamp: [String: Any] = [
                "conversation_id": name,
                "updated_at": nowMs,
                "history": [[
                    "user": "",
                    "request_metadata": ["request_start_timestamp_ms": timestampValue],
                ]],
            ]
            try JSONSerialization.data(withJSONObject: invalidZeroUsageTimestamp)
                .write(to: archiveFile)
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: root.appendingPathComponent("missing.sqlite3"),
                archiveURL: archive,
                sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
                now: now)
            XCTAssertFalse(result.completed, name)
            XCTAssertEqual(result.failures, ["archive"], name)
        }

        let missingLegacyTimestamp: [String: Any] = [
            "conversation_id": "missing-legacy-timestamp",
            "updated_at": nowMs,
            "history": [["user": "usage without time"]],
        ]
        try JSONSerialization.data(withJSONObject: missingLegacyTimestamp).write(to: archiveFile)
        let missingLegacyResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(missingLegacyResult.completed)
        XCTAssertEqual(missingLegacyResult.failures, ["archive"])

        try FileManager.default.removeItem(at: archiveFile)
        XCTAssertTrue(FileManager.default.createFile(atPath: archiveFile.path, contents: nil))
        let oversizedArchiveHandle = try FileHandle(forWritingTo: archiveFile)
        try oversizedArchiveHandle.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1))
        try oversizedArchiveHandle.close()
        let oversizedArchiveResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(oversizedArchiveResult.completed)
        XCTAssertEqual(oversizedArchiveResult.failures, ["archive"])

        let invalidLegacyTimestamp: [String: Any] = [
            "conversation_id": "invalid-legacy-request-timestamp",
            "created_at": nowMs,
            "updated_at": nowMs,
            "history": [[
                "user": "usage with invalid request time",
                "request_metadata": ["request_start_timestamp_ms": "broken"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: invalidLegacyTimestamp).write(to: archiveFile)
        let invalidLegacyResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(invalidLegacyResult.completed)
        XCTAssertEqual(invalidLegacyResult.failures, ["archive"])

        let validLegacyFallback: [String: Any] = [
            "conversation_id": "valid-legacy-fallback",
            "created_at": nowMs,
            "updated_at": nowMs,
            "history": [["user": "usage with outer time"]],
        ]
        try JSONSerialization.data(withJSONObject: validLegacyFallback).write(to: archiveFile)
        let validLegacyResult = KiroCostScanner.scanFullResult(
            cliDBURL: root.appendingPathComponent("missing.sqlite3"),
            archiveURL: archive,
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertTrue(validLegacyResult.completed)
        XCTAssertGreaterThan(validLegacyResult.report.todayTokens, 0)
    }

    func testKiroSQLiteV2MetadataAndSchemaDriftFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-sqlite-v2-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("data.sqlite3")
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let futureMs = Int64(now.addingTimeInterval(86_400 * 2).timeIntervalSince1970 * 1_000)
        let payload = """
        {"history":[{"user":"usage","request_metadata":{"request_start_timestamp_ms":\(nowMs)}}]}
        """

        func writeDatabase(_ statements: [String]) throws {
            try? FileManager.default.removeItem(at: dbURL)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
            let opened = try XCTUnwrap(db)
            defer { sqlite3_close(opened) }
            for statement in statements {
                var error: UnsafeMutablePointer<CChar>?
                let code = sqlite3_exec(opened, statement, nil, nil, &error)
                let message = error.map { String(cString: $0) } ?? ""
                if let error { sqlite3_free(error) }
                XCTAssertEqual(code, SQLITE_OK, message)
            }
        }

        let tableSQL = """
        CREATE TABLE conversations_v2 (
          conversation_id TEXT, created_at INTEGER, updated_at INTEGER, value TEXT
        )
        """
        for (name, created, updated) in [
            ("future-updated", nowMs, futureMs),
            ("future-created", futureMs, nowMs),
        ] {
            try writeDatabase([
                tableSQL,
                "INSERT INTO conversations_v2 VALUES ('\(name)', \(created), \(updated), '\(payload)')",
            ])
            let result = KiroCostScanner.scanFullResult(
                cliDBURL: dbURL,
                archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
                sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
                now: now)
            XCTAssertFalse(result.completed, name)
            XCTAssertEqual(result.failures, ["sqlite"], name)
        }

        try writeDatabase([
            "CREATE TABLE conversations (value TEXT NOT NULL)",
            "CREATE TABLE conversations_v2 (conversation_id TEXT, created_at INTEGER, value TEXT)",
        ])
        let drifted = KiroCostScanner.scanFullResult(
            cliDBURL: dbURL,
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertFalse(drifted.completed)
        XCTAssertEqual(drifted.failures, ["sqlite"])

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
        var walDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &walDB), SQLITE_OK)
        let openedWAL = try XCTUnwrap(walDB)
        defer { sqlite3_close(openedWAL) }
        let walPayload = """
        {"conversation_id":"wal-row","history":[{"user":"usage from committed WAL","request_metadata":{"request_start_timestamp_ms":\(nowMs)}}]}
        """
        for statement in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE conversations (value TEXT NOT NULL)",
            "PRAGMA wal_checkpoint(TRUNCATE)",
            "INSERT INTO conversations (value) VALUES ('\(walPayload)')",
        ] {
            var error: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(openedWAL, statement, nil, nil, &error)
            let message = error.map { String(cString: $0) } ?? ""
            if let error { sqlite3_free(error) }
            XCTAssertEqual(code, SQLITE_OK, message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        let walResult = KiroCostScanner.scanFullResult(
            cliDBURL: dbURL,
            archiveURL: root.appendingPathComponent("missing-archive", isDirectory: true),
            sessionsURL: root.appendingPathComponent("missing-sessions", isDirectory: true),
            now: now)
        XCTAssertTrue(walResult.completed)
        XCTAssertGreaterThan(walResult.report.todayTokens, 0)
    }

    func testKiroIncompleteScanMergesPartialUsageWithoutClaimingLive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-kiro-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("cost-history.json")
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        _ = CostHistoryStore.apply(
            source: .kiro,
            liveDays: [(today, 1.0, 100, [("known", 1.0, 100)])],
            now: now,
            windowDays: 90,
            url: historyURL)
        let partial = KiroCostScanner.buildReport(
            sessions: [.init(day: today, tokens: 9_000, usd: 90, model: "partial")],
            now: now,
            windowDays: 90)

        let merged = KiroCostScanner.mergeLiveReport(
            partial,
            now: now,
            historyURL: historyURL,
            liveScanSucceeded: false)

        XCTAssertEqual(merged.todayTokens, 9_000)
        XCTAssertEqual(merged.todayUSD, 90, accuracy: 0.001)
        XCTAssertFalse(merged.scanConfidence.live)
        XCTAssertEqual(
            CostHistoryStore.storedCountingRevision(source: .kiro, url: historyURL),
            0)
    }

    /// Parse a conversation history fixture into daily session points.
    func testKiroCostScannerParseConversationFixture() throws {
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
        let points = try XCTUnwrap(KiroCostScanner.parseConversation(
            data: data, fallbackCreatedMs: tsMs, cutoff: today, now: now, calendar: cal))
        XCTAssertFalse(points.isEmpty)
        let totalTokens = points.reduce(0) { $0 + $1.tokens }
        XCTAssertGreaterThan(totalTokens, 0)
        XCTAssertEqual(points.first?.model, "claude-sonnet-4")
        let report = KiroCostScanner.buildReport(sessions: points, now: now, windowDays: 30, calendar: cal)
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(report.todayTokens, totalTokens)
        XCTAssertEqual(
            KiroCostScanner.textTokenEstimate(String(repeating: "👨‍👩‍👧‍👦", count: 4)),
            25)
    }

    /// Parse a TUI kiro-cli session sidecar (~/.kiro/sessions/cli/<id>.json):
    /// USD from real metered credits, tokens from context-window growth.
    func testKiroCostScannerParseCLISessionSidecar() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let turnEnd = iso.string(from: now)

        let sidecar: [String: Any] = [
            "session_id": "6f45aad0-test",
            "created_at": turnEnd,
            "updated_at": turnEnd,
            "session_state": [
                "conversation_metadata": [
                    "user_turn_metadatas": [
                        [
                            "end_timestamp": turnEnd,
                            "input_token_count": 0,
                            "output_token_count": 0,
                            "context_usage_percentage": 2.0,
                            "metering_usage": [
                                ["value": 0.07, "unit": "credit"],
                                ["value": 0.09, "unit": "credit"],
                            ],
                        ] as [String: Any],
                        [
                            "end_timestamp": turnEnd,
                            "input_token_count": 0,
                            "output_token_count": 0,
                            "context_usage_percentage": 4.5,
                            "metering_usage": [["value": 0.84, "unit": "credit"]],
                        ] as [String: Any],
                    ],
                ],
                "rts_model_state": [
                    "model_info": [
                        "model_id": "claude-sonnet-4.5",
                        "context_window_tokens": 200_000,
                    ],
                ],
            ] as [String: Any],
        ]

        let points = KiroCostScanner.parseCLISessionSidecar(sidecar, cutoff: today, calendar: cal)
        XCTAssertEqual(points.count, 1)   // both turns land on today
        let p = points[0]
        XCTAssertEqual(p.model, "claude-sonnet-4.5")
        // Turn 1: 2.0% of 200k = 4000; turn 2: Δ2.5% = 5000 → 9000 tokens.
        XCTAssertEqual(p.tokens, 9000)
        // Credits (0.07+0.09+0.84 = 1.0) × $0.04/credit.
        XCTAssertEqual(p.usd, 0.04, accuracy: 0.0001)

        // Old sidecar without metering/turns parses to nothing (no crash).
        XCTAssertTrue(KiroCostScanner.parseCLISessionSidecar(
            ["session_id": "x"], cutoff: today, calendar: cal).isEmpty)
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
        XCTAssertTrue(s.windows[1].isSupplementary)
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

    /// FreeModel menu bar: the bonus "Số dư" window is excluded; once the
    /// 5-hour window hits 0 remaining, the readout collapses to JUST the
    /// balance percent (no week percent alongside).
    func testFreemodelMenuBarPercentsSwapToBalanceWhenExhausted() {
        func w(_ label: String, remaining: Int) -> QuotaWindow {
            QuotaWindow(label: label, usedPct: 100 - remaining, remainingPct: remaining)
        }
        // Normal: balance hidden, plan windows as-is.
        XCTAssertEqual(
            MenuBarIconRenderer.freemodelMenuBarPercents(
                [w("5 giờ", remaining: 38), w("Tuần", remaining: 92), w("Số dư", remaining: 64)]),
            [38, 92])
        // 5h exhausted → ONLY the balance percent.
        XCTAssertEqual(
            MenuBarIconRenderer.freemodelMenuBarPercents(
                [w("5 giờ", remaining: 0), w("Tuần", remaining: 92), w("Số dư", remaining: 67)]),
            [67])
        // 5h exhausted but no balance left → keep the honest plan windows.
        XCTAssertEqual(
            MenuBarIconRenderer.freemodelMenuBarPercents(
                [w("5 giờ", remaining: 0), w("Tuần", remaining: 92), w("Số dư", remaining: 0)]),
            [0, 92])
        // No balance window at all (nothing earned) → unchanged.
        XCTAssertEqual(
            MenuBarIconRenderer.freemodelMenuBarPercents(
                [w("5 giờ", remaining: 0), w("Tuần", remaining: 92)]),
            [0, 92])
        // Metric picker isolated the balance window itself → show it.
        XCTAssertEqual(
            MenuBarIconRenderer.freemodelMenuBarPercents([w("Số dư", remaining: 64)]),
            [64])
    }

    /// "Lowest Quota" card bug: an exhausted bonus-credit window (referral
    /// balance run out — expected once spent, not urgent) must not outrank a
    /// healthy primary quota. Reproduces the reported screenshot: 5h 92%,
    /// week 78%, bonus balance 0% — the card should read "Tuần · 78%", not
    /// "Số dư · 0%".
    func testLowestWindowIgnoresSupplementaryBonusWindow() {
        let status = ProviderStatus(
            id: "freemodel", displayName: "FreeModel",
            windows: [
                QuotaWindow(label: "5 giờ", usedPct: 8, remainingPct: 92),
                QuotaWindow(label: "Tuần", usedPct: 22, remainingPct: 78),
                QuotaWindow(label: "Số dư", usedPct: 100, remainingPct: 0, isSupplementary: true),
            ],
            lastUpdated: Date())
        let lowest = ProviderStatusSummary.lowestWindow(status)
        XCTAssertEqual(lowest?.label, "Tuần")
        XCTAssertEqual(lowest?.remainingPct, 78)
    }

    /// When every window is supplementary (degenerate case), fall back to
    /// considering all of them rather than returning nil for a status that
    /// does have data.
    func testLowestWindowFallsBackWhenAllWindowsSupplementary() {
        let status = ProviderStatus(
            id: "freemodel", displayName: "FreeModel",
            windows: [
                QuotaWindow(label: "Số dư", usedPct: 100, remainingPct: 0, isSupplementary: true),
            ],
            lastUpdated: Date())
        XCTAssertEqual(ProviderStatusSummary.lowestWindow(status)?.remainingPct, 0)
    }

    func testMenuBarPercentTitleIncludesUnit() {
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [76]), "76%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [93, 82]), "93%  82%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [-4, 120]), "0%  100%")
    }

    func testMenuBarStackedTitleUsesDownwardBaselineAndDynamicTextColor() {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: MenuBarIconRenderer.stackedTitleFontSize, weight: .semibold)
        let title = MenuBarIconRenderer.attributedStackedTitle("93%\n82% ", font: font)

        XCTAssertEqual(MenuBarIconRenderer.stackedTitleFontSize, 9)
        XCTAssertEqual(title.string, "93%\n82% ")
        XCTAssertEqual(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(
            (title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing,
            0)
        XCTAssertEqual(
            title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.controlTextColor)
    }

    func testMenuBarStackedPercentLinesKeepFiveHourAboveWeekly() {
        XCTAssertEqual(
            MenuBarIconRenderer.stackedPercentLines(for: [96, 98]),
            ["96%", "98%"])
        XCTAssertEqual(
            MenuBarIconRenderer.stackedPercentLines(for: [-4, 120, 42]),
            ["0%", "100%"])
    }

    func testMenuBarStackedTitleRightAlignsPercentColumns() {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: MenuBarIconRenderer.stackedTitleFontSize, weight: .semibold)
        let title = MenuBarIconRenderer.attributedStackedTitle("100%\n64%", font: font)
        let paragraphStyle = title.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(paragraphStyle?.alignment, .right)
    }

    func testMenuBarStackedProviderImageUsesCompactTemplateCanvas() {
        let image = MenuBarIconRenderer.stackedProviderImage(
            for: "claude", percents: [93, 82])

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.height, MenuBarIconRenderer.stackedProviderImageHeight)
        XCTAssertGreaterThan(image.size.width, image.size.height)
    }

    func testProviderLogoPointSizeUsesProviderSpecificScale() {
        XCTAssertEqual(
            MenuBarIconRenderer.providerLogoPointSize(for: "freemodel"),
            19.8,
            accuracy: 0.001)
        XCTAssertEqual(
            MenuBarIconRenderer.providerLogoPointSize(for: "claude"),
            20.7,
            accuracy: 0.001)
        XCTAssertEqual(
            MenuBarIconRenderer.providerLogoPointSize(for: "codex"),
            18,
            accuracy: 0.001)
    }

    func testMenuBarPlainTitleClearsStackedAttributes() {
        let button = NSButton()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.attributedTitle = MenuBarIconRenderer.attributedStackedTitle(
            "93%\n82% ", font: font)

        button.attributedTitle = NSAttributedString(string: "")
        button.title = "76% "

        XCTAssertEqual(button.title, "76% ")
        XCTAssertEqual(button.attributedTitle.string, "76% ")
        XCTAssertNil(button.attributedTitle.attribute(.baselineOffset, at: 0, effectiveRange: nil))
    }

    func testMenuBarMetricResolverPreservesPrimaryAndSecondaryValues() {
        let windows = [
            QuotaWindow(label: "5h", usedPct: 7, remainingPct: 93),
            QuotaWindow(label: "Week", usedPct: 18, remainingPct: 82),
        ]
        let resolved = MenuBarMetricResolver.resolve(
            windows: windows,
            preference: .primaryAndSecondary,
            supportsAverage: false,
            supportsPrimaryAndSecondary: true,
            supportsTertiary: false,
            supportsExtraUsage: false,
            hasMonthlyPlan: false)

        XCTAssertEqual(resolved, windows)
    }

    func testMenuBarMetricResolverUsesSingleValueWhenSecondaryMissing() {
        let window = QuotaWindow(label: "5h", usedPct: 7, remainingPct: 93)
        let resolved = MenuBarMetricResolver.resolve(
            windows: [window],
            preference: .primaryAndSecondary,
            supportsAverage: false,
            supportsPrimaryAndSecondary: true,
            supportsTertiary: false,
            supportsExtraUsage: false,
            hasMonthlyPlan: false)

        XCTAssertEqual(resolved, [window])
    }

    func testAntigravityQuotaBarUsesCompactHeight() {
        XCTAssertEqual(QuotaBarLayout.compactHeight, 4, accuracy: 0.001)
    }

    func testAntigravityAutomaticMenuBarPreservesSingleGeminiRepresentative() {
        withAntigravityMenuBarMetric(.automatic, genericPreference: .secondary) {
            XCTAssertEqual(
                antigravityMenuBarFrames(for: [
                    QuotaWindow(label: "Claude/GPT weekly", usedPct: 75, remainingPct: 25),
                    QuotaWindow(label: "Gemini weekly", usedPct: 40, remainingPct: 60),
                    QuotaWindow(label: "Claude/GPT 5-hour", usedPct: 55, remainingPct: 45),
                    QuotaWindow(label: "Gemini 5-hour", usedPct: 20, remainingPct: 80),
                ]),
                [.provider(
                    id: "antigravity",
                    name: "Antigravity",
                    percents: [60],
                    text: nil)])
        }
    }

    func testAntigravityAutomaticMenuBarFallsBackToSingleClaudeGPTRepresentative() {
        withAntigravityMenuBarMetric(.automatic) {
            XCTAssertEqual(
                antigravityMenuBarFrames(for: [
                    QuotaWindow(label: "Claude/GPT weekly", usedPct: 75, remainingPct: 25),
                    QuotaWindow(label: "Claude/GPT 5-hour", usedPct: 55, remainingPct: 45),
                ]),
                [.provider(
                    id: "antigravity",
                    name: "Antigravity",
                    percents: [25],
                    text: nil)])
        }
    }

    func testAntigravityExplicitClaudeGPTMenuBarShowsOnlySelectedGroup() {
        withAntigravityMenuBarMetric(.claudeGPT) {
            XCTAssertEqual(
                antigravityMenuBarFrames(for: [
                    QuotaWindow(label: "Gemini 5-hour", usedPct: 20, remainingPct: 80),
                    QuotaWindow(label: "Gemini weekly", usedPct: 40, remainingPct: 60),
                    QuotaWindow(label: "Claude/GPT 5-hour", usedPct: 55, remainingPct: 45),
                    QuotaWindow(label: "Claude/GPT weekly", usedPct: 75, remainingPct: 25),
                ]),
                [.provider(
                    id: "antigravity",
                    name: "Antigravity",
                    percents: [45, 25],
                    text: nil)])
        }
    }

    func testAntigravityExplicitGroupSupportsOneWindowWithoutCrossStacking() {
        withAntigravityMenuBarMetric(.gemini) {
            XCTAssertEqual(
                antigravityMenuBarFrames(for: [
                    QuotaWindow(label: "Gemini weekly", usedPct: 40, remainingPct: 60),
                    QuotaWindow(label: "Claude/GPT 5-hour", usedPct: 55, remainingPct: 45),
                ]),
                [.provider(
                    id: "antigravity",
                    name: "Antigravity",
                    percents: [60],
                    text: nil)])
        }
    }

    func testAntigravityMissingExplicitGroupFallsBackToAutomatic() {
        withAntigravityMenuBarMetric(.gemini) {
            XCTAssertEqual(
                antigravityMenuBarFrames(for: [
                    QuotaWindow(label: "Claude/GPT weekly", usedPct: 75, remainingPct: 25),
                    QuotaWindow(label: "Claude/GPT 5-hour", usedPct: 55, remainingPct: 45),
                ]),
                [.provider(
                    id: "antigravity",
                    name: "Antigravity",
                    percents: [25],
                    text: nil)])
        }
    }

    func testAntigravityOAuthModelLabelsFallBackToSingleConservativeValue() {
        let windows = [
            QuotaWindow(label: "Pro", usedPct: 30, remainingPct: 70),
            QuotaWindow(label: "Flash", usedPct: 60, remainingPct: 40),
            QuotaWindow(label: "Flash Lite", usedPct: 35, remainingPct: 65),
        ]

        for metric in AntigravityMenuBarMetric.allCases {
            withAntigravityMenuBarMetric(metric) {
                XCTAssertEqual(
                    antigravityMenuBarFrames(for: windows),
                    [.provider(
                        id: "antigravity",
                        name: "Antigravity",
                        percents: [40],
                        text: nil)])
            }
        }
    }

    func testAntigravityMenuBarMetricUsesDedicatedDefaultsKey() {
        withAntigravityMenuBarMetric(.claudeGPT, genericPreference: .primary) {
            XCTAssertEqual(AntigravityMenuBarMetric.current, .claudeGPT)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: "menuBarMetricPreferencesJSON"),
                "{\"antigravity\":\"primary\"}")
        }
    }

    func testAntigravityMenuBarMetricDefaultsToAutomatic() {
        let defaults = UserDefaults.standard
        let key = AntigravityMenuBarMetric.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertEqual(AntigravityMenuBarMetric.current, .automatic)
    }

    func testMenuBarFramesRenderConfiguredPrimaryAndSecondaryValues() {
        let key = "menuBarMetricPreferencesJSON"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(
            "{\"claude\":\"primaryAndSecondary\"}", forKey: key)

        let status = ProviderStatus(
            id: "claude",
            displayName: "Claude",
            windows: [
                QuotaWindow(label: "5h", usedPct: 7, remainingPct: 93),
                QuotaWindow(label: "Week", usedPct: 18, remainingPct: 82),
            ],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [status], showPercent: true, visibility: { _ in true }),
            [.provider(id: "claude", name: "Claude", percents: [93, 82], text: nil)])
    }

    func testClaudeAutomaticMenuBarFramesShowFiveHourAndWeeklyValues() {
        let key = "menuBarMetricPreferencesJSON"
        let legacyKey = "menuBarMetric.claude"
        let previous = UserDefaults.standard.object(forKey: key)
        let previousLegacy = UserDefaults.standard.object(forKey: legacyKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            if let previousLegacy {
                UserDefaults.standard.set(previousLegacy, forKey: legacyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }
        UserDefaults.standard.set("{}", forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)

        let status = ProviderStatus(
            id: "claude",
            displayName: "Claude",
            windows: [
                QuotaWindow(label: "5 giờ", usedPct: 7, remainingPct: 93),
                QuotaWindow(label: "Tuần", usedPct: 18, remainingPct: 82),
                QuotaWindow(label: "Opus", usedPct: 1, remainingPct: 99),
            ],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [status], showPercent: true, visibility: { _ in true }),
            [.provider(id: "claude", name: "Claude", percents: [93, 82], text: nil)])
    }

    func testClaudeAutomaticMenuBarFramesFallBackWhenWeeklyWindowMissing() {
        let key = "menuBarMetricPreferencesJSON"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set("{}", forKey: key)

        let status = ProviderStatus(
            id: "claude",
            displayName: "Claude",
            windows: [
                QuotaWindow(label: "5 giờ", usedPct: 7, remainingPct: 93),
                QuotaWindow(label: "Opus", usedPct: 1, remainingPct: 99),
            ],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [status], showPercent: true, visibility: { _ in true }),
            [.provider(id: "claude", name: "Claude", percents: [93], text: nil)])
    }

    func testClaudeSecondaryMetricStillShowsOnlyWeeklyValue() {
        let key = "menuBarMetricPreferencesJSON"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set("{\"claude\":\"secondary\"}", forKey: key)

        let status = ProviderStatus(
            id: "claude",
            displayName: "Claude",
            windows: [
                QuotaWindow(label: "5 giờ", usedPct: 7, remainingPct: 93),
                QuotaWindow(label: "Tuần", usedPct: 18, remainingPct: 82),
            ],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [status], showPercent: true, visibility: { _ in true }),
            [.provider(id: "claude", name: "Claude", percents: [82], text: nil)])
    }

    func testCodexAutomaticMenuBarFramesShowFiveHourAndWeeklyValues() {
        withCodexMenuBarPreferences(metric: .automatic, genericPreference: .primary) {
            XCTAssertEqual(
                codexMenuBarFrames(for: [
                    QuotaWindow(label: "5 giờ", usedPct: 0, remainingPct: 100),
                    QuotaWindow(label: "Tuần", usedPct: 18, remainingPct: 82),
                    QuotaWindow(label: "Codex Spark Tuần", usedPct: 36, remainingPct: 64),
                ]),
                [.provider(id: "codex", name: "Codex", percents: [100, 82], text: nil)])
        }
    }

    func testCodexAutomaticMenuBarFramesKeepWeeklyOnlyBehavior() {
        withCodexMenuBarPreferences(metric: .automatic) {
            XCTAssertEqual(
                codexMenuBarFrames(for: [
                    QuotaWindow(label: "Tuần", usedPct: 18, remainingPct: 82),
                ]),
                [.provider(id: "codex", name: "Codex", percents: [82], text: nil)])
        }
    }

    func testCodexAutomaticMenuBarFramesDoNotPromoteSparkToCanonicalWeekly() {
        withCodexMenuBarPreferences(metric: .automatic) {
            XCTAssertEqual(
                codexMenuBarFrames(for: [
                    QuotaWindow(label: "5 giờ", usedPct: 7, remainingPct: 93),
                    QuotaWindow(label: "Codex Spark Tuần", usedPct: 36, remainingPct: 64),
                ]),
                [.provider(id: "codex", name: "Codex", percents: [64], text: nil)])
        }
    }

    func testCodexExplicitMenuBarMetricsStaySingleValue() {
        let windows = [
            QuotaWindow(label: "5 giờ", usedPct: 7, remainingPct: 93),
            QuotaWindow(label: "Tuần", usedPct: 18, remainingPct: 82),
            QuotaWindow(label: "Codex Spark 5 giờ", usedPct: 30, remainingPct: 70),
            QuotaWindow(label: "Codex Spark Tuần", usedPct: 36, remainingPct: 64),
        ]

        withCodexMenuBarPreferences(metric: .session) {
            XCTAssertEqual(
                codexMenuBarFrames(for: windows),
                [.provider(id: "codex", name: "Codex", percents: [93], text: nil)])
        }
        withCodexMenuBarPreferences(metric: .weekly) {
            XCTAssertEqual(
                codexMenuBarFrames(for: windows),
                [.provider(id: "codex", name: "Codex", percents: [82], text: nil)])
        }
    }

    func testMenuBarProviderLogosAreMonochromeTemplates() {
        let providerIDs = [
            "minimax", "hapo", "codex", "claude", "openrouter", "tryapi", "deepseek", "zai",
            "elevenlabs", "deepgram", "groq", "grok", "openai", "ollama", "copilot",
            "kilo", "commandcode", "freemodel", "mimo", "cursor", "alibaba", "opencode",
            "opencodego", "gemini", "kiro", "antigravity", "bedrock", "hiyo",
        ]

        for id in providerIDs {
            XCTAssertTrue(MenuBarIconRenderer.providerLogo(for: id).isTemplate, id)
        }
    }

    func testDefaultMenuBarLogoPreservesOriginalColors() {
        XCTAssertFalse(MenuBarIconRenderer.iconImage().isTemplate)
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
        XCTAssertFalse(fiveH.isInactive)

        let week = s.windows[1]
        XCTAssertEqual(week.label, "Tuần")
        XCTAssertEqual(week.usedPct, 0)              // 8/132000 ≈ 0.006% → 0
        XCTAssertEqual(week.subtitle, "$0.08 / $1,320.00")
        XCTAssertFalse(week.isInactive)

        // Malformed payload → error, no windows.
        let bad = FreemodelProvider._parseForTesting(usageData: Data("{}".utf8), accountLabel: nil)
        XCTAssertNotNil(bad.error)
        XCTAssertTrue(bad.windows.isEmpty)
    }

    func testFreemodelInactiveWindowsDoNotLookLikeFullQuota() throws {
        let zeroPlan = """
        {"window5h":{"usedCents":0,"limitCents":0,"resetsAt":0},
         "windowWeek":{"usedCents":0,"limitCents":0,"resetsAt":0}}
        """.data(using: .utf8)!
        let status = FreemodelProvider._parseForTesting(
            usageData: zeroPlan,
            accountLabel: nil,
            referralData: Data(#"{"credits":64,"used":36}"#.utf8))

        XCTAssertEqual(status.windows.count, 3)
        XCTAssertTrue(status.windows[0].isInactive)
        XCTAssertTrue(status.windows[1].isInactive)
        XCTAssertEqual(status.windows[0].remainingPct, 100)
        XCTAssertEqual(status.windows[0].subtitle, "$0.00 / $0.00")
        XCTAssertEqual(MenuBarIconRenderer.freemodelMenuBarPercents(status.windows), [64])
        XCTAssertEqual(ProviderStatusSummary.lowestWindow(status)?.label, "Số dư")

        let encoded = try JSONEncoder().encode(status.windows[0])
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: encoded)
        XCTAssertTrue(decoded.isInactive)
    }

    func testFreemodelZeroUsedWithPlanRemainsActiveAndFull() {
        let json = """
        {"window5h":{"usedCents":0,"limitCents":20000,"resetsAt":0},
         "windowWeek":{"usedCents":100,"limitCents":1000,"resetsAt":0}}
        """.data(using: .utf8)!
        let status = FreemodelProvider._parseForTesting(usageData: json, accountLabel: nil)

        XCTAssertFalse(status.windows[0].isInactive)
        XCTAssertEqual(status.windows[0].remainingPct, 100)
        XCTAssertEqual(MenuBarIconRenderer.freemodelMenuBarPercents(status.windows), [100, 90])
    }

    /// Dashboard "Current balance" → "Số dư" window: remaining = referral
    /// credits + signup credit, total = remaining + used.
    func testFreemodelBalanceWindow() {
        let usage = """
        {"window5h":{"usedCents":100,"limitCents":20000,"resetsAt":0},
         "windowWeek":{"usedCents":100,"limitCents":132000,"resetsAt":0}}
        """.data(using: .utf8)!
        // Screenshot numbers: used 67.22, remaining 120.62 (referral 100.62 + signup $20).
        let referral = Data(#"{"code":"x","count":8,"credits":100.62,"used":67.22}"#.utf8)
        let billing = Data(#"{"signupCreditCents":2000}"#.utf8)

        let s = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: referral, billingData: billing)
        XCTAssertEqual(s.windows.count, 3)
        let balance = s.windows[2]
        XCTAssertEqual(balance.label, "Số dư")
        XCTAssertEqual(balance.subtitle, "$67.22 / $187.84 · 8 giới thiệu")
        XCTAssertEqual(balance.usedPct, 36)          // 67.22/187.84 ≈ 35.8% → 36
        XCTAssertEqual(balance.remainingPct, 64)
        XCTAssertTrue(balance.isSupplementary)

        // No referral data (endpoint failed) → no third window.
        let noRef = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil, referralData: nil, billingData: billing)
        XCTAssertEqual(noRef.windows.count, 2)

        // Zero balance everywhere → hidden, not a "0/0" bar.
        let zero = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: Data(#"{"count":0,"credits":0,"used":0}"#.utf8), billingData: nil)
        XCTAssertEqual(zero.windows.count, 2)

        // 2026 schema without billing: referral still renders on its own
        // (user preference) — used-only figure, remaining unknown → 100% used.
        let newSchema = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: Data(#"{"count":0,"credits":0,"used":155.53}"#.utf8), billingData: nil)
        XCTAssertEqual(newSchema.windows.count, 3)
        XCTAssertEqual(newSchema.windows[2].usedPct, 100)

        // 2026 schema (live payload shape): referral.credits is always 0; the
        // remaining bonus lives in billing.creditCents. Dashboard readout was
        // "$189.79 / $323.52" for these exact numbers.
        let referral2026 = Data(#"{"code":"x","count":8,"credits":0,"used":189.79,"pendingCents":6000}"#.utf8)
        let billing2026 = Data(#"{"creditCents":13373,"signupCreditCents":13373}"#.utf8)
        let live = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: referral2026, billingData: billing2026)
        XCTAssertEqual(live.windows.count, 3)
        XCTAssertEqual(live.windows[2].subtitle, "$189.79 / $323.52 · 8 giới thiệu")
        XCTAssertEqual(live.windows[2].usedPct, 59)  // 189.79/323.52 ≈ 58.7% → 59

        // Billing timed out under the 2026 schema: referral-only figure still
        // renders immediately (billing tops the total up when it arrives).
        let billingDown = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: referral2026, billingData: nil)
        XCTAssertEqual(billingDown.windows.count, 3)
        XCTAssertEqual(billingDown.windows[2].subtitle, "$189.79 / $189.79 · 8 giới thiệu")
    }

    func testFreemodelStickyBalanceWindowMarksStaleExactlyOnce() {
        let usage = """
        {"window5h":{"usedCents":100,"limitCents":20000,"resetsAt":0},
         "windowWeek":{"usedCents":100,"limitCents":132000,"resetsAt":0}}
        """.data(using: .utf8)!
        let referral = Data(#"{"code":"x","count":8,"credits":0,"used":189.79}"#.utf8)
        let billing = Data(#"{"creditCents":13373,"signupCreditCents":13373}"#.utf8)
        let provider = FreemodelProvider()

        let fresh = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: referral, billingData: billing, provider: provider)
        XCTAssertEqual(fresh.windows[2].subtitle, "$189.79 / $323.52 · 8 giới thiệu")
        XCTAssertFalse(fresh.windows[2].subtitle?.contains("số cũ") ?? false)

        for _ in 0..<2 {
            let stale = FreemodelProvider._parseForTesting(
                usageData: usage, accountLabel: nil, provider: provider)
            XCTAssertEqual(stale.windows[2].subtitle, "$189.79 / $323.52 · 8 giới thiệu · số cũ")
        }
    }

    func testFreemodelBalanceCachesDoNotCrossSameBrowserAccountIdentity() throws {
        let usage = """
        {"window5h":{"usedCents":100,"limitCents":20000,"resetsAt":0},
         "windowWeek":{"usedCents":100,"limitCents":132000,"resetsAt":0}}
        """.data(using: .utf8)!
        let referral = Data(#"{"code":"x","count":8,"credits":0,"used":189.79}"#.utf8)
        let billing = Data(#"{"creditCents":13373,"signupCreditCents":13373}"#.utf8)
        let suiteName = "FreemodelBalanceIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountAIdentity = "browser:chrome\u{0}bm_session=account-a"
        let accountBIdentity = "browser:chrome\u{0}bm_session=account-b"
        let provider = FreemodelProvider(balanceDefaults: defaults)

        let accountA = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            referralData: referral, billingData: billing,
            provider: provider, balanceCacheIdentity: accountAIdentity,
            usePersistentBalanceCache: true)
        XCTAssertEqual(accountA.windows.count, 3)

        let accountBInMemory = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            provider: provider, balanceCacheIdentity: accountBIdentity,
            usePersistentBalanceCache: true)
        XCTAssertEqual(accountBInMemory.windows.count, 2)
        XCTAssertFalse(accountBInMemory.windows.contains(where: { $0.label == "Số dư" }))

        let restartedForB = FreemodelProvider(balanceDefaults: defaults)
        let accountBAfterRestart = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            provider: restartedForB, balanceCacheIdentity: accountBIdentity,
            usePersistentBalanceCache: true)
        XCTAssertEqual(accountBAfterRestart.windows.count, 2)
        XCTAssertFalse(accountBAfterRestart.windows.contains(where: { $0.label == "Số dư" }))

        let restartedForA = FreemodelProvider(balanceDefaults: defaults)
        let accountAAfterRestart = FreemodelProvider._parseForTesting(
            usageData: usage, accountLabel: nil,
            provider: restartedForA, balanceCacheIdentity: accountAIdentity,
            usePersistentBalanceCache: true)
        XCTAssertTrue(accountAAfterRestart.windows[2].subtitle?.contains("số cũ") == true)
        let persistedKeys = defaults.persistentDomain(forName: suiteName)
            .map { Array($0.keys) } ?? []
        XCTAssertEqual(persistedKeys.filter {
            $0.hasPrefix("freemodelCachedBalanceWindow.v2.")
        }.count, 1)
        XCTAssertFalse(persistedKeys.contains(where: {
            $0.contains("bm_session") || $0.contains("account-a")
        }))
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

    func testHiyoParse() {
        let json = """
        {
          "balance": 3.98917248,
          "remaining": 3.98917248,
          "unit": "USD",
          "isValid": true,
          "mode": "unrestricted",
          "planName": "钱包余额",
          "usage": {
            "total": { "cost": 0.0135344, "total_tokens": 26935, "requests": 6 },
            "today": { "cost": 0, "total_tokens": 0, "requests": 0 }
          }
        }
        """.data(using: .utf8)!
        let s = HiyoProvider()._parseForTesting(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows.first?.label, "Số dư")
        XCTAssertEqual(s.creditsRemaining ?? 0, 3.98917248, accuracy: 0.0001)
        XCTAssertTrue(s.windows.first?.subtitle?.contains("$") == true)
    }

    /// Isolated store: temp metadata file + throwaway UserDefaults suite so
    /// tests never touch the real key store or the app's active selection.
    private func makeTempHiyoStore() throws -> (url: URL, defaults: UserDefaults, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiyo-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hiyo-keys.json")
        // Pre-create an empty store so ensureLegacyImport never copies the
        // machine's real legacy apiKey into the temp store.
        try Data(#"{"accounts":[]}"#.utf8).write(to: url)
        let suite = "hiyo-keys-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (url, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    func testHiyoKeyStoreAddSwitchRemoveRoundtrip() throws {
        let store = try makeTempHiyoStore()
        defer { store.cleanup() }
        let url = store.url, defaults = store.defaults

        XCTAssertTrue(HiyoKeyStore.allKeys(url: url, defaults: defaults).isEmpty)
        XCTAssertNil(HiyoKeyStore.activeApiKey(url: url, defaults: defaults))

        let k1 = try HiyoKeyStore.add(apiKey: "sk-hiyo-test-one-aaaa", label: "Work",
                                      url: url, defaults: defaults)
        XCTAssertEqual(k1.label, "Work")
        XCTAssertEqual(k1.preview, "sk-hiyo-")
        // First key auto-activates.
        XCTAssertEqual(HiyoKeyStore.activeID(url: url, defaults: defaults), k1.id)

        let k2 = try HiyoKeyStore.add(apiKey: "sk-hiyo-test-two-bbbb", label: "Personal",
                                      url: url, defaults: defaults)
        // Adding a second key must NOT steal active.
        XCTAssertEqual(HiyoKeyStore.activeID(url: url, defaults: defaults), k1.id)

        HiyoKeyStore.setActive(k2.id, url: url, defaults: defaults)
        XCTAssertEqual(HiyoKeyStore.activeID(url: url, defaults: defaults), k2.id)
        XCTAssertEqual(HiyoKeyStore.activeApiKey(url: url, defaults: defaults), "sk-hiyo-test-two-bbbb")
        XCTAssertEqual(HiyoKeyStore.activeDisplayLabel(url: url, defaults: defaults), "Personal")

        try HiyoKeyStore.remove(k2.id, url: url, defaults: defaults)
        // Active falls back to the first remaining key.
        XCTAssertEqual(HiyoKeyStore.activeID(url: url, defaults: defaults), k1.id)
        XCTAssertEqual(HiyoKeyStore.allKeys(url: url, defaults: defaults).count, 1)

        try HiyoKeyStore.remove(k1.id, url: url, defaults: defaults)
        XCTAssertTrue(HiyoKeyStore.allKeys(url: url, defaults: defaults).isEmpty)
        XCTAssertNil(HiyoKeyStore.activeApiKey(url: url, defaults: defaults))
    }

    // MARK: Antigravity quota-summary parsing

    /// Server wraps groups under "response" (Vendor-accepted variant). All four
    /// semantic windows must come out in canonical order with correct values.
    func testAntigravitySummaryResponseWrapperFourBuckets() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini","buckets":[
            {"bucketId":"gemini-5h","displayName":"5-hour","remainingFraction":0.8,
             "resetTime":"2099-01-01T00:00:00Z"},
            {"bucketId":"gemini-weekly","displayName":"Weekly","remainingFraction":0.6},
            {"bucketId":"gemini-lite-weekly","displayName":"Weekly","remainingFraction":0.1},
            {"bucketId":"gemini-weekly-disabled","displayName":"Weekly","disabled":true,
             "remainingFraction":0.1}]},
          {"displayName":"Claude/GPT","buckets":[
            {"bucketId":"claude-gpt-5h","displayName":"5-hour",
             "remaining":{"case":"remainingFraction","value":0.45}},
            {"bucketId":"claude-gpt-weekly","displayName":"Weekly","remainingFraction":0.25}]}]}}
        """.data(using: .utf8)!
        let windows = try AntigravityProvider()._parseQuotaSummaryForTesting(json)
        XCTAssertEqual(windows.map(\.label),
                       ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"])
        XCTAssertEqual(windows.map(\.remainingPct), [80, 60, 45, 25])
        XCTAssertEqual(windows.map(\.windowSeconds), [18_000, 604_800, 18_000, 604_800])
        XCTAssertNotNil(windows.first?.resetDate)
    }

    /// "summary" wrapper and bare root groups must also parse (legacy variants).
    func testAntigravitySummaryAndRootWrappersParse() throws {
        let group = """
        {"displayName":"Gemini","buckets":[
          {"bucketId":"gemini-5h","displayName":"5-hour","remainingFraction":0.5}]}
        """
        for body in ["{\"summary\":{\"groups\":[\(group)]}}", "{\"groups\":[\(group)]}"] {
            let windows = try AntigravityProvider()
                ._parseQuotaSummaryForTesting(body.data(using: .utf8)!)
            XCTAssertEqual(windows.map(\.label), ["Gemini 5-hour"], "body: \(body)")
            XCTAssertEqual(windows.first?.remainingPct, 50)
        }
    }

    func testAntigravityActualSummaryShapeMapsSemanticBuckets() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini Models",
           "description":"Models within this group: Gemini Flash, Gemini Pro",
           "buckets":[
             {"bucketId":"gemini-weekly","displayName":"Weekly Limit",
              "remainingFraction":0.6380629},
             {"bucketId":"gemini-5h","displayName":"Five Hour Limit",
              "remainingFraction":1}]},
          {"displayName":"Claude and GPT models","buckets":[
             {"bucketId":"3p-weekly","displayName":"Weekly Limit",
              "remainingFraction":1},
             {"bucketId":"3p-5h","displayName":"Five Hour Limit",
              "remainingFraction":1}]}]}}
        """.data(using: .utf8)!
        let windows = try AntigravityProvider()._parseQuotaSummaryForTesting(json)
        XCTAssertEqual(windows.map(\.label),
                       ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"])
        XCTAssertEqual(windows.map(\.remainingPct), [100, 64, 100, 100])
        XCTAssertEqual(windows.map(\.windowSeconds), [18_000, 604_800, 18_000, 604_800])
    }

    /// No weekly/week marker anywhere → no weekly row may be synthesized, even
    /// with a 7-day-style reset countdown text.
    func testAntigravityNoWeeklyMarkerEmitsNoWeeklyRow() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini","buckets":[
            {"bucketId":"gemini-prompts","displayName":"Prompts","remainingFraction":0.9,
             "description":"Resets in 7 days"}]}]}}
        """.data(using: .utf8)!
        let windows = try AntigravityProvider()._parseQuotaSummaryForTesting(json)
        XCTAssertFalse(windows.contains { $0.label.lowercased().contains("week") })
        XCTAssertTrue(windows.isEmpty)
    }

    func testAntigravityProcessListKeepsAllCandidates() {
        let output = """
        101 /opt/antigravity/language_server --csrf_token=stale --app_data_dir=/tmp/a
        202 agy serve
        """
        XCTAssertEqual(AntigravityProvider._processIDsForTesting(output), [101, 202])
        XCTAssertTrue(AntigravityProvider._shouldContinueAfterCandidateForTesting(
            error: "Account không khớp: old"
        ))
        XCTAssertFalse(AntigravityProvider._shouldContinueAfterCandidateForTesting(error: nil))
    }

    func testAntigravityIsolatedAgyHomeDirSanitizesLabelDeterministically() {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-isolated-agy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let dirA = AntigravityIsolatedAgy.homeDir(forAccountLabel: " user@example.com ", home: tempHome, env: [:])
        let dirB = AntigravityIsolatedAgy.homeDir(forAccountLabel: " user@example.com ", home: tempHome, env: [:])
        XCTAssertEqual(dirA, dirB, "cùng label phải luôn ra cùng một thư mục (deterministic)")
        XCTAssertEqual(dirA.lastPathComponent, "user_example.com")
        XCTAssertTrue(dirA.path.hasSuffix(".config/birdnion/agy-accounts/user_example.com"))

        // Chưa từng login cô lập cho account này -> phải false, không được bịa dữ liệu
        XCTAssertFalse(AntigravityIsolatedAgy.hasLogin(forAccountLabel: "user@example.com", home: tempHome, env: [:]))
    }

    func testAntigravitySelectedOAuthEmailOverridesLegacyConfigGuard() {
        XCTAssertEqual(
            AntigravityProvider._expectedAccountEmailForTesting(
                selectedEmail: " selected@example.com ",
                configLabel: "legacy@example.com"
            ),
            "selected@example.com"
        )
        XCTAssertEqual(
            AntigravityProvider._expectedAccountEmailForTesting(
                selectedEmail: nil,
                configLabel: " legacy@example.com "
            ),
            "legacy@example.com"
        )
        XCTAssertNil(AntigravityProvider._expectedAccountEmailForTesting(
            selectedEmail: nil,
            configLabel: "Work"
        ))
        XCTAssertNil(AntigravityProvider._accountMismatchErrorForTesting(
            responseEmail: "SELECTED@example.com",
            selectedEmail: "selected@example.com",
            configLabel: "legacy@example.com"
        ))
        XCTAssertTrue(AntigravityProvider._accountMismatchErrorForTesting(
            responseEmail: "legacy@example.com",
            selectedEmail: "selected@example.com",
            configLabel: "legacy@example.com"
        )?.hasPrefix("Account không khớp:") == true)
    }

    func testAntigravityTwoClientBinaryUsesCanonicalSecretPairing() throws {
        let secretPrefix = "GOCSPX" + "-"
        let firstSecret = secretPrefix + String(repeating: "a", count: 28)
        let secondSecret = secretPrefix + String(repeating: "b", count: 28)
        let firstID = "100-" + String(repeating: "c", count: 24) + ".apps.googleusercontent.com"
        let secondID = "200-" + String(repeating: "d", count: 24) + ".apps.googleusercontent.com"
        let binaryPayload = [
            firstSecret,
            secondSecret,
            firstID,
            secondID,
        ].joined(separator: "\0binary\0")
        var binaryLikeData = Data([0xFF])
        binaryLikeData.append(contentsOf: binaryPayload.utf8)

        let canonicalClient = try XCTUnwrap(
            AntigravityOAuthConfig.parseClient(fromInstalledArtifactData: binaryLikeData))
        let client = try XCTUnwrap(
            AntigravityOAuthStore.discoveredClient(from: canonicalClient))
        let partialIDResolved = try XCTUnwrap(AntigravityOAuthStore.resolvedClient(
            store: .init(clientId: "legacy-partial-client-id"),
            fallbackClient: client))
        let partialSecretResolved = try XCTUnwrap(AntigravityOAuthStore.resolvedClient(
            store: .init(clientSecret: firstSecret),
            fallbackClient: client))

        XCTAssertEqual(partialIDResolved.id, firstID)
        XCTAssertEqual(partialIDResolved.secret, secondSecret)
        XCTAssertEqual(partialSecretResolved.id, firstID)
        XCTAssertEqual(partialSecretResolved.secret, secondSecret)
        XCTAssertNotEqual(partialSecretResolved.secret, firstSecret)
    }

    func testAntigravityActiveSelectionPersistsWithoutChangingCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-antigravity-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let accounts = [
            AntigravityOAuthStore.Account(
                label: "personal", email: "one@example.com", refreshToken: "refresh-one"),
            AntigravityOAuthStore.Account(
                label: "work", email: "two@example.com", refreshToken: "refresh-two"),
        ]
        let original = AntigravityOAuthStore.Store(
            clientId: "client-id",
            clientSecret: "client-secret",
            activeLabel: "personal",
            accounts: accounts
        )
        try AntigravityOAuthStore.save(original, url: url)

        XCTAssertTrue(try AntigravityOAuthStore.persistActiveLabel("work", url: url))
        let selected = AntigravityOAuthStore.load(url: url)
        XCTAssertEqual(selected.activeLabel, "work")
        XCTAssertEqual(selected.clientId, original.clientId)
        XCTAssertEqual(selected.clientSecret, original.clientSecret)
        XCTAssertEqual(selected.accounts, accounts)
        XCTAssertFalse(try AntigravityOAuthStore.persistActiveLabel("missing", url: url))
        XCTAssertEqual(AntigravityOAuthStore.load(url: url).activeLabel, "work")
    }

    func testAntigravityAtomicMutationSurfacesPreserveConcurrentAccountChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        let original = AntigravityOAuthStore.Store(
            clientId: "client-a",
            clientSecret: "secret-a",
            activeLabel: "personal",
            accounts: [.init(label: "personal", email: "a@example.com", refreshToken: "token-a")])
        try AntigravityOAuthStore.save(original, url: url)

        _ = try AntigravityOAuthStore.persistAccount(
            label: "work",
            refreshToken: "token-b",
            email: "b@example.com",
            url: url)
        XCTAssertTrue(try AntigravityOAuthStore.persistActiveLabel("personal", url: url))
        let selected = AntigravityOAuthStore.load(url: url)
        XCTAssertEqual(selected.accounts.map(\.label), ["personal", "work"])
        XCTAssertEqual(selected.accounts.map(\.refreshToken), ["token-a", "token-b"])

        let removed = try AntigravityOAuthStore.persistRemovingAccount("personal", url: url)
        XCTAssertEqual(removed.accounts.map(\.label), ["work"])
        XCTAssertEqual(removed.activeLabel, "work")
        XCTAssertEqual(removed.clientId, "client-a")
        XCTAssertEqual(removed.clientSecret, "secret-a")
    }

    func testAntigravityRemovingLastActiveAccountLeavesNoSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        try AntigravityOAuthStore.save(.init(
            clientId: "client-a",
            clientSecret: "secret-a",
            activeLabel: "personal",
            accounts: [.init(
                label: "personal",
                email: "a@example.com",
                refreshToken: "token-a")]
        ), url: url)

        let removed = try AntigravityOAuthStore.persistRemovingAccount("personal", url: url)

        XCTAssertTrue(removed.accounts.isEmpty)
        XCTAssertNil(removed.activeLabel)
        XCTAssertEqual(removed.clientId, "client-a")
        XCTAssertEqual(removed.clientSecret, "secret-a")
    }

    func testAntigravityPersistAccountCanAtomicallyMakeNewLoginActive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        try AntigravityOAuthStore.save(.init(
            activeLabel: "personal",
            accounts: [.init(label: "personal", email: nil, refreshToken: "token-a")]), url: url)

        let updated = try AntigravityOAuthStore.persistAccount(
            label: "work",
            refreshToken: "token-b",
            email: "work@example.com",
            makeActive: true,
            url: url)

        XCTAssertEqual(updated.activeLabel, "work")
        XCTAssertEqual(updated.accounts.map(\.label), ["personal", "work"])
        XCTAssertEqual(AntigravityOAuthStore.load(url: url).activeLabel, "work")
    }

    func testAntigravityNewLoginWithoutEmailKeepsExistingFallbackAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")

        _ = try AntigravityOAuthStore.persistNewLoginAccount(
            fallbackLabel: "Account",
            refreshToken: "token-a",
            email: nil,
            makeActive: true,
            url: url)
        let updated = try AntigravityOAuthStore.persistNewLoginAccount(
            fallbackLabel: "Account",
            refreshToken: "token-b",
            email: nil,
            makeActive: true,
            url: url)

        XCTAssertEqual(updated.accounts.map(\.label), ["Account", "Account 2"])
        XCTAssertEqual(updated.accounts.map(\.refreshToken), ["token-a", "token-b"])
        XCTAssertEqual(updated.activeLabel, "Account 2")
    }

    func testAntigravityActiveAccountFallsBackWhenStoredLabelIsStale() {
        let first = AntigravityOAuthStore.Account(
            label: "personal", email: "one@example.com", refreshToken: "token-a")
        let store = AntigravityOAuthStore.Store(
            activeLabel: "removed-account",
            accounts: [first, .init(
                label: "work", email: "two@example.com", refreshToken: "token-b")])

        XCTAssertEqual(AntigravityOAuthStore.activeAccount(in: store), first)
    }

    func testAntigravityPersistAccountRejectsBlankTokenWithoutMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        let original = AntigravityOAuthStore.Store(
            activeLabel: "personal",
            accounts: [.init(label: "personal", email: nil, refreshToken: "token-a")])
        try AntigravityOAuthStore.save(original, url: url)

        XCTAssertThrowsError(try AntigravityOAuthStore.persistAccount(
            label: "work",
            refreshToken: "   \n",
            email: nil,
            makeActive: true,
            url: url))

        let preserved = AntigravityOAuthStore.load(url: url)
        XCTAssertEqual(preserved.activeLabel, "personal")
        XCTAssertEqual(preserved.accounts, original.accounts)
    }

    func testAntigravityMutationPreservesCorruptStoreBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try AntigravityOAuthStore.persistAccount(
            label: "work",
            refreshToken: "token-b",
            email: nil,
            url: url))

        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testAntigravityInvalidClientCredentialPairPreservesStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("antigravity-oauth.json")
        let original = AntigravityOAuthStore.Store(
            clientId: "client-old",
            clientSecret: "secret-old",
            activeLabel: "work",
            accounts: [.init(label: "work", email: "work@example.com", refreshToken: "token-old")])
        try AntigravityOAuthStore.save(original, url: url)

        XCTAssertThrowsError(try AntigravityOAuthStore.persistClientCredentials(
            clientId: nil,
            clientSecret: nil,
            url: url))
        XCTAssertThrowsError(try AntigravityOAuthStore.persistClientCredentials(
            clientId: "client-new",
            clientSecret: nil,
            url: url))
        XCTAssertThrowsError(try AntigravityOAuthStore.persistAccount(
            label: "other",
            refreshToken: "token-new",
            email: nil,
            clientId: "client-new",
            clientSecret: nil,
            url: url))

        let preserved = AntigravityOAuthStore.load(url: url)
        XCTAssertEqual(preserved.clientId, "client-old")
        XCTAssertEqual(preserved.clientSecret, "secret-old")
        XCTAssertEqual(preserved.accounts.map(\.label), ["work"])
        XCTAssertEqual(preserved.accounts[0].refreshToken, "token-old")
    }

    func testAntigravityLiveFetchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BIRDNION_RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set BIRDNION_RUN_LIVE_TESTS=1 to run the Antigravity live smoke test")
        }
        let provider = AntigravityProvider()
        let status = try await provider.fetch()
        XCTAssertNil(status.error, "Antigravity fetch should not fail: \(status.error ?? "")")
        XCTAssertFalse(status.windows.isEmpty, "Antigravity should return quota windows")
    }

    func testAntigravityIsolatedAgySeedLoginWritesAgyState() throws {
        // Seed một login agy cô lập từ bộ token OAuth và kiểm đủ 5 file agy cần,
        // đúng format (đã xác minh trên máy thật rằng agy chấp nhận bộ này).
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-agyseed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let label = "seed.user@example.com"
        try AntigravityIsolatedAgy.seedLogin(
            forAccountLabel: label,
            accessToken: "ACCESS-XYZ",
            refreshToken: "REFRESH-XYZ",
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            home: tempHome,
            env: [:])

        // hasLogin phải thấy token vừa seed.
        XCTAssertTrue(AntigravityIsolatedAgy.hasLogin(forAccountLabel: label, home: tempHome, env: [:]))

        let fm = FileManager.default
        let gemini = AntigravityIsolatedAgy.homeDir(forAccountLabel: label, home: tempHome, env: [:])
            .appendingPathComponent(".gemini", isDirectory: true)
        let cli = gemini.appendingPathComponent("antigravity-cli", isDirectory: true)

        for path in ["jetski-standalone-oauth-token", "user_id"] {
            XCTAssertTrue(fm.fileExists(atPath: gemini.appendingPathComponent(path).path), "thiếu \(path)")
        }
        for path in ["antigravity-oauth-token", "installation_id", "jetski_state.pbtxt"] {
            XCTAssertTrue(fm.fileExists(atPath: cli.appendingPathComponent(path).path), "thiếu \(path)")
        }

        // Token đúng format agy: { token: { access_token, ... }, auth_method: consumer }.
        let tokenData = try Data(contentsOf: gemini.appendingPathComponent("jetski-standalone-oauth-token"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])
        XCTAssertEqual(json["auth_method"] as? String, "consumer")
        let token = try XCTUnwrap(json["token"] as? [String: Any])
        XCTAssertEqual(token["access_token"] as? String, "ACCESS-XYZ")
        XCTAssertEqual(token["refresh_token"] as? String, "REFRESH-XYZ")
        XCTAssertEqual(token["token_type"] as? String, "Bearer")

        // installation_id phải KHỚP installation_uuid trong pbtxt (onboarding).
        let installID = try String(contentsOf: cli.appendingPathComponent("installation_id"), encoding: .utf8)
        let pbtxt = try String(contentsOf: cli.appendingPathComponent("jetski_state.pbtxt"), encoding: .utf8)
        XCTAssertTrue(pbtxt.contains("installation_uuid:  \"\(installID)\""), "pbtxt uuid phải khớp installation_id")
        XCTAssertTrue(pbtxt.contains("POST_ONBOARDING_STEP_TYPE_MANAGER_WELCOME"))

        // File token phải 0600.
        let attrs = try fm.attributesOfItem(atPath: gemini.appendingPathComponent("jetski-standalone-oauth-token").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testOMPCostScannerDeduplicationAndExtraction() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "omp_session_sample",
                withExtension: "jsonl"))
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-omp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceFixture,
            to: fixtureDir.appendingPathComponent(sourceFixture.lastPathComponent))
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        
        let result = await OMPCostScanner.scanSessions(
            roots: [fixtureDir],
            scanDays: 30,
            now: ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z") ?? Date())

        let totalTokens = result.dailyBuckets.reduce(0) { $0 + $1.tokens }
        let totalUSD = result.dailyBuckets.reduce(0.0) { $0 + $1.usd }

        // turn-2 (1500) + turn-4 (2500) = 4000 tokens (duplicate turn-2 ignored)
        XCTAssertEqual(totalTokens, 4000)
        XCTAssertEqual(totalUSD, 0.05, accuracy: 0.001)
        XCTAssertEqual(result.projectRecords.first?.displayName, "alpha")
        XCTAssertTrue(result.completed)
        XCTAssertFalse(result.wasTruncated)
    }

    func testPiCostScannerDeduplicationAndExtraction() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "pi_session_sample",
                withExtension: "jsonl"))
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-pi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceFixture,
            to: fixtureDir.appendingPathComponent(sourceFixture.lastPathComponent))
        defer { try? FileManager.default.removeItem(at: fixtureDir) }

        let result = await PiCostScanner.scanSessions(
            root: fixtureDir,
            scanDays: 30,
            now: ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z") ?? Date())

        let totalTokens = result.dailyBuckets.reduce(0) { $0 + $1.tokens }
        let totalUSD = result.dailyBuckets.reduce(0.0) { $0 + $1.usd }

        // pi-turn-2 (800) + pi-turn-3 (1200) = 2000 tokens (duplicate turn-2 ignored)
        XCTAssertEqual(totalTokens, 2000)
        XCTAssertEqual(totalUSD, 0.010, accuracy: 0.001)
        XCTAssertEqual(result.projectRecords.first?.displayName, "beta")
        XCTAssertTrue(result.completed)
        XCTAssertFalse(result.wasTruncated)
    }

    /// A single session past the size guard used to fail `parseSessionFile`,
    /// which marked the whole pass incomplete — so every other file's turns were
    /// thrown away and the provider's history froze. The oversized file must be
    /// skipped on its own while the rest of the scan still counts.
    func testOMPOversizedSessionIsSkippedAndMarksScanIncomplete() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "omp_session_sample",
                withExtension: "jsonl"))
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-omp-oversize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        try FileManager.default.copyItem(
            at: sourceFixture,
            to: fixtureDir.appendingPathComponent(sourceFixture.lastPathComponent))

        // Sparse file: past the guard on disk without writing 256 MB.
        let oversized = fixtureDir.appendingPathComponent("oversized.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(OMPCostScanner.maxSessionFileBytes) + 1)
        try handle.close()

        let result = await OMPCostScanner.scanSessions(
            roots: [fixtureDir],
            scanDays: 30,
            now: ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z") ?? Date())

        XCTAssertFalse(
            result.completed,
            "skipping any session must withhold destructive completion privileges")
        XCTAssertEqual(
            result.dailyBuckets.reduce(0) { $0 + $1.tokens }, 4000,
            "the normal session's turns must still be counted")
    }

    func testPiOversizedSessionIsSkippedAndMarksScanIncomplete() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "pi_session_sample",
                withExtension: "jsonl"))
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-pi-oversize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        try FileManager.default.copyItem(
            at: sourceFixture,
            to: fixtureDir.appendingPathComponent(sourceFixture.lastPathComponent))

        let oversized = fixtureDir.appendingPathComponent("oversized.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PiCostScanner.maxSessionFileBytes) + 1)
        try handle.close()

        let result = await PiCostScanner.scanSessions(
            root: fixtureDir,
            scanDays: 30,
            now: ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z") ?? Date())

        XCTAssertFalse(
            result.completed,
            "skipping any session must withhold destructive completion privileges")
        XCTAssertEqual(
            result.dailyBuckets.reduce(0) { $0 + $1.tokens }, 2000,
            "the normal session's turns must still be counted")
    }

    /// A pass that could not read everything still holds real turns. Discarding
    /// it left this provider's history frozen for days behind one bad file, so a
    /// partial pass must publish what it read — while never being allowed to
    /// replace history or stamp the counting revision from incomplete data.
    func testOMPPartialScanStillPublishesTurns() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "omp_session_sample",
                withExtension: "jsonl"))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-omp-partial-\(UUID().uuidString)", isDirectory: true)
        let roots = tmp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: roots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two sessions so the walk can stop after the first one and still have
        // read real turns — that is what "partial" means here.
        for name in ["a.jsonl", "b.jsonl"] {
            try FileManager.default.copyItem(
                at: sourceFixture, to: roots.appendingPathComponent(name))
        }

        let historyURL = tmp.appendingPathComponent("cost-history.json")
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z"))

        let full = await OMPCostScanner.scanSessions(roots: [roots], scanDays: 30, now: now)
        XCTAssertTrue(full.completed)
        XCTAssertEqual(full.dailyBuckets.reduce(0) { $0 + $1.tokens }, 4000)

        let priorScan = now.addingTimeInterval(-3600)
        _ = CostHistoryStore.applyWithReceipt(
            source: .omp,
            liveDays: [(now, 0.01, 100, [("seed", 0.01, 100)])],
            now: priorScan,
            windowDays: OMPCostScanner.chartWindowDays,
            url: historyURL,
            replacingSource: true,
            liveScanSucceeded: true,
            countingRevision: OMPCostScanner.countingRevision)
        let stampedBefore = CostHistoryStore.read(url: historyURL).scannedAt?["omp"]

        let report = await OMPCostScanner.loadReport(
            now: now,
            forceRescan: true,
            historyURL: historyURL,
            scanRoots: [roots],
            maxEntries: 1)

        XCTAssertEqual(report.last30Tokens, 4000)
        XCTAssertFalse(report.scanConfidence.live)
        XCTAssertEqual(
            CostHistoryStore.read(url: historyURL).scannedAt?["omp"],
            stampedBefore,
            "a partial pass must not stamp scan freshness")
    }

    func testPiPartialScanStillPublishesTurns() async throws {
        let sourceFixture = try XCTUnwrap(
            Bundle(for: NewProviderTests.self).url(
                forResource: "pi_session_sample",
                withExtension: "jsonl"))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-pi-partial-\(UUID().uuidString)", isDirectory: true)
        let sessions = tmp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["a.jsonl", "b.jsonl"] {
            try FileManager.default.copyItem(
                at: sourceFixture, to: sessions.appendingPathComponent(name))
        }

        let historyURL = tmp.appendingPathComponent("cost-history.json")
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z"))
        let priorScan = now.addingTimeInterval(-3600)
        _ = CostHistoryStore.applyWithReceipt(
            source: .pi,
            liveDays: [(now, 0.01, 100, [("seed", 0.01, 100)])],
            now: priorScan,
            windowDays: PiCostScanner.chartWindowDays,
            url: historyURL,
            replacingSource: true,
            liveScanSucceeded: true,
            countingRevision: PiCostScanner.countingRevision)
        let stampedBefore = CostHistoryStore.read(url: historyURL).scannedAt?["pi"]

        let report = await PiCostScanner.loadReport(
            now: now,
            forceRescan: true,
            historyURL: historyURL,
            sessionsRoot: sessions,
            maxEntries: 1)

        XCTAssertEqual(report.last30Tokens, 2000)
        XCTAssertFalse(report.scanConfidence.live)
        XCTAssertEqual(
            CostHistoryStore.read(url: historyURL).scannedAt?["pi"],
            stampedBefore,
            "a partial pass must not stamp scan freshness")
    }

    func testOMPScannerHonorsEntryLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-omp-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("a.jsonl"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("b.jsonl"))

        let result = await OMPCostScanner.scanSessions(
            roots: [root],
            scanDays: 30,
            maxEntries: 1)

        XCTAssertTrue(result.dailyBuckets.isEmpty)
        XCTAssertTrue(result.projectRecords.isEmpty)
        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.wasTruncated)
    }

    func testPiScannerHonorsEntryLimitWithoutClaimingLiveCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-pi-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("a.jsonl"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("b.jsonl"))

        let result = await PiCostScanner.scanSessions(
            root: root,
            scanDays: 30,
            maxEntries: 1)

        XCTAssertFalse(result.completed)
        XCTAssertTrue(result.wasTruncated)
    }

    func testOMPPiScannerUnreadableRootDoesNotClaimCompletion() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-missing-\(UUID().uuidString)", isDirectory: true)

        let omp = await OMPCostScanner.scanSessions(roots: [missing], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: missing, scanDays: 30)

        XCTAssertFalse(omp.completed)
        XCTAssertFalse(pi.completed)
        XCTAssertFalse(omp.wasTruncated)
        XCTAssertFalse(pi.wasTruncated)
    }

    func testOMPPiMalformedCompleteLineDowngradesCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-malformed-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json\n".utf8).write(to: root.appendingPathComponent("bad.jsonl"))
        defer { try? FileManager.default.removeItem(at: root) }

        let omp = await OMPCostScanner.scanSessions(roots: [root], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: root, scanDays: 30)

        XCTAssertFalse(omp.completed)
        XCTAssertFalse(pi.completed)
    }

    func testOMPPiMalformedUnterminatedTailIsTolerated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("tail.jsonl"))
        defer { try? FileManager.default.removeItem(at: root) }

        let omp = await OMPCostScanner.scanSessions(roots: [root], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: root, scanDays: 30)

        XCTAssertTrue(omp.completed)
        XCTAssertTrue(pi.completed)
    }

    func testOMPPiLargeSingleLineUsesStreamingCursor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-large-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var data = Data(repeating: 0x20, count: 2 * 1_024 * 1_024)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent("large.jsonl"))
        defer { try? FileManager.default.removeItem(at: root) }

        let omp = await OMPCostScanner.scanSessions(roots: [root], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: root, scanDays: 30)

        XCTAssertTrue(omp.completed)
        XCTAssertTrue(pi.completed)
    }

    func testOMPPiRejectSingleLinePastMemoryGuard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-line-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large-line.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(OMPCostScanner.maxSessionLineBytes) + 1)
        try handle.close()

        let omp = await OMPCostScanner.scanSessions(roots: [root], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: root, scanDays: 30)

        XCTAssertFalse(omp.completed)
        XCTAssertFalse(pi.completed)
        XCTAssertTrue(omp.dailyBuckets.isEmpty)
        XCTAssertTrue(pi.dailyBuckets.isEmpty)
    }

    func testOMPPiInvalidDuplicateDoesNotBlockValidUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-jsonl-duplicate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let contents = """
        {"type":"message","id":"same","message":{"role":"assistant","timestamp":"\(timestamp)","usage":{}}}
        {"type":"message","id":"same","message":{"role":"assistant","timestamp":"\(timestamp)","usage":{"totalTokens":100}}}

        """
        try Data(contents.utf8).write(to: root.appendingPathComponent("duplicate.jsonl"))

        let omp = await OMPCostScanner.scanSessions(roots: [root], scanDays: 30)
        let pi = await PiCostScanner.scanSessions(root: root, scanDays: 30)

        XCTAssertEqual(omp.dailyBuckets.reduce(0) { $0 + $1.tokens }, 100)
        XCTAssertEqual(pi.dailyBuckets.reduce(0) { $0 + $1.tokens }, 100)
        XCTAssertTrue(omp.completed)
        XCTAssertTrue(pi.completed)
    }

    func testOMPAgentConfigStoreParseAndSerialize() {
        let sampleYAML = """
        setupVersion: 2
        modelRoles:
          default: google-antigravity/gemini-3.7-flash:high
          plan: claude-opus-4-6:auto
          slow: gpt-5.6-sol:max
          smol: gpt-5.2-mini
        prewalk:
          enabled: true
          into: smol
        """
        let parsed = OMPAgentConfigStore.parse(content: sampleYAML)
        XCTAssertEqual(parsed.modelRoles.defaultRole, "google-antigravity/gemini-3.7-flash:high")
        XCTAssertEqual(parsed.modelRoles.plan, "claude-opus-4-6:auto")
        XCTAssertEqual(parsed.modelRoles.slow, "gpt-5.6-sol:max")
        XCTAssertEqual(parsed.modelRoles.smol, "gpt-5.2-mini")
        XCTAssertTrue(parsed.prewalkEnabled)
    }
    /// The store never shrinks a day, so a corrected formula must be able to
    /// re-derive the whole window — and an older build must never merge its
    /// numbers back over history a newer one already rewrote.
    func testOMPAndPiCountingScanPlanCoversAllThreeCases() {
        let inc = 3
        for label in ["omp", "pi"] {
            let rev = label == "omp"
                ? OMPCostScanner.countingRevision : PiCostScanner.countingRevision
            let window = label == "omp"
                ? OMPCostScanner.chartWindowDays : PiCostScanner.chartWindowDays
            func plan(_ stored: Int) -> (windowDays: Int, replacing: Bool, historyOnly: Bool) {
                label == "omp"
                    ? OMPCostScanner.countingScanPlan(
                        storedRevision: stored, incrementalDays: inc)
                    : PiCostScanner.countingScanPlan(
                        storedRevision: stored, incrementalDays: inc)
            }
            let stale = plan(rev - 1)
            XCTAssertTrue(stale.replacing, label)
            XCTAssertFalse(stale.historyOnly, label)
            XCTAssertEqual(stale.windowDays, window, label)

            let current = plan(rev)
            XCTAssertFalse(current.replacing, label)
            XCTAssertFalse(current.historyOnly, label)
            XCTAssertEqual(current.windowDays, inc, label)

            let newer = plan(rev + 1)
            XCTAssertTrue(newer.historyOnly, label)
            XCTAssertFalse(newer.replacing, label)
        }
    }

    // MARK: - Antigravity per-account snapshot refresh

    private func agAccount(_ label: String) -> AntigravityOAuthStore.Account {
        AntigravityOAuthStore.Account(label: label, email: label, refreshToken: "t-\(label)")
    }

    func testAntigravityAccountCardFallsBackWhenNoOAuthAccountsExist() {
        XCTAssertFalse(AntigravityAccountQuotaPresentation.usesAccountCard(accountCount: 0))
        XCTAssertTrue(AntigravityAccountQuotaPresentation.usesAccountCard(accountCount: 1))
    }

    func testAntigravityAccountDisplayNameKeepsDomainDistinct() {
        let work = AntigravityOAuthStore.Account(
            label: "work", email: "alex@work.com", refreshToken: "work-token")
        let personal = AntigravityOAuthStore.Account(
            label: "personal", email: "alex@gmail.com", refreshToken: "personal-token")

        XCTAssertEqual(
            AntigravityAccountQuotaPresentation.displayName(for: work), "alex@work.com")
        XCTAssertEqual(
            AntigravityAccountQuotaPresentation.displayName(for: personal), "alex@gmail.com")
    }

    func testAntigravityAccountMustRemainAuthorizedBeforeSnapshotSave() {
        let account = agAccount("a@x.com")
        XCTAssertTrue(AntigravityAccountSnapshotRefresher.accountStillAuthorized(
            account,
            in: AntigravityOAuthStore.Store(accounts: [account]),
            resolvedRefreshToken: "isolated-token",
            usedRefreshToken: "isolated-token"))
        XCTAssertFalse(AntigravityAccountSnapshotRefresher.accountStillAuthorized(
            account,
            in: AntigravityOAuthStore.Store(accounts: []),
            resolvedRefreshToken: "isolated-token",
            usedRefreshToken: "isolated-token"))
        XCTAssertFalse(AntigravityAccountSnapshotRefresher.accountStillAuthorized(
            account,
            in: AntigravityOAuthStore.Store(accounts: [account]),
            resolvedRefreshToken: nil,
            usedRefreshToken: "isolated-token"))
        XCTAssertFalse(AntigravityAccountSnapshotRefresher.accountStillAuthorized(
            account,
            in: AntigravityOAuthStore.Store(accounts: [account]),
            resolvedRefreshToken: "rotated-token",
            usedRefreshToken: "isolated-token"))
    }

    func testAntigravityStaleAccountsIncludeNeverFetchedAccount() {
        let now = Date()
        let cached: [String: Date] = ["a@x.com": now]
        let due = AntigravityAccountSnapshotRefresher.staleAccounts(
            accounts: [agAccount("a@x.com"), agAccount("b@x.com")],
            now: now,
            cachedAt: { cached[$0] })
        XCTAssertEqual(due.map(\.label), ["b@x.com"])
    }

    func testAntigravityStaleAccountsReturnsEveryAgedOutAccount() {
        let now = Date()
        let old = now.addingTimeInterval(-AntigravityAccountSnapshotRefresher.maxSnapshotAge - 1)
        let cached: [String: Date] = ["a@x.com": old, "b@x.com": old]
        let due = AntigravityAccountSnapshotRefresher.staleAccounts(
            accounts: [agAccount("a@x.com"), agAccount("b@x.com")],
            now: now,
            cachedAt: { cached[$0] })
        XCTAssertEqual(due.map(\.label), ["a@x.com", "b@x.com"])
    }

    func testAntigravityStaleAccountsSkipsFreshSnapshots() {
        let now = Date()
        let fresh = now.addingTimeInterval(-AntigravityAccountSnapshotRefresher.maxSnapshotAge + 1)
        let cached: [String: Date] = ["a@x.com": fresh, "b@x.com": fresh]
        XCTAssertTrue(
            AntigravityAccountSnapshotRefresher.staleAccounts(
                accounts: [agAccount("a@x.com"), agAccount("b@x.com")],
                now: now,
                cachedAt: { cached[$0] }).isEmpty)
    }

    // MARK: - CommandCode: balance is not a quota

    private func commandCodeCredits(
        monthly: Double, purchased: Double = 0, premium: Double = 0
    ) -> Data {
        Data("""
        {"credits":{"monthlyCredits":\(monthly),"purchasedCredits":\(purchased),\
        "premiumMonthlyCredits":\(premium),"opensourceMonthlyCredits":0}}
        """.utf8)
    }

    /// The plan lookup is what supplies the denominator; without it there is no
    /// percentage, so the balance must not be dressed up as a full window.
    func testCommandCodeUnknownPlanPublishesBalanceNotFullWindow() {
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 60.97),
            subscriptionData: Data(#"{"success":true,"data":null}"#.utf8))
        XCTAssertNil(status.error)
        XCTAssertTrue(status.windows.isEmpty, "a balance has no percentage to chart")
        XCTAssertEqual(status.creditsRemaining ?? 0, 60.97, accuracy: 0.001)
        XCTAssertNil(status.cost)
    }

    func testCommandCodeUnknownPlanSumsEveryBalance() {
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 10, purchased: 5, premium: 2.5),
            subscriptionData: nil)
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(status.creditsRemaining ?? 0, 17.5, accuracy: 0.001)
    }

    /// A known plan still charts the monthly grant — top-ups stay a balance
    /// because they have no allowance of their own to divide by.
    func testCommandCodeKnownPlanChartsGrantAndKeepsTopUpsAsBalance() {
        let subscription = Data(#"""
        {"success":true,"data":{"planId":"individual-pro","status":"active",        "currentPeriodEnd":"2099-08-01T00:00:00.000Z"}}
        """#.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 12, purchased: 7),
            subscriptionData: subscription)
        XCTAssertEqual(status.planName, "Pro")
        XCTAssertEqual(status.windows.count, 1)
        let window = try? XCTUnwrap(status.windows.first)
        XCTAssertEqual(window?.label, "Tháng")
        // $12 left of the $30 Pro grant → 60% spent.
        XCTAssertEqual(window?.usedPct, 60)
        XCTAssertEqual(window?.remainingPct, 40)
        XCTAssertEqual(status.creditsRemaining ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(status.cost?.used ?? 0, 18, accuracy: 0.001)
    }

    func testCommandCodeNoCreditsAtAllIsAnError() {
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 0),
            subscriptionData: nil)
        XCTAssertNotNil(status.error)
        XCTAssertTrue(status.windows.isEmpty)
    }

    /// The header spinner and the card skeleton share this predicate; keying
    /// either on `windows.isEmpty` alone left a balance-only provider stuck on
    /// "Đang tải…" forever next to its own populated credits row.
    func testBalanceOnlyStatusIsNotAwaitingContent() {
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 60.97),
            subscriptionData: nil)
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(status.renderableCreditsBalance ?? 0, 60.97, accuracy: 0.001)
        XCTAssertFalse(status.popoverIsAwaitingFirstContent)
        XCTAssertTrue(status.hasRenderableQuotaContent)
    }

    func testStatusWithNothingFetchedIsAwaitingContent() {
        let pending = ProviderStatus(
            id: "commandcode", displayName: "Command Code", windows: [], lastUpdated: Date())
        XCTAssertTrue(pending.popoverIsAwaitingFirstContent)
        XCTAssertFalse(pending.hasRenderableQuotaContent)
    }

    func testErroredStatusIsNotAwaitingContent() {
        let failed = ProviderStatus(
            id: "commandcode", displayName: "Command Code", windows: [],
            lastUpdated: Date(), error: "boom")
        XCTAssertFalse(failed.popoverIsAwaitingFirstContent, "an error card is not a spinner")
        XCTAssertFalse(failed.hasRenderableQuotaContent)
    }

    func testCommandCodeRejectsNonFiniteNumericStrings() {
        let credits = Data(#"{"credits":{"monthlyCredits":60.97,"purchasedCredits":0,"premiumMonthlyCredits":0,"monthlyCreditsGranted":"Infinity"}}"#.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: credits, subscriptionData: nil)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(status.creditsRemaining ?? 0, 60.97, accuracy: 0.001)
    }

    func testCommandCodeDropsWindowLimitWithoutMeasuredUsage() {
        let credits = Data(#"{"credits":{"monthlyCredits":5,"purchasedCredits":0,"premiumMonthlyCredits":0},"windowLimits":{"limited":true,"fiveHour":{"cap":14}}}"#.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: credits, subscriptionData: nil)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(status.creditsRemaining ?? 0, 5, accuracy: 0.001)
    }

    /// Production payload shape: the grant total and the rolling caps both ship
    /// inside `/credits`, so a plan the catalog never heard of still charts.
    func testCommandCodeUsesGrantedTotalAndWindowLimits() {
        let credits = Data("""
        {"credits":{"monthlyCredits":60.825467787,"purchasedCredits":0,
        "premiumMonthlyCredits":0,"monthlyCreditsGranted":70},
        "windowLimits":{"limited":true,"exceeded":null,
        "fiveHour":{"used":0.185009678,"cap":14,"exceeded":false,"resetAt":1789293206298},
        "weekly":{"used":9.174532213,"cap":35,"exceeded":false,"resetAt":1789703513267}}}
        """.utf8)
        let subscription = Data(#"{"success":true,"data":{"planId":"individual-goat","status":"active"}}"#.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: credits, subscriptionData: subscription)

        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.map(\.label), ["5 giờ", "Tuần", "Tháng"])
        // 0.185 of 14 → 1% spent; 9.17 of 35 → 26%; 60.83 of a 70 grant → 13%.
        XCTAssertEqual(status.windows[0].usedPct, 1)
        XCTAssertEqual(status.windows[1].usedPct, 26)
        XCTAssertEqual(status.windows[2].usedPct, 13)
        XCTAssertEqual(status.windows[2].remainingPct, 87)
        XCTAssertNotNil(status.windows[0].resetDate)
        XCTAssertEqual(status.cost?.limit ?? 0, 70, accuracy: 0.001)
        XCTAssertNil(status.creditsRemaining, "the grant is charted, not a balance")
    }

    /// The granted total must win over the catalog: a plan whose real allowance
    /// has changed would otherwise be charted against a stale constant.
    func testCommandCodeGrantedTotalOverridesPlanCatalog() {
        let credits = Data("""
        {"credits":{"monthlyCredits":20,"purchasedCredits":0,
        "premiumMonthlyCredits":0,"monthlyCreditsGranted":50}}
        """.utf8)
        let subscription = Data(#"{"success":true,"data":{"planId":"individual-pro","status":"active"}}"#.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: credits, subscriptionData: subscription)
        XCTAssertEqual(status.planName, "Pro")
        // 20 of 50 granted → 60% spent, NOT the catalog's $30 Pro figure (33%).
        XCTAssertEqual(status.windows.first?.usedPct, 60)
    }

    /// No `monthlyCreditsGranted` (older response) still falls back to the plan.
    func testCommandCodeFallsBackToCatalogWhenGrantAbsent() {
        let status = CommandCodeProvider._parseForTesting(
            creditsData: commandCodeCredits(monthly: 12),
            subscriptionData: Data(#"{"success":true,"data":{"planId":"individual-pro","status":"active"}}"#.utf8))
        XCTAssertEqual(status.windows.first?.usedPct, 60)
    }

    func testCommandCodeSkipsWindowLimitsWhenNotLimited() {
        let credits = Data("""
        {"credits":{"monthlyCredits":10,"purchasedCredits":0,"premiumMonthlyCredits":0,
        "monthlyCreditsGranted":20},
        "windowLimits":{"limited":false,"fiveHour":{"used":1,"cap":14}}}
        """.utf8)
        let status = CommandCodeProvider._parseForTesting(
            creditsData: credits, subscriptionData: nil)
        XCTAssertEqual(status.windows.map(\.label), ["Tháng"])
    }

    // MARK: - OpenCode Go: API key source

    func testOpenCodeGoKeyPrefersEnvOverConfig() {
        XCTAssertEqual(
            OpenCodeGoProvider.resolvedAPIKey(
                env: ["OPENCODE_API_KEY": "sk-env"], configKey: "sk-config"),
            "sk-env")
        XCTAssertEqual(
            OpenCodeGoProvider.resolvedAPIKey(
                env: ["OPENCODE_ZEN_API_KEY": "sk-zen"], configKey: nil),
            "sk-zen")
        XCTAssertEqual(
            OpenCodeGoProvider.resolvedAPIKey(env: [:], configKey: "  sk-config  "),
            "sk-config")
    }

    /// A blank entry must read as "no key" so the provider falls through to the
    /// cookie path instead of sending `Bearer ` and failing.
    func testOpenCodeGoBlankKeyResolvesToNil() {
        XCTAssertNil(OpenCodeGoProvider.resolvedAPIKey(env: ["OPENCODE_API_KEY": "   "], configKey: "  "))
        XCTAssertNil(OpenCodeGoProvider.resolvedAPIKey(env: [:], configKey: nil))
    }

    /// The server's own wording is the actionable part; "HTTP 403" is not.
    func testOpenCodeGoAPIErrorSurfacesServerMessage() {
        let body = Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
        XCTAssertEqual(
            OpenCodeGoProvider.apiErrorMessage(body, status: 403),
            "OpenCode Go subscription required. (HTTP 403)")
        XCTAssertEqual(
            OpenCodeGoProvider.apiErrorMessage(Data("not json".utf8), status: 500),
            "HTTP 500")
    }

    /// The key path feeds the same tolerant parser as the cookie path, so a
    /// plain JSON usage body charts without a shape of its own.
    func testOpenCodeGoParsesPlainJSONUsageBody() {
        let json = """
        {"rollingUsage":{"usagePercent":67.3,"resetInSec":12600},
         "weeklyUsage":{"usagePercent":34.1,"resetInSec":345600}}
        """
        let status = OpenCodeGoProvider._parseForTesting(pageText: json, zenBalance: nil)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.map(\.label), ["Rolling", "Tuần"])
        XCTAssertEqual(status.windows[0].usedPct, 67)
        XCTAssertEqual(status.windows[1].usedPct, 34)
    }

    /// `used`/`limit` instead of a percent is one of the shapes the parser
    /// already accepts — the API body may use either.
    func testOpenCodeGoParsesUsedOverLimitUsageBody() {
        let json = """
        {"usage":{"rolling":{"used":25,"limit":100,"resetInSec":600},
                  "weekly":{"used":10,"limit":40,"resetInSec":86400}}}
        """
        let status = OpenCodeGoProvider._parseForTesting(pageText: json, zenBalance: nil)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows[0].usedPct, 25)
        XCTAssertEqual(status.windows[1].usedPct, 25)
    }

    /// Live Zen payload: `percent` is already 0-100, so an integer `1` means
    /// 1% used — it must NOT be rescaled as a 0-1 fraction into 100%.
    func testOpenCodeGoIntegerPercentPayloadNotRescaled() {
        let json = """
        {"usage":{"rolling":{"percent":0,"resetsAt":"2030-01-01T00:00:00.000Z"},
                  "weekly":{"percent":1,"resetsAt":"2030-01-08T00:00:00.000Z"},
                  "monthly":{"percent":57,"resetsAt":"2030-02-01T00:00:00.000Z"}}}
        """
        let status = OpenCodeGoProvider._parseForTesting(pageText: json, zenBalance: nil)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.map(\.usedPct), [0, 1, 57])
    }

    /// Fraction-style payloads still scale up — decided once per payload,
    /// not per value.
    func testOpenCodeGoFractionPayloadScalesToPercent() {
        let json = """
        {"usage":{"rolling":{"percent":0.67,"resetInSec":600},
                  "weekly":{"percent":0.34,"resetInSec":86400}}}
        """
        let status = OpenCodeGoProvider._parseForTesting(pageText: json, zenBalance: nil)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.windows.map(\.usedPct), [67, 34])
    }

    /// Storage may carry metadata for several orgs; emit one session per
    /// internal-org candidate so the fetcher can try each — auth1 tokens only
    /// resolve against their own org ("No organizations found for auth1 user").
    func testDevinImporterEmitsOneSessionPerOrgCandidate() {
        let storage: [String: String] = [
            "auth1_session": "{\"token\":\"auth1_0123456789abcdef0123456789\"}",
            "sidebar-collapsed-folders:org-aaaaaaaaa": "[]",
            "feature-flags-cache:user-1:org-bbbbbbbbb": "1",
        ]
        let sessions = DevinSessionImporter.sessions(from: storage, sourceLabel: "test")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(
            Set(sessions.map(\.internalOrganizationID)),
            ["org-aaaaaaaaa", "org-bbbbbbbbb"])
        // Sorted-key scan keeps the first candidate deterministic.
        XCTAssertEqual(sessions.first?.internalOrganizationID, "org-bbbbbbbbb")
        XCTAssertEqual(Set(sessions.map(\.accessToken)).count, 1)
    }

    /// `billing/usage/daily-usage?cycle=current&view=all` — shape observed
    /// live on 2026-09-22: cycle bounds + per-day amount/cumulative rows +
    /// per-product totals. Parser must keep days, products and the total.
    func testDevinDailyUsageParser() {
        let json = """
        {
          "cycle_start": "2026-09-22T03:27:08+00:00",
          "cycle_end": "2026-10-22T03:27:08+00:00",
          "previous_cycle_available": true,
          "total": 12.5,
          "days": [
            {"date": "2026-09-21", "amount": 0.0, "cumulative": 0.0},
            {"date": "2026-09-22", "amount": 4.5, "cumulative": 4.5},
            {"date": "2026-09-23", "amount": 8.0, "cumulative": 12.5}
          ],
          "products": [
            {"view": "sessions", "total": 10.0,
             "days": [{"date": "2026-09-23", "amount": 8.0, "cumulative": 10.0}]},
            {"view": "reviews", "total": 2.5, "days": []}
          ]
        }
        """
        let history = DevinUsageParser.parseDailyUsage(Data(json.utf8))
        XCTAssertNotNil(history)
        XCTAssertEqual(history?.days.count, 3)
        XCTAssertEqual(history?.days[1].amount, 4.5)
        XCTAssertEqual(history?.days[2].cumulative, 12.5)
        XCTAssertEqual(history?.products.count, 2)
        XCTAssertEqual(history?.products.first?.view, "sessions")
        XCTAssertEqual(history?.products.first?.total, 10.0)
        XCTAssertEqual(history?.total, 12.5)
        XCTAssertNotNil(history?.cycleStart)
        XCTAssertNotNil(history?.cycleEnd)
        XCTAssertTrue(DevinUsageParser.previousCycleAvailable(in: Data(json.utf8)))
    }

    /// Garbage payload → nil (chart stays hidden), never a thrown error.
    func testDevinDailyUsageParserRejectsBadPayload() {
        XCTAssertNil(DevinUsageParser.parseDailyUsage(Data("{}".utf8)))
        XCTAssertNil(DevinUsageParser.parseDailyUsage(Data("[]".utf8)))
        XCTAssertNil(DevinUsageParser.parseDailyUsage(Data("not json".utf8)))
    }

    /// Previous + current cycle merge: days dedupe by date, product totals
    /// sum per view, cycle bounds span both.
    func testDevinDailyUsageMergeCycles() {
        func day(_ iso: String, _ amount: Double) -> DevinDailyUsage {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return DevinDailyUsage(date: f.date(from: iso)!, amount: amount, cumulative: 0)
        }
        let previous = DevinUsageHistory(
            days: [day("2026-08-23", 1), day("2026-08-24", 2)],
            products: [DevinProductUsage(view: "sessions", total: 3, days: [day("2026-08-24", 2)])],
            cycleStart: Date(timeIntervalSince1970: 100),
            cycleEnd: Date(timeIntervalSince1970: 200),
            total: 3)
        let current = DevinUsageHistory(
            days: [day("2026-09-22", 4)],
            products: [DevinProductUsage(view: "sessions", total: 4, days: [day("2026-09-22", 4)]),
                       DevinProductUsage(view: "reviews", total: 1, days: [])],
            cycleStart: Date(timeIntervalSince1970: 300),
            cycleEnd: Date(timeIntervalSince1970: 400),
            total: 4)
        let merged = DevinUsageParser.mergeCycles(previous: previous, current: current)
        XCTAssertEqual(merged.days.count, 3)
        XCTAssertEqual(merged.days.map(\.amount), [1, 2, 4])
        XCTAssertEqual(merged.total, 7)
        XCTAssertEqual(merged.cycleStart, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(merged.cycleEnd, Date(timeIntervalSince1970: 400))
        let sessions = merged.products.first { $0.view == "sessions" }
        XCTAssertEqual(sessions?.total, 6)
        XCTAssertEqual(merged.products.count, 2)
    }

    /// `readTextEntries` scans the whole profile LevelDB — unscoped. Without
    /// the origin guard, a foreign auth0 key (e.g. ChatGPT's auth0spajs entry
    /// in the same store) is mistaken for a Devin session: a token with no
    /// org, surfacing as "missing organization".
    func testDevinImporterRejectsForeignOriginStorageKeys() {
        let sep = "\u{0}\u{1}"
        XCTAssertTrue(DevinSessionImporter.isOwnOriginTextKey(
            "_https://app.devin.ai\(sep)@@auth0spajs@@::devin::"))
        XCTAssertFalse(DevinSessionImporter.isOwnOriginTextKey(
            "_https://chatgpt.com\(sep)@@auth0spajs@@::app_2SKx67EdpoN0G6j64rFvigXD::"))
        XCTAssertFalse(DevinSessionImporter.isOwnOriginTextKey(
            "_https://example.com\(sep)auth1_session"))
    }

    /// DIAGNOSTIC — remove before commit.
    func testZZZDevinDiagnosticRawPayloads() async throws {
        struct RecordingTransport: ProviderHTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let (data, resp) = try await ProviderHTTPClient.shared.data(for: request)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("DIAG-URL \(request.url?.absoluteString ?? "?")")
                    print("DIAG-KEYS \(obj.keys.sorted())")
                    for (k, v) in obj where !(v is [Any]) {
                        print("DIAG-FIELD \(k)=\(v)")
                    }
                }
                return (data, resp)
            }
        }
        let sessions = DevinSessionImporter.importSessions(browserDetection: BrowserDetection())
        guard let s = sessions.first(where: { $0.internalOrganizationID != nil }) else {
            print("DIAG no session"); return
        }
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: s.accessToken, organization: s.organization,
            internalOrganizationID: s.internalOrganizationID, sourceLabel: s.sourceLabel)
        _ = try? await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth, transport: RecordingTransport())
    }

    // MARK: - Devin CLI cost scanner (transcripts → CostHistoryStore.devin)

    private var devinUTCCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Synthetic transcript — steps carry `metrics.prompt_tokens` +
    /// `completion_tokens`; `cached_tokens` is a subset of prompt and must
    /// NOT be added again. Steps without metrics carry no usage.
    private func writeDevinTranscript(_ json: String, to dir: URL, name: String) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testDevinCostScannerCountsPromptPlusCompletionNotCached() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeDevinTranscript("""
        {
          "schema_version": 1,
          "session_id": "s1",
          "agent": {"model_name": "swe-2-max"},
          "steps": [
            {"timestamp": "2026-09-21T10:00:00Z", "model_name": "swe-2-max",
             "metrics": {"prompt_tokens": 1000, "completion_tokens": 100, "cached_tokens": 400}},
            {"timestamp": "2026-09-21T11:00:00Z", "model_name": "swe-2-high",
             "metrics": {"prompt_tokens": 500, "completion_tokens": 50}},
            {"timestamp": "2026-09-22T09:00:00Z", "model_name": "swe-2-max",
             "metrics": {"prompt_tokens": 200, "completion_tokens": 20, "cached_tokens": 200}},
            {"timestamp": "2026-09-22T09:30:00Z", "model_name": "swe-2-max"},
            {"timestamp": "2026-09-22T10:00:00Z"}
          ],
          "final_metrics": {"total_prompt_tokens": 1700, "total_completion_tokens": 170}
        }
        """, to: dir, name: "session-one.json")

        let cal = devinUTCCalendar
        let now = cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 22, hour: 12))!
        let result = DevinCostScanner.scanTranscripts(
            root: dir, scanDays: 30, now: now, calendar: cal)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.dailyBuckets.count, 2)

        let sep21 = cal.startOfDay(for: cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 21))!)
        let sep22 = cal.startOfDay(for: cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 22))!)
        let day1 = result.dailyBuckets.first { $0.date == sep21 }
        let day2 = result.dailyBuckets.first { $0.date == sep22 }

        // 1000+100 + 500+50 = 1650 (cached 400/200 are inside prompt_tokens).
        XCTAssertEqual(day1?.tokens, 1650)
        XCTAssertEqual(day2?.tokens, 220)

        // USD at published API rates (swe-2: $0.75 in / $3.75 out /
        // $0.075 cache-read per 1M):
        //   swe-2-max : 600×0.75 + 400×0.075 + 100×3.75 = 855 µ$/1M
        //   swe-2-high: 500×0.75 + 50×3.75              = 562.5
        XCTAssertEqual(day1?.usd ?? -1, 0.0014175, accuracy: 0.0000001)
        // Sep22 swe-2-max: 0 uncached + 200×0.075 + 20×3.75 = 90 µ$/1M
        XCTAssertEqual(day2?.usd ?? -1, 0.00009, accuracy: 0.0000001)

        // Models grouped per day; token-sorted, carrying their own USD.
        XCTAssertEqual(day1?.models.count, 2)
        XCTAssertEqual(day1?.models.first?.name, "swe-2-max")
        XCTAssertEqual(day1?.models.first?.tokens, 1100)
        XCTAssertEqual(day1?.models.first?.usd ?? -1, 0.000855, accuracy: 0.0000001)
        XCTAssertEqual(day1?.models.last?.name, "swe-2-high")
        XCTAssertEqual(day1?.models.last?.tokens, 550)
        XCTAssertEqual(day1?.models.last?.usd ?? -1, 0.0005625, accuracy: 0.0000001)
    }

    /// Pricing table mirrors the `modelCostData` API rates published on
    /// docs.devin.ai/desktop/models. Unknown models keep usd = 0 (tokens
    /// still count — the UI falls back to showing them).
    func testDevinPricingUsesPublishedRatesAndSkipsUnknownModels() {
        XCTAssertEqual(
            DevinCostScanner.usdCost(
                model: "swe-2-max", promptTokens: 1_000_000,
                cachedTokens: 0, completionTokens: 0),
            0.75, accuracy: 0.0001)
        XCTAssertEqual(
            DevinCostScanner.usdCost(
                model: "swe-2-max", promptTokens: 1_000_000,
                cachedTokens: 1_000_000, completionTokens: 1_000_000),
            0.075 + 3.75, accuracy: 0.0001)
        // cached > prompt clamps at zero uncached — never negative cost.
        XCTAssertEqual(
            DevinCostScanner.usdCost(
                model: "swe-2-high", promptTokens: 100,
                cachedTokens: 500, completionTokens: 0),
            500 * 0.075 / 1_000_000, accuracy: 0.0000001)
        XCTAssertEqual(
            DevinCostScanner.usdCost(
                model: "some-future-model", promptTokens: 1_000_000,
                cachedTokens: 0, completionTokens: 0),
            0, accuracy: 0.0001)
    }

    /// Malformed/legacy transcripts must not abort the scan: the bad file
    /// marks the pass incomplete (never claims LIVE) while valid transcripts
    /// still contribute their days.
    func testDevinCostScannerMalformedFileMarksIncompleteButKeepsData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeDevinTranscript("not json at all", to: dir, name: "a-bad.json")
        try writeDevinTranscript("""
        {"steps": [
          {"timestamp": "2026-09-22T08:00:00Z",
           "metrics": {"prompt_tokens": 42, "completion_tokens": 8}}
        ]}
        """, to: dir, name: "b-good.json")

        let cal = devinUTCCalendar
        let now = cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 22, hour: 12))!
        let result = DevinCostScanner.scanTranscripts(
            root: dir, scanDays: 30, now: now, calendar: cal)

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.dailyBuckets.reduce(0) { $0 + $1.tokens }, 50)
        // Missing metrics → model falls back to "devin".
        XCTAssertEqual(result.dailyBuckets.first?.models.first?.name, "devin")
    }

    /// Empty transcript directory → completed, zero buckets (not an error).
    func testDevinCostScannerEmptyDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = DevinCostScanner.scanTranscripts(
            root: dir, scanDays: 30, calendar: devinUTCCalendar)
        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.dailyBuckets.isEmpty)
    }

    /// Steps older than the scan window are dropped.
    func testDevinCostScannerHonorsScanWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeDevinTranscript("""
        {"steps": [
          {"timestamp": "2026-08-01T08:00:00Z",
           "metrics": {"prompt_tokens": 999, "completion_tokens": 1}},
          {"timestamp": "2026-09-22T08:00:00Z",
           "metrics": {"prompt_tokens": 10, "completion_tokens": 5}}
        ]}
        """, to: dir, name: "s.json")

        let cal = devinUTCCalendar
        let now = cal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 22, hour: 12))!
        let result = DevinCostScanner.scanTranscripts(
            root: dir, scanDays: 7, now: now, calendar: cal)

        XCTAssertEqual(result.dailyBuckets.count, 1)
        XCTAssertEqual(result.dailyBuckets.first?.tokens, 15)
    }

    /// `makeDevinReport` aggregates last30 + picks the top model by tokens.
    func testDevinReportFromHistoryWindow() {
        let cal = devinUTCCalendar
        let day = { (offset: Int) -> Date in
            cal.date(byAdding: .day, value: offset,
                     to: cal.startOfDay(for: Date()))!
        }
        let window = [
            CostHistoryStore.DayBucket(
                date: day(-1), usd: 0, tokens: 100,
                models: [CostHistoryStore.Model(name: "swe-2-max", usd: 0, tokens: 100)]),
            CostHistoryStore.DayBucket(
                date: day(0), usd: 0, tokens: 40,
                models: [
                    CostHistoryStore.Model(name: "swe-2-max", usd: 0, tokens: 10),
                    CostHistoryStore.Model(name: "swe-2-high", usd: 0, tokens: 30),
                ]),
        ]
        let report = CostHistoryStore.makeDevinReport(
            window: window,
            confidence: .init(included: true, live: true, scannedAt: Date()))
        XCTAssertEqual(report.todayTokens, 40)
        XCTAssertEqual(report.last30Tokens, 140)
        XCTAssertEqual(report.last30USD, 0)
        XCTAssertEqual(report.topModel, "swe-2-max")
        XCTAssertEqual(report.daily.count, 2)
    }

    /// The Devin agent record feeds the `.devin` cost source so the All tab
    /// can authorize and attribute the scan.
    func testDevinAgentMapsToDevinCostSource() {
        XCTAssertEqual(InstalledAgentID.devin.costHistorySource, .devin)
        XCTAssertEqual(CostHistoryStore.Source(rawValue: "devin"), .devin)
    }

    /// cost-history.json round-trips a "devin" source entry — the schema gate
    /// (`knownSources`) must accept it so macOS/Linux share the file format.
    func testDevinCostHistorySourceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-devin-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")

        let cal = devinUTCCalendar
        let today = cal.startOfDay(for: Date())
        _ = CostHistoryStore.apply(
            source: .devin,
            liveDays: [(today, 0.0, 123,
                        [(name: "swe-2-max", usd: 0.0, tokens: 123)])],
            now: Date(),
            calendar: cal,
            windowDays: 120,
            url: url,
            liveScanSucceeded: true)

        let window = CostHistoryStore.window(
            source: .devin, now: Date(), calendar: cal, windowDays: 120, url: url)
        XCTAssertEqual(window.last?.tokens, 123)
        XCTAssertEqual(window.last?.models.first?.name, "swe-2-max")
    }

    // MARK: - Menu bar: 5-hour + weekly for CommandCode / OpenCode Go

    private func rateWindow(_ label: String, remaining: Int, seconds: Int) -> QuotaWindow {
        QuotaWindow(
            label: label, usedPct: 100 - remaining, remainingPct: remaining,
            windowSeconds: seconds)
    }

    /// Matching on LENGTH, not label: the same 18 000-second budget is called
    /// "5 giờ" by CommandCode and "Rolling" by OpenCode Go.
    func testRollingAndWeeklyPicksBothLabelSchemes() {
        let commandCode = [
            rateWindow("5 giờ", remaining: 100, seconds: 5 * 3600),
            rateWindow("Tuần", remaining: 21, seconds: 7 * 24 * 3600),
            rateWindow("Tháng", remaining: 60, seconds: 30 * 24 * 3600),
        ]
        XCTAssertEqual(
            MenuBarIconRenderer.rollingAndWeeklyWindows(commandCode).map(\.remainingPct),
            [100, 21])

        let openCodeGo = [
            rateWindow("Rolling", remaining: 100, seconds: 5 * 3600),
            rateWindow("Tuần", remaining: 80, seconds: 7 * 24 * 3600),
            rateWindow("Tháng", remaining: 84, seconds: 30 * 24 * 3600),
        ]
        XCTAssertEqual(
            MenuBarIconRenderer.rollingAndWeeklyWindows(openCodeGo).map(\.remainingPct),
            [100, 80])
    }

    /// Order is 5-hour → weekly regardless of the order the provider emits,
    /// and the monthly row must never stand in for the weekly one.
    func testRollingAndWeeklyIsOrderedAndSkipsMonthly() {
        let shuffled = [
            rateWindow("Tháng", remaining: 60, seconds: 30 * 24 * 3600),
            rateWindow("Tuần", remaining: 21, seconds: 7 * 24 * 3600),
            rateWindow("Rolling", remaining: 90, seconds: 5 * 3600),
        ]
        XCTAssertEqual(
            MenuBarIconRenderer.rollingAndWeeklyWindows(shuffled).map(\.label),
            ["Rolling", "Tuần"])

        let monthlyOnly = [rateWindow("Tháng", remaining: 60, seconds: 30 * 24 * 3600)]
        XCTAssertTrue(MenuBarIconRenderer.rollingAndWeeklyWindows(monthlyOnly).isEmpty)
    }

    /// The explicit picker entries must be offered too, not just the new default.
    func testCommandCodeAndOpenCodeGoExposeSecondaryMetrics() {
        let settings = SettingsStore()
        for id in ["commandcode", "opencodego"] {
            let caps = settings.providerCapabilities(for: id)
            XCTAssertTrue(caps.hasSecondary, id)
            XCTAssertTrue(caps.hasTertiary, id)
            XCTAssertTrue(settings.supportsMetric(.primaryAndSecondary, for: id), id)
        }
    }

    // MARK: - Antigravity OAuth loopback: one-shot continuation

    /// Counts how many callers believed they settled the continuation.
    private final class SettleCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// The crash: two connection callbacks both reached `resume`, and resuming
    /// a CheckedContinuation twice traps the runtime. Only the first caller may
    /// win, and it must be told so it alone tears the listener down.
    func testOneShotContinuationSettlesExactlyOnce() async throws {
        let winners = SettleCounter()
        let value: Int = try await withCheckedThrowingContinuation { cont in
            let once = OneShotContinuation(cont)
            XCTAssertFalse(once.isSettled)
            if once.resume(with: .success(1)) { winners.increment() }
            XCTAssertTrue(once.isSettled)
            // Every later attempt must be refused rather than trap.
            if once.resume(with: .success(2)) { winners.increment() }
            if once.resume(with: .failure(AntigravityOAuthError.codeMissing)) { winners.increment() }
        }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(winners.value, 1)
    }

    /// Concurrent callbacks are the real shape of the bug — `NWConnection`
    /// delivers them on a concurrent global queue, so the guard has to be
    /// atomic, not just correctly placed.
    func testOneShotContinuationIsSafeUnderConcurrentResumes() async throws {
        let winners = SettleCounter()
        let value: Int = try await withCheckedThrowingContinuation { cont in
            let once = OneShotContinuation(cont)
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                if once.resume(with: .success(index)) { winners.increment() }
            }
        }
        XCTAssertTrue((0..<64).contains(value))
        XCTAssertEqual(winners.value, 1, "exactly one caller may resume")
    }

    /// `/favicon.ico` arrives on its own connection right after the redirect
    /// page renders. Treating it as "no code" used to fail the whole login.
    func testLoopbackIgnoresRequestsWithoutCallbackParams() {
        let favicon = "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(
            AntigravityOAuthLogin.callbackOutcome(fromRequest: favicon), .unrelated)
        let bare = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(AntigravityOAuthLogin.callbackOutcome(fromRequest: bare), .unrelated)
    }

    func testLoopbackReadsCodeAndDenial() {
        let ok = "GET /?code=4%2F0AX&scope=email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(
            AntigravityOAuthLogin.callbackOutcome(fromRequest: ok), .code("4/0AX"))

        // A denial must fail fast instead of waiting out the 120s timeout.
        let denied = "GET /?error=access_denied HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(
            AntigravityOAuthLogin.callbackOutcome(fromRequest: denied), .denied("access_denied"))
    }

    // MARK: - Cookie reader: browser chọn theo phiên CÒN SỐNG

    private func pair(_ name: String, _ value: String, inDays: Double?) -> ProviderCookieReader.CookiePair {
        ProviderCookieReader.CookiePair(
            name: name, value: value,
            expires: inDays.map { Date().addingTimeInterval($0 * 86_400) })
    }

    /// Bug đã gặp: Chrome hết phiên lúc 20:17 nhưng vẫn còn `_ga`/`__stripe_mid`
    /// hạn dài, nên nó thắng Brave — nơi người dùng thực sự đang đăng nhập.
    func testStoreWithExpiredSessionLosesToSignedInBrowser() {
        let chrome = [
            pair("__Secure-commandcode_prod_.session_token", "dead", inDays: -0.1),
            pair("_ga", "GA1.1", inDays: 400),
            pair("__stripe_mid", "x", inDays: 365),
        ]
        let brave = [
            pair("__Secure-commandcode_prod_.session_token", "alive", inDays: 6),
            pair("_ga", "GA1.1", inDays: 400),
        ]
        let picked = ProviderCookieReader.firstUsableStore(
            [chrome, brave], matchesSession: CommandCodeProvider.isSessionCookieName)
        XCTAssertEqual(
            picked?.first(where: { $0.name.contains("session_token") })?.value, "alive")
    }

    /// Không có matcher thì cookie sống bất kỳ cũng tính — giữ hành vi cũ cho
    /// provider chưa khai báo cookie phiên.
    func testWithoutMatcherAnyLiveCookieQualifies() {
        let stores = [[pair("_ga", "x", inDays: -1)], [pair("_ga", "y", inDays: 30)]]
        XCTAssertEqual(
            ProviderCookieReader.firstUsableStore(stores, matchesSession: nil)?.first?.value, "y")
    }

    /// Cookie phiên không có `expires` (chết theo tiến trình trình duyệt) vẫn
    /// phải tính là còn sống — nếu không thì mọi phiên kiểu đó bị loại oan.
    func testSessionCookieWithoutExpiryCountsAsLive() {
        let store = [pair("better-auth.session_token", "v", inDays: nil)]
        XCTAssertNotNil(
            ProviderCookieReader.firstUsableStore(
                [store], matchesSession: CommandCodeProvider.isSessionCookieName))
    }

    func testNoBrowserHasLiveSessionYieldsNil() {
        let dead = [[pair("__Secure-commandcode_prod_.session_token", "d", inDays: -2)]]
        XCTAssertNil(
            ProviderCookieReader.firstUsableStore(
                dead, matchesSession: CommandCodeProvider.isSessionCookieName))
    }

    /// Brave đứng trước Chrome theo yêu cầu; Safari giữ vị trí sớm vì là store
    /// duy nhất không cần prompt Keychain.
    func testBraveLeadsBrowserSearchOrder() throws {
        let order = ProviderCookieReader.browserSearchOrderIDs
        // Safari → Brave → Chrome → phần còn lại.
        XCTAssertEqual(Array(order.prefix(3)), ["safari", "brave", "chrome"])
        let safari = try XCTUnwrap(order.firstIndex(of: "safari"))
        let brave = try XCTUnwrap(order.firstIndex(of: "brave"))
        let chrome = try XCTUnwrap(order.firstIndex(of: "chrome"))
        XCTAssertLessThan(safari, brave)
        XCTAssertLessThan(brave, chrome)
        // Không lặp, và không nuốt mất trình duyệt nào.
        XCTAssertEqual(Set(order).count, order.count)
        XCTAssertGreaterThanOrEqual(order.count, 8)
    }

    // MARK: - Cửa sổ quét: thường ngày hẹp + quét sâu định kỳ

    /// Người dùng hằng ngày: ngày mới nhất đã lưu CHÍNH LÀ hôm nay nên khoảng
    /// cách = 0. Trước đây sàn 7 khiến mỗi lần refresh đọc lại cả tuần file.
    func testRoutinePassStaysNarrowForDailyUser() {
        let now = Date()
        let plan = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 0,
            lastDeepScan: now.addingTimeInterval(-3_600),
            now: now)
        XCTAssertEqual(plan.days, CostHistoryStore.routineScanDays)
        XCTAssertEqual(plan.days, 3)
        XCTAssertFalse(plan.isDeep)
    }

    /// Quá hạn thì nới rộng để bắt lại phiên ghi trễ — thứ mà cửa sổ hẹp bỏ sót
    /// và store never-shrink không bao giờ tự sửa.
    func testDeepPassWidensWhenDue() {
        let now = Date()
        let due = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 0,
            lastDeepScan: now.addingTimeInterval(-CostHistoryStore.deepScanInterval - 60),
            now: now)
        XCTAssertEqual(due.days, CostHistoryStore.deepScanDays)
        XCTAssertTrue(due.isDeep)

        // Chưa từng quét sâu cũng tính là tới hạn.
        let never = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 0, lastDeepScan: nil, now: now)
        XCTAssertTrue(never.isDeep)

        // Clock rollback/corrupt future stamp must not suppress deep scans.
        let future = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 0,
            lastDeepScan: now.addingTimeInterval(3_600),
            now: now)
        XCTAssertTrue(future.isDeep)
    }

    /// Không có lịch sử = khởi động lạnh: phải quét đủ maxDays, không được rơi
    /// xuống cửa sổ hẹp rồi mất sạch ngày cũ.
    func testColdStartScansFullWindow() {
        let plan = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: nil, lastDeepScan: Date(), now: Date(), maxDays: 90)
        XCTAssertEqual(plan.days, 90)
        XCTAssertTrue(plan.isDeep)
    }

    /// Nghỉ dài ngày: khoảng trống thật phải thắng cả sàn lẫn cửa sổ sâu, và
    /// vẫn bị maxDays chặn trên.
    func testLongGapWinsAndIsCappedByMaxDays() {
        let now = Date()
        let recentDeep = now.addingTimeInterval(-60)
        let gap = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 40, lastDeepScan: recentDeep, now: now)
        XCTAssertEqual(gap.days, 41, "phải phủ đúng khoảng trống, không bị bóp về sàn")

        let huge = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 500, lastDeepScan: recentDeep, now: now, maxDays: 90)
        XCTAssertEqual(huge.days, 90)
    }

    /// Nguồn truyền sàn riêng vẫn được tôn trọng.
    func testCallerSuppliedMinDaysIsHonoured() {
        let now = Date()
        let plan = CostHistoryStore.scanBackPlan(
            daysSinceLatestStoredDay: 0,
            lastDeepScan: now.addingTimeInterval(-60),
            now: now,
            minDays: 10)
        XCTAssertEqual(plan.days, 10)
    }

    /// OMP/Pi trước đây thiếu seed nên tổng tab All NHẢY khi chúng quét xong.
    func testOMPAndPiSeedFromStoredHistory() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cost-history.json")
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        for source in [CostHistoryStore.Source.omp, .pi] {
            _ = CostHistoryStore.apply(
                source: source,
                liveDays: [
                    (yesterday, 4.0, 400, [("m", 4.0, 400)]),
                    (today, 1.0, 100, [("m", 1.0, 100)]),
                ],
                now: now, calendar: cal, windowDays: 90, url: url)
        }

        let omp = await OMPCostScanner.seededReport(now: now, calendar: cal, url: url)
        XCTAssertEqual(omp?.todayTokens, 100)
        XCTAssertEqual(omp?.last30Tokens, 500)

        let pi = await PiCostScanner.seededReport(now: now, calendar: cal, url: url)
        XCTAssertEqual(pi?.todayTokens, 100)

        // Kho rỗng → nil để UI giữ skeleton thay vì vẽ số 0.
        let missing = dir.appendingPathComponent("nope.json")
        let ompEmpty = await OMPCostScanner.seededReport(now: now, calendar: cal, url: missing)
        let piEmpty = await PiCostScanner.seededReport(now: now, calendar: cal, url: missing)
        XCTAssertNil(ompEmpty)
        XCTAssertNil(piEmpty)
    }

    // MARK: - Quét lần đầu: chặn file khổng lồ

    /// Lần quét đầu đọc MỌI file vì chưa có gì trong cache, nên một transcript
    /// quá khổ ở đó kéo sập cả lượt. Cap phải bằng nhau giữa các scanner để
    /// không có nguồn nào thành lỗ hổng.
    func testAllScannersShareTheSameOversizeCap() {
        let cap = 256 * 1024 * 1024
        XCTAssertEqual(ClaudeCostScanner.maxSessionFileBytes, cap)
        XCTAssertEqual(GrokCostScanner.maxSessionFileBytes, cap)
        XCTAssertEqual(OMPCostScanner.maxSessionFileBytes, cap)
        XCTAssertEqual(PiCostScanner.maxSessionFileBytes, cap)
    }

    /// File dưới ngưỡng vẫn đọc bình thường; quá ngưỡng trả nil thay vì nạp
    /// nguyên khối vào RAM.
    func testGrokBoundedDataRejectsOversizeFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let small = dir.appendingPathComponent("small.json")
        try Data("{}".utf8).write(to: small)
        XCTAssertEqual(GrokCostScanner.boundedData(at: small)?.count, 2)

        // File thưa: chiếm đúng 1 byte trên đĩa nhưng khai kích thước lớn.
        let huge = dir.appendingPathComponent("huge.jsonl")
        fm.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(GrokCostScanner.maxSessionFileBytes) + 1)
        try handle.close()
        XCTAssertNil(GrokCostScanner.boundedData(at: huge), "file quá khổ phải bị bỏ qua")

        XCTAssertNil(GrokCostScanner.boundedData(at: dir.appendingPathComponent("nope.json")))
    }

    // MARK: - Devin

    /// Snapshot daily/weekly → hai window "Ngày"/"Tuần" với reset + pace.
    func testDevinSnapshotMapsToProviderStatus() {
        let reset = Date(timeIntervalSinceNow: 3600)
        let snap = DevinUsageSnapshot(
            daily: DevinQuotaWindow(usedPercent: 42.4, resetsAt: reset),
            weekly: DevinQuotaWindow(usedPercent: 7.6),
            planName: "Core",
            organization: "org/acme",
            updatedAt: Date())
        let s = DevinProvider._mapForTesting(snap)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.id, "devin")
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertEqual(s.windows[0].label, "Ngày")
        XCTAssertEqual(s.windows[0].usedPct, 42)
        XCTAssertEqual(s.windows[0].remainingPct, 58)
        XCTAssertEqual(s.windows[0].resetDate, reset)
        XCTAssertEqual(s.windows[0].windowSeconds, 24 * 3600)
        XCTAssertEqual(s.windows[1].label, "Tuần")
        XCTAssertEqual(s.windows[1].windowSeconds, 7 * 24 * 3600)
        XCTAssertEqual(s.accountLabel, "org/acme")
        XCTAssertEqual(s.planName, "Core")
    }

    /// `overage_balance` trong quota payload → snapshot.overageBalance →
    /// ProviderStatus.creditsRemaining (hàng CREDITS · "$10 còn lại").
    func testDevinOverageBalanceMapsToCredits() throws {
        let json = """
        {"daily_percentage": 48, "weekly_percentage": 24,
         "overage_balance": 10.0, "is_quota_plan": true}
        """
        let snap = try DevinUsageParser.parse(Data(json.utf8), organization: "org/acme")
        XCTAssertEqual(snap.overageBalance, 10.0)
        let s = DevinProvider._mapForTesting(snap)
        XCTAssertEqual(s.creditsRemaining, 10.0)
    }

    /// Snapshot kèm usageHistory → ProviderStatus.devinUsage cho chart card;
    /// products total=0 bị lọc, còn lại sort giảm dần.
    func testDevinSnapshotMapsUsageHistory() {
        let day = DevinDailyUsage(date: Date(), amount: 2.5, cumulative: 2.5)
        let history = DevinUsageHistory(
            days: [day],
            products: [
                DevinProductUsage(view: "sessions", total: 2.5, days: [day]),
                DevinProductUsage(view: "reviews", total: 0, days: []),
            ],
            cycleStart: nil,
            cycleEnd: nil,
            total: 2.5)
        let snap = DevinUsageSnapshot(
            daily: DevinQuotaWindow(usedPercent: 10),
            weekly: nil, planName: nil, organization: nil,
            updatedAt: Date(), usageHistory: history)
        let s = DevinProvider._mapForTesting(snap)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.devinUsage?.days.count, 1)
        XCTAssertEqual(s.devinUsage?.days.first?.amount, 2.5)
        XCTAssertEqual(s.devinUsage?.total, 2.5)
        XCTAssertEqual(s.devinUsage?.products.map(\.view), ["sessions"])
    }

    /// Không có window nào → status lỗi thay vì popover trống.
    func testDevinSnapshotWithoutWindowsYieldsError() {
        let snap = DevinUsageSnapshot(
            daily: nil, weekly: nil, planName: nil, organization: nil,
            updatedAt: Date())
        let s = DevinProvider._mapForTesting(snap)
        XCTAssertNotNil(s.error)
        XCTAssertTrue(s.windows.isEmpty)
    }
}
