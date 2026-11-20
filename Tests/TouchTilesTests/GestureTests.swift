import AppKit
import XCTest
@testable import TouchTiles

final class GestureTests: XCTestCase {
    private func fingers(_ positions: [(CGFloat, CGFloat)]) -> [Finger] {
        positions.enumerated().map { index, point in
            Finger(path: Int32(index), position: CGPoint(x: point.0, y: point.1))
        }
    }

    func testRawPinchAndTwoFingerMotionPassThroughToMacOS() {
        var contacts = ContactGesture()
        let initial = fingers([(0.25, 0.3), (0.75, 0.7)])
        XCTAssertEqual(contacts.update(initial, modifierHeld: true), [])
        XCTAssertEqual(contacts.fingerCount, 2)
        XCTAssertEqual(contacts.update(fingers([(0.2, 0.25), (0.8, 0.75)]), modifierHeld: true), [])
        XCTAssertEqual(contacts.update(fingers([(0.22, 0.28), (0.82, 0.78)]), modifierHeld: true), [])
        XCTAssertFalse(contacts.claimed)
        XCTAssertEqual(contacts.update([], modifierHeld: true), [])
    }

    func testScrollResizeUsesPointDeltasOnBothAxesRegardlessOfNaturalScrollSetting() {
        for natural in [true, false] {
            let sign: CGFloat = natural ? 1 : -1
            var scroll = ScrollResize()
            let start = scroll.update(phase: .began, momentum: [], owner: .resize, motion: .zero)
            XCTAssertTrue(start.drop)
            XCTAssertEqual(start.events, [])
            for (i, (x, y)) in [(CGFloat(22), CGFloat(0)), (0, -13), (-8, 17)].enumerated() {
                let motion = ScrollResize.fingerMotion(x: sign * x, y: sign * y, natural: natural)
                let result = scroll.update(phase: .changed, momentum: [], owner: .resize, motion: motion)
                XCTAssertTrue(result.drop)
                let change = TrackpadGesture.resize(CGSize(width: x, height: y))
                XCTAssertEqual(result.events, i == 0 ? [.began, change] : [change])
            }
            XCTAssertEqual(scroll.update(phase: .ended, momentum: [], owner: .resize, motion: .zero).events, [.ended])
        }
    }

    func testReleaseStopsResizeAndDrainsOnlyThatScrollAndItsMomentum() {
        var scroll = ScrollResize()
        let delta = CGSize(width: 10, height: 5)
        _ = scroll.update(phase: .began, momentum: [], owner: .resize, motion: delta)
        XCTAssertEqual(scroll.release(), [.ended])
        XCTAssertEqual(scroll.release(), [])
        for phase in [NSEvent.Phase.changed, .ended] {
            let result = scroll.update(phase: phase, momentum: [], owner: .application, motion: delta)
            XCTAssertTrue(result.drop)
            XCTAssertEqual(result.events, [])
        }
        for momentum in [NSEvent.Phase.began, .changed, .ended] {
            let result = scroll.update(phase: [], momentum: momentum, owner: .application, motion: delta)
            XCTAssertTrue(result.drop)
            XCTAssertEqual(result.events, [])
        }
        let next = scroll.update(phase: .began, momentum: [], owner: .application, motion: delta)
        XCTAssertFalse(next.drop)
        XCTAssertEqual(next.events, [])
    }

    func testAppScrollingKeepsItsMomentumEvenIfCommandWasPressedMidGesture() {
        var scroll = ScrollResize()
        let delta = CGSize(width: 0, height: 20)
        _ = scroll.update(phase: .began, momentum: [], owner: .application, motion: delta)
        for phase in [NSEvent.Phase.changed, .ended] {
            let result = scroll.update(phase: phase, momentum: [], owner: .resize, motion: delta)
            XCTAssertFalse(result.drop)
            XCTAssertEqual(result.events, [])
        }
        XCTAssertFalse(scroll.update(phase: [], momentum: .began, owner: .resize, motion: delta).drop)
        XCTAssertFalse(scroll.update(phase: [], momentum: .ended, owner: .resize, motion: delta).drop)
    }

