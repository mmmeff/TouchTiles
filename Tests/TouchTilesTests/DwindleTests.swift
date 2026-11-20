import CoreGraphics
import XCTest
@testable import TouchTiles

final class DwindleTests: XCTestCase {
    // Secondary monitor to the left and above the primary, with an odd width and height.
    private let screen = CGRect(x: -1201, y: -301, width: 1201, height: 901)

    private func threeWindows() -> Dwindle {
        var tree = Dwindle()
        tree.insert(1, near: nil, at: .zero, in: screen)
        tree.insert(2, near: 1, at: .zero, in: screen)
        tree.insert(3, near: 2, at: .zero, in: screen)
        return tree
    }

    func testNewWindowSplitsTheFocusedTileAndPreservesGaps() throws {
        let tree = threeWindows()
        let frames = tree.frames(in: screen)
        let left = try XCTUnwrap(frames[1])
        let upper = try XCTUnwrap(frames[2])
        let lower = try XCTUnwrap(frames[3])
        XCTAssertEqual(tree.ids, [1, 2, 3])
        XCTAssertEqual(left.minX, screen.minX + 10)
        XCTAssertEqual(upper.maxX, screen.maxX - 10)
        XCTAssertEqual(left.minY, screen.minY + 10)
        XCTAssertEqual(lower.maxY, screen.maxY - 10)
        XCTAssertEqual(upper.minX - left.maxX, 10)
        XCTAssertEqual(lower.minY - upper.maxY, 10)
        XCTAssertEqual(upper.minX, lower.minX)
        XCTAssertEqual(left.maxY, lower.maxY)

        let portrait = CGRect(x: 300, y: -200, width: 700, height: 1400)
        let rotated = tree.frames(in: portrait)
        XCTAssertLessThan(try XCTUnwrap(rotated[1]).maxX, try XCTUnwrap(rotated[2]).minX)
    }

    func testRemovingALeafPromotesTheWholeSiblingTree() throws {
        var tree = threeWindows()
        tree.remove(1)
        let frames = tree.frames(in: screen)
        XCTAssertEqual(tree.ids, [2, 3])
        XCTAssertEqual(try XCTUnwrap(frames[2]).width, screen.width - 20)
        XCTAssertEqual(try XCTUnwrap(frames[3]).width, screen.width - 20)
        tree.remove(2)
        XCTAssertEqual(tree.frames(in: screen)[3], screen.insetBy(dx: 10, dy: 10))
        tree.remove(3)
        XCTAssertTrue(tree.ids.isEmpty)
        XCTAssertTrue(tree.frames(in: screen).isEmpty)
    }

    func testTopLeftDragResizesASecondChildOnBothAxes() throws {
        var tree = threeWindows()
        let before = try XCTUnwrap(tree.frames(in: screen)[3])
        let corner = ResizeCorner(at: before.origin, in: before)
        tree.resize(3, corner: corner, by: CGSize(width: -33, height: -51), in: screen)
        let after = try XCTUnwrap(tree.frames(in: screen)[3])
        XCTAssertEqual(after.width, before.width + 33, accuracy: 1)
        XCTAssertEqual(after.height, before.height + 51, accuracy: 1)
        XCTAssertEqual(after.maxX, before.maxX)
        XCTAssertEqual(after.maxY, before.maxY)
        tree.resize(3, corner: corner, by: CGSize(width: 33, height: 51), in: screen)
        XCTAssertEqual(tree.frames(in: screen)[3], before)
    }

    func testContinuousSubpointDeltasAccumulate() throws {
        var tree = threeWindows()
        let before = try XCTUnwrap(tree.frames(in: screen)[2])
        let corner = ResizeCorner(at: CGPoint(x: before.minX, y: before.maxY), in: before)
        for _ in 0..<20 { tree.resize(2, corner: corner, by: CGSize(width: -0.25, height: 0.25), in: screen) }
        let after = try XCTUnwrap(tree.frames(in: screen)[2])
        XCTAssertEqual(after.width, before.width + 5, accuracy: 1)
        XCTAssertEqual(after.height, before.height + 5, accuracy: 1)
    }

