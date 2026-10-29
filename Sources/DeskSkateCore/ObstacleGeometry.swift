import CoreGraphics
import Foundation

/// Shape of each obstacle, shared by physics and rendering so they always agree. (US-001)
///
/// Every polyline runs with the solid on the RIGHT of each segment (normal = left
/// perpendicular points out of the obstacle). Surface ids: `o<ownerID>-<poly>-<seg>`.
public enum ObstacleGeometry {
    /// One polyline plus per-segment physics properties (`kinds.count == points.count - 1`).
    struct Piece {
        var points: [CGPoint]
        var kinds: [Surface.Kind]
        var grindable: [Bool]
    }

    /// Number of segments in the quarter pipe's transition.
    static let transitionSegments = 12
    /// Lip angle from horizontal, radians (~80°).
    static let lipAngle: CGFloat = 80 * .pi / 180

    /// Polylines in the obstacle's local space (origin = bottom-left of its frame, y up),
    /// already mirrored when `flipped`. Physics turns these into surfaces; the renderer fills them.
    public static func profile(kind: ObstacleKind, size: CGSize, flipped: Bool) -> [[CGPoint]] {
        pieces(kind: kind, size: size, flipped: flipped).map(\.points)
    }

    /// Collision surfaces for an obstacle in global coordinates.
    public static func surfaces(for obstacle: ObstacleModel) -> [Surface] {
        let frame = obstacle.frame.standardized
        let ox = frame.minX, oy = frame.minY
        var out: [Surface] = []
        for (p, piece) in pieces(kind: obstacle.kind, size: frame.size, flipped: obstacle.flipped).enumerated() {
            // Convert once so consecutive segments share exact endpoints.
            let pts = piece.points.map { CGPoint(x: $0.x + ox, y: $0.y + oy) }
            for s in 0..<(pts.count - 1) {
                out.append(Surface(id: "o\(obstacle.ownerID)-\(p)-\(s)", a: pts[s], b: pts[s + 1],
                                   kind: piece.kinds[s], oneWay: true, grindable: piece.grindable[s],
                                   ownerID: obstacle.ownerID, ownerVelocity: obstacle.velocity))
            }
        }
        return out
    }

    // MARK: - Shapes (unflipped: rises to the right)

    static func pieces(kind: ObstacleKind, size: CGSize, flipped: Bool) -> [Piece] {
        let w = max(size.width, 1), h = max(size.height, 1)
        var result: [Piece]
        switch kind {
        case .quarterPipe: result = quarterPipe(w: w, h: h)
        case .kicker:
            result = [
                Piece(points: [CGPoint(x: 0, y: 0), CGPoint(x: w, y: h)], kinds: [.ramp], grindable: [false]),
                backWall(w: w, h: h),
            ]
        case .rail:
            let inset = min(4, w / 4)
            result = [Piece(points: [CGPoint(x: inset, y: h), CGPoint(x: w - inset, y: h)],
                            kinds: [.rail], grindable: [true])]
        case .box:
            result = [Piece(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.12 * w, y: h),
                                     CGPoint(x: 0.88 * w, y: h), CGPoint(x: w, y: 0)],
                            kinds: [.ramp, .rail, .ramp], grindable: [false, true, false])]
        }
        return flipped ? result.map { mirror($0, width: w) } : result
    }

    static func quarterPipe(w: CGFloat, h: CGFloat) -> [Piece] {
        let flat = 0.15 * w
        let deck = min(0.15 * w, 24)
        let lipX = w - deck
        // Elliptical-arc transition from (flat, 0), tangent horizontal, to (lipX, h) at lipAngle.
        let rx = (lipX - flat) / sin(lipAngle)
        let ry = h / (1 - cos(lipAngle))
        var pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: flat, y: 0)]
        for i in 1..<transitionSegments {
            let t = lipAngle * CGFloat(i) / CGFloat(transitionSegments)
            pts.append(CGPoint(x: flat + rx * sin(t), y: ry * (1 - cos(t))))
        }
        pts.append(CGPoint(x: lipX, y: h)) // exact lip, no rounding drift
        pts.append(CGPoint(x: w, y: h))
        let segs = pts.count - 1
        return [
            Piece(points: pts, kinds: Array(repeating: .ramp, count: segs),
                  grindable: Array(repeating: false, count: segs)),
            backWall(w: w, h: h),
        ]
    }

    /// The back of a ramp: top → bottom at x = w, solid to the left, normal +x.
    static func backWall(w: CGFloat, h: CGFloat) -> Piece {
        Piece(points: [CGPoint(x: w, y: h), CGPoint(x: w, y: 0)], kinds: [.wall], grindable: [false])
    }

    /// Mirror in x, then reverse so the solid stays on the right of each segment.
    static func mirror(_ piece: Piece, width w: CGFloat) -> Piece {
        Piece(points: piece.points.reversed().map { CGPoint(x: w - $0.x, y: $0.y) },
              kinds: piece.kinds.reversed(), grindable: piece.grindable.reversed())
    }
}
