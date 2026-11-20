import CoreGraphics

/// Fractions of the accepted window frame in Quartz coordinates.
struct WindowGrip {
    private let fraction: CGPoint

    init?(at point: CGPoint, in frame: CGRect) {
        guard Self.hasUsableBounds(frame), point.x.isFinite, point.y.isFinite else { return nil }
        let x = min(frame.maxX, max(frame.minX, point.x))
        let y = min(frame.maxY, max(frame.minY, point.y))
        fraction = CGPoint(x: (x - frame.minX) / frame.width, y: (y - frame.minY) / frame.height)
    }

    func point(in frame: CGRect) -> CGPoint? {
        guard Self.hasUsableBounds(frame) else { return nil }
        let projected = CGPoint(x: frame.minX + frame.width * fraction.x,
                                y: frame.minY + frame.height * fraction.y)
        return Self.fit(projected, inside: quarter(of: frame))
    }

    func point(in frame: CGRect, on displays: [MacDisplay]) -> CGPoint? {
        guard let projected = point(in: frame) else { return nil }
        // A floating window can extend beyond one display or span a gap.
        for bounds in [quarter(of: frame), frame] {
            let visible = displays.map { bounds.intersection($0.fullFrame) }.filter {
                !$0.isEmpty && ceil($0.minX) < $0.maxX && ceil($0.minY) < $0.maxY
            }
            if let nearest = visible.min(by: { $0.distanceSquared(to: projected) < $1.distanceSquared(to: projected) }) {
                return Self.fit(projected, inside: nearest)
            }
        }
        return nil
    }

    private func quarter(of frame: CGRect) -> CGRect {
        CGRect(x: fraction.x < 0.5 ? frame.minX : frame.midX,
               y: fraction.y < 0.5 ? frame.minY : frame.midY,
               width: frame.width / 2, height: frame.height / 2)
    }

    private static func fit(_ point: CGPoint, inside bounds: CGRect) -> CGPoint {
        func coordinate(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
            // Keep a rounded cursor inside the half-open interval at dividers
            // and trailing edges. Interior coordinates stay fractional.
            let first = ceil(lower), last = ceil(upper) - 1
            if first <= last { return min(last, max(first, value)) }
            return min(upper.nextDown, max(lower, value))
        }
        return CGPoint(x: coordinate(point.x, from: bounds.minX, to: bounds.maxX),
                       y: coordinate(point.y, from: bounds.minY, to: bounds.maxY))
    }

    private static func hasUsableBounds(_ frame: CGRect) -> Bool {
        !frame.isInfinite && frame.size.width > 0 && frame.size.height > 0
            && frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
    }
}

/// Window and pointer coordinates share Quartz's top-left origin.
struct ResizeCorner {
    let left: Bool
    let top: Bool

    init(at point: CGPoint, in frame: CGRect) {
        left = point.x < frame.midX
        top = point.y < frame.midY
    }

    func frame(anchoredTo original: CGRect, size: CGSize) -> CGRect {
        CGRect(x: left ? original.maxX - size.width : original.minX,
               y: top ? original.maxY - size.height : original.minY,
               width: size.width, height: size.height)
    }

    func floatingFrame(from original: CGRect, by delta: CGSize) -> CGRect {
        let width = max(1, original.width + (left ? -delta.width : delta.width))
        let height = max(1, original.height + (top ? -delta.height : delta.height))
        return frame(anchoredTo: original, size: CGSize(width: width, height: height))
    }
}

struct TileLimits: Equatable {
    let rows: Int
    let columns: Int

    init(rows: Int = 2, columns: Int = 8) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
    }
}

/// A Dwindle tree for one display. Coordinates increase towards the bottom right.
/// Nodes retain their split direction when the display or an ancestor resizes.
struct Dwindle {
    private enum Axis {
        case width
        case height

        func length(of size: CGSize) -> CGFloat {
            switch self {
            case .width: return size.width
            case .height: return size.height
            }
        }
    }

    private struct Split {
        let axis: Axis
        var firstShare: CGFloat = 0.5
        var firstMinimum: CGFloat = 0
        var secondMinimum: CGFloat = 0

        func distance(for share: CGFloat, in extent: CGFloat) -> CGFloat {
            min(extent - secondMinimum, max(firstMinimum, extent * share))
        }

        func divide(_ bounds: CGRect) -> (first: CGRect, second: CGRect) {
            let distance = distance(for: firstShare, in: axis.length(of: bounds.size))
            let edge: CGRectEdge = axis == .width ? .minXEdge : .minYEdge
            let (first, second) = bounds.divided(atDistance: distance, from: edge)
            return (first, second)
        }
    }

    private struct BranchStep {
        let axis: Axis
        let first: Bool
        let divider: CGFloat
    }

