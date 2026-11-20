import CoreGraphics
import XCTest
@testable import TouchTiles

final class MinimumLayoutTests: XCTestCase {
    private let landscape = CGRect(x: -1200, y: -200, width: 1200, height: 800)

    func testWidestWindowInAStackConstrainsItsColumnWhileHeightsRemainIndependent() throws {
        var tree = Dwindle()
        for id: CGWindowID in 1...3 {
            XCTAssertTrue(tree.insert(id, near: id - 1, at: landscape.center, in: landscape))
        }
        tree.minimumSizes = [2: CGSize(width: 512, height: 350), 3: CGSize(width: 625, height: 258)]
        let lower = try XCTUnwrap(tree.frames(in: landscape)[3])
        let corner = ResizeCorner(at: lower.origin, in: lower)
        tree.resize(3, corner: corner, by: CGSize(width: 1000, height: 1000), in: landscape)
        let frames = tree.frames(in: landscape)
        let upper = try XCTUnwrap(frames[2])
        let clamped = try XCTUnwrap(frames[3])
        XCTAssertEqual(upper.width, 625)
        XCTAssertEqual(clamped.width, 625)
        XCTAssertEqual(clamped.height, 258)
        XCTAssertGreaterThanOrEqual(upper.height, 350)
        XCTAssertEqual(upper.minX, clamped.minX)
        XCTAssertEqual(upper.minX - (try XCTUnwrap(frames[1])).maxX, 10)
        XCTAssertEqual(clamped.minY - upper.maxY, 10)

        tree.resize(3, corner: corner, by: CGSize(width: -1, height: -1), in: landscape)
        XCTAssertEqual(tree.frames(in: landscape)[3]?.size, CGSize(width: 626, height: 259))
        tree.remove(3)
        tree.resize(2, corner: corner, by: CGSize(width: 1000, height: 0), in: landscape)
        XCTAssertEqual(tree.frames(in: landscape)[2]?.width, 512)
    }

    func testTallestWindowInASideBySidePairConstrainsItsRow() throws {
        let portrait = CGRect(x: 300, y: -100, width: 800, height: 1200)
        var tree = Dwindle()
        for id: CGWindowID in 1...3 {
            XCTAssertTrue(tree.insert(id, near: id - 1, at: portrait.center, in: portrait))
        }
        tree.minimumSizes = [2: CGSize(width: 280, height: 650), 3: CGSize(width: 190, height: 500)]
        let right = try XCTUnwrap(tree.frames(in: portrait)[3])
        tree.resize(3, corner: ResizeCorner(at: right.origin, in: right),
                    by: CGSize(width: 1000, height: 1000), in: portrait)
        XCTAssertEqual(tree.frames(in: portrait)[2]?.height, 650)
        XCTAssertEqual(tree.frames(in: portrait)[3]?.size, CGSize(width: 190, height: 650))
    }

    func testWindowsUseTheOtherAxisWhenTheirCombinedWidthsCannotFit() throws {
        var tree = Dwindle(minimumSizes: [1: CGSize(width: 720, height: 0), 2: CGSize(width: 720, height: 0)])
        XCTAssertTrue(tree.insert(1, near: nil, at: .zero, in: landscape))
        XCTAssertTrue(tree.insert(2, near: 1, at: .zero, in: landscape))
        let frames = tree.frames(in: landscape)
        let first = try XCTUnwrap(frames[1])
        let second = try XCTUnwrap(frames[2])
        XCTAssertEqual(first.width, landscape.width - 20)
        XCTAssertEqual(first.minX, second.minX)
        XCTAssertEqual(second.minY - first.maxY, 10)
    }

    func testAnExactFitUsesZeroGapsAndOnePointLessOverflows() throws {
        let limits = TileLimits(rows: 1, columns: 2)
        let floors: [CGWindowID: CGSize] = [1: CGSize(width: 750, height: 0), 2: CGSize(width: 450, height: 0)]
        var tree = Dwindle(limits: limits, minimumSizes: floors)
        XCTAssertTrue(tree.insert(1, near: nil, at: .zero, in: landscape))
        XCTAssertTrue(tree.insertDragged(2, near: 1, at: landscape.origin, in: landscape))
        let frames = tree.frames(in: landscape)
        let left = try XCTUnwrap(frames[2])
        let right = try XCTUnwrap(frames[1])
        XCTAssertEqual(left.minX, landscape.minX)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, landscape.maxX)
        XCTAssertEqual(left.minY, landscape.minY + 10)
        XCTAssertEqual(right.maxY, landscape.maxY - 10)
        XCTAssertEqual(left.width, 450)
        XCTAssertEqual(right.width, 750)
        XCTAssertFalse(tree.fits(in: CGRect(x: 0, y: 0, width: 1199, height: landscape.height)))
    }

    func testHardFloorAboveTheNormalNinetyFivePercentLimitStillAllowsMotion() throws {
        var tree = Dwindle(limits: TileLimits(rows: 1, columns: 2))
        tree.insert(1, near: nil, at: .zero, in: landscape)
        tree.insert(2, near: 1, at: .zero, in: landscape)
        tree.minimumSizes = [1: CGSize(width: 1150, height: 0)]
        let left = try XCTUnwrap(tree.frames(in: landscape)[1])
        XCTAssertEqual(left.width, 1150)
        let corner = ResizeCorner(at: CGPoint(x: left.maxX, y: left.maxY), in: left)
        tree.resize(1, corner: corner, by: CGSize(width: 2, height: 0), in: landscape)
        XCTAssertEqual(tree.frames(in: landscape)[1]?.width, 1152)
    }

    func testOverflowSkipsAnOversizedWindowAndReadmitsItOnALargerDisplay() throws {
        let small = MacDisplay(id: 1, visibleFrame: landscape, fullFrame: landscape, space: 7)
        let bigger = CGRect(x: -1200, y: -200, width: 2000, height: 800)
        let large = MacDisplay(id: 1, visibleFrame: bigger, fullFrame: bigger, space: 7)
        var layout = DesktopLayout(limits: TileLimits(rows: 1, columns: 2))
        let windows = [2, 1].map { WindowPosition(id: CGWindowID($0), frame: landscape) }
        layout.reconcile(windows, on: [small], focused: nil, pointer: .zero)
        layout.minimumSizes = [1: CGSize(width: 1500, height: 300), 2: CGSize(width: 330, height: 0)]
        layout.reconcile(windows, on: [small], focused: 1, pointer: .zero)
        XCTAssertEqual(layout.frames(on: small), [2: landscape.insetBy(dx: 10, dy: 10)])
        layout.reconcile(windows, on: [large], focused: 2, pointer: .zero)
        let frames = layout.frames(on: large)
        XCTAssertEqual(Set(frames.keys), [1, 2])
        XCTAssertGreaterThanOrEqual((try XCTUnwrap(frames[1])).width, 1500)
        XCTAssertGreaterThanOrEqual((try XCTUnwrap(frames[2])).width, 330)
    }
}
