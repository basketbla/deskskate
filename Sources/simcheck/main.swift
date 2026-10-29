import CoreGraphics
import DeskSkateCore
import Foundation

// Headless physics scenarios. (US-010)
//
//   swift run simcheck            run every scenario
//   swift run simcheck <filter>   run scenarios whose name contains <filter>
//   SIMCHECK_TRACE=1              print a per-frame trace for each scenario run

let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
let dt = 1.0 / 60
let traceEnabled = ProcessInfo.processInfo.environment["SIMCHECK_TRACE"] != nil

// MARK: - Harness

/// Held controls for one frame; the harness derives jump edges from consecutive frames.
struct Controls {
    var left = false
    var right = false
    var jump = false
    var trick = false
    var grind = false
}

final class Sim {
    var windows: [TrackedWindow]
    var obstacles: [ObstacleModel]
    let skater: Skater
    var world: WorldSnapshot
    var time: Double = 0
    var frame = 0
    var events: [(frame: Int, event: SkaterEvent)] = []
    var lastEvents: [SkaterEvent] = []
    private var prevJump = false
    private var prevTrick = false

    init(windows: [TrackedWindow] = [], obstacles: [ObstacleModel] = [], spawn: CGPoint) {
        self.windows = windows
        self.obstacles = obstacles
        skater = Skater(spawn: spawn)
        world = SurfaceBuilder.build(windows: windows, screens: [screen], obstacles: obstacles)
    }

    var state: SkaterState { skater.state }

    /// Moves windows by their velocity, rebuilds the world, steps the skater.
    func step(_ c: Controls = Controls()) {
        for i in windows.indices {
            let v = windows[i].velocity
            windows[i].frame = windows[i].frame.offsetBy(dx: v.dx * dt, dy: v.dy * dt)
        }
        world = SurfaceBuilder.build(windows: windows, screens: [screen], obstacles: obstacles)
        let input = SkaterInput(left: c.left, right: c.right, jump: c.jump,
                                jumpPressed: c.jump && !prevJump, jumpReleased: !c.jump && prevJump,
                                trickPressed: c.trick && !prevTrick, grind: c.grind)
        prevJump = c.jump
        prevTrick = c.trick
        step(input: input)
    }

    func step(input: SkaterInput) {
        lastEvents = skater.step(dt: dt, input: input, world: world)
        for e in lastEvents { events.append((frame, e)) }
        time += dt
        frame += 1
        if traceEnabled { print("    " + trace()) }
    }

    func run(seconds: Double, _ controls: (Sim) -> Controls = { _ in Controls() }) {
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n { step(controls(self)) }
    }

    /// Steps until `done` is true or `seconds` elapse. Returns whether `done` became true.
    @discardableResult
    func run(until done: (Sim) -> Bool, max seconds: Double, _ controls: (Sim) -> Controls = { _ in Controls() }) -> Bool {
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n {
            if done(self) { return true }
            step(controls(self))
        }
        return done(self)
    }

    func setVelocity(window id: UInt32, _ v: CGVector) {
        if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].velocity = v }
    }

    func window(_ id: UInt32) -> TrackedWindow? { windows.first { $0.id == id } }

    func saw(_ e: SkaterEvent) -> Bool { events.contains { $0.event == e } }

    func trace() -> String {
        let s = state
        return String(format: "f%4d t=%.3f pos=(%.1f, %.1f) v=(%.1f, %.1f) ", frame, time,
                      s.position.x, s.position.y, s.velocity.dx, s.velocity.dy)
            + "\(phaseName(s.phase)) surf=\(s.surfaceID ?? "-") ev=\(lastEvents)"
    }
}

func phaseName(_ p: SkaterPhase) -> String {
    switch p {
    case .rolling: "rolling"
    case .airborne: "airborne"
    case .grinding: "grinding"
    case .bailed(let r): String(format: "bailed(%.2f)", r)
    }
}