    func testAnAxisWithoutAnAncestorSplitCannotResize() throws {
        var tree = threeWindows()
        tree.remove(3)
        let before = tree.frames(in: screen)
        let right = try XCTUnwrap(before[2])
        let left = try XCTUnwrap(before[1])
        tree.resize(2, corner: ResizeCorner(at: right.origin, in: right), by: CGSize(width: 0, height: -300), in: screen)
        XCTAssertEqual(tree.frames(in: screen), before)
        let corner = ResizeCorner(at: CGPoint(x: left.maxX, y: left.maxY), in: left)
        tree.resize(1, corner: corner, by: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0), in: screen)
        let small = try XCTUnwrap(tree.frames(in: screen)[2])
        XCTAssertEqual(small.width + 15, screen.width * 0.05, accuracy: 1)
        XCTAssertGreaterThan(small.height, 0)
    }

    func testNearestCellAndDraggedSide() throws {
        var tree = threeWindows()
        let upperLeft = CGPoint(x: screen.minX + 40, y: screen.minY + 35)
        tree.insert(4, near: nil, at: upperLeft, in: screen)
        XCTAssertEqual(tree.ids, [1, 4, 2, 3])
        tree.remove(4)
        tree.insertDragged(4, near: nil, at: upperLeft, in: screen)
        XCTAssertEqual(tree.ids, [4, 1, 2, 3])
    }

    func testDuplicatesUnknownIDsAndSwap() {
        var tree = threeWindows()
        let before = tree.frames(in: screen)
        tree.insert(3, near: 2, at: .zero, in: screen)
        tree.resize(100, corner: ResizeCorner(at: screen.center, in: screen), by: CGSize(width: 50, height: 50), in: screen)
        tree.remove(101)
        tree.swap(102, 3)
        tree.swap(2, 2)
        XCTAssertEqual(tree.frames(in: screen), before)
        tree.swap(1, 3)
        XCTAssertEqual(tree.frames(in: screen)[1], before[3])
        XCTAssertEqual(tree.frames(in: screen)[2], before[2])
        XCTAssertEqual(tree.frames(in: screen)[3], before[1])
    }

    func testNarrowCellsGiveUpTheirGaps() throws {
        var tree = Dwindle()
        let small = CGRect(x: 0, y: 0, width: 17, height: 10)
        tree.insert(1, near: nil, at: .zero, in: small)
        tree.insert(2, near: 1, at: .zero, in: small)
        let frames = tree.frames(in: small)
        let first = try XCTUnwrap(frames[1])
        let second = try XCTUnwrap(frames[2])
        XCTAssertGreaterThanOrEqual(first.width, 1)
        XCTAssertGreaterThanOrEqual(second.width, 1)
        XCTAssertTrue(small.contains(first))
        XCTAssertTrue(small.contains(second))
        XCTAssertLessThanOrEqual(first.maxX, second.minX)
        XCTAssertTrue(tree.frames(in: .zero).isEmpty)
    }

    func testDefaultLimitsHoldAcrossEveryHorizontalAndVerticalScanline() {
        let bounds = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        var tree = Dwindle()
        for id: CGWindowID in 1...16 {
            XCTAssertTrue(tree.insert(id, near: id - 1, at: bounds.center, in: bounds))
        }
        XCTAssertFalse(tree.insert(17, near: 16, at: bounds.center, in: bounds))
        let frames = Array(tree.frames(in: bounds).values)
        func maximumIntersections(_ minimum: KeyPath<CGRect, CGFloat>, _ maximum: KeyPath<CGRect, CGFloat>) -> Int {
            let edges = Set(frames.flatMap { [$0[keyPath: minimum], $0[keyPath: maximum]] }).sorted()
            return zip(edges, edges.dropFirst()).map { a, b in
                let mid = (a + b) / 2
                return frames.filter { $0[keyPath: minimum] < mid && mid < $0[keyPath: maximum] }.count
            }.max() ?? 0
        }
        // At fixed x, at most two tiles can stack. At fixed y, at most eight can sit side by side.
        XCTAssertEqual(maximumIntersections(\.minX, \.maxX), 2)
        XCTAssertEqual(maximumIntersections(\.minY, \.maxY), 8)
    }

    func testOneColumnUsesVerticalSplitsEvenOnAWideScreen() throws {
        var tree = Dwindle(limits: TileLimits(rows: 3, columns: 1))
        for id: CGWindowID in 1...3 { XCTAssertTrue(tree.insert(id, near: 1, at: .zero, in: screen)) }
        let frames = tree.frames(in: screen)
        XCTAssertEqual(Set(frames.values.map(\.minX)).count, 1)
        XCTAssertEqual(Set(frames.values.map(\.minY)).count, 3)
        XCTAssertFalse(tree.insert(4, near: 1, at: .zero, in: screen))
        tree.remove(2)
        XCTAssertTrue(tree.insert(4, near: 1, at: .zero, in: screen))
    }

    func testPortraitSplitFallsBackToATileWithRemainingCapacity() throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 1400)
        var tree = Dwindle(limits: TileLimits(rows: 2, columns: 2))
        for id: CGWindowID in 1...3 { XCTAssertTrue(tree.insert(id, near: 1, at: .zero, in: bounds)) }
        let original = tree.frames(in: bounds)
        XCTAssertTrue(tree.insert(4, near: 1, at: .zero, in: bounds))
        let next = tree.frames(in: bounds)
        XCTAssertEqual(next[1], original[1])
        XCTAssertEqual(next[3], original[3])
        XCTAssertEqual(try XCTUnwrap(next[4]).minY, try XCTUnwrap(next[2]).minY)
        XCTAssertLessThan(try XCTUnwrap(next[2]).width, try XCTUnwrap(original[2]).width)
    }
}
