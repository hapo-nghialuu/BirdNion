import XCTest
@testable import AIStatusbar

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
        XCTAssertEqual(pace?.lastsUntilReset, true) // burn rate leaves headroom
        XCTAssertEqual(pace?.resetText, "20h 46m")
    }

    func testWindowPaceOverPaceWillNotLast() {
        // 90% used very early in the week → over pace, won't last.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(6 * 24 * 3600) // ~1 day elapsed of 7
        let w = QuotaWindow(label: "Tuần", usedPct: 90, remainingPct: 10,
                            resetDate: reset, windowSeconds: 604_800)
        let pace = WindowPace(window: w, now: now)
        XCTAssertEqual(pace?.reservePct, 0)          // way over linear pace
        XCTAssertEqual(pace?.lastsUntilReset, false)
        XCTAssertEqual(pace?.resetText, "6d 0h")
    }

    func testWindowPaceNilWithoutData() {
        let w = QuotaWindow(label: "Tuần", usedPct: 40, remainingPct: 60) // no reset/seconds
        XCTAssertNil(WindowPace(window: w))
    }
}