    func testMomentumBeforeTouchEndAndOldMomentumDuringANewGesture() {
        var scroll = ScrollResize()
        let delta = CGSize(width: -12, height: 3)
        _ = scroll.update(phase: .began, momentum: [], owner: .resize, motion: delta)
        let inertia = scroll.update(phase: [], momentum: .began, owner: .resize, motion: delta)
        XCTAssertTrue(inertia.drop)
        XCTAssertEqual(inertia.events, [.ended])
        XCTAssertEqual(scroll.update(phase: .ended, momentum: [], owner: .resize, motion: .zero).events, [])
        _ = scroll.update(phase: .began, momentum: [], owner: .resize, motion: delta)
        let oldEnd = scroll.update(phase: [], momentum: .ended, owner: .resize, motion: delta)
        XCTAssertTrue(oldEnd.drop)
        XCTAssertEqual(oldEnd.events, [])
        XCTAssertTrue(scroll.resizing)
        XCTAssertEqual(scroll.update(phase: .cancelled, momentum: [], owner: .resize, motion: .zero).events, [.cancelled])
    }

    func testScrollDuringThreeFingerSwipeIsConsumedWithoutResizing() {
        var scroll = ScrollResize()
        let delta = CGSize(width: 0, height: 10)
        let result = scroll.update(phase: .began, momentum: [], owner: .swipe, motion: delta)
        XCTAssertTrue(result.drop)
        XCTAssertEqual(result.events, [])
        XCTAssertTrue(scroll.update(phase: .ended, momentum: [], owner: .application, motion: .zero).drop)
    }

    func testNewAppMomentumPassesIfPreviousResizeMomentumWasInterrupted() {
        var scroll = ScrollResize()
        let delta = CGSize(width: 0, height: 10)
        _ = scroll.update(phase: .began, momentum: [], owner: .resize, motion: delta)
        _ = scroll.update(phase: .ended, momentum: [], owner: .resize, motion: .zero)
        XCTAssertTrue(scroll.update(phase: [], momentum: .began, owner: .resize, motion: delta).drop)
        _ = scroll.update(phase: .began, momentum: [], owner: .application, motion: delta)
        _ = scroll.update(phase: .ended, momentum: [], owner: .application, motion: .zero)
        XCTAssertFalse(scroll.update(phase: [], momentum: .began, owner: .application, motion: delta).drop)
    }

    func testThirdFingerStartsMoveAndStaggeredLiftNeverStartsPinch() {
        var gesture = ContactGesture()
        let initial = fingers([(0.25, 0.3), (0.5, 0.3), (0.75, 0.3)])
        XCTAssertEqual(gesture.update(Array(initial.prefix(2)), modifierHeld: true), [])
        XCTAssertEqual(gesture.update(initial, modifierHeld: true), [])
        let moved = fingers([(0.35, 0.5), (0.6, 0.5), (0.85, 0.5)])
        let events = gesture.update(moved, modifierHeld: true)
        XCTAssertEqual(events.first, .began)
        guard case .move(let size) = events.last else { return XCTFail("Expected a three-finger move") }
        XCTAssertEqual(size.width, 0.1, accuracy: 0.000001)
        XCTAssertEqual(size.height, -0.2, accuracy: 0.000001)
        XCTAssertEqual(gesture.update(Array(moved.prefix(2)), modifierHeld: true), [.ended])
        XCTAssertEqual(gesture.update(fingers([(0.1, 0.3), (0.9, 0.3)]), modifierHeld: true), [])
        XCTAssertEqual(gesture.update([], modifierHeld: true), [])
        XCTAssertTrue(gesture.idle)
    }

    func testAChordCannotStealAMacGestureInFlight() {
        var gesture = ContactGesture()
        _ = gesture.update(fingers([(0.3, 0.3), (0.7, 0.7)]), modifierHeld: false)
        XCTAssertEqual(gesture.update(fingers([(0.2, 0.2), (0.8, 0.8)]), modifierHeld: true), [])
        XCTAssertFalse(gesture.claimed)
        XCTAssertEqual(gesture.update([], modifierHeld: true), [])
        XCTAssertTrue(gesture.idle)
    }

    func testFourthFingerCancelsAndModifierReleaseCommitsOnce() {
        let start = fingers([(0.2, 0.4), (0.4, 0.4), (0.6, 0.4)])
        let moved = fingers([(0.3, 0.4), (0.5, 0.4), (0.7, 0.4)])
        var gesture = ContactGesture()
        _ = gesture.update(start, modifierHeld: true)
        _ = gesture.update(moved, modifierHeld: true)
        var copied = gesture
        XCTAssertEqual(copied.update(moved + [Finger(path: 9, position: .zero)], modifierHeld: true), [.cancelled])
        XCTAssertEqual(copied.update(moved, modifierHeld: true), [])
        XCTAssertEqual(gesture.releaseModifier(), [.ended])
        XCTAssertEqual(gesture.update(moved, modifierHeld: false), [])
        XCTAssertEqual(gesture.update([], modifierHeld: true), [])
    }
}
