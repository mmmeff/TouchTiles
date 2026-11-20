import Cocoa

private final class ColorGrid: NSView {
    override var isFlipped: Bool { true }
    var changing: NSColor = .red { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width / 2, height = bounds.height / 2
        for (column, row, color) in [(0, 0, changing), (1, 0, .yellow), (0, 1, .green), (1, 1, .magenta)] {
            color.setFill()
            NSRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height).fill()
        }
    }
}

final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    private var widthIncrement: CGFloat?
    private var refusedWidthBelow: CGFloat?
    private var lastAcceptedWidth: CGFloat = 0
    private var nativeSurface: NSWindow?
    private var openMenu: NSMenu?

    // Exercise the two AX readbacks that native minSize cannot produce:
    // a snapped text column, and a successful write that preserves the old width.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        var frame = window.frame
        let accepted: CGFloat
        if let floor = refusedWidthBelow, frame.width < floor {
            accepted = lastAcceptedWidth
        } else if let widthIncrement {
            accepted = ceil(frame.width / widthIncrement) * widthIncrement
        } else {
            accepted = frame.width
        }
        lastAcceptedWidth = accepted
        guard accepted != frame.width else { return }
        frame.size.width = accepted
        window.setFrame(frame, display: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = Int(ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_WINDOWS"] ?? "") ?? 2
        let minimums = (ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_MINIMUMS"] ?? "")
            .split(separator: ";").map { entry -> CGSize in
                let sides = entry.split(separator: "x").compactMap { Int($0) }
                precondition(sides.count == 2)
                return CGSize(width: sides[0], height: sides[1])
            }
        for index in 0..<count {
            let offset = index * 160
            let frame = NSRect(x: 45 + offset, y: 85 + offset, width: 300, height: 210)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "TouchTiles frame verification \(index + 1)"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = .fullScreenPrimary
            if index == 0, let raw = ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_WIDTH_INCREMENT"],
               let increment = Int(raw), increment > 1 {
                widthIncrement = CGFloat(increment)
                window.delegate = self
            }
            if index == 0, let raw = ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_REFUSE_WIDTH_BELOW"],
               let minimum = Int(raw), minimum > 0 {
                refusedWidthBelow = CGFloat(minimum)
                var initial = window.frame
                initial.size.width = CGFloat(minimum + 101)
                window.setFrame(initial, display: false)
                lastAcceptedWidth = window.frame.width
                window.delegate = self
            }
            if minimums.indices.contains(index) {
                window.minSize = minimums[index]
                var initial = window.frame
                initial.size.width = max(initial.width, window.minSize.width)
                initial.size.height = max(initial.height, window.minSize.height)
                window.setFrame(initial, display: false)
            }
            if ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_PROTECTED"] == "1" {
                window.sharingType = .none
            }
            if ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_COLORS"] == "1" {
                window.contentView = ColorGrid(frame: window.contentView?.bounds ?? .zero)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        if ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_COLORS"] == "1"
            || ProcessInfo.processInfo.environment["TOUCHTILES_FIXTURE_SURFACES"] == "1" {
            FileHandle.standardInput.readabilityHandler = { [weak self] input in
                let data = input.availableData
                guard !data.isEmpty else { input.readabilityHandler = nil; return }
                let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                guard fields.count == 2, let number = Int(fields[0]) else { return }
                let command = String(fields[1])
                RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
                    guard let self, let window = self.windows.first(where: { $0.windowNumber == number }) else { return }
                    self.perform(command, on: window)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in NSApp.terminate(nil) }
    }

    private func perform(_ command: String, on window: NSWindow) {
        let rect = NSRect(x: window.frame.minX + 24, y: window.frame.minY + 40, width: 180, height: 104)
        switch command {
        case "blue", "red":
            (window.contentView as? ColorGrid)?.changing = command == "red" ? .red : .blue
        case "focus":
            window.makeKeyAndOrderFront(nil)
        case "panel":
            let panel = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Fixture utility panel"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = true
            nativeSurface = panel
            panel.makeKeyAndOrderFront(nil)
        case "sheet":
            let sheet = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = "Fixture document sheet"
            sheet.isReleasedWhenClosed = false
            nativeSurface = sheet
            window.beginSheet(sheet, completionHandler: nil)
        case "menu":
            guard let view = window.contentView else { return }
            let menu = NSMenu(title: "Fixture context menu")
            menu.autoenablesItems = false
            for index in 1...6 {
                menu.addItem(withTitle: "Fixture menu command \(index)", action: nil, keyEquivalent: "")
            }
            openMenu = menu
            menu.popUp(positioning: nil, at: CGPoint(x: 24, y: view.bounds.midY), in: view)
            openMenu = nil
        case "dismiss":
            if let openMenu {
                openMenu.cancelTracking()
                return
            }
            guard let surface = nativeSurface else { return }
            if let parent = surface.sheetParent { parent.endSheet(surface) }
            surface.orderOut(nil)
            nativeSurface = nil
        default: break
        }
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.setActivationPolicy(.regular)
app.delegate = fixture
app.run()
