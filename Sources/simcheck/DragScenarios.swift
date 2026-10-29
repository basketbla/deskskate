import CoreGraphics
import DeskSkateCore
import Foundation

// Window drags as the real app sees them, and the mouse grab/throw.
//
// The app polls window frames at 30Hz (WindowTracker) and extrapolates by the smoothed
// velocity in between (GameController). Hand drags are uneven and the window server
// sometimes reports the same frame twice, so the tracker sees stalls followed by double
// steps, an EMA velocity (factor 0.5) that lags, and a velocity that snaps to zero after two
// slow polls. `JerkyTracker` reproduces that pipeline.

/// Mirrors WindowTracker's velocity filter plus GameController's between-poll extrapolation.
struct JerkyTracker {
    static let pollInterval = 1.0 / 30
    static let smoothing: CGFloat = 0.5
    static let stopSpeed: CGFloat = 5
    static let stopPolls = 2

    var reported: CGRect
    var velocity: CGVector = .zero
    var slowPolls = 0
    var lastPoll: Double = 0
    var pollIndex = 0

    init(frame: CGRect) { reported = frame }

    /// Polls `truth` if a poll is due. Some polls see a stale frame (the window server had not
    /// caught up), including occasional back-to-back stalls.
    mutating func update(now: Double, truth: CGRect) {
        guard now - lastPoll >= Self.pollInterval - 1e-9 else { return }
        let gap = now - lastPoll
        lastPoll = now
        pollIndex += 1
        let k = pollIndex
        let stalled = k % 5 == 2 || k % 11 == 7 || k % 11 == 8
        let frame = stalled ? reported : truth
        let d = CGVector(dx: frame.midX - reported.midX, dy: frame.maxY - reported.maxY)
        let raw = d * CGFloat(1 / gap)
        slowPolls = raw.length < Self.stopSpeed ? slowPolls + 1 : 0
        velocity = slowPolls >= Self.stopPolls ? .zero : velocity + (raw - velocity) * Self.smoothing
        reported = frame
    }

    /// What the physics sees this frame: last poll extrapolated by the smoothed velocity.
    func seen(now: Double) -> CGRect {
        let ahead = CGFloat(now - lastPoll)
        return reported.offsetBy(dx: velocity.dx * ahead, dy: velocity.dy * ahead)
    }
}

/// Drags window 1 by `delta` over `duration` along an eased, wobbly hand path, then lets go
/// and settles. Returns the result of the acceptance checks.
func jerkyDrag(_ name: String, start: CGRect, delta: CGVector, duration: Double = 1.2,
               maxOffsetChange: CGFloat? = nil) -> Result {
    let w = TrackedWindow(id: 1, frame: start, zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: start.midX, y: start.maxY + 20))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "w1-", y: start.maxY) else {
        return (false, "did not settle first: \(describe(sim.state))")
    }
    let offset0 = sim.state.position.x - start.minX
    var tracker = JerkyTracker(frame: start)
    let t0 = sim.time
    var airFrames = 0
    var maxGap: CGFloat = 0
    var truth = start
    let total = duration + 0.8
    let n = Int((total / dt).rounded())
    for _ in 0..<n {
        let now = sim.time + dt - t0
        let u = min(max(now / duration, 0), 1)
        let e = CGFloat(u * u * (3 - 2 * u))
        // Hand wobble across the drag direction, gone once released.
        let wobble = u < 1 ? CGFloat(sin(now * 37) * 4 + sin(now * 13) * 3) : 0
        let perp = delta.normalized.perpendicular
        truth = start.offsetBy(dx: delta.dx * e + perp.dx * wobble, dy: delta.dy * e + perp.dy * wobble)
        tracker.update(now: now, truth: truth)
        let seen = tracker.seen(now: now)
        sim.windows = [TrackedWindow(id: 1, frame: seen, velocity: tracker.velocity, zIndex: 0)]
        sim.world = SurfaceBuilder.build(windows: sim.windows, screens: [screen], obstacles: [])
        sim.step(input: SkaterInput())
        if !sim.skater.isOnSurface || !(sim.state.surfaceID?.hasPrefix("w1-") ?? false) {
            airFrames += 1
            maxGap = max(maxGap, abs(sim.state.position.y - seen.maxY))
        }
    }
    let final = sim.window(1)!.frame
    let s = sim.state
    let offset1 = s.position.x - final.minX
    let offsetChange = abs(offset1 - offset0)
    var ok = settled(s, prefix: "w1-", y: final.maxY)
    if let m = maxOffsetChange { ok = ok && offsetChange < m }
    return (ok, "windowTop \(f(start.maxY))→\(f(final.maxY)) x \(f(start.minX))→\(f(final.minX)) offsetChange=\(f(offsetChange)) framesOffLedge=\(airFrames) maxGapOffLedge=\(f(maxGap)) final \(describe(s)) events=\(eventSummary(sim))")
}

