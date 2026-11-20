import AppKit
import CoreGraphics
import TouchBridge

enum TrackpadGesture: Equatable {
    case began
    case resize(CGSize)
    case move(CGSize)
    case ended
    case cancelled
}

struct Finger {
    let path: Int32
    let position: CGPoint
}

// Raw contact positions are normalized to the trackpad. Only a three-finger
// move uses these positions. macOS supplies the two-finger scroll deltas.
struct ContactGesture {
    private enum State {
        case idle, twoFingers, waitForLift
        case swipe(paths: [Int32], centroid: CGPoint, claimed: Bool)
    }

    private var state = State.idle

    var claimed: Bool {
        if case .swipe(_, _, claimed: true) = state { return true }
        return false
    }

    var fingerCount: Int {
        switch state {
        case .swipe: return 3
        case .twoFingers: return 2
        default: return 0
        }
    }

    var idle: Bool {
        if case .idle = state { return true }
        return false
    }

    mutating func releaseModifier() -> [TrackpadGesture] {
        guard !idle else { return [] }
        let events: [TrackpadGesture] = claimed ? [.ended] : []
        state = .waitForLift
        return events
    }

    mutating func update(_ fingers: [Finger], modifierHeld: Bool) -> [TrackpadGesture] {
        if fingers.isEmpty {
            let events: [TrackpadGesture] = claimed ? [.ended] : []
            state = .idle
            return events
        }
        if case .waitForLift = state { return [] }
        guard modifierHeld else {
            if !idle { return releaseModifier() }
            if fingers.count >= 2 { state = .waitForLift }
            return []
        }
        guard fingers.count == 3 else {
            if case .swipe = state {
                let events: [TrackpadGesture] = claimed ? [fingers.count < 3 ? .ended : .cancelled] : []
                state = .waitForLift
                return events
            }
            switch fingers.count {
            case 2: state = .twoFingers
            case 1: state = .idle
            default: state = .waitForLift
            }
            return []
        }
        let paths = fingers.map(\.path).sorted()
        let center = CGPoint(x: fingers.reduce(0) { $0 + $1.position.x } / 3,
                             y: fingers.reduce(0) { $0 + $1.position.y } / 3)
        guard case let .swipe(previousPaths, previousCenter, active) = state else {
            state = .swipe(paths: paths, centroid: center, claimed: false)
            return []
        }
        guard previousPaths == paths else {
            state = .waitForLift
            return active ? [.cancelled] : []
        }
        let delta = CGSize(width: center.x - previousCenter.x, height: previousCenter.y - center.y)
        guard delta != .zero, active || hypot(delta.width, delta.height) >= 0.008 else { return [] }
        state = .swipe(paths: paths, centroid: center, claimed: true)
        return active ? [.move(delta)] : [.began, .move(delta)]
    }
}

struct ScrollResize {
    enum Owner { case application, resize, swipe }
    private enum State { case idle, application, armed, resizing, draining }
    private var state = State.idle
    private var lastDirectWasConsumed = false
    private var consumeMomentum: Bool?

    var resizing: Bool { state == .resizing }
    private var consumed: Bool { state == .armed || resizing || state == .draining }

    // In natural scrolling, positive Cocoa deltas move content right and down.
    // AX uses those same axes. Undo the opposite sign for traditional scrolling.
    static func fingerMotion(x: CGFloat, y: CGFloat, natural: Bool) -> CGSize {
        let sign: CGFloat = natural ? 1 : -1
        return CGSize(width: x * sign, height: y * sign)
    }

    mutating func release(cancel: Bool = false) -> [TrackpadGesture] {
        guard state == .armed || resizing else { return [] }
        let events: [TrackpadGesture] = resizing ? [cancel ? .cancelled : .ended] : []
        state = .draining
        return events
    }

    private mutating func finish(cancel: Bool) -> (drop: Bool, events: [TrackpadGesture]) {
        let drop = consumed
        let events = release(cancel: cancel)
        lastDirectWasConsumed = drop
        state = .idle
        return (drop, events)
    }