func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
func pt(_ p: CGPoint) -> String { "(\(f(p.x)), \(f(p.y)))" }

/// Settled on a surface: rolling, on the expected surface prefix, at the expected height.
func settled(_ s: SkaterState, prefix: String, y: CGFloat) -> Bool {
    s.phase == .rolling && (s.surfaceID?.hasPrefix(prefix) ?? false) && abs(s.position.y - y) < 1
}

func describe(_ s: SkaterState) -> String {
    "pos=\(pt(s.position)) v=(\(f(s.velocity.dx)), \(f(s.velocity.dy))) phase=\(phaseName(s.phase)) surf=\(s.surfaceID ?? "nil")"
}

func eventSummary(_ sim: Sim) -> String {
    var counts: [String: Int] = [:]
    for (_, e) in sim.events { counts["\(e)", default: 0] += 1 }
    return counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
}

typealias Result = (pass: Bool, detail: String)

// MARK: - Scenarios

func dropOntoLedge() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 400, y: 200, width: 500, height: 300), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 600, y: 700))
    sim.run(seconds: 2)
    let s = sim.state
    let ok = settled(s, prefix: "w1", y: 500) && abs(s.velocity.dx) < 1 && abs(s.position.x - 600) < 2
    return (ok, "ledgeY=500 \(describe(s)) events=\(eventSummary(sim))")
}

func rollOffLedgeOntoLower() -> Result {
    // Upper window x 300…600 top 500; lower window behind it, x 500…1000 top 300 (visible 600…1000).
    let upper = TrackedWindow(id: 1, frame: CGRect(x: 300, y: 200, width: 300, height: 300), zIndex: 0)
    let lower = TrackedWindow(id: 2, frame: CGRect(x: 500, y: 100, width: 500, height: 200), zIndex: 1)
    let sim = Sim(windows: [upper, lower], spawn: CGPoint(x: 400, y: 540))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "w1", y: 500) else {
        return (false, "did not settle on upper ledge first: \(describe(sim.state))")
    }
    var leftUpper = false
    var maxX: CGFloat = 0
    let landed = sim.run(until: { $0.state.phase == .rolling && ($0.state.surfaceID?.hasPrefix("w2") ?? false) },
                         max: 4) { sim in
        if sim.state.phase == .airborne { leftUpper = true }
        maxX = max(maxX, sim.state.position.x)
        return Controls(right: sim.state.phase == .rolling && (sim.state.surfaceID?.hasPrefix("w1") ?? false))
    }
    sim.run(seconds: 0.3)
    let s = sim.state
    let ok = landed && leftUpper && settled(s, prefix: "w2", y: 300) && s.position.x > 600 && s.position.x < 1000
    return (ok, "wentAirborne=\(leftUpper) landedOnW2=\(landed) lowerY=300 \(describe(s)) events=\(eventSummary(sim))")
}

func rideMovingWindow() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 300, y: 200, width: 500, height: 300), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 550, y: 520))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "w1", y: 500) else {
        return (false, "did not settle first: \(describe(sim.state))")
    }
    let x0 = sim.state.position.x
    let wx0 = sim.window(1)!.frame.minX
    sim.setVelocity(window: 1, CGVector(dx: 300, dy: 0))
    sim.run(seconds: 1.5)
    let midVX = sim.state.velocity.dx
    sim.setVelocity(window: 1, .zero)
    sim.run(seconds: 0.5)
    let s = sim.state
    let windowShift = sim.window(1)!.frame.minX - wx0
    let skaterShift = s.position.x - x0
    let ok = settled(s, prefix: "w1", y: 500) && abs(skaterShift - windowShift) < 15 && abs(midVX - 300) < 20
    return (ok, "windowShift=\(f(windowShift)) skaterShift=\(f(skaterShift)) vxWhileMoving=\(f(midVX)) \(describe(s))")
}

