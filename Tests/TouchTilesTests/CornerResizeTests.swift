import CoreGraphics
import XCTest
@testable import TouchTiles

final class CornerResizeTests: XCTestCase {
    private let screen = CGRect(x: -300, y: -800, width: 1200, height: 800)

    func testGripKeepsBothFractionsAcrossRepeatedResizes() throws {
        let start = CGRect(x: 48, y: 20, width: 800, height: 400)
        let grip = try XCTUnwrap(WindowGrip(at: CGPoint(x: 248, y: 320), in: start))
        let resized = CGRect(x: -305.5, y: -901.25, width: 507, height: 331)
        let position = try XCTUnwrap(grip.point(in: resized))
        XCTAssertEqual(position.x, -178.75)
        XCTAssertEqual(position.y, -653)
        XCTAssertEqual(grip.point(in: start), CGPoint(x: 248, y: 320))
    }

    func testRoundedGripStaysInsideItsOriginalCornerAtEdgesAndMidlines() throws {
        let start = CGRect(x: 0, y: 0, width: 600, height: 400)
        let target = CGRect(x: -200.25, y: 86.75, width: 43, height: 28)
        for x in [start.minX, start.midX - 0.01, start.midX, start.midX + 0.01, start.maxX] {
            for y in [start.minY, start.midY - 0.01, start.midY, start.midY + 0.01, start.maxY] {
                let origin = CGPoint(x: x, y: y)
                let original = ResizeCorner(at: origin, in: start)
                let grip = try XCTUnwrap(WindowGrip(at: origin, in: start))
                let position = try XCTUnwrap(grip.point(in: target))
                let rounded = CGPoint(x: position.x.rounded(), y: position.y.rounded())
                XCTAssertTrue(target.contains(rounded))
                let corner = ResizeCorner(at: rounded, in: target)
                XCTAssertEqual(corner.left, original.left)
                XCTAssertEqual(corner.top, original.top)
            }
        }
    }

    func testInvalidGeometryCannotProduceACursorPosition() throws {
        let grip = try XCTUnwrap(WindowGrip(at: screen.center, in: screen))
        let invalid: [CGRect] = [.zero, .null, .infinite,
                                 CGRect(x: 0, y: 1, width: -CGFloat.infinity, height: 10),
                                 CGRect(x: CGFloat.nan, y: 1, width: 10, height: 10)]
        for frame in invalid {
            XCTAssertNil(WindowGrip(at: .zero, in: frame))
            XCTAssertNil(grip.point(in: frame))
        }
        XCTAssertNil(WindowGrip(at: CGPoint(x: CGFloat.infinity, y: 0), in: screen))
    }

    func testPartlyOffscreenGripUsesTheNearestVisiblePointInItsQuarter() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let grip = try XCTUnwrap(WindowGrip(at: CGPoint(x: 180, y: 150), in: frame))
        func display(_ id: CGDirectDisplayID, from x: CGFloat, to end: CGFloat) -> MacDisplay {
            let bounds = CGRect(x: x, y: 0, width: end - x, height: 300)
            return MacDisplay(id: id, visibleFrame: bounds, fullFrame: bounds, space: nil)
        }
        let left = display(1, from: -100, to: 150)
        let right = display(2, from: 202, to: 500)
        XCTAssertEqual(grip.point(in: frame, on: [left, right]), CGPoint(x: 149, y: 150))
        XCTAssertEqual(grip.point(in: frame, on: [right]), CGPoint(x: 202, y: 150))
        XCTAssertNil(grip.point(in: frame, on: [display(3, from: 500, to: 820)]))
    }

    func testMiddleColumnChoosesTheGrabbedSideAndHoldsTheOtherDividerStill() throws {
        var baseline = Dwindle(limits: TileLimits(rows: 1, columns: 4))
        for id in 1...3 {
            baseline.insert(CGWindowID(id), near: CGWindowID(id - 1), at: .zero, in: screen)
        }
        let frames = baseline.frames(in: screen)
        let middle = try XCTUnwrap(frames[2])
        for grabsLeft in [true, false] {
            var tree = baseline
            let hit = CGPoint(x: grabsLeft ? middle.minX + 3 : middle.maxX - 3, y: middle.midY)
            tree.resize(2, corner: ResizeCorner(at: hit, in: middle), by: CGSize(width: 42, height: 90), in: screen)
            let result = tree.frames(in: screen)
            let moved = try XCTUnwrap(result[2])
            XCTAssertEqual(moved.minX, middle.minX + (grabsLeft ? 42 : 0))
            XCTAssertEqual(moved.maxX, middle.maxX + (grabsLeft ? 0 : 42))
            XCTAssertEqual(moved.minY, middle.minY)
            XCTAssertEqual(moved.maxY, middle.maxY)
            let unaffected: CGWindowID = grabsLeft ? 3 : 1
            XCTAssertEqual(result[unaffected], frames[unaffected])
        }
    }

    func testAtTheDisplayEdgeTheInteriorDividerFollowsScreenDirection() throws {
        var tree = Dwindle()
        tree.insert(1, near: nil, at: .zero, in: screen)
        tree.insert(2, near: 1, at: .zero, in: screen)
        tree.insert(3, near: 2, at: .zero, in: screen)
        let original = try XCTUnwrap(tree.frames(in: screen)[3])
        let outsideCorner = ResizeCorner(at: CGPoint(x: original.maxX, y: original.maxY), in: original)
        tree.resize(3, corner: outsideCorner, by: CGSize(width: 23, height: -34), in: screen)
        let result = try XCTUnwrap(tree.frames(in: screen)[3])
        XCTAssertEqual(result.minX, original.minX + 23)
        XCTAssertEqual(result.maxX, original.maxX)
        XCTAssertEqual(result.minY, original.minY - 34)
        XCTAssertEqual(result.maxY, original.maxY)
    }

    func testEveryFloatingCornerFollowsSignedMotionAndKeepsOppositeCornerFixed() {
        let frame = CGRect(x: -20, y: 90, width: 200, height: 150)
        for x in [frame.minX, frame.maxX] {
            for y in [frame.minY, frame.maxY] {
                let corner = ResizeCorner(at: CGPoint(x: x, y: y), in: frame)
                let resized = corner.floatingFrame(from: frame, by: CGSize(width: 25, height: -30))
                XCTAssertEqual(resized.minX, frame.minX + (corner.left ? 25 : 0))
                XCTAssertEqual(resized.maxX, frame.maxX + (corner.left ? 0 : 25))
                XCTAssertEqual(resized.minY, frame.minY - (corner.top ? 30 : 0))
                XCTAssertEqual(resized.maxY, frame.maxY - (corner.top ? 0 : 30))
            }
        }
    }
}
