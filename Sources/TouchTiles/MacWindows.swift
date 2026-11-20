import AppKit
import ApplicationServices
import Darwin

struct ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let element: AXUIElement
}

struct MacDisplay {
    let id: CGDirectDisplayID
    let visibleFrame: CGRect
    let fullFrame: CGRect
    let space: UInt64?
}

// Cocoa measures up from the primary screen's bottom edge. AX and Quartz
// measure down from its top edge, including on screens above or left of it.
struct DesktopCoordinates {
    let primaryTop: CGFloat

    func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
}

private enum WindowServer {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    // AX has no public window-number attribute. Resolve these at runtime so
    // an OS change disables the affected capability without breaking launch.
    static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static let spaceFunctions: (MainConnection, CopySpaces)? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let framework = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let connection = dlsym(framework, "SLSMainConnectionID"),
              let spaces = dlsym(framework, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self),
                unsafeBitCast(spaces, to: CopySpaces.self))
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id = kCGNullWindowID
        guard getWindow?(element, &id) == .success, id != kCGNullWindowID else { return nil }
        return id
    }

    static func activeSpaces() -> [String: UInt64] {
        guard let (connection, copy) = spaceFunctions,
              let displays = copy(connection())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [String: UInt64] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let id = current["ManagedSpaceID"] as? NSNumber else { continue }
            result[identifier.uppercased()] = id.uint64Value
        }
        return result
    }
}

private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

private func accessibilityElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func isWritable(_ attribute: String, of element: AXUIElement) -> Bool {
    var writable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success
        && writable.boolValue
}

private func attributes(_ names: [String], of element: AXUIElement) -> [AnyObject]? {
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
          let result = values as? [AnyObject], result.count == names.count else { return nil }
    return result
}

private struct VisibleWindow {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let level: Int
    let alpha: CGFloat

    init?(_ info: [String: Any]) {
        guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
              let id = info[kCGWindowNumber as String] as? NSNumber,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty else { return nil }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { return nil }
        self.id = id.uint32Value
        self.pid = pid.int32Value
        self.frame = frame
        self.level = layer.intValue
        self.alpha = alpha
    }
}