    /// A display edge has two gap units. Each side of an interior divider has one.
    private struct Margins {
        var left = 2, right = 2, top = 2, bottom = 2

        func divided(along axis: Axis) -> (Margins, Margins) {
            var first = self, second = self
            switch axis {
            case .width:
                first.right = 1
                second.left = 1
            case .height:
                first.bottom = 1
                second.top = 1
            }
            return (first, second)
        }
    }

    private indirect enum Node {
        case window(CGWindowID)
        case branch(Split, Node, Node)

        /// Each child of a side-by-side split uses its own columns, but can use
        /// all of the parent's rows. The same rule holds in reverse for a stack.
        var occupied: TileLimits {
            switch self {
            case .window: return TileLimits(rows: 1, columns: 1)
            case let .branch(split, first, second):
                let a = first.occupied, b = second.occupied
                switch split.axis {
                case .width: return TileLimits(rows: max(a.rows, b.rows), columns: a.columns + b.columns)
                case .height: return TileLimits(rows: a.rows + b.rows, columns: max(a.columns, b.columns))
                }
            }
        }

        /// Record each child's minimum extent on its divider, including that
        /// child's exterior margins. Stacked windows share a width, so the
        /// wider floor wins. Side-by-side windows contribute both widths.
        func measured(floors: [CGWindowID: CGSize], margins: Margins, gap: CGSize) -> (node: Node, size: CGSize) {
            switch self {
            case let .window(id):
                let floor = floors[id] ?? .zero
                func minimum(_ length: CGFloat, _ units: Int, _ unitSize: CGFloat) -> CGFloat {
                    guard length.isFinite, length > 0 else { return 1 }
                    return ceil(length) + CGFloat(units) * unitSize
                }
                return (self, CGSize(width: minimum(floor.width, margins.left + margins.right, gap.width),
                                     height: minimum(floor.height, margins.top + margins.bottom, gap.height)))
            case .branch(var split, let first, let second):
                let (leading, trailing) = margins.divided(along: split.axis)
                let a = first.measured(floors: floors, margins: leading, gap: gap)
                let b = second.measured(floors: floors, margins: trailing, gap: gap)
                split.firstMinimum = split.axis.length(of: a.size)
                split.secondMinimum = split.axis.length(of: b.size)
                let size: CGSize
                switch split.axis {
                case .width: size = CGSize(width: a.size.width + b.size.width, height: max(a.size.height, b.size.height))
                case .height: size = CGSize(width: max(a.size.width, b.size.width), height: a.size.height + b.size.height)
                }
                return (.branch(split, a.node, b.node), size)
            }
        }

        func splitCandidates(in bounds: CGRect, within limit: TileLimits, visit: (CGWindowID, CGRect, [Axis]) -> Void) {
            switch self {
            case let .window(id):
                let canWiden = limit.columns > 1
                let canStack = limit.rows > 1
                guard canWiden || canStack else { return }
                let axis: Axis = canWiden && (bounds.width > bounds.height || !canStack) ? .width : .height
                let alternate: Axis = axis == .width ? .height : .width
                visit(id, bounds, canWiden && canStack ? [axis, alternate] : [axis])
            case let .branch(split, first, second):
                let cells = split.divide(bounds)
                func available(alongside sibling: Node) -> TileLimits {
                    switch split.axis {
                    case .width:
                        return TileLimits(rows: limit.rows, columns: limit.columns - sibling.occupied.columns)
                    case .height:
                        return TileLimits(rows: limit.rows - sibling.occupied.rows, columns: limit.columns)
                    }
                }
                first.splitCandidates(in: cells.first, within: available(alongside: second), visit: visit)
                second.splitCandidates(in: cells.second, within: available(alongside: first), visit: visit)
            }
        }

        func visit(in bounds: CGRect, _ visitWindow: (CGWindowID, CGRect) -> Void) {
            switch self {
            case let .window(id): visitWindow(id, bounds)
            case let .branch(split, first, second):
                let cells = split.divide(bounds)
                first.visit(in: cells.first, visitWindow)
                second.visit(in: cells.second, visitWindow)
            }
        }

        func appendIDs(to ids: inout [CGWindowID]) {
            switch self {
            case let .window(id): ids.append(id)
            case let .branch(_, first, second):
                first.appendIDs(to: &ids)
                second.appendIDs(to: &ids)
            }
        }

        /// Removing a leaf promotes its sibling, including the sibling's entire subtree.
        func replacingLeaves(_ replace: (CGWindowID) -> Node?) -> Node? {
            switch self {
            case let .window(id): return replace(id)
            case let .branch(split, first, second):
                let left = first.replacingLeaves(replace)
                let right = second.replacingLeaves(replace)
                if let left, let right { return .branch(split, left, right) }
                return left ?? right
            }
        }

        /// Each entry records the child's side and its parent's divider in
        /// display coordinates. Divider positions stay meaningful after an
        /// ancestor's resize changes the bounds used for the child ratio.
        func path(to id: CGWindowID, in bounds: CGRect, steps: inout [BranchStep]) -> CGRect? {
            switch self {
            case .window(let candidate): return candidate == id ? bounds : nil
            case .branch(let split, let first, let second):
                let cells = split.divide(bounds)
                let divider = split.axis == .width ? cells.first.maxX : cells.first.maxY
                steps.append(BranchStep(axis: split.axis, first: true, divider: divider))
                if let match = first.path(to: id, in: cells.first, steps: &steps) { return match }
                steps[steps.count - 1] = BranchStep(axis: split.axis, first: false, divider: divider)
                if let match = second.path(to: id, in: cells.second, steps: &steps) { return match }
                steps.removeLast()
                return nil
            }
        }

        mutating func setDividers(_ positions: [Int: CGFloat], following path: [BranchStep],
                                  depth: Int, in bounds: CGRect) {
            guard depth < path.count, case .branch(var split, var first, var second) = self else { return }
            let extent = split.axis.length(of: bounds.size)
            if let position = positions[depth], extent > 0 {
                let start = split.axis == .width ? bounds.minX : bounds.minY
                let desired = (position - start) / extent
                // The usual 5% drag margin only applies when both windows
                // can fit inside it. A wider floor can consume over 95%.
                let canUseMargin = split.firstMinimum <= 0.95 * extent && split.secondMinimum <= 0.95 * extent
                let share = canUseMargin ? min(0.95, max(0.05, desired)) : desired
                split.firstShare = split.distance(for: share, in: extent) / extent
            }
            let cells = split.divide(bounds)
            if path[depth].first {
                first.setDividers(positions, following: path, depth: depth + 1, in: cells.first)
            } else {
                second.setDividers(positions, following: path, depth: depth + 1, in: cells.second)
            }
            self = .branch(split, first, second)
        }

    }

