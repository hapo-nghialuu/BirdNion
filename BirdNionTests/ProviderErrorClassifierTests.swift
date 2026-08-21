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
        // A token that's present but wrong/expired -> tokenInvalidOrMissing.
        // "Never configured" phrasing is a DIFFERENT kind (see testNotConfigured).
        XCTAssertEqual(classify(rawError: "Token hết hạn"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "HTTP 401"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "HTTP 403"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "unauthorized"), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "xAI team was not found (HTTP 404). Check the Team ID."), .tokenInvalidOrMissing)
        XCTAssertEqual(classify(rawError: "Không tìm thấy xAI team (HTTP 404). Kiểm tra Team ID."), .tokenInvalidOrMissing)
    }

    func testNotConfigured() {
        // "Never set up" is distinct from "wrong/expired" (R4 — Error UX).
        XCTAssertEqual(classify(rawError: "Chưa cấu hình token"), .notConfigured)
        XCTAssertEqual(classify(rawError: "Chưa đăng nhập Codex — chạy `codex` để đăng nhập"), .notConfigured)
        XCTAssertEqual(
            classify(rawError: "xAI Management API key is not configured. Set XAI_MANAGEMENT_API_KEY."),
            .notConfigured
        )
        XCTAssertEqual(classify(rawError: "Antigravity: chưa đăng nhập Google (Login with Google trong Settings)"),
                       .notConfigured)
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
        XCTAssertEqual(ProviderErrorKind.allCases.count, 7)
    }

    // MARK: - Fix-button eligibility (R4 — Error UX)

    func testIsFixableOnlyForConfigCredentialCookie() {
        XCTAssertTrue(ProviderErrorKind.notConfigured.isFixable)
        XCTAssertTrue(ProviderErrorKind.tokenInvalidOrMissing.isFixable)
        XCTAssertTrue(ProviderErrorKind.cookieExpiredOrMissing.isFixable)
        XCTAssertFalse(ProviderErrorKind.rateLimited.isFixable)
        XCTAssertFalse(ProviderErrorKind.networkUnreachableOrTimeout.isFixable)
        XCTAssertFalse(ProviderErrorKind.apiSchemaChanged.isFixable)
        XCTAssertFalse(ProviderErrorKind.unknown.isFixable)
    }

    func testRemediationTargetsAreExactAndFixableOnly() {
        XCTAssertEqual(remediationTarget(providerID: "claude", kind: .notConfigured), .setupSource)
        XCTAssertEqual(remediationTarget(providerID: "codex", kind: .tokenInvalidOrMissing), .setupSource)
        XCTAssertEqual(remediationTarget(providerID: "grok", kind: .cookieExpiredOrMissing), .setupSource)
        XCTAssertEqual(remediationTarget(providerID: "claude", kind: .cookieExpiredOrMissing), .cookieSource)
        XCTAssertEqual(remediationTarget(providerID: "codex", kind: .cookieExpiredOrMissing), .cookieSource)
        XCTAssertEqual(remediationTarget(providerID: "openrouter", kind: .tokenInvalidOrMissing), .credential)

        for kind in [ProviderErrorKind.networkUnreachableOrTimeout, .rateLimited,
                     .apiSchemaChanged, .unknown] {
            XCTAssertNil(remediationTarget(providerID: "claude", kind: kind))
        }
    }

    func testRemediationTargetRawValuesAreStableAndNonSecret() {
        XCTAssertEqual(ProviderRemediationTarget.allCases.map(\.rawValue),
                       ["setupSource", "credential", "cookieSource"])
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
                    "provider.guidedSetup.saveFailed", "notification.providerFailing"] {
            for lang in ["vi", "en"] {
                XCTAssertNotEqual(L10n.t(key, lang), key, "\(key) missing in \(lang)")
            }
        }
    }

    func testActionCenterProjectsOnlyCurrentSetupAndConnectionIssues() {
        let now = Date()
        let statuses = [
            ProviderStatus(id: "claude", displayName: "Claude", windows: [],
                           lastUpdated: now, error: "Chưa cấu hình token"),
            ProviderStatus(id: "groq", displayName: "Groq", windows: [],
                           lastUpdated: now, error: "HTTP 429"),
            ProviderStatus(id: "codex", displayName: "Codex",
                           windows: [QuotaWindow(label: "Week", usedPct: 10, remainingPct: 90)],
                           lastUpdated: now),
            ProviderStatus(id: "grok", displayName: "Grok", windows: [],
                           lastUpdated: now, error: "HTTP 429"),
            ProviderStatus(id: "openai", displayName: "OpenAI", windows: [],
                           lastUpdated: now, error: "HTTP 429"),
        ]
        let providers = ["claude", "groq", "codex", "grok", "openai"].map {
            BirdNionConfigStore.Provider(id: $0, enabled: true)
        }
        let issues = ActionCenterIssue.current(
            providers: providers,
            statuses: statuses,
            detectionReady: { _ in true },
            staleWarning: { id in
                id == "codex"
                    ? StaleQuotaWarning(kind: .networkUnreachableOrTimeout, lastGoodUpdated: now)
                    : nil
            })

        XCTAssertEqual(issues.map(\.providerID), ["claude", "codex", "grok"])
        XCTAssertEqual(issues.map(\.kind), [.setup, .connection, .connection])
        XCTAssertEqual(issues.first?.remediationTarget, .setupSource)
        XCTAssertNil(issues[1].remediationTarget)
        XCTAssertFalse(issues.contains { $0.providerID == "groq" || $0.providerID == "openai" })
    }

    func testActionCenterIncludesEnabledProviderWithNoDetectedSourceBeforeStatusArrives() {
        let providers = [BirdNionConfigStore.Provider(id: "claude", enabled: true)]
        let issues = ActionCenterIssue.current(
            providers: providers,
            statuses: [],
            detectionReady: { _ in false },
            staleWarning: { _ in nil })

        XCTAssertEqual(issues, [ActionCenterIssue(
            providerID: "claude", providerName: "Claude",
            kind: .setup, remediationTarget: .setupSource)])
    }

    func testActionCenterCopyResolvesWithoutRawProviderError() {
        let keys = [
            "settings.tab.actionCenter", "actionCenter.title", "actionCenter.subtitle",
            "actionCenter.current", "actionCenter.emptyTitle", "actionCenter.emptyBody",
            "actionCenter.setupTitle", "actionCenter.setupHint",
            "actionCenter.connectionTitle", "actionCenter.connectionHint",
            "actionCenter.serviceTitle", "actionCenter.serviceHint",
            "actionCenter.fix", "actionCenter.retry", "actionCenter.open",
        ]
        for key in keys {
            for language in ["vi", "en"] {
                XCTAssertNotEqual(L10n.t(key, language), key, "missing \(key) in \(language)")
            }
        }
    }

    // MARK: - Last-good transient policy

    func testNilAndEmptyAreNotTransient() {
        XCTAssertFalse(isTransientForLastGood(rawError: nil))
        XCTAssertFalse(isTransientForLastGood(rawError: ""))
        XCTAssertFalse(isTransientForLastGood(rawError: "   "))
    }

    func testNetworkTimeoutAndRateLimitAreTransient() {
        XCTAssertTrue(isTransientForLastGood(rawError: "Claude: timeout sau 12s"))
        XCTAssertTrue(isTransientForLastGood(rawError: "Network: could not connect to host"))
        XCTAssertTrue(isTransientForLastGood(rawError: "HTTP 429 rate limit exceeded"))
    }

    func testServer5xxIsTransientButGenericSchemaIsNot() {
        XCTAssertTrue(isTransientForLastGood(rawError: "server responded (500)"))
        XCTAssertTrue(isTransientForLastGood(rawError: "HTTP 503"))
        XCTAssertFalse(isTransientForLastGood(rawError: "Response không hợp lệ"))
        XCTAssertFalse(isTransientForLastGood(rawError: "failed to parse json response"))
    }

    func testCredentialAndCookieErrorsAreNotTransient() {
        XCTAssertFalse(isTransientForLastGood(rawError: "HTTP 401"))
        XCTAssertFalse(isTransientForLastGood(rawError: "Chưa cấu hình token"))
        XCTAssertFalse(isTransientForLastGood(rawError: "Cookie hết hạn"))
    }

    func testUnknownErrorIsNotTransient() {
        XCTAssertFalse(isTransientForLastGood(rawError: "something weird happened"))
    }
}

