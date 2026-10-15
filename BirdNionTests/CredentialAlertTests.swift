import XCTest
@testable import BirdNion

/// Episode semantics for credential-expiry alerts (CodexBar contract):
/// one alert per provider per failure episode, prompt on first detection,
/// reset only by a fresh successful fetch — network/quota errors never fire.
final class CredentialAlertTests: XCTestCase {

    private let enabledKey = "credentialExpiryNotificationsEnabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    @MainActor
    private func makeService(
        posted: @escaping (String) -> Void,
        removed: @escaping (String) -> Void = { _ in }
    ) -> QuotaService {
        QuotaService(
            providers: [],
            interval: 60,
            failureNotificationPost: { id, _, _ in posted(id) },
            failureNotificationRemove: { removed($0) },
            legacyFailureNotificationCleanup: { _ in })
    }

    @MainActor
    func testCredentialErrorPostsOncePerEpisode() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        var posted: [String] = []
        let svc = makeService(posted: { posted.append($0) })

        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized token")
        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized token")
        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized token")

        let credentialPosts = posted.filter { $0.hasPrefix("provider.credential.") }
        XCTAssertEqual(credentialPosts, ["provider.credential.claude"])
        XCTAssertTrue(svc.credentialAlertActive(for: "claude"))
    }

    @MainActor
    func testFreshSuccessResetsEpisodeAndRemovesAlert() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        var posted: [String] = []
        var removed: [String] = []
        let svc = makeService(posted: { posted.append($0) }, removed: { removed.append($0) })

        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized")
        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: nil)

        XCTAssertEqual(removed, ["provider.credential.claude"])
        XCTAssertFalse(svc.credentialAlertActive(for: "claude"))

        // A later failure starts a new episode and alerts again.
        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized")
        let credentialPosts = posted.filter { $0.hasPrefix("provider.credential.") }
        XCTAssertEqual(credentialPosts, ["provider.credential.claude", "provider.credential.claude"])
    }

    @MainActor
    func testNonCredentialErrorsNeverAlert() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        var posted: [String] = []
        let svc = makeService(posted: { posted.append($0) })

        for _ in 0..<4 {
            svc.evaluateFailureEpisode(id: "codex", displayName: "Codex", error: "network timeout")
            svc.evaluateFailureEpisode(id: "codex", displayName: "Codex", error: "http 429 rate limit")
        }

        // The generic failure notification may fire after 3 failures — the
        // assertion is only that no CREDENTIAL alert was posted.
        XCTAssertTrue(posted.allSatisfy { !$0.hasPrefix("provider.credential.") })
        XCTAssertFalse(svc.credentialAlertActive(for: "codex"))
    }

    @MainActor
    func testToggleOffSuppressesDeliveryButRetainsEpisode() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        var posted: [String] = []
        let svc = makeService(posted: { posted.append($0) })

        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized")

        XCTAssertTrue(posted.isEmpty)
        // Episode still recorded — re-enabling mid-episode must not re-alert.
        XCTAssertTrue(svc.credentialAlertActive(for: "claude"))

        UserDefaults.standard.set(true, forKey: enabledKey)
        svc.evaluateFailureEpisode(id: "claude", displayName: "Claude", error: "401 unauthorized")
        XCTAssertTrue(posted.isEmpty)
    }

    @MainActor
    func testCookieAndBrowserDataKindsAlsoAlert() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        var posted: [String] = []
        let svc = makeService(posted: { posted.append($0) })

        svc.evaluateFailureEpisode(id: "a", displayName: "A", error: "session cookie missing")
        svc.evaluateFailureEpisode(id: "b", displayName: "B", error: "thiếu quyền đọc dữ liệu trình duyệt")

        XCTAssertEqual(posted, ["provider.credential.a", "provider.credential.b"])
    }
}
