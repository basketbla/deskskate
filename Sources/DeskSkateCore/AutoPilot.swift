import CoreGraphics
import Foundation

/// Drives the skater when nobody is on the keyboard. (US-007)
///
/// A little desktop pet: cruises at a mood-dependent speed, turns at walls and window ends,
/// ollies up onto ledges it can reach, throws tricks when the air allows, grinds sometimes,
/// idles now and then, and gets itself unstuck. The world is rebuilt every frame, so every
/// plan is re-evaluated against the current snapshot; only surface ids are remembered.
public final class AutoPilot {
    private typealias T = Skater.Tuning

    // MARK: Randomness

    private var rngState: UInt64

    private func nextRandom() -> UInt64 {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    private func rand() -> Double { Double(nextRandom() >> 11) / Double(1 << 53) }
    private func rand(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * rand() }
    private func chance(_ p: Double) -> Bool { rand() < p }

    // MARK: State

    private var time: Double = 0
    /// World-x direction we want to travel: +1 right, -1 left.
    private var desiredDir: CGFloat = 1
    private var lastTurnTime: Double = -10
    private var cruiseSpeed: CGFloat = 250
    private var nextMoodAt: Double = 0
    private var nextRandomTurnAt: Double = 0
    private var nextIdleAt: Double = 0
    private var idleUntil: Double = -1
    /// Now and then, a full-crouch ollie on flat ground just for fun (room for a flip trick).
    private var nextFlatOllieAt: Double = 0

    // Jump / crouch.
    private var jumpHeld = false
    private var crouchTime: Double = 0
    private enum CrouchReason { case target(String), endOllie, wallHop, unstick, pinned, flatOllie }
    private var crouchReason: CrouchReason?

    // Per-target / per-end decisions, keyed by surface id, expiring.
    private var targetDecisions: [String: (go: Bool, at: Double)] = [:]
    private enum EndAction { case rollOff, ollieOff, turnBack }
    private var endDecisions: [String: (action: EndAction, at: Double)] = [:]

    // Air.
    private var airTrickDecided = false
    private var airGrindDecided = false
    private var holdGrindInAir = false
    private var airTargetID: String?
    /// The skater cycles through trick kinds in order; the last one seen tells us the next.
    private var lastTrick: TrickKind?

    private var nextTrickDuration: Double {
        // Unknown (no trick seen yet): a fresh skater starts with a kickflip; pad it a little
        // in case the player already flipped a few by hand.
        guard let last = lastTrick, let i = TrickKind.allCases.firstIndex(of: last) else {
            return T.trickDuration + 0.08
        }
        let next = TrickKind.allCases[(i + 1) % TrickKind.allCases.count]
        return next == .threeSixtyFlip ? T.threeSixtyFlipDuration : T.trickDuration
    }

    // Grinding.
    private var grindReleaseAt: Double = .infinity

    /// Recent landings. Several in a fraction of a second means the physics has us pinned at a
    /// segment end (roll off, re-land on the end point, repeat): pop out of it.
    private var landedTimes: [Double] = []
    private var isPinned: Bool { landedTimes.filter { time - $0 < 0.3 }.count >= 3 }

    /// The snapshot for the current call only (never kept across frames).
    private var lastWorld: WorldSnapshot?

    // Stuck detection.
    private var samples: [(t: Double, p: CGPoint)] = []
    private var lastSampleAt: Double = -1

    public init(seed: UInt64) {
        rngState = seed
        cruiseSpeed = CGFloat(rand(180, 320))
        nextMoodAt = rand(8, 20)
        nextRandomTurnAt = rand(6, 15)
        nextIdleAt = rand(20, 40)
        nextFlatOllieAt = rand(3, 9)
        desiredDir = chance(0.5) ? 1 : -1
    }

    public convenience init() {
        self.init(seed: UInt64.random(in: 0 ... UInt64.max))
    }

    // MARK: Main entry

    public func input(state: SkaterState, world: WorldSnapshot, events: [SkaterEvent], dt: Double) -> SkaterInput {
        let dt = dt.isFinite ? max(0, min(dt, 0.25)) : 0
        time += dt
        lastWorld = world
        defer { lastWorld = nil }
        handle(events: events)
        expireDecisions()

        if time >= nextMoodAt {
            cruiseSpeed = CGFloat(rand(180, 320))
            nextMoodAt = time + rand(8, 20)
        }

        var out = SkaterInput()
        var wantJump = false

        switch state.phase {
        case .bailed, .held:
            // Lie there until the skater gets back up (or the mouse lets go).
            resetGroundPlans()
            samples.removeAll()
        case .airborne:
            if case .pinned = crouchReason {
                // Keep holding: the release has to happen on a frame that starts on the surface.
                wantJump = true
            } else {
                crouchReason = nil
            }
            air(state, world, &out)
        case .grinding:
            grinding(state, world, &out, &wantJump, dt)
        case .rolling:
            rolling(state, world, &out, &wantJump, dt)
        }

        // Jump edges are derived from what we held last frame.
        out.jump = wantJump
        out.jumpPressed = wantJump && !jumpHeld
        out.jumpReleased = !wantJump && jumpHeld
        jumpHeld = wantJump
        if wantJump, state.surfaceID != nil { crouchTime += dt } else if !wantJump { crouchTime = 0 }
        return out
    }

    private func handle(events: [SkaterEvent]) {
        for e in events {
            switch e {
            case .ollie:
                crouchReason = nil
            case .landed, .respawned, .bail, .grabbed, .thrown:
                if case .landed = e { landedTimes.append(time) }
                airTrickDecided = false
                airGrindDecided = false
                airTargetID = nil
                if case .respawned = e { samples.removeAll() }
            case .grindStart:
                grindReleaseAt = chance(0.3) ? .infinity : time + rand(0.5, 2)
                holdGrindInAir = false
            case .grindEnd:
                holdGrindInAir = false
                grindReleaseAt = .infinity
            case .trickStarted(let kind):
                lastTrick = kind
            }
        }
    }

    private func expireDecisions() {
        targetDecisions = targetDecisions.filter { time - $0.value.at < 5 }
        endDecisions = endDecisions.filter { time - $0.value.at < 4 }
        landedTimes.removeAll { time - $0 > 0.5 }
    }

    private func resetGroundPlans() {
        crouchReason = nil
        holdGrindInAir = false
    }

    private func turnAround() {
        desiredDir = -desiredDir
        lastTurnTime = time
        crouchReason = nil
        nextRandomTurnAt = time + rand(6, 15)
    }

    // MARK: Rolling

    private func rolling(_ state: SkaterState, _ world: WorldSnapshot, _ out: inout SkaterInput,
                         _ wantJump: inout Bool, _ dt: Double) {
        let pos = state.position
        guard let sid = state.surfaceID, let surface = world.surface(id: sid) else {
            pushToward(desiredDir, state: state, ownerVX: 0, out: &out)
            return
        }
        let ownerVX = surface.ownerVelocity.dx
        let relV = state.velocity - surface.ownerVelocity
        let vx = relV.dx

        // Momentum the other way (rolled back down a ramp, came out of vert air): go with it.
        if abs(vx) > 150, vx * desiredDir < 0, time - lastTurnTime > 1.0, crouchReason == nil {
            desiredDir = vx > 0 ? 1 : -1
            lastTurnTime = time
        }

        if isPinned, crouchReason == nil || !jumpHeld {
            if let w = wallAhead(pos, dir: desiredDir, world: world), w.dist < 20 { turnAround() }
            crouchReason = .pinned
            landedTimes.removeAll()
        }

        // Idle: brake to a stop and stand there for a bit.
        if time < idleUntil, crouchReason == nil {
            crouchReason = nil
            if abs(vx) > 15 {
                if vx > 0 { out.left = true } else { out.right = true }
            }
            samples.removeAll()
            return
        }
        if idleUntil > 0 {
            idleUntil = -1
            if chance(0.5) { turnAround() }
        }
        if time >= nextIdleAt, crouchReason == nil, abs(surface.direction.dy) < 0.2 {
            idleUntil = time + rand(1.5, 4)
            nextIdleAt = idleUntil + rand(20, 40)
            return
        }

        // Stuck detection.
        if checkStuck(pos) {
            turnAround()
            crouchReason = .unstick
        }

        // Random turnaround.
        if time >= nextRandomTurnAt, crouchReason == nil, time - lastTurnTime > 1 {
            turnAround()
        }

        var target = cruiseSpeed
        if rampAhead(state, world, surface) { target = 360 }

        // Walls ahead.
        let speedAhead = max(0, vx * desiredDir)
        if crouchReason == nil, let wall = wallAhead(pos, dir: desiredDir, world: world) {
            let lookahead = 70 + speedAhead * 0.15
            if wall.hoppable && speedAhead > 120 {
                // Back of a low ramp: hop it instead of bouncing off.
                if wall.dist < speedAhead * 0.45 + 40 { crouchReason = .wallHop }
            } else if wall.dist < lookahead {
                turnAround()
            }
        }

        // Ledges above within reach.
        if crouchReason == nil {
            if let tgt = pickTarget(state, world, surface, vx: vx) {
                crouchReason = .target(tgt)
            }
        }

        // End of the chain ahead (window end).
        if crouchReason == nil, let end = chainEnd(from: surface, at: pos, dir: desiredDir, world: world),
           abs(end.last.direction.dy) < 0.5 {
            let key = end.last.id + (desiredDir > 0 ? ">" : "<")
            let decideDist = speedAhead * 0.6 + 80
            if end.dist < decideDist {
                let action: EndAction
                if let d = endDecisions[key] {
                    action = d.action
                } else {
                    let drop = dropBelow(end.point, dir: desiredDir, world: world)
                    let r = rand()
                    let wallBeyond = wallAhead(end.point, dir: desiredDir, world: world, below: 140)
                    if let w = wallBeyond, w.dist < 160 { action = .turnBack } // don't drop into a screen corner
                    else if steepFaceBeyond(end) { action = r < 0.7 ? .ollieOff : .turnBack }
                    else if drop > 400 && chance(0.5) { action = .turnBack }
                    else if drop == .infinity { action = .turnBack }
                    else { action = r < 0.4 ? .ollieOff : (r < 0.75 ? .rollOff : .turnBack) }
                    endDecisions[key] = (action, time)
                }
                switch action {
                case .turnBack:
                    let brake = speedAhead * speedAhead / (2 * T.brakeAccel)
                    // Don't undo a wall turn made a moment ago (a deck end next to a wall).
                    if end.dist < brake + 30, time - lastTurnTime > 0.6 { turnAround() }
                case .ollieOff:
                    if steepFaceBeyond(end) && speedAhead < 160 {
                        // Too slow to clear a box side: turn back instead.
                        if end.dist < 40, time - lastTurnTime > 0.6 { turnAround() } else { target = max(target, 260) }
                    } else if end.dist < speedAhead * 0.3 + 20 {
                        crouchReason = .endOllie
                    }
                case .rollOff:
                    if speedAhead < 120 { target = max(target, 200) }
                }
            }
        }

        // Just-for-fun ollie on a clear flat stretch.
        if crouchReason == nil, time >= nextFlatOllieAt {
            nextFlatOllieAt = time + rand(3, 9)
            let clearAhead = speedAhead * 1.0 + 120
            let wallClear = (wallAhead(pos, dir: desiredDir, world: world)?.dist ?? .infinity) > clearAhead + 60
            let endClear = (chainEnd(from: surface, at: pos, dir: desiredDir, world: world)?.dist ?? .infinity) > clearAhead
            if abs(surface.direction.dy) < 0.2, speedAhead > 100, wallClear, endClear {
                crouchReason = .flatOllie
            }
        }

        pushToward(desiredDir, state: state, ownerVX: ownerVX, out: &out, target: target)

        // Execute the crouch plan.
        guard let reason = crouchReason else { return }
        wantJump = true
        let charge = CGFloat(min(crouchTime / T.crouchFillTime, 1))
        var release = false
        switch reason {
        case .target(let id):
            if let tgt = world.surface(id: id) {
                let n = surface.normal
                let v = surface.direction * relV.dot(surface.direction) + n * (T.popSpeed * (1 + T.crouchPopBonus * charge))
                if let land = predictLanding(from: pos + n * 0.5, velocity: v, world: world, maxTime: 2),
                   land.surface.id == id || (land.surface.ownerID != nil && land.surface.ownerID == tgt.ownerID
                                             && land.surface.ownerID != surface.ownerID
                                             && land.surface.normal.dy > 0.6) {
                    let margin = min(20, land.surface.length * 0.2)
                    let tt = (land.point - land.surface.a).dot(land.surface.direction)
                    if tt > margin && tt < land.surface.length - margin && !nearSteepFace(land.point, world: world) {
                        release = true
                    }
                }
                if crouchTime > 1.2 { release = true; targetDecisions[id] = (false, time) }
                if release { airTargetID = id }
            } else {
                release = true
            }
        case .endOllie:
            if let end = chainEnd(from: surface, at: pos, dir: desiredDir, world: world) {
                if end.dist < 22 || crouchTime > 0.8 { release = true }
            } else {
                release = true
            }
        case .wallHop:
            if let wall = wallAhead(pos, dir: desiredDir, world: world), speedAhead > 1 {
                let t = Double(wall.dist / speedAhead)
                let vy = Double(T.popSpeed * (1 + T.crouchPopBonus * charge))
                let y = vy * t - 0.5 * Double(T.gravity) * t * t
                if y > Double(wall.top - pos.y) + 10 || wall.dist < 12 || crouchTime > 0.8 { release = true }
            } else {
                release = true
            }
        case .unstick:
            if crouchTime > T.crouchFillTime { release = true }
        case .pinned:
            if jumpHeld { release = true }
        case .flatOllie:
            if crouchTime >= T.crouchFillTime { release = true }
        }
        if release {
            wantJump = false
            crouchReason = nil
        }
    }

    private func pushToward(_ dir: CGFloat, state: SkaterState, ownerVX: CGFloat, out: inout SkaterInput,
                            target: CGFloat? = nil) {
        let vx = state.velocity.dx - ownerVX
        let goal = target ?? cruiseSpeed
        if vx * dir < goal || vx * dir < 0 {
            if dir > 0 { out.right = true } else { out.left = true }
        }
    }

    // MARK: Grinding

    private func grinding(_ state: SkaterState, _ world: WorldSnapshot, _ out: inout SkaterInput,
                          _ wantJump: inout Bool, _ dt: Double) {
        if checkStuck(state.position) { turnAround(); crouchReason = .unstick }
        if isPinned { crouchReason = .pinned; landedTimes.removeAll() }
        if time < grindReleaseAt { out.grind = true }
        if let reason = crouchReason {
            switch reason {
            case .pinned, .unstick:
                if jumpHeld { crouchReason = nil } else { wantJump = true }
                return
            default:
                crouchReason = nil
            }
        }
        // Occasionally pop off the end of a grind.
        if let sid = state.surfaceID, let s = world.surface(id: sid) {
            let vx = state.velocity.dx - s.ownerVelocity.dx
            let dir: CGFloat = vx >= 0 ? 1 : -1
            if let end = chainEnd(from: s, at: state.position, dir: dir, world: world, sameOwnerOnly: true) {
                if steepFaceBeyond(end), abs(vx) < 160, end.dist < 80 {
                    // Too slow to pop clear of the box side: drop out of the grind and let the
                    // rolling logic turn back.
                    out.grind = false
                    return
                }
                let key = s.id + "grind"
                if endDecisions[key] == nil {
                    endDecisions[key] = (steepFaceBeyond(end) || chance(0.4) ? .ollieOff : .rollOff, time)
                }
                if endDecisions[key]?.action == .ollieOff, end.dist < abs(vx) * 0.3 + 25 {
                    wantJump = end.dist > 15 && crouchTime < 0.5
                }
            }
        }
    }

    // MARK: Air

    private func air(_ state: SkaterState, _ world: WorldSnapshot, _ out: inout SkaterInput) {
        let landing = predictLanding(from: state.position, velocity: state.velocity, world: world, maxTime: 3)

        // Tricks.
        let trickActive = state.trick.map { $0.progress < 1 } ?? false
        if !trickActive, !airTrickDecided, let land = landing, state.phaseTime > T.trickMinAirTime + 0.01 {
            if land.time > nextTrickDuration + 0.12 {
                airTrickDecided = true
                if chance(0.7) { out.trickPressed = true }
            }
        } else if !trickActive, airTrickDecided, state.trick != nil, let land = landing,
                  land.time > nextTrickDuration + 0.2 {
            // Trick finished with lots of air left: maybe chain another.
            if chance(0.03) { out.trickPressed = true }
        }

        // Grinds.
        if let land = landing, land.surface.grindable {
            if !airGrindDecided {
                airGrindDecided = true
                holdGrindInAir = chance(land.surface.kind == .rail ? 0.5 : 0.25)
            }
        }
        // Never grind into a trick landing: a trick that can't finish bails anyway.
        out.grind = holdGrindInAir

        // Steering.
        if let id = airTargetID, let tgt = world.surface(id: id) {
            let lo = min(tgt.a.x, tgt.b.x), hi = max(tgt.a.x, tgt.b.x)
            let landsOnIt = landing.map { $0.surface.id == id || $0.surface.ownerID == tgt.ownerID && tgt.ownerID != nil } ?? false
            if !landsOnIt, tgt.a.y < state.position.y + 200 {
                let mid = (lo + hi) / 2
                let landX = landing?.point.x ?? state.position.x
                if landX < lo + 15 || landX > hi - 15 {
                    if mid > landX { out.right = true } else { out.left = true }
                }
            }
        } else if let w = nearbyWall(state.position, world: world, within: 140),
                  state.velocity.dx * w.side > -60 {
            // Don't land in a screen corner: drift away from a wall we're heading into.
            if w.side > 0 { out.left = true } else { out.right = true }
            if state.velocity.dx * w.side > 0 { desiredDir = -w.side }
        } else if landing == nil {
            if let x = nearestFloorBelowX(state.position, world: world) {
                if x > state.position.x + 4 { out.right = true } else if x < state.position.x - 4 { out.left = true }
            }
        }
    }

    // MARK: Prediction

    private struct Landing { var surface: Surface; var point: CGPoint; var time: Double }

    /// Ballistic flight (no air control) until the first floor-like surface it would land on.
    private func predictLanding(from p0: CGPoint, velocity v0: CGVector, world: WorldSnapshot,
                                maxTime: Double) -> Landing? {
        let h: CGFloat = 1.0 / 60
        var p = p0
        var v = v0
        var t: Double = 0
        let floors = world.surfaces.filter { $0.kind != .wall && $0.length > 1e-3 && $0.normal.dy > -0.05 }
        let minY = (world.screens.map(\.minY).min() ?? -10_000) - T.respawnMargin
        while t < maxTime {
            v.dy -= T.gravity * h
            let p1 = p + v * h
            var best: (Surface, CGPoint, CGFloat)?
            for s in floors {
                let n = s.normal
                if s.oneWay && v.dot(n) >= 0 { continue }
                let d0 = (p - s.a).dot(n)
                let d1 = (p1 - s.a).dot(n)
                if d0 >= -1, d1 < 0, d0 > d1 {
                    let u = max(0, d0) / (max(0, d0) - d1)
                    let hp = p + (p1 - p) * u
                    let tt = (hp - s.a).dot(s.direction)
                    if tt >= -0.5, tt <= s.length + 0.5, best == nil || u < best!.2 {
                        best = (s, s.a + s.direction * min(max(tt, 0), s.length), u)
                    }
                }
                // Steep ramps catch a falling skater sideways (vert re-attach): count them early.
                if abs(n.dy) < 0.5, v.dy < 0, best == nil {
                    let lo = min(s.a.y, s.b.y), hi = max(s.a.y, s.b.y)
                    if p1.y >= lo, p1.y <= hi, hi - lo > 1e-3 {
                        let u = (p1.y - s.a.y) / (s.b.y - s.a.y)
                        let x = s.a.x + (s.b.x - s.a.x) * u
                        if abs(x - p1.x) < 30 { best = (s, CGPoint(x: x, y: p1.y), 1) }
                    }
                }
            }
            t += Double(h)
            if let b = best { return Landing(surface: b.0, point: b.1, time: t) }
            p = p1
            if p.y < minY { return nil }
        }
        return nil
    }

    // MARK: World queries

    private struct WallInfo { var dist: CGFloat; var top: CGFloat; var hoppable: Bool }

    /// The nearest wall in the travel direction that would block us at our height.
    private func wallAhead(_ pos: CGPoint, dir: CGFloat, world: WorldSnapshot, below: CGFloat = 0) -> WallInfo? {
        var best: WallInfo?
        for s in world.surfaces where s.kind == .wall {
            let n = s.normal
            // Only walls we hit from their normal side (one-way) or any side (two-way).
            if s.oneWay && n.dx * dir >= 0 { continue }
            let lo = min(s.a.y, s.b.y), hi = max(s.a.y, s.b.y)
            guard pos.y + 8 >= lo, pos.y - below <= hi + 1 else { continue }
            let x = (s.a.x + s.b.x) / 2
            let d = (x - pos.x) * dir
            guard d > -1, d < 600 else { continue }
            if best == nil || d < best!.dist {
                let height = hi - pos.y
                best = WallInfo(dist: max(0, d), top: hi, hoppable: s.ownerID != nil && height < 95)
            }
        }
        return best
    }

    /// Closest wall to either side at our height; `side` is +1 when it's to the right.
    private func nearbyWall(_ pos: CGPoint, world: WorldSnapshot, within: CGFloat) -> (dist: CGFloat, side: CGFloat)? {
        var best: (dist: CGFloat, side: CGFloat)?
        for s in world.surfaces where s.kind == .wall && s.ownerID == nil {
            let lo = min(s.a.y, s.b.y), hi = max(s.a.y, s.b.y)
            guard pos.y + 8 >= lo, pos.y <= hi + 1 else { continue }
            let x = (s.a.x + s.b.x) / 2
            let d = abs(x - pos.x)
            if d < within, best == nil || d < best!.dist { best = (d, x > pos.x ? 1 : -1) }
        }
        return best
    }

    private struct ChainEnd { var point: CGPoint; var last: Surface; var dist: CGFloat }

    /// Follows the current surface's chain in the travel direction to where it ends.
    private func chainEnd(from s: Surface, at pos: CGPoint, dir: CGFloat, world: WorldSnapshot,
                          sameOwnerOnly: Bool = false) -> ChainEnd? {
        let minDot = cos(T.maxChainTurn)
        var cur = s
        var from = pos
        var dist: CGFloat = 0
        for _ in 0 ..< 16 {
            let forward = cur.direction.dx * dir >= 0
            let end = forward ? cur.b : cur.a
            dist += (end - from).length
            if dist > 900 { return nil }
            let moving = cur.direction * (forward ? 1 : -1)
            var next: Surface?
            for o in world.surfaces where o.id != cur.id && o.kind != .wall && o.length > 1e-3 {
                if o.ownerID == cur.ownerID {
                    if (o.a - end).length < 0.5, moving.dot(o.direction) > minDot { next = o; break }
                    if (o.b - end).length < 0.5, moving.dot(o.direction) < -minDot { next = o; break }
                }
                if sameOwnerOnly { continue }
                guard o.normal.dy > 0.05, abs(moving.dot(o.direction)) > minDot else { continue }
                let rel = end - o.a
                let t = rel.dot(o.direction)
                guard abs(rel.dot(o.normal)) < 1, t >= -0.5, t <= o.length + 0.5 else { continue }
                let onward = moving.dot(o.direction) >= 0 ? o.length - t : t
                if onward > 0.5 { next = o }
            }
            guard let n = next else { return ChainEnd(point: end, last: cur, dist: dist) }
            from = end
            cur = n
        }
        return nil
    }

    /// A steep face of the same obstacle continues past this end (a box side): rolling down
    /// it slams into the floor at a bail angle, so it has to be ollied.
    private func steepFaceBeyond(_ end: ChainEnd) -> Bool {
        guard end.last.ownerID != nil else { return false }
        // `world` isn't needed: the obstacle's sides share the end point and owner.
        return lastWorld?.surfaces.contains { o in
            o.ownerID == end.last.ownerID && o.id != end.last.id && o.kind != .wall && o.normal.dy < 0.6
                && ((o.a - end.point).length < 0.5 || (o.b - end.point).length < 0.5)
        } ?? false
    }

    /// A landing point right next to a steep obstacle face is likely to clip the face instead.
    private func nearSteepFace(_ p: CGPoint, world: WorldSnapshot) -> Bool {
        world.surfaces.contains { s in
            guard s.kind != .wall, s.normal.dy < 0.6, s.normal.dy > -0.05 else { return false }
            let lo = min(s.a.x, s.b.x) - 35, hi = max(s.a.x, s.b.x) + 35
            let bottom = min(s.a.y, s.b.y), top = max(s.a.y, s.b.y)
            return p.x >= lo && p.x <= hi && top >= p.y - 5 && bottom <= p.y + 80
        }
    }

    /// Height of the drop off a ledge end (infinity when there's nothing below).
    private func dropBelow(_ p: CGPoint, dir: CGFloat, world: WorldSnapshot) -> CGFloat {
        let x = p.x + dir * 30
        var best = CGFloat.infinity
        for s in world.surfaces where s.kind != .wall && s.normal.dy > 0.05 {
            let lo = min(s.a.x, s.b.x), hi = max(s.a.x, s.b.x)
            guard x >= lo, x <= hi, hi - lo > 1e-3 else { continue }
            let y = s.a.y + (s.b.y - s.a.y) * (x - s.a.x) / (s.b.x - s.a.x)
            let gap = p.y - y
            if gap > 1, gap < best { best = gap }
        }
        return best
    }

    /// X to steer toward when falling with nothing predicted below.
    private func nearestFloorBelowX(_ p: CGPoint, world: WorldSnapshot) -> CGFloat? {
        var best: (CGFloat, CGFloat)?
        for s in world.surfaces where s.kind != .wall && s.normal.dy > 0.5 {
            guard max(s.a.y, s.b.y) < p.y - 2 else { continue }
            let lo = min(s.a.x, s.b.x) + 10, hi = max(s.a.x, s.b.x) - 10
            guard hi > lo else { continue }
            let x = min(max(p.x, lo), hi)
            let d = abs(x - p.x) + (p.y - max(s.a.y, s.b.y)) * 0.2
            if best == nil || d < best!.1 { best = (x, d) }
        }
        return best?.0
    }

    /// A ramp or kicker on our level a little way ahead: carry speed into it.
    private func rampAhead(_ state: SkaterState, _ world: WorldSnapshot, _ surface: Surface) -> Bool {
        let p = state.position
        for s in world.surfaces where s.kind == .ramp && s.ownerID != surface.ownerID {
            let nearX = desiredDir > 0 ? min(s.a.x, s.b.x) : max(s.a.x, s.b.x)
            let nearY = desiredDir > 0 ? (s.a.x < s.b.x ? s.a.y : s.b.y) : (s.a.x < s.b.x ? s.b.y : s.a.y)
            let d = (nearX - p.x) * desiredDir
            if d > 0, d < 260, abs(nearY - p.y) < 6 { return true }
        }
        return false
    }

    /// Picks a ledge/rail/box top above and ahead that an ollie can reach, and decides
    /// (once per target, ~60%) whether to go for it. Returns the id when it's time to crouch.
    private func pickTarget(_ state: SkaterState, _ world: WorldSnapshot, _ surface: Surface, vx: CGFloat) -> String? {
        let pos = state.position
        let dir = desiredDir
        guard abs(surface.direction.dy) < 0.35 else { return nil }
        let speed = max(0, vx * dir)
        let fullPop = T.popSpeed * (1 + T.crouchPopBonus)
        var best: (Surface, CGFloat)?
        for s in world.surfaces where s.kind != .wall && s.kind != .ground && s.normal.dy > 0.5 && s.oneWay {
            if s.id == surface.id { continue }
            if s.ownerID != nil && s.ownerID == surface.ownerID { continue }
            let lo = min(s.a.x, s.b.x), hi = max(s.a.x, s.b.x)
            guard hi - lo > 30 else { continue }
            let y = max(s.a.y, s.b.y)
            let h = y - pos.y
            guard h >= 20, h <= 140 else { continue }
            // Horizontal reach: time to fall back to the target height after a full pop.
            let disc = fullPop * fullPop - 2 * T.gravity * (h + 6)
            guard disc > 0 else { continue }
            let tLand = (fullPop + disc.squareRoot()) / T.gravity
            let reach = speed * tLand
            // Distance along travel to the near and far ends of the target.
            let near = (dir > 0 ? lo : hi) - pos.x
            let far = (dir > 0 ? hi : lo) - pos.x
            let nearD = near * dir, farD = far * dir
            guard farD > 40 else { continue }
            // Already under it: needs an almost vertical pop, only when slow enough.
            if nearD < 0 && speed * tLand > farD - 20 { continue }
            // Start crouching roughly when a full-crouch release will land just past the near end.
            let startAt = reach + speed * CGFloat(T.crouchFillTime) + 40
            guard nearD < startAt else { continue }
            if best == nil || nearD < best!.1 { best = (s, nearD) }
        }
        guard let (tgt, _) = best else { return nil }
        if let d = targetDecisions[tgt.id] { return d.go ? tgt.id : nil }
        let go = chance(0.6)
        targetDecisions[tgt.id] = (go, time)
        return go ? tgt.id : nil
    }

    // MARK: Stuck

    private func checkStuck(_ p: CGPoint) -> Bool {
        if time - lastSampleAt >= 0.25 {
            samples.append((time, p))
            lastSampleAt = time
        }
        samples.removeAll { time - $0.t > 3.05 }
        guard let first = samples.first, time - first.t >= 2.9 else { return false }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for s in samples {
            minX = min(minX, s.p.x); maxX = max(maxX, s.p.x); minY = min(minY, s.p.y); maxY = max(maxY, s.p.y)
        }
        if max(maxX - minX, maxY - minY) < 15 {
            samples.removeAll()
            return true
        }
        return false
    }
}