    mutating func update(phase: NSEvent.Phase, momentum: NSEvent.Phase, owner: Owner,
                         motion: CGSize) -> (drop: Bool, events: [TrackpadGesture]) {
        if !momentum.isEmpty {
            // The first inertial event can arrive before the fingers-up event.
            // Settle the resize once. Momentum never moves a window.
            let ended = momentum.contains(.ended) || momentum.contains(.cancelled)
            if let drop = consumeMomentum, !momentum.contains(.began) {
                if ended { consumeMomentum = nil }
                return (drop, [])
            }
            if ended { return (lastDirectWasConsumed, []) }
            let events = state != .idle ? finish(cancel: false).events : []
            consumeMomentum = lastDirectWasConsumed
            return (lastDirectWasConsumed, events)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // A terminal packet after momentum began belongs to that scroll.
            if state == .idle { return (lastDirectWasConsumed, []) }
            return finish(cancel: phase.contains(.cancelled))
        }
        if phase.contains(.mayBegin) { return (owner != .application, []) }
        var events: [TrackpadGesture] = []
        if phase.contains(.began) && state != .idle {
            events += finish(cancel: false).events
        }
        if state == .idle {
            switch owner {
            case .application: state = .application
            case .swipe: state = .draining
            case .resize: state = .armed
            }
        }
        if state == .armed && motion != .zero {
            if owner == .resize {
                state = .resizing
                events.append(.began)
            } else {
                state = .draining
            }
        }
        if resizing && motion != .zero { events.append(.resize(motion)) }
        return (consumed, events)
    }

    // If a driver omits phase.began on its next scroll, the fresh two-contact
    // sequence also separates it from a previous scroll's drained remainder.
    mutating func newContacts() {
        if state == .draining || state == .application { _ = finish(cancel: false) }
    }
}

// MT can call on multiple device threads. The tap must make its decision before
// returning to WindowServer. Never perform AX calls on either of these paths.
private final class TouchSession {
    private let lock = NSLock()
    private let modifiers: CGEventFlags
    private let deliver: ([TrackpadGesture]) -> Void
    private var tracks: [UInt: ContactGesture] = [:]
    private var owner: UInt?
    private var resizeDevice: UInt?
    private var scroll = ScrollResize()
    private var swallowTerminalUntil: TimeInterval = 0
    private var pending: [TrackpadGesture] = []
    private var running = true
    private var threeFingerDrag = false
    private var claimedMouseDown = false
    private var tap: CFMachPort?

    init(modifiers: CGEventFlags, deliver: @escaping ([TrackpadGesture]) -> Void) {
        self.modifiers = modifiers
        self.deliver = deliver
    }

    func readDraggingStyle() {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let enabled = domains.contains { domain in
            CFPreferencesGetAppBooleanValue("TrackpadThreeFingerDrag" as CFString, domain as CFString, nil)
        }
        lock.lock()
        threeFingerDrag = enabled
        lock.unlock()
    }

