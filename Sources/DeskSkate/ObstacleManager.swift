import AppKit
import DeskSkateCore

/// The draggable ramps and obstacles on the desktop. (US-008)
final class ObstacleManager {
    static let shared = ObstacleManager()

    private static let defaultsKey = "obstacles"
    /// Above any CGWindowID, so obstacle surface owners never collide with window owners.
    private static let firstOwnerID: UInt32 = 0xF000_0000
    /// A frame jump bigger than this between two game frames is a teleport, not a drag.
    private static let teleportDistance: CGFloat = 400
    private static let smoothing: CGFloat = 0.5

    private struct Motion {
        var lastFrame: CGRect
        var velocity: CGVector = .zero
        var stillFrames = 0
    }

    /// Gravity state per obstacle. Missing = falling from rest.
    private enum Fall {
        /// Sitting on the surface with this id.
        case resting(String)
        /// In the air with this velocity (points/second).
        case falling(CGVector)
    }

    private static let gravity: CGFloat = 1900
    private static let maxFallSpeed: CGFloat = 2500
    /// Fraction of the mouse's release velocity a thrown obstacle keeps.
    private static let throwCarry: CGFloat = 0.6
    /// Floors are surfaces whose normal points at least this much up.
    private static let floorNormalY: CGFloat = 0.7

    private var panels: [ObstaclePanel] = []
    private var fall: [UUID: Fall] = [:]
    /// Obstacles that were being dragged last frame; their release starts a throw.
    private var dragging: Set<UUID> = []
    /// Every surface's endpoints last frame, by id, to measure how a support moved.
    private var previousSurfaces: [String: (a: CGPoint, b: CGPoint)] = [:]
    private var motion: [UUID: Motion] = [:]
    private var nextOwnerID = ObstacleManager.firstOwnerID
    private var saveWork: DispatchWorkItem?
    private var observing = false

    // MARK: - Lifecycle

