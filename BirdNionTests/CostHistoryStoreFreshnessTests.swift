import XCTest
@testable import BirdNion

/// Freshness semantics of `CostHistoryStore.Document.updated_at`: the label
/// must track "when did live data last land in the store" — including
/// pending-episode merges that are not yet a completed scan generation —
/// while `scanned_at` keeps marking only fully completed scans.
final class CostHistoryStoreFreshnessTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birdnion-history-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("cost-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var yesterday: Date {
        calendar.date(byAdding: .day, value: -1, to: Date())!
    }

    func testCompletedScanStampsBothScannedAtAndUpdatedAt() throws {
        let before = Date().addingTimeInterval(-1)
        let receipt = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [(date: yesterday, usd: 1.0, tokens: 100, models: [])],
            now: Date(), calendar: calendar, url: url,
            liveScanSucceeded: true)
        XCTAssertTrue(receipt.persisted)

        let doc = CostHistoryStore.read(url: url)
        let scannedAt = try XCTUnwrap(doc.scannedAt?["codex"])
        let updatedAt = try XCTUnwrap(doc.updatedAt?["codex"])
        XCTAssertGreaterThanOrEqual(scannedAt, Int64(before.timeIntervalSince1970 * 1_000))
        XCTAssertGreaterThanOrEqual(updatedAt, Int64(before.timeIntervalSince1970 * 1_000))
    }

    func testPendingEpisodeMergeStampsUpdatedAtButNotScannedAt() throws {
        let receipt = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [(date: yesterday, usd: 1.0, tokens: 100, models: [])],
            now: Date(), calendar: calendar, url: url,
            liveScanSucceeded: false)
        XCTAssertTrue(receipt.persisted)

        let doc = CostHistoryStore.read(url: url)
        XCTAssertNil(doc.scannedAt?["codex"])
        XCTAssertNotNil(doc.updatedAt?["codex"])

        let confidence = CostHistoryStore.confidence(
            source: .codex, liveScanSucceeded: false, url: url)
        XCTAssertFalse(confidence.live)
        XCTAssertNil(confidence.scannedAt)
        XCTAssertNotNil(confidence.updatedAt)
    }

    func testHistoryOnlyPassDoesNotRestampUpdatedAt() throws {
        _ = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [(date: yesterday, usd: 1.0, tokens: 100, models: [])],
            now: Date(), calendar: calendar, url: url,
            liveScanSucceeded: false)
        let stamped = try XCTUnwrap(CostHistoryStore.read(url: url).updatedAt?["codex"])

        _ = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [],
            now: Date().addingTimeInterval(3_600), calendar: calendar, url: url,
            liveScanSucceeded: false)

        XCTAssertEqual(CostHistoryStore.read(url: url).updatedAt?["codex"], stamped)
    }

    func testDocumentWithoutUpdatedAtDecodesAndReportsNilFreshness() throws {
        let json = #"{"version":1,"sources":{"codex":{}},"scanned_at":{"codex":1700000000000}}"#
        try json.data(using: .utf8)!.write(to: url)

        let doc = CostHistoryStore.read(url: url)
        XCTAssertEqual(doc.scannedAt?["codex"], 1_700_000_000_000)
        XCTAssertNil(doc.updatedAt?["codex"])

        let confidence = CostHistoryStore.confidence(
            source: .codex, liveScanSucceeded: false, url: url)
        XCTAssertNotNil(confidence.scannedAt)
        XCTAssertNil(confidence.updatedAt)
    }

    func testLegacyCamelCaseUpdatedAtDecodes() throws {
        let json = #"{"version":1,"sources":{},"updatedAt":{"codex":1700000000123}}"#
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(CostHistoryStore.read(url: url).updatedAt?["codex"], 1_700_000_000_123 as Int64)
    }

    func testEncodeWritesCanonicalUpdatedAtKey() throws {
        _ = CostHistoryStore.applyWithReceipt(
            source: .codex,
            liveDays: [(date: yesterday, usd: 1.0, tokens: 100, models: [])],
            now: Date(), calendar: calendar, url: url,
            liveScanSucceeded: true)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"updated_at\""))
        XCTAssertFalse(raw.contains("\"updatedAt\""))
    }
}
