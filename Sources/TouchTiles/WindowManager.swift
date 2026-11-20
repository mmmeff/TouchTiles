import AppKit

/// AX and AppKit run on the main run loop. The input driver also delivers there.
final class WindowManager {
    var onError: ((String) -> Void)?
    var isRecordingShortcut: () -> Bool = { false }
    var onFloatingPreviewIssue: ((String?) -> Void)?
    private let mac: MacWindows
    private var layout = DesktopLayout()
    private var screens: [MacDisplay] = []
    private var windows: [ManagedWindow] = []
    private var originals: [CGWindowID: ManagedWindow] = [:]
    private var floating = Set<CGWindowID>()
    private var visibleTiles = Set<CGWindowID>()
    private var floatingPreviewsEnabled = false
    private var floatingPreviews: FloatingPreviews?
    private var floatingPreviewTimer: Timer?
    private struct ExpandedWindow {
        let previousFrame: CGRect
        let previousDisplay: MacDisplay

        func floatingFrame(on display: MacDisplay) -> CGRect {
            let source = previousDisplay.fullFrame
            let destination = display.fullFrame
            if previousDisplay.id == display.id && source == destination { return previousFrame }
            return previousFrame.offsetBy(dx: destination.minX - source.minX, dy: destination.minY - source.minY)
                .fitted(to: display.visibleFrame)
        }
    }
    private var expanded: [CGWindowID: ExpandedWindow] = [:]
    private var modified = Set<CGWindowID>()
    private var lastTiled = Set<CGWindowID>()
    private var lastWrite: [CGWindowID: (requested: CGRect, observed: CGRect)] = [:]
    private var pendingSizeChecks: [CGWindowID: (requested: CGSize, prior: CGSize)] = [:]
    private var sizeCheckTimer: Timer?
    private static let dimensions: [WritableKeyPath<CGSize, CGFloat>] = [\.width, \.height]
    private var focused: CGWindowID?
    private var lastPointer: CGPoint?
    private var lastHoverWindow: CGWindowID?
    private var deferredHover: (window: CGWindowID, retryAt: TimeInterval)?
    private var hoverTimer: Timer?
    private var inventoryTimer: Timer?
    private var reflow = TileReflow()
    private var reflowTimer: Timer?
    private var reportedClosures = Set<CGWindowID>()
    private lazy var closeObserver = WindowCloseObserver { [weak self] id in
        guard let self, self.inventoryTimer?.isValid == true else { return }
        let needsRefresh = self.reportedClosures.isEmpty
        self.reportedClosures.insert(id)
        if needsRefresh {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.reportedClosures.isEmpty else { return }
                self.refresh()
            }
        }
    }
    private var lastPrune = Date.distantPast
    private var restoring: [CGWindowID: ManagedWindow] = [:]
    private var restoreTimer: Timer?
    var restorationPending: Bool { !restoring.isEmpty }

    private struct Drag {
        let window: ManagedWindow
        let source: MacDisplay
        let frame: CGRect
        var layout: DesktopLayout
        let pointer: CGPoint
        let tiled: Bool
        let corner: ResizeCorner
        var offset = CGSize.zero
        var detached: DesktopLayout?
        var landing: DesktopLayout?
        var neighborFrames: [CGWindowID: CGRect]?
        var moving = false
        var checkedDimensions: [CGWindowID: Set<WritableKeyPath<CGSize, CGFloat>>] = [:]
    }
    private var drag: Drag?

    private struct PinnedCursor {
        let window: ManagedWindow
        var display: MacDisplay
        let tiled: Bool
        let grip: WindowGrip
        var requestedFrame: CGRect
        var position: CGPoint
        var lastDestination: CGPoint?
        var releasedAt: TimeInterval?
        var settledFrame: CGRect?

        func canContinue(at point: CGPoint) -> Bool {
            guard let releasedAt, point == position, NSEvent.pressedMouseButtons == 0 else { return false }
            let elapsed = ProcessInfo.processInfo.systemUptime - releasedAt
            guard elapsed < 0.35 else { return false }
            return [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved].allSatisfy {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= elapsed
            }
        }
    }
    private var pinnedCursor: PinnedCursor?

    init(mac: MacWindows = MacWindows()) { self.mac = mac }
    var supportsWindowIdentity: Bool { mac.supportsWindowIdentity }

    func setLimits(_ limits: TileLimits) {
        guard layout.limits != limits else { return }
        cancelReflow()
        cancelDrag()
        pinnedCursor = nil
        let minimumSizes = layout.minimumSizes
        layout = DesktopLayout(limits: limits)
        layout.minimumSizes = minimumSizes
        if inventoryTimer?.isValid == true { refresh() }
    }

    func start() {
        inventoryTimer = timer(every: 0.55) { [weak self] in self?.refresh() }
        hoverTimer = timer(every: 0.045) { [weak self] in
            guard let self else { return }
            self.hover(at: self.mac.pointer)
        }
        refresh()
    }

    private func timer(every interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func suspend() {
        inventoryTimer?.invalidate()
        hoverTimer?.invalidate()
        lastHoverWindow = nil
        deferredHover = nil
        stopFloatingPreviews()
        cancelReflow()
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = nil
        pendingSizeChecks.removeAll()
        closeObserver.watch([])
        reportedClosures.removeAll()
        drag = nil
        pinnedCursor = nil
        mac.clear()
    }

    func stop() {
        suspend()
        for id in modified {
            guard let original = originals[id], mac.isAlive(original), !mac.isNativeFullscreen(original) else { continue }
            if !restore(original) { restoring[id] = original }
        }
        if !restoring.isEmpty {
            let deadline = Date().addingTimeInterval(6)
            restoreTimer = timer(every: 0.2) { [weak self] in self?.finishRestoring(deadline: deadline) }
        }
        layout = DesktopLayout(limits: layout.limits)
        windows = []
        originals = [:]
        modified = []
        lastTiled = []
        floating = []
        visibleTiles = []
        expanded = [:]
        lastWrite = [:]
        lastPointer = nil
        focused = nil
    }

    private func restore(_ window: ManagedWindow) -> Bool {
        guard mac.isResponsive(window) else { return false }
        let frame = window.frame
        let visible = mac.displays
        // A monitor may have been unplugged since this window was first tiled.
        let reachable = visible.contains { $0.visibleFrame.intersects(frame) }
        let target = reachable ? frame : visible.first.map { frame.fitted(to: $0.visibleFrame) } ?? frame
        if expanded[window.id] != nil,
           let display = DesktopLayout.screen(containing: target, in: visible) {
            mac.restoreExpandedFrame(target, of: window, on: display)
        } else {
            mac.setFrame(target, of: window)
        }
        return mac.currentFrame(of: window)?.approximatelyEquals(target) == true
    }

    private func finishRestoring(deadline: Date) {
        for (id, window) in restoring {
            guard mac.isAlive(window), !mac.isNativeFullscreen(window) else {
                restoring[id] = nil
                continue
            }
            if restore(window) { restoring[id] = nil }
        }
        if Date() >= deadline || restoring.isEmpty {
            restoring.removeAll()
            restoreTimer?.invalidate()
            restoreTimer = nil
        }
    }

    func spaceChanged() {
        guard inventoryTimer?.isValid == true else { return }
        stopFloatingPreviews()
        cancelReflow()
        pendingSizeChecks.removeAll()
        pinnedCursor = nil
        cancelDrag()
        lastPointer = mac.pointer
        lastHoverWindow = nil
        deferredHover = nil
        mac.outline(nil)
        refresh()
    }

    private func refresh() {
        guard drag == nil else { return }
        let previous = layout
        let previousWindows = windows
        let previousDisplays = screens
        screens = mac.displays
        windows = mac.inventory().filter { !reportedClosures.contains($0.id) }
        let visible = Set(windows.map(\.id))
        if pinnedCursor?.releasedAt != nil && visible != Set(previousWindows.map(\.id)) {
            // A changed inventory starts a different layout operation.
            pinnedCursor = nil
        }
        var closed = reportedClosures
        reportedClosures.removeAll()
        // Apps may retain a closed NSWindow and omit its AX destruction notification.
        // A tile that disappears from the same visible Space still leaves a gap.
        if previousWindows.contains(where: { !visible.contains($0.id) && !closed.contains($0.id) }) {
            let sameSpaces = previousDisplays.filter { old in
                screens.contains { SpaceKey($0) == SpaceKey(old) && $0.visibleFrame == old.visibleFrame }
            }
            let previousTiles = Set(sameSpaces.flatMap { previous.frames(on: $0).keys })
            for window in previousWindows where previousTiles.contains(window.id) && !visible.contains(window.id)
                && !closed.contains(window.id) && !mac.isNativeFullscreen(window) {
                closed.insert(window.id)
            }
        }
        for window in windows {
            if let original = originals[window.id], original.pid != window.pid || !CFEqual(original.element, window.element) {
                layout.minimumSizes[window.id] = nil
                lastWrite[window.id] = nil
                pendingSizeChecks[window.id] = nil
                originals[window.id] = window
            }
            if originals[window.id] == nil { originals[window.id] = window }
            if mac.isResponsive(window), var minimum = layout.minimumSizes[window.id] {
                // A changed document, sidebar or app mode can release its old minimum.
                for dimension in Self.dimensions where window.frame.size[keyPath: dimension] + 1 < minimum[keyPath: dimension] {
                    minimum[keyPath: dimension] = 0
                }
                layout.minimumSizes[window.id] = minimum == .zero ? nil : minimum
            }
        }
        // Expanded tiles stay in the tree. Their siblings can still close or
        // split, so returning to the tile uses its current rectangle.
        let tiles = windows.compactMap { window -> WindowPosition? in
            guard !floating.contains(window.id) else { return nil }
            return WindowPosition(id: window.id, frame: window.frame)
        }
        layout.reconcile(tiles, on: screens, focused: focused, pointer: mac.pointer)
        // A smaller grid can release a window on a Space visited earlier.
        // Restore it once, when that Space is visible. It then moves freely.
        let tiled = Set(screens.flatMap { layout.frames(on: $0).keys })
        visibleTiles = tiled
        for window in windows {
            if tiled.contains(window.id) { lastTiled.insert(window.id); continue }
            if lastTiled.remove(window.id) != nil, !floating.contains(window.id), expanded[window.id] == nil,
               let original = originals[window.id],
               let screen = DesktopLayout.screen(containing: window.frame, in: screens) {
                write(original.frame.fitted(to: screen.visibleFrame), window: window)
            }
        }
        closeObserver.watch(windows.filter { tiled.contains($0.id) && mac.isResponsive($0) })
        reflowAfterClose(closed, previous: previous, previousWindows: previousWindows)
        for window in windows where expanded[window.id] != nil {
            if let display = DesktopLayout.screen(containing: window.frame, in: screens) {
                apply(display.fullFrame, to: window, filling: display)
            }
        }
        let active = mac.focused(among: windows)
        focused = active?.id
        mac.outline(active.flatMap { mac.currentFrame(of: $0) })
        updateFloatingPreviews()
        if Date().timeIntervalSince(lastPrune) > 10 {
            lastPrune = Date()
            for (id, window) in originals where !visible.contains(id) && !mac.isAlive(window) {
                originals[id] = nil
                floating.remove(id)
                expanded[id] = nil
                modified.remove(id)
                lastTiled.remove(id)
                lastWrite[id] = nil
                layout.minimumSizes[id] = nil
                pendingSizeChecks[id] = nil
                layout.forget(id)
            }
        }
    }

    private func reflowAfterClose(_ closed: Set<CGWindowID>, previous: DesktopLayout, previousWindows: [ManagedWindow]) {
        var targets: [CGWindowID: CGRect] = [:]
        var animate = Set<CGWindowID>()
        let previousIDs = Set(previousWindows.map(\.id))
        for display in screens {
            let frames = layout.frames(on: display)
            targets.merge(frames) { _, new in new }
            guard !closed.isEmpty else { continue }
            let before = previous.frames(on: display)
            guard !closed.isDisjoint(with: before.keys) else { continue }
            for (id, target) in frames where previousIDs.contains(id) && before[id] != target {
                animate.insert(id)
            }
        }
        let observed = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        scheduleReflow(targets: targets, observed: observed, animate: animate)
    }

    private func scheduleReflow(targets: [CGWindowID: CGRect], observed: [CGWindowID: CGRect],
                                animate: Set<CGWindowID>) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelReflow()
            apply(frames: targets)
            return
        }
        let targets = targets.filter { expanded[$0.key] == nil && !reportedClosures.contains($0.key) }
        let immediate = reflow.reconcile(targets: targets, observed: observed, animate: animate,
                                         now: ProcessInfo.processInfo.systemUptime)
        apply(frames: immediate)
        if reflow.isEmpty {
            cancelReflow()
        } else if reflowTimer == nil {
            reflowTimer = timer(every: 1.0 / 60) { [weak self] in self?.stepReflow() }
        }
    }

    private func stepReflow() {
        let frames = reflow.sample(at: ProcessInfo.processInfo.systemUptime)
        for window in windows {
            guard let frame = frames[window.id], expanded[window.id] == nil,
                  !reportedClosures.contains(window.id), mac.isResponsive(window) else { continue }
            // setFrame checks the app's actual geometry before writing. Avoid
            // two extra AX reads per window on every intermediate tick.
            if reflow.isAnimating(window.id) { write(frame, window: window) }
            else { apply(frame, to: window) }
            if window.id == focused { mac.outline(mac.currentFrame(of: window)) }
        }
        if reflow.isEmpty { cancelReflow() }
    }

    private func cancelReflow(settle: Bool = false) {
        reflowTimer?.invalidate()
        reflowTimer = nil
        if settle { apply(frames: reflow.sample(at: .infinity)) }
        reflow = TileReflow()
    }

    private func apply(_ display: MacDisplay) {
        apply(frames: layout.frames(on: display))
    }

    private func apply(frames targets: [CGWindowID: CGRect]) {
        for window in windows {
            guard expanded[window.id] == nil, !reportedClosures.contains(window.id),
                  let target = targets[window.id] else { continue }
            apply(target, to: window)
        }
    }

    private func apply(_ target: CGRect, to window: ManagedWindow, filling display: MacDisplay? = nil) {
        guard mac.isResponsive(window) else { return }
        guard let actual = mac.currentFrame(of: window) else { return }
        if target.approximatelyEquals(actual) {
            lastWrite[window.id] = nil
            pendingSizeChecks[window.id] = nil
            return
        }
        // Apps can constrain a frame. Retry when the app or the target changes.
        if let last = lastWrite[window.id],
           last.requested == target && last.observed.approximatelyEquals(actual) { return }
        let wroteSize = write(target, window: window)
        guard var accepted = mac.currentFrame(of: window) else { return }
        if let display, !display.fullFrame.contains(accepted) {
            // Some apps reserve the menu bar but accept the physical display
            // height. Keep their bottom edge on this monitor.
            let clipped = display.fullFrame.intersection(accepted)
            if !clipped.isEmpty {
                mac.restoreExpandedFrame(clipped, of: window, on: display)
                accepted = mac.currentFrame(of: window) ?? accepted
            }
        }
        if !target.approximatelyEquals(accepted), wroteSize || actual.size == target.integral.size {
            lastWrite[window.id] = (target, accepted)
        }
        guard wroteSize, display == nil else { return }
        var requested = accepted.size
        for dimension in Self.dimensions {
            let desired = target.integral.size[keyPath: dimension]
            if desired + 1 < accepted.size[keyPath: dimension] {
                requested[keyPath: dimension] = desired
            }
        }
        if requested != accepted.size {
            pendingSizeChecks[window.id] = (requested, actual.size)
            if sizeCheckTimer == nil {
                sizeCheckTimer = timer(every: 0.08) { [weak self] in self?.confirmSizeLimits() }
            }
        }
    }

    @discardableResult
    private func write(_ frame: CGRect, window: ManagedWindow, afterExpansionOn display: MacDisplay? = nil) -> Bool {
        lastWrite[window.id] = nil
        pendingSizeChecks[window.id] = nil
        modified.insert(window.id)
        if let display {
            mac.restoreExpandedFrame(frame, of: window, on: display)
            return false
        }
        return mac.setFrame(frame, of: window)
    }

    private func confirmSizeLimits() {
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = nil
        let pending = pendingSizeChecks
        pendingSizeChecks.removeAll()
        let affectsPointer = drag?.moving != true && (pinnedCursor.map {
            $0.tiled && !Set(pending.keys).isDisjoint(with: layout.frames(on: $0.display).keys)
        } ?? false)
        var minima = layout.minimumSizes
        for window in windows {
            guard let check = pending[window.id], let last = lastWrite[window.id],
                  expanded[window.id] == nil, !floating.contains(window.id), !reportedClosures.contains(window.id)
            else { continue }
            guard let frame = mac.currentFrame(of: window), frame.approximatelyEquals(last.observed) else {
                lastWrite[window.id] = nil
                continue
            }

            var observed = frame
            if let display = DesktopLayout.screen(containing: last.requested, in: screens),
               !display.visibleFrame.insetBy(dx: 1, dy: 1).contains(frame) {
                // A window stuck against a display seam can report a false floor.
                mac.restoreExpandedFrame(last.requested, of: window, on: display)
                guard let settled = mac.currentFrame(of: window) else {
                    lastWrite[window.id] = nil
                    continue
                }
                observed = settled
            }
            var minimum = minima[window.id] ?? .zero
            var fitted = last.requested
            for dimension in Self.dimensions {
                let length = observed.size[keyPath: dimension]
                let desired = check.requested[keyPath: dimension]
                guard desired + 1 < length,
                      abs(length - last.observed.size[keyPath: dimension]) <= 1 else { continue }
                // A terminal can round two identical requests to the same text
                // cell. Step across a typical row or column before calling it a
                // floor. Limit the extra movement on small windows.
                var isolated = observed.size
                let step = min(48, max(24, 2 * (length - desired)))
                isolated[keyPath: dimension] = max(min(desired, 48), desired - step)
                guard mac.setSize(isolated, of: window), let result = mac.currentFrame(of: window) else {
                    lastWrite[window.id] = nil
                    break
                }
                if desired < check.prior[keyPath: dimension],
                   abs(result.width - observed.width) <= 1 && abs(result.height - observed.height) <= 1 {
                    var floor = length
                    if abs(length - check.prior[keyPath: dimension]) <= 1,
                       minimum[keyPath: dimension] + 1 < length {
                        // The first write never moved this edge. An app that
                        // ignores an undersized request can still accept sizes
                        // between the requested width and its current width.
                        guard let smallest = smallestAcceptedSize(of: window, along: dimension,
                                                                  refused: desired, from: result.size) else {
                            observed = mac.currentFrame(of: window) ?? result
                            lastWrite[window.id] = nil
                            break
                        }
                        floor = smallest
                    }
                    minimum[keyPath: dimension] = max(minimum[keyPath: dimension], floor)
                } else if result.size[keyPath: dimension] <= desired {
                    // Keep the largest accepted step inside the allocated tile.
                    var closer = observed.size
                    closer[keyPath: dimension] = max(result.size[keyPath: dimension], desired - (length - desired))
                    if mac.setSize(closer, of: window), let next = mac.currentFrame(of: window),
                       next.size[keyPath: dimension] <= desired {
                        fitted.size[keyPath: dimension] = next.size[keyPath: dimension]
                    } else {
                        fitted.size[keyPath: dimension] = result.size[keyPath: dimension]
                    }
                }
                observed = mac.currentFrame(of: window) ?? result
            }
            if minimum != .zero { minima[window.id] = minimum }
            if fitted != last.requested || !observed.approximatelyEquals(last.observed) {
                // Restore the tile after an axis-isolated request changed its geometry.
                mac.setFrame(fitted, of: window)
                if lastWrite[window.id] != nil {
                    lastWrite[window.id] = mac.currentFrame(of: window).map { (last.requested, $0) }
                }
            }
        }
        updateMinimumSizes(minima)
        if affectsPointer, let cursor = pinnedCursor {
            if let target = layout.frames(on: cursor.display)[cursor.window.id] {
                pinnedCursor?.requestedFrame = target
                followPinnedCursor(afterSizeCheck: true)
            } else {
                pinnedCursor = nil
            }
        }
    }

    /// The upper bound is an observed size. A successful write that leaves the
    /// edge there raises the lower bound. Transport failures establish neither.
    private func smallestAcceptedSize(of window: ManagedWindow, along dimension: WritableKeyPath<CGSize, CGFloat>,
                                      refused: CGFloat, from original: CGSize) -> CGFloat? {
        let other: WritableKeyPath<CGSize, CGFloat> = dimension == \.width ? \.height : \.width
        var lower = refused
        var upper = original[keyPath: dimension]
        for attempt in 0..<16 {
            guard upper - lower > 1 else { return upper }
            // An owner already at its floor narrows the search to at most 24pt
            // on the first write. Subsequent midpoints halve the remaining span.
            let half = floor((upper - lower) / 2)
            let trial = upper - max(1, attempt == 0 ? min(24, half) : half)
            var size = original
            size[keyPath: dimension] = trial
            guard mac.setSize(size, of: window), let measured = mac.currentFrame(of: window)?.size,
                  abs(measured[keyPath: other] - original[keyPath: other]) <= 1 else { return nil }
            let accepted = measured[keyPath: dimension]
            guard accepted > refused, accepted <= upper + 1 else { return nil }
            if accepted < upper {
                upper = accepted
            } else {
                lower = trial
            }
        }
        return upper - lower <= 1 ? upper : nil
    }

    private func updateMinimumSizes(_ minima: [CGWindowID: CGSize], replayResize: Bool = false) {
        guard minima != layout.minimumSizes else { return }
        let previousTiles = Set(frames(in: layout).keys)
        layout.minimumSizes = minima
        guard var current = drag else {
            refresh()
            return
        }
        let tiles = windows.filter { !floating.contains($0.id) && !reportedClosures.contains($0.id) }
            .map { WindowPosition(id: $0.id, frame: $0.frame) }
        layout.reconcile(tiles, on: screens, focused: focused, pointer: current.pointer)
        current.layout.minimumSizes = minima
        current.layout.reconcile(tiles, on: screens, focused: focused, pointer: current.pointer)
        current.detached = nil
        current.landing = nil
        drag = current
        if previousTiles != Set(frames(in: layout).keys) {
            // Releasing a tile to overflow changes the gesture's original tree.
            cancelDrag()
            refresh()
        } else if current.moving && current.tiled {
            moveTile(&current)
            drag = current
        } else {
            if replayResize {
                layout = current.layout
                layout.resize(current.window.id, corner: current.corner, by: current.offset, on: current.source)
            }
            apply(current.source)
        }
    }

    func setFloatingPreviewsEnabled(_ enabled: Bool) {
        guard floatingPreviewsEnabled != enabled else { return }
        floatingPreviewsEnabled = enabled
        if enabled { updateFloatingPreviews() }
        else { stopFloatingPreviews() }
    }

    private func updateFloatingPreviews() {
        guard floatingPreviewsEnabled, inventoryTimer?.isValid == true else { return }
        let visible = windows.filter { !reportedClosures.contains($0.id) }
        guard !visibleTiles.isEmpty, visible.contains(where: { !visibleTiles.contains($0.id) }) else {
            stopFloatingPreviews()
            return
        }
        if floatingPreviews == nil {
            floatingPreviews = FloatingPreviews(onHandoff: { [weak self] id in
                guard let self else { return }
                self.lastPointer = self.mac.pointer
                self.deferredHover = nil
                self.handoffPreview(id)
            }, onError: { [weak self] issue in
                self?.onFloatingPreviewIssue?(issue)
            })
        }
        floatingPreviews?.update(windows: visible, tiled: visibleTiles)
        if floatingPreviewTimer == nil {
            floatingPreviewTimer = timer(every: 0.09) { [weak self] in self?.updateFloatingPreviews() }
        }
    }

    private func stopFloatingPreviews() {
        floatingPreviewTimer?.invalidate()
        floatingPreviewTimer = nil
        floatingPreviews?.stop()
        floatingPreviews = nil
    }

    private func handoffPreview(_ id: CGWindowID) {
        guard floatingPreviewsEnabled, inventoryTimer?.isValid == true, drag == nil,
              !visibleTiles.contains(id), !reportedClosures.contains(id),
              let window = windows.first(where: { $0.id == id }), mac.isResponsive(window) else { return }
        mac.focus(window)
        focused = id
        mac.outline(mac.currentFrame(of: window))
    }

    private func interactionTarget(at point: CGPoint) -> (window: ManagedWindow, isPreview: Bool)? {
        if let id = floatingPreviews?.window(at: point) {
            return windows.first { $0.id == id }.map { ($0, true) }
        }
        return mac.window(at: point, among: windows).map { ($0, false) }
    }

    func hover(at point: CGPoint) {
        if pinnedCursor != nil {
            followPinnedCursor()
            if pinnedCursor != nil || drag != nil { return }
            // A settling warp can consume the sampled position before hit testing.
            if point != mac.pointer { return }
        }
        guard drag == nil && NSEvent.pressedMouseButtons == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard point != lastPointer || now >= (deferredHover?.retryAt ?? .infinity) else { return }
        lastPointer = point
        guard let target = interactionTarget(at: point) else {
            lastHoverWindow = nil
            deferredHover = nil
            return
        }
        let id = target.window.id
        let entered = lastHoverWindow != id
        lastHoverWindow = id
        if let deferredHover, deferredHover.window == id, now < deferredHover.retryAt { return }
        if !target.isPreview, focused == id {
            // A sheet can take focus between inventory ticks. Verify the cached
            // focus when entering a tile or returning to it after a blocked hover.
            if (!entered && deferredHover == nil) || mac.focusedID() == id {
                deferredHover = nil
                return
            }
        }
        guard !isRecordingShortcut(), mac.allowsHoverFocus(to: target.window) else {
            // Retry a stationary pointer after the user dismisses the panel or menu.
            deferredHover = (id, now + 0.2)
            return
        }
        deferredHover = nil
        if target.isPreview {
            floatingPreviews?.handoff(id)
            return
        }
        mac.focus(target.window)
        focused = id
        mac.outline(mac.currentFrame(of: target.window))
        updateFloatingPreviews()
    }

    func perform(_ action: WindowAction) {
        cancelReflow(settle: true)
        cancelDrag()
        deferredHover = nil
        pinnedCursor = nil
        guard let window = mac.focused(among: windows),
              let frame = mac.currentFrame(of: window),
              let display = DesktopLayout.screen(containing: frame, in: screens) else { return }
        switch action {
        case .float:
            lastWrite[window.id] = nil
            let previous = expanded.removeValue(forKey: window.id)
            if layout.contains(window.id, on: display) {
                let frame = (originals[window.id]?.frame ?? window.frame).fitted(to: display.visibleFrame)
                floating.insert(window.id)
                layout.forget(window.id)
                write(frame, window: window, afterExpansionOn: previous == nil ? nil : display)
                mac.focus(window)
            } else {
                if let previous {
                    write(previous.floatingFrame(on: display), window: window, afterExpansionOn: display)
                }
                floating.remove(window.id)
            }
            refresh()
            if !floating.contains(window.id) && !layout.contains(window.id, on: display) {
                onError?("The tile grid is full on this display. The window will tile when a slot opens.")
            }
        case .fullscreen:
            if let previous = expanded.removeValue(forKey: window.id) {
                let target = layout.frames(on: display)[window.id] ?? previous.floatingFrame(on: display)
                write(target, window: window, afterExpansionOn: display)
            } else {
                expanded[window.id] = ExpandedWindow(previousFrame: frame, previousDisplay: display)
                apply(display.fullFrame, to: window, filling: display)
            }
            mac.focus(window)
            mac.outline(mac.currentFrame(of: window))
            updateFloatingPreviews()
        }
    }

    func beginGesture(at point: CGPoint) {
        cancelDrag()
        deferredHover = nil
        let target = interactionTarget(at: point)
        if let target, target.isPreview { floatingPreviews?.handoff(target.window.id) }
        let hit = target?.window
        let window = gestureContinuation(at: point, hit: hit) ?? hit
        pinnedCursor = nil
        guard let window,
              expanded[window.id] == nil,
              let frame = mac.currentFrame(of: window),
              let screen = DesktopLayout.screen(containing: frame, in: screens) else { return }
        cancelReflow()
        drag = Drag(window: window, source: screen, frame: frame, layout: layout, pointer: point,
                    tiled: layout.contains(window.id, on: screen), corner: ResizeCorner(at: point, in: frame))
    }

    private func gestureContinuation(at point: CGPoint, hit: ManagedWindow?) -> ManagedWindow? {
        guard let cursor = pinnedCursor, let settled = cursor.settledFrame, cursor.canContinue(at: point),
              hit?.id != cursor.window.id, settled.contains(point),
              let window = windows.first(where: { $0.id == cursor.window.id && $0.pid == cursor.window.pid }),
              CFEqual(window.element, cursor.window.element), mac.currentFrame(of: window) == settled,
              DesktopLayout.screen(containing: settled, in: screens).map(SpaceKey.init) == SpaceKey(cursor.display),
              mac.focusedID() == window.id else { return nil }
        // WindowServer can still hit the neighbor's old frame after AX committed
        // the new divider. An overlapping window at its actual frame wins.
        if let hit {
            guard let frame = mac.currentFrame(of: hit), !frame.contains(point) else { return nil }
        }
        return window
    }

    private func pinCursor(to drag: Drag) {
        guard pinnedCursor == nil, let grip = WindowGrip(at: drag.pointer, in: drag.frame) else { return }
        pinnedCursor = PinnedCursor(window: drag.window, display: drag.source, tiled: drag.tiled,
                                    grip: grip, requestedFrame: drag.frame, position: mac.pointer)
        if mac.focusedID() != drag.window.id { mac.focus(drag.window) }
        focused = drag.window.id
    }

    func handle(_ event: TrackpadGesture) {
        switch event {
        case .began:
            if let cursor = pinnedCursor, cursor.canContinue(at: mac.pointer) {
                if cursor.tiled && !Set(pendingSizeChecks.keys).isDisjoint(with: layout.frames(on: cursor.display).keys) {
                    // The next scroll can arrive before the previous owner's
                    // size-confirmation timer. Finish that resize before hit testing.
                    confirmSizeLimits()
                }
                followPinnedCursor()
            }
            beginGesture(at: mac.pointer)
        case .move(let delta):
            guard var current = drag else { return }
            pinCursor(to: current)
            current.offset.width += delta.width
            current.offset.height += delta.height
            current.moving = true
            let requested = current.frame.offsetBy(dx: current.offset.width, dy: current.offset.height)
            pinnedCursor?.requestedFrame = requested
            mac.setPosition(requested.origin, of: current.window)
            lastWrite[current.window.id] = nil
            modified.insert(current.window.id)
            if current.tiled { moveTile(&current) }
            drag = current
            followPinnedCursor()
        case .resize(let delta):
            guard var current = drag else { return }
            pinCursor(to: current)
            current.offset.width += delta.width
            current.offset.height += delta.height
            drag = current
            let id = current.window.id
            if !current.tiled {
                var requested = current.corner.floatingFrame(from: current.frame, by: current.offset)
                write(requested, window: current.window)
                if let accepted = mac.currentFrame(of: current.window), accepted.size != requested.size {
                    // AX clients enforce their own minimum size. Preserve the
                    // fixed corner even if the app rejected our requested size.
                    requested = current.corner.frame(anchoredTo: current.frame, size: accepted.size)
                    write(requested, window: current.window)
                }
                pinnedCursor?.requestedFrame = requested
            } else {
                layout.resize(id, corner: current.corner, by: delta, on: current.source)
                apply(current.source)
                reconsiderSizes(during: &current)
                if let target = layout.frames(on: current.source)[id] { pinnedCursor?.requestedFrame = target }
            }
            followPinnedCursor()
        case .ended:
            guard var current = drag else { return }
            if current.moving && current.tiled {
                layout = current.landing ?? current.layout
                let finalFrames = frames(in: layout)
                if let target = finalFrames[current.window.id] {
                    pinnedCursor?.requestedFrame = target
                    apply(target, to: current.window)
                }
                moveNeighbors(to: finalFrames, drag: &current)
            }
            if current.moving, let target = pinnedCursor?.requestedFrame,
               let destination = DesktopLayout.screen(containing: target, in: screens) {
                pinnedCursor?.display = destination
                followPinnedCursor()
            }
            // Some AX owners commit the last write on their next run-loop turn.
            // Follow that final frame only while the user leaves the cursor alone.
            pinnedCursor?.releasedAt = ProcessInfo.processInfo.systemUptime
            drag = nil
            lastPointer = mac.pointer
            refresh()
            followPinnedCursor()
        case .cancelled: cancelDrag()
        }
    }

    private func followPinnedCursor(afterSizeCheck: Bool = false) {
        guard var cursor = pinnedCursor else { return }
        let pointer = mac.pointer
        if cursor.releasedAt != nil {
            guard cursor.canContinue(at: pointer) else {
                pinnedCursor = nil
                return
            }
            if cursor.settledFrame != nil && !afterSizeCheck { return }
        }
        guard !reportedClosures.contains(cursor.window.id), let frame = mac.currentFrame(of: cursor.window),
              let projected = cursor.grip.point(in: frame, on: screens) else { return }
        // WindowServer truncates a fractional warp toward zero, including on
        // displays above the main screen. Use the nearest reachable point.
        let destination = CGPoint(x: projected.x.rounded(), y: projected.y.rounded())
        let accepted = frame.approximatelyEquals(cursor.requestedFrame)
        // After lift, ignore unrelated window motion. A completed size check
        // can settle at an app-enforced size that differs from the request.
        guard cursor.releasedAt == nil || accepted || afterSizeCheck else { return }
        if pointer != destination && (cursor.lastDestination != destination || cursor.position != pointer) {
            guard mac.movePointer(to: destination) else { return }
            cursor.position = mac.pointer
        } else {
            cursor.position = pointer
        }
        cursor.lastDestination = destination
        lastPointer = cursor.position
        if cursor.releasedAt == nil { mac.outline(frame) }
        if cursor.releasedAt != nil && (accepted || afterSizeCheck) {
            let waiting = cursor.tiled && !pendingSizeChecks.isEmpty
                && !Set(pendingSizeChecks.keys).isDisjoint(with: layout.frames(on: cursor.display).keys)
            cursor.settledFrame = waiting ? nil : frame
        }
        pinnedCursor = cursor
    }

    /// An app can relax its minimum without resizing its current window. Try
    /// the user's intended size once per axis when a new drag pushes past it.
    private func reconsiderSizes(during current: inout Drag) {
        let minima = layout.minimumSizes
        guard !minima.isEmpty else { return }
        let tiles = layout.frames(on: current.source)
        let constrained = windows.filter { window in
            guard let minimum = minima[window.id], let tile = tiles[window.id], expanded[window.id] == nil
            else { return false }
            return Self.dimensions.contains { dimension in
                minimum[keyPath: dimension] > 0 && tile.size[keyPath: dimension] <= minimum[keyPath: dimension] + 1
                    && current.checkedDimensions[window.id]?.contains(dimension) != true
            }
        }
        guard !constrained.isEmpty else { return }
        let start = current.layout.frames(on: current.source)
        var unconstrained = current.layout
        unconstrained.minimumSizes = [:]
        let before = unconstrained.frames(on: current.source)
        unconstrained.resize(current.window.id, corner: current.corner, by: current.offset, on: current.source)
        let after = unconstrained.frames(on: current.source)
        var updated = minima
        for window in constrained {
            guard var minimum = minima[window.id], let tile = tiles[window.id], let initial = start[window.id],
                  let from = before[window.id], let to = after[window.id] else { continue }
            var intended = tile.size
            for dimension in Self.dimensions where minimum[keyPath: dimension] > 0
                && current.checkedDimensions[window.id]?.contains(dimension) != true {
                let delta = to.size[keyPath: dimension] - from.size[keyPath: dimension]
                let requested = max(1, initial.size[keyPath: dimension] + delta)
                // A deliberate move past the edge also distinguishes a floor
                // from a window that simply rounds sizes to a text row or column.
                if delta < 0, tile.size[keyPath: dimension] <= minimum[keyPath: dimension] + 1,
                   requested + 16 < minimum[keyPath: dimension] {
                    intended[keyPath: dimension] = requested
                    current.checkedDimensions[window.id, default: []].insert(dimension)
                }
            }
            guard intended != tile.size, let actual = mac.currentFrame(of: window) else { continue }
            var requested = actual.size
            for dimension in Self.dimensions where intended[keyPath: dimension] != tile.size[keyPath: dimension] {
                requested[keyPath: dimension] = intended[keyPath: dimension]
            }
            guard mac.setSize(requested, of: window), let accepted = mac.currentFrame(of: window) else { continue }
            for dimension in Self.dimensions where accepted.size[keyPath: dimension] + 1 < minimum[keyPath: dimension] {
                minimum[keyPath: dimension] = 0
            }
            updated[window.id] = minimum == .zero ? nil : minimum
            if updated[window.id] == minima[window.id], !accepted.approximatelyEquals(tile) {
                mac.setFrame(tile, of: window)
            }
        }
        drag = current
        updateMinimumSizes(updated, replayResize: true)
    }

    private func moveTile(_ drag: inout Drag) {
        if drag.detached == nil {
            drag.detached = drag.layout
            drag.detached?.detach(drag.window.id, from: drag.source)
        }
        guard let detached = drag.detached else { return }
        let point = CGPoint(x: drag.pointer.x + drag.offset.width, y: drag.pointer.y + drag.offset.height)
        let destination = DesktopLayout.screen(nearest: point, in: screens) ?? drag.source
        var candidate = detached
        // Hit-test the detached tree on every update. Reflowing a neighbor
        // cannot move its own hit target out from under a stationary finger.
        if SpaceKey(destination) == SpaceKey(drag.source), drag.frame.contains(point) {
            drag.landing = drag.layout
        } else if candidate.attachDragged(drag.window.id, at: point, on: destination) {
            drag.landing = candidate
        } else {
            drag.landing = nil
        }
        moveNeighbors(to: frames(in: candidate), drag: &drag)
    }

    private func frames(in layout: DesktopLayout) -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for screen in screens {
            frames.merge(layout.frames(on: screen)) { _, replacement in replacement }
        }
        return frames
    }

    private func moveNeighbors(to targets: [CGWindowID: CGRect], drag: inout Drag) {
        var neighbors = targets
        neighbors[drag.window.id] = nil
        guard neighbors != drag.neighborFrames else { return }
        // Capture the live starting frame only when a window's destination changes.
        // Repeated swipe samples toward the same slot keep the current animation.
        var observed: [CGWindowID: CGRect] = [:]
        for window in windows {
            guard let target = neighbors[window.id], drag.neighborFrames?[window.id] != target,
                  expanded[window.id] == nil, !reportedClosures.contains(window.id) else { continue }
            observed[window.id] = mac.currentFrame(of: window)
        }
        scheduleReflow(targets: neighbors, observed: observed, animate: Set(observed.keys))
        drag.neighborFrames = neighbors
    }

    private func cancelDrag() {
        guard let current = drag else { return }
        cancelReflow()
        drag = nil
        layout = current.layout
        write(current.frame, window: current.window)
        for screen in screens { apply(screen) }
        followPinnedCursor()
        pinnedCursor = nil
        mac.outline(nil)
    }
}
