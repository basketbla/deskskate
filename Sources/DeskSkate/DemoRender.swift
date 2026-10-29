import AppKit
import DeskSkateCore
import ImageIO
import UniformTypeIdentifiers

/// Renders the landing-page demo video offscreen from the real physics and drawing code:
/// a made-up desktop (gradient wallpaper, blank menu bar, placeholder windows), real obstacle
/// art, the real skater, and a drawn cursor. Nothing on the actual screen is read or touched.
///
///   DeskSkate --render-demo <outdir> [--trace] [--every N] [--scale S]
///
/// Writes frame-00000.png … at 60fps into <outdir> (encode with scripts/render-demo.sh).
/// `--trace` prints the scripted phases and skater state instead of drawing.
enum DemoRender {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-demo") else { return false }
        guard i + 1 < args.count else {
            FileHandle.standardError.write("usage: DeskSkate --render-demo <outdir> [--trace] [--every N]\n".data(using: .utf8)!)
            exit(2)
        }
        let out = URL(fileURLWithPath: args[i + 1])
        let trace = args.contains("--trace")
        var every = 1
        if let j = args.firstIndex(of: "--every"), j + 1 < args.count { every = max(1, Int(args[j + 1]) ?? 1) }
        var scale: CGFloat = 1.2
        if let j = args.firstIndex(of: "--scale"), j + 1 < args.count { scale = CGFloat(Double(args[j + 1]) ?? 1.2) }
        if !trace { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        DemoScene(outDir: out, trace: trace, every: every, outputScale: scale).run()
        return true
    }
}

// MARK: - Scene

private struct DemoWindow {
    var id: UInt32
    var frame: CGRect
    var velocity: CGVector = .zero
    var style: Int
}

private final class DemoScene {
    static let size = CGSize(width: 1600, height: 1000)
    static let menuBar: CGFloat = 24
    static let fps = 60.0
    static let dt = 1.0 / fps
    static let superSample: CGFloat = 2

    let outDir: URL
    let trace: Bool
    let every: Int
    let outputScale: CGFloat

