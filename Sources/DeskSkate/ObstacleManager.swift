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

    private var panels: [ObstaclePanel] = []
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

    // MARK: - Private

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
    @objc private func panelMoved(_ note: Notification) {
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
