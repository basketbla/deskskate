import AppKit
import QuartzCore
import DeskSkateCore

/// Owns the overlay windows and the frame loop. (US-006)
final class GameController {
    static let shared = GameController()

    private(set) var skater: Skater?
    private(set) var world: WorldSnapshot?
    let renderer = SkaterRenderer()

    private let tracker = WindowTracker()
    private let autopilot = AutoPilot()
    private var panels: [OverlayPanel] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var lastEvents: [SkaterEvent] = []
    /// Global rect redrawn last frame, so a skater leaving a screen gets cleared once.
    private var lastDirty: CGRect = .null
    private var surfacesWereShown = false
    private var started = false
    // Windows are polled at 30Hz and extrapolated by their velocity in between.
    private var polledWindows: [TrackedWindow] = []
    private var lastPoll: CFTimeInterval = 0
    // Mouse grab: true from mouseDown on the skater until mouseUp.
    private var isDragging = false
    private var lastDragTime: CFTimeInterval = 0
    /// Which screen's overlay shows the controls card, so moving screens redraws both.
    private var hudScreen: CGRect = .null
    // Autonomous mode: seconds spent on the screen floor; long stretches end in a drop-in.
    private var groundTime: Double = 0
    private var nextDropIn = Double.random(in: 25...45)

    // Keyboard state.
    private var heldKeys = Set<UInt16>()
    private var jumpPressed = false
    private var jumpReleased = false
    private var trickPressed = false

