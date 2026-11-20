import AppKit
import CoreMedia
import IOSurface
import ScreenCaptureKit

/// Only the parts of a floating window covered by tiles need a preview.
/// A dialog or another floating window keeps its own visible pixels and hit targets.
func subtract(_ cover: CGRect, from frame: CGRect) -> [CGRect] {
    let cut = frame.intersection(cover)
    guard !cut.isEmpty else { return [frame] }
    return [
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: cut.minY - frame.minY),
        CGRect(x: frame.minX, y: cut.maxY, width: frame.width, height: frame.maxY - cut.maxY),
        CGRect(x: frame.minX, y: cut.minY, width: cut.minX - frame.minX, height: cut.height),
        CGRect(x: cut.maxX, y: cut.minY, width: frame.maxX - cut.maxX, height: cut.height)
    ].filter { !$0.isEmpty }
}

private struct PreviewArea: Equatable {
    let pid: pid_t
    let frame: CGRect
    let pieces: [CGRect]
}

final class FloatingPreviews {
    private let onHandoff: (CGWindowID) -> Void
    private let onError: (String?) -> Void
    private var desired: [CGWindowID: PreviewArea] = [:]
    private var previews: [CGWindowID: FloatingPreview] = [:]
    private var lookup: Task<Void, Never>?
    private var retryAfter: [CGWindowID: TimeInterval] = [:]
    private var issue: String?

    init(onHandoff: @escaping (CGWindowID) -> Void, onError: @escaping (String?) -> Void = { _ in }) {
        self.onHandoff = onHandoff
        self.onError = onError
    }

    static func panelTitle(for window: CGWindowID) -> String { "TouchTiles floating preview \(window)" }

    static func isShareable(_ state: NSNumber?) -> Bool {
        switch state?.uint32Value {
        case CGWindowSharingType.readOnly.rawValue, CGWindowSharingType.readWrite.rawValue: return true
        default: return false
        }
    }

    func update(windows: [ManagedWindow], tiled: Set<CGWindowID>) {
        let floats = Set(windows.map(\.id)).subtracting(tiled)
        guard !floats.isEmpty, !tiled.isEmpty else {
            stop()
            return
        }
        // Core Graphics supplies geometry and z order without capturing screen pixels.
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var inFront: [(id: CGWindowID, frame: CGRect)] = []
        var next: [CGWindowID: PreviewArea] = [:]
        for row in rows {
            guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (0...NSWindow.Level.floating.rawValue).contains(layer),
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty else { continue }
            if pid == getpid(),
               NSApp.window(withWindowNumber: Int(id))?.ignoresMouseEvents == true
                || previews.values.contains(where: { $0.ownsVisiblePanel(Int(id)) }) { continue }
            if floats.contains(id), Self.isShareable(row[kCGWindowSharingState as String] as? NSNumber) {
                // The float order is independent of the tiles. Preserve higher floats
                // even when one tiled window currently obscures both of them.
                var remaining = [frame]
                for peer in inFront where floats.contains(peer.id) && peer.frame.intersects(frame) {
                    remaining = remaining.flatMap { subtract(peer.frame, from: $0) }
                }
                var pieces: [CGRect] = []
                for cover in inFront where cover.frame.intersects(frame) && !remaining.isEmpty {
                    if tiled.contains(cover.id) {
                        pieces += remaining.map { $0.intersection(cover.frame) }.filter { !$0.isEmpty }
                    }
                    remaining = remaining.flatMap { subtract(cover.frame, from: $0) }
                }
                if !pieces.isEmpty { next[id] = PreviewArea(pid: pid, frame: frame, pieces: pieces) }
            }
            inFront.append((id, frame))
        }
        desired = next
        for (id, preview) in previews where next[id]?.pid != preview.area.pid {
            preview.stop()
            previews[id] = nil
        }
        retryAfter = retryAfter.filter { next[$0.key] != nil }
        for (id, preview) in previews {
            if let area = next[id], area != preview.area { preview.update(area) }
        }
        if next.isEmpty { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let missing = next.filter { previews[$0.key] == nil && (retryAfter[$0.key] ?? 0) <= now }
        guard !missing.isEmpty, lookup == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // The Settings permission monitor stops active streams on revocation.
            // A denied stream must never reach content enumeration.
            for id in missing.keys { retryAfter[id] = now + 2 }
            return
        }
        lookup = Task { @MainActor [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard !Task.isCancelled, let self else { return }
                self.lookup = nil
                for (id, request) in missing {
                    guard let area = self.desired[id], area.pid == request.pid, self.previews[id] == nil else { continue }
                    guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == area.pid }) else {
                        self.failed(id)
                        continue
                    }
                    let preview = FloatingPreview(window: window, area: area, handoff: { [weak self] in
                        self?.handoff(id)
                    }, ready: { [weak self] session in
                        guard let self, self.previews[id] === session else { return }
                        self.retryAfter[id] = nil
                        if self.retryAfter.isEmpty { self.report(nil) }
                    }, failed: { [weak self] session in
                        guard let self, self.previews[id] === session else { return }
                        session.stop()
                        self.previews[id] = nil
                        self.failed(id)
                    })
                    self.previews[id] = preview
                    preview.start()
                }
                if self.retryAfter.isEmpty { self.report(nil) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.lookup = nil
                for id in missing.keys where self.desired[id] != nil { self.failed(id) }
            }
        }
    }

    func window(at point: CGPoint) -> CGWindowID? {
        let coordinates = DesktopCoordinates(primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        let number = NSWindow.windowNumber(at: coordinates.flip(point), belowWindowWithWindowNumber: 0)
        return previews.first { $0.value.ownsVisiblePanel(number) }?.key
    }

    func stop() {
        lookup?.cancel()
        lookup = nil
        for preview in previews.values { preview.stop() }
        previews.removeAll()
        desired.removeAll()
        retryAfter.removeAll()
        report(nil)
    }

    func handoff(_ id: CGWindowID) {
        guard let preview = previews.removeValue(forKey: id) else { return }
        preview.stop()
        // Give WindowServer time to raise the native window before looking for occlusion again.
        retryAfter[id] = ProcessInfo.processInfo.systemUptime + 0.3
        onHandoff(id)
    }

    private func failed(_ id: CGWindowID) {
        retryAfter[id] = ProcessInfo.processInfo.systemUptime + 5
        report("macOS couldn’t share a floating window. TouchTiles will retry while it’s covered.")
    }

    private func report(_ message: String?) {
        guard issue != message else { return }
        issue = message
        onError(message)
    }
}