    // Windows, front to back is decided by `order` (index 0 = frontmost).
    var windows: [DemoWindow] = [
        DemoWindow(id: 1, frame: CGRect(x: 140, y: 330, width: 560, height: 290), style: 0),   // A
        DemoWindow(id: 2, frame: CGRect(x: 780, y: 420, width: 420, height: 300), style: 1),   // B
        DemoWindow(id: 3, frame: CGRect(x: 170, y: 46, width: 360, height: 200), style: 2),    // C
    ]
    var order: [UInt32] = [2, 1, 3]
    let obstacles: [ObstacleModel] = [
        ObstacleModel(kind: .quarterPipe, frame: CGRect(x: 1430, y: 0, width: 150, height: 88), ownerID: 9001),
        ObstacleModel(kind: .rail, frame: CGRect(x: 640, y: 0, width: 240, height: 40), ownerID: 9002),
        ObstacleModel(kind: .kicker, frame: CGRect(x: 905, y: 0, width: 110, height: 54), flipped: true, ownerID: 9003),
    ]
    var screens: [CGRect] { [CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height - Self.menuBar)] }

    let skater = Skater(spawn: CGPoint(x: 230, y: 660))
    let renderer = SkaterRenderer()
    let autopilot = AutoPilot(seed: 11)
    var lastEvents: [SkaterEvent] = []
    var world: WorldSnapshot!

    // Clock and script.
    var frame = 0
    var t: Double { Double(frame) * Self.dt }
    enum Phase: String { case cruiseA, airAtoB, rideB, floorToQP, quarterPipe, toRail, grind, afterRail,
                         reach, carry, settleC, toTitleBar, dragC, flick, launched, finale, done }
    var phase: Phase = .cruiseA
    var phaseStart = 0.0
    var pt: Double { t - phaseStart }
    var prevJump = false, prevTrick = false
    var trickDone = false
    var finaleStart = 0.0

    // Cursor.
    var cursor = CGPoint(x: 1240, y: 300)
    var cursorDown = false
    var pathFrom = CGPoint.zero
    var cWindowStart = CGRect.zero
    var grabOffset = CGVector.zero

    var wallpaper: CGImage?

    // Camera: a gentle follow-zoom (like a screen-recording editor's auto zoom) so the
    // 45pt skater reads on a landing page. `camCenter`/`camZoom` are in desktop points.
    var camCenter = CGPoint(x: 400, y: 600)
    var camZoom: CGFloat = 1.5
    var camReady = false

    func updateCamera() {
        var s = skater.state.position
        if skater.state.phase == .held { s.y += SkaterRenderer.heldBoardOffset - 10 }
        var focus = CGPoint(x: s.x, y: s.y + 40)
        var zoom: CGFloat = 1.55
        switch phase {
        case .reach, .toTitleBar:
            focus = CGPoint(x: (s.x + cursor.x) / 2, y: (s.y + 40 + cursor.y) / 2)
        case .dragC, .flick, .launched:
            focus = CGPoint(x: s.x + 60, y: s.y + 60)
            zoom = 1.3
        case .finale, .done:
            zoom = 1.4
        default: break
        }
        if !camReady { camCenter = focus; camZoom = zoom; camReady = true }
        let k = CGFloat(1 - exp(-Self.dt * 3.2))
        camCenter = CGPoint(x: camCenter.x + (focus.x - camCenter.x) * k, y: camCenter.y + (focus.y - camCenter.y) * k)
        camZoom += (zoom - camZoom) * CGFloat(1 - exp(-Self.dt * 1.6))
    }

    /// Visible desktop rect for this frame, clamped inside the desktop.
    var viewRect: CGRect {
        let w = Self.size.width / camZoom, h = Self.size.height / camZoom
        let x = min(max(camCenter.x - w / 2, 0), Self.size.width - w)
        let y = min(max(camCenter.y - h / 2, 0), Self.size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    init(outDir: URL, trace: Bool, every: Int, outputScale: CGFloat) {
        self.outDir = outDir; self.trace = trace; self.every = every; self.outputScale = outputScale
    }

    func go(_ p: Phase) {
        if trace { print(String(format: "t=%6.2f  → %@", t, p.rawValue)) }
        phase = p; phaseStart = t
    }

    func window(_ id: UInt32) -> DemoWindow { windows.first { $0.id == id }! }
    func setFrame(_ id: UInt32, _ f: CGRect) {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return }
        let old = windows[i].frame
        windows[i].velocity = CGVector(dx: (f.minX - old.minX) / Self.dt, dy: (f.minY - old.minY) / Self.dt)
        windows[i].frame = f
    }

    var tracked: [TrackedWindow] {
        windows.map { w in
            TrackedWindow(id: w.id, frame: w.frame, velocity: w.velocity, zIndex: order.firstIndex(of: w.id) ?? 9)
        }
    }

    // MARK: Run

    func run() {
        wallpaper = makeWallpaper()
        world = SurfaceBuilder.build(windows: tracked, screens: screens, obstacles: obstacles)
        var written = 0
        while phase != .done && t < 40 {
            for i in windows.indices { windows[i].velocity = .zero }
            let input = script()
            world = SurfaceBuilder.build(windows: tracked, screens: screens, obstacles: obstacles)
            var events = skater.step(dt: Self.dt, input: input, world: world)
            events += pendingEvents
            pendingEvents = []
            renderer.handle(events: events, state: skater.state)
            renderer.update(dt: Self.dt)
            lastEvents = events
            updateCamera()
            if trace {
                if frame % 6 == 0 || events.contains(where: { $0 != .landed(clean: true) }) && !events.isEmpty {
                    let s = skater.state
                    print(String(format: "t=%6.2f %-11@ pos=(%6.1f,%6.1f) v=(%6.1f,%6.1f) %@ surf=%@ ev=%@",
                                 t, phase.rawValue, s.position.x, s.position.y, s.velocity.dx, s.velocity.dy,
                                 "\(s.phase)", s.surfaceID ?? "-", "\(events)"))
                }
            } else if frame % every == 0 {
                autoreleasepool { writeFrame(index: frame) }
                written += 1
            }
            frame += 1
        }
        print("demo: \(frame) frames (\(String(format: "%.2f", t))s), wrote \(written) to \(outDir.path)")
    }

    var pendingEvents: [SkaterEvent] = []

    // MARK: Script

    func controls(left: Bool = false, right: Bool = false, jump: Bool = false, trick: Bool = false,
                  grind: Bool = false) -> SkaterInput {
        let input = SkaterInput(left: left, right: right, jump: jump, jumpPressed: jump && !prevJump,
                                jumpReleased: !jump && prevJump, trickPressed: trick && !prevTrick, grind: grind)
        prevJump = jump; prevTrick = trick
        return input
    }

    func ease(_ u: Double) -> CGFloat { let u = min(max(u, 0), 1); return CGFloat(u * u * (3 - 2 * u)) }

    /// Moves the cursor toward `target` at up to `speed` pt/s, easing in the last stretch.
    @discardableResult
    func moveCursor(toward target: CGPoint, speed: CGFloat = 900) -> Bool {
        let d = target - cursor
        let len = d.length
        if len < 1.5 { cursor = target; return true }
        let stepLen = min(len, max(speed * CGFloat(Self.dt) * min(1, len / 120), 1.5))
        cursor = cursor + d.normalized * stepLen
        return false
    }

    func script() -> SkaterInput {
        let s = skater.state
        let onSurf = { (prefix: String) in s.surfaceID?.hasPrefix(prefix) == true }
        let speedX = s.velocity.dx

        switch phase {
        case .cruiseA:
            // Settle on window A, push right, load an ollie near the end.
            let a = window(1).frame
            if s.phase == .rolling && s.position.x > a.maxX - 32 {
                go(.airAtoB); trickDone = false
                return controls(right: true, jump: false)
            }
            let load = s.phase == .rolling && s.position.x > a.maxX - 150 && t > 1.2
            return controls(right: speedX < 330, jump: load)

        case .airAtoB:
            let trick = s.phase == .airborne && !trickDone && pt > 0.08
            if trick { trickDone = true }
            if s.phase == .rolling && onSurf("w2") { go(.rideB) }
            return controls(right: s.phase == .airborne && s.position.x < 900, trick: trick)

        case .rideB:
            if onSurf("g") { go(.floorToQP) }
            return controls(left: speedX > 170 && s.phase == .rolling, right: speedX < 120 && s.phase == .rolling)

        case .floorToQP:
            if onSurf("o9001") || (s.phase == .airborne && s.position.x > 1430) { go(.quarterPipe) }
            return controls(right: s.phase == .rolling && speedX < 400)

        case .quarterPipe:
            if s.phase == .rolling && onSurf("g") && speedX < -40 && s.position.x < 1380 { go(.toRail); trickDone = false }
            return controls()

        case .toRail:
            // Off the kicker straight onto the rail, holding grind.
            let x = s.position.x
            if x < 1000 && s.phase != .rolling { go(.grind) }
            return controls(left: s.phase == .rolling && speedX > -340 && x > 1060, grind: x < 1040)

        case .grind:
            if s.phase == .rolling && onSurf("g") && pt > 0.2 { go(.afterRail) }
            return controls(grind: s.phase != .rolling || onSurf("o9002"))

        case .afterRail:
            if abs(speedX) < 140 || s.position.x < 420 { go(.reach) }
            return controls(right: speedX < -100)

        case .reach:
            // Cursor chases the skater's torso and picks him up.
            let target = s.position + CGVector(dx: 0, dy: 30)
            let near = moveCursor(toward: target, speed: 1300)
            if near || (cursor - target).length < 4 {
                cursor = target
                pendingEvents += skater.grab(at: boardPoint(forMouse: cursor))
                cursorDown = true
                pathFrom = cursor
                go(.carry)
                return controls()
            }
            return controls(right: speedX < -60)

        case .carry:
            let c = window(3).frame
            let to = CGPoint(x: c.midX + 10, y: c.maxY + 105)
            let dur = 1.15
            let u = ease(pt / dur)
            // Swoop up and over in an arc.
            let arc = sin(Double(u) * .pi) * 80
            cursor = CGPoint(x: pathFrom.x + (to.x - pathFrom.x) * u,
                             y: pathFrom.y + (to.y - pathFrom.y) * u + CGFloat(arc))
            skater.drag(to: boardPoint(forMouse: cursor), dt: Self.dt)
            if pt > dur + 0.35 {
                pendingEvents += skater.release()
                cursorDown = false
                go(.settleC)
            }
            return controls()

        case .settleC:
            moveCursor(toward: cursor + CGVector(dx: 30, dy: 20), speed: 200)
            if s.phase == .rolling && onSurf("w3") && pt > 0.6 {
                pathFrom = cursor
                go(.toTitleBar)
            }
            return controls(left: speedX > 15, right: speedX < -15)

        case .toTitleBar:
            let c = window(3).frame
            let target = CGPoint(x: c.maxX - 70, y: c.maxY - 13)
            if moveCursor(toward: target, speed: 900) && pt > 0.3 {
                cursorDown = true
                order = [3] + order.filter { $0 != 3 }
                cWindowStart = c
                grabOffset = cursor - c.origin
                go(.dragC)
            }
            return controls()

        case .dragC:
            // A slow drag: he rides along.
            let dur = 1.6
            let u = ease(pt / dur)
            let wobble = CGFloat(sin(pt * 9) * 3) * (1 - u)
            var f = cWindowStart
            f.origin.x += 150 * u
            f.origin.y += 110 * u + wobble
            setFrame(3, f)
            cursor = f.origin + grabOffset
            if pt >= dur + 0.25 { cWindowStart = window(3).frame; go(.flick); trickDone = false }
            return controls(left: speedX > 15, right: speedX < -15)

        case .flick:
            // Flick upward fast, then stop dead: he keeps going.
            let dur = 0.13
            let u = min(pt / dur, 1)
            var f = cWindowStart
            f.origin.y += CGFloat(150 * u)
            setFrame(3, f)
            cursor = f.origin + grabOffset
            if pt > dur + 0.25 { cursorDown = false }
            if s.phase == .airborne && pt > 0.05 { go(.launched) }
            return controls()

        case .launched:
            if pt > 0.2 { cursorDown = false }
            moveCursor(toward: CGPoint(x: 1240, y: 300), speed: 500)
            let trick = s.phase == .airborne && !trickDone && pt > 0.12
            if trick { trickDone = true }
            if s.phase == .rolling && pt > 0.3 { go(.finale) }
            return controls(trick: trick)

        case .finale:
            moveCursor(toward: CGPoint(x: 1240, y: 300), speed: 500)
            if pt > 3.2 { go(.done) }
            return autopilot.input(state: s, world: world, events: lastEvents, dt: Self.dt)

        case .done:
            return controls()
        }
    }

    func boardPoint(forMouse mouse: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x, y: mouse.y - SkaterRenderer.heldBoardOffset)
    }

    // MARK: Drawing

    func writeFrame(index: Int) {
        let ss = Self.superSample
        let w = Int(Self.size.width * ss), h = Int(Self.size.height * ss)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let view = viewRect
        ctx.scaleBy(x: ss * camZoom, y: ss * camZoom)
        ctx.translateBy(x: -view.minX, y: -view.minY)
        drawScene(ctx)
        guard let big = ctx.makeImage() else { return }

        let ow = Int(Self.size.width * outputScale), oh = Int(Self.size.height * outputScale)
        guard let small = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        small.interpolationQuality = .high
        small.draw(big, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        guard let image = small.makeImage() else { return }
        let url = outDir.appendingPathComponent(String(format: "frame-%05d.png", index))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    func drawScene(_ ctx: CGContext) {
        if let wallpaper { ctx.draw(wallpaper, in: CGRect(origin: .zero, size: Self.size)) }
        for id in order.reversed() { drawWindow(window(id), ctx) }

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for o in obstacles {
            ctx.saveGState()
            ctx.translateBy(x: o.frame.minX, y: o.frame.minY)
            ObstacleArt.draw(kind: o.kind, size: o.frame.size, flipped: o.flipped)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        var state = skater.state
        if state.phase == .held { state.position.y += SkaterRenderer.heldBoardOffset }
        renderer.draw(state, in: ctx)

        drawMenuBar(ctx)
        drawCursor(at: cursor, pressed: cursorDown, ctx)
    }

    func makeWallpaper() -> CGImage? {
        let ss = Self.superSample
        let w = Int(Self.size.width * ss), h = Int(Self.size.height * ss)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.scaleBy(x: ss, y: ss)
        let size = Self.size
        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: a)
        }
        let base = CGGradient(colorsSpace: cs, colors: [rgb(0xDCE6F5), rgb(0xA9BCE0), rgb(0x7083B8)] as CFArray,
                              locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 200, y: size.height), end: CGPoint(x: 1400, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Soft blobs.
        let blobs: [(CGPoint, CGFloat, UInt32, CGFloat)] = [
            (CGPoint(x: 1250, y: 820), 560, 0xC6D9FF, 0.75),
            (CGPoint(x: 260, y: 140), 520, 0x8FC3D9, 0.55),
            (CGPoint(x: 1450, y: 120), 480, 0x9B93D9, 0.45),
            (CGPoint(x: 650, y: 700), 420, 0xEEF3FB, 0.5),
        ]
        for (c, r, hex, a) in blobs {
            let g = CGGradient(colorsSpace: cs, colors: [rgb(hex, a), rgb(hex, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        return ctx.makeImage()
    }

    func drawMenuBar(_ ctx: CGContext) {
        let h = Self.menuBar
        let y = Self.size.height - h
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 0.72))
        ctx.fill(CGRect(x: 0, y: y, width: Self.size.width, height: h))
        let ink = CGColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 0.85)
        let faint = CGColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 0.32)
        // Generic glyph + menu placeholders.
        ctx.setFillColor(ink)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 18, y: y + 7, width: 11, height: 11), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        var x: CGFloat = 46
        for (i, wdt) in [CGFloat(46), 30, 30, 38, 44, 32].enumerated() {
            ctx.setFillColor(i == 0 ? ink : faint)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y + 9, width: wdt, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            x += wdt + 18
        }
        // Right side: a skateboard (this app), two status dots, a clock-shaped pill.
        var rx = Self.size.width - 18
        ctx.setFillColor(faint)
        rx -= 44
        ctx.addPath(CGPath(roundedRect: CGRect(x: rx, y: y + 9, width: 44, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        for _ in 0..<2 {
            rx -= 26
            ctx.fillEllipse(in: CGRect(x: rx, y: y + 7, width: 10, height: 10))
        }
        rx -= 34
        drawBoardIcon(ctx, at: CGPoint(x: rx + 10, y: y + 12), color: ink)
        ctx.restoreGState()
    }

    func drawBoardIcon(_ ctx: CGContext, at c: CGPoint, color: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineWidth(2.2)
        ctx.move(to: CGPoint(x: c.x - 10, y: c.y + 3))
        ctx.addQuadCurve(to: CGPoint(x: c.x - 6, y: c.y), control: CGPoint(x: c.x - 9, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + 6, y: c.y))
        ctx.addQuadCurve(to: CGPoint(x: c.x + 10, y: c.y + 3), control: CGPoint(x: c.x + 9, y: c.y))
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 6, width: 4.4, height: 4.4))
        ctx.fillEllipse(in: CGRect(x: c.x + 2.6, y: c.y - 6, width: 4.4, height: 4.4))
        ctx.restoreGState()
    }

    func drawWindow(_ w: DemoWindow, _ ctx: CGContext) {
        let f = w.frame
        let radius: CGFloat = 11
        let path = CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let front = order.first == w.id
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: front ? 44 : 30,
                      color: CGColor(srgbRed: 0.05, green: 0.08, blue: 0.2, alpha: front ? 0.32 : 0.22))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // Title bar.
        let tb: CGFloat = 30
        ctx.setFillColor(CGColor(srgbRed: 0.955, green: 0.963, blue: 0.976, alpha: 1))
        ctx.fill(CGRect(x: f.minX, y: f.maxY - tb, width: f.width, height: tb))
        ctx.setFillColor(CGColor(srgbRed: 0.87, green: 0.89, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: f.minX, y: f.maxY - tb - 1, width: f.width, height: 1))
        let lights: [CGColor] = [CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                                 CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                                 CGColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (i, c) in lights.enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: f.minX + 13 + CGFloat(i) * 19, y: f.maxY - tb / 2 - 6, width: 12, height: 12))
        }
        let pill = CGColor(srgbRed: 0.80, green: 0.83, blue: 0.87, alpha: 1)
        let block = CGColor(srgbRed: 0.925, green: 0.937, blue: 0.955, alpha: 1)
        let block2 = CGColor(srgbRed: 0.86, green: 0.885, blue: 0.915, alpha: 1)
        func rr(_ r: CGRect, _ c: CGColor, _ rad: CGFloat = 4) {
            ctx.setFillColor(c)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(rad, r.height / 2), cornerHeight: min(rad, r.height / 2), transform: nil))
            ctx.fillPath()
        }
        rr(CGRect(x: f.midX - 50, y: f.maxY - tb / 2 - 4, width: 100, height: 8), pill)

        let top = f.maxY - tb - 1
        switch w.style {
        case 0:
            // Sidebar + list.
            let sw: CGFloat = 150
            ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.972, blue: 0.982, alpha: 1))
            ctx.fill(CGRect(x: f.minX, y: f.minY, width: sw, height: top - f.minY))
            var y = top - 26
            for i in 0..<9 where y > f.minY + 14 {
                rr(CGRect(x: f.minX + 18, y: y, width: [80, 96, 64, 88, 72, 90, 60, 84, 70][i], height: 8),
                   i == 1 ? CGColor(srgbRed: 0.62, green: 0.72, blue: 0.9, alpha: 1) : block2)
                y -= 24
            }
            y = top - 34
            var row = 0
            while y > f.minY + 20 {
                rr(CGRect(x: f.minX + sw + 22, y: y - 6, width: 22, height: 22), block, 6)
                rr(CGRect(x: f.minX + sw + 56, y: y + 6, width: [190, 150, 220, 170, 200, 140][row % 6], height: 8), block2)
                rr(CGRect(x: f.minX + sw + 56, y: y - 6, width: [120, 180, 90, 140, 110, 160][row % 6], height: 7), block)
                y -= 46; row += 1
            }
        case 1:
            // Tile grid.
            let pad: CGFloat = 18, cols = 3
            let tw = (f.width - pad * CGFloat(cols + 1)) / CGFloat(cols)
            let th: CGFloat = 92
            let tints: [CGColor] = [
                CGColor(srgbRed: 0.80, green: 0.86, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.85, green: 0.90, blue: 0.93, alpha: 1),
                CGColor(srgbRed: 0.86, green: 0.84, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.82, green: 0.91, blue: 0.92, alpha: 1),
            ]
            var y = top - pad - th
            var k = 0
            while y > f.minY + 8 {
                for c in 0..<cols {
                    let x = f.minX + pad + CGFloat(c) * (tw + pad)
                    rr(CGRect(x: x, y: y + 22, width: tw, height: th - 22), tints[k % tints.count], 8)
                    rr(CGRect(x: x, y: y + 6, width: tw * 0.6, height: 7), block2)
                    k += 1
                }
                y -= th + pad
            }
        default:
            // Editor lines.
            var y = top - 28
            var i = 0
            let widths: [CGFloat] = [0.55, 0.8, 0.7, 0.4, 0.75, 0.62, 0.3, 0.68, 0.5]
            while y > f.minY + 14 {
                rr(CGRect(x: f.minX + 18, y: y, width: 14, height: 7), block)
                let indent: CGFloat = [0, 16, 16, 32, 16, 0, 16, 32, 16][i % 9]
                rr(CGRect(x: f.minX + 44 + indent, y: y, width: (f.width - 80) * widths[i % 9], height: 7),
                   i % 4 == 2 ? CGColor(srgbRed: 0.72, green: 0.80, blue: 0.94, alpha: 1) : block2)
                y -= 20; i += 1
            }
        }
        ctx.restoreGState()

        // Hairline border.
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.13, blue: 0.2, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The standard arrow pointer, tip at `p`. Slightly smaller when pressed.
    func drawCursor(at p: CGPoint, pressed: Bool, _ ctx: CGContext) {
        let s: CGFloat = pressed ? 0.92 : 1
        let pts: [CGPoint] = [(0, 0), (0, -17), (4, -13), (6.8, -19.4), (9.4, -18.3), (6.7, -12), (12, -12)]
            .map { CGPoint(x: p.x + $0.0 * s * 1.15, y: p.y + $0.1 * s * 1.15) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2.4)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
        ctx.addPath(path); ctx.fillPath()
    }
}
