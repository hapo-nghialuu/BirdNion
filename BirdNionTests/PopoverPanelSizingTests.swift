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
