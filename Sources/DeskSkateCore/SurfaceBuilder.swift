import CoreGraphics

/// Turns the tracked windows, screens and obstacles into the collision world. (US-001)
public enum SurfaceBuilder {
    public static func build(windows: [TrackedWindow], screens: [CGRect], obstacles: [ObstacleModel]) -> WorldSnapshot {
        WorldSnapshot(surfaces: [], screens: screens)
    }
}
