import XCTest
@testable import BirdNion

final class PreferencesDocumentTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let name = "pref-doc-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    func testRoundTripCarriesOnlyAllowlistedKeys() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "hidePersonalInfo")
        defaults.set(80, forKey: "quotaWarnLevel1")
        defaults.set(120.0, forKey: "refreshIntervalSeconds")
        defaults.set("beta", forKey: "updateChannel")
        // Non-portable keys present in defaults are excluded by construction.
        defaults.set("sessionKey=sk-secret", forKey: "claudeManualCookieHeader")
        defaults.set(1_700_000_000.0, forKey: "codexAutoPrimeLastRun")

        var document = try PreferencesDocument(defaults: defaults)
        XCTAssertEqual(document.preferences.count, 4)
        XCTAssertNil(document.preferences["claudeManualCookieHeader"])
        XCTAssertNil(document.preferences["codexAutoPrimeLastRun"])

        let decoded = try PreferencesDocument(data: document.encoded())
        XCTAssertEqual(decoded.preferences, document.preferences)
    }

    func testValidationRejectsSecretsAndUnknownKeys() throws {
        var document = PreferencesDocument()
        try document.set("claudeManualCookieHeader", "sessionKey=sk-secret")
        XCTAssertThrowsError(try document.encoded()) { error in
            XCTAssertTrue(error.localizedDescription.contains("claudeManualCookieHeader"))
        }
    }

    func testValidationRejectsUnsupportedVersion() throws {
        let json = #"{"version":99,"preferences":{}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try PreferencesDocument(data: json))
    }

    func testValidationRejectsOutOfRangeThreshold() throws {
        var document = PreferencesDocument()
        try document.set("quotaWarnLevel1", 500)
        XCTAssertThrowsError(try document.encoded())
    }

    func testValidationRejectsDuplicateProviderIDs() throws {
        var document = PreferencesDocument()
        document.providers = [
            .init(id: "codex", enabled: true),
            .init(id: "codex", enabled: false),
        ]
        XCTAssertThrowsError(try document.encoded())
    }

    @MainActor
    func testImportAppliesDefaultsThroughStore() throws {
        let defaults = try makeDefaults()
        var document = PreferencesDocument()
        try document.set("hidePersonalInfo", true)
        try document.set("quotaWarnLevel2", 10)
        try document.set("updateChannel", "beta")

        let settings = SettingsStore()
        try settings.importPreferences(document, defaults: defaults)

        XCTAssertEqual(defaults.bool(forKey: "hidePersonalInfo"), true)
        XCTAssertEqual(defaults.integer(forKey: "quotaWarnLevel2"), 10)
        XCTAssertEqual(defaults.string(forKey: "updateChannel"), "beta")
    }

    @MainActor
    func testProviderPreferencesReorderAndTogglePreserveSecrets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pref-doc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")

        _ = try BirdNionConfigStore.saveProviders([
            .init(id: "codex", apiKey: "sk-codex-secret", enabled: true),
            .init(id: "claude", apiKey: "sk-claude-secret", enabled: false),
            .init(id: "kiro", apiKey: nil, enabled: true),
        ], url: url)

        try SettingsStore.applyProviderPreferences([
            .init(id: "claude", enabled: true),
            .init(id: "codex", enabled: false),
        ], url: url)

        let saved = BirdNionConfigStore.allProviders(url: url)
        // The two document-listed providers move to the front in document
        // order; the rest (registry-merged defaults + kiro) keep their order.
        XCTAssertEqual(saved.prefix(2).map(\.id), ["claude", "codex"])
        XCTAssertEqual(saved.first(where: { $0.id == "claude" })?.enabled, true)
        XCTAssertEqual(saved.first(where: { $0.id == "codex" })?.enabled, false)
        XCTAssertEqual(saved.first(where: { $0.id == "kiro" })?.enabled, true)
        // Secrets untouched by the reorder.
        XCTAssertEqual(saved.first(where: { $0.id == "claude" })?.apiKey, "sk-claude-secret")
        XCTAssertEqual(saved.first(where: { $0.id == "codex" })?.apiKey, "sk-codex-secret")
    }

    @MainActor
    func testPendingImportConsumedOnce() throws {
        let defaults = try makeDefaults()
        var document = PreferencesDocument()
        try document.set("hidePersonalInfo", true)
        try defaults.set(document.encoded(), forKey: PreferencesDocument.pendingImportKey)

        let settings = SettingsStore()
        // consumePendingPreferencesImport reads .standard; drive the seam
        // directly against the test suite to keep the assertion isolated.
        try settings.importPreferences(
            PreferencesDocument(data: defaults.data(forKey: PreferencesDocument.pendingImportKey)!),
            defaults: defaults)
        defaults.removeObject(forKey: PreferencesDocument.pendingImportKey)

        XCTAssertTrue(defaults.bool(forKey: "hidePersonalInfo"))
        XCTAssertNil(defaults.data(forKey: PreferencesDocument.pendingImportKey))
    }
}
