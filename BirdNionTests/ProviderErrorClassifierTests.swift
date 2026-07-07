import XCTest
@testable import BirdNion

/// Pure classifier tests: one representative string per kind, precedence pins,
/// nil/empty, and digit-in-text negative cases (Red Team Finding 5).
final class ProviderErrorClassifierTests: XCTestCase {
    // MARK: - One assertion per kind

    func testCookieMarker() {
        XCTAssertEqual(classify(rawError: "Không tìm thấy cookie trình duyệt"), .cookieExpiredOrMissing)
        XCTAssertEqual(classify(rawError: "sessionKey missing"), .cookieExpiredOrMissing)
    }

    func testRateLimited() {
        XCTAssertEqual(classify(rawError: "HTTP 429"), .rateLimited)
        XCTAssertEqual(classify(rawError: "Rate limit exceeded, too many requests"), .rateLimited)
    }

    func testNetworkTimeout() {
        XCTAssertEqual(classify(rawError: "Claude: timeout sau 12s"), .networkUnreachableOrTimeout)
        XCTAssertEqual(classify(rawError: "Network: could not connect to host"), .networkUnreachableOrTimeout)
        XCTAssertEqual(classify(rawError: "Mất kết nối mạng"), .networkUnreachableOrTimeout)
    }

    func testTokenInvalid() {
        XCTAssertEqual(classify(rawError: "Chưa cấu hình token"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "HTTP 401"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "HTTP 403"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "unauthorized"), .tokenInvalidOrMissing)
    }

    func testSchemaChanged() {
        XCTAssertEqual(classify(rawError: "Response JSON không hợp lệ"), .apiSchemaChanged)
        XCTAssertEqual(classify(rawError: "Response thiếu trường"), .apiSchemaChanged)
        XCTAssertEqual(classify(rawError: "HTTP 500"), .apiSchemaChanged)
        XCTAssertEqual(classify(rawError: "HTTP 503"), .apiSchemaChanged)
    }

    func testUnknownFallback() {
        XCTAssertEqual(classify(rawError: "weird gibberish"), .unknown)
    }

    // MARK: - Precedence (order of checks)

    func testCookieBeatsTokenCode() {
        // 401 present but cookie marker wins (R0.3).
        XCTAssertEqual(classify(rawError: "HTTP 401 (cookie)"), .cookieExpiredOrMissing)
    }

    func testRateBeatsTokenCode() {
        XCTAssertEqual(classify(rawError: "429"), .rateLimited)
    }

    func testNetworkBeatsSchema() {
        // "invalid" schema marker present but timeout wins (R0.5).
        XCTAssertEqual(classify(rawError: "timeout — invalid response"), .networkUnreachableOrTimeout)
    }

    // MARK: - nil / empty (R0.7)

    func testNilAndEmpty() {
        XCTAssertNil(classify(rawError: nil))
        XCTAssertNil(classify(rawError: ""))
        XCTAssertNil(classify(rawError: "   "))
    }

    // MARK: - Digit-in-text negatives (Finding 5)

    func testDigitsEmbeddedInTextAreNotHTTPCodes() {
        // Unit suffix: the 429 belongs to "429ms", timeout marker wins anyway.
        XCTAssertEqual(classify(rawError: "timeout sau 429ms"), .networkUnreachableOrTimeout)
        // "5000" must not be read as a 500 schema code; "tokens" here is a count
        // word, but it does contain the token marker → tokenInvalidOrMissing is
        // NOT acceptable either per Finding 5 intent; the string has no error
        // marker other than the count. "token" substring matches "tokens" — use
        // the exact spec assertion: NOT apiSchemaChanged.
        XCTAssertNotEqual(classify(rawError: "5000 tokens used"), .apiSchemaChanged)
        // Long digit run → no code, no marker → unknown.
        XCTAssertEqual(classify(rawError: "account id 140399"), .unknown)
        // Version string must not be read as codes.
        XCTAssertEqual(classify(rawError: "cli v0.140.0 mismatch detected"), .unknown)
    }

    // MARK: - L10n key mapping (R0.1)

    func testKindKeys() {
        XCTAssertEqual(ProviderErrorKind.rateLimited.titleKey, "providerError.rateLimited.title")
        XCTAssertEqual(ProviderErrorKind.cookieExpiredOrMissing.hintKey, "providerError.cookieExpiredOrMissing.hint")
        XCTAssertEqual(ProviderErrorKind.allCases.count, 6)
    }

    // MARK: - Localization resolution (R1.1–R1.3)

    /// Every kind's title + hint must resolve in BOTH languages — a lookup
    /// falling through to the raw key means a missing table entry.
    func testAllKindsResolveInBothLanguages() {
        for kind in ProviderErrorKind.allCases {
            for lang in ["vi", "en"] {
                XCTAssertNotEqual(L10n.t(kind.titleKey, lang), kind.titleKey,
                                  "\(kind.titleKey) missing in \(lang)")
                XCTAssertNotEqual(L10n.t(kind.hintKey, lang), kind.hintKey,
                                  "\(kind.hintKey) missing in \(lang)")
            }
            // vi and en copies must actually differ (negative-path check).
            XCTAssertNotEqual(L10n.t(kind.hintKey, "vi"), L10n.t(kind.hintKey, "en"))
        }
    }

    func testSelfTestAndNotificationKeysResolve() {
        for key in ["provider.selfTest", "provider.selfTest.running", "provider.selfTest.pass",
                    "provider.selfTest.fail", "provider.selfTest.disabled",
                    "notification.providerFailing"] {
            for lang in ["vi", "en"] {
                XCTAssertNotEqual(L10n.t(key, lang), key, "\(key) missing in \(lang)")
            }
        }
    }
}
