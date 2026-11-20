import XCTest
@testable import TouchTiles

final class TileReflowTests: XCTestCase {
    private let left = CGRect(x: 0, y: 10, width: 350, height: 640)
    private let right = CGRect(x: 360, y: 10, width: 350, height: 640)
    private let whole = CGRect(x: 0, y: 10, width: 710, height: 640)

    func testSurvivorMovesThroughIntermediateFramesAndEndsAtExactTile() throws {
        var motion = TileReflow()
        let targets: [CGWindowID: CGRect] = [1: whole, 3: left]
        XCTAssertEqual(motion.reconcile(targets: targets, observed: [1: right], animate: [1], now: 0), [3: left])
        XCTAssertEqual(motion.sample(at: 0), [1: right])
        let midway = try XCTUnwrap(motion.sample(at: TileReflow.duration / 2)[1])
        XCTAssertGreaterThan(midway.minX, whole.minX)
        XCTAssertLessThan(midway.minX, right.minX)
        XCTAssertEqual(midway.maxX, whole.maxX)
        XCTAssertEqual(motion.sample(at: TileReflow.duration), [1: whole])
        XCTAssertTrue(motion.isEmpty)
    }

    func testSecondCloseResumesFromObservedGeometryAndDiscardsDeadTargets() throws {
        var motion = TileReflow()
        _ = motion.reconcile(targets: [1: whole, 2: whole], observed: [1: right, 2: left], animate: [1, 2], now: 1)
        let now = 1.05
        let interrupted = try XCTUnwrap(motion.sample(at: now)[1])
        let taller = whole.insetBy(dx: 0, dy: -10)
        XCTAssertEqual(motion.reconcile(targets: [1: taller], observed: [1: interrupted], animate: [1], now: now), [:])
        XCTAssertEqual(motion.sample(at: now), [1: interrupted])
        XCTAssertEqual(motion.sample(at: 2), [1: taller])
    }

    func testOrdinaryRefreshPreservesMotionAndNewLayoutCancelsIt() {
        var motion = TileReflow()
        _ = motion.reconcile(targets: [1: whole], observed: [1: left], animate: [1], now: 2)
        XCTAssertEqual(motion.reconcile(targets: [1: whole], observed: [1: left], animate: [], now: 2.1), [:])
        XCTAssertEqual(motion.reconcile(targets: [1: right], observed: [1: left], animate: [], now: 2.15), [1: right])
        XCTAssertTrue(motion.isEmpty)
    }
}
