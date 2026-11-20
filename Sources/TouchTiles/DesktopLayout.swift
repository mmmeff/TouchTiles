import CoreGraphics

struct SpaceKey: Hashable {
    let display: CGDirectDisplayID
    let space: UInt64?

    init(_ screen: MacDisplay) {
        display = screen.id
        space = screen.space
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = max(0, minX - point.x, point.x - maxX)
        let dy = max(0, minY - point.y, point.y - maxY)
        return dx * dx + dy * dy
    }

    func approximatelyEquals(_ other: CGRect) -> Bool {
        abs(minX - other.minX) <= 1 && abs(minY - other.minY) <= 1
            && abs(width - other.width) <= 1 && abs(height - other.height) <= 1
    }

    func fitted(to bounds: CGRect) -> CGRect {
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        return CGRect(x: max(bounds.minX, min(minX, bounds.maxX - w)),
                      y: max(bounds.minY, min(minY, bounds.maxY - h)), width: w, height: h)
    }
}

struct WindowPosition {
    let id: CGWindowID
    let frame: CGRect
}

/// Inactive Spaces keep their tree. Only the displays in a snapshot may lose leaves.
struct DesktopLayout {
    let limits: TileLimits
    private var trees: [SpaceKey: Dwindle] = [:]
    private var waiting: [SpaceKey: [CGWindowID]] = [:]
    var minimumSizes: [CGWindowID: CGSize] = [:] {
        didSet {
            for key in trees.keys { trees[key]?.minimumSizes = minimumSizes }
        }
    }

    init(limits: TileLimits = TileLimits()) { self.limits = limits }

    static func screen(nearest point: CGPoint, in displays: [MacDisplay]) -> MacDisplay? {
        displays.first { $0.fullFrame.contains(point) } ?? displays.min {
            $0.fullFrame.distanceSquared(to: point) < $1.fullFrame.distanceSquared(to: point)
        }
    }

    static func screen(containing frame: CGRect, in displays: [MacDisplay]) -> MacDisplay? {
        func area(_ screen: MacDisplay) -> CGFloat {
            let overlap = screen.fullFrame.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let display = displays.max(by: { area($0) < area($1) }), area(display) > 0 { return display }
        return screen(nearest: frame.center, in: displays)
    }

    mutating func reconcile(_ windows: [WindowPosition], on displays: [MacDisplay],
                            focused: CGWindowID?, pointer: CGPoint) {
        let assignments = Dictionary(grouping: windows) { window in
            Self.screen(containing: window.frame, in: displays).map(SpaceKey.init)
        }
        for display in displays {
            let key = SpaceKey(display)
            let here = assignments[key] ?? []
            let visible = Set(here.map(\.id))
            var tree = trees[key] ?? Dwindle(limits: limits, minimumSizes: minimumSizes)
            for id in tree.ids where !visible.contains(id) { tree.remove(id) }
            // Keep the largest prefix of the old tree that fits. Retry its
            // displaced leaves first, including the other split direction.
            var displaced: [CGWindowID] = []
            for id in tree.ids.reversed() {
                guard !tree.fits(in: display.visibleFrame) else { break }
                tree.remove(id)
                displaced.append(id)
            }
            var queue = Array(displaced.reversed())
            var known = Set(tree.ids).union(queue)
            for id in waiting[key] ?? [] where visible.contains(id) && known.insert(id).inserted {
                queue.append(id)
            }
            for window in here.reversed() where known.insert(window.id).inserted {
                queue.append(window.id)
            }
            // macOS cannot tell us the historical focus order of windows that
            // were open before tiling started. Subdivide the largest cell when
            // adopting a batch, then resume Dwindle's normal focused insertion.
            let adopting = tree.ids.isEmpty && here.count > 2
            var target = focused
            var overflow: [CGWindowID] = []
            for id in queue {
                if adopting { target = tree.largestTile(in: display.visibleFrame) }
                if tree.insert(id, near: target, at: pointer, in: display.visibleFrame) {
                    target = id
                } else {
                    overflow.append(id)
                }
            }
            trees[key] = tree.ids.isEmpty ? nil : tree
            waiting[key] = overflow.isEmpty ? nil : overflow
        }
    }

    func frames(on display: MacDisplay) -> [CGWindowID: CGRect] {
        trees[SpaceKey(display)]?.frames(in: display.visibleFrame) ?? [:]
    }

    func contains(_ id: CGWindowID, on display: MacDisplay) -> Bool {
        trees[SpaceKey(display)]?.ids.contains(id) == true
    }

    mutating func resize(_ id: CGWindowID, corner: ResizeCorner, by delta: CGSize, on display: MacDisplay) {
        trees[SpaceKey(display)]?.resize(id, corner: corner, by: delta, in: display.visibleFrame)
    }

    mutating func detach(_ id: CGWindowID, from display: MacDisplay) {
        let key = SpaceKey(display)
        trees[key]?.remove(id)
        if trees[key]?.ids.isEmpty == true { trees.removeValue(forKey: key) }
    }

    @discardableResult
    mutating func attachDragged(_ id: CGWindowID, at point: CGPoint, on display: MacDisplay) -> Bool {
        let key = SpaceKey(display)
        var tree = trees[key] ?? Dwindle(limits: limits, minimumSizes: minimumSizes)
        let target = tree.frames(in: display.visibleFrame).min {
            let a = $0.value.distanceSquared(to: point), b = $1.value.distanceSquared(to: point)
            return a == b ? $0.key < $1.key : a < b
        }?.key
        guard tree.insertDragged(id, near: target, at: point, in: display.visibleFrame) else { return false }
        trees[key] = tree
        return true
    }

    mutating func forget(_ id: CGWindowID) {
        for key in Array(trees.keys) where trees[key]?.ids.contains(id) == true {
            trees[key]?.remove(id)
            if trees[key]?.ids.isEmpty == true { trees.removeValue(forKey: key) }
        }
        for key in Array(waiting.keys) {
            waiting[key]?.removeAll { $0 == id }
            if waiting[key]?.isEmpty == true { waiting.removeValue(forKey: key) }
        }
    }

}
