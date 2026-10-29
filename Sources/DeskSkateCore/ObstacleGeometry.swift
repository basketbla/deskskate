import CoreGraphics

/// Shape of each obstacle, shared by physics and rendering so they always agree. (US-001)
public enum ObstacleGeometry {
    /// Polylines in the obstacle's local space (origin = bottom-left of its frame, y up),
    /// already mirrored when `flipped`. Physics turns these into surfaces; the renderer fills them.
    public static func profile(kind: ObstacleKind, size: CGSize, flipped: Bool) -> [[CGPoint]] { [] }

    /// Collision surfaces for an obstacle in global coordinates.
    public static func surfaces(for obstacle: ObstacleModel) -> [Surface] { [] }
}
