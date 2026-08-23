import XCTest
@testable import BirdNion

@MainActor
final class AgentVisibilityStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "birdnion.tests.agentVisibility.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreVisibleAndUnpinned() {
        let store = InstalledAgentVisibilityStore(defaults: defaults)
        XCTAssertTrue(store.isVisible(.codex))
        XCTAssertFalse(store.isPinned(.codex))
    }

    func testHiddenAndPinnedPreferencesPersistIndependently() {
        let store = InstalledAgentVisibilityStore(defaults: defaults)
        store.setVisible(false, for: .codex)
        store.setPinned(true, for: .codex)
        let restored = InstalledAgentVisibilityStore(defaults: defaults)
        XCTAssertFalse(restored.isVisible(.codex))
        XCTAssertTrue(restored.isPinned(.codex))
        XCTAssertNil(defaults.object(forKey: "preferredAgent"))
        XCTAssertEqual(defaults.stringArray(forKey: "birdnion.agentVisibility.v1.hiddenIDs"), ["codex"])
    }

    func testVisibleProjectionOmitsHiddenAndOrdersPinnedFirst() {
        let store = InstalledAgentVisibilityStore(defaults: defaults)
        let original = [record(.claude), record(.codex), record(.grok)]
        store.setVisible(false, for: .codex)
        store.setPinned(true, for: .grok)
        XCTAssertEqual(store.visibleRecords(from: original).map(\.id), [.grok, .claude])
        XCTAssertEqual(original.map(\.id), [.claude, .codex, .grok])
    }

    func testLegacyAgentsTabMigratesWithoutChangingPreferredAgent() {
        defaults.set("agents", forKey: "popover.selectedTab")
        defaults.set("pi", forKey: "preferredAgent")
        _ = InstalledAgentVisibilityStore(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "popover.selectedTab"), "all")
        XCTAssertEqual(defaults.string(forKey: "preferredAgent"), "pi")
    }

    func testOtherLegacySelectionIsUntouched() {
        defaults.set("codex", forKey: "popover.selectedTab")
        _ = InstalledAgentVisibilityStore(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "popover.selectedTab"), "codex")
    }

    private func record(_ id: InstalledAgentID) -> InstalledAgentRecord {
        InstalledAgentRecord(id: id, evidence: [], capabilities: [], providerIDs: [])
    }
}
