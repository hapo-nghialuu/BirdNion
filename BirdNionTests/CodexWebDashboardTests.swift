import XCTest
@testable import BirdNion
import CodexBarCore

/// Tests for `CodexWebDashboard` — only the pure snapshot → extras mapping and
/// the enabled flag. The actual scrape (hidden WKWebView + browser cookies)
/// can't run in a unit test. Kept in its own file so `import CodexBarCore`
/// (for OpenAIDashboardSnapshot) doesn't clash with BirdNion's Codex types.
final class CodexWebDashboardTests: XCTestCase {
    func testMapsDashboardSnapshot() {
        let snap = OpenAIDashboardSnapshot(
            signedInEmail: "u@x.com",
            codeReviewRemainingPercent: 73.6,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: "https://chatgpt.com/codex/settings/credits",
            creditsRemaining: 12.5,
            updatedAt: Date())
        let extras = CodexWebDashboard.map(snap)
        XCTAssertEqual(extras.signedInEmail, "u@x.com")
        XCTAssertEqual(extras.codeReviewRemainingPercent, 74)   // rounded
        XCTAssertEqual(extras.creditsRemaining, 12.5)
        XCTAssertEqual(extras.creditsPurchaseURL, "https://chatgpt.com/codex/settings/credits")
        XCTAssertNil(extras.creditsHistoryCount)                // no credit events
    }

    func testMapsClampsCodeReviewPercent() {
        let snap = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: 142,   // out of range → clamped
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        XCTAssertEqual(CodexWebDashboard.map(snap).codeReviewRemainingPercent, 100)
    }

    func testDisabledByDefault() {
        let key = CodexWebDashboard.enabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(CodexWebDashboard.isEnabled)
    }
}
