import XCTest
@testable import BirdNion

final class PopoverPanelSizingTests: XCTestCase {
    func testShortContentUsesFittingHeight() {
        XCTAssertEqual(
            height(fittingHeight: 300, top: 900, visibleFrameMinY: 100),
            300
        )
    }

    func testContentAbovePreviousCapUsesFittingHeight() {
        XCTAssertEqual(
            height(fittingHeight: 700, top: 900, visibleFrameMinY: 100),
            700
        )
    }

    func testTallContentUsesAvailableScreenHeight() {
        XCTAssertEqual(
            height(fittingHeight: 1_200, top: 900, visibleFrameMinY: 100),
            792
        )
    }

    func testMissingScreenUsesFittingHeight() {
        XCTAssertEqual(
            height(fittingHeight: 900, top: 1_200, visibleFrameMinY: nil),
            900
        )
    }

    func testHeightHasMinimumOfOneWhenScreenHasNoAvailableSpace() {
        XCTAssertEqual(
            height(fittingHeight: 500, top: 5, visibleFrameMinY: 20),
            1
        )
    }

    func testEqualHeightDoesNotNeedResize() {
        XCTAssertFalse(
            PopoverPanelSizing.needsResize(currentHeight: 500, targetHeight: 500)
        )
    }

    func testHeightDeltaWithinToleranceDoesNotNeedResize() {
        XCTAssertFalse(
            PopoverPanelSizing.needsResize(currentHeight: 500, targetHeight: 500.5)
        )
    }

    func testHeightDeltaAboveToleranceNeedsResize() {
        XCTAssertTrue(
            PopoverPanelSizing.needsResize(currentHeight: 500, targetHeight: 500.51)
        )
    }

    private func height(
        fittingHeight: CGFloat,
        top: CGFloat,
        visibleFrameMinY: CGFloat?
    ) -> CGFloat {
        PopoverPanelSizing.height(
            fittingHeight: fittingHeight,
            top: top,
            visibleFrameMinY: visibleFrameMinY
        )
    }
}

final class SettingsWindowOpenerTests: XCTestCase {
    // Settings select lists (e.g. 29 currencies ≈ 936 pt) must stay on the
    // anchor's screen: a list taller than the room below opens above or
    // scrolls instead of being moved to another display.
    private let laptop = NSRect(x: 843, y: -956, width: 1470, height: 924)

    func testSelectListFittingBelowOpensBelowAnchor() {
        let anchor = NSRect(x: 1900, y: -300, width: 160, height: 28)
        let frame = InstrumentMenuPanelLayout.frame(
            anchor: anchor, contentHeight: 104, width: 180, visibleFrame: laptop)
        XCTAssertEqual(frame, NSRect(x: 1900, y: -408, width: 180, height: 104))
    }

    func testSelectListTooTallBelowOpensAboveWhenItFits() {
        let anchor = NSRect(x: 1900, y: -900, width: 160, height: 28)
        let frame = InstrumentMenuPanelLayout.frame(
            anchor: anchor, contentHeight: 300, width: 180, visibleFrame: laptop)
        XCTAssertEqual(frame, NSRect(x: 1900, y: -868, width: 180, height: 300))
    }

    func testSelectListTallerThanEitherSideIsClampedToTheScreen() {
        let anchor = NSRect(x: 1900, y: -400, width: 160, height: 28)
        let frame = InstrumentMenuPanelLayout.frame(
            anchor: anchor, contentHeight: 936, width: 180, visibleFrame: laptop)
        XCTAssertTrue(laptop.contains(frame), "\(frame) leaves the anchor's screen")
        XCTAssertLessThan(frame.height, 936)
        XCTAssertFalse(frame.intersects(anchor), "list must not cover its own trigger")
    }

    func testSelectListIsPulledBackFromTheRightScreenEdge() {
        let anchor = NSRect(x: 2250, y: -300, width: 160, height: 28)
        let frame = InstrumentMenuPanelLayout.frame(
            anchor: anchor, contentHeight: 104, width: 180, visibleFrame: laptop)
        XCTAssertEqual(frame.maxX, laptop.maxX)
    }

    func testRetryIntervalsStayWithinColdBootBudget() {
        XCTAssertEqual(SettingsWindowOpener.retryIntervals.first, 0)
        XCTAssertLessThanOrEqual(SettingsWindowOpener.retryIntervals.reduce(0, +), 20)
    }
}
