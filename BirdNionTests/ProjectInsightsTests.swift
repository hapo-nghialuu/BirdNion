import XCTest
@testable import BirdNion

final class ProjectInsightsTests: XCTestCase {
    func testInsightsSourcesBootstrapDetectedKiroWithoutProviderOrHistory() {
        let detected = InstalledAgentRecord(
            id: .kiro,
            evidence: [.init(kind: .configuration, token: "~/.kiro")],
            capabilities: [.nativeConfig],
            providerIDs: ["kiro"])
        let projected = detected.projected(
            providerStatuses: [],
            availableCostSources: [.kiro])

        XCTAssertEqual(
            InsightsPane.localProjectSources(
                enabledProviderIDs: [],
                agentRecords: [detected]),
            [.kiro])
        XCTAssertFalse(InsightsPane.localProjectSources(
            enabledProviderIDs: [],
            agentRecords: []).contains(.kiro))
        XCTAssertEqual(
            InsightsPane.localProjectSources(
                enabledProviderIDs: [],
                agentRecords: [projected]),
            [.kiro])
    }

    func testInsightsCurrentLoadClearsOldKiroReportWhenSourcesDisappear() throws {
        let generation = UUID()
        let oldKiro = makeReport(source: .kiro, projectKey: "old-kiro")
        XCTAssertTrue(InsightsPane.localProjectSources(
            enabledProviderIDs: [], agentRecords: []).isEmpty)

        var displayedReport: ProjectInsightsReport? = oldKiro
        var loading = true
        let completion = try XCTUnwrap(InsightsPane.loadCompletion(
            generation: generation,
            currentGeneration: generation,
            seeded: nil,
            live: nil))
        displayedReport = completion.report
        loading = completion.loading

        XCTAssertNil(displayedReport)
        XCTAssertFalse(loading)
    }

    func testInsightsCurrentLoadPrefersLiveThenSeeded() throws {
        let generation = UUID()
        let seeded = makeReport(source: .kiro, projectKey: "seeded-kiro")
        let live = makeReport(source: .codex, projectKey: "live-codex")

        XCTAssertEqual(try XCTUnwrap(InsightsPane.loadCompletion(
            generation: generation,
            currentGeneration: generation,
            seeded: seeded,
            live: live)).report, live)
        XCTAssertEqual(try XCTUnwrap(InsightsPane.loadCompletion(
            generation: generation,
            currentGeneration: generation,
            seeded: seeded,
            live: nil)).report, seeded)
    }