    /// Half-size of the area around the skater that is redrawn each frame.
    private static let dirtyRadius: CGFloat = 120

    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3
        static let w: UInt16 = 13, r: UInt16 = 15, space: UInt16 = 49, esc: UInt16 = 53, slash: UInt16 = 44
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        skater = Skater(spawn: Self.spawnPoint(on: NSScreen.main ?? NSScreen.screens.first))
        DesktopIcons.shared.setEnabled(AppState.shared.desktopIcons)
        buildPanels()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                       queue: .main) { [weak self] _ in self?.buildPanels() }
        nc.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.appStateChanged()
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.redrawAll() }
        }
    }

    /// Drop the skater in at the mouse (kept inside the screen it is on).
    func respawn() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var point = mouse
        if let vf = screen?.visibleFrame {
            point.x = min(max(point.x, vf.minX + 20), vf.maxX - 20)
            point.y = min(max(point.y, vf.minY + 1), vf.maxY - 10)
        }
        if let skater {
            skater.respawn(at: point)
            renderer.handle(events: [.respawned], state: skater.state)
        } else {
            skater = Skater(spawn: point)
        }
        lastEvents = [.respawned]
        if AppState.shared.paused { redrawAll() }
    }

    /// Tall windows are out of ollie range, so an autonomous skater that has cruised the
    /// floor for a while drops back in from the top of a screen, over a random window ledge.
    private func dropInPoint(dt: Double, world: WorldSnapshot) -> CGPoint? {
        guard let skater else { return nil }
        let onFloor = skater.state.surfaceID?.hasPrefix("g") == true && skater.state.phase == .rolling
        groundTime = onFloor ? groundTime + dt : 0
        guard groundTime > nextDropIn else { return nil }
        groundTime = 0
        nextDropIn = Double.random(in: 25...45)
        let ledges = world.surfaces.filter { $0.kind == .ledge && $0.length > 100 }
        guard let ledge = ledges.randomElement(),
              let screen = world.screens.first(where: { $0.minX <= ledge.a.x + 1 && ledge.b.x - 1 <= $0.maxX })
        else { return nil }
        let x = CGFloat.random(in: (ledge.a.x + 30)...(ledge.b.x - 30))
        return CGPoint(x: x, y: screen.maxY - 30)
    }

    private static func spawnPoint(on screen: NSScreen?) -> CGPoint {
        guard let vf = screen?.visibleFrame else { return CGPoint(x: 400, y: 400) }
        return CGPoint(x: vf.midX, y: vf.maxY - 40)
    }

    // MARK: Panels

    private func buildPanels() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels = NSScreen.screens.map { OverlayPanel(screen: $0) }
        if !AppState.shared.hidden {
            for panel in panels { panel.orderFrontRegardless() }
        }

        if let view = panels.first?.overlayView {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            link.isPaused = AppState.shared.hidden
            displayLink = link
        }
        lastDirty = .null
        if AppState.shared.mode == .keyboard { focusKeyboardPanel() }
        redrawAll()
    }

    private func appStateChanged() {
        let state = AppState.shared
        DesktopIcons.shared.setEnabled(state.desktopIcons)
        if state.hidden {
            for panel in panels { panel.orderOut(nil) }
            displayLink?.isPaused = true
        } else {
            for panel in panels where !panel.isVisible { panel.orderFrontRegardless() }
            if displayLink?.isPaused == true {
                lastTimestamp = nil
                lastDirty = .null
                displayLink?.isPaused = false
                redrawAll()
            }
        }

        if state.mode == .keyboard {
            if !state.hidden { focusKeyboardPanel() }
        } else {
            // ModeController restores the previous app, which takes key from the panel.
            clearKeys()
        }

        if state.showSurfaces != surfacesWereShown {
            surfacesWereShown = state.showSurfaces
            redrawAll()
        }
    }

    func focusKeyboardPanel() {
        let position = skater?.state.position ?? .zero
        let panel = panels.first { NSMouseInRect(position, $0.frame, false) }
            ?? panels.first { $0.screen == NSScreen.main }
            ?? panels.first
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.overlayView)
    }

    private func redrawAll() {
        for panel in panels { panel.overlayView.needsDisplay = true }
    }

    // MARK: Frame loop

    @objc private func frame(_ link: CADisplayLink) {
        let state = AppState.shared
        guard !state.hidden, let skater else { return }

        let dt: Double
        if let last = lastTimestamp {
            dt = link.targetTimestamp - last
        } else {
            dt = link.targetTimestamp - link.timestamp
        }
        lastTimestamp = link.targetTimestamp
        let clampedDT = min(max(dt, 0), 1.0 / 20)

        let now = CACurrentMediaTime()
        if now - lastPoll >= 1.0 / 30 {
            polledWindows = tracker.poll(now: now)
            lastPoll = now
        }
        let ahead = CGFloat(now - lastPoll)
        let windows = ahead > 0 ? polledWindows.map { w -> TrackedWindow in
            var w = w
            w.frame = w.frame.offsetBy(dx: w.velocity.dx * ahead, dy: w.velocity.dy * ahead)
            return w
        } : polledWindows
        let icons = DesktopIcons.shared.frames.enumerated().map { i, frame in
            TrackedWindow(id: SurfaceBuilder.iconIDBase + UInt32(i), frame: frame, zIndex: windows.count + i)
        }
        let obstacles = ObstacleManager.shared.currentModels(dt: clampedDT)
        let world = SurfaceBuilder.build(windows: windows + icons, screens: WindowTracker.screenFrames(),
                                         obstacles: obstacles, docks: tracker.dockFrames)
        self.world = world
        ObstacleManager.shared.applyGravity(dt: clampedDT, world: world)
        liftOntoDock(world: world)
        updateMouseHover()

        if !state.paused, clampedDT > 0 {
            let input: SkaterInput
            if state.mode == .keyboard {
                input = keyboardInput()
            } else {
                input = autopilot.input(state: skater.state, world: world, events: lastEvents, dt: clampedDT)
            }
            var events = skater.step(dt: clampedDT, input: input, world: world)
            if state.mode == .autonomous, let point = dropInPoint(dt: clampedDT, world: world) {
                skater.respawn(at: point)
                events.append(.respawned)
            }
            renderer.handle(events: events, state: skater.state)
            lastEvents = events
            renderer.update(dt: clampedDT)
        }

        invalidate(around: skater.state.position, paused: state.paused, showSurfaces: state.showSurfaces)
        let screen = hudVisible ? (screenFrame(containing: skater.state.position) ?? .null) : .null
        if screen != hudScreen {
            hudScreen = screen
            redrawAll()
        }
    }

    /// The Dock slid up over the floor the skater is rolling on: pop him up onto it.
    private func liftOntoDock(world: WorldSnapshot) {
        guard let skater, !skater.isHeld, skater.state.surfaceID?.hasPrefix("g") == true else { return }
        let p = skater.state.position
        for dock in world.surfaces where dock.id.hasPrefix("dock-") {
            if dock.a.x <= p.x, p.x <= dock.b.x, dock.a.y > p.y + 2, dock.a.y < p.y + 250 {
                skater.respawn(at: CGPoint(x: p.x, y: dock.a.y + 1))
                return
            }
        }
    }

    private func screenFrame(containing point: CGPoint) -> CGRect? {
        panels.map(\.frame).first { $0.contains(point) }
    }

    // MARK: Controls card

    /// Shown in keyboard mode on the skater's screen until `/` hides it.
    var hudVisible: Bool {
        let state = AppState.shared
        return state.mode == .keyboard && state.showControls && !state.hidden
    }

    /// The screen frame whose overlay draws the card, if any.
    var controlsScreen: CGRect? { hudScreen.isNull ? nil : hudScreen }

    // MARK: Mouse grab

    /// Hit box around the skater (board at the bottom, head ~45pt up).
    private func skaterHitRect() -> CGRect {
        guard let p = skater?.state.position else { return .null }
        return CGRect(x: p.x - 24, y: p.y - 8, width: 48, height: 62)
    }

    /// Overlays ignore the mouse except right over the skater, so he can be picked up while
    /// clicks everywhere else go to the windows underneath.
    private func updateMouseHover() {
        guard !isDragging else { return }
        let mouse = NSEvent.mouseLocation
        let hover = !AppState.shared.hidden && skaterHitRect().contains(mouse)
        for panel in panels {
            let ignore = !(hover && NSMouseInRect(mouse, panel.frame, false))
            if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
        }
    }

    /// Physics keeps the board's position; the held pose hangs below the mouse.
    private func boardPoint(forMouse mouse: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x, y: mouse.y - SkaterRenderer.heldBoardOffset)
    }

    func mouseDown() {
        guard let skater else { return }
        isDragging = true
        lastDragTime = CACurrentMediaTime()
        let events = skater.grab(at: boardPoint(forMouse: NSEvent.mouseLocation))
        renderer.handle(events: events, state: skater.state)
        lastEvents = events
        NSCursor.closedHand.push()
    }

    func mouseDragged() {
        guard isDragging, let skater else { return }
        let now = CACurrentMediaTime()
        skater.drag(to: boardPoint(forMouse: NSEvent.mouseLocation), dt: max(now - lastDragTime, 1.0 / 240))
        lastDragTime = now
        if AppState.shared.paused { redrawAll() }
    }

    func mouseUp() {
        guard isDragging, let skater else { return }
        isDragging = false
        mouseDragged()
        let events = skater.release()
        renderer.handle(events: events, state: skater.state)
        lastEvents = events
        NSCursor.pop()
        updateMouseHover()
    }

    private func invalidate(around position: CGPoint, paused: Bool, showSurfaces: Bool) {
        if showSurfaces {
            redrawAll()
            return
        }
        if paused && lastDirty.contains(position) { return }

        let r = Self.dirtyRadius
        let current = CGRect(x: position.x - r, y: position.y - r, width: 2 * r, height: 2 * r)
            .union(renderer.effectsBounds)
        let dirty = lastDirty.isNull ? current : current.union(lastDirty)
        lastDirty = current
        guard dirty.width.isFinite, dirty.height.isFinite else { return }

        for panel in panels {
            let frame = panel.frame
            guard frame.intersects(dirty) else { continue }
            let local = dirty.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
            panel.overlayView.setNeedsDisplay(local)
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was handled.
    func keyDown(_ event: NSEvent) -> Bool {
        guard AppState.shared.mode == .keyboard else { return false }
        let code = event.keyCode
        guard Self.isGameKey(code) else { return false }
        if event.isARepeat { return true }
        heldKeys.insert(code)
        switch code {
        case Key.space: jumpPressed = true
        case Key.up, Key.w, Key.f: trickPressed = true
        case Key.r: respawn()
        case Key.slash: AppState.shared.showControls.toggle()
        case Key.esc:
            clearKeys()
            AppState.shared.mode = .autonomous
        default: break
        }
        return true
    }

    func keyUp(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        guard Self.isGameKey(code) else { return false }
        if heldKeys.remove(code) != nil, code == Key.space { jumpReleased = true }
        return true
    }

    private static func isGameKey(_ code: UInt16) -> Bool {
        switch code {
        case Key.a, Key.s, Key.d, Key.f, Key.w, Key.r, Key.space, Key.esc, Key.slash,
             Key.left, Key.right, Key.down, Key.up: true
        default: false
        }
    }

    private func keyboardInput() -> SkaterInput {
        let input = SkaterInput(
            left: heldKeys.contains(Key.left) || heldKeys.contains(Key.a),
            right: heldKeys.contains(Key.right) || heldKeys.contains(Key.d),
            jump: heldKeys.contains(Key.space),
            jumpPressed: jumpPressed,
            jumpReleased: jumpReleased,
            trickPressed: trickPressed,
            grind: heldKeys.contains(Key.down) || heldKeys.contains(Key.s))
        jumpPressed = false
        jumpReleased = false
        trickPressed = false
        return input
    }

    private func clearKeys() {
        heldKeys.removeAll()
        jumpPressed = false
        jumpReleased = false
        trickPressed = false
    }
}
