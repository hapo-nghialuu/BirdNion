import XCTest
@testable import BirdNion

final class WidgetSnapshotTests: XCTestCase {

    func testSaveWritesSnapshotAndLoadsBack() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("widget-snapshot.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let status = ProviderStatus(
            id: "devin",
            displayName: "Devin",
            windows: [
                QuotaWindow(
                    label: "Ngày",
                    usedPct: 58,
                    remainingPct: 42,
                    resetDate: Date(timeIntervalSince1970: 1_800_000_000),
                    windowSeconds: 86_400,
                    allowance: nil),
                QuotaWindow(
                    label: "Bonus",
                    usedPct: 100,
                    remainingPct: 0,
                    isSupplementary: true),
            ],
            lastUpdated: Date(timeIntervalSince1970: 1_799_999_000),
            error: nil,
            creditsRemaining: 12.4)

        WidgetSnapshotStore.save([status], to: url, reloadTimelines: false)

        let snapshot = WidgetSnapshotStore.load(from: url)
        XCTAssertEqual(snapshot?.version, 1)
        XCTAssertEqual(snapshot?.providers.count, 1)
        let provider = snapshot?.providers.first
        XCTAssertEqual(provider?.id, "devin")
        XCTAssertEqual(provider?.name, "Devin")
        XCTAssertEqual(provider?.creditsRemaining, 12.4)
        // Supplementary windows are excluded — a spent bonus isn't quota.
        XCTAssertEqual(provider?.windows.count, 1)
        XCTAssertEqual(provider?.windows.first?.label, "Ngày")
        XCTAssertEqual(provider?.windows.first?.usedPercent, 58)
        XCTAssertEqual(provider?.windows.first?.windowMinutes, 1_440)
        XCTAssertEqual(provider?.windows.first?.resetsAt, 1_800_000_000)
    }

    func testSnapshotURLLandsNextToSettings() {
        let url = WidgetSnapshotStore.snapshotURL(
            env: ["BIRDNION_CONFIG": "/tmp/bn/settings.json"],
            fileManager: NoAppGroupFileManager())
        XCTAssertEqual(url.path, "/tmp/bn/widget-snapshot.json")
    }

    /// Unsigned/dev builds: simulates the app-group container being absent so
    /// the XDG fallback path is exercised.
    private final class NoAppGroupFileManager: FileManager {
        override func containerURL(
            forSecurityApplicationGroupIdentifier groupIdentifier: String
        ) -> URL? { nil }
    }
}
