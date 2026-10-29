import AppKit
import DeskSkateCore

/// Draws the procedural skater. (US-004)
final class SkaterRenderer {
    /// Feed events from each physics step so effects (sparks, dust, bail stars) can spawn.
    func handle(events: [SkaterEvent], state: SkaterState) {}

    /// Advance effect particles.
    func update(dt: Double) {}

    /// Draw in global AppKit coordinates — the caller has already translated `ctx` so that
    /// global points land in the right place on this screen.
    func draw(_ state: SkaterState, in ctx: CGContext) {}
}