    private func matches(_ flags: CGEventFlags) -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return !modifiers.isEmpty && flags.intersection(mask) == modifiers
    }

    func receive(device: UInt, contacts: UnsafePointer<DTContact>?, count: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return false }
        if count < 0 {
            tracks.removeValue(forKey: device)
            if resizeDevice == device {
                enqueue(scroll.release(cancel: true))
                resizeDevice = nil
            }
            if owner == device {
                owner = nil
                enqueue([.cancelled])
            }
            return false
        }
        if let active = owner ?? resizeDevice, active != device { return false }
        let held = matches(CGEventSource.flagsState(.combinedSessionState))
        if !held && tracks[device] == nil && count < 2 { return false }
        let fingers = UnsafeBufferPointer(start: contacts, count: Int(count)).map {
            Finger(path: $0.path, position: CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
        }
        var track = tracks[device] ?? ContactGesture()
        let previouslyClaimed = track.claimed
        if resizeDevice == device && (count != 2 || !held) {
            enqueue(scroll.release(cancel: count > 2))
            resizeDevice = nil
            if count != 0 { _ = track.releaseModifier() }
        }
        if track.idle && count == 2 { scroll.newContacts() }
        let events = track.update(fingers, modifierHeld: held)
        if track.idle { tracks.removeValue(forKey: device) }
        else { tracks[device] = track }
        if track.claimed {
            if owner == nil { tracks = [device: track] }
            owner = device
        } else if previouslyClaimed {
            owner = nil
            swallowTerminalUntil = ProcessInfo.processInfo.systemUptime + 0.18
        }
        enqueue(events)
        return track.claimed || (previouslyClaimed && count == 0)
    }

    private func enqueue(_ events: [TrackpadGesture]) {
        guard !events.isEmpty else { return }
        let schedule = pending.isEmpty
        for event in events {
            switch (pending.last, event) {
            case let (.move(a), .move(b)):
                pending[pending.count - 1] = .move(CGSize(width: a.width + b.width, height: a.height + b.height))
            case let (.resize(a), .resize(b)):
                pending[pending.count - 1] = .resize(CGSize(width: a.width + b.width, height: a.height + b.height))
            default:
                pending.append(event)
            }
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let batch = self.pending
                self.pending.removeAll(keepingCapacity: true)
                self.lock.unlock()
                self.deliver(batch)
            }
        }
    }

    private func shouldDrop(type: CGEventType, event: CGEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if owner != nil || scroll.resizing { enqueue([.cancelled]) }
            owner = nil
            resizeDevice = nil
            scroll = ScrollResize()
            tracks.removeAll()
            claimedMouseDown = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        switch type {
        case .leftMouseDown:
            // When Accessibility emulates a drag it emits an ordinary left
            // click. Own the sequence only if its down coincides with a
            // configured three-finger gesture; never swallow an orphan up.
            claimedMouseDown = threeFingerDrag && matches(event.flags)
                && tracks.values.contains(where: { $0.fingerCount == 3 })
            return claimedMouseDown
        case .leftMouseDragged:
            return claimedMouseDown
        case .leftMouseUp:
            let claimed = claimedMouseDown
            claimedMouseDown = false
            return claimed
        default:
            break
        }
        if type == .flagsChanged {
            if !matches(event.flags) {
                enqueue(scroll.release())
                resizeDevice = nil
                for device in Array(tracks.keys) {
                    if var track = tracks[device] {
                        enqueue(track.releaseModifier())
                        tracks[device] = track
                    }
                }
                if owner != nil { swallowTerminalUntil = ProcessInfo.processInfo.systemUptime + 0.18 }
                owner = nil
            }
            return false
        }
        if type == .scrollWheel {
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                  let wheel = NSEvent(cgEvent: event) else { return false }
            return handleScroll(wheel, flags: event.flags)
        }
        guard (28...31).contains(type.rawValue) else { return false }
        if owner != nil { return true }
        // The Dock and the app recognizers run independently of raw contact
        // delivery. Suppress a competing three-finger swipe as soon as it
        // starts. Two-finger magnification still goes to the foreground app.
        let subtype = event.getIntegerValueField(CGEventField(rawValue: 110)!)
        if matches(CGEventSource.flagsState(.combinedSessionState)) {
            if subtype == 23 && tracks.values.contains(where: { $0.fingerCount == 3 }) { return true }
        }
        // Raw contacts sometimes end before Quartz dispatches the last Dock
        // swipe. Suppress its terminal packet without swallowing a new gesture.
        let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        return subtype == 23 && (phase == 4 || phase == 8)
            && ProcessInfo.processInfo.systemUptime <= swallowTerminalUntil
    }

    private func handleScroll(_ wheel: NSEvent, flags: CGEventFlags) -> Bool {
        let two = tracks.first(where: { $0.value.fingerCount == 2 })?.key
        let three = tracks.values.contains(where: { $0.fingerCount == 3 })
        let held = matches(flags)
        if !held && scroll.resizing && wheel.momentumPhase.isEmpty {
            enqueue(scroll.release())
            resizeDevice = nil
        }
        let route: ScrollResize.Owner
        if owner != nil || (held && three) { route = .swipe }
        else if held && two != nil { route = .resize }
        else { route = .application }
        // The event tap supplies accelerated point deltas, including both
        // axes for diagonal motion. Raw touches identify the trackpad only.
        let motion = ScrollResize.fingerMotion(x: wheel.scrollingDeltaX, y: wheel.scrollingDeltaY,
                                               natural: wheel.isDirectionInvertedFromDevice)
        let result = scroll.update(phase: wheel.phase, momentum: wheel.momentumPhase,
                                   owner: route, motion: motion)
        resizeDevice = scroll.resizing ? two : nil
        enqueue(result.events)
        return result.drop
    }

    func installTap() -> Bool {
        let standard: [CGEventType] = [.scrollWheel, .flagsChanged, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let types = standard.map(\.rawValue) + [28, 29, 30, 31]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: {
            _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<TouchSession>.fromOpaque(info).takeUnretainedValue()
            return session.shouldDrop(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        tap = port
        CGEvent.tapEnable(tap: port, enable: true)
        // AX clients can stall the main thread. Keep the event tap responsive
        // while the manager waits for a slow window to accept its new bounds.
        Thread.detachNewThread { [self] in
            Thread.current.name = "TouchTiles gesture tap"
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            while CFMachPortIsValid(port) {
                CFRunLoopRunInMode(.defaultMode, 1, false)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
            withExtendedLifetime(self) {}
        }
        return true
    }

    func stop() {
        lock.lock()
        running = false
        pending.removeAll()
        owner = nil
        let port = tap
        tap = nil
        lock.unlock()
        if let port { CFMachPortInvalidate(port) }
    }
}

final class GestureInput {
    var onGesture: ((TrackpadGesture) -> Void)?
    var onStatus: ((String?) -> Void)?

    private var session: TouchSession?
    private var displaySize = CGSize.zero
    private var delivering = false
    private var modifiers: CGEventFlags = []
    private var refresh: Timer?
    private var observers: [NSObjectProtocol] = []
    private var asleep = false
    private var status: String?

    func start(modifiers: CGEventFlags) {
        stop()
        self.modifiers = modifiers
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.asleep = true
                self?.closeSession()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.asleep = false
                self?.refreshDevices()
            },
        ]
        refreshDevices()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.refreshDevices() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    private func refreshDevices() {
        guard !asleep else { return }
        let count: Int32
        if session != nil {
            count = DTRefreshDevices()
        } else {
            let stream = TouchSession(modifiers: modifiers) { [weak self] events in
                self?.emit(events)
            }
            guard stream.installTap() else {
                report("Gestures need access to macOS input events. Check Accessibility and Input Monitoring in System Settings.")
                return
            }
            session = stream
            count = DTStartContacts({ context, device, contacts, count in
                guard let context else { return false }
                return Unmanaged<TouchSession>.fromOpaque(context).takeUnretainedValue()
                    .receive(device: device, contacts: contacts, count: count)
            }, Unmanaged.passUnretained(stream).toOpaque())
        }
        session?.readDraggingStyle()
        switch count {
        case -2:
            report("macOS blocked trackpad contacts. Allow TouchTiles in System Settings → Privacy & Security → Input Monitoring, then reopen it.")
        case ..<0:
            closeSession()
            report("This version of macOS does not expose the trackpad contact interface TouchTiles needs.")
        case 0:
            report("Connect an Apple trackpad to use window gestures.")
        default:
            report(nil)
        }
    }

    private func report(_ message: String?) {
        guard status != message else { return }
        status = message
        onStatus?(message)
    }

    private func emit(_ events: [TrackpadGesture]) {
        for event in events {
            switch event {
            case .began:
                let point = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
                guard let screen else { continue }
                displaySize = screen.frame.size
                delivering = true
                onGesture?(.began)
            case .resize where delivering:
                onGesture?(event)
            case let .move(normalized) where delivering:
                onGesture?(.move(project(normalized)))
            case .ended, .cancelled:
                if delivering { onGesture?(event) }
                delivering = false
            default:
                break
            }
        }
    }

    private func project(_ delta: CGSize) -> CGSize {
        CGSize(width: delta.width * displaySize.width, height: delta.height * displaySize.height)
    }

    private func closeSession() {
        if let session {
            session.stop()
            DTStopContacts()
            self.session = nil
        }
        if delivering { onGesture?(.cancelled) }
        delivering = false
    }

    func stop() {
        refresh?.invalidate()
        refresh = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        closeSession()
        asleep = false
        report(nil)
    }

    deinit { stop() }
}
