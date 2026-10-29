import CoreGraphics

/// The skater's physics. (US-002)
public final class Skater {
    public private(set) var state: SkaterState

    public init(spawn: CGPoint) {
        state = SkaterState(position: spawn)
    }

    /// Advance one frame. Returns what happened, for effects and the autopilot.
    @discardableResult
    public func step(dt: Double, input: SkaterInput, world: WorldSnapshot) -> [SkaterEvent] { [] }

    public func respawn(at point: CGPoint) {
        state = SkaterState(position: point)
    }
}
