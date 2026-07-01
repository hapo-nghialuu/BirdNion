import XCTest
@testable import BirdNion

/// Parser tests for the natively-authored new providers (fixture-driven, no
/// network). Cookie/OAuth/CLI providers expose their own `_parseForTesting`
/// hooks; these cover the three hand-written API-key parsers.
final class NewProviderTests: XCTestCase {

    func testElevenLabsParse() {
        let json = """
        {"tier":"creator","character_count":12000,"character_limit":100000,
         "voice_slots_used":3,"voice_limit":30,"next_character_count_reset_unix":1700000000}
        """.data(using: .utf8)!
        let s = ElevenLabsProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.first?.label, "Credits")
        XCTAssertEqual(s.windows.first?.usedPct, 12)   // 12000 / 100000
        XCTAssertEqual(s.planName, "Creator")
        XCTAssertTrue(s.windows.contains { $0.label == "Voice slots" })
    }

    func testCopilotParsePremiumAndPlaceholderSkip() {
        let json = """
        {"copilot_plan":"business","quota_reset_date":"2026-07-01",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"remaining":75,"percent_remaining":25},
           "chat":{"entitlement":0,"remaining":0,"percent_remaining":100}}}
        """.data(using: .utf8)!
        let s = CopilotProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.planName, "Business")
        // Premium: 25% remaining → 75% used. Chat is a zero-entitlement placeholder → skipped.
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows.first?.label, "Premium")
        XCTAssertEqual(s.windows.first?.usedPct, 75)
    }

    func testGroqParseScalarSumsSeries() {
        let json = """
        {"status":"success","data":{"result":[
          {"value":[1700000000,"1.5"]},
          {"value":[1700000000,2.5]}]}}
        """.data(using: .utf8)!
        XCTAssertEqual(GroqProvider.parseScalar(json), 4.0, accuracy: 0.001)
    }

    // MARK: - Parity additions (Wave 2-3)

    func testElevenLabsProVoicesAndStatusSuffix() {
        let json = """
        {"tier":"pro","status":"canceled","character_count":0,"character_limit":100,
         "voice_slots_used":1,"voice_limit":10,
         "professional_voice_slots_used":2,"professional_voice_limit":5}
        """.data(using: .utf8)!
        let s = ElevenLabsProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.planName, "Pro · canceled")  // status != active → suffix
        XCTAssertTrue(s.windows.contains { $0.label == "Professional voices" && $0.usedPct == 40 })
    }

    func testDeepSeekGrantedBreakdownAndLowBalance() {
        let json = """
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"5.00","granted_balance":"2.00","topped_up_balance":"3.00"}]}
        """.data(using: .utf8)!
        let s = DeepSeekProvider().parse(json, accountLabel: "u")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.windows.first?.usedPct, 0)
        XCTAssertTrue(s.windows.first?.subtitle?.contains("Trả: $3.00") ?? false)
        XCTAssertTrue(s.windows.first?.subtitle?.contains("Tặng: $2.00") ?? false)

        let zero = """
        {"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0"}]}
        """.data(using: .utf8)!
        let s2 = DeepSeekProvider().parse(zero, accountLabel: "u")
        XCTAssertEqual(s2.windows.first?.usedPct, 100)  // balance ≤ 0 → red warning
    }

    func testOpenCodeRenewWindow() {
        let json = """
        {"rollingUsage":{"usagePercent":50,"resetInSec":3600},
         "weeklyUsage":{"usagePercent":20,"resetInSec":86400},
         "renewAt":"2026-07-01T00:00:00Z"}
        """
        let s = OpenCodeProvider._parseForTesting(subscriptionText: json)
        XCTAssertNil(s.error)
        XCTAssertTrue(s.windows.contains { $0.label == "Gia hạn" })
    }

    /// Kiro menu-bar display modes turn structured credits/overage into the
    /// menu-bar title; nil falls back to numeric percents, "" = hidden.
    func testKiroMenuBarDisplayModes() {
        let menu = KiroMenuUsage(
            creditsRemaining: 1234, creditsUsed: 766, creditsTotal: 2000,
            primaryRemainingPct: 62,
            overageCreditsUsed: 50, overageCostUSD: 1.5)
        let s = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [],
                               lastUpdated: Date(), kiroMenu: menu)
        func text(_ m: KiroMenuBarDisplayMode) -> String? {
            MenuBarIconRenderer.kiroDisplayText(status: s, mode: m)
        }
        XCTAssertEqual(text(.hidden), "")
        XCTAssertEqual(text(.creditsLeft), "1234")
        XCTAssertEqual(text(.percentLeft), "62%")
        XCTAssertEqual(text(.creditsAndPercent), "1234 · 62%")
        XCTAssertEqual(text(.usedAndTotal), "766 / 2000")
        XCTAssertEqual(text(.overageCostWhenExhausted), "+$1.50")
        XCTAssertEqual(text(.automatic), "1234")  // hasTotal → credits

        // No kiroMenu → nil (caller shows percents); no overage → falls back.
        let bare = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [], lastUpdated: Date())
        XCTAssertNil(MenuBarIconRenderer.kiroDisplayText(status: bare, mode: .creditsLeft))
        let noOverage = KiroMenuUsage(creditsRemaining: 10, creditsUsed: 0, creditsTotal: 10, primaryRemainingPct: 100)
        let s2 = ProviderStatus(id: "kiro", displayName: "Kiro", windows: [], lastUpdated: Date(), kiroMenu: noOverage)
        XCTAssertEqual(MenuBarIconRenderer.kiroDisplayText(status: s2, mode: .overageCostWhenExhausted), "10")
    }

    func testMenuBarPercentTitleIncludesUnit() {
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [76]), "76%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [93, 82]), "93%  82%")
        XCTAssertEqual(MenuBarIconRenderer.percentTitle(for: [-4, 120]), "0%  100%")
    }

    func testMenuBarFramesFallBackToBirdWhenPercentHiddenOrNoQuota() {
        let status = ProviderStatus(
            id: "hapo", displayName: "AI Hub",
            windows: [QuotaWindow(label: "Week", usedPct: 24, remainingPct: 76)],
            lastUpdated: Date())
        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [status], showPercent: false, visibility: { _ in true }),
            [.bird])
        XCTAssertEqual(
            MenuBarIconRenderer.frames(
                from: [ProviderStatus(id: "hapo", displayName: "AI Hub", windows: [], lastUpdated: Date())],
                showPercent: true,
                visibility: { _ in true }),
            [.bird])
    }

    func testMenuBarFramesRotateThroughActiveProviderPercents() {
        let codex = ProviderStatus(
            id: "codex", displayName: "Codex",
            windows: [QuotaWindow(label: "5 hours", usedPct: 7, remainingPct: 93)],
            lastUpdated: Date())
        let hapo = ProviderStatus(
            id: "hapo", displayName: "AI Hub",
            windows: [QuotaWindow(label: "Week", usedPct: 24, remainingPct: 76)],
            lastUpdated: Date())

        XCTAssertEqual(
            MenuBarIconRenderer.frames(from: [codex, hapo], showPercent: true, visibility: { _ in true }),
            [
                .provider(id: "codex", name: "Codex", percents: [93], text: nil),
                .provider(id: "hapo", name: "AI Hub", percents: [76], text: nil),
            ])
    }

    /// Kilo org list comes back as a tRPC batch whose `json` is a DIRECT array
    /// of orgs (not `{organizations:[...]}`). The REST profile shape is also
    /// accepted as a fallback.
    func testKiloOrganizationsParseTRPCArrayAndREST() {
        let trpc = """
        [{"result":{"data":{"json":[
          {"id":"org_1","name":"Acme","role":"admin"},
          {"id":"org_2","name":"Beta"}]}}}]
        """.data(using: .utf8)!
        let orgs = KiloOrganization.parse(data: trpc)
        XCTAssertEqual(orgs.map(\.id), ["org_1", "org_2"])
        XCTAssertEqual(orgs.first?.name, "Acme")
        XCTAssertEqual(orgs.first?.role, "admin")
        XCTAssertNil(orgs.last?.role)  // missing role → nil

        let rest = #"{"organizations":[{"id":"org_3","name":"Gamma"}]}"#.data(using: .utf8)!
        XCTAssertEqual(KiloOrganization.parse(data: rest).map(\.id), ["org_3"])

        // Empty / unknown shape → empty array (not a crash).
        XCTAssertTrue(KiloOrganization.parse(data: Data("{}".utf8)).isEmpty)
    }

    /// FreeModel returns two dollar budgets (5h + weekly) as cents. The parser
    /// converts cents→USD, computes used%, and renders a "$used / $limit"
    /// subtitle. Account label passes through unchanged.
    func testFreemodelDollarWindows() {
        let json = """
        {"window5h":{"usedCents":2250,"limitCents":20000,"resetsAt":1782724407},
         "windowWeek":{"usedCents":8,"limitCents":132000,"resetsAt":1783321795}}
        """.data(using: .utf8)!
        let s = FreemodelProvider._parseForTesting(usageData: json, accountLabel: "me@x.com")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.accountLabel, "me@x.com")
        XCTAssertEqual(s.windows.count, 2)

        let fiveH = s.windows[0]
        XCTAssertEqual(fiveH.label, "5 giờ")
        XCTAssertEqual(fiveH.usedPct, 11)            // 2250/20000 = 11.25% → 11
        XCTAssertEqual(fiveH.remainingPct, 89)
        XCTAssertEqual(fiveH.subtitle, "$22.50 / $200.00")
        XCTAssertNotNil(fiveH.resetDate)

        let week = s.windows[1]
        XCTAssertEqual(week.label, "Tuần")
        XCTAssertEqual(week.usedPct, 0)              // 8/132000 ≈ 0.006% → 0
        XCTAssertEqual(week.subtitle, "$0.08 / $1,320.00")

        // Malformed payload → error, no windows.
        let bad = FreemodelProvider._parseForTesting(usageData: Data("{}".utf8), accountLabel: nil)
        XCTAssertNotNil(bad.error)
        XCTAssertTrue(bad.windows.isEmpty)
    }

    /// The cookie filter forwards every pair but only proceeds when `bm_session`
    /// is present, and tolerates a full "Cookie: …" header line pasted from devtools.
    func testFreemodelCookieHeaderFilter() {
        // Plain pair list with the session cookie → forwarded as-is.
        XCTAssertEqual(
            FreemodelProvider.filteredCookieHeader(from: "bm_session=abc; other=v"),
            "bm_session=abc; other=v")

        // A pasted "Cookie:" prefix is stripped so the session is still recognised.
        XCTAssertEqual(
            FreemodelProvider.filteredCookieHeader(from: "Cookie: bm_session=abc; other=v"),
            "bm_session=abc; other=v")

        // No session cookie → rejected (nil), even if other cookies exist.
        XCTAssertNil(FreemodelProvider.filteredCookieHeader(from: "_ga=1; __stripe_mid=2"))
    }
}