    func restore() {
        startObserving()
        var models: [ObstacleModel] = []
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ObstacleModel].self, from: data) {
            models = decoded
            for i in models.indices { models[i].frame = Self.pulledOnScreen(models[i].frame) }
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            // First launch: show what obstacles are.
            let vf = screen.visibleFrame
            models = [
                Self.groundModel(.kicker, centerX: vf.minX + 0.30 * vf.width, in: vf),
                Self.groundModel(.quarterPipe, centerX: vf.minX + 0.75 * vf.width, in: vf),
            ]
        }
        for m in models { makePanel(m) }
        save()
    }

    func save() {
        saveWork?.cancel(); saveWork = nil
        let models = panels.map {
            ObstacleModel(id: $0.obstacleID, kind: $0.kind, frame: $0.obstacleFrame, flipped: $0.flipped)
        }
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Editing

    /// Drops a new obstacle on the ground of the screen under the mouse, near the mouse x.
    func add(_ kind: ObstacleKind) {
        startObserving()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        makePanel(Self.groundModel(kind, centerX: mouse.x, in: vf))
        save()
    }

    func remove(id: UUID) {
        guard let i = panels.firstIndex(where: { $0.obstacleID == id }) else { return }
        let panel = panels.remove(at: i)
        motion[id] = nil
        fall[id] = nil
        dragging.remove(id)
        panel.orderOut(nil)
        panel.close()
        save()
    }

    func flip(id: UUID) {
        guard let panel = panels.first(where: { $0.obstacleID == id }) else { return }
        panel.flipped.toggle()
        save()
    }

    func removeAll() {
        for p in panels { p.orderOut(nil); p.close() }
        panels.removeAll()
        motion.removeAll()
        fall.removeAll()
        dragging.removeAll()
        save()
    }

    // MARK: - Game loop

    /// Obstacles as they are right now (frames follow drags live, with velocity), for the
    /// surface builder. Called once per frame by the game loop.
    func currentModels(dt: Double) -> [ObstacleModel] {
        if AppState.shared.hidden { return [] }
        let dt = CGFloat(max(dt, 1.0 / 240))
        return panels.map { panel in
            let frame = panel.obstacleFrame
            var m = motion[panel.obstacleID] ?? Motion(lastFrame: frame)
            let delta = CGVector(dx: frame.minX - m.lastFrame.minX, dy: frame.minY - m.lastFrame.minY)
            if delta.length > Self.teleportDistance {
                m.velocity = .zero
                m.stillFrames = 0
            } else if delta.length < 0.01 {
                m.stillFrames += 1
                m.velocity = m.stillFrames >= 2 ? .zero : m.velocity * (1 - Self.smoothing)
            } else {
                m.stillFrames = 0
                m.velocity = m.velocity * (1 - Self.smoothing) + (delta * (1 / dt)) * Self.smoothing
            }
            m.lastFrame = frame
            motion[panel.obstacleID] = m
            return ObstacleModel(id: panel.obstacleID, kind: panel.kind, frame: frame,
                                 flipped: panel.flipped, ownerID: panel.ownerID, velocity: m.velocity)
        }
    }

    /// Drops, carries and lands obstacles when `AppState.obstacleGravity` is on. Called once
    /// per frame by the game loop right after it builds `world`. With gravity off it does
    /// nothing and obstacles stay where they were put (mid-air ones freeze).
    func applyGravity(dt: Double, world: WorldSnapshot) {
        defer {
            var map: [String: (a: CGPoint, b: CGPoint)] = [:]
            map.reserveCapacity(world.surfaces.count)
            for s in world.surfaces { map[s.id] = (s.a, s.b) }
            previousSurfaces = map
        }
        guard AppState.shared.obstacleGravity, !AppState.shared.hidden else {
            fall.removeAll()
            dragging.removeAll()
            return
        }
        let dt = CGFloat(min(max(dt, 0), 1.0 / 20))
        guard dt > 0 else { return }

        for panel in panels {
            let id = panel.obstacleID
            if panel.isBeingDragged {
                dragging.insert(id)
                fall[id] = nil
                continue
            }
            if dragging.remove(id) != nil {
                fall[id] = .falling(panel.releaseVelocity * Self.throwCarry)
            }
            let state = fall[id] ?? .falling(.zero)
            var frame = panel.obstacleFrame

            switch state {
            case .resting(let supportID):
                if let support = world.surface(id: supportID) {
                    if let prev = previousSurfaces[supportID] {
                        let d = Self.displacement(support, previous: prev)
                        frame.origin.x += d.dx
                        frame.origin.y += d.dy
                    }
                    if let y = Self.surfaceY(support, atX: frame.midX) {
                        frame.origin.y = y
                        move(panel, to: frame)
                        continue
                    }
                }
                // Support vanished or slid out from under us: start falling from here.
                stepFall(panel, frame: frame, velocity: .zero, dt: dt, world: world)

            case .falling(let v):
                stepFall(panel, frame: frame, velocity: v, dt: dt, world: world)
            }
        }
    }

    // MARK: - Private

    /// One step of free fall for `panel` from `frame`: integrate, then land or keep falling.
    private func stepFall(_ panel: ObstaclePanel, frame start: CGRect, velocity v0: CGVector, dt: CGFloat,
                      world: WorldSnapshot) {
        let id = panel.obstacleID
        var v = v0
        v.dy = max(v.dy - Self.gravity * dt, -Self.maxFallSpeed)
        var frame = start
        frame.origin.x += v.dx * dt
        frame.origin.y += v.dy * dt

        // Thrown sideways past the edge of every screen: stop at the nearest one's side.
        if let screen = Self.nearestScreen(toX: frame.midX, in: world.screens),
           !world.screens.contains(where: { frame.midX >= $0.minX && frame.midX <= $0.maxX }) {
            frame.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
            v.dx = 0
        }

        if let landing = Self.landing(ownerID: panel.ownerID, x: frame.midX, prevBottom: start.minY,
                                      newBottom: frame.minY, world: world) {
            frame.origin.y = landing.y
            fall[id] = .resting(landing.id)
            move(panel, to: frame)
            scheduleSave()
            return
        }

        // Fell below the screens: put it back on the ground of the nearest one.
        if let screen = Self.nearestScreen(toX: frame.midX, in: world.screens), frame.maxY < screen.minY {
            frame.origin.y = screen.minY
            frame.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
            let groundID = world.surfaces.first {
                $0.kind == .ground && $0.ownerID == nil && abs($0.a.y - screen.minY) < 1
                    && frame.midX >= min($0.a.x, $0.b.x) && frame.midX <= max($0.a.x, $0.b.x)
            }?.id
            fall[id] = groundID.map { .resting($0) } ?? .falling(.zero)
            move(panel, to: frame)
            scheduleSave()
            return
        }

        fall[id] = .falling(v)
        move(panel, to: frame)
    }

    /// The highest floor-like surface (not one of this obstacle's own) under `x` whose height
    /// the obstacle's bottom crossed from above this frame.
    static func landing(ownerID: UInt32, x: CGFloat, prevBottom: CGFloat, newBottom: CGFloat,
                        world: WorldSnapshot) -> (id: String, y: CGFloat)? {
        var best: (id: String, y: CGFloat)?
        for s in world.surfaces {
            guard s.kind != .wall, s.normal.dy > floorNormalY else { continue }
            if let owner = s.ownerID, owner == ownerID { continue }
            guard let y = surfaceY(s, atX: x) else { continue }
            guard prevBottom >= y - 1, newBottom <= y else { continue }
            if best == nil || y > best!.y { best = (s.id, y) }
        }
        return best
    }

    /// How a support moved since last frame: `a`'s displacement when it moved rigidly. When its
    /// ends moved differently (a window resized, or a ledge clipped by a window in front), the
    /// horizontal part is the smaller of the two ends' so the rider isn't flung sideways.
    static func displacement(_ s: Surface, previous: (a: CGPoint, b: CGPoint)) -> CGVector {
        let da = s.a - previous.a, db = s.b - previous.b
        if abs(da.dx - db.dx) <= 1 { return da }
        return CGVector(dx: abs(da.dx) < abs(db.dx) ? da.dx : db.dx, dy: da.dy)
    }

    /// Height of `s` at `x`, or nil when `x` is outside its horizontal span.
    static func surfaceY(_ s: Surface, atX x: CGFloat) -> CGFloat? {
        let lo = min(s.a.x, s.b.x), hi = max(s.a.x, s.b.x)
        guard hi - lo > 0.001, x >= lo, x <= hi else { return nil }
        let t = (x - s.a.x) / (s.b.x - s.a.x)
        return s.a.y + t * (s.b.y - s.a.y)
    }

    static func nearestScreen(toX x: CGFloat, in screens: [CGRect]) -> CGRect? {
        screens.min { distance(x, $0) < distance(x, $1) }
    }

    private static func distance(_ x: CGFloat, _ r: CGRect) -> CGFloat {
        x < r.minX ? r.minX - x : (x > r.maxX ? x - r.maxX : 0)
    }

    /// Moves the panel so its obstacle box is `frame`; skips sub-pixel no-ops.
    private func move(_ panel: ObstaclePanel, to frame: CGRect) {
        let current = panel.obstacleFrame
        guard abs(current.minX - frame.minX) > 0.01 || abs(current.minY - frame.minY) > 0.01 else { return }
        panel.setFrameOrigin(NSPoint(x: frame.minX - ObstaclePanel.padding, y: frame.minY - ObstaclePanel.padding))
    }

    private func makePanel(_ model: ObstacleModel) {
        let ownerID = nextOwnerID
        nextOwnerID &+= 1
        let panel = ObstaclePanel(model: model, ownerID: ownerID)
        let id = model.id
        panel.onDragEnded = { [weak self] in self?.save() }
        panel.onFlip = { [weak self] in self?.flip(id: id) }
        panel.onRemove = { [weak self] in
            // Let the context menu finish tearing down before the panel goes away.
            DispatchQueue.main.async { self?.remove(id: id) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved(_:)),
                                               name: NSWindow.didMoveNotification, object: panel)
        panels.append(panel)
        motion[id] = Motion(lastFrame: panel.obstacleFrame)
        if !AppState.shared.hidden { panel.orderFrontRegardless() }
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(appStateChanged),
                                               name: .appStateChanged, object: nil)
    }

    @objc private func appStateChanged() {
        let hidden = AppState.shared.hidden
        for p in panels {
            if hidden { p.orderOut(nil) } else if !p.isVisible { p.orderFrontRegardless() }
        }
    }

    /// Debounced save for moves that don't end in our own mouseUp (e.g. screen changes).
    @objc private func panelMoved(_ note: Notification) { scheduleSave() }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func groundModel(_ kind: ObstacleKind, centerX: CGFloat, in vf: CGRect) -> ObstacleModel {
        let size = kind.defaultSize
        let frame = CGRect(x: centerX - size.width / 2, y: vf.minY, width: size.width, height: size.height)
        return ObstacleModel(kind: kind, frame: clamp(frame, inside: vf))
    }

    private static func clamp(_ r: CGRect, inside vf: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.minX, vf.minX), max(vf.minX, vf.maxX - r.width))
        r.origin.y = min(max(r.minY, vf.minY), max(vf.minY, vf.maxY - r.height))
        return r
    }

    /// Keeps a restored frame if it is on any screen; otherwise drops it on the main screen's ground.
    private static func pulledOnScreen(_ frame: CGRect) -> CGRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return frame }
        var r = frame
        r.origin.x = frame.minX
        r.origin.y = vf.minY
        return clamp(r, inside: vf)
    }
}
