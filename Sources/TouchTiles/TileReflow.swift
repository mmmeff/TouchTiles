import Foundation
import CoreGraphics

/// A close or a drag can retarget a tile before its last animation finishes.
struct TileReflow {
    static let duration: TimeInterval = 0.22

    private struct Transition {
        let from: CGRect
        let to: CGRect
        let start: TimeInterval

        func frame(at time: TimeInterval) -> CGRect {
            let remaining = max(0, min(1, 1 - (time - start) / TileReflow.duration))
            let weight = remaining * remaining * remaining
            func edge(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
                (b + (a - b) * weight).rounded()
            }
            let x = edge(from.minX, to.minX)
            let y = edge(from.minY, to.minY)
            return CGRect(x: x, y: y, width: edge(from.maxX, to.maxX) - x,
                          height: edge(from.maxY, to.maxY) - y)
        }
    }

    private var transitions: [CGWindowID: Transition] = [:]
    var isEmpty: Bool { transitions.isEmpty }
    func isAnimating(_ id: CGWindowID) -> Bool { transitions[id] != nil }

    mutating func reconcile(targets: [CGWindowID: CGRect], observed: [CGWindowID: CGRect],
                            animate: Set<CGWindowID>, now: TimeInterval) -> [CGWindowID: CGRect] {
        var next: [CGWindowID: Transition] = [:]
        var immediate: [CGWindowID: CGRect] = [:]
        for (id, target) in targets {
            if let current = transitions[id], current.to == target {
                next[id] = current
            } else if animate.contains(id), let from = observed[id], !from.approximatelyEquals(target) {
                next[id] = Transition(from: from, to: target, start: now)
            } else {
                immediate[id] = target
            }
        }
        transitions = next
        return immediate
    }

    mutating func sample(at now: TimeInterval) -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for (id, transition) in transitions {
            if now >= transition.start + Self.duration {
                frames[id] = transition.to
                transitions[id] = nil
            } else {
                frames[id] = transition.frame(at: now)
            }
        }
        return frames
    }
}
