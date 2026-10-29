import AppKit
import DeskSkateCore

/// A transparent, click-through panel covering one screen. The skater is drawn into it. (US-006)
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        // Obstacle panels sit at .floating; the skater must draw over them.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var overlayView: OverlayView { contentView as! OverlayView }
}

/// Draws the skater (and optionally the collision surfaces) in global AppKit coordinates.
final class OverlayView: NSView {
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let window else { return }
        ctx.clear(dirtyRect)

        let game = GameController.shared
        guard !AppState.shared.hidden else { return }

        ctx.saveGState()
        let origin = window.frame.origin
        ctx.translateBy(x: -origin.x, y: -origin.y)

        if AppState.shared.showSurfaces, let world = game.world {
            drawSurfaces(world.surfaces, in: ctx)
        }
        if let skater = game.skater {
            game.renderer.draw(skater.state, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawSurfaces(_ surfaces: [Surface], in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        for s in surfaces {
            let color = Self.color(for: s.kind)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(s.oneWay ? 2 : 3)
            if s.grindable { ctx.setLineDash(phase: 0, lengths: []) } else { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
            ctx.move(to: s.a)
            ctx.addLine(to: s.b)
            ctx.strokePath()

            // Normal ticks every ~40pt.
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(1)
            let len = s.length
            guard len > 0 else { continue }
            let n = s.normal * 6
            let dir = s.direction
            let count = max(1, Int(len / 40))
            for i in 0...count {
                let t = len * CGFloat(i) / CGFloat(count)
                let p = s.a + dir * t
                ctx.move(to: p)
                ctx.addLine(to: p + n)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func color(for kind: Surface.Kind) -> CGColor {
        switch kind {
        case .ground: CGColor(srgbRed: 0.2, green: 0.8, blue: 0.3, alpha: 0.9)
        case .ledge: CGColor(srgbRed: 0.1, green: 0.6, blue: 1.0, alpha: 0.9)
        case .ramp: CGColor(srgbRed: 1.0, green: 0.6, blue: 0.1, alpha: 0.9)
        case .rail: CGColor(srgbRed: 0.9, green: 0.2, blue: 0.9, alpha: 0.9)
        case .wall: CGColor(srgbRed: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !GameController.shared.keyDown(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !GameController.shared.keyUp(event) { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }
}
