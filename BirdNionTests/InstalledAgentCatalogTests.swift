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

    private func createDirectory(_ path: String) {
        let target = tempDirectory.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
}
