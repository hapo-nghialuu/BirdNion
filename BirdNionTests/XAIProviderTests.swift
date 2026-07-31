import XCTest
@testable import BirdNion

final class XAIProviderTests: XCTestCase {
    func testTokenAndTeamEnvironmentOverrideConfig() throws {
        let configURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        try BirdNionConfigStore.save(
            BirdNionConfigStore.Provider(
                id: "xai",
                apiKey: "config-key",
                enabled: true,
                region: "config-team"),
            url: configURL)

        XCTAssertEqual(
            XAIProvider.resolveToken(
                env: ["XAI_MANAGEMENT_API_KEY": " env-key "],
                configURL: configURL),
            "env-key")
        XCTAssertEqual(
            XAIProvider.resolveTeamID(
                env: ["XAI_TEAM_ID": " env-team "],
                configURL: configURL),
            "env-team")
    }

    func testTokenAndTeamFallbackToConfig() throws {
        let configURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        try BirdNionConfigStore.save(
            BirdNionConfigStore.Provider(
                id: "xai",
                apiKey: "config-key",
                enabled: true,
                region: "config-team"),
            url: configURL)

        XCTAssertEqual(XAIProvider.resolveToken(env: [:], configURL: configURL), "config-key")
        XCTAssertEqual(XAIProvider.resolveTeamID(env: [:], configURL: configURL), "config-team")
    }

    func testMapSurfacesBalanceSpendAndIdentity() {
        let now = Date(timeIntervalSince1970: 1_751_356_800)
        let status = XAIProvider._mapForTesting(
            balanceUSD: 12.34,
            dailyUSD: [1.25, 2.75],
            teamID: "team-123",
            now: now)

        XCTAssertEqual(status.id, "xai")
        XCTAssertEqual(status.displayName, "xAI")
        XCTAssertEqual(status.planName, "xAI Platform")
        XCTAssertEqual(status.sourceLabel, "api")
        XCTAssertEqual(status.accountLabel, "team-123")
        XCTAssertEqual(status.creditsRemaining ?? -1, 12.34, accuracy: 0.001)
        XCTAssertEqual(status.windows.count, 1)
        XCTAssertEqual(status.windows.first?.label, "Balance")
        XCTAssertNil(status.windows.first?.resetDate)
        XCTAssertNil(status.windows.first?.windowSeconds)
        XCTAssertEqual(status.cost?.used ?? -1, 4.0, accuracy: 0.001)
        XCTAssertEqual(status.cost?.limit, 0)
        XCTAssertEqual(status.cost?.currencyCode, "USD")
        XCTAssertEqual(status.cost?.period, "Last 30 days")
    }

    func testPartialUsageMarksCostPeriodPartial() {
        let status = XAIProvider._mapForTesting(
            balanceUSD: 0,
            dailyUSD: [3],
            limitReached: true,
            teamID: "team",
            accountLabel: "Billing team")

        XCTAssertEqual(status.accountLabel, "Billing team")
        XCTAssertEqual(status.cost?.period, "Last 30 days (partial)")
        XCTAssertEqual(status.cost?.used ?? -1, 3, accuracy: 0.001)
    }

    func testMissingKeyAndTeamReturnFriendlyErrors() async throws {
        let configURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let missingKey = try await XAIProvider(env: [:], configURL: configURL).fetch()
        XCTAssertTrue(missingKey.windows.isEmpty)
        XCTAssertTrue(missingKey.error?.contains("Management API key") == true)

        let missingTeam = try await XAIProvider(
            env: ["XAI_MANAGEMENT_API_KEY": "key"],
            configURL: configURL).fetch()
        XCTAssertTrue(missingTeam.windows.isEmpty)
        XCTAssertTrue(missingTeam.error?.contains("team ID") == true)
    }

    func testInvalidTeamReturnsFriendlyErrorBeforeNetwork() async throws {
        let configURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        try BirdNionConfigStore.save(
            BirdNionConfigStore.Provider(
                id: "xai",
                apiKey: "key",
                enabled: true,
                region: "../escape"),
            url: configURL)

        let status = try await XAIProvider(env: [:], configURL: configURL).fetch()
        XCTAssertTrue(status.error?.contains("team ID is invalid") == true)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
    }
}
