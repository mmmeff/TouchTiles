import XCTest
@testable import TouchTiles

final class FloatingPreviewTests: XCTestCase {
    func testCaptureRequiresAnExplicitShareableWindow() {
        XCTAssertFalse(FloatingPreviews.isShareable(nil))
        XCTAssertFalse(FloatingPreviews.isShareable(0))
        XCTAssertTrue(FloatingPreviews.isShareable(1))
        XCTAssertTrue(FloatingPreviews.isShareable(2))
        XCTAssertFalse(FloatingPreviews.isShareable(3))
    }
}