func flickWindowUp() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 400, y: 100, width: 500, height: 300), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 650, y: 420))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "w1", y: 400) else {
        return (false, "did not settle first: \(describe(sim.state))")
    }
    sim.setVelocity(window: 1, CGVector(dx: 0, dy: 900))
    sim.run(seconds: 0.15)
    sim.setVelocity(window: 1, .zero)
    let top = sim.window(1)!.frame.maxY
    var maxRise: CGFloat = -.infinity
    var sawAir = false
    sim.run(seconds: 1.2) { sim in
        maxRise = max(maxRise, sim.state.position.y - top)
        if sim.state.phase == .airborne { sawAir = true }
        return Controls()
    }
    let s = sim.state
    let ok = sawAir && maxRise > 40 && settled(s, prefix: "w1", y: top)
    return (ok, "newTop=\(f(top)) maxRiseAboveTop=\(f(maxRise)) wentAirborne=\(sawAir) final \(describe(s)) events=\(eventSummary(sim))")
}

func windowRemoved() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 400, y: 200, width: 500, height: 300), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 600, y: 520))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "w1", y: 500) else {
        return (false, "did not settle first: \(describe(sim.state))")
    }
    sim.windows.removeAll()
    sim.step()
    let airborneNext = sim.state.phase == .airborne
    sim.run(seconds: 1.5)
    let s = sim.state
    let ok = airborneNext && settled(s, prefix: "g0", y: 0)
    return (ok, "airborneFrameAfterRemoval=\(airborneNext) final \(describe(s)) events=\(eventSummary(sim))")
}

func quarterPipe() -> Result {
    let qp = ObstacleModel(kind: .quarterPipe, frame: CGRect(x: 800, y: 0, width: 140, height: 120), ownerID: 100)
    let sim = Sim(obstacles: [qp], spawn: CGPoint(x: 150, y: 5))
    // Push up to ~350 pt/s, then coast from x=500 on.
    sim.run(until: { $0.state.position.x >= 500 }, max: 4) { sim in Controls(right: sim.state.velocity.dx < 350) }
    let entry = sim.state.velocity.dx
    var maxY: CGFloat = 0
    var cameBack = false
    var sawVertAir = false
    var surfaces = Set<String>()
    sim.run(seconds: 4) { sim in
        maxY = max(maxY, sim.state.position.y)
        if sim.skater.isInVertAir { sawVertAir = true }
        if let id = sim.state.surfaceID { surfaces.insert(id.split(separator: "-").prefix(2).joined(separator: "-")) }
        if maxY > 60 && sim.state.velocity.dx < -20 { cameBack = true }
        return Controls()
    }
    let s = sim.state
    let ok = entry > 300 && maxY > 60 && cameBack
    return (ok, "entryVx=\(f(entry)) maxY=\(f(maxY)) cameBack=\(cameBack) vertAir=\(sawVertAir) surfaces=\(surfaces.sorted()) final \(describe(s)) events=\(eventSummary(sim))")
}

func kicker() -> Result {
    let k = ObstacleModel(kind: .kicker, frame: CGRect(x: 800, y: 0, width: 110, height: 44), ownerID: 101)
    let sim = Sim(obstacles: [k], spawn: CGPoint(x: 150, y: 5))
    sim.run(until: { $0.state.position.x >= 500 }, max: 4) { sim in Controls(right: sim.state.velocity.dx < 380) }
    let entry = sim.state.velocity.dx
    var onRamp = false
    var maxY: CGFloat = 0
    var airStart: Double?
    var airTime = 0.0
    var landedX: CGFloat?
    sim.run(seconds: 3) { sim in
        let s = sim.state
        if s.surfaceID?.hasPrefix("o101") ?? false { onRamp = true }
        if onRamp && s.phase == .airborne {
            if airStart == nil { airStart = sim.time }
            maxY = max(maxY, s.position.y)
        }
        if let a = airStart, landedX == nil, s.phase != .airborne {
            airTime = sim.time - a
            landedX = s.position.x
        }
        return Controls()
    }
    let ok = onRamp && airStart != nil && airTime > 0.15 && maxY > 44 && (landedX ?? 0) > 910
    return (ok, "entryVx=\(f(entry)) rodeRamp=\(onRamp) airTime=\(String(format: "%.2f", airTime))s maxY=\(f(maxY)) landedX=\(landedX.map(f) ?? "nil") final \(describe(sim.state)) events=\(eventSummary(sim))")
}