private final class FloatingPreview: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var area: PreviewArea
    private let window: SCWindow
    private let handoff: () -> Void
    private let ready: (FloatingPreview) -> Void
    private let failed: (FloatingPreview) -> Void
    private var stream: SCStream?
    private var stopped = false
    private var panels: [PreviewPanel] = []
    private var buffer: CVPixelBuffer?
    private var contentRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(window: SCWindow, area: PreviewArea, handoff: @escaping () -> Void, ready: @escaping (FloatingPreview) -> Void,
         failed: @escaping (FloatingPreview) -> Void) {
        self.window = window
        self.area = area
        self.handoff = handoff
        self.ready = ready
        self.failed = failed
    }

    func start() {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
        config.width = max(1, Int(ceil(area.frame.width * scale)))
        config.height = max(1, Int(ceil(area.frame.height * scale)))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
        }
        let source = SCStream(filter: filter, configuration: config, delegate: self)
        stream = source
        do {
            try source.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        } catch { failed(self); return }
        source.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else {
                    if error == nil { source.stopCapture { _ in } }
                    return
                }
                if error != nil { self.failed(self) }
            }
        }
    }

    func update(_ area: PreviewArea) {
        self.area = area
        if buffer != nil { present() }
    }

    func ownsVisiblePanel(_ number: Int) -> Bool {
        panels.contains { $0.isVisible && $0.windowNumber == number }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.failed(self)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sampleBuffer.isValid,
              let frames = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]],
              let metadata = frames.first, let status = metadata[.status] as? Int else { return }
        if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.stopped.rawValue {
            for panel in panels { panel.clearFrame() }
            buffer = nil
            return
        }
        guard status == SCFrameStatus.complete.rawValue, let pixelBuffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else { return }
        let firstFrame = buffer == nil
        buffer = pixelBuffer
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        contentRect = unit
        if let dict = metadata[.contentRect] as? NSDictionary,
           let content = CGRect(dictionaryRepresentation: dict),
           let scale = metadata[.scaleFactor] as? CGFloat, !content.isEmpty {
            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let crop = CGRect(x: content.minX * scale / w, y: content.minY * scale / h,
                             width: content.width * scale / w, height: content.height * scale / h)
                .intersection(unit)
            if !crop.isEmpty { contentRect = crop }
        }
        present()
        if firstFrame { ready(self) }
    }

    private func present() {
        guard let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let coordinates = DesktopCoordinates(primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        while panels.count > area.pieces.count {
            let panel = panels.removeLast()
            panel.clearFrame()
            panel.close()
        }
        for (index, piece) in area.pieces.enumerated() {
            if index == panels.count {
                panels.append(PreviewPanel(title: FloatingPreviews.panelTitle(for: window.windowID), handoff: handoff))
            }
            let crop = CGRect(x: contentRect.minX + contentRect.width * (piece.minX - area.frame.minX) / area.frame.width,
                              y: contentRect.minY + contentRect.height * (piece.minY - area.frame.minY) / area.frame.height,
                              width: contentRect.width * piece.width / area.frame.width,
                              height: contentRect.height * piece.height / area.frame.height)
            panels[index].present(surface, crop: crop, frame: coordinates.flip(piece))
        }
    }

    func stop() {
        stopped = true
        for panel in panels { panel.clearFrame(); panel.close() }
        panels.removeAll()
        buffer = nil
        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
            stream.stopCapture { _ in }
        }
        stream = nil
    }
}

private final class PreviewPanel: NSPanel {
    private let handoff: () -> Void

    init(title: String, handoff: @escaping () -> Void) {
        self.handoff = handoff
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        isOpaque = false
        colorSpace = .sRGB
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Draw over tiles and leave native floating panels above the preview.
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let view = NSView()
        view.wantsLayer = true
        contentView = view
    }

    func present(_ surface: IOSurfaceRef, crop: CGRect, frame: CGRect) {
        let reveal = !isVisible
        if self.frame != frame || reveal { setFrame(frame, display: true) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView?.layer?.contentsRect = crop
        contentView?.layer?.contents = surface
        CATransaction.commit()
        if reveal { orderFrontRegardless() }
    }

    func clearFrame() {
        orderOut(nil)
        contentView?.layer?.contents = nil
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: handoff()
        default: super.sendEvent(event)
        }
    }
    override func accessibilityPerformPress() -> Bool { handoff(); return true }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