    func testInsightsStaleLoadCannotClearNewerReport() {
        let staleGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let currentGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newerReport = makeReport(source: .codex, projectKey: "newer-codex")
        var displayedReport: ProjectInsightsReport? = newerReport
        var loading = true

        if let stale = InsightsPane.loadCompletion(
            generation: staleGeneration,
            currentGeneration: currentGeneration,
            seeded: nil,
            live: nil) {
            displayedReport = stale.report
            loading = stale.loading
        }

        XCTAssertEqual(displayedReport, newerReport)
        XCTAssertTrue(loading)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day))!
    }

    func testInsightsNavigationRestoresOnlyKnownValues() {
        XCTAssertEqual(SettingsTab.restored("insights"), .insights)
        XCTAssertEqual(SettingsTab.restored("removed-tab"), .general)
        XCTAssertEqual(InsightsSegment.restored("projects"), .projects)
        XCTAssertEqual(InsightsSegment.restored("removed-segment"), .overview)
    }

    func testClaudeIdentityUsesStableSessionKeyAndSafeCWDLabel() {
        let first = ProjectIdentity.claude(
            cwd: "/Users/alice/Secret Client/birdnion", fallbackDirectory: "-Users-alice-other")
        let second = ProjectIdentity.claude(
            cwd: nil, fallbackDirectory: "-Users-alice-other")

        XCTAssertEqual(first.key, second.key)
        XCTAssertEqual(first.displayName, "birdnion")
        XCTAssertEqual(first.attribution, .derived)
        XCTAssertEqual(first.key.count, 64)
        XCTAssertFalse(first.key.contains("alice"))
    }

    func testClaudeFallbackIdentityIsStableAndDoesNotExposeEncodedDirectory() {
        let identity = ProjectIdentity.claude(
            cwd: "relative/project", fallbackDirectory: "-Users-alice-Secret-Client")
        let repeated = ProjectIdentity.claude(
            cwd: nil, fallbackDirectory: "-Users-alice-Secret-Client")

        XCTAssertEqual(identity, repeated)
        XCTAssertEqual(identity.attribution, .derived)
        XCTAssertFalse(identity.displayName.contains("alice"))
        XCTAssertFalse(identity.displayName.contains("Secret"))
    }

    func testCodexAndGrokIdentityContractsMatchCrossPlatformDomains() throws {
        let codex = try XCTUnwrap(ProjectIdentity.codex(
            cwd: "/Users/alice/work/../work/birdnion"))
        XCTAssertEqual(
            codex.key,
            "8eeeb78acd744c6a05b506bd5697a3faf455b36998e678fe1a284646b0b63284")
        XCTAssertEqual(codex.displayName, "birdnion")
        XCTAssertEqual(codex.attribution, .exact)
        XCTAssertNil(ProjectIdentity.codex(cwd: "relative/private"))

        let grok = try XCTUnwrap(ProjectIdentity.grok(
            encodedDirectory: "-Users-alice-work-birdnion",
            gitRootDir: "/Users/alice/work/birdnion"))
        XCTAssertEqual(
            grok.key,
            "14831731d7a097d36f08d9c315a0c126f9d3b71f2c9ba621c6797916bd91c248")
        XCTAssertEqual(grok.displayName, "birdnion")
        XCTAssertEqual(grok.attribution, .derived)
        let fallback = try XCTUnwrap(ProjectIdentity.grok(
            encodedDirectory: "-Users-alice-work-birdnion", gitRootDir: "relative/private"))
        XCTAssertEqual(fallback.key, grok.key)
        XCTAssertEqual(fallback.displayName, "Grok Project 14831731")
        XCTAssertFalse(fallback.displayName.contains("alice"))
    }

    func testClaudeScannerEmitsDeterministicProjectsFromSamePass() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let encoded = root.appendingPathComponent("-Users-alice-birdnion", isDirectory: true)
        let file = encoded.appendingPathComponent("session.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: encoded, withIntermediateDirectories: true)
        let line = #"{"cwd":"/Users/alice/work/birdnion","timestamp":"2026-08-20T10:00:00Z","message":{"id":"msg_1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        try Data((line + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date(20)], ofItemAtPath: file.path)

        let result = try XCTUnwrap(ClaudeCostScanner.scanFullWithProjects(
            roots: [root], now: date(20).addingTimeInterval(18 * 3_600), scanDays: 7))
        XCTAssertEqual(result.report.last30Tokens, 150)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects[0].displayName, "birdnion")
        XCTAssertEqual(result.projects[0].attribution, .derived)
        XCTAssertEqual(result.projects[0].daily.first?.tokens, 150)
    }

    func testConflictingDuplicateProjectIdentityFallsBackToUnknownResidual() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectA = root.appendingPathComponent("encoded-a", isDirectory: true)
        let projectB = root.appendingPathComponent("encoded-b", isDirectory: true)
        let projectC = root.appendingPathComponent("encoded-c", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectC, withIntermediateDirectories: true)
        let first = #"{"cwd":"/private/work/a","timestamp":"2026-08-20T10:00:00Z","message":{"id":"same-message","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let second = #"{"cwd":"/private/work/b","timestamp":"2026-08-20T10:00:00Z","message":{"id":"same-message","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let third = #"{"cwd":"/private/work/c","timestamp":"2026-08-20T10:00:00Z","message":{"id":"same-message","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}"#
        let fileA = projectA.appendingPathComponent("a.jsonl")
        let fileB = projectB.appendingPathComponent("b.jsonl")
        let fileC = projectC.appendingPathComponent("c.jsonl")
        try Data((first + "\n").utf8).write(to: fileA)
        try Data((second + "\n").utf8).write(to: fileB)
        try Data((third + "\n").utf8).write(to: fileC)
        try FileManager.default.setAttributes([.modificationDate: date(20)], ofItemAtPath: fileA.path)
        try FileManager.default.setAttributes([.modificationDate: date(20)], ofItemAtPath: fileB.path)
        try FileManager.default.setAttributes([.modificationDate: date(20)], ofItemAtPath: fileC.path)

        let result = try XCTUnwrap(ClaudeCostScanner.scanFullWithProjects(
            roots: [root], now: date(20).addingTimeInterval(18 * 3_600), scanDays: 7))

        XCTAssertEqual(result.report.last30Tokens, 150)
        XCTAssertTrue(result.projects.isEmpty)
    }

    func testStoreHighWaterPruneCorruptionAndPrivacy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("project-cost-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = ProjectUsageRecord(
            source: .claude, projectKey: "/Users/alice/Secret Client/birdnion",
            displayName: "/Users/alice/Secret Client/birdnion", attribution: .exact,
            daily: [
                ProjectDailyUsage(
                    date: date(20), usd: 3, tokens: 300,
                    models: [.init(
                        name: "/Users/alice/Secret/client-model", usd: 3, tokens: 300)]),
                ProjectDailyUsage(date: date(1), usd: 9, tokens: 900, models: []),
            ])
        _ = ProjectCostHistoryStore.apply(
            source: .claude, liveProjects: [live], now: date(20), calendar: calendar,
            url: url, replacingSource: true)
        let lower = ProjectUsageRecord(
            source: .claude, projectKey: live.projectKey, displayName: live.displayName,
            attribution: .exact,
            daily: [ProjectDailyUsage(date: date(20), usd: 1, tokens: 100, models: [])])
        let merged = ProjectCostHistoryStore.apply(
            source: .claude, liveProjects: [lower], now: date(20), calendar: calendar, url: url)

        let project = try XCTUnwrap(merged.sources?["claude"]?.values.first)
        XCTAssertEqual(project.days["2026-08-20"]?.tokens, 300)
        XCTAssertNotNil(project.days["2026-08-01"])
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("/Users/alice"))
        XCTAssertFalse(raw.contains("Secret Client"))
        XCTAssertFalse(raw.contains("/Users/alice/Secret"))
        XCTAssertEqual(project.days["2026-08-20"]?.models.first?.name, "client-model")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("not-json".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(ProjectCostHistoryStore.read(url: url).sources ?? [:], [:])
    }

    func testStorePrunesBeyondRetentionWindow() {
        let oldDate = calendar.date(byAdding: .day, value: -400, to: date(20))!
        let record = ProjectUsageRecord(
            source: .claude, projectKey: String(repeating: "a", count: 64),
            displayName: "birdnion", attribution: .exact,
            daily: [
                ProjectDailyUsage(date: oldDate, usd: 1, tokens: 1, models: []),
                ProjectDailyUsage(date: date(20), usd: 2, tokens: 2, models: []),
            ])
        let merged = ProjectCostHistoryStore.merge(
            document: .init(version: 1, sources: [:]), source: .claude,
            liveProjects: [record], now: date(20), calendar: calendar)
        let days = merged.sources?["claude"]?[record.projectKey]?.days
        XCTAssertEqual(days?.count, 1)
        XCTAssertNotNil(days?["2026-08-20"])
    }

    func testStoreDropsPrivacyUnsafeSourceKeysBeforeWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("project-cost-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = String(repeating: "d", count: 64)
        let unsafe = ProjectCostHistoryStore.Document(version: 1, sources: [
            "/Users/private/Secret": [key: .init(
                displayName: "secret", attribution: .derived,
                days: ["2026-08-20": .init(usd: 1, tokens: 1, models: [])])],
        ])

        try ProjectCostHistoryStore.write(unsafe, url: url)
        let raw = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(raw.contains("/Users/private"))
        XCTAssertTrue(ProjectCostHistoryStore.read(url: url).sources?.isEmpty == true)
    }

    func testStoreDropsNonCanonicalDayKeysBeforeReadAndRewrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("project-cost-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = String(repeating: "e", count: 64)
        let raw = """
        {
          "version": 1,
          "sources": {
            "claude": {
              "\(key)": {
                "displayName": "birdnion",
                "attribution": "derived",
                "days": {
                  "2026-08-20": {"usd": 1, "tokens": 10, "models": []},
                  "2026-02-30": {"usd": 2, "tokens": 20, "models": []},
                  "2026-08-19-/Users/alice/private": {"usd": 3, "tokens": 30, "models": []}
                }
              }
            }
          }
        }
        """
        try Data(raw.utf8).write(to: url)

        let document = ProjectCostHistoryStore.read(url: url)
        let days = try XCTUnwrap(document.sources?["claude"]?[key]?.days)
        XCTAssertEqual(Array(days.keys), ["2026-08-20"])

        _ = ProjectCostHistoryStore.apply(
            source: .claude, liveProjects: [], now: date(20), calendar: calendar, url: url)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("2026-02-30"))
        XCTAssertFalse(rewritten.contains("/Users/alice"))
    }

    func testStoreSanitizesNegativeUsageAndBoundsModels() throws {
        let key = String(repeating: "f", count: 64)
        let models = (0..<7).map { index in
            ProjectCostHistoryStore.Model(
                name: "model-\(index)", usd: Double(index), tokens: index)
        } + [.init(name: "negative", usd: -1, tokens: -100)]
        let document = ProjectCostHistoryStore.Document(version: 1, sources: [
            "codex": [key: .init(
                displayName: "birdnion", attribution: .exact,
                days: ["2026-08-20": .init(usd: 1, tokens: -100, models: models)])],
        ])

        let sanitized = ProjectCostHistoryStore.merge(
            document: document, source: .codex, liveProjects: [],
            now: date(20), calendar: calendar)
        let day = try XCTUnwrap(sanitized.sources?["codex"]?[key]?.days["2026-08-20"])

        XCTAssertEqual(day.tokens, 0)
        XCTAssertEqual(day.models.count, 5)
        XCTAssertFalse(day.models.contains { $0.usd < 0 || $0.tokens < 0 })
    }

    func testEmptyLaterScanDoesNotShrinkObservedProjectHistory() {
        let observed = ProjectUsageRecord(
            source: .claude, projectKey: String(repeating: "a", count: 64),
            displayName: "Claude Project aaaaaaaa", attribution: .derived,
            daily: [ProjectDailyUsage(
                date: date(20), usd: 1, tokens: 100, models: [])])
        let first = ProjectCostHistoryStore.merge(
            document: .init(version: 1, sources: [:]), source: .claude,
            liveProjects: [observed], now: date(20), calendar: calendar)
        let second = ProjectCostHistoryStore.merge(
            document: first, source: .claude, liveProjects: [],
            now: date(20), calendar: calendar)

        XCTAssertEqual(
            second.sources?["claude"]?[observed.projectKey]?.days["2026-08-20"]?.tokens,
            100)
    }

    func testBuilderReusesWeeklyPulseAndKeepsCodexGrokUnknown() {
        let now = date(20)
        let daily = (7...20).map { day -> CombinedDailyUsage in
            CombinedDailyUsage(
                date: date(day), claudeUSD: 1, claudeTokens: 100,
                codexUSD: day >= 14 ? 3 : 1, codexTokens: day >= 14 ? 300 : 100,
                grokUSD: 0.5, grokTokens: 50,
                models: [CombinedModelCost(name: "gpt-5", usd: 3, tokens: 300, source: "codex")])
        }
        let combined = makeCombined(daily: daily)
        let key = String(repeating: "b", count: 64)
        let history = ProjectCostHistoryStore.Document(version: 1, sources: [
            "claude": [key: .init(
                displayName: "birdnion", attribution: .exact,
                days: Dictionary(uniqueKeysWithValues: (14...20).map {
                    (String(format: "2026-08-%02d", $0), .init(usd: 1, tokens: 100, models: []))
                }))]
        ])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history,
            enabledSources: Set(ProjectUsageSource.allCases), now: now, calendar: calendar)
        let pulse = WeeklyDigest.pulse(daily: daily, now: now, calendar: calendar)
        XCTAssertEqual(report.overview.currentUSD, pulse.currentUSD, accuracy: 0.0001)
        XCTAssertEqual(report.overview.priorUSD, pulse.priorUSD, accuracy: 0.0001)
        XCTAssertEqual(report.overview.changePercent, pulse.changePercent)

        let ranking = report.ranking(days: 7, now: now, calendar: calendar)
        XCTAssertEqual(ranking.first?.source, .codex)
        XCTAssertEqual(ranking.first?.displayName, "Unknown")
        XCTAssertEqual(ranking.first?.attribution, .unknown)
        XCTAssertTrue(ranking.contains { $0.source == .grok && $0.attribution == .unknown })
        XCTAssertTrue(ranking.contains { $0.source == .claude && $0.displayName == "birdnion" })
        let copied = ProjectInsightsBuilder.copySummary(report, language: "en")
        XCTAssertFalse(copied.contains("/Users/"))
    }

    func testBuilderIncludesKiroInOverviewUnknownProjectAndConfidence() throws {
        let daily = [CombinedDailyUsage(
            date: date(20), claudeUSD: 0, claudeTokens: 0,
            codexUSD: 0, codexTokens: 0,
            kiroUSD: 7, kiroTokens: 700,
            models: [
                .init(name: "real-model", usd: 1, tokens: 100, source: "kiro"),
                .init(name: KiroCostScanner.aggregateModelName,
                      usd: 6, tokens: 600, source: "kiro"),
            ])]
        let combined = makeCombined(daily: daily, enabledSources: [.kiro])

        let report = ProjectInsightsBuilder.build(
            combined: combined,
            history: .init(version: 1, sources: [:]),
            enabledSources: [.kiro],
            now: date(20),
            calendar: calendar)

        XCTAssertEqual(report.overview.topSource, .kiro)
        XCTAssertEqual(report.overview.topModel?.name, "real-model")
        XCTAssertEqual(report.overview.topModel?.source, "kiro")
        let unknown = try XCTUnwrap(report.projects.first { $0.source == .kiro })
        XCTAssertEqual(unknown.projectKey, "unknown-kiro")
        XCTAssertEqual(unknown.daily.first?.usd ?? 0, 7, accuracy: 0.0001)
        XCTAssertEqual(unknown.daily.first?.tokens, 700)
        XCTAssertEqual(unknown.daily.first?.models.map(\.name), ["real-model"])
        XCTAssertEqual(report.overview.confidence.live, [.kiro])
        XCTAssertTrue(report.overview.confidence.historyOnly.isEmpty)
        XCTAssertTrue(report.overview.confidence.unavailable.isEmpty)
        XCTAssertEqual(ProjectUsageSource.kiro.displayName, "Kiro")
    }

    func testBuilderSubtractsKnownCodexAndGrokPerDayWithoutDoubleCounting() throws {
        let codexKey = String(repeating: "c", count: 64)
        let grokKey = String(repeating: "d", count: 64)
        let history = ProjectCostHistoryStore.Document(version: 1, sources: [
            "codex": [codexKey: .init(
                displayName: "codex-project", attribution: .exact,
                days: ["2026-08-20": .init(usd: 6, tokens: 600, models: [])])],
            "grok": [grokKey: .init(
                displayName: "grok-project", attribution: .derived,
                days: ["2026-08-20": .init(usd: 8, tokens: 800, models: [])])],
        ])
        let combined = makeCombined(daily: [CombinedDailyUsage(
            date: date(20), claudeUSD: 0, claudeTokens: 0,
            codexUSD: 10, codexTokens: 1_000,
            grokUSD: 8, grokTokens: 800)])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history, enabledSources: [.codex, .grok],
            now: date(20), calendar: calendar)
        let codexRows = report.projects.filter { $0.source == .codex }
        let grokRows = report.projects.filter { $0.source == .grok }
        XCTAssertEqual(codexRows.flatMap(\.daily).reduce(0) { $0 + $1.tokens }, 1_000)
        XCTAssertEqual(
            codexRows.flatMap(\.daily).reduce(0) { $0 + $1.usd }, 10, accuracy: 0.0001)
        let codexUnknown = try XCTUnwrap(codexRows.first { $0.attribution == .unknown })
        XCTAssertEqual(codexUnknown.daily.first?.tokens, 400)
        XCTAssertEqual(codexUnknown.daily.first?.usd ?? 0, 4, accuracy: 0.0001)
        XCTAssertEqual(grokRows.flatMap(\.daily).reduce(0) { $0 + $1.tokens }, 800)
        XCTAssertFalse(grokRows.contains { $0.attribution == .unknown })
    }

    func testBuilderReconcilesIndependentProjectHighWaterToAggregate() {
        let firstKey = String(repeating: "a", count: 64)
        let secondKey = String(repeating: "b", count: 64)
        let history = ProjectCostHistoryStore.Document(version: 1, sources: [
            "codex": [
                firstKey: .init(
                    displayName: "first", attribution: .exact,
                    days: ["2026-08-20": .init(usd: 10, tokens: 1, models: [])]),
                secondKey: .init(
                    displayName: "second", attribution: .exact,
                    days: ["2026-08-20": .init(usd: 10, tokens: 1, models: [])]),
            ],
        ])
        let combined = makeCombined(
            daily: [.init(
                date: date(20), claudeUSD: 0, claudeTokens: 0,
                codexUSD: 10, codexTokens: 1, grokUSD: 0, grokTokens: 0)],
            enabledSources: [.codex])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history, enabledSources: [.codex],
            now: date(20), calendar: calendar)
        let rows = report.projects.filter { $0.source == .codex }

        XCTAssertEqual(rows.flatMap(\.daily).reduce(0) { $0 + $1.tokens }, 1)
        XCTAssertEqual(rows.flatMap(\.daily).reduce(0) { $0 + $1.usd }, 10, accuracy: 0.0001)
        XCTAssertEqual(rows.filter { !$0.projectKey.hasPrefix("unknown-") }.count, 2)
        XCTAssertFalse(rows.contains { $0.attribution == .unknown })
    }

    func testBuilderLargestRemainderMatchesExactCrossPlatformVector() {
        let keys = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        let tokens = [169_874_575_206, 930_536_964_766, 556_645_033_356]
        let projects = Dictionary(uniqueKeysWithValues: zip(keys, tokens).map { key, tokens in
            (key, ProjectCostHistoryStore.Project(
                displayName: key, attribution: .exact,
                days: ["2026-08-20": .init(usd: 1, tokens: tokens, models: [])]))
        })
        let history = ProjectCostHistoryStore.Document(
            version: 1, sources: ["codex": projects])
        let combined = makeCombined(
            daily: [.init(
                date: date(20), claudeUSD: 0, claudeTokens: 0,
                codexUSD: 3, codexTokens: 679_330_185_810,
                grokUSD: 0, grokTokens: 0)],
            enabledSources: [.codex])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history, enabledSources: [.codex],
            now: date(20), calendar: calendar)
        let allocated = Dictionary(uniqueKeysWithValues: report.projects
            .filter { $0.source == .codex && $0.attribution != .unknown }
            .map { ($0.projectKey, $0.daily.first?.tokens ?? 0) })

        XCTAssertEqual(
            keys.map { allocated[$0] },
            [69_642_116_387, 381_484_772_066, 228_203_297_357])
    }

    func testBuilderModelScalingMatchesExactCrossPlatformVector() {
        let key = String(repeating: "a", count: 64)
        let history = ProjectCostHistoryStore.Document(version: 1, sources: [
            "codex": [
                key: .init(
                    displayName: "birdnion", attribution: .exact,
                    days: ["2026-08-20": .init(
                        usd: 1,
                        tokens: 819_658_394_797,
                        models: [.init(
                            name: "gpt-5",
                            usd: 1,
                            tokens: 677_997_133_818)])]),
            ],
        ])
        let combined = makeCombined(
            daily: [.init(
                date: date(20), claudeUSD: 0, claudeTokens: 0,
                codexUSD: 1, codexTokens: 720_527_863_824,
                grokUSD: 0, grokTokens: 0)],
            enabledSources: [.codex])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history, enabledSources: [.codex],
            now: date(20), calendar: calendar)
        let model = report.projects.first { $0.projectKey == key }?
            .daily.first?.models.first

        XCTAssertEqual(model?.tokens, 595_999_296_303)
    }

    func testExplicitRetractionMovesOnlyAmbiguousContributionToUnknownOnce() throws {
        let key = String(repeating: "c", count: 64)
        let retractionID = String(repeating: "d", count: 64)
        let project = ProjectUsageRecord(
            source: .codex, projectKey: key, displayName: "birdnion", attribution: .exact,
            daily: [.init(
                date: date(20), usd: 20, tokens: 200,
                models: [.init(name: "gpt-5", usd: 20, tokens: 200)])])
        let initial = ProjectCostHistoryStore.merge(
            document: .init(version: 1, sources: [:]),
            source: .codex,
            liveProjects: [project],
            now: date(20),
            calendar: calendar)
        let retraction = ProjectCostHistoryStore.Retraction(
            id: retractionID,
            projectKey: key,
            daily: [.init(
                date: date(20), usd: 10, tokens: 100,
                models: [.init(name: "gpt-5", usd: 10, tokens: 100)])])
        let corrected = ProjectCostHistoryStore.merge(
            document: initial,
            source: .codex,
            liveProjects: [],
            now: date(20),
            calendar: calendar,
            retractions: [retraction])
        let repeated = ProjectCostHistoryStore.merge(
            document: corrected,
            source: .codex,
            liveProjects: [],
            now: date(20),
            calendar: calendar,
            retractions: [retraction])

        let onlyAmbiguous = ProjectUsageRecord(
            source: .codex, projectKey: key, displayName: "birdnion", attribution: .exact,
            daily: [.init(
                date: date(20), usd: 10, tokens: 100,
                models: [.init(name: "gpt-5", usd: 10, tokens: 100)])])
        let onlyAmbiguousHistory = ProjectCostHistoryStore.merge(
            document: .init(version: 1, sources: [:]), source: .codex,
            liveProjects: [onlyAmbiguous], now: date(20), calendar: calendar)
        let fullyRetracted = ProjectCostHistoryStore.merge(
            document: onlyAmbiguousHistory, source: .codex,
            liveProjects: [], now: date(20), calendar: calendar,
            retractions: [retraction])

        XCTAssertEqual(
            repeated.sources?["codex"]?[key]?.days["2026-08-20"]?.tokens,
            100)
        XCTAssertEqual(repeated.appliedRetractionIDs?["codex"], [retractionID])
        XCTAssertNil(fullyRetracted.sources?["codex"]?[key])

        let combined = makeCombined(
            daily: [.init(
                date: date(20), claudeUSD: 0, claudeTokens: 0,
                codexUSD: 20, codexTokens: 200, grokUSD: 0, grokTokens: 0)],
            enabledSources: [.codex])
        let report = ProjectInsightsBuilder.build(
            combined: combined,
            history: repeated,
            enabledSources: [.codex],
            now: date(20),
            calendar: calendar)
        let named = try XCTUnwrap(report.projects.first { $0.projectKey == key })
        let unknown = try XCTUnwrap(report.projects.first { $0.attribution == .unknown })
        XCTAssertEqual(named.daily.first?.tokens, 100)
        XCTAssertEqual(unknown.daily.first?.tokens, 100)
    }

    func testRankingTieBreakIsDeterministicByPrivacyKey() {
        let rows = ["b", "a"].map { suffix in
            ProjectUsageRecord(
                source: .claude, projectKey: String(repeating: suffix, count: 64),
                displayName: "Project \(suffix)", attribution: .exact,
                daily: [ProjectDailyUsage(date: date(20), usd: 1, tokens: 100, models: [])])
        }
        let emptyOverview = ProjectInsightsOverview(
            currentUSD: 0, currentTokens: 0, priorUSD: 0, priorTokens: 0,
            changePercent: nil, topSource: nil, topModel: nil,
            confidence: .init(live: [], historyOnly: [], unavailable: []))
        let report = ProjectInsightsReport(overview: emptyOverview, projects: rows)

        XCTAssertEqual(
            report.ranking(days: 7, now: date(20), calendar: calendar).map(\.projectKey),
            [String(repeating: "a", count: 64), String(repeating: "b", count: 64)])
    }

    func testDisabledSourceHistoryIsExcludedFromProjects() {
        let claudeKey = String(repeating: "c", count: 64)
        let history = ProjectCostHistoryStore.Document(version: 1, sources: [
            "claude": [claudeKey: .init(
                displayName: "disabled-claude", attribution: .exact,
                days: ["2026-08-20": .init(usd: 99, tokens: 999, models: [])])],
        ])
        let combined = makeCombined(
            daily: [CombinedDailyUsage(
                date: date(20), claudeUSD: 0, claudeTokens: 0,
                codexUSD: 1, codexTokens: 10, grokUSD: 0, grokTokens: 0)],
            enabledSources: [.codex])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: history, enabledSources: [.codex],
            now: date(20), calendar: calendar)

        XCTAssertFalse(report.projects.contains { $0.source == .claude })
        XCTAssertEqual(report.ranking(days: 7, now: date(20), calendar: calendar).first?.source, .codex)
    }

    func testHighlightReloadsForConfidenceAndHistoryChanges() {
        let historyOnly = CostHistoryStore.UsageScanConfidence(
            included: true, live: false, scannedAt: date(19))
        let live = CostHistoryStore.UsageScanConfidence(
            included: true, live: true, scannedAt: date(20))
        let daily = [CombinedDailyUsage(
            date: date(20), claudeUSD: 1, claudeTokens: 100,
            codexUSD: 0, codexTokens: 0, grokUSD: 0, grokTokens: 0, models: [])]
        let seeded = makeCombined(daily: daily, confidence: historyOnly)
        let refreshed = makeCombined(daily: daily, confidence: live)

        XCTAssertNotEqual(
            InsightsHighlightCard.reloadKey(
                combined: seeded, enabledSources: [.claude], historyStamp: "1:10"),
            InsightsHighlightCard.reloadKey(
                combined: refreshed, enabledSources: [.claude], historyStamp: "1:10"))
        XCTAssertNotEqual(
            InsightsHighlightCard.reloadKey(
                combined: refreshed, enabledSources: [.claude], historyStamp: "1:10"),
            InsightsHighlightCard.reloadKey(
                combined: refreshed, enabledSources: [.claude], historyStamp: "2:20"))
        XCTAssertNotEqual(
            InsightsHighlightCard.reloadKey(
                combined: refreshed, enabledSources: [.claude], historyStamp: "1:10"),
            InsightsHighlightCard.reloadKey(
                combined: refreshed, enabledSources: [.claude, .codex], historyStamp: "1:10"))
    }

    func testHighlightConfidenceDenominatorIncludesUnavailableEnabledSources() {
        let confidence = ProjectInsightsConfidence(
            live: [.claude], historyOnly: [], unavailable: [.codex, .grok])
        XCTAssertEqual(InsightsHighlightCard.confidenceLabel(confidence), "LIVE 1/3")
    }

    func testBuilderKeepsEnabledSourceWithoutReportAsUnavailable() {
        let combined = makeCombined(
            daily: [CombinedDailyUsage(
                date: date(20), claudeUSD: 1, claudeTokens: 100,
                codexUSD: 0, codexTokens: 0, grokUSD: 0, grokTokens: 0)],
            enabledSources: [.claude])

        let report = ProjectInsightsBuilder.build(
            combined: combined, history: .init(version: 1, sources: [:]),
            enabledSources: [.claude, .codex], now: date(20), calendar: calendar)

        XCTAssertEqual(report.overview.confidence.live, [.claude])
        XCTAssertEqual(report.overview.confidence.historyOnly, [])
        XCTAssertEqual(report.overview.confidence.unavailable, [.codex])
    }

    func testProjectRankingPayloadIsBounded() {
        let projects = (0...ProjectInsightsReport.rankingLimit).map { index in
            ProjectUsageRecord(
                source: .claude, projectKey: String(format: "%064x", index),
                displayName: "project-\(index)", attribution: .exact,
                daily: [ProjectDailyUsage(
                    date: date(20), usd: 1, tokens: 1, models: [])])
        }
        let report = ProjectInsightsReport(
            overview: .init(
                currentUSD: 0, currentTokens: 0, priorUSD: 0, priorTokens: 0,
                changePercent: nil, topSource: nil, topModel: nil,
                confidence: .init(live: [], historyOnly: [], unavailable: [])),
            projects: projects)

        XCTAssertEqual(
            report.ranking(days: 7, now: date(20), calendar: calendar).count,
            ProjectInsightsReport.rankingLimit)
    }

    func testProjectModelDetailSortIsCostThenTokensThenName() {
        let rows = InsightsProjectsContent.foldedModels([
            ProjectDailyUsage(
                date: date(20), usd: 4, tokens: 2_500,
                models: [
                    .init(name: "model-b", usd: 1, tokens: 1_000),
                    .init(name: "model-c", usd: 2, tokens: 500),
                    .init(name: "model-a", usd: 1, tokens: 1_000),
                ]),
        ])

        XCTAssertEqual(rows.map(\.name), ["model-c", "model-a", "model-b"])
    }

    private func makeReport(
        source: ProjectUsageSource,
        projectKey: String
    ) -> ProjectInsightsReport {
        ProjectInsightsReport(
            overview: .init(
                currentUSD: 1, currentTokens: 1,
                priorUSD: 0, priorTokens: 0,
                changePercent: nil, topSource: nil, topModel: nil,
                confidence: .init(live: [source], historyOnly: [], unavailable: [])),
            projects: [.init(
                source: source, projectKey: projectKey,
                displayName: projectKey, attribution: .unknown,
                daily: [])])
    }

    private func makeCombined(
        daily: [CombinedDailyUsage],
        confidence: CostHistoryStore.UsageScanConfidence? = nil,
        enabledSources: Set<ProjectUsageSource> = Set(ProjectUsageSource.allCases)
    ) -> CombinedUsageReport {
        let live = confidence ?? CostHistoryStore.UsageScanConfidence(
            included: true, live: true, scannedAt: date(20))
        return CombinedUsageReport(
            todayUSD: daily.last?.usd ?? 0, todayTokens: daily.last?.tokens ?? 0,
            last30USD: daily.reduce(0) { $0 + $1.usd },
            last30Tokens: daily.reduce(0) { $0 + $1.tokens },
            totalUSD: daily.reduce(0) { $0 + $1.usd },
            totalTokens: daily.reduce(0) { $0 + $1.tokens }, daily: daily,
            topModels: [], peakDayUSD: daily.map(\.usd).max() ?? 0, peakDayDate: nil,
            avgPerActiveDayUSD: 0, activeDays: daily.count, streakDays: daily.count,
            claudeConfidence: enabledSources.contains(.claude) ? live : nil,
            codexConfidence: enabledSources.contains(.codex) ? live : nil,
            grokConfidence: enabledSources.contains(.grok) ? live : nil,
            kiroConfidence: enabledSources.contains(.kiro) ? live : nil)
    }
}