/// Pushes to `speed`, crouches at `crouchX`, pops at `popX`, then holds `grind`.
func ollieController(speed: CGFloat, crouchX: CGFloat, popX: CGFloat, grind: Bool) -> (Sim) -> Controls {
    var popped = false
    return { sim in
        let x = sim.state.position.x
        if !popped && x >= popX && sim.state.phase == .rolling { popped = true }
        let crouching = !popped && x >= crouchX
        return Controls(right: !popped && sim.state.velocity.dx < speed, jump: crouching, grind: grind && popped)
    }
}

func grindRailScenario() -> Result {
    let rail = ObstacleModel(kind: .rail, frame: CGRect(x: 700, y: 0, width: 220, height: 40), ownerID: 102)
    let sim = Sim(obstacles: [rail], spawn: CGPoint(x: 150, y: 5))
    let controller = ollieController(speed: 350, crouchX: 480, popX: 560, grind: true)
    var grindFrames = 0
    var grindSurf: String?
    var grindY: CGFloat = 0
    var grindXs: (CGFloat, CGFloat) = (.infinity, -.infinity)
    sim.run(seconds: 4) { sim in
        let s = sim.state
        if s.phase == .grinding {
            grindFrames += 1
            grindSurf = s.surfaceID
            grindY = s.position.y
            grindXs = (min(grindXs.0, s.position.x), max(grindXs.1, s.position.x))
        }
        return controller(sim)
    }
    // After the rail ends the skater must drop off it and roll away on the floor.
    let rodeAway = settled(sim.state, prefix: "g0", y: 0) && sim.state.position.x > 916
    let ok = sim.saw(.ollie) && sim.saw(.grindStart) && grindFrames >= 15
        && (grindSurf?.hasPrefix("o102") ?? false) && abs(grindY - 40) < 1 && rodeAway
    let span = grindFrames > 0 ? "\(f(grindXs.0))…\(f(grindXs.1))" : "-"
    return (ok, "grindFrames=\(grindFrames) (\(String(format: "%.2f", Double(grindFrames) * dt))s) surf=\(grindSurf ?? "nil") railY=40 grindY=\(f(grindY)) grindX=\(span) rodeAwayOnFloor=\(rodeAway) final \(describe(sim.state)) events=\(eventSummary(sim))")
}

func ollieOntoHigherLedge() -> Result {
    // A window whose top (y=80) sits above the floor, 700…1100.
    let w = TrackedWindow(id: 1, frame: CGRect(x: 700, y: 0, width: 400, height: 80), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 150, y: 5))
    let controller = ollieController(speed: 350, crouchX: 450, popX: 560, grind: false)
    var landedOnLedge = false
    sim.run(seconds: 3) { sim in
        if settled(sim.state, prefix: "w1", y: 80) { landedOnLedge = true }
        return controller(sim)
    }
    let ok = sim.saw(.ollie) && landedOnLedge
    return (ok, "ledgeY=80 landedOnLedge=\(landedOnLedge) final \(describe(sim.state)) events=\(eventSummary(sim))")
}