final class MacWindows {
    private static let fullScreen = "AXFullScreen"
    private static let systemPanelOwners: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.Spotlight", "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
    ]
    private let system = AXUIElementCreateSystemWide()
    private var panel: FocusOutline?
    private let processFilter: Set<pid_t>?
    private var retryAfter: [pid_t: TimeInterval] = [:]
    private var previous: [CGWindowID: ManagedWindow] = [:]
    private var attachments: [CGWindowID: pid_t] = [:]

    init(processFilter: Set<pid_t>? = nil) {
        self.processFilter = processFilter
        // A hung app should not hold the menu bar UI for the AX default timeout.
        AXUIElementSetMessagingTimeout(system, 0.15)
    }

    var supportsWindowIdentity: Bool { WindowServer.getWindow != nil }

    private var coordinates: DesktopCoordinates {
        DesktopCoordinates(primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    var displays: [MacDisplay] {
        let spaces = WindowServer.activeSpaces()
        let coordinates = self.coordinates
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = number.uint32Value
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let identifier = uuid.map { (CFUUIDCreateString(nil, $0) as String).uppercased() }
            let space = identifier.flatMap { spaces[$0] }
                ?? ((!NSScreen.screensHaveSeparateSpaces || id == CGMainDisplayID()) ? spaces["MAIN"] : nil)
            return MacDisplay(id: id, visibleFrame: coordinates.flip(screen.visibleFrame),
                              fullFrame: coordinates.flip(screen.frame), space: space)
        }
    }

    var pointer: CGPoint { coordinates.flip(NSEvent.mouseLocation) }

    /// Quartz and AX use the same global, top-left desktop coordinate space.
    /// Warping the cursor leaves scroll, mouse-move and drag event streams alone.
    @discardableResult
    func movePointer(to point: CGPoint) -> Bool {
        CGWarpMouseCursorPosition(point) == .success
    }

    func inventory() -> [ManagedWindow] {
        guard supportsWindowIdentity, AXIsProcessTrusted(),
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let visible = info.compactMap(VisibleWindow.init)
            .filter { $0.level == 0 && $0.pid != getpid() && processFilter?.contains($0.pid) != false }
        let byProcess = Dictionary(grouping: visible, by: \.pid)
        var eligible: [CGWindowID: ManagedWindow] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        retryAfter = retryAfter.filter { byProcess[$0.key] != nil && $0.value > now }

        for (pid, candidates) in byProcess {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden,
                  app.activationPolicy == .regular else { continue }
            var value: CFTypeRef?
            if retryAfter[pid] == nil {
                let owner = AXUIElementCreateApplication(pid)
                if AXUIElementCopyAttributeValue(owner, kAXWindowsAttribute as CFString, &value) == .cannotComplete {
                    retryAfter[pid] = now + 2
                }
            }
            if retryAfter[pid] != nil {
                // Keep the split of a busy app. WindowServer still tells us which
                // windows are visible and where they are without messaging it.
                for candidate in candidates {
                    if let window = previous[candidate.id], window.pid == pid {
                        eligible[candidate.id] = ManagedWindow(id: candidate.id, pid: pid,
                                                                frame: candidate.frame, element: window.element)
                    }
                }
                continue
            }
            guard let elements = value as? [AXUIElement] else { continue }
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for element in elements {
                guard let id = WindowServer.windowID(element), let window = byID[id],
                      let frame = Self.tileableFrame(of: element) else { continue }
                eligible[id] = ManagedWindow(id: window.id, pid: pid, frame: frame, element: element)
            }
        }
        previous = eligible
        // CG's on-screen list supplies stacking order. AXWindows does not.
        return visible.compactMap { eligible[$0.id] }
    }

    private static func tileableFrame(of element: AXUIElement) -> CGRect? {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, fullScreen,
                     kAXModalAttribute, kAXPositionAttribute, kAXSizeAttribute]
        guard let values = attributes(names, of: element),
              values[0] as? String == kAXWindowRole, values[1] as? String == kAXStandardWindowSubrole,
              (values[2] as? NSNumber)?.boolValue != true, (values[3] as? NSNumber)?.boolValue != true,
              (values[4] as? NSNumber)?.boolValue != true,
              isWritable(kAXPositionAttribute, of: element), isWritable(kAXSizeAttribute, of: element)
        else { return nil }
        // WindowServer animation can lag a completed AX move across displays.
        // Use its list for visibility and stacking, and AX for desired geometry.
        return frame(position: values[5], size: values[6])
    }

    func isResponsive(_ window: ManagedWindow) -> Bool {
        guard let deadline = retryAfter[window.pid] else { return true }
        return ProcessInfo.processInfo.systemUptime >= deadline
    }

    func window(at point: CGPoint, among windows: [ManagedWindow]) -> ManagedWindow? {
        let number = NSWindow.windowNumber(at: coordinates.flip(point), belowWindowWithWindowNumber: 0)
        guard let id = CGWindowID(exactly: number) else { return nil }
        return windows.first { $0.id == id }
    }

    /// App activation can close a menu or hide a utility panel. Raising a
    /// document can cover another document's sheet. Read live state because
    /// these surfaces can open between inventory ticks.
    func allowsHoverFocus(to target: ManagedWindow) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let visible = info.compactMap(VisibleWindow.init).filter { processFilter?.contains($0.pid) != false }
        guard let index = visible.firstIndex(where: { $0.id == target.id && $0.pid == target.pid }) else { return false }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let candidates = visible.prefix(index).filter { surface in
            if surface.level == NSWindow.Level.popUpMenu.rawValue { return true }
            guard surface.pid != getpid(), previous[surface.id] == nil else { return false }
            if surface.level == 0 {
                let deactivatesOwner = surface.pid == frontPID && surface.pid != target.pid
                return deactivatesOwner || surface.frame.intersects(visible[index].frame)
            }
            return surface.level <= NSWindow.Level.popUpMenu.rawValue
        }
        // AppKit removes AXSheet before the dismiss animation finishes and
        // can restore focus to its document at the end of that animation.
        if !attachments.isEmpty {
            attachments = attachments.filter { id, pid in visible.contains { $0.id == id && $0.pid == pid } }
            if candidates.contains(where: { attachments[$0.id] == $0.pid }) { return false }
        }
        for (pid, ownerWindows) in Dictionary(grouping: candidates, by: \.pid) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { continue }
            let bundle = app.bundleIdentifier ?? ""
            let systemPanelOwner = Self.systemPanelOwners.contains(bundle)
            let popups = ownerWindows.filter { $0.level == NSWindow.Level.popUpMenu.rawValue }
            if popups.contains(where: menuAtCenter) { return false }
            guard pid != getpid(), retryAfter[pid] == nil,
                  pid == frontPID || systemPanelOwner || ownerWindows.contains(where: { $0.level == 0 })
            else { continue }
            let owner = AXUIElementCreateApplication(pid)
            guard let elements = attribute(kAXWindowsAttribute, of: owner) as? [AXUIElement] else { continue }
            let windows = elements.compactMap { element in WindowServer.windowID(element).map { ($0, element) } }
            // A sheet has a WindowServer number but isn't in AXWindows. Its
            // AXSheet belongs to the document, which may no longer be key.
            let listed = Set(windows.map { $0.0 })
            let unlisted = ownerWindows.filter { $0.level == 0 && !listed.contains($0.id) }
            for (id, element) in windows {
                if !unlisted.isEmpty, let document = visible.first(where: { $0.id == id }) {
                    let nearby = unlisted.filter { document.frame.intersects($0.frame) }
                    if !nearby.isEmpty,
                       let child = Self.attachedTransient(in: element, matching: Set(nearby.map(\.id))),
                       let childID = WindowServer.windowID(child) {
                        attachments[childID] = pid
                        return false
                    }
                }
                guard let surface = ownerWindows.first(where: { $0.id == id }) else { continue }
                // Status items live entirely in the menu bar. An open system
                // picker or Control Center panel extends into the desktop.
                if systemPanelOwner {
                    guard extendsBelowMenuBar(surface.frame) else { continue }
                    // Notification Center also owns passive banners while
                    // another app has the keyboard. Keep ordinary hover live.
                    if bundle == "com.apple.notificationcenterui", pid != frontPID,
                       !Self.isTransient(element), !ownsKeyboardFocus(pid) { continue }
                    return false
                }
                let isOwnersPalette = pid == frontPID && surface.level == NSWindow.Level.floating.rawValue
                if Self.isTransient(element, atFloatingLevel: isOwnersPalette) {
                    // AppKit can leave a modeless dialog behind a covering
                    // document. Raising the target can't cover it any further.
                    if surface.level == 0, (attribute(kAXModalAttribute, of: element) as? NSNumber)?.boolValue == false,
                       isCoveredByDocuments(surface, in: visible) { continue }
                    return false
                }
            }
        }
        if let frontPID, processFilter?.contains(frontPID) != false, retryAfter[frontPID] == nil {
            if frontPID == getpid() {
                if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil
                    || (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true { return false }
            } else if Self.frontmostApplicationHasTransient(frontPID, visible: visible) {
                return false
            }
        }

        return true
    }

    private func isCoveredByDocuments(_ surface: VisibleWindow, in visible: [VisibleWindow]) -> Bool {
        var exposed = [surface.frame]
        for cover in visible.prefix(while: { $0.id != surface.id })
            where cover.level == 0 && cover.alpha == 1 && previous[cover.id]?.pid == cover.pid {
            exposed = exposed.flatMap { subtract(cover.frame, from: $0) }
            if exposed.isEmpty { return true }
        }
        return false
    }

    private func ownsKeyboardFocus(_ pid: pid_t) -> Bool {
        guard let focused = accessibilityElement(attribute(kAXFocusedUIElementAttribute, of: system)) else { return false }
        var owner: pid_t = 0
        return AXUIElementGetPid(focused, &owner) == .success && owner == pid
    }

    private func extendsBelowMenuBar(_ frame: CGRect) -> Bool {
        let coordinates = self.coordinates
        return NSScreen.screens.contains { screen in
            let overlap = coordinates.flip(screen.visibleFrame).intersection(frame)
            let barHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            return !overlap.isEmpty && overlap.maxY > coordinates.flip(screen.frame).minY + barHeight
        }
    }

    private static func frontmostApplicationHasTransient(_ pid: pid_t, visible: [VisibleWindow]) -> Bool {
        let owner = AXUIElementCreateApplication(pid)
        guard let values = attributes([kAXShownMenuUIElementAttribute, kAXFocusedWindowAttribute,
                                       kAXMainWindowAttribute], of: owner)
        else { return false }
        if accessibilityElement(values[0]) != nil { return true }
        // AXFocusedWindow can be nil during AppKit's sheet presentation.
        guard let window = accessibilityElement(values[1]) ?? accessibilityElement(values[2]) else { return false }
        let transient = Self.isTransient(window) ? window : attachedTransient(in: window)
        guard let transient else { return false }
        guard let id = WindowServer.windowID(transient) else { return true }
        return visible.contains { $0.id == id && $0.pid == pid }
    }

    private static func attachedTransient(in window: AXUIElement, matching ids: Set<CGWindowID>? = nil) -> AXUIElement? {
        guard let children = attribute(kAXChildrenAttribute, of: window) as? [AXUIElement] else { return nil }
        return children.first { child in
            let role = attribute(kAXRoleAttribute, of: child) as? String
            guard role == kAXSheetRole || role == kAXPopoverRole else { return false }
            guard let ids else { return true }
            return WindowServer.windowID(child).map(ids.contains) == true
        }
    }

    private static func isTransient(_ element: AXUIElement, atFloatingLevel: Bool = false) -> Bool {
        guard let values = attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute], of: element)
        else { return false }
        switch values[0] as? String {
        case kAXMenuRole, kAXSheetRole, kAXPopoverRole: return true
        case kAXWindowRole:
            if (values[2] as? NSNumber)?.boolValue == true { return true }
            switch values[1] as? String {
            case kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole:
                return true
            case kAXStandardWindowSubrole, kAXUnknownSubrole, nil: return atFloatingLevel
            default: return false
            }
        default: return false
        }
    }

    private func menuAtCenter(of surface: VisibleWindow) -> Bool {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(surface.frame.midX), Float(surface.frame.midY),
                                               &element) == .success else { return false }
        // A menu extra can present a menu without becoming the frontmost app.
        for _ in 0..<8 {
            guard let item = element, let role = attribute(kAXRoleAttribute, of: item) as? String else { return false }
            if role == kAXMenuRole || role == kAXMenuItemRole { return true }
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            element = accessibilityElement(attribute(kAXParentAttribute, of: item))
        }
        return false
    }

    private func focusedElement() -> (pid_t, AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              processFilter?.contains(app.processIdentifier) != false,
              retryAfter[app.processIdentifier] == nil else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attribute(kAXFocusedWindowAttribute, of: element),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (app.processIdentifier, focused as! AXUIElement)
    }

    func focusedID() -> CGWindowID? {
        focusedElement().flatMap { WindowServer.windowID($0.1) }
    }

    func focused(among windows: [ManagedWindow]) -> ManagedWindow? {
        guard let id = focusedID() else { return nil }
        return windows.first { $0.id == id }
    }

    func focus(_ window: ManagedWindow) {
        guard isResponsive(window) else { return }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid {
            if AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
                NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            }
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    func isAlive(_ window: ManagedWindow) -> Bool {
        guard NSRunningApplication(processIdentifier: window.pid)?.isTerminated == false else { return false }
        guard isResponsive(window) else { return true }
        var role: CFTypeRef?
        // An app can be busy while a Space changes. Only discard its saved
        // frame if the owner exited or AX confirms destruction.
        return AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &role) != .invalidUIElement
    }

    func currentFrame(of window: ManagedWindow) -> CGRect? {
        guard isResponsive(window) else { return nil }
        return currentFrame(of: window.element)
    }

    private func currentFrame(of element: AXUIElement) -> CGRect? {
        guard let values = attributes([kAXPositionAttribute, kAXSizeAttribute], of: element) else { return nil }
        return Self.frame(position: values[0], size: values[1])
    }

    private static func frame(position: AnyObject, size sizeValue: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func setPosition(_ position: CGPoint, of window: ManagedWindow) {
        guard isResponsive(window), position.x.isFinite, position.y.isFinite else { return }
        var origin = position
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of window: ManagedWindow) -> Bool {
        setExactFrame(frame.integral, of: window)
    }

    /// Only a successful AXSize write can establish that the owner refused a smaller size.
    func setSize(_ requested: CGSize, of window: ManagedWindow) -> Bool {
        var size = requested
        guard isResponsive(window), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let value = AXValueCreate(.cgSize, &size)
        else { return false }
        let result = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
        if result == .cannotComplete { retryAfter[window.pid] = ProcessInfo.processInfo.systemUptime + 2 }
        return result == .success
    }

    @discardableResult
    private func setExactFrame(_ target: CGRect, of window: ManagedWindow) -> Bool {
        guard isResponsive(window) else { return false }
        guard target.width > 0, target.height > 0, !target.isInfinite, !target.isNull else { return false }
        let existing = currentFrame(of: window)
        guard target != existing else { return false }
        var origin = target.origin
        guard let positionValue = AXValueCreate(.cgPoint, &origin) else { return false }
        if origin != existing?.origin {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        }
        if target.size != existing?.size {
            let wroteSize = setSize(target.size, of: window)
            // AppKit can clamp the first move against the *old* window size.
            // Retry the origin once after resizing, including across displays.
            if isResponsive(window) {
                AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
            }
            return wroteSize
        }
        return false
    }

    func restoreExpandedFrame(_ target: CGRect, of window: ManagedWindow, on display: MacDisplay) {
        setExactFrame(target, of: window)
        guard let accepted = currentFrame(of: window),
              accepted.width > target.width + 1 || accepted.height > target.height + 1 else { return }

        // A slight shrink can stick to the seam between displays. Get the
        // window clear of that edge before growing it back to the requested tile.
        let inset = display.visibleFrame.insetBy(dx: 30, dy: 30)
        guard !inset.isEmpty else { return }
        let interior = target.fitted(to: inset)
        guard interior != target else { return }
        setFrame(interior, of: window)
        setExactFrame(target, of: window)
    }

    func isNativeFullscreen(_ window: ManagedWindow) -> Bool {
        guard isResponsive(window) else { return false }
        return (attribute(Self.fullScreen, of: window.element) as? NSNumber)?.boolValue == true
    }

    func outline(_ frame: CGRect?) {
        guard let frame, !frame.isEmpty else { panel?.orderOut(nil); return }
        let outline = panel ?? FocusOutline()
        panel = outline
        let rect = coordinates.flip(frame)
        if outline.frame != rect { outline.setFrame(rect, display: true) }
        if !outline.isVisible { outline.orderFrontRegardless() }
    }

    func clear() {
        retryAfter.removeAll()
        previous.removeAll()
        panel?.close()
        panel = nil
    }
}

private final class FocusOutline: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        animationBehavior = .none
        setAccessibilityElement(false)
        let border = NSView(frame: .zero)
        border.wantsLayer = true
        border.layer?.cornerRadius = 9
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
        contentView = border
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
