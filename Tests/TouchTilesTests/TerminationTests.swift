import AppKit
import XCTest
@testable import TouchTiles

final class TerminationTests: XCTestCase {
    func testQuitImmediatelyWhenWindowsAreRestored() {
        let decision = AppDelegate.terminationReply(restorationPending: { false }) {
            XCTFail("Immediate termination does not need a deferred reply.")
        }
        XCTAssertEqual(decision, .terminateNow)
    }

    func testDeferredQuitRepliesInModalModeAfterRestoration() {
        var restoring = true
        var replied = false
        let decision = AppDelegate.terminationReply(restorationPending: { restoring }) {
            XCTAssertEqual(RunLoop.current.currentMode, .modalPanel)
            XCTAssertFalse(restoring)
            replied = true
        }
        XCTAssertEqual(decision, .terminateLater)

        RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.25))
        XCTAssertFalse(replied)
        restoring = false
        let deadline = Date().addingTimeInterval(2)
        while !replied, Date() < deadline {
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(replied, "AppKit keeps the process alive until it receives the quit reply.")
    }
}
