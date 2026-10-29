import CoreGraphics

/// Turns the tracked windows, screens and obstacles into the collision world. (US-001)
///
/// Surface ids (stable frame to frame, the physics re-finds its surface by id):
/// - `w<windowID>-<spanIndex>`  visible spans of a window's top edge, left to right
/// - `g<screenIndex>`           a screen's visible-frame bottom
/// - `wall-<screenIndex>-L/R`   outer screen sides with no neighbouring screen
/// - `o<ownerID>-<poly>-<seg>`  obstacle segments (see `ObstacleGeometry`)
///
/// Orientation follows `Surface.normal` = left perpendicular of a→b:
/// floors/ledges run left→right (normal up); the LEFT world wall runs top→bottom (normal +x,
/// into the world); the RIGHT world wall runs bottom→top (normal −x, into the world).
public enum SurfaceBuilder {
    public static let minWindowWidth: CGFloat = 60
    public static let minWindowHeight: CGFloat = 40
    public static let minLedgeLength: CGFloat = 24
    /// How far above a window's top another window's top may sit and still count as covering it.
    static let coverSlop: CGFloat = 2
    /// Tolerance when matching ledges and neighbours against screen frames.
    static let screenTolerance: CGFloat = 1
    static let neighbourTolerance: CGFloat = 2

    /// `docks`: frames of the Dock while it is showing; its top becomes a floor.
    public static func build(windows: [TrackedWindow], screens: [CGRect], obstacles: [ObstacleModel],
                             docks: [CGRect] = []) -> WorldSnapshot {
        var surfaces: [Surface] = []
        surfaces.reserveCapacity(windows.count * 2 + screens.count * 3 + obstacles.count * 16)
        appendLedges(windows: windows, screens: screens, into: &surfaces)
        appendScreenSurfaces(screens: screens, into: &surfaces)
        for obstacle in obstacles { surfaces.append(contentsOf: ObstacleGeometry.surfaces(for: obstacle)) }
        for (i, dock) in docks.enumerated() {
            surfaces.append(Surface(id: "dock-\(i)", a: CGPoint(x: dock.minX, y: dock.maxY),
                                    b: CGPoint(x: dock.maxX, y: dock.maxY), kind: .ground,
                                    oneWay: true, grindable: true))
        }
        return WorldSnapshot(surfaces: surfaces, screens: screens)
    }

    // MARK: - Window ledges

    static func appendLedges(windows: [TrackedWindow], screens: [CGRect], into surfaces: inout [Surface]) {
        var covered: [(CGFloat, CGFloat)] = []
        var allowed: [(CGFloat, CGFloat)] = []
        for window in windows {
            let f = window.frame.standardized
            guard f.width >= minWindowWidth, f.height >= minWindowHeight else { continue }
            let y = f.maxY

            // Horizontal extents of screens this edge's height lies on.
            allowed.removeAll(keepingCapacity: true)
            for s in screens where y >= s.minY - screenTolerance && y <= s.maxY + screenTolerance {
                let lo = max(s.minX, f.minX), hi = min(s.maxX, f.maxX)
                if hi > lo { allowed.append((lo, hi)) }
            }
            guard !allowed.isEmpty else { continue }

            // Spans hidden by windows in front (any size: a small window still hides what's behind).
            covered.removeAll(keepingCapacity: true)
            for front in windows where front.zIndex < window.zIndex && front.id != window.id {
                let g = front.frame.standardized
                guard y > g.minY && y <= g.maxY + coverSlop else { continue }
                let lo = max(g.minX, f.minX), hi = min(g.maxX, f.maxX)
                if hi > lo { covered.append((lo, hi)) }
            }

            let visible = subtract(merge(allowed), merge(covered))
            let velocity = window.teleported ? CGVector.zero : window.velocity
            var span = 0
            for (lo, hi) in visible where hi - lo >= minLedgeLength {
                surfaces.append(Surface(id: "w\(window.id)-\(span)",
                                        a: CGPoint(x: lo, y: y), b: CGPoint(x: hi, y: y),
                                        kind: .ledge, oneWay: true, grindable: true,
                                        ownerID: window.id, ownerVelocity: velocity))
                span += 1
            }
        }
    }

    /// Sorts and unions intervals.
    static func merge(_ intervals: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        guard intervals.count > 1 else { return intervals }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var out: [(CGFloat, CGFloat)] = [sorted[0]]
        for iv in sorted.dropFirst() {
            if iv.0 <= out[out.count - 1].1 {
                out[out.count - 1].1 = max(out[out.count - 1].1, iv.1)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// `base` minus `cut`; both sorted and disjoint.
    static func subtract(_ base: [(CGFloat, CGFloat)], _ cut: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        guard !cut.isEmpty else { return base }
        var out: [(CGFloat, CGFloat)] = []
        var j = 0
        for (lo0, hi) in base {
            var lo = lo0
            while j < cut.count && cut[j].1 <= lo { j += 1 }
            var k = j
            while k < cut.count && cut[k].0 < hi {
                if cut[k].0 > lo { out.append((lo, cut[k].0)) }
                lo = max(lo, cut[k].1)
                if lo >= hi { break }
                k += 1
            }
            if lo < hi { out.append((lo, hi)) }
        }
        return out
    }

    // MARK: - Screens

    static func appendScreenSurfaces(screens: [CGRect], into surfaces: inout [Surface]) {
        for (i, s) in screens.enumerated() {
            surfaces.append(Surface(id: "g\(i)",
                                    a: CGPoint(x: s.minX, y: s.minY), b: CGPoint(x: s.maxX, y: s.minY),
                                    kind: .ground, oneWay: false, grindable: false))

            var leftNeighbour = false, rightNeighbour = false
            for (j, o) in screens.enumerated() where j != i {
                guard o.minY < s.maxY && o.maxY > s.minY else { continue }
                if abs(o.maxX - s.minX) <= neighbourTolerance { leftNeighbour = true }
                if abs(o.minX - s.maxX) <= neighbourTolerance { rightNeighbour = true }
            }
            if !leftNeighbour {
                // Solid to the left, normal +x: top → bottom.
                surfaces.append(Surface(id: "wall-\(i)-L",
                                        a: CGPoint(x: s.minX, y: s.maxY), b: CGPoint(x: s.minX, y: s.minY),
                                        kind: .wall, oneWay: false, grindable: false))
            }
            if !rightNeighbour {
                // Solid to the right, normal −x: bottom → top.
                surfaces.append(Surface(id: "wall-\(i)-R",
                                        a: CGPoint(x: s.maxX, y: s.minY), b: CGPoint(x: s.maxX, y: s.maxY),
                                        kind: .wall, oneWay: false, grindable: false))
            }
        }
    }
}
