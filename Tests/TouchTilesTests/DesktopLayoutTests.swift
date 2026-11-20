import CoreGraphics
import XCTest
@testable import TouchTiles

final class DesktopLayoutTests: XCTestCase {
    private let primaryFrame = CGRect(x: 0, y: 0, width: 1600, height: 1050)
    private let secondaryFrame = CGRect(x: -1280, y: -200, width: 1280, height: 800)

    private func screen(id: CGDirectDisplayID, frame: CGRect, space: UInt64) -> MacDisplay {
        MacDisplay(
            id: id,
            visibleFrame: CGRect(x: frame.minX, y: frame.minY + 24, width: frame.width, height: frame.height - 24),
            fullFrame: frame,
            space: space
        )
    }

    private func windows(_ ids: [CGWindowID], on screen: MacDisplay) -> [WindowPosition] {
        let frame = CGRect(x: screen.visibleFrame.minX + 82, y: screen.visibleFrame.minY + 44, width: 400, height: 260)
        return ids.map { WindowPosition(id: $0, frame: frame) }
    }

    func testSpaceSwitchKeepsTheOriginalSplitsAndRatios() throws {
        let first = screen(id: 1, frame: primaryFrame, space: 101)
        let second = screen(id: 1, frame: primaryFrame, space: 102)
        let external = screen(id: 2, frame: secondaryFrame, space: 201)
        let externalWindows = windows([8, 9], on: external)
        let firstWindows = windows([1, 2, 3], on: first)
        var layout = DesktopLayout()
        layout.reconcile(firstWindows + externalWindows, on: [first, external], focused: 1, pointer: first.visibleFrame.center)
        let tile = try XCTUnwrap(layout.frames(on: first)[1])
        let corner = ResizeCorner(at: CGPoint(x: tile.maxX, y: tile.minY), in: tile)
        layout.resize(1, corner: corner, by: CGSize(width: 47, height: -63), on: first)
        let original = layout.frames(on: first)
        XCTAssertNotEqual(original[1], tile)
        let externalFrames = layout.frames(on: external)

        layout.reconcile(windows([4], on: second) + externalWindows, on: [second, external], focused: 4, pointer: .zero)
        XCTAssertEqual(Set(layout.frames(on: second).keys), [4])
        XCTAssertEqual(layout.frames(on: external), externalFrames)
        layout.reconcile(firstWindows + externalWindows, on: [first, external], focused: 2, pointer: .zero)
        XCTAssertEqual(layout.frames(on: first), original)
        XCTAssertEqual(layout.frames(on: external), externalFrames)
    }

    func testDropAcrossDisplaysCanBePreviewedWithoutCommitting() throws {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        let external = screen(id: 2, frame: secondaryFrame, space: 201)
        var layout = DesktopLayout()
        layout.reconcile(windows([1, 2], on: main) + windows([3], on: external),
                         on: [main, external], focused: 2, pointer: .zero)
        let mainFrames = layout.frames(on: main)
        let externalFrames = layout.frames(on: external)
        var preview = layout
        preview.detach(1, from: main)
        XCTAssertTrue(preview.attachDragged(1, at: CGPoint(x: external.visibleFrame.minX + 40, y: external.visibleFrame.midY), on: external))
        let destination = preview.frames(on: external)
        XCTAssertEqual(Set(preview.frames(on: main).keys), [2])
        XCTAssertEqual(Set(destination.keys), [1, 3])
        XCTAssertLessThan(try XCTUnwrap(destination[1]).maxX, try XCTUnwrap(destination[3]).minX)
        XCTAssertEqual(layout.frames(on: main), mainFrames)
        XCTAssertEqual(layout.frames(on: external), externalFrames)

        let moved = destination.map { WindowPosition(id: $0.key, frame: $0.value) }
        preview.reconcile(windows([2], on: main) + moved, on: [main, external], focused: 1, pointer: .zero)
        XCTAssertEqual(preview.frames(on: external), destination)
        XCTAssertEqual(preview.frames(on: main)[2], main.visibleFrame.insetBy(dx: 10, dy: 10))
    }

    func testDiscardingADetachedPreviewRetainsTheOriginalSplitRatios() throws {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        var layout = DesktopLayout()
        layout.reconcile(windows([3, 2, 1], on: main), on: [main], focused: nil, pointer: .zero)
        let originalTile = try XCTUnwrap(layout.frames(on: main)[2])
        let corner = ResizeCorner(at: originalTile.origin, in: originalTile)
        layout.resize(2, corner: corner, by: CGSize(width: -109, height: -73), on: main)
        let frames = layout.frames(on: main)
        var preview = layout
        preview.detach(2, from: main)
        XCTAssertFalse(preview.contains(2, on: main))
        XCTAssertNotEqual(preview.frames(on: main), frames)
        XCTAssertEqual(layout.frames(on: main), frames)
    }