    private var root: Node?
    private let limits: TileLimits
    var minimumSizes: [CGWindowID: CGSize] = [:]

    init(limits: TileLimits = TileLimits(), minimumSizes: [CGWindowID: CGSize] = [:]) {
        self.limits = limits
        self.minimumSizes = minimumSizes
    }

    /// On a tight display, keep the largest whole-point gap that fits. When
    /// even gapless windows cannot fit, DesktopLayout retries another split
    /// or leaves the excess window in its overflow queue.
    private func geometry(_ node: Node, in bounds: CGRect) -> (node: Node, gap: CGSize)? {
        var gap = CGSize(width: 5, height: 5)
        while true {
            let measured = node.measured(floors: minimumSizes, margins: Margins(), gap: gap)
            let tooWide = measured.size.width > bounds.width
            let tooTall = measured.size.height > bounds.height
            if !tooWide && !tooTall { return (measured.node, gap) }
            if tooWide {
                guard gap.width > 0 else { return nil }
                gap.width -= 1
            }
            if tooTall {
                guard gap.height > 0 else { return nil }
                gap.height -= 1
            }
        }
    }

    func fits(in bounds: CGRect) -> Bool {
        guard let root else { return true }
        return geometry(root, in: bounds) != nil
    }

    var ids: [CGWindowID] {
        var result: [CGWindowID] = []
        root?.appendIDs(to: &result)
        return result
    }

    func largestTile(in bounds: CGRect) -> CGWindowID? {
        var largestID: CGWindowID?
        var largestArea: CGFloat = -1
        guard let root, let layout = geometry(root, in: bounds) else { return nil }
        layout.node.splitCandidates(in: bounds, within: limits) { id, cell, _ in
            let area = cell.width * cell.height
            if area > largestArea {
                largestID = id
                largestArea = area
            }
        }
        return largestID
    }

    @discardableResult
    mutating func insert(_ id: CGWindowID, near target: CGWindowID?, at point: CGPoint, in bounds: CGRect) -> Bool {
        insert(id, near: target, at: point, in: bounds, dragged: false)
    }

    @discardableResult
    mutating func insertDragged(_ id: CGWindowID, near target: CGWindowID?, at point: CGPoint, in bounds: CGRect) -> Bool {
        insert(id, near: target, at: point, in: bounds, dragged: true)
    }