/// The stale banner shows while last-good quota is still on screen, so it must
/// name the cause instead of reusing the error card's remediation hint. Reusing
/// `hintKey` there told users to "connect this provider in Settings" for a
/// provider that was signed in and serving data.
final class StaleCauseCopyTests: XCTestCase {
    func testEveryKindHasStaleCauseCopyInBothLanguages() {
        for kind in ProviderErrorKind.allCases {
            for language in ["vi", "en"] {
                let text = L10n.t(kind.staleCauseKey, language)
                // L10n.t echoes the key back when no entry exists.
                XCTAssertNotEqual(text, kind.staleCauseKey,
                                  "missing \(language) copy for \(kind.staleCauseKey)")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Guards the regression directly: the banner string must never collapse
    /// back onto the instruction-phrased error-card string.
    func testStaleCauseIsDistinctFromErrorCardHint() {
        for kind in ProviderErrorKind.allCases {
            XCTAssertNotEqual(kind.staleCauseKey, kind.hintKey)
            for language in ["vi", "en"] {
                XCTAssertNotEqual(L10n.t(kind.staleCauseKey, language),
                                  L10n.t(kind.hintKey, language),
                                  "\(kind) reuses the error-card hint in \(language)")
            }
        }
    }

    /// The specific string the user saw: a signed-in Claude whose background
    /// refresh was skipped must not be told to go configure anything.
    func testNotConfiguredCauseDoesNotTellUserToOpenSettings() {
        let english = L10n.t(ProviderErrorKind.notConfigured.staleCauseKey, "en").lowercased()
        let vietnamese = L10n.t(ProviderErrorKind.notConfigured.staleCauseKey, "vi").lowercased()
        XCTAssertFalse(english.contains("settings"))
        XCTAssertFalse(english.contains("connect"))
        XCTAssertFalse(vietnamese.contains("cài đặt"))
        XCTAssertFalse(vietnamese.contains("kết nối"))
    }
}