    func testManualMonitorMoveReassignsTheLeafByLargestOverlap() {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        let external = screen(id: 2, frame: secondaryFrame, space: 201)
        var layout = DesktopLayout()
        layout.reconcile(windows([1, 2], on: main), on: [main, external], focused: nil, pointer: .zero)
        let straddling = CGRect(x: -600, y: 80, width: 800, height: 450)
        XCTAssertEqual(DesktopLayout.screen(containing: straddling, in: [main, external])?.id, external.id)
        layout.reconcile([WindowPosition(id: 1, frame: straddling)] + windows([2], on: main),
                         on: [main, external], focused: 1, pointer: .zero)
        XCTAssertEqual(layout.frames(on: main), [2: main.visibleFrame.insetBy(dx: 10, dy: 10)])
        XCTAssertEqual(layout.frames(on: external), [1: external.visibleFrame.insetBy(dx: 10, dy: 10)])
    }

    func testOpeningTilingWithSixteenWindowsBalancesOnlyTheExistingBatch() throws {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        let existing = windows(Array(1...16), on: main)
        var layout = DesktopLayout(limits: TileLimits(rows: 8, columns: 8))
        layout.reconcile(existing, on: [main], focused: 5, pointer: .zero)
        let frames = layout.frames(on: main)
        XCTAssertEqual(frames.count, 16)
        for rect in frames.values {
            XCTAssertGreaterThan(rect.width, main.visibleFrame.width / 4 - 21)
            XCTAssertGreaterThan(rect.height, main.visibleFrame.height / 4 - 21)
        }

        let focused = try XCTUnwrap(frames[5])
        layout.reconcile(windows([17], on: main) + existing, on: [main], focused: 5, pointer: main.visibleFrame.origin)
        let after = layout.frames(on: main)
        for (id, frame) in frames where id != 5 { XCTAssertEqual(after[id], frame) }
        XCTAssertGreaterThan(try XCTUnwrap(after[17]).minX, focused.minX)
        XCTAssertLessThan(try XCTUnwrap(after[5]).width, focused.width)
    }

    func testCrossDisplaySwipeClampsToTheNearestDisplayAtAnOutsideEdge() {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        let external = screen(id: 2, frame: secondaryFrame, space: 201)
        let displays = [main, external]
        for x in [external.fullFrame.midX, external.fullFrame.minX - 60] {
            XCTAssertEqual(DesktopLayout.screen(nearest: CGPoint(x: x, y: 100), in: displays)?.id, external.id)
        }
        XCTAssertEqual(DesktopLayout.screen(nearest: CGPoint(x: 100, y: -30), in: displays)?.id, main.id)
        XCTAssertNil(DesktopLayout.screen(nearest: .zero, in: []))
    }

    func testOverflowFloatsAndTheOldestWaitingWindowFillsAVacancy() {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        var layout = DesktopLayout(limits: TileLimits(rows: 1, columns: 2))
        func reconcile(_ ids: [CGWindowID]) {
            layout.reconcile(windows(ids, on: main), on: [main], focused: 1, pointer: .zero)
        }
        reconcile([2, 1])
        let initial = layout.frames(on: main)
        reconcile([3, 2, 1])
        reconcile([4, 3, 2, 1])
        XCTAssertEqual(layout.frames(on: main), initial)
        // Bringing the first waiting window to the front must not reset the queue.
        reconcile([3, 1, 4])
        XCTAssertEqual(Set(layout.frames(on: main).keys), [1, 3])
        XCTAssertFalse(layout.contains(4, on: main))
        reconcile([4, 1])
        XCTAssertEqual(Set(layout.frames(on: main).keys), [1, 4])
    }

    func testDropOnFullSecondDisplayPreservesSourceAndDestination() throws {
        let main = screen(id: 1, frame: primaryFrame, space: 101)
        let external = screen(id: 2, frame: secondaryFrame, space: 201)
        var layout = DesktopLayout(limits: TileLimits(rows: 1, columns: 2))
        layout.reconcile(windows([2, 1], on: main) + windows([4, 3], on: external),
                         on: [main, external], focused: nil, pointer: .zero)
        let mainBefore = layout.frames(on: main)
        let externalBefore = layout.frames(on: external)
        var candidate = layout
        candidate.detach(1, from: main)
        XCTAssertFalse(candidate.attachDragged(1, at: external.visibleFrame.center, on: external))
        XCTAssertEqual(candidate.frames(on: external), externalBefore)
        XCTAssertEqual(layout.frames(on: main), mainBefore)
        XCTAssertEqual(layout.frames(on: external), externalBefore)

        let target = try XCTUnwrap(mainBefore[2])
        XCTAssertTrue(candidate.attachDragged(1, at: CGPoint(x: target.maxX - 5, y: target.midY), on: main))
        XCTAssertEqual(candidate.frames(on: main)[1], mainBefore[2])
        XCTAssertEqual(candidate.frames(on: main)[2], mainBefore[1])
    }
}
