import AppKit
import DeskSkateCore

/// A ramp or obstacle on the desktop: a borderless, non-activating panel you drag by its body.
/// Sits at `.floating` so the skater's overlay (`.floating + 1`) draws over it. (US-008)
final class ObstaclePanel: NSPanel {
    let obstacleID: UUID
    let kind: ObstacleKind
    let ownerID: UInt32
    var flipped: Bool { didSet { contentView?.needsDisplay = true } }

    /// Called when a drag finishes, so the manager can save.
    var onDragEnded: (() -> Void)?
    var onFlip: (() -> Void)?
    var onRemove: (() -> Void)?

    /// Transparent margin around the obstacle so its outline/halo isn't clipped.
    static let padding: CGFloat = 5

    /// The obstacle's frame (what physics uses), global AppKit coords.
    var obstacleFrame: CGRect { frame.insetBy(dx: Self.padding, dy: Self.padding) }
    func setObstacleFrame(_ r: CGRect) {
        setFrame(r.insetBy(dx: -Self.padding, dy: -Self.padding), display: true)
    }

    init(model: ObstacleModel, ownerID: UInt32) {
        obstacleID = model.id
        kind = model.kind
        flipped = model.flipped
        self.ownerID = ownerID
        let outer = model.frame.insetBy(dx: -Self.padding, dy: -Self.padding)
        super.init(contentRect: outer, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Dragging is done by ObstacleView itself (see there), not by the window server.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        let view = ObstacleView(frame: NSRect(origin: .zero, size: outer.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the obstacle and handles dragging + the right-click menu.
///
/// Dragging is tracked by hand (mouseDown/mouseDragged → setFrameOrigin) instead of
/// `isMovableByWindowBackground`: a window-server drag updates `NSWindow.frame` late and runs
/// a nested tracking loop, which would starve the game loop and blur the ramp's velocity.
final class ObstacleView: NSView {
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false

    private var panel: ObstaclePanel? { window as? ObstaclePanel }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let panel, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad = ObstaclePanel.padding
        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)
        ObstacleArt.draw(kind: panel.kind, size: bounds.insetBy(dx: pad, dy: pad).size, flipped: panel.flipped)
        ctx.restoreGState()
    }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        let origin = NSPoint(x: dragStartOrigin.x + now.x - start.x, y: dragStartOrigin.y + now.y - start.y)
        window.setFrameOrigin(origin)
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { panel?.onDragEnded?() }
        dragStartMouse = nil
        didDrag = false
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let flip = NSMenuItem(title: "Flip", action: #selector(flipAction), keyEquivalent: "")
        flip.target = self
        menu.addItem(flip)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeAction), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func flipAction() { panel?.onFlip?() }
    @objc private func removeAction() { panel?.onRemove?() }
}

/// The obstacle drawing, separate from the view so it can be rendered offscreen.
enum ObstacleArt {
    static let face = NSColor(srgbRed: 0.31, green: 0.45, blue: 0.62, alpha: 1)
    static let faceDark = NSColor(srgbRed: 0.22, green: 0.33, blue: 0.47, alpha: 1)
    static let coping = NSColor(srgbRed: 0.82, green: 0.88, blue: 0.95, alpha: 1)
    static let outline = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
    static let halo = NSColor(white: 1, alpha: 0.45)
    static let metal = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.71, alpha: 1)
    static let metalHighlight = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)

    /// Draws in the current graphics context, local space origin bottom-left, y up.
    static func draw(kind: ObstacleKind, size: CGSize, flipped: Bool) {
        let profile = ObstacleGeometry.profile(kind: kind, size: size, flipped: flipped)
        if kind == .rail {
            drawRail(profile: profile, size: size)
            return
        }

        // Solid region: each polyline closed straight down to y = 0.
        let body = NSBezierPath()
        for poly in profile where poly.count > 2 || (poly.count == 2 && poly[0].x != poly[1].x) {
            guard let first = poly.first, let last = poly.last else { continue }
            body.move(to: first)
            for p in poly.dropFirst() { body.line(to: p) }
            body.line(to: CGPoint(x: last.x, y: 0))
            body.line(to: CGPoint(x: first.x, y: 0))
            body.close()
        }
        body.lineJoinStyle = .round

        // Halo first so it reads on dark desktops, then fill, then the dark outline.
        halo.setStroke()
        body.lineWidth = 5
        body.stroke()

        if let gradient = NSGradient(starting: face, ending: faceDark) {
            gradient.draw(in: body, angle: -90)
        } else {
            face.setFill(); body.fill()
        }

        outline.setStroke()
        body.lineWidth = 1.5
        body.stroke()

        // Coping: lighter riding edge along each surface, skipping runs on the floor.
        let copingPath = NSBezierPath()
        for poly in profile where poly.count >= 2 {
            for i in 0..<(poly.count - 1) {
                let a = poly[i], b = poly[i + 1]
                if a.y < 1 && b.y < 1 { continue }   // floor run
                if abs(a.x - b.x) < 0.5 { continue }  // back wall
                copingPath.move(to: a)
                copingPath.line(to: b)
            }
        }
        copingPath.lineCapStyle = .round
        copingPath.lineJoinStyle = .round
        outline.setStroke()
        copingPath.lineWidth = 4.5
        copingPath.stroke()
        coping.setStroke()
        copingPath.lineWidth = 3
        copingPath.stroke()
    }

    private static func drawRail(profile: [[CGPoint]], size: CGSize) {
        guard let top = profile.first, let a = top.first, let b = top.last else { return }
        let w = size.width, h = size.height
        let barH: CGFloat = 4
        let left = min(a.x, b.x), right = max(a.x, b.x)
        let bar = NSRect(x: left, y: h - barH, width: right - left, height: barH)
        let postW: CGFloat = 4
        let posts = [0.15 * w, 0.85 * w].map {
            NSRect(x: $0 - postW / 2, y: 0, width: postW, height: h - barH)
        }
        let feet = [0.15 * w, 0.85 * w].map {
            NSRect(x: $0 - 7, y: 0, width: 14, height: 3)
        }
        let shape = NSBezierPath()
        for r in posts + feet { shape.append(NSBezierPath(rect: r)) }
        shape.append(NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2))

        halo.setStroke(); shape.lineWidth = 4; shape.stroke()
        metal.setFill(); shape.fill()
        outline.setStroke(); shape.lineWidth = 1.5; shape.stroke()

        // Shine along the top of the bar.
        let shine = NSBezierPath()
        shine.move(to: CGPoint(x: left + 2, y: h - 1.5))
        shine.line(to: CGPoint(x: right - 2, y: h - 1.5))
        metalHighlight.setStroke()
        shine.lineWidth = 1
        shine.stroke()
    }
}
