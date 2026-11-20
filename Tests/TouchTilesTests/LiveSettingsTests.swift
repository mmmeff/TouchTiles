import AppKit
import XCTest
@testable import TouchTiles

extension LiveWindowTests {
    func testNativeFloatingSettingsStayReachableWhenAnotherAppTakesFocus() throws {
        try withFixture { _, mac, windows in
            let delegate = AppDelegate()
            delegate.showSettings()
            let settings = try XCTUnwrap(NSApp.windows.first { $0.title == "TouchTiles Settings" })
            defer { settings.close() }

            let tile = try XCTUnwrap(windows.first)
            let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let bounds = DesktopCoordinates(primaryTop: top).flip(settings.frame)
            mac.setFrame(bounds.insetBy(dx: -20, dy: -20), of: tile)
            XCTAssertTrue(try XCTUnwrap(mac.currentFrame(of: tile)).contains(bounds.center))
            mac.focus(tile)
            XCTAssertTrue(observe { mac.focusedID() == tile.id })

            XCTAssertTrue(observe {
                settings.isVisible
                    && NSWindow.windowNumber(at: settings.frame.center, belowWindowWithWindowNumber: 0)
                        == settings.windowNumber
            }, "The tile took focus and covered the settings controls.")
            XCTAssertEqual(mac.focusedID(), tile.id)
        }
    }
}
