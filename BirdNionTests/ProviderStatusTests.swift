import XCTest
@testable import BirdNion

final class ProviderStatusTests: XCTestCase {
    func testQuotaWindowRoundTrip() throws {
        let w = QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80)
        let data = try JSONEncoder().encode(w)
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: data)
        XCTAssertEqual(w.label, decoded.label)
        XCTAssertEqual(w.usedPct, decoded.usedPct)
        XCTAssertEqual(w.remainingPct, decoded.remainingPct)
    }

    func testProviderStatusWindowsPreserveOrder() throws {
        let s = ProviderStatus(
            id: "minimax",
            displayName: "MiniMax",
            windows: [
                QuotaWindow(label: "5 giờ", usedPct: 20, remainingPct: 80),
                QuotaWindow(label: "Tuần", usedPct: 40, remainingPct: 60)
            ],
            lastUpdated: Date(timeIntervalSince1970: 1700000000)
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProviderStatus.self, from: data)
        XCTAssertEqual(decoded.windows.count, 2)
        XCTAssertEqual(decoded.windows[0].label, "5 giờ")
        XCTAssertEqual(decoded.windows[1].label, "Tuần")
    }

    func testErrorFieldRoundTripsNilAndString() throws {
        let nilErr = ProviderStatus(id: "x", displayName: "X", windows: [], lastUpdated: Date(), error: nil)
        let someErr = ProviderStatus(id: "x", displayName: "X", windows: [], lastUpdated: Date(), error: "boom")
        let d1 = try JSONDecoder().decode(ProviderStatus.self, from: try JSONEncoder().encode(nilErr))
        let d2 = try JSONDecoder().decode(ProviderStatus.self, from: try JSONEncoder().encode(someErr))
        XCTAssertNil(d1.error)
        XCTAssertEqual(d2.error, "boom")
    }

    func testProviderCopyDoesNotLeakVietnameseIntoEnglishUI() {
        let samples = [
            "Hapo endpoint chưa được cấu hình trong bản build",
            "Chưa đăng nhập OpenCode trên trình duyệt",
            "Không tìm thấy session cookie của MiMo (cần serviceToken)",
            "Không lấy được dữ liệu từ Cost Explorer và CloudWatch",
            "File credentials không đọc được",
            "Hết số dư — cần nạp thêm",
            "Chưa cấu hình API key Groq",
            "Không có project Deepgram cho key này",
            "Antigravity OAuth client chưa được cấu hình",
            "Response thiếu trường credits",
            "API key ElevenLabs không hợp lệ",
            "Không thể phân tích dữ liệu usage OpenCode",
            "Codex CLI không trả dữ liệu — kiểm tra `codex`",
            "Token Codex hết hạn — chạy `codex` để đăng nhập lại",
            "Chưa cài Kiro CLI",
            "Định dạng tRPC batch không nhận ra",
            "Không tìm thấy tổ chức Claude cho tài khoản này.",
            "Chỉ hỗ trợ macOS.",
        ]

        for sample in samples {
            let localized = L10n.providerText(sample, preference: SettingsStore.Language.english.rawValue)
            XCTAssertNil(localized.range(of: #"[À-ỹĐđ]"#, options: .regularExpression), localized)
        }
        XCTAssertEqual(
            L10n.providerText(samples[0], preference: SettingsStore.Language.english.rawValue),
            "Hapo endpoint is not configured in this build"
        )
    }

    func testProviderLabelsLocalizeInBothDirections() {
        XCTAssertEqual(L10n.windowLabel("Tuần", preference: "en"), "Week")
        XCTAssertEqual(L10n.windowLabel("5 giờ", preference: "en"), "5 hours")
        XCTAssertEqual(L10n.windowLabel("Requests (30d)", preference: "vi"), "Yêu cầu (30 ngày)")
        XCTAssertEqual(L10n.windowLabel("Bonus Credits", preference: "vi"), "Tín dụng thưởng")
    }

    func testVietnameseTableDoesNotKeepEnglishActionLabels() {
        XCTAssertEqual(L10n.t("popover.refresh", "vi"), "Làm mới")
        XCTAssertEqual(L10n.t("popover.settings", "vi"), "Cài đặt")
        XCTAssertEqual(L10n.t("chart.latestTokens", "vi"), "Token gần nhất")
    }

    // MARK: - ProviderStatusPage strip rules

    func testStatusPageURLsForClaudeCodexGrok() {
        XCTAssertEqual(
            ProviderStatusPage.url(for: "claude")?.absoluteString,
            "https://status.claude.com/")
        XCTAssertEqual(
            ProviderStatusPage.url(for: "codex")?.absoluteString,
            "https://status.openai.com/")
        XCTAssertEqual(
            ProviderStatusPage.url(for: "grok")?.absoluteString,
            "https://status.x.ai")
        XCTAssertNil(ProviderStatusPage.url(for: "minimax"))
    }

    func testStatusPageHasIssueLevels() {
        XCTAssertFalse(ProviderStatusPage.hasIssue(level: nil))
        XCTAssertFalse(ProviderStatusPage.hasIssue(level: "none"))
        XCTAssertTrue(ProviderStatusPage.hasIssue(level: "minor"))
        XCTAssertTrue(ProviderStatusPage.hasIssue(level: "critical"))
        XCTAssertTrue(ProviderStatusPage.hasIssue(level: "maintenance"))
        XCTAssertEqual(ProviderStatusPage.health(level: "none"), .ok)
        XCTAssertEqual(ProviderStatusPage.health(level: "major"), .issue)
        XCTAssertEqual(ProviderStatusPage.health(level: nil), .unknown)
    }

    func testStripAlwaysShowsOperationalClaudeAsOk() {
        let s = ProviderStatus(
            id: "claude", displayName: "Claude", windows: [], lastUpdated: Date(),
            serviceStatus: "All Systems Operational", serviceStatusLevel: "none")
        let strip = ProviderStatusPage.strip(
            for: s, statusChecksEnabled: true,
            operationalLabel: "Operational", issueFallbackLabel: "Issues",
            unknownLabel: "No data yet")
        XCTAssertEqual(strip?.health, .ok)
        XCTAssertEqual(strip?.label, "All Systems Operational")
    }

    func testStripShowsClaudeIssueAsRed() {
        let s = ProviderStatus(
            id: "claude", displayName: "Claude", windows: [], lastUpdated: Date(),
            serviceStatus: "Partial System Outage", serviceStatusLevel: "major")
        let strip = ProviderStatusPage.strip(
            for: s, statusChecksEnabled: true,
            operationalLabel: "Operational", issueFallbackLabel: "Issues",
            unknownLabel: "No data yet")
        XCTAssertEqual(strip?.health, .issue)
        XCTAssertEqual(strip?.label, "Partial System Outage")
    }

    func testStripUnknownWhenStatusChecksDisabled() {
        let s = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [], lastUpdated: Date(),
            serviceStatus: "Major Outage", serviceStatusLevel: "critical")
        let strip = ProviderStatusPage.strip(
            for: s, statusChecksEnabled: false,
            operationalLabel: "Operational", issueFallbackLabel: "Issues",
            unknownLabel: "No data yet")
        XCTAssertEqual(strip?.health, .unknown)
        XCTAssertEqual(strip?.label, "No data yet")
    }

    func testStripGrokAlwaysUnknownWithLink() {
        let s = ProviderStatus(
            id: "grok", displayName: "Grok", windows: [], lastUpdated: Date())
        let strip = ProviderStatusPage.strip(
            for: s, statusChecksEnabled: true,
            operationalLabel: "Operational", issueFallbackLabel: "Issues",
            unknownLabel: "No data yet")
        XCTAssertEqual(strip?.health, .unknown)
        XCTAssertEqual(strip?.label, "No data yet")
    }

    func testStripCodexOkAndIssue() {
        let ok = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [], lastUpdated: Date(),
            serviceStatus: "All Systems Operational", serviceStatusLevel: "none")
        XCTAssertEqual(
            ProviderStatusPage.strip(
                for: ok, statusChecksEnabled: true,
                operationalLabel: "Operational", issueFallbackLabel: "Issues",
                unknownLabel: "No data yet")?.health,
            .ok)
        let bad = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [], lastUpdated: Date(),
            serviceStatus: nil, serviceStatusLevel: "critical")
        XCTAssertEqual(
            ProviderStatusPage.strip(
                for: bad, statusChecksEnabled: true,
                operationalLabel: "Operational", issueFallbackLabel: "Issues",
                unknownLabel: "No data yet")?.label,
            "Issues")
    }

    func testProviderReorderMovesDownAfterHoveredRow() {
        let rows = ["a", "b", "c", "d"].map { BirdNionConfigStore.Provider(id: $0) }
        let reordered = ProvidersPane.reorderedProviders(
            rows, visibleIDs: rows.map(\.id), draggedID: "a", targetIndex: 2)
        XCTAssertEqual(reordered.map(\.id), ["b", "c", "a", "d"])
    }

    func testProviderReorderMovesUpBeforeHoveredRow() {
        let rows = ["a", "b", "c", "d"].map { BirdNionConfigStore.Provider(id: $0) }
        let reordered = ProvidersPane.reorderedProviders(
            rows, visibleIDs: rows.map(\.id), draggedID: "d", targetIndex: 1)
        XCTAssertEqual(reordered.map(\.id), ["a", "d", "b", "c"])
    }

    func testProviderReorderUsesVisibleGroupedOrder() {
        let rows = [
            BirdNionConfigStore.Provider(id: "a", enabled: true),
            BirdNionConfigStore.Provider(id: "b", enabled: false),
            BirdNionConfigStore.Provider(id: "c", enabled: true),
            BirdNionConfigStore.Provider(id: "d", enabled: false),
        ]
        let reordered = ProvidersPane.reorderedProviders(
            rows, visibleIDs: ["a", "c", "b", "d"], draggedID: "a", targetIndex: 1)
        XCTAssertEqual(reordered.map(\.id), ["b", "c", "a", "d"])
    }

    // MARK: - WindowPace (linear reserve / lasts-until-reset)

    func testWindowPaceReserveMatchesUnderPace() {
        // Weekly window, 37% used, reset in 20h46m → ~87.6% elapsed → ~51% reserve.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(20 * 3600 + 46 * 60)
        let w = QuotaWindow(label: "Tuần", usedPct: 37, remainingPct: 63,
                            resetDate: reset, windowSeconds: 604_800)
        let pace = WindowPace(window: w, now: now)
        XCTAssertNotNil(pace)
        XCTAssertEqual(pace?.reservePct, 51)        // 87.63 - 37 ≈ 50.6 → 51
        XCTAssertEqual(pace?.deltaPct, -51)         // signed CodexBar delta (reserve)
        XCTAssertEqual(pace?.isOnTrack, false)
        XCTAssertEqual(pace?.lastsUntilReset, true) // burn rate leaves headroom
        XCTAssertNil(pace?.etaSeconds)              // lasts → no run-out ETA
        XCTAssertEqual(pace?.resetText, "20h 46m")
        // Expected-used marker sits at the elapsed fraction of the window.
        XCTAssertEqual(pace.map { Int($0.expectedUsedPct.rounded()) }, 88)
    }

    func testWindowPaceOverPaceWillNotLast() {
        // 90% used very early in the week → over pace, won't last.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(6 * 24 * 3600) // ~1 day elapsed of 7
        let w = QuotaWindow(label: "Tuần", usedPct: 90, remainingPct: 10,
                            resetDate: reset, windowSeconds: 604_800)
        let pace = WindowPace(window: w, now: now)
        XCTAssertEqual(pace?.reservePct, 0)          // way over linear pace
        XCTAssertEqual(pace?.deltaPct, 76)           // 90 used vs ~14 expected
        XCTAssertEqual(pace?.lastsUntilReset, false)
        // 90% in 1 day → remaining 10% burns in ~9600s (2h40m).
        XCTAssertEqual(pace?.etaSeconds.map { Int($0.rounded()) }, 9_600)
        XCTAssertEqual(pace?.resetText, "6d 0h")
    }

    func testWindowPaceNilWithoutData() {
        let w = QuotaWindow(label: "Tuần", usedPct: 40, remainingPct: 60) // no reset/seconds
        XCTAssertNil(WindowPace(window: w))
    }

    // MARK: - withServiceStatus (copy helper)

    /// The copy helper must override only `serviceStatus`/`serviceStatusLevel`
    /// and leave every other field — including quota windows and
    /// `lastUpdated` — byte-for-byte identical.
    func testWithServiceStatusOverridesOnlyThoseTwoFields() {
        let original = ProviderStatus(
            id: "codex",
            displayName: "Codex",
            windows: [QuotaWindow(label: "5 giờ", usedPct: 10, remainingPct: 90)],
            lastUpdated: Date(timeIntervalSince1970: 1_000),
            error: nil,
            accountLabel: "acct",
            planType: "plus",
            serviceStatus: "Degraded",
            serviceStatusLevel: "major")

        let copy = original.withServiceStatus("All Systems Operational", level: "none")

        XCTAssertEqual(copy.serviceStatus, "All Systems Operational")
        XCTAssertEqual(copy.serviceStatusLevel, "none")
        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.displayName, original.displayName)
        XCTAssertEqual(copy.windows, original.windows)
        XCTAssertEqual(copy.lastUpdated, original.lastUpdated)
        XCTAssertNil(copy.error)
        XCTAssertEqual(copy.accountLabel, original.accountLabel)
        XCTAssertEqual(copy.planType, original.planType)
    }

    func testWithServiceStatusAcceptsNilPair() {
        let original = ProviderStatus(
            id: "codex", displayName: "Codex", windows: [], lastUpdated: Date(),
            serviceStatus: "All Systems Operational", serviceStatusLevel: "none")
        let copy = original.withServiceStatus(nil, level: nil)
        XCTAssertNil(copy.serviceStatus)
        XCTAssertNil(copy.serviceStatusLevel)
    }

    func testOnboardingDetectionPrefersPrimaryWithoutReadingSecrets() {
        let primary = ProvidersPane.onboardingDetection(
            hasPrimary: true, primaryLabel: "Login file",
            hasSecondary: true, secondaryLabel: "CLI", fallbackLabel: "None")
        let secondary = ProvidersPane.onboardingDetection(
            hasPrimary: false, primaryLabel: "Login file",
            hasSecondary: true, secondaryLabel: "CLI", fallbackLabel: "None")
        let missing = ProvidersPane.onboardingDetection(
            hasPrimary: false, primaryLabel: "Login file",
            hasSecondary: false, secondaryLabel: "CLI", fallbackLabel: "None")

        XCTAssertEqual(primary, .init(isReady: true, source: "Login file"))
        XCTAssertEqual(secondary, .init(isReady: true, source: "CLI"))
        XCTAssertEqual(missing, .init(isReady: false, source: "None"))
    }

    func testOnboardingPhaseRequiresRealQuotaOrPassingSelfTestForLive() {
        XCTAssertEqual(ProvidersPane.onboardingPhase(
            testState: .idle, statusHasError: false,
            statusHasQuota: false, detectionReady: false), .needsSource)
        XCTAssertEqual(ProvidersPane.onboardingPhase(
            testState: .idle, statusHasError: false,
            statusHasQuota: false, detectionReady: true), .readyToTest)
        XCTAssertEqual(ProvidersPane.onboardingPhase(
            testState: .running, statusHasError: false,
            statusHasQuota: false, detectionReady: true), .testing)
        XCTAssertEqual(ProvidersPane.onboardingPhase(
            testState: .idle, statusHasError: true,
            statusHasQuota: false, detectionReady: true), .failed)
        XCTAssertEqual(ProvidersPane.onboardingPhase(
            testState: .pass, statusHasError: false,
            statusHasQuota: false, detectionReady: true), .live)
    }
}