func autopilot60s() -> Result {
    let windows = [
        TrackedWindow(id: 1, frame: CGRect(x: 80, y: 300, width: 520, height: 380), zIndex: 0),
        TrackedWindow(id: 2, frame: CGRect(x: 500, y: 120, width: 600, height: 420), zIndex: 1),
        TrackedWindow(id: 3, frame: CGRect(x: 950, y: 400, width: 420, height: 300), zIndex: 2),
    ]
    let obstacles = [
        ObstacleModel(kind: .quarterPipe, frame: CGRect(x: 1250, y: 0, width: 140, height: 120), ownerID: 200),
        ObstacleModel(kind: .quarterPipe, frame: CGRect(x: 40, y: 0, width: 140, height: 120), flipped: true, ownerID: 201),
        ObstacleModel(kind: .kicker, frame: CGRect(x: 600, y: 0, width: 110, height: 44), ownerID: 202),
        ObstacleModel(kind: .rail, frame: CGRect(x: 850, y: 0, width: 220, height: 40), ownerID: 203),
    ]
    let sim = Sim(windows: windows, obstacles: obstacles, spawn: CGPoint(x: 700, y: 800))
    let pilot = AutoPilot()
    var events: [SkaterEvent] = []
    var outOfBounds: CGPoint?
    var xs: [CGFloat] = []
    var surfaces = Set<String>()
    for _ in 0..<(60 * 60) {
        let input = pilot.input(state: sim.state, world: sim.world, events: events, dt: dt)
        sim.world = SurfaceBuilder.build(windows: sim.windows, screens: [screen], obstacles: sim.obstacles)
        sim.step(input: input)
        events = sim.lastEvents
        let p = sim.state.position
        if outOfBounds == nil && (p.x < screen.minX - 1 || p.x > screen.maxX + 1 || p.y < screen.minY - 1) {
            outOfBounds = p
        }
        xs.append(p.x)
        if let id = sim.state.surfaceID { surfaces.insert(String(id.split(separator: "-").first ?? "")) }
    }
    // Stuck = any 10s stretch where x moved within a band narrower than 40pt.
    var stuckAt: Double?
    let win = 600
    var i = 0
    while i + win <= xs.count {
        let slice = xs[i..<(i + win)]
        if slice.max()! - slice.min()! < 40 { stuckAt = Double(i) * dt; break }
        i += 60
    }
    let respawns = sim.events.filter { $0.event == .respawned }.count
    let ok = outOfBounds == nil && stuckAt == nil && respawns == 0
    return (ok, "outOfBounds=\(outOfBounds.map(pt) ?? "none") stuckFrom=\(stuckAt.map { String(format: "%.0fs", $0) } ?? "never") respawns=\(respawns) surfacesVisited=\(surfaces.sorted()) xRange=\(f(xs.min() ?? 0))…\(f(xs.max() ?? 0)) events=\(eventSummary(sim))")
}

// MARK: - Runner

let scenarios: [(String, () -> Result)] = [
    ("drop-onto-ledge", dropOntoLedge),
    ("roll-off-onto-lower-ledge", rollOffLedgeOntoLower),
    ("ride-moving-window", rideMovingWindow),
    ("flick-window-up", flickWindowUp),
    ("window-removed", windowRemoved),
    ("quarter-pipe", quarterPipe),
    ("kicker", kicker),
    ("grind-rail", grindRailScenario),
    ("ollie-onto-higher-ledge", ollieOntoHigherLedge),
    ("autopilot-60s", autopilot60s),
]

let filter = CommandLine.arguments.dropFirst().first
var passed = 0, failed = 0
for (name, run) in scenarios where filter.map({ name.contains($0) }) ?? true {
    if traceEnabled { print("--- \(name)") }
    let r = run()
    print("\(r.pass ? "PASS" : "FAIL") \(name) — \(r.detail)")
    if r.pass { passed += 1 } else { failed += 1 }
}
print("\nsimcheck: \(passed) passed, \(failed) failed")
if passed + failed == 0 { print("no scenario matches '\(filter ?? "")'") ; exit(1) }
exit(failed > 0 ? 1 : 0)
