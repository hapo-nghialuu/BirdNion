import XCTest
@testable import BirdNion

final class InstalledAgentCatalogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-catalog-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testAbsentEvidenceProducesEmptyRoster() {
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertTrue(detected.isEmpty)
    }

    func testExactKnownMarkersProduceDeterministicCatalogOrder() {
        createDirectory(".claude")
        createDirectory(".codex")
        createDirectory(".omp/agent")

        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(detected.map(\.id), [.claude, .codex, .omp])
    }

    func testExecutableEvidenceIsBoundedAndRedacted() {
        let binDirectory = tempDirectory.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let customBinary = binDirectory.appendingPathComponent("pi")
        FileManager.default.createFile(atPath: customBinary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: ["PATH": binDirectory.path]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(detected.map(\.id), [.pi])
        XCTAssertEqual(detected.first?.evidence.first?.token, "PATH:pi")
    }

    func testUnknownPathsNeverCreateRecords() {
        createDirectory(".unknown-tool")
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertTrue(detected.isEmpty)
    }

    func testKiroConfigEvidenceDoesNotRequireBinary() {
        createDirectory(".kiro")
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )
        let detected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(detected.map(\.id), [.kiro])
        XCTAssertTrue(detected[0].capabilities.contains(.nativeConfig))
        XCTAssertFalse(detected[0].capabilities.contains(.localCost))
        XCTAssertFalse(detected[0].capabilities.contains(.quota))

        try? FileManager.default.removeItem(at: tempDirectory.appendingPathComponent(".kiro"))
        createDirectory(".kiro_sessions")
        let legacyDetected = InstalledAgentDetectors.detect(context: context)
        XCTAssertEqual(legacyDetected.map(\.id), [.kiro])
        XCTAssertTrue(legacyDetected[0].capabilities.contains(.nativeConfig))
        XCTAssertFalse(legacyDetected[0].capabilities.contains(.localCost))
    }

    func testKiroSQLiteMarkersRequireRegularFiles() {
        let markers = [
            "Library/Application Support/kiro-cli/data.sqlite3",
            ".local/share/kiro-cli/data.sqlite3",
        ]
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:]
        )

        for marker in markers { createDirectory(marker) }
        XCTAssertTrue(InstalledAgentDetectors.detect(context: context).isEmpty)

        for marker in markers {
            let url = tempDirectory.appendingPathComponent(marker)
            try? FileManager.default.removeItem(at: url)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        XCTAssertEqual(InstalledAgentDetectors.detect(context: context).map(\.id), [.kiro])
        XCTAssertEqual(
            KiroCostScanner.defaultCLIDatabaseURL(home: tempDirectory, environment: [:]).path,
            tempDirectory.appendingPathComponent(
                "Library/Application Support/kiro-cli/data.sqlite3").path)
    }

    func testKiroCustomXDGDatabaseUsesSameDetectorAndScannerPredicate() {
        let xdg = tempDirectory.appendingPathComponent("custom-xdg", isDirectory: true)
        let database = xdg.appendingPathComponent("kiro-cli/data.sqlite3")
        try? FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: database.path, contents: Data()))
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: ["XDG_DATA_HOME": xdg.path, "PATH": ""])

        XCTAssertEqual(InstalledAgentDetectors.detect(context: context).map(\.id), [.kiro])
        XCTAssertEqual(
            KiroCostScanner.defaultCLIDatabaseURL(
                home: tempDirectory,
                environment: context.environment).path,
            database.path)
    }

    func testQuotaCapabilityIsProjectedFromRealProviderWindow() {
        let record = InstalledAgentRecord(
            id: .gemini,
            evidence: [.init(kind: .configuration, token: "~/.gemini/settings.json")],
            capabilities: [.quota],
            providerIDs: ["gemini"])
        let noWindow = record.projected(providerStatuses: [])
        XCTAssertFalse(noWindow.capabilities.contains(.quota))

        let live = ProviderStatus(
            id: "gemini",
            displayName: "Gemini",
            windows: [.init(label: "5-hour", usedPct: 20, remainingPct: 80)],
            lastUpdated: Date())
        let withWindow = record.projected(providerStatuses: [live])
        XCTAssertTrue(withWindow.capabilities.contains(.quota))
    }

    func testCostCapabilityIsProjectedOnlyWhenHistorySourceIsAvailable() {
        let record = InstalledAgentRecord(
            id: .kiro,
            evidence: [.init(kind: .configuration, token: "~/.kiro")],
            capabilities: [],
            providerIDs: ["kiro"])

        XCTAssertFalse(record.projected(providerStatuses: []).capabilities.contains(.localCost))
        let withHistory = record.projected(
            providerStatuses: [],
            availableCostSources: [.kiro])
        XCTAssertTrue(withHistory.capabilities.contains(.localCost))
        XCTAssertTrue(withHistory.capabilities.contains(.activityDetail))
    }

    func testAgentDetailSnapshotUsesOnlySelectedAgentEvidence() {
        let now = Calendar.current.startOfDay(for: Date())
        let record = InstalledAgentRecord(
            id: .omp,
            evidence: [
                .init(kind: .configuration, token: "~/.omp/agent/config.yml"),
                .init(kind: .applicationState, token: "~/.omp/agent/sessions"),
            ],
            capabilities: [.nativeConfig, .localCost, .activityDetail],
            providerIDs: [])
        let combined = CombinedUsageReport(
            todayUSD: 12,
            todayTokens: 3_000,
            last30USD: 12,
            last30Tokens: 3_000,
            totalUSD: 12,
            totalTokens: 3_000,
            daily: [CombinedDailyUsage(
                date: now,
                claudeUSD: 10,
                claudeTokens: 1_000,
                codexUSD: 0,
                codexTokens: 0,
                ompUSD: 2,
                ompTokens: 2_000,
                models: [CombinedModelCost(
                    name: "provider/model",
                    usd: 2,
                    tokens: 2_000,
                    source: "omp")])],
            topModels: [],
            peakDayUSD: 12,
            peakDayDate: now,
            avgPerActiveDayUSD: 12,
            activeDays: 1,
            streakDays: 1)

        let snapshot = AgentDetailSnapshot.build(
            record: record,
            providerStatuses: [],
            combined: combined,
            sourceName: "provider/model",
            now: now)

        XCTAssertEqual(snapshot.costSummary?.todayUSD ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.costSummary?.periodUSD ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.models.map(\.name), ["provider/model"])
        XCTAssertEqual(snapshot.sourceName, "provider/model")
        XCTAssertEqual(snapshot.logPath, "~/.omp/agent/sessions")
        XCTAssertEqual(snapshot.configPath, "~/.omp/agent/config.yml")
    }

    func testAgentDetailSnapshotDoesNotRenderUnavailableCostAsZero() {
        let record = InstalledAgentRecord(
            id: .omp,
            evidence: [.init(kind: .applicationState, token: "~/.omp/agent/sessions")],
            capabilities: [.localCost, .activityDetail],
            providerIDs: [])
        let empty = CombinedUsageReport(
            todayUSD: 0,
            todayTokens: 0,
            last30USD: 0,
            last30Tokens: 0,
            totalUSD: 0,
            totalTokens: 0,
            daily: [],
            topModels: [],
            peakDayUSD: 0,
            peakDayDate: nil,
            avgPerActiveDayUSD: 0,
            activeDays: 0,
            streakDays: 0,
            ompConfidence: .unavailable)

        let snapshot = AgentDetailSnapshot.build(
            record: record,
            providerStatuses: [],
            combined: empty)

        XCTAssertNil(snapshot.costSummary)
        XCTAssertTrue(snapshot.hasLocalCost, "capability stays observable without fabricating numeric evidence")
    }

    func testKiroAgentDetailKeepsTotalsButHidesSyntheticOtherModel() {
        let now = Calendar.current.startOfDay(for: Date())
        let record = InstalledAgentRecord(
            id: .kiro,
            evidence: [.init(kind: .applicationState, token: "~/.kiro/sessions/cli")],
            capabilities: [.localCost, .activityDetail],
            providerIDs: ["kiro"])
        let combined = CombinedUsageReport(
            todayUSD: 5.5, todayTokens: 550,
            last30USD: 5.5, last30Tokens: 550,
            totalUSD: 5.5, totalTokens: 550,
            daily: [CombinedDailyUsage(
                date: now,
                claudeUSD: 0, claudeTokens: 0,
                codexUSD: 0, codexTokens: 0,
                kiroUSD: 5.5, kiroTokens: 550,
                models: [
                    CombinedModelCost(name: "real-model", usd: 1, tokens: 100, source: "kiro"),
                    CombinedModelCost(
                        name: KiroCostScanner.aggregateModelName,
                        usd: 4.5, tokens: 450, source: "kiro"),
                ])],
            topModels: [], peakDayUSD: 5.5, peakDayDate: now,
            avgPerActiveDayUSD: 5.5, activeDays: 1, streakDays: 1,
            kiroConfidence: .init(included: true, live: true, scannedAt: now))

        let snapshot = AgentDetailSnapshot.build(
            record: record, providerStatuses: [], combined: combined, now: now)

        XCTAssertEqual(snapshot.costSummary?.periodTokens, 550)
        XCTAssertEqual(snapshot.models.map(\.name), ["real-model"])
        XCTAssertEqual(snapshot.recentActivity.last?.models.map(\.name), ["real-model"])
    }

    @MainActor
    func testNewestCatalogRefreshWinsAfterDetectedAgentIsRemoved() async {
        createDirectory(".kiro")
        let context = InstalledAgentDetectionContext(
            homeURL: tempDirectory,
            environment: [:])
        let gate = InstalledAgentRefreshGate()
        let catalog = InstalledAgentCatalog(context: context) { context in
            let snapshot = InstalledAgentDetectors.detect(context: context)
            let call = await gate.registerCall()
            if call == 2 { await gate.pauseSecondCall() }
            return snapshot
        }

        await catalog.refresh().value
        XCTAssertEqual(catalog.records.map(\.id), [.kiro])

        let staleRefresh = catalog.refresh()
        await gate.waitForCallCount(2)
        try? FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent(".kiro"))

        let currentRefresh = catalog.refresh()
        await currentRefresh.value
        XCTAssertTrue(catalog.records.isEmpty)

        await gate.releaseSecondCall()
        await staleRefresh.value
        XCTAssertTrue(catalog.records.isEmpty)
        XCTAssertFalse(catalog.isRefreshing)
    }

    private func createDirectory(_ path: String) {
        let target = tempDirectory.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
}

private actor InstalledAgentRefreshGate {
    private var callCount = 0
    private var secondCallContinuation: CheckedContinuation<Void, Never>?

    func registerCall() -> Int {
        callCount += 1
        return callCount
    }

    func pauseSecondCall() async {
        await withCheckedContinuation { continuation in
            secondCallContinuation = continuation
        }
    }

    func waitForCallCount(_ expected: Int) async {
        while callCount < expected { await Task.yield() }
    }

    func releaseSecondCall() {
        secondCallContinuation?.resume()
        secondCallContinuation = nil
    }
}