    private mutating func insert(
        _ id: CGWindowID, near target: CGWindowID?, at point: CGPoint, in bounds: CGRect, dragged: Bool
    ) -> Bool {
        guard let tree = root else {
            guard geometry(.window(id), in: bounds) != nil else { return false }
            root = .window(id)
            return true
        }

        guard !ids.contains(id), let layout = geometry(tree, in: bounds) else { return false }
        var cells: [(id: CGWindowID, bounds: CGRect, axes: [Axis])] = []
        layout.node.splitCandidates(in: bounds, within: limits) { cells.append(($0, $1, $2)) }
        // Swift's stable sort preserves tree order for ties at a shared corner.
        cells.sort { a, b in
            if a.id == target || b.id == target { return a.id == target && b.id != target }
            return a.bounds.distanceSquared(to: point) < b.bounds.distanceSquared(to: point)
        }
        for cell in cells {
            for axis in cell.axes {
                let before = dragged && (axis == .width ? point.x < cell.bounds.midX : point.y < cell.bounds.midY)
                let branch = Node.branch(Split(axis: axis), .window(before ? id : cell.id), .window(before ? cell.id : id))
                if let candidate = tree.replacingLeaves({ $0 == cell.id ? branch : .window($0) }),
                   geometry(candidate, in: bounds) != nil {
                    root = candidate
                    return true
                }
            }
        }
        return false
    }

    mutating func remove(_ id: CGWindowID) {
        root = root?.replacingLeaves { $0 == id ? nil : .window($0) }
    }

    mutating func swap(_ first: CGWindowID, _ second: CGWindowID) {
        let windows = Set(ids)
        guard first != second, windows.contains(first), windows.contains(second) else { return }
        root = root?.replacingLeaves {
            if $0 == first { return .window(second) }
            if $0 == second { return .window(first) }
            return .window($0)
        }
    }

    /// Dwindle's smart resize moves the divider on the grabbed side. A tile
    /// touching the display boundary uses its available interior divider.
    mutating func resize(_ id: CGWindowID, corner: ResizeCorner, by delta: CGSize, in bounds: CGRect) {
        var path: [BranchStep] = []
        guard let root, var layout = geometry(root, in: bounds),
              let cell = layout.node.path(to: id, in: bounds, steps: &path) else { return }
        var dividers: [Int: CGFloat] = [:]
        func choose(_ axis: Axis, by movement: CGFloat, grabsLeading: Bool, onLeading: Bool, onTrailing: Bool) {
            guard movement.isFinite, movement != 0, !(onLeading && onTrailing) else { return }
            var inner: Int?
            for depth in path.indices.reversed() where path[depth].axis == axis {
                let step = path[depth]
                let matches = step.first ? (!grabsLeading || onLeading) : (grabsLeading || onTrailing)
                if matches {
                    dividers[depth] = step.divider + movement
                    if let inner { dividers[inner] = path[inner].divider }
                    return
                }
                if inner == nil { inner = depth }
            }
        }
        choose(.width, by: delta.width, grabsLeading: corner.left,
               onLeading: abs(cell.minX - bounds.minX) < 0.5, onTrailing: abs(cell.maxX - bounds.maxX) < 0.5)
        choose(.height, by: delta.height, grabsLeading: corner.top,
               onLeading: abs(cell.minY - bounds.minY) < 0.5, onTrailing: abs(cell.maxY - bounds.maxY) < 0.5)
        if !dividers.isEmpty {
            layout.node.setDividers(dividers, following: path, depth: 0, in: bounds)
            self.root = layout.node
        }
    }

    func frames(in bounds: CGRect) -> [CGWindowID: CGRect] {
        guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull,
              let root, let layout = geometry(root, in: bounds) else { return [:] }
        var frames: [CGWindowID: CGRect] = [:]
        layout.node.visit(in: bounds) { id, cell in
            let x = Self.inset(cell.minX, cell.maxX, within: bounds.minX...bounds.maxX, gap: layout.gap.width)
            let y = Self.inset(cell.minY, cell.maxY, within: bounds.minY...bounds.maxY, gap: layout.gap.height)
            frames[id] = CGRect(
                x: x.lowerBound, y: y.lowerBound,
                width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound
            )
        }
        return frames
    }

    /// Hyprland applies the outer gap to display edges and the inner gap to each
    /// adjacent tile edge. On tiny cells, give up gap space before window space.
    private static func inset(_ minimum: CGFloat, _ maximum: CGFloat, within display: ClosedRange<CGFloat>,
                              gap: CGFloat) -> ClosedRange<CGFloat> {
        let lower = minimum.rounded()
        let upper = maximum.rounded()
        guard upper > lower else { return minimum...maximum }
        guard gap > 0 else { return lower...upper }
        let leading = lower == display.lowerBound.rounded() ? 2 * gap : gap
        let trailing = upper == display.upperBound.rounded() ? 2 * gap : gap
        let scale = min(1, (upper - lower - 1) / (leading + trailing))
        return (lower + floor(leading * scale))...(upper - floor(trailing * scale))
    }
}
