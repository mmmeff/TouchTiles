import AppKit
import ApplicationServices
import ScreenCaptureKit
import XCTest
@testable import TouchTiles

final class LiveWindowTests: XCTestCase {
    func observe(within seconds: TimeInterval = 2, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !predicate() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.025)))
        }
        return true
    }

    func withFixture(restoringPointer: Bool = false, _ verify: (Process, MacWindows, [ManagedWindow]) throws -> Void) throws {
        try withFixtures(windowCounts: [2], restoringPointer: restoringPointer) { processes, mac, initial in
            try verify(processes[0], mac, initial)
        }
    }

    private func withFixtures(windowCounts: [Int], allowsColorChanges: Bool = false, protectContents: Bool = false,
                              minimums: [CGSize] = [], widthIncrement: Int? = nil, refuseWidthBelow: Int? = nil,
                              restoringPointer: Bool = false, allowsNativeSurfaces: Bool = false,
                              _ verify: ([Process], MacWindows, [ManagedWindow]) throws -> Void) throws {
        guard let path = ProcessInfo.processInfo.environment["TOUCHTILES_WINDOW_FIXTURE"],
              AXIsProcessTrusted(), !NSScreen.screens.isEmpty else {
            throw XCTSkip("Run Integration/test-windows.sh from an Accessibility-authorized terminal in a macOS login session.")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        var fixtures: [Process] = []
        let originalPointer = restoringPointer ? CGEvent(source: nil)?.location : nil
        defer {
            for fixture in fixtures {
                if fixture.isRunning { fixture.terminate() }
                fixture.waitUntilExit()
            }
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }
        for count in windowCounts {
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: path)
            var environment = ProcessInfo.processInfo.environment
            environment["TOUCHTILES_FIXTURE_WINDOWS"] = String(count)
            if let widthIncrement { environment["TOUCHTILES_FIXTURE_WIDTH_INCREMENT"] = String(widthIncrement) }
            if let refuseWidthBelow { environment["TOUCHTILES_FIXTURE_REFUSE_WIDTH_BELOW"] = String(refuseWidthBelow) }
            if !minimums.isEmpty {
                environment["TOUCHTILES_FIXTURE_MINIMUMS"] = minimums.map {
                    "\(Int($0.width))x\(Int($0.height))"
                }.joined(separator: ";")
            }
            if protectContents { environment["TOUCHTILES_FIXTURE_PROTECTED"] = "1" }
            if allowsColorChanges {
                environment["TOUCHTILES_FIXTURE_COLORS"] = "1"
            }
            if allowsNativeSurfaces { environment["TOUCHTILES_FIXTURE_SURFACES"] = "1" }
            if allowsColorChanges || allowsNativeSurfaces { fixture.standardInput = Pipe() }
            fixture.environment = environment
            try fixture.run()
            fixtures.append(fixture)
        }
        let owners = Set(fixtures.map(\.processIdentifier))
        let mac = MacWindows(processFilter: owners)
        var initial: [ManagedWindow] = []
        let found = observe(within: 5) {
            initial = mac.inventory()
            return initial.count == windowCounts.reduce(0, +) && Set(initial.map(\.pid)) == owners
        }
        XCTAssertTrue(found)
        guard found else { return }
        try verify(fixtures, mac, initial)
    }

    private func close(_ window: ManagedWindow) throws {
        var closeButton: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString,
                                                     &closeButton), .success)
        let button = try XCTUnwrap(closeButton)
        guard CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return XCTFail("The fixture’s close button has no AX element")
        }
        XCTAssertEqual(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString), .success)
    }

    private func fixtureWindow(number: Int, in windows: [ManagedWindow]) throws -> ManagedWindow {
        try XCTUnwrap(windows.first { window in
            var title: CFTypeRef?
            return AXUIElementCopyAttributeValue(window.element, kAXTitleAttribute as CFString, &title) == .success
                && title as? String == "TouchTiles frame verification \(number)"
        })
    }

    private func primaryScreenSize() throws -> CGSize {
        guard let size = NSScreen.screens.first?.visibleFrame.size else {
            throw XCTSkip("Minimum-size tests need a macOS login session.")
        }
        return size
    }

    func testNativeFloatingPanelRemainsReachableWhenCrossingAnotherApp() throws {
        try checkNativeSurface("panel")
    }

    func testNativeFloatingSheetKeepsItsDocumentActiveAcrossAnotherApp() throws {
        try checkNativeSurface("sheet")
    }

    func testNativeFloatingSheetOnAnotherDocumentSurvivesCrossingToAnotherApp() throws {
        try checkNativeSurface("sheet", focusSibling: true)
    }

    func testNativeFloatingContextMenuStaysOpenAcrossAnotherApp() throws {
        try checkNativeSurface("menu")
    }

    private func checkNativeSurface(_ command: String, focusSibling: Bool = false) throws {
        let counts = [focusSibling ? 2 : 1, 1]
        try withFixtures(windowCounts: counts, restoringPointer: true, allowsNativeSurfaces: true) { apps, mac, windows in
            let owner = apps[0]
            let parent = try XCTUnwrap(windows.first { $0.pid == owner.processIdentifier })
            let other = try XCTUnwrap(windows.first { $0.pid != parent.pid })
            let input = try XCTUnwrap(owner.standardInput as? Pipe).fileHandleForWriting
            let manager = WindowManager(mac: mac)
            manager.start()
            defer { manager.stop() }
            let parentFrame = try XCTUnwrap(mac.currentFrame(of: parent))
            let otherFrame = try XCTUnwrap(mac.currentFrame(of: other))
            XCTAssertEqual(CGWarpMouseCursorPosition(otherFrame.center), .success)
            mac.focus(other)
            XCTAssertTrue(observe { mac.focusedID() == other.id })
            XCTAssertEqual(CGWarpMouseCursorPosition(parentFrame.center), .success)
            manager.hover(at: mac.pointer)
            mac.focus(parent)
            XCTAssertTrue(observe { mac.focusedID() == parent.id })

            // Read only the fixture owner's WindowServer records. Their bounds and numbers
            // establish whether the native surface remains on screen and receives input.
            func surfaces() -> [CGWindowID: CGRect] {
                let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] ?? []
                var visible: [CGWindowID: CGRect] = [:]
                for entry in info {
                    guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == parent.pid,
                          let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id != parent.id,
                          let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                          let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 100, frame.height >= 80
                    else { continue }
                    visible[id] = frame
                }
                return visible
            }
            let previous = Set(surfaces().keys)
            try input.write(contentsOf: Data("\(parent.id) \(command)\n".utf8))
            var surfaceID: CGWindowID?
            var center = CGPoint.zero
            let coordinates = DesktopCoordinates(primaryTop: try XCTUnwrap(NSScreen.screens.first).frame.maxY)
            func topWindow(at point: CGPoint) -> CGWindowID? {
                CGWindowID(exactly: NSWindow.windowNumber(at: coordinates.flip(point), belowWindowWithWindowNumber: 0))
            }
            guard observe({
                for (id, frame) in surfaces() where !previous.contains(id) && topWindow(at: frame.center) == id {
                    surfaceID = id
                    center = frame.center
                    return true
                }
                return false
            }), let surfaceID else {
                return XCTFail("AppKit did not present a hittable \(command). Fixture windows: \(surfaces())")
            }
            XCTAssertTrue(inFront(surfaceID, of: parent.id))
            if focusSibling {
                let sibling = try XCTUnwrap(windows.first { $0.pid == parent.pid && $0.id != parent.id })
                let frame = try XCTUnwrap(surfaces()[sibling.id])
                XCTAssertEqual(CGWarpMouseCursorPosition(frame.center), .success)
                try input.write(contentsOf: Data("\(sibling.id) focus\n".utf8))
                XCTAssertTrue(observe { mac.focusedID() == sibling.id },
                              "The fixture could not focus its other document while the sheet was open.")
                XCTAssertEqual(topWindow(at: center), surfaceID)
            }
            XCTAssertEqual(CGWarpMouseCursorPosition(otherFrame.center), .success)
            XCTAssertEqual(topWindow(at: mac.pointer), other.id)
            manager.hover(at: mac.pointer)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, parent.pid,
                           "Crossing a tile deactivated the owner of the open \(command).")
            XCTAssertEqual(topWindow(at: center), surfaceID, "Crossing the other tile buried or dismissed the \(command).")
            try input.write(contentsOf: Data("\(parent.id) dismiss\n".utf8))
            XCTAssertTrue(observe { surfaces()[surfaceID] == nil })
            XCTAssertTrue(observe { mac.focusedID() == other.id },
                          "Hover focus should resume at the waiting pointer when the \(command) closes.")
        }
    }

    func testMinimumOfOneWindowStopsItsWholeColumnOrRow() throws {
        let size = try primaryScreenSize()
        let minimum = CGSize(width: floor(size.width * 0.35), height: floor(size.height * 0.35))
        let small = CGSize(width: 100, height: 80)
        try withFixtures(windowCounts: [4], minimums: [minimum, small, small, small], restoringPointer: true) { _, mac, windows in
            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 2, columns: 2))
            manager.start()
            defer { manager.stop() }
            let constrained = try self.fixtureWindow(number: 1, in: windows)
            let original = try XCTUnwrap(mac.currentFrame(of: constrained))
            let horizontal = size.width > size.height
            func origin(_ frame: CGRect) -> CGFloat { horizontal ? frame.minX : frame.minY }
            func length(_ frame: CGRect) -> CGFloat { horizontal ? frame.width : frame.height }
            let peers = windows.filter { $0.id != constrained.id }
            let handle = try XCTUnwrap(peers.first {
                mac.currentFrame(of: $0).map { origin($0) == origin(original) } == true
            })
            let neighbor = try XCTUnwrap(peers.first {
                mac.currentFrame(of: $0).map { origin($0) != origin(original) } == true
            })
            let other = try XCTUnwrap(mac.currentFrame(of: neighbor))
            let leading = origin(original) < origin(other)
            let floorLength = horizontal ? minimum.width : minimum.height
            func moveDivider(by growth: CGFloat) {
                let shift = leading ? growth : -growth
                manager.handle(.resize(horizontal ? CGSize(width: shift, height: 0) : CGSize(width: 0, height: shift)))
            }
            func resize(by growth: CGFloat) throws {
                let frame = try XCTUnwrap(mac.currentFrame(of: handle))
                let grip = horizontal
                    ? CGPoint(x: leading ? frame.maxX - 12 : frame.minX + 12, y: frame.midY)
                    : CGPoint(x: frame.midX, y: leading ? frame.maxY - 12 : frame.minY + 12)
                mac.focus(handle)
                XCTAssertTrue(observe { mac.window(at: grip, among: windows)?.id == handle.id })
                manager.beginGesture(at: grip)
                moveDivider(by: growth)
            }
            try resize(by: -length(original))
            let pinned = observe {
                guard let first = mac.currentFrame(of: constrained), let second = mac.currentFrame(of: handle),
                      let far = mac.currentFrame(of: neighbor) else { return false }
                let gap = leading ? origin(far) - origin(first) - length(first)
                                  : origin(first) - origin(far) - length(far)
                return abs(length(first) - floorLength) <= 1 && abs(length(second) - floorLength) <= 1
                    && origin(first) == origin(second) && abs(gap - 10) <= 1
            }
            let atLimit = try XCTUnwrap(mac.currentFrame(of: constrained))
            let peerAtLimit = try XCTUnwrap(mac.currentFrame(of: handle))
            let adjacent = try XCTUnwrap(mac.currentFrame(of: neighbor))
            print("Shared minimum \(minimum), start \(original), constrained \(atLimit), sibling \(peerAtLimit), adjacent \(adjacent)")
            XCTAssertTrue(pinned, "The shared divider must stop at the stricter sibling’s minimum and keep the gap.")
            XCTAssertEqual(horizontal ? atLimit.height : atLimit.width, horizontal ? original.height : original.width)
            moveDivider(by: 30)
            XCTAssertTrue(observe {
                mac.currentFrame(of: handle).map { abs(length($0) - floorLength - 30) <= 1 } == true
            }, "Reversing direction in the same gesture must move the divider immediately.")
            print("Same gesture reversed 30 points to \(String(describing: mac.currentFrame(of: handle)))")
            manager.handle(.ended)
            try resize(by: 64)
            XCTAssertTrue(observe { mac.currentFrame(of: constrained).map { abs(length($0) - floorLength - 94) <= 1 } == true })
            manager.handle(.ended)
            try close(constrained)
            XCTAssertTrue(observe { mac.inventory().count == 3 })
            manager.spaceChanged()
            XCTAssertTrue(observe {
                mac.currentFrame(of: handle).map { horizontal ? $0.height > original.height + 10 : $0.width > original.width + 10 } == true
            })
            try resize(by: -128)
            XCTAssertTrue(observe { mac.currentFrame(of: handle).map { length($0) < floorLength - 20 } == true },
                          "Closing the constrained sibling must release its minimum.")
            manager.handle(.ended)
        }
    }

    func testMinimumHeightStopsAnAdjacentRow() throws {
        let size = try primaryScreenSize()
        let minimum = CGSize(width: 120, height: floor(size.height * 0.37))
        try withFixtures(windowCounts: [2], minimums: [minimum, CGSize(width: 100, height: 80)], restoringPointer: true) { _, mac, windows in
            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 2, columns: 1))
            manager.start()
            defer { manager.stop() }
            let constrained = try self.fixtureWindow(number: 1, in: windows)
            let handle = try self.fixtureWindow(number: 2, in: windows)
            let original = try XCTUnwrap(mac.currentFrame(of: constrained))
            let other = try XCTUnwrap(mac.currentFrame(of: handle))
            let above = other.midY < original.midY
            let grip = CGPoint(x: other.midX, y: above ? other.maxY - 12 : other.minY + 12)
            mac.focus(handle)
            XCTAssertTrue(observe { mac.window(at: grip, among: windows)?.id == handle.id })
            manager.beginGesture(at: grip)
            manager.handle(.resize(CGSize(width: 0, height: above ? original.height : -original.height)))
            let pinned = observe {
                guard let first = mac.currentFrame(of: constrained), let second = mac.currentFrame(of: handle) else { return false }
                let gap = above ? first.minY - second.maxY : second.minY - first.maxY
                return abs(first.height - minimum.height) <= 1 && abs(gap - 10) <= 1
            }
            let accepted = try XCTUnwrap(mac.currentFrame(of: constrained))
            let adjacent = try XCTUnwrap(mac.currentFrame(of: handle))
            print("Row minimum \(minimum.height), start \(original), constrained \(accepted), adjacent \(adjacent)")
            XCTAssertTrue(pinned)
            XCTAssertEqual(accepted.width, original.width)
            manager.handle(.ended)
        }
    }

    func testMinimumOverflowReturnsToTilingAfterClose() throws {
        let size = try primaryScreenSize()
        let minima = [CGSize(width: floor(size.width * 0.56), height: 120),
                      CGSize(width: floor(size.width * 0.58), height: 160)]
        try withFixtures(windowCounts: [2], minimums: minima) { _, mac, windows in
            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 1, columns: 2))
            manager.start()
            defer { manager.stop() }
            let display = try XCTUnwrap(DesktopLayout.screen(containing: windows[0].frame, in: mac.displays))
            let soleTile = display.visibleFrame.insetBy(dx: 10, dy: 10)
            func fillsDisplay(_ window: ManagedWindow) -> Bool {
                mac.currentFrame(of: window)?.approximatelyEquals(soleTile) == true
            }
            guard observe({ windows.contains(where: fillsDisplay) }),
                  let resident = windows.first(where: fillsDisplay) else {
                let accepted = windows.compactMap { mac.currentFrame(of: $0) }
                return XCTFail("No admitted full-width tile for minima \(minima), actual frames \(accepted).")
            }
            let waiting = try XCTUnwrap(windows.first { $0.id != resident.id })
            XCTAssertTrue(observe { mac.currentFrame(of: waiting)?.approximatelyEquals(waiting.frame) == true })
            try close(resident)
            XCTAssertTrue(observe(within: 4) { fillsDisplay(waiting) })
            print("Overflow waiter restored at \(waiting.frame), readmitted at \(String(describing: mac.currentFrame(of: waiting)))")
        }
    }

    func testMinimumLearningAllowsFurtherResizesInTextColumnIncrements() throws {
        let increment = 12
        try withFixtures(windowCounts: [2], widthIncrement: increment, restoringPointer: true) { _, mac, windows in
            let terminal = try self.fixtureWindow(number: 1, in: windows)
            let neighbor = try self.fixtureWindow(number: 2, in: windows)
            var request = terminal.frame
            request.size.width = 281
            mac.setFrame(request, of: terminal)
            XCTAssertTrue(observe { mac.currentFrame(of: terminal)?.width == 288 },
                          "The fixture must round AX widths up to a complete text column.")
            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 1, columns: 2))
            manager.start()
            defer { manager.stop() }
            let start = try XCTUnwrap(mac.currentFrame(of: terminal))
            let other = try XCTUnwrap(mac.currentFrame(of: neighbor))
            let left = start.midX < other.midX
            let grip = CGPoint(x: left ? start.maxX - 18 : start.minX + 18, y: start.midY)
            mac.focus(terminal)
            XCTAssertTrue(observe { mac.window(at: grip, among: windows)?.id == terminal.id })
            manager.beginGesture(at: grip)
            var widths = [start.width]
            for _ in 0..<4 {
                manager.handle(.resize(CGSize(width: left ? -37 : 37, height: 0)))
                // Let the asynchronous readback settle before issuing another
                // event. Intermediate probes can be smaller than the final tile.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
                let frame = try XCTUnwrap(mac.currentFrame(of: terminal))
                XCTAssertEqual(frame.width.truncatingRemainder(dividingBy: CGFloat(increment)), 0)
                XCTAssertLessThan(frame.width, try XCTUnwrap(widths.last),
                                  "Snapping a width up to a text column must not pin the divider there.")
                widths.append(frame.width)
            }
            manager.handle(.ended)
            print("Accepted widths for 12-point columns in one continuous resize: \(widths)")
        }
    }

    func testMinimumWhenAppSilentlyRejectsAnUndersizedRequest() throws {
        let floor = Int(try primaryScreenSize().width * 0.32)
        try withFixtures(windowCounts: [2], refuseWidthBelow: floor, restoringPointer: true) { _, mac, windows in
            let constrained = try self.fixtureWindow(number: 1, in: windows)
            let neighbor = try self.fixtureWindow(number: 2, in: windows)
            var undersized = CGSize(width: floor / 2, height: Int(constrained.frame.height))
            let value = try XCTUnwrap(AXValueCreate(.cgSize, &undersized))
            XCTAssertEqual(AXUIElementSetAttributeValue(constrained.element, kAXSizeAttribute as CFString, value), .success)
            XCTAssertEqual(mac.currentFrame(of: constrained)?.width, constrained.frame.width)

            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 1, columns: 2))
            manager.start()
            defer { manager.stop() }
            let start = try XCTUnwrap(mac.currentFrame(of: constrained))
            let other = try XCTUnwrap(mac.currentFrame(of: neighbor))
            XCTAssertGreaterThan(start.width, CGFloat(floor + 20))
            let left = start.midX < other.midX
            let grip = CGPoint(x: left ? start.maxX - 12 : start.minX + 12, y: start.midY)
            mac.focus(constrained)
            XCTAssertTrue(observe { mac.window(at: grip, among: windows)?.id == constrained.id })
            manager.beginGesture(at: grip)
            manager.handle(.resize(CGSize(width: left ? -start.width : start.width, height: 0)))
            XCTAssertTrue(observe {
                guard let frame = mac.currentFrame(of: constrained), let adjacent = mac.currentFrame(of: neighbor) else { return false }
                let gap = left ? adjacent.minX - frame.maxX : frame.minX - adjacent.maxX
                return abs(frame.width - CGFloat(floor)) <= 1 && abs(gap - 10) <= 1
            }, "A successful AX write that preserves the old width must not turn that old width into the floor.")
            print("Silent rejection from \(start.width) for a \(floor)-point minimum settled at \(String(describing: mac.currentFrame(of: constrained))) beside \(String(describing: mac.currentFrame(of: neighbor)))")
            manager.handle(.ended)
        }
    }

    private func point(in frame: CGRect, at fraction: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + fraction.x * frame.width, y: frame.minY + fraction.y * frame.height)
    }

    private func fraction(of point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    private func assertCursor(near expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        let matched = observe(within: 0.35) {
            guard let actual = CGEvent(source: nil)?.location else { return false }
            return abs(actual.x - expected.x) <= 1 && abs(actual.y - expected.y) <= 1
        }
        XCTAssertTrue(matched, "Expected pointer at \(expected), observed \(String(describing: CGEvent(source: nil)?.location))",
                      file: file, line: line)
    }

    func testResizeCursorFollowsTileThroughMinimumSettlementAndRelease() throws {
        try checkTiledResizeCursor(moveBeforeSettlement: false)
    }

    func testResizeCursorReleasesImmediatelyWhenUserMovesToAnotherWindow() throws {
        try checkTiledResizeCursor(moveBeforeSettlement: true)
    }

    private func checkTiledResizeCursor(moveBeforeSettlement: Bool) throws {
        let minimumWidth = floor(try primaryScreenSize().width * 0.3)
        let minima = [CGSize(width: minimumWidth, height: 100), CGSize(width: 100, height: 100)]
        try withFixtures(windowCounts: [2], minimums: minima, restoringPointer: true) { _, mac, windows in
            let neighbor = try self.fixtureWindow(number: 1, in: windows)
            let tile = try self.fixtureWindow(number: 2, in: windows)
            let manager = WindowManager(mac: mac)
            manager.setLimits(TileLimits(rows: 1, columns: 2))
            manager.start()
            defer { manager.stop() }
            let original = try XCTUnwrap(mac.currentFrame(of: tile))
            let leading = original.midX < (try XCTUnwrap(mac.currentFrame(of: neighbor))).midX
            let start = point(in: original, at: CGPoint(x: leading ? 0.78 : 0.22, y: 0.36))
            XCTAssertEqual(CGWarpMouseCursorPosition(start), .success)
            let grip = fraction(of: mac.pointer, in: original)
            mac.focus(tile)
            XCTAssertTrue(observe { NSWorkspace.shared.frontmostApplication?.processIdentifier == tile.pid
                && mac.focusedID() == tile.id && mac.window(at: mac.pointer, among: windows)?.id == tile.id })
            manager.handle(.began)
            manager.handle(.resize(CGSize(width: leading ? 24 : -24, height: 0)))
            let first = try XCTUnwrap(mac.currentFrame(of: tile))
            XCTAssertEqual(first.width, original.width + 24, accuracy: 1)
            assertCursor(near: point(in: first, at: grip))
            manager.handle(.resize(CGSize(width: leading ? first.width : -first.width, height: 0)))
            manager.handle(.ended)
            let display = try XCTUnwrap(DesktopLayout.screen(containing: original, in: mac.displays))
            let next = CGPoint(x: leading ? display.visibleFrame.maxX - 30 : display.visibleFrame.minX + 30,
                               y: original.midY)
            var releaseGrip = grip
            if moveBeforeSettlement {
                XCTAssertEqual(CGWarpMouseCursorPosition(next), .success)
            } else {
                let atRelease = try XCTUnwrap(mac.currentFrame(of: tile))
                releaseGrip = fraction(of: mac.pointer, in: atRelease)
                // A new contact can arrive before WindowServer reports the new
                // tile boundaries. The resize still belongs to this window.
                manager.handle(.began)
                manager.handle(.resize(CGSize(width: leading ? -24 : 24, height: 0)))
                let retreat = try XCTUnwrap(mac.currentFrame(of: tile))
                XCTAssertLessThanOrEqual(retreat.width, atRelease.width - 23, "The second gesture must move the divider")
                XCTAssertEqual(mac.focusedID(), tile.id, "An immediate regrip picked up a different window")
                manager.handle(.resize(CGSize(width: leading ? 24 : -24, height: 0)))
                manager.handle(.ended)
            }
            XCTAssertTrue(observe {
                guard let accepted = mac.currentFrame(of: neighbor), let final = mac.currentFrame(of: tile) else { return false }
                let gap = leading ? accepted.minX - final.maxX : final.minX - accepted.maxX
                return display.visibleFrame.contains(accepted) && display.visibleFrame.contains(final)
                    && abs(accepted.width - minimumWidth) <= 1 && abs(gap - 10) <= 1
            })
            let settled = try XCTUnwrap(mac.currentFrame(of: tile))
            if !moveBeforeSettlement {
                assertCursor(near: point(in: settled, at: releaseGrip))
                XCTAssertTrue(observe { mac.window(at: mac.pointer, among: windows)?.id == tile.id })
                XCTAssertEqual(mac.focusedID(), tile.id)
                print("Tiled cursor from \(start) to \(mac.pointer) in settled frame \(settled)")
                XCTAssertEqual(CGWarpMouseCursorPosition(next), .success)
            }
            XCTAssertTrue(observe { mac.focusedID() == neighbor.id })
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            assertCursor(near: next)
        }
    }

    func testResizeCursorKeepsFloatingCornerAcrossGesturesAndCancellation() throws {
        let minimum = CGSize(width: 240, height: 180)
        try withFixtures(windowCounts: [2], minimums: [minimum], restoringPointer: true) { _, mac, windows in
            let window = try self.fixtureWindow(number: 1, in: windows)
            let manager = WindowManager(mac: mac)
            manager.start()
            defer { manager.stop() }
            mac.focus(window)
            XCTAssertTrue(observe { mac.focusedID() == window.id })
            manager.perform(.float)
            let ownDisplay = try XCTUnwrap(DesktopLayout.screen(containing: window.frame, in: mac.displays))
            let bounds = (mac.displays.first { $0.id != ownDisplay.id } ?? ownDisplay).visibleFrame
            let width = min(600, bounds.width * 0.7), height = min(440, bounds.height * 0.7)
            let desired = CGRect(x: (bounds.midX - width / 2).rounded(), y: (bounds.midY - height / 2).rounded(),
                                 width: width.rounded(), height: height.rounded())
            mac.setFrame(desired, of: window)
            let original = try XCTUnwrap(mac.currentFrame(of: window))
            XCTAssertTrue(bounds.contains(original))
            let start = point(in: original, at: CGPoint(x: 0.28, y: 0.24))
            XCTAssertEqual(CGWarpMouseCursorPosition(start), .success)
            let grip = fraction(of: mac.pointer, in: original)
            mac.focus(window)
            XCTAssertTrue(observe { NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                && mac.window(at: mac.pointer, among: windows)?.id == window.id })
            manager.handle(.began)
            manager.handle(.resize(CGSize(width: original.width - minimum.width + 50,
                                          height: original.height - minimum.height + 40)))
            let small = try XCTUnwrap(mac.currentFrame(of: window))
            XCTAssertEqual(small.size, minimum)
            XCTAssertFalse(small.contains(start), "The old pointer must lie outside the shrunken window")
            assertCursor(near: point(in: small, at: grip))
            manager.handle(.ended)
            let released = mac.pointer
            guard mac.window(at: released, among: windows)?.id == window.id else {
                return XCTFail("A second gesture at \(released) would miss the resized window at \(small)")
            }
            let nextGrip = fraction(of: released, in: small)
            manager.handle(.began)
            manager.handle(.resize(CGSize(width: -54, height: -42)))
            let grown = try XCTUnwrap(mac.currentFrame(of: window))
            XCTAssertEqual(grown, CGRect(x: small.minX - 54, y: small.minY - 42,
                                         width: small.width + 54, height: small.height + 42))
            let secondPoint = mac.pointer
            assertCursor(near: point(in: grown, at: nextGrip))
            manager.handle(.cancelled)
            XCTAssertEqual(mac.currentFrame(of: window), small)
            assertCursor(near: released)
            print("Floating cursor from \(start) to \(released), second resize to \(secondPoint), cancelled to \(mac.pointer)")

            manager.handle(.began)
            manager.handle(.move(CGSize(width: 18, height: 12)))
            let moved = try XCTUnwrap(mac.currentFrame(of: window))
            XCTAssertEqual(moved, small.offsetBy(dx: 18, dy: 12))
            let carriedGrip = point(in: moved, at: nextGrip)
            assertCursor(near: carriedGrip)
            manager.handle(.ended)
            assertCursor(near: carriedGrip)

            manager.handle(.began)
            manager.handle(.move(CGSize(width: -10, height: 14)))
            let secondMove = try XCTUnwrap(mac.currentFrame(of: window))
            XCTAssertEqual(secondMove, moved.offsetBy(dx: -10, dy: 14))
            assertCursor(near: point(in: secondMove, at: nextGrip))
            manager.handle(.cancelled)
            XCTAssertEqual(mac.currentFrame(of: window), moved)
            assertCursor(near: carriedGrip)
        }
    }

    func testExpandedTileRestoresToItsLargerSlotAfterNeighborCloses() throws {
        try withFixture { _, mac, initial in
            let expanding = initial[0]
            let closing = initial[1]
            let display = try XCTUnwrap(DesktopLayout.screen(containing: expanding.frame, in: mac.displays))
            let soleTile = display.visibleFrame.insetBy(dx: 10, dy: 10)
            let manager = WindowManager(mac: mac)
            manager.start()
            defer { manager.stop() }
            let originalTile = try XCTUnwrap(mac.currentFrame(of: expanding))
            XCTAssertFalse(originalTile.approximatelyEquals(soleTile))
            mac.focus(expanding)
            XCTAssertTrue(observe { mac.focusedID() == expanding.id })
            manager.perform(.fullscreen)
            let expanded = try XCTUnwrap(mac.currentFrame(of: expanding))
            XCTAssertGreaterThan(expanded.width * expanded.height, originalTile.width * originalTile.height)
            try close(closing)
            XCTAssertTrue(observe { mac.inventory().map(\.id) == [expanding.id] })
            manager.spaceChanged()
            XCTAssertTrue(observe(within: 4) { mac.currentFrame(of: expanding) == expanded })
            mac.focus(expanding)
            manager.perform(.fullscreen)
            XCTAssertTrue(observe { mac.currentFrame(of: expanding)?.approximatelyEquals(soleTile) == true })
            XCTAssertFalse(mac.isNativeFullscreen(expanding))
        }
    }

    func testWindowLifecycle() throws {
        try withFixture(restoringPointer: true, checkWindowLifecycle)
    }

    func testDraggedTileKeepsItsGripAndNeighborsSlide() throws {
        try withFixture(restoringPointer: true) { _, mac, windows in
            let carried = windows[0]
            let neighbor = windows[1]
            let manager = WindowManager(mac: mac)
            manager.start()
            defer { manager.stop() }
            // Grow the pickup tile so the drop changes both its origin and its size.
            let initial = try XCTUnwrap(mac.currentFrame(of: carried))
            let adjacent = try XCTUnwrap(mac.currentFrame(of: neighbor))
            let horizontal = abs(adjacent.midX - initial.midX) > abs(adjacent.midY - initial.midY)
            let resizePoint = point(in: initial, at: CGPoint(x: initial.midX < adjacent.midX ? 0.75 : 0.25,
                                                             y: initial.midY < adjacent.midY ? 0.75 : 0.25))
            XCTAssertEqual(CGWarpMouseCursorPosition(resizePoint), .success)
            mac.focus(carried)
            XCTAssertTrue(observe { mac.window(at: mac.pointer, among: windows)?.id == carried.id })
            manager.handle(.began)
            manager.handle(.resize(horizontal
                ? CGSize(width: adjacent.midX > initial.midX ? 48 : -48, height: 0)
                : CGSize(width: 0, height: adjacent.midY > initial.midY ? 48 : -48)))
            manager.handle(.ended)
            let start = try XCTUnwrap(mac.currentFrame(of: carried))
            XCTAssertNotEqual(start.size, initial.size)
            let other = try XCTUnwrap(mac.currentFrame(of: neighbor))
            let display = try XCTUnwrap(DesktopLayout.screen(containing: start, in: mac.displays))
            let wholeTile = display.visibleFrame.insetBy(dx: 10, dy: 10)
            XCTAssertEqual(CGWarpMouseCursorPosition(point(in: start, at: CGPoint(x: 0.35, y: 0.45))), .success)
            let grip = mac.pointer
            let heldFraction = fraction(of: grip, in: start)
            let firstDelta = horizontal
                ? CGSize(width: other.midX > start.midX ? 24 : -24, height: 0)
                : CGSize(width: 0, height: other.midY > start.midY ? 24 : -24)
            mac.focus(carried)
            XCTAssertTrue(observe { mac.window(at: grip, among: windows)?.id == carried.id })
            manager.handle(.began)
            manager.handle(.move(firstDelta))
            let atPickup = try XCTUnwrap(mac.currentFrame(of: carried))
            XCTAssertEqual(atPickup.size, start.size, "Carried window changed size at pickup")
            XCTAssertEqual(atPickup.origin, start.offsetBy(dx: firstDelta.width, dy: firstDelta.height).origin,
                           "Pickup changed the pointer's grip within the window")

            func checkMotion(from origin: CGRect, until settled: (CGRect) -> Bool) throws {
                var frames = [CGRect]()
                let reached = observe {
                    guard let frame = mac.currentFrame(of: neighbor) else { return false }
                    if settled(frame) { return true }
                    if frame != origin, frames.last != frame { frames.append(frame) }
                    return false
                }
                XCTAssertTrue(reached, "Neighbor failed to reach its preview frame from \(origin)")
                print("Drag reflow from \(origin) sampled \(frames.count) intermediate frames.")
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertGreaterThanOrEqual(frames.count, 2, "Neighbor jumped directly to its preview frame")
                }
            }
            try checkMotion(from: other) { $0.approximatelyEquals(wholeTile) }
            assertCursor(near: point(in: atPickup, at: heldFraction))
            let destination = other.center
            let offset = CGSize(width: destination.x - grip.x, height: destination.y - grip.y)
            manager.handle(.move(CGSize(width: offset.width - firstDelta.width, height: offset.height - firstDelta.height)))
            let crossing = try XCTUnwrap(mac.currentFrame(of: carried))
            XCTAssertEqual(crossing.size, start.size, "Carried window resized while crossing a neighbor")
            // The detached tree has a single leaf. Inserting at the neighbor's center
            // gives it the opposite half of the display.
            var landing = DesktopLayout()
            landing.reconcile([WindowPosition(id: neighbor.id, frame: wholeTile)], on: [display], focused: nil, pointer: grip)
            XCTAssertTrue(landing.attachDragged(carried.id, at: destination, on: display))
            let targets = landing.frames(on: display)
            let neighborTarget = try XCTUnwrap(targets[neighbor.id])
            let carriedTarget = try XCTUnwrap(targets[carried.id])
            try checkMotion(from: wholeTile) { $0.approximatelyEquals(neighborTarget) }
            assertCursor(near: point(in: crossing, at: heldFraction))
            XCTAssertNotEqual(carriedTarget.size, start.size, "The drop must exercise a change in tile size")
            // Rapidly reverse, then release back over the same destination
            // before that reversal has time to finish.
            manager.handle(.move(CGSize(width: firstDelta.width - offset.width, height: firstDelta.height - offset.height)))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.055))
            manager.handle(.move(CGSize(width: offset.width - firstDelta.width, height: offset.height - firstDelta.height)))
            XCTAssertEqual(mac.currentFrame(of: carried)?.size, start.size)
            manager.handle(.ended)
            XCTAssertTrue(observe {
                mac.currentFrame(of: carried)?.approximatelyEquals(carriedTarget) == true
                    && mac.currentFrame(of: neighbor)?.approximatelyEquals(neighborTarget) == true
            })
            let landed = try XCTUnwrap(mac.currentFrame(of: carried))
            assertCursor(near: point(in: landed, at: heldFraction))
            XCTAssertEqual(CGWarpMouseCursorPosition(neighborTarget.center), .success)
            XCTAssertTrue(observe { mac.focusedID() == neighbor.id })
            assertCursor(near: neighborTarget.center)
            XCTAssertTrue(mac.currentFrame(of: neighbor)?.approximatelyEquals(neighborTarget) == true)
        }
    }

    private func inFront(_ front: CGWindowID, of back: CGWindowID) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ids = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        guard let frontIndex = ids.firstIndex(of: front), let backIndex = ids.firstIndex(of: back) else { return false }
        return frontIndex < backIndex
    }

    private func preview(of source: CGWindowID) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == FloatingPreviews.panelTitle(for: source) }
    }

    private func awaitCapture<T>(_ start: (@escaping (T?, Error?) -> Void) -> Void) throws -> T {
        var outcome: Result<T, Error>?
        start { value, error in
            DispatchQueue.main.async {
                if let value { outcome = .success(value) }
                else if let error { outcome = .failure(error) }
            }
        }
        guard observe(within: 5, { outcome != nil }) else {
            throw NSError(domain: "TouchTilesWindowTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Window capture timed out"])
        }
        return try XCTUnwrap(outcome).get()
    }

    @available(macOS 14, *)
    private func captureFilter(for id: CGWindowID, owner: pid_t) throws -> SCContentFilter {
        let deadline = Date(timeIntervalSinceNow: 4)
        repeat {
            let content: SCShareableContent = try awaitCapture {
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false, completionHandler: $0)
            }
            if let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == owner }) {
                return SCContentFilter(desktopIndependentWindow: window)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
        } while Date() < deadline
        throw NSError(domain: "TouchTilesWindowTest", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Window capture could not find fixture or preview \(id), owner \(owner)"
        ])
    }

    @available(macOS 14, *)
    private func panelPixels(_ filter: SCContentFilter) throws -> NSBitmapImageRep {
        let config = SCStreamConfiguration()
        config.width = 96
        config.height = max(1, Int((96 * filter.contentRect.height / filter.contentRect.width).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        let image: CGImage = try awaitCapture {
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config, completionHandler: $0)
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private func color(_ image: NSBitmapImageRep, x: Double, y: Double) -> NSColor? {
        image.colorAt(x: Int(x * Double(image.pixelsWide)),
                      y: Int(y * Double(image.pixelsHigh)))?.usingColorSpace(.sRGB)
    }

    private func matches(_ observed: NSColor, _ reference: NSColor) -> Bool {
        // The system color-manages the window once at capture and again when
        // compositing the preview. Compare against the actual fixture's sample.
        abs(observed.redComponent - reference.redComponent) < 0.19
            && abs(observed.greenComponent - reference.greenComponent) < 0.19
            && abs(observed.blueComponent - reference.blueComponent) < 0.19
            && abs(observed.alphaComponent - reference.alphaComponent) < 0.1
    }

    private func quadrantPixels(_ image: NSBitmapImageRep) -> String {
        [0.35, 0.75].flatMap { y in
            [0.25, 0.75].map { x in
                guard let rgba = color(image, x: x, y: y) else { return "nil" }
                return String(describing: [rgba.redComponent, rgba.greenComponent, rgba.blueComponent, rgba.alphaComponent]
                    .map { Int(($0 * 255).rounded()) })
            }
        }.joined(separator: ", ")
    }

    @available(macOS 14, *)
    private func describePixels(panel: NSWindow, screenshot: NSBitmapImageRep, source: ManagedWindow) throws -> String {
        let original = try panelPixels(captureFilter(for: source.id, owner: source.pid))
        let contents = panel.contentView?.layer?.contents.map { String(describing: type(of: $0)) } ?? "nil"
        return "Source RGBA \(quadrantPixels(original)), preview RGBA \(quadrantPixels(screenshot)), panel frame \(panel.frame), crop \(String(describing: panel.contentView?.layer?.contentsRect)), layer content \(contents)"
    }

    @available(macOS 14, *)
    private func liveColorMismatch(source: ManagedWindow, owner: Process, panel: NSWindow) throws -> String? {
        let filter = try captureFilter(for: CGWindowID(panel.windowNumber), owner: getpid())
        let originalFilter = try captureFilter(for: source.id, owner: source.pid)
        let input = try XCTUnwrap(owner.standardInput as? Pipe)
        for changing in ["blue", "red"] {
            try input.fileHandleForWriting.write(contentsOf: Data("\(source.id) \(changing)\n".utf8))
            var matched = false
            let deadline = Date(timeIntervalSinceNow: 5)
            repeat {
                let pixels = try panelPixels(filter)
                let original = try panelPixels(originalFilter)
                let originalUpper = try XCTUnwrap(color(original, x: 0.25, y: 0.35))
                let originalLower = try XCTUnwrap(color(original, x: 0.25, y: 0.75))
                let upper = try XCTUnwrap(color(pixels, x: 0.25, y: 0.35))
                let lower = try XCTUnwrap(color(pixels, x: 0.25, y: 0.75))
                let changed = changing == "blue" ? originalUpper.blueComponent - originalUpper.redComponent > 0.25
                                                : originalUpper.redComponent - originalUpper.blueComponent > 0.25
                matched = changed && originalLower.greenComponent - originalLower.blueComponent > 0.25
                    && matches(upper, originalUpper) && matches(lower, originalLower)
                if !matched { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08)) }
            } while !matched && Date() < deadline
            if !matched {
                let diagnostics = try describePixels(panel: panel, screenshot: panelPixels(filter), source: source)
                return "Preview did not show \(changing) and green. \(diagnostics)"
            }
        }
        return nil
    }

    func testFloatingPreviewsRequireOptIn() throws {
        try withFixture(restoringPointer: true) { _, mac, windows in
            let manager = WindowManager(mac: mac)
            manager.start()
            defer { manager.stop() }
            try focusUnderPointer(windows[0], using: mac, among: windows)
            manager.perform(.float)
            let floating = try XCTUnwrap(mac.currentFrame(of: windows[0]))
            let tiled = try XCTUnwrap(mac.currentFrame(of: windows[1]))
            try focusUnderPointer(windows[1], at: exposedPoint(in: tiled, outside: floating), using: mac, among: windows)
            XCTAssertTrue(observe { self.inFront(windows[1].id, of: windows[0].id) })
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
            XCTAssertNil(preview(of: windows[0].id))
            if !CGPreflightScreenCaptureAccess() {
                manager.setFloatingPreviewsEnabled(true)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
                XCTAssertNil(preview(of: windows[0].id))
            }
        }
    }

    private func focusUnderPointer(_ window: ManagedWindow, at point: CGPoint? = nil,
                                   using mac: MacWindows, among windows: [ManagedWindow]) throws {
        let position = try point ?? XCTUnwrap(mac.currentFrame(of: window)).center
        XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
        mac.focus(window)
        XCTAssertTrue(observe {
            mac.focusedID() == window.id && mac.window(at: mac.pointer, among: windows)?.id == window.id
        }, "Expected the pointer and keyboard focus on fixture window \(window.id) at \(position).")
    }

    private func exposedPoint(in tile: CGRect, outside floating: CGRect) throws -> CGPoint {
        let areas = subtract(floating, from: tile)
        return try XCTUnwrap(areas.max { $0.width * $0.height < $1.width * $1.height }).center
    }

    func testFloatingPreviewPreservesWindowSharingProtection() throws {
        try withFixtures(windowCounts: [2], protectContents: true, restoringPointer: true) { _, mac, windows in
            let source = windows[0]
            let tile = windows[1]
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, source.id) as? [[String: Any]]
            let sharing = try XCTUnwrap(rows?.first?[kCGWindowSharingState as String] as? NSNumber)
            guard sharing.intValue == 0 else {
                throw XCTSkip("WindowServer reports that this fixture window is shareable despite its requested sharing protection.")
            }
            let manager = WindowManager(mac: mac)
            manager.setFloatingPreviewsEnabled(true)
            manager.start()
            defer { manager.stop() }
            try focusUnderPointer(source, using: mac, among: windows)
            manager.perform(.float)
            let tileFrame = try XCTUnwrap(mac.currentFrame(of: tile))
            let floatingFrame = try XCTUnwrap(mac.currentFrame(of: source))
            let exposed = try exposedPoint(in: tileFrame, outside: floatingFrame)
            try focusUnderPointer(tile, at: exposed, using: mac, among: windows)
            XCTAssertTrue(observe { self.inFront(tile.id, of: source.id) && mac.focusedID() == tile.id })
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
            XCTAssertNil(preview(of: source.id))
        }
    }

    private func checkFloatingOrder(windowCounts: [Int], overflow: Bool) throws {
        try withFixtures(windowCounts: windowCounts, allowsColorChanges: true, restoringPointer: true) { owners, mac, windows in
            guard CGPreflightScreenCaptureAccess() else {
                throw XCTSkip("Live floating previews require Screen Recording permission for the test runner.")
            }
            let manager = WindowManager(mac: mac)
            manager.setFloatingPreviewsEnabled(true)
            if overflow { manager.setLimits(TileLimits(rows: 1, columns: 1)) }
            manager.start()
            defer { manager.stop() }
            let display = try XCTUnwrap(DesktopLayout.screen(containing: windows[0].frame, in: mac.displays))
            let soleTile = display.visibleFrame.insetBy(dx: 10, dy: 10)
            let floating: ManagedWindow
            let tile: ManagedWindow
            if overflow {
                tile = try XCTUnwrap(windows.first { mac.currentFrame(of: $0)?.approximatelyEquals(soleTile) == true })
                floating = try XCTUnwrap(windows.first { $0.id != tile.id })
            } else {
                floating = windows[0]
                tile = windows[1]
                try focusUnderPointer(floating, using: mac, among: windows)
                manager.perform(.float)
            }
            let tileFrame = try XCTUnwrap(mac.currentFrame(of: tile))
            mac.setPosition(CGPoint(x: tileFrame.minX + 18, y: tileFrame.minY + 18), of: floating)
            let floatFrame = try XCTUnwrap(mac.currentFrame(of: floating))
            XCTAssertTrue(floatFrame.intersects(tileFrame))
            let exposed = try exposedPoint(in: tileFrame, outside: floatFrame)
            try focusUnderPointer(tile, at: exposed, using: mac, among: windows)
            func presented() -> Bool {
                guard let panel = preview(of: floating.id),
                      let number = CGWindowID(exactly: panel.windowNumber) else { return false }
                return inFront(number, of: tile.id) && inFront(tile.id, of: floating.id) && mac.focusedID() == tile.id
            }
            guard observe(within: 7, presented) else {
                return XCTFail("Expected live preview over the focused tile. Float \(floating.id), tile \(tile.id), overflow \(overflow)")
            }
            let panel = try XCTUnwrap(preview(of: floating.id))
            XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
            XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.floating.rawValue,
                              "Native floating panels must stay above a live preview.")
            let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let previewFrame = DesktopCoordinates(primaryTop: primaryTop).flip(panel.frame)
            XCTAssertTrue(previewFrame.approximatelyEquals(floatFrame.intersection(tileFrame)))
            XCTAssertFalse(panel.isKeyWindow)
            if #available(macOS 14, *), windowCounts.count > 1 {
                let owner = try XCTUnwrap(owners.first { $0.processIdentifier == floating.pid })
                var mismatch = try liveColorMismatch(source: floating, owner: owner, panel: panel)
                if let frontmost = NSWorkspace.shared.frontmostApplication,
                   frontmost.processIdentifier != getpid(), !owners.contains(where: { $0.processIdentifier == frontmost.processIdentifier }) {
                    // A third app can take focus in a logged-in session. Replay
                    // the color changes once with the fixture tile in front.
                    print("Cross-app color samples interrupted by \(frontmost.bundleIdentifier ?? String(frontmost.processIdentifier))")
                    mac.focus(tile)
                    guard observe(within: 7, presented) else { return XCTFail("Could not refocus the covering fixture tile") }
                    let refocused = try XCTUnwrap(preview(of: floating.id))
                    mismatch = try liveColorMismatch(source: floating, owner: owner, panel: refocused)
                }
                if let mismatch { XCTFail(mismatch) }
                let frontmost = NSWorkspace.shared.frontmostApplication
                XCTAssertTrue(presented(), "Expected focus on tile \(tile.id), observed \(String(describing: mac.focusedID())), " +
                              "frontmost \(frontmost?.bundleIdentifier ?? "unknown") PID \(String(describing: frontmost?.processIdentifier)), " +
                              "pointer \(mac.pointer), preview frame \(floatFrame)")
            }
            manager.perform(.fullscreen)
            XCTAssertTrue(observe(within: 6) {
                guard let frame = mac.currentFrame(of: tile) else { return false }
                return frame != tileFrame && presented()
            }, "An expanded tile must preserve the float preview")
            manager.perform(.fullscreen)
            XCTAssertTrue(observe(within: 6) { mac.currentFrame(of: tile) == tileFrame && presented() })
            XCTAssertEqual(CGWarpMouseCursorPosition(previewFrame.center), .success)
            manager.hover(at: mac.pointer)
            XCTAssertTrue(observe {
                self.preview(of: floating.id) == nil
                    && self.inFront(floating.id, of: tile.id) && mac.focusedID() == floating.id
            }, "Hover must hand off to the actual interactive window")
            if !overflow {
                manager.perform(.float)
                try focusUnderPointer(tile, using: mac, among: windows)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
                XCTAssertNil(preview(of: floating.id), "Retiling must remove the preview")
                XCTAssertTrue(inFront(tile.id, of: floating.id))
            } else {
                try focusUnderPointer(tile, at: exposed, using: mac, among: windows)
                XCTAssertTrue(observe(within: 7, presented))
            }
            manager.stop()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            XCTAssertNil(preview(of: floating.id), "Stopping must remove active preview panels")
            mac.focus(tile)
            XCTAssertTrue(observe { self.inFront(tile.id, of: floating.id) && mac.focusedID() == tile.id })
        }
    }

    func testFloatingOrderWithinOneApp() throws {
        try checkFloatingOrder(windowCounts: [2], overflow: false)
    }

    func testFloatingOrderBetweenApps() throws {
        try checkFloatingOrder(windowCounts: [1, 1], overflow: false)
    }

    func testFloatingPreviewCropsTheCoveredHalf() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("Inspecting the composited preview needs macOS 14") }
        try withFixtures(windowCounts: [3], allowsColorChanges: true, restoringPointer: true) { _, mac, windows in
            guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Live preview requires Screen Recording permission.") }
            let manager = WindowManager(mac: mac)
            manager.setFloatingPreviewsEnabled(true)
            manager.start()
            defer { manager.stop() }
            let source = windows[0]
            try focusUnderPointer(source, using: mac, among: windows)
            manager.perform(.float)
            let cover = windows[1]
            let coveredTile = try XCTUnwrap(mac.currentFrame(of: cover))
            let neighbor = try XCTUnwrap(mac.currentFrame(of: windows[2]))
            let horizontal = abs(coveredTile.midX - neighbor.midX) > abs(coveredTile.midY - neighbor.midY)
            let original = try XCTUnwrap(mac.currentFrame(of: source))
            let seam = horizontal
                ? CGPoint(x: coveredTile.midX < neighbor.midX ? coveredTile.maxX : coveredTile.minX, y: coveredTile.midY)
                : CGPoint(x: coveredTile.midX, y: coveredTile.midY < neighbor.midY ? coveredTile.maxY : coveredTile.minY)
            mac.setFrame(CGRect(x: seam.x - original.width / 2, y: seam.y - original.height / 2,
                                width: original.width, height: original.height), of: source)
            let moved = try XCTUnwrap(mac.currentFrame(of: source))
            let wanted = moved.intersection(coveredTile)
            let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let coordinates = DesktopCoordinates(primaryTop: primaryTop)
            try focusUnderPointer(source, using: mac, among: windows)
            // Hover follows the real cursor even while the screenshot is pending.
            // Park it at the far edge of the covering tile, clear of the preview.
            let inset = coveredTile.insetBy(dx: 12, dy: 12)
            let exposed = horizontal
                ? CGPoint(x: seam.x > coveredTile.midX ? inset.minX : inset.maxX, y: coveredTile.midY)
                : CGPoint(x: coveredTile.midX, y: seam.y > coveredTile.midY ? inset.minY : inset.maxY)
            XCTAssertFalse(moved.contains(exposed))
            try focusUnderPointer(cover, at: exposed, using: mac, among: windows)
            func coveredPanel() -> NSWindow? {
                NSApp.windows.first {
                    $0.isVisible && $0.title == FloatingPreviews.panelTitle(for: source.id)
                        && coordinates.flip($0.frame).approximatelyEquals(wanted)
                }
            }
            XCTAssertTrue(observe(within: 7) { coveredPanel() != nil && mac.focusedID() == cover.id },
                          "Expected cover \(cover.id), focus \(String(describing: mac.focusedID())), " +
                          "frontmost PID \(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier)), " +
                          "fixture PID \(cover.pid), pointer \(mac.pointer), crop \(wanted)")
            let panel = try XCTUnwrap(coveredPanel(), "Expected only the covered half at \(wanted)")
            let pixels = try panelPixels(captureFilter(for: CGWindowID(panel.windowNumber), owner: getpid()))
            let originalPixels = try panelPixels(captureFilter(for: source.id, owner: source.pid))
            let samples = horizontal ? [(0.5, 0.35), (0.5, 0.75)] : [(0.25, 0.6), (0.75, 0.6)]
            var references: [NSColor] = []
            for (x, y) in samples {
                let sourceX = (wanted.minX + x * wanted.width - moved.minX) / moved.width
                let sourceY = (wanted.minY + y * wanted.height - moved.minY) / moved.height
                let reference = try XCTUnwrap(color(originalPixels, x: sourceX, y: sourceY))
                let actual = try XCTUnwrap(color(pixels, x: x, y: y))
                references.append(reference)
                XCTAssertTrue(matches(actual, reference), "Covered quadrant at \(x), \(y) differs from source at \(sourceX), \(sourceY). Source RGBA \(quadrantPixels(originalPixels)), preview RGBA \(quadrantPixels(pixels)), crop \(String(describing: panel.contentView?.layer?.contentsRect))")
            }
            XCTAssertFalse(matches(references[0], references[1]), "The two crop probes must sample different quadrants")
        }
    }

    func testOverflowOrderWithinOneApp() throws {
        try checkFloatingOrder(windowCounts: [2], overflow: true)
    }

    private func checkWindowLifecycle(_ fixture: Process, _ mac: MacWindows, _ initial: [ManagedWindow]) throws {
        let first = initial[0]
        let second = initial[1]
        let firstFrame = try XCTUnwrap(mac.currentFrame(of: first))
        let secondFrame = try XCTUnwrap(mac.currentFrame(of: second))
        let requested = firstFrame.insetBy(dx: 12, dy: 8)
        mac.setFrame(requested, of: first)
        XCTAssertEqual(mac.currentFrame(of: first), requested)
        mac.setFrame(firstFrame, of: first)
        XCTAssertEqual(mac.currentFrame(of: first), firstFrame)

        // AppKit may reserve the menu bar and Dock when an AX client requests
        // the entire display. Measure the fixture's accepted bounds per display.
        var expandedFrames: [CGDirectDisplayID: CGRect] = [:]
        for display in mac.displays {
            mac.setFrame(display.fullFrame, of: second)
            let accepted = try XCTUnwrap(mac.currentFrame(of: second))
            print("Display \(display.id) full \(display.fullFrame), usable \(display.visibleFrame), AX accepted \(accepted).")
            let onScreen = accepted.intersection(display.fullFrame)
            XCTAssertGreaterThanOrEqual(onScreen.width, display.visibleFrame.width - 1)
            XCTAssertGreaterThanOrEqual(onScreen.height, display.visibleFrame.height - 1)
            expandedFrames[display.id] = onScreen
        }
        mac.setFrame(secondFrame, of: second)
        XCTAssertEqual(mac.currentFrame(of: second), secondFrame)

        for window in initial {
            mac.focus(window)
            XCTAssertTrue(observe { mac.focusedID() == window.id })
        }
        mac.outline(secondFrame)
        let border = CGPoint(x: secondFrame.midX, y: secondFrame.minY + 1)
        XCTAssertTrue(observe { mac.window(at: border, among: initial)?.id == second.id })
        mac.clear()

        let manager = WindowManager(mac: mac)
        manager.onError = { XCTFail($0) }
        manager.start()
        defer { manager.stop() }
        func expandSecond(_ context: String) throws {
            mac.focus(second)
            XCTAssertTrue(observe { mac.focusedID() == second.id })
            let frame = try XCTUnwrap(mac.currentFrame(of: second))
            let displays = mac.displays
            let display = try XCTUnwrap(DesktopLayout.screen(containing: frame, in: displays))
            let expected = try XCTUnwrap(expandedFrames[display.id])
            let neighbor = try XCTUnwrap(mac.currentFrame(of: first))
            let spaces = Set(displays.map(SpaceKey.init))
            manager.perform(.fullscreen)
            XCTAssertTrue(observe { mac.currentFrame(of: second)?.approximatelyEquals(expected) == true },
                          "\(context) expand on display \(display.id): expected \(expected), got \(String(describing: mac.currentFrame(of: second)))")
            manager.spaceChanged()
            // A busy AX owner is retried by the manager's inventory timer after
            // two seconds. Check one complete snapshot once its frames return.
            let settled = observe(within: 4) {
                mac.currentFrame(of: first) == neighbor
                    && mac.currentFrame(of: second)?.approximatelyEquals(expected) == true
                    && mac.focusedID() == second.id
                    && Set(mac.displays.map(SpaceKey.init)) == spaces
                    && !mac.isNativeFullscreen(second)
            }
            XCTAssertTrue(settled, "\(context) refresh on display \(display.id): expected \(expected) and neighbor \(neighbor), got \(String(describing: mac.currentFrame(of: second))) and \(String(describing: mac.currentFrame(of: first))); focused \(String(describing: mac.focusedID()))")
        }
        func checkExpansionRoundTrip(_ context: String) throws {
            let before = try XCTUnwrap(mac.currentFrame(of: second))
            let neighbor = try XCTUnwrap(mac.currentFrame(of: first))
            let spaces = Set(mac.displays.map(SpaceKey.init))
            let display = try XCTUnwrap(DesktopLayout.screen(containing: before, in: mac.displays))
            try expandSecond(context)
            manager.perform(.fullscreen)
            let restored = observe { mac.currentFrame(of: second) == before }
            if !restored {
                let actual = mac.currentFrame(of: second)
                let usable = mac.displays.first { $0.id == display.id }?.visibleFrame
                mac.setFrame(before, of: second)
                XCTFail("\(context) restore on display \(display.id): expected \(before), got \(String(describing: actual)); usable \(String(describing: usable)); direct AX retry gave \(String(describing: mac.currentFrame(of: second)))")
            }
            XCTAssertEqual(mac.currentFrame(of: first), neighbor, "\(context) neighbor moved on restore")
            XCTAssertEqual(Set(mac.displays.map(SpaceKey.init)), spaces)
            XCTAssertFalse(mac.isNativeFullscreen(second))
        }
        func isTiled() -> Bool {
            guard let a = mac.currentFrame(of: first), let b = mac.currentFrame(of: second) else { return false }
            return a != firstFrame && b != secondFrame && !a.intersects(b)
        }
        XCTAssertTrue(observe { isTiled() }, "Actual frames: \(String(describing: mac.currentFrame(of: first))), \(String(describing: mac.currentFrame(of: second)))")
        mac.focus(second)
        XCTAssertTrue(observe { mac.focusedID() == second.id })
        manager.perform(.float)
        XCTAssertTrue(observe { mac.currentFrame(of: second) == secondFrame })
        let floatCorner = CGPoint(x: secondFrame.minX + 12, y: secondFrame.minY + 24)
        XCTAssertTrue(observe { mac.window(at: floatCorner, among: initial)?.id == second.id })
        manager.beginGesture(at: floatCorner)
        manager.handle(.resize(CGSize(width: -36, height: -26)))
        let enlarged = try XCTUnwrap(mac.currentFrame(of: second))
        XCTAssertEqual(enlarged.minX, secondFrame.minX - 36, accuracy: 1)
        XCTAssertEqual(enlarged.minY, secondFrame.minY - 26, accuracy: 1)
        XCTAssertEqual(enlarged.maxX, secondFrame.maxX, accuracy: 1)
        XCTAssertEqual(enlarged.maxY, secondFrame.maxY, accuracy: 1)
        manager.handle(.ended)
        try checkExpansionRoundTrip("Resized floating window")
        mac.focus(second)
        XCTAssertTrue(observe { mac.focusedID() == second.id })
        manager.perform(.float)
        XCTAssertTrue(observe { isTiled() }, "Actual frames: \(String(describing: mac.currentFrame(of: first))), \(String(describing: mac.currentFrame(of: second)))")

        mac.focus(second)
        XCTAssertTrue(observe { mac.focusedID() == second.id })
        let before = try XCTUnwrap(mac.currentFrame(of: second))
        let neighbor = try XCTUnwrap(mac.currentFrame(of: first))
        let sideBySide = abs(before.midX - neighbor.midX) > abs(before.midY - neighbor.midY)
        // The AX geometry changes before WindowServer finishes the visual move.
        XCTAssertTrue(observe { mac.window(at: before.center, among: initial)?.id == second.id })
        manager.beginGesture(at: before.center)
        let rightOfNeighbor = before.midX > neighbor.midX
        let belowNeighbor = before.midY > neighbor.midY
        manager.handle(.resize(CGSize(width: rightOfNeighbor ? -75 : 75, height: belowNeighbor ? -65 : 65)))
        manager.handle(.ended)
        let grown = try XCTUnwrap(mac.currentFrame(of: second))
        XCTAssertGreaterThan(sideBySide ? grown.width : grown.height, sideBySide ? before.width : before.height)

        let target = try XCTUnwrap(mac.currentFrame(of: first))
        // While the picked-up window is still over its original tile, its
        // neighbor fills the gap. Cancellation restores both exact rectangles.
        XCTAssertTrue(observe { mac.window(at: grown.center, among: initial)?.id == second.id })
        manager.beginGesture(at: grown.center)
        let pickupDelta = sideBySide
            ? CGSize(width: rightOfNeighbor ? -15 : 15, height: 0)
            : CGSize(width: 0, height: belowNeighbor ? -12 : 12)
        manager.handle(.move(pickupDelta))
        XCTAssertTrue(observe {
            guard let frame = mac.currentFrame(of: first) else { return false }
            return frame.width * frame.height > target.width * target.height
        })
        let carried = try XCTUnwrap(mac.currentFrame(of: second))
        XCTAssertEqual(carried.size, grown.size)
        XCTAssertEqual(carried.minX, grown.minX + pickupDelta.width, accuracy: 2)
        XCTAssertEqual(carried.minY, grown.minY + pickupDelta.height, accuracy: 2)
        manager.handle(.cancelled)
        XCTAssertTrue(observe { mac.currentFrame(of: first) == target && mac.currentFrame(of: second) == grown })
        let dropPoint = sideBySide
            ? CGPoint(x: target.midX < grown.midX ? target.minX + 15 : target.maxX - 15, y: target.midY)
            : CGPoint(x: target.midX, y: target.midY < grown.midY ? target.minY + 15 : target.maxY - 15)
        XCTAssertTrue(observe { mac.window(at: grown.center, among: initial)?.id == second.id })
        manager.beginGesture(at: grown.center)
        manager.handle(.move(CGSize(width: dropPoint.x - grown.midX, height: dropPoint.y - grown.midY)))
        XCTAssertTrue(observe {
            guard let frame = mac.currentFrame(of: first) else { return false }
            return !frame.contains(dropPoint) && frame != target
        })
        manager.handle(.ended)
        XCTAssertTrue(observe { mac.currentFrame(of: second)?.contains(dropPoint) == true })
        let dropDisplay = try XCTUnwrap(DesktopLayout.screen(containing: target, in: mac.displays))
        var droppedLayout = DesktopLayout()
        droppedLayout.reconcile([WindowPosition(id: first.id, frame: target)], on: [dropDisplay],
                                focused: nil, pointer: dropPoint)
        XCTAssertTrue(droppedLayout.attachDragged(second.id, at: dropPoint, on: dropDisplay))
        let settledNeighbor = try XCTUnwrap(droppedLayout.frames(on: dropDisplay)[first.id])
        XCTAssertTrue(observe { mac.currentFrame(of: first)?.approximatelyEquals(settledNeighbor) == true })
        try checkExpansionRoundTrip("Reordered tile")

        let frame = try XCTUnwrap(mac.currentFrame(of: second))
        let displays = mac.displays
        let source = try XCTUnwrap(DesktopLayout.screen(containing: frame, in: displays))
        if let other = displays.first(where: { $0.id != source.id && !$0.fullFrame.intersects(source.fullFrame) }) {
            mac.focus(second)
            XCTAssertEqual(CGWarpMouseCursorPosition(point(in: frame, at: CGPoint(x: 0.38, y: 0.62))), .success)
            let pickup = mac.pointer
            let grip = fraction(of: pickup, in: frame)
            XCTAssertTrue(observe { mac.window(at: pickup, among: initial)?.id == second.id })
            let destination = other.visibleFrame.center
            manager.handle(.began)
            manager.handle(.move(CGSize(width: destination.x - pickup.x, height: destination.y - pickup.y)))
            let underDrag = try XCTUnwrap(mac.currentFrame(of: second))
            manager.handle(.ended)
            let afterDrop = try XCTUnwrap(mac.currentFrame(of: second))
            let sourceTile = source.visibleFrame.insetBy(dx: 10, dy: 10)
            let destinationTile = other.visibleFrame.insetBy(dx: 10, dy: 10)
            XCTAssertTrue(observe {
                mac.currentFrame(of: first)?.approximatelyEquals(sourceTile) == true
                    && mac.currentFrame(of: second)?.approximatelyEquals(destinationTile) == true
            }, "Cross-display drop expected \(sourceTile) and \(destinationTile). During drag: \(underDrag); on release: \(afterDrop); final: \(String(describing: mac.currentFrame(of: first))) and \(String(describing: mac.currentFrame(of: second)))")
            assertCursor(near: point(in: try XCTUnwrap(mac.currentFrame(of: second)), at: grip))
            try checkExpansionRoundTrip("Tile on secondary display")
        }

        manager.stop()
        XCTAssertTrue(observe(within: 6) {
            !manager.restorationPending && mac.currentFrame(of: first) == firstFrame
                && mac.currentFrame(of: second) == secondFrame
        })

        manager.start()
        XCTAssertTrue(observe { isTiled() })
        try expandSecond("Before disabling tiling")
        manager.stop()
        func restoredAfterFullscreen() -> Bool {
            !manager.restorationPending && !mac.isNativeFullscreen(second)
                && mac.currentFrame(of: first) == firstFrame && mac.currentFrame(of: second) == secondFrame
        }
        XCTAssertTrue(observe(within: 6) { restoredAfterFullscreen() })
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.75))
        XCTAssertTrue(restoredAfterFullscreen())

        manager.setLimits(TileLimits(rows: 1, columns: 1))
        manager.start()
        let display = try XCTUnwrap(DesktopLayout.screen(containing: firstFrame, in: mac.displays))
        let onlyTile = display.visibleFrame.insetBy(dx: 10, dy: 10)
        XCTAssertTrue(observe {
            [first, second].filter { mac.currentFrame(of: $0)?.approximatelyEquals(onlyTile) == true }.count == 1
        })
        let overflow = mac.currentFrame(of: first)?.approximatelyEquals(onlyTile) == true ? second : first
        let native = overflow.id == second.id ? secondFrame : firstFrame
        XCTAssertEqual(mac.currentFrame(of: overflow), native)
        mac.focus(overflow)
        let bottomRight = CGPoint(x: native.maxX - 10, y: native.maxY - 10)
        XCTAssertTrue(observe { mac.window(at: bottomRight, among: initial)?.id == overflow.id })
        manager.beginGesture(at: bottomRight)
        manager.handle(.resize(CGSize(width: 30, height: 20)))
        manager.handle(.ended)
        let freeFrame = try XCTUnwrap(mac.currentFrame(of: overflow))
        XCTAssertEqual(freeFrame.size, CGSize(width: native.width + 30, height: native.height + 20))
        XCTAssertTrue(observe { mac.window(at: freeFrame.center, among: initial)?.id == overflow.id })
        manager.beginGesture(at: freeFrame.center)
        manager.handle(.move(CGSize(width: 30, height: -15)))
        manager.handle(.ended)
        XCTAssertEqual(mac.currentFrame(of: overflow), freeFrame.offsetBy(dx: 30, dy: -15))
        if let other = mac.displays.first(where: { $0.id != display.id && !$0.fullFrame.intersects(display.fullFrame) }) {
            let taken = other.visibleFrame.insetBy(dx: 10, dy: 10)
            mac.setFrame(taken, of: overflow)
            manager.spaceChanged()
            let tile = overflow.id == second.id ? first : second
            let sourceFrame = try XCTUnwrap(mac.currentFrame(of: tile))
            mac.focus(tile)
            XCTAssertEqual(CGWarpMouseCursorPosition(sourceFrame.center), .success)
            let pickup = mac.pointer
            XCTAssertTrue(observe { mac.window(at: pickup, among: initial)?.id == tile.id })
            manager.handle(.began)
            manager.handle(.move(CGSize(width: taken.midX - pickup.x, height: taken.midY - pickup.y)))
            XCTAssertTrue(observe { mac.currentFrame(of: tile)?.contains(taken.center) == true })
            manager.handle(.ended)
            XCTAssertEqual(mac.currentFrame(of: tile), sourceFrame)
            XCTAssertEqual(mac.currentFrame(of: overflow), taken)
            assertCursor(near: pickup)
        }
        manager.stop()
        XCTAssertTrue(observe { mac.currentFrame(of: first) == firstFrame && mac.currentFrame(of: second) == secondFrame })

        XCTAssertTrue(observe(within: 4) { mac.inventory().count == 2 })
        XCTAssertEqual(kill(fixture.processIdentifier, SIGSTOP), 0)
        defer { kill(fixture.processIdentifier, SIGCONT) }
        let duringHang = mac.inventory()
        XCTAssertEqual(Set(duringHang.map(\.id)), Set(initial.map(\.id)))
        XCTAssertFalse(mac.isResponsive(first))
        XCTAssertEqual(kill(fixture.processIdentifier, SIGCONT), 0)
        XCTAssertTrue(observe(within: 4) {
            _ = mac.inventory()
            return mac.isResponsive(first)
        })

        manager.setLimits(TileLimits())
        manager.start()
        XCTAssertTrue(observe { isTiled() })
        let remainingFrame = try XCTUnwrap(mac.currentFrame(of: first))
        let remainingDisplay = try XCTUnwrap(DesktopLayout.screen(containing: remainingFrame, in: mac.displays))
        let settledFrame = remainingDisplay.visibleFrame.insetBy(dx: 10, dy: 10)
        XCTAssertFalse(remainingFrame.approximatelyEquals(settledFrame))
        try close(second)
        var intermediate: Set<CGFloat> = []
        let closedAt = ProcessInfo.processInfo.systemUptime
        let settled = observe {
            guard let frame = mac.currentFrame(of: first) else { return false }
            if frame.approximatelyEquals(settledFrame) { return true }
            let area = frame.width * frame.height
            if area > remainingFrame.width * remainingFrame.height && area < settledFrame.width * settledFrame.height {
                intermediate.insert(area)
            }
            return false
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - closedAt
        print("Close reflow sampled \(intermediate.count) intermediate sizes in \(Int(elapsed * 1_000)) ms.")
        XCTAssertTrue(settled, "Remaining tile failed to fill \(settledFrame)")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertGreaterThanOrEqual(intermediate.count, 2, "Expected consecutive frames during the close animation")
        }
    }
}
