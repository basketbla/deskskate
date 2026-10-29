import CoreGraphics

/// Drives the skater when nobody is on the keyboard. (US-007)
public final class AutoPilot {
    public init() {}

    public func input(state: SkaterState, world: WorldSnapshot, events: [SkaterEvent], dt: Double) -> SkaterInput {
        SkaterInput()
    }
}