func jerkyDragUp() -> Result {
    jerkyDrag("up", start: CGRect(x: 300, y: 0, width: 500, height: 200), delta: CGVector(dx: 150, dy: 600))
}

func jerkyDragSideways() -> Result {
    jerkyDrag("sideways", start: CGRect(x: 100, y: 200, width: 500, height: 300), delta: CGVector(dx: 600, dy: 0),
              maxOffsetChange: 30)
}

func jerkyDragDown() -> Result {
    jerkyDrag("down", start: CGRect(x: 300, y: 500, width: 500, height: 300), delta: CGVector(dx: -100, dy: -600))
}

// MARK: - Mouse grab

func grabAndDrop() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 700, y: 0, width: 500, height: 400), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 200, y: 5))
    sim.run(seconds: 1)
    guard settled(sim.state, prefix: "g0", y: 0) else {
        return (false, "did not settle on the floor first: \(describe(sim.state))")
    }
    var ev = sim.skater.grab(at: CGPoint(x: 200, y: 30))
    let grabbedOK = ev == [.grabbed] && sim.skater.isHeld && sim.state.phase == .held
    // Drag to above the ledge (x 900, y 520) over 0.5s, stepping the world as the app would.
    let from = CGPoint(x: 200, y: 30), to = CGPoint(x: 900, y: 520)
    var heldStill = true
    let steps = 30
    for i in 1...steps {
        let u = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u)
        sim.skater.drag(to: p, dt: dt)
        sim.step()
        if sim.state.position != p || sim.state.phase != .held { heldStill = false }
    }
    // Hold still a moment so the release is a drop, not a throw.
    for _ in 0..<12 { sim.skater.drag(to: to, dt: dt); sim.step() }
    ev = sim.skater.release()
    let releasedOK = ev == [.thrown] && !sim.skater.isHeld && sim.state.phase == .airborne
    sim.run(seconds: 1.5)
    let s = sim.state
    let ok = grabbedOK && heldStill && releasedOK && settled(s, prefix: "w1-", y: 400) && !sim.saw(.bail)
    return (ok, "grabbed=\(grabbedOK) heldThroughSteps=\(heldStill) released=\(releasedOK) ledgeY=400 final \(describe(s)) events=\(eventSummary(sim))")
}

func throwSkater() -> Result {
    let w = TrackedWindow(id: 1, frame: CGRect(x: 700, y: 0, width: 500, height: 300), zIndex: 0)
    let sim = Sim(windows: [w], spawn: CGPoint(x: 200, y: 5))
    sim.run(seconds: 0.5)
    sim.skater.grab(at: CGPoint(x: 300, y: 200))
    // Flick at (700, 500) pt/s for a few frames, then let go.
    var p = CGPoint(x: 300, y: 200)
    for _ in 0..<12 {
        p = p + CGVector(dx: 700, dy: 500) * CGFloat(dt)
        sim.skater.drag(to: p, dt: dt)
        sim.step()
    }
    let held = sim.state.velocity
    let ev = sim.skater.release()
    let v0 = sim.state.velocity
    let airborne = sim.state.phase == .airborne && ev == [.thrown]
    var nan = false
    let landed = sim.run(until: { $0.skater.isOnSurface }, max: 4) { sim in
        let s = sim.state
        if !(s.position.x.isFinite && s.position.y.isFinite && s.velocity.dx.isFinite && s.velocity.dy.isFinite) { nan = true }
        return Controls()
    }
    sim.run(seconds: 2)
    let s = sim.state
    let ok = airborne && landed && !nan && v0.dx > 300 && v0.dy > 200 && !sim.saw(.respawned)
    return (ok, "heldVelocity=(\(f(held.dx)), \(f(held.dy))) releaseVelocity=(\(f(v0.dx)), \(f(v0.dy))) landed=\(landed) nan=\(nan) final \(describe(s)) events=\(eventSummary(sim))")
}
