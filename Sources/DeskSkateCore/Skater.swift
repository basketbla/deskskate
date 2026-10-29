import CoreGraphics
import Foundation

/// The skater's physics. (US-002)
///
/// The world is rebuilt every step, so the skater never holds on to a `Surface`; it remembers
/// the surface id (plus owner) and re-finds it each step. While on a surface it tracks a
/// scalar tangent speed relative to the surface's owner; the world velocity reported in
/// `state.velocity` adds the owner's velocity back in.
public final class Skater {
    /// Tuning constants, readable by the autopilot and scenario checks.
    public enum Tuning {
        public static let gravity: CGFloat = 1900
        public static let pushAccel: CGFloat = 500
        public static let maxPushSpeed: CGFloat = 380
        public static let brakeAccel: CGFloat = 900
        public static let rollingFriction: CGFloat = 0.1
        public static let rollingFrictionConstant: CGFloat = 12
        /// Arcade gravity on ramps so desktop-sized quarter pipes and kickers are reachable.
        public static let rampGravityScale: CGFloat = 0.3
        /// How far past a ledge's end a landing from above still catches it (half a board).
        public static let landingEdgeSlop: CGFloat = 14
        public static let grindFriction: CGFloat = 0.08
        public static let bailFriction: CGFloat = 3
        public static let bailFrictionConstant: CGFloat = 250
        public static let popSpeed: CGFloat = 620
        public static let crouchPopBonus: CGFloat = 0.25
        public static let crouchFillTime: Double = 0.35
        public static let crouchRelaxRate: CGFloat = 4
        public static let landingCrouch: CGFloat = 0.7
        public static let airControl: CGFloat = 200
        public static let airAngleEaseRate: CGFloat = 6
        public static let angleRaycastDistance: CGFloat = 200
        public static let trickDuration: Double = 0.45
        public static let threeSixtyFlipDuration: Double = 0.6
        public static let trickMinAirTime: Double = 0.05
        public static let maxCleanLandingAngle: CGFloat = 0.6
        public static let bailDuration: Double = 1.2
        /// Largest bend between chained segments that the skater rolls through.
        public static let maxChainTurn: CGFloat = 50 * .pi / 180
        /// Segments steeper than this send the skater straight up at the lip (vert air).
        public static let vertMinSteepness: CGFloat = 75 * .pi / 180
        /// Launch off a window flicked upward: its smoothed upward speed must have stayed above
        /// `launchMinOwnerSpeed` for `launchMinUpTime`, then fallen below `launchStopFraction` of
        /// that run's peak within `launchStopWindow`.
        public static let launchMinOwnerSpeed: CGFloat = 450
        public static let launchMinUpTime: Double = 0.08
        public static let launchStopFraction: CGFloat = 0.25
        public static let launchStopWindow: Double = 0.15
        /// Landing back on the launch ledge within this long keeps the pre-launch speed.
        public static let relandWindow: Double = 0.6
        /// Left behind by a window yanked down: it must go from not moving down (every sample
        /// `dropAwayLookback`…`dropAwayYankTime` ago above −`dropAwayStillSpeed`) to faster than
        /// `dropAwayMinSpeed` downward within `dropAwayYankTime`. A steady drag down is ridden.
        public static let dropAwayMinSpeed: CGFloat = 650
        public static let dropAwayStillSpeed: CGFloat = 150
        public static let dropAwayYankTime: Double = 0.1
        public static let dropAwayLookback: Double = 0.3
        public static let wallBounce: CGFloat = 0.2
        public static let reattachDistance: CGFloat = 6
        public static let respawnMargin: CGFloat = 300
        public static let respawnDrop: CGFloat = 40
        public static let maxStep: Double = 1.0 / 60
        public static let substep: Double = 1.0 / 120
        /// Time constant (s) of the drag velocity filter while held.
        public static let dragVelocitySmoothing: Double = 0.05
        /// Horizontal drag speed above which the held skater turns to face the drag.
        public static let dragFacingSpeed: CGFloat = 60
        public static let maxThrowSpeed: CGFloat = 1600
        /// A thrown skater hitting a surface faster than this along its normal bails.
        public static let throwBailImpact: CGFloat = 1500
    }

    public private(set) var state: SkaterState

    // MARK: Internal state

    /// Tangent speed along the current surface's a→b direction, relative to its owner.
    private var speed: CGFloat = 0
    private var ownerID: UInt32?
    private var prevOwnerVelocity: CGVector = .zero
    private var holdTime: Double = 0
    /// Set while in vert air off a steep ramp lip: the ramp to re-attach to on the way down.
    private var vertOwner: UInt32?
    private var vertAngle: CGFloat = 0
    private var trickIndex = 0
    /// Set from a mouse throw until the next landing (hard impacts bail).
    private var thrown = false
    /// Last frame's surfaces by id, and how far each moved this frame. Window frames arrive
    /// in uneven jumps with lagging velocities, so motion is measured, not taken from
    /// `ownerVelocity`.
    private var lastSurfaces: [String: Surface] = [:]
    private var frameDisplacement: [String: CGVector] = [:]
    private var frameDT: CGFloat = 0
    /// True during the first substep of a step: the only one that applies the frame's displacement.
    private var firstSubstep = false
    /// Recent smoothed velocities of the owner under the board, one per frame, for launch and
    /// drop-away detection.
    private var ownerHistory: [(t: Double, v: CGVector, d: CGVector)] = []
    private var historyOwner: UInt32?
    private var clock: Double = 0
    /// Last launch off a rising window. Jerky tracking can fake a stop mid-drag; landing back
    /// on the same ledge moments later keeps the speed he had relative to it, instead of
    /// picking up whatever the window's wobble was doing at that instant.
    private var lastLaunch: (surfaceID: String, speed: CGFloat, t: Double)?
    private let spawn: CGPoint

    public init(spawn: CGPoint) {
        self.spawn = spawn
        state = SkaterState(position: spawn)
    }

    // MARK: Public helpers

    /// True while rolling, grinding, or sliding along a surface after a bail.
    public var isOnSurface: Bool { state.surfaceID != nil }
    /// Tangent speed along the current surface, relative to its owner (0 when airborne).
    public var surfaceSpeed: CGFloat { state.surfaceID == nil ? 0 : speed }
    /// True during a quarter-pipe air that will re-attach to the ramp on the way down.
    public var isInVertAir: Bool { vertOwner != nil && state.phase == .airborne }
    /// True while the mouse is holding the skater.
    public var isHeld: Bool { state.phase == .held }

    // MARK: Mouse grab

    /// Picks the skater up at `point`. Physics is suspended until `release()`.
    @discardableResult
    public func grab(at point: CGPoint) -> [SkaterEvent] {
        var events: [SkaterEvent] = []
        if case .grinding = state.phase { events.append(.grindEnd) }
        state.position = point
        state.velocity = .zero
        state.trick = nil
        state.surfaceID = nil
        state.crouch = 0
        state.phase = .held
        state.phaseTime = 0
        clearMotionState()
        events.append(.grabbed)
        return events
    }

    /// Moves the held skater to `point`. Velocity is a smoothed estimate of the drag so the
    /// renderer can swing the figure and `release()` can throw.
    public func drag(to point: CGPoint, dt: Double) {
        guard isHeld else { return }
        if dt.isFinite, dt > 0, point.x.isFinite, point.y.isFinite {
            let raw = (point - state.position) * CGFloat(1 / dt)
            let a = CGFloat(min(1, dt / Tuning.dragVelocitySmoothing))
            let v = state.velocity + (raw - state.velocity) * a
            if v.dx.isFinite && v.dy.isFinite { state.velocity = v }
            if abs(state.velocity.dx) > Tuning.dragFacingSpeed { state.facing = state.velocity.dx > 0 ? 1 : -1 }
            state.angle *= max(0, 1 - Tuning.airAngleEaseRate * CGFloat(dt))
            state.phaseTime += dt
        }
        if point.x.isFinite && point.y.isFinite { state.position = point }
    }

    /// Lets go: the skater flies off with the drag velocity (clamped).
    @discardableResult
    public func release() -> [SkaterEvent] {
        guard isHeld else { return [] }
        var v = state.velocity
        let len = v.length
        if !len.isFinite { v = .zero } else if len > Tuning.maxThrowSpeed { v = v * (Tuning.maxThrowSpeed / len) }
        state.velocity = v
        state.trick = nil
        state.surfaceID = nil
        clearMotionState()
        thrown = true
        setPhase(.airborne)
        return [.thrown]
    }

    // MARK: Step

    /// Advance one frame. Returns what happened, for effects and the autopilot.
    @discardableResult
    public func step(dt: Double, input: SkaterInput, world: WorldSnapshot) -> [SkaterEvent] {
        guard dt.isFinite, dt > 0 else { return [] }
        let previous = lastSurfaces
        lastSurfaces = Dictionary(world.surfaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Held by the mouse: no physics at all (no respawn either), only the bookkeeping above
        // so the first frame after release doesn't see every window jump.
        if isHeld { return [] }
        let total = min(dt, 0.25)
        clock += total
        frameDT = CGFloat(total)
        frameDisplacement.removeAll(keepingCapacity: true)
        for s in world.surfaces {
            guard let p = previous[s.id] else { continue }
            frameDisplacement[s.id] = Self.displacement(from: p, to: s, expected: s.ownerVelocity * CGFloat(total))
        }
        let count = total > Tuning.maxStep ? Int((total / Tuning.substep).rounded(.up)) : 1
        let h = total / Double(count)
        var events: [SkaterEvent] = []
        for i in 0..<count {
            var inp = input
            if i > 0 { inp.jumpPressed = false; inp.jumpReleased = false; inp.trickPressed = false }
            firstSubstep = i == 0
            substep(CGFloat(h), inp, world, &events)
            if !isFinite(state) {
                reset(at: respawnPoint(world) ?? spawn)
                events.append(.respawned)
            }
        }
        return events
    }

    /// How far a surface moved since last frame. Normally its `a` end; when the segment changed
    /// length (clipped by a screen edge or a window in front) one end stayed put, so take the
    /// end whose motion best matches the owner's velocity.
    private static func displacement(from p: Surface, to s: Surface, expected: CGVector) -> CGVector {
        let da = s.a - p.a
        if abs(s.length - p.length) < 0.5 { return da }
        let db = s.b - p.b
        return (da - expected).length <= (db - expected).length ? da : db
    }

    /// This substep's motion of `s`: the measured frame displacement on the first substep
    /// (or `ownerVelocity · dt` for a surface that is new this frame), nothing after.
    private func substepDisplacement(of s: Surface) -> CGVector {
        guard firstSubstep else { return .zero }
        return frameDisplacement[s.id] ?? s.ownerVelocity * frameDT
    }

    public func respawn(at point: CGPoint) {
        reset(at: point)
    }

    private func reset(at point: CGPoint) {
        let facing = state.facing
        state = SkaterState(position: point, facing: facing == 0 ? 1 : facing)
        clearMotionState()
    }

    /// Forgets everything tied to a surface or an air phase (vert air, launch tracking, throw).
    private func clearMotionState() {
        speed = 0
        ownerID = nil
        prevOwnerVelocity = .zero
        holdTime = 0
        vertOwner = nil
        thrown = false
        ownerHistory.removeAll()
        historyOwner = nil
        lastLaunch = nil
    }

    private func substep(_ h: CGFloat, _ input: SkaterInput, _ world: WorldSnapshot, _ events: inout [SkaterEvent]) {
        if needsRespawn(world), let p = respawnPoint(world) {
            reset(at: p)
            events.append(.respawned)
            return
        }
        state.phaseTime += Double(h)
        switch state.phase {
        case .held:
            return
        case .rolling:
            stepOnSurface(h, input, world, mode: .rolling, &events)
        case .grinding:
            stepOnSurface(h, input, world, mode: .grinding, &events)
        case .airborne:
            stepAir(h, input, world, bailed: false, &events)
        case .bailed(let remaining):
            let left = remaining - Double(h)
            if state.surfaceID != nil {
                stepOnSurface(h, input, world, mode: .bailed, &events)
            } else {
                stepAir(h, input, world, bailed: true, &events)
            }
            // A respawn or other reset during the step may have changed the phase.
            guard case .bailed = state.phase else { return }
            if left <= 0 {
                if state.surfaceID != nil {
                    speed = 0
                    state.velocity = prevOwnerVelocity
                    setPhase(.rolling)
                } else {
                    setPhase(.airborne)
                }
            } else {
                state.phase = .bailed(remaining: left)
            }
        }
    }

    // MARK: On a surface

    private enum Mode { case rolling, grinding, bailed }

    private func stepOnSurface(_ h: CGFloat, _ input: SkaterInput, _ world: WorldSnapshot, mode: Mode,
                               _ events: inout [SkaterEvent]) {
        // Ride along with the surface. While its id still exists we follow it however far it
        // jumped this frame (one id is one window's top edge); only a vanished id falls back to
        // a nearby-surface search.
        let s: Surface
        let probe: CGPoint
        if let id = state.surfaceID, let cur = world.surface(id: id), cur.kind != .wall, cur.length > 1e-3 {
            let carried = state.position + substepDisplacement(of: cur)
            s = sameOwnerSpan(containing: carried, from: cur, world: world)
            probe = carried
        } else {
            probe = state.position + (firstSubstep ? prevOwnerVelocity * frameDT : .zero)
            guard let found = nearestSurface(world, near: probe), found.normal.dy >= -0.05 else {
                // The window under us closed or was dragged away: fall.
                leaveSurface(at: probe, velocity: state.velocity, mode: mode, &events)
                return
            }
            s = found
        }
        // Re-found a different surface (old one vanished): carry the world velocity over.
        if s.id != state.surfaceID {
            speed = (state.velocity - s.ownerVelocity).dot(s.direction)
            if s.ownerID != ownerID { prevOwnerVelocity = s.ownerVelocity }
        }
        let ov = s.ownerVelocity
        let dir = s.direction
        let n = s.normal

        if firstSubstep {
            recordOwner(s)
            // Flicked upward then stopped: launch with the speed the window had.
            if let launch = launchVelocity() {
                let before = speed
                leaveSurface(at: probe, velocity: dir * speed + launch, mode: mode, &events)
                lastLaunch = (s.id, before, clock)
                return
            }
            // Yanked downward faster than gravity can follow: we stay where we were.
            if yankedDown() {
                let before = ownerHistory.count >= 2 ? ownerHistory[ownerHistory.count - 2].v : .zero
                leaveSurface(at: state.position, velocity: dir * speed + before, mode: mode, &events)
                return
            }
        }

        // Snap onto the (re-built) surface line.
        let rel = probe - s.a
        var t = min(max(rel.dot(dir), 0), s.length)
        let start = s.a + dir * t

        var currentMode = mode
        if mode == .grinding && !input.grind {
            currentMode = .rolling
            setPhase(.rolling)
            events.append(.grindEnd)
        }

        // Ollie.
        if currentMode != .bailed && input.jumpReleased {
            let charge = CGFloat(min(holdTime / Tuning.crouchFillTime, 1))
            holdTime = 0
            let pop = Tuning.popSpeed * (1 + Tuning.crouchPopBonus * charge)
            let v = dir * speed + ov + n * pop
            if currentMode == .grinding { events.append(.grindEnd) }
            events.append(.ollie)
            state.crouch = 0
            leaveSurface(at: start + n * 0.5, velocity: v, mode: .rolling, &events)
            return
        }

        // Crouch.
        if currentMode != .bailed && input.jump {
            holdTime += Double(h)
            state.crouch = max(state.crouch, CGFloat(min(holdTime / Tuning.crouchFillTime, 1)))
        } else {
            holdTime = 0
            state.crouch = max(0, state.crouch - Tuning.crouchRelaxRate * h)
        }

        // Forces along the tangent.
        let tSign: CGFloat = dir.dx < -1e-6 ? -1 : 1
        speed += -Tuning.gravity * (s.kind == .ramp ? Tuning.rampGravityScale : 1) * dir.dy * h
        let inDir = CGFloat((input.right ? 1 : 0) - (input.left ? 1 : 0)) * tSign
        if currentMode == .rolling && inDir != 0 {
            if speed * inDir >= 0 || abs(speed) < 5 {
                if abs(speed) < Tuning.maxPushSpeed || speed * inDir < 0 {
                    let next = speed + inDir * Tuning.pushAccel * h
                    speed = abs(next) > Tuning.maxPushSpeed && speed * inDir >= 0
                        ? max(abs(speed), Tuning.maxPushSpeed) * inDir : next
                }
            } else {
                let b = Tuning.brakeAccel * h
                speed = abs(speed) <= b ? 0 : speed + inDir * b
            }
        }
        let k: CGFloat, c: CGFloat
        switch currentMode {
        case .rolling: k = Tuning.rollingFriction; c = Tuning.rollingFrictionConstant
        case .grinding: k = Tuning.grindFriction; c = 0
        case .bailed: k = Tuning.bailFriction; c = Tuning.bailFrictionConstant
        }
        let dec = abs(speed) * k * h + c * h
        speed = abs(speed) <= dec ? 0 : speed - (speed > 0 ? dec : -dec)

        // Move along the chain.
        var cur = s
        var remaining = speed * h
        var iterations = 0
        while iterations < 8 {
            iterations += 1
            let len = cur.length
            let target = t + remaining
            if target >= 0 && target <= len { t = target; remaining = 0; break }
            let forward = target > len
            let endPoint = forward ? cur.b : cur.a
            let moveDir = cur.direction * (forward ? 1 : -1)
            if let (next, nt) = continuation(of: cur, at: endPoint, moving: moveDir, world: world,
                                             allowForeign: currentMode != .grinding) {
                let along = moveDir.dot(next.direction) >= 0 ? CGFloat(1) : -1
                let overshoot = forward ? target - len : -target
                speed = abs(speed) * along
                cur = next
                t = nt
                remaining = overshoot * along
                continue
            }
            // End of the line: airborne.
            let relV = cur.direction * speed
            if currentMode != .bailed, cur.ownerID != nil, moveDir.dy > sin(Tuning.vertMinSteepness), relV.dy > 0 {
                // Quarter-pipe lip: straight up, come back down onto the same ramp.
                let v = CGVector(dx: cur.ownerVelocity.dx, dy: relV.dy + cur.ownerVelocity.dy)
                let a = angle(of: cur)
                leaveSurface(at: endPoint, velocity: v, mode: currentMode, &events)
                state.facing = -state.facing
                state.angle = a
                vertOwner = cur.ownerID
                vertAngle = a
                return
            }
            state.angle = angle(of: cur)
            leaveSurface(at: endPoint, velocity: relV + cur.ownerVelocity, mode: currentMode, &events)
            return
        }
        t = min(max(t, 0), cur.length)
        var newPos = cur.a + cur.direction * t

        // Rolled onto an obstacle that starts on this surface (a kicker on the floor).
        if cur.id == s.id, currentMode == .rolling,
           let hit = sweep(from: start, to: newPos, velocity: dir * speed + ov, world: world, h: 0, excluding: s.id)
            ?? rampEntry(from: start, to: newPos, on: s, world: world),
           hit.surface.ownerID != s.ownerID || hit.surface.ownerID == nil {
            let moveDir = dir * (speed >= 0 ? 1 : -1)
            if abs(moveDir.dot(hit.surface.direction)) > cos(Tuning.maxChainTurn) {
                cur = hit.surface
                speed = abs(speed) * (moveDir.dot(cur.direction) >= 0 ? 1 : -1)
                t = min(max((hit.point - cur.a).dot(cur.direction), 0), cur.length)
                newPos = cur.a + cur.direction * t
            }
        }

        // Walls.
        let wall = collideWalls(from: start, to: newPos, velocity: cur.direction * speed + cur.ownerVelocity,
                                world: world, h: 0)
        if wall.hit {
            cur = s
            newPos = start
            speed = -speed * Tuning.wallBounce
            state.facing = -state.facing
        }

        let cdir = cur.direction
        state.position = newPos
        state.surfaceID = cur.id
        ownerID = cur.ownerID
        prevOwnerVelocity = cur.ownerVelocity
        state.angle = angle(of: cur)
        state.velocity = cdir * speed + cur.ownerVelocity
        let sign: CGFloat = cdir.dx < -1e-6 ? -1 : 1
        if abs(speed) > 1 {
            state.facing = speed > 0 ? sign : -sign
        } else if inDir != 0 && currentMode == .rolling {
            state.facing = inDir * sign
        }
    }

    /// Next surface to roll onto at the end of `cur`: the chained segment of the same owner,
    /// else (when `allowForeign`) any floor-like surface passing through the end point.
    private func continuation(of cur: Surface, at end: CGPoint, moving: CGVector, world: WorldSnapshot,
                              allowForeign: Bool) -> (Surface, CGFloat)? {
        let minDot = cos(Tuning.maxChainTurn)
        var foreign: (Surface, CGFloat, CGFloat)?
        for s in world.surfaces where s.id != cur.id && s.kind != .wall && s.length > 1e-3 {
            if s.ownerID == cur.ownerID {
                if (s.a - end).length < 0.5, moving.dot(s.direction) > minDot { return (s, 0) }
                if (s.b - end).length < 0.5, moving.dot(s.direction) < -minDot { return (s, s.length) }
            }
            guard allowForeign, s.normal.dy > 0.05, abs(moving.dot(s.direction)) > minDot else { continue }
            let rel = end - s.a
            let t = rel.dot(s.direction)
            let d = abs(rel.dot(s.normal))
            guard d < 1, t >= -0.5, t <= s.length + 0.5 else { continue }
            let tc = min(max(t, 0), s.length)
            // Must be able to move onward along it.
            let onward = moving.dot(s.direction) >= 0 ? s.length - tc : tc
            guard onward > 0.5 else { continue }
            if foreign == nil || d < foreign!.2 { foreign = (s, tc, d) }
        }
        if let f = foreign { return (f.0, f.1) }
        return nil
    }

    /// A window's top edge can split into spans (another window moved in front) and span ids
    /// are indices, so if the carried point is off the end of `cur` but on another span of the
    /// same owner, use that one.
    private func sameOwnerSpan(containing p: CGPoint, from cur: Surface, world: WorldSnapshot) -> Surface {
        guard cur.kind == .ledge, let owner = cur.ownerID else { return cur }
        let t = (p - cur.a).dot(cur.direction)
        guard t < -1 || t > cur.length + 1 else { return cur }
        for s in world.surfaces where s.id != cur.id && s.ownerID == owner && s.kind == .ledge {
            let u = (p - s.a).dot(s.direction)
            if u >= 0, u <= s.length, abs((p - s.a).dot(s.normal)) < 1 { return s }
        }
        return cur
    }

    /// Appends this frame's owner velocity to the history (reset when the owner changes).
    private func recordOwner(_ s: Surface) {
        if s.ownerID != historyOwner || s.ownerID == nil {
            ownerHistory.removeAll(keepingCapacity: true)
            historyOwner = s.ownerID
        }
        ownerHistory.append((clock, s.ownerVelocity, frameDisplacement[s.id] ?? s.ownerVelocity * frameDT))
        let cutoff = clock - Tuning.dropAwayLookback - 0.05
        if let k = ownerHistory.firstIndex(where: { $0.t >= cutoff }), k > 0 { ownerHistory.removeFirst(k) }
    }

    /// The owner rose fast for long enough and has now nearly stopped: the velocity to fly off
    /// with, else nil. That is how fast the window actually moved over the run (measured
    /// displacement), capped by the smoothed peak: the smoothed velocity overshoots when the
    /// tracker catches up after stalled polls.
    private func launchVelocity() -> CGVector? {
        guard historyOwner != nil, let now = ownerHistory.last, ownerHistory.count >= 2 else { return nil }
        let fast = Tuning.launchMinOwnerSpeed
        guard now.v.dy < fast else { return nil }
        // Most recent fast sample, then walk back to the start of that run.
        var j = ownerHistory.count - 2
        while j >= 0 && ownerHistory[j].v.dy <= fast { j -= 1 }
        guard j >= 0, now.t - ownerHistory[j].t <= Tuning.launchStopWindow else { return nil }
        var k = j
        var peak = ownerHistory[j].v
        while k > 0 && ownerHistory[k - 1].v.dy > fast {
            k -= 1
            if ownerHistory[k].v.dy > peak.dy { peak = ownerHistory[k].v }
        }
        // Each sample stands for one frame, so the run lasts from its first frame's start.
        let frame = j + 1 < ownerHistory.count ? ownerHistory[j + 1].t - ownerHistory[j].t : Double(frameDT)
        let duration = ownerHistory[j].t - ownerHistory[k].t + frame
        guard duration >= Tuning.launchMinUpTime - 1e-6 else { return nil }
        guard now.v.dy < peak.dy * Tuning.launchStopFraction else { return nil }
        var moved = CGVector.zero
        for i in k...j { moved = moved + ownerHistory[i].d }
        let measured = moved * CGFloat(1 / duration)
        let dy = min(peak.dy, max(measured.dy, 0))
        let dx = abs(measured.dx) < abs(peak.dx) ? measured.dx : peak.dx
        return CGVector(dx: dx, dy: dy)
    }

    /// The owner went from not moving down to dropping fast within a moment.
    private func yankedDown() -> Bool {
        guard historyOwner != nil, let now = ownerHistory.last, now.v.dy < -Tuning.dropAwayMinSpeed else { return false }
        let earlier = ownerHistory.filter { now.t - $0.t >= Tuning.dropAwayYankTime - 1e-6 }
        guard !earlier.isEmpty else { return false }
        return earlier.allSatisfy { $0.v.dy > -Tuning.dropAwayStillSpeed }
    }

    private func nearestSurface(_ world: WorldSnapshot, near p: CGPoint) -> Surface? {
        var best: Surface?
        var bestScore = CGFloat.infinity
        for s in world.surfaces where s.kind != .wall && s.length > 1e-3 && s.normal.dy > -0.05 {
            let d = distance(p, to: s)
            guard d <= Tuning.reattachDistance else { continue }
            let score = d - (ownerID != nil && s.ownerID == ownerID ? 100 : 0)
            if score < bestScore { bestScore = score; best = s }
        }
        return best
    }

    private func leaveSurface(at p: CGPoint, velocity v: CGVector, mode: Mode, _ events: inout [SkaterEvent]) {
        if mode == .grinding, case .grinding = state.phase { events.append(.grindEnd) }
        state.position = p
        state.velocity = v
        state.surfaceID = nil
        ownerID = nil
        prevOwnerVelocity = .zero
        holdTime = 0
        speed = 0
        vertOwner = nil
        ownerHistory.removeAll(keepingCapacity: true)
        historyOwner = nil
        if mode != .bailed { setPhase(.airborne) }
    }

    // MARK: Air

    private func stepAir(_ h: CGFloat, _ input: SkaterInput, _ world: WorldSnapshot, bailed: Bool,
                         _ events: inout [SkaterEvent]) {
        var v = state.velocity
        v.dy -= Tuning.gravity * h
        if !bailed {
            let inDir = CGFloat((input.right ? 1 : 0) - (input.left ? 1 : 0))
            v.dx += inDir * Tuning.airControl * h
        }
        state.crouch = max(0, state.crouch - Tuning.crouchRelaxRate * h)
        holdTime = 0

        // Tricks.
        if !bailed {
            let active = state.trick.map { $0.progress < 1 } ?? false
            if input.trickPressed, !active, state.phaseTime > Tuning.trickMinAirTime {
                let kinds = TrickKind.allCases
                let kind = kinds[trickIndex % kinds.count]
                trickIndex += 1
                state.trick = TrickState(kind: kind, progress: 0)
                events.append(.trickStarted(kind))
            } else if var trick = state.trick, trick.progress < 1 {
                let duration = trick.kind == .threeSixtyFlip ? Tuning.threeSixtyFlipDuration : Tuning.trickDuration
                trick.progress = min(1, trick.progress + Double(h) / duration)
                state.trick = trick
            }
        }

        let p0 = state.position
        let p1 = p0 + v * h

        // Vert air: drop back onto the ramp we launched from.
        if let owner = vertOwner, !bailed {
            if let (s, point) = vertReattach(owner: owner, from: p0, to: p1, velocity: v, world: world) {
                land(on: s, at: point, velocity: v, input: input, bailed: false, &events)
                return
            }
            if !world.surfaces.contains(where: { $0.ownerID == owner }) { vertOwner = nil }
        }

        if let hit = sweep(from: p0, to: p1, velocity: v, world: world, h: h, excluding: nil) {
            land(on: hit.surface, at: hit.point, velocity: v, input: input, bailed: bailed, &events)
            return
        }

        let wall = collideWalls(from: p0, to: p1, velocity: v, world: world, h: h)
        // A wall push can move the feet back over a floor the first sweep missed (diving into a
        // screen corner), so check the corrected path once more.
        if wall.hit, let hit = sweep(from: p0, to: wall.position, velocity: wall.velocity, world: world,
                                     h: h, excluding: nil) {
            land(on: hit.surface, at: hit.point, velocity: wall.velocity, input: input, bailed: bailed, &events)
            return
        }
        state.position = wall.position
        state.velocity = wall.velocity

        // Board angle eases toward the surface below (or flat).
        let target: CGFloat
        if vertOwner != nil {
            target = vertAngle
        } else {
            target = surfaceBelow(state.position, world: world).map { angle(of: $0) } ?? 0
        }
        let diff = wrap(target - state.angle)
        state.angle = wrap(state.angle + diff * min(1, Tuning.airAngleEaseRate * h))
    }

    private func vertReattach(owner: UInt32, from p0: CGPoint, to p1: CGPoint, velocity v: CGVector,
                              world: WorldSnapshot) -> (Surface, CGPoint)? {
        var best: (Surface, CGPoint, CGFloat)?
        for s in world.surfaces where s.ownerID == owner && s.kind != .wall && s.length > 1e-3 && s.normal.dy > -0.05 {
            guard v.dy - s.ownerVelocity.dy < 0 else { continue }
            let lo = min(s.a.y, s.b.y), hi = max(s.a.y, s.b.y)
            guard hi - lo > 1e-3, p1.y >= lo, p1.y <= hi else { continue }
            let u = (p1.y - s.a.y) / (s.b.y - s.a.y)
            let x = s.a.x + (s.b.x - s.a.x) * u
            let dx = abs(x - p1.x)
            guard dx < 30 else { continue }
            if best == nil || dx < best!.2 { best = (s, CGPoint(x: x, y: p1.y), dx) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private struct Hit { var surface: Surface; var point: CGPoint }

    /// A ramp resting on this surface rarely sits exactly on its line (a ramp riding a window
    /// lags it slightly), so the swept test can pass just under the ramp's first segment. Catch
    /// the ramp's entry endpoint when it lies within a few points of the floor we're crossing.
    private func rampEntry(from p0: CGPoint, to p1: CGPoint, on floor: Surface, world: WorldSnapshot) -> Hit? {
        let movingRight = p1.x >= p0.x
        let lo = min(p0.x, p1.x) - 0.5, hi = max(p0.x, p1.x) + 0.5
        let fd = floor.direction
        guard abs(fd.dx) > 1e-6 else { return nil }
        var best: Hit?
        var bestDist = CGFloat.infinity
        for s in world.surfaces where s.kind != .wall && s.id != floor.id && s.length > 1e-3 {
            guard s.ownerID != floor.ownerID || s.ownerID == nil, s.normal.dy > 0.05 else { continue }
            let entry = movingRight ? (s.a.x <= s.b.x ? s.a : s.b) : (s.a.x >= s.b.x ? s.a : s.b)
            guard entry.x >= lo, entry.x <= hi else { continue }
            let floorY = floor.a.y + fd.dy / fd.dx * (entry.x - floor.a.x)
            guard abs(entry.y - floorY) < 4 else { continue }
            let dist = abs(entry.x - p0.x)
            if dist < bestDist { bestDist = dist; best = Hit(surface: s, point: entry) }
        }
        return best
    }

    /// Swept feet test against floor-like surfaces, entered from the normal side.
    private func sweep(from p0: CGPoint, to p1: CGPoint, velocity v: CGVector, world: WorldSnapshot,
                       h: CGFloat, excluding: String?) -> Hit? {
        var best: Hit?
        var bestU = CGFloat.infinity
        for s in world.surfaces where s.kind != .wall && s.length > 1e-3 && s.id != excluding {
            let n = s.normal
            // Where the feet started relative to where the surface is now: a ledge that rose
            // into a falling or standing skater this frame catches him. Approaching from the
            // normal side (d0 > d1) is the one-way test, measured, not from a stale velocity.
            let q0 = p0 + (h > 0 ? substepDisplacement(of: s) : .zero)
            let d0 = (q0 - s.a).dot(n)
            let d1 = (p1 - s.a).dot(n)
            guard d0 >= -1, d1 < 0, d0 > d1 else { continue }
            let u = max(0, d0) / (max(0, d0) - d1)
            guard u.isFinite else { continue }
            let hp = q0 + (p1 - q0) * u
            let t = (hp - s.a).dot(s.direction)
            // End slop only when actually coming from above; otherwise rolling off an end
            // re-lands on the segment just left and the skater freezes there.
            // Coming down from above, half a board hanging past the end still lands (snapped onto
            // the end). Otherwise no slop: rolling off an end must not re-land on it.
            let slop: CGFloat = d0 > 0.5 ? Tuning.landingEdgeSlop : -1e-3
            guard t >= -slop, t <= s.length + slop else { continue }
            if u < bestU {
                bestU = u
                let tc = min(max(t, 0), s.length)
                best = Hit(surface: s, point: s.a + s.direction * tc)
            }
        }
        return best
    }

    private func land(on s: Surface, at point: CGPoint, velocity v: CGVector, input: SkaterInput, bailed: Bool,
                      _ events: inout [SkaterEvent]) {
        let rel = v - s.ownerVelocity
        speed = rel.dot(s.direction)
        if let l = lastLaunch, l.surfaceID == s.id, clock - l.t <= Tuning.relandWindow { speed = l.speed }
        lastLaunch = nil
        let sAngle = angle(of: s)
        let wasThrown = thrown
        thrown = false
        let trickOK = state.trick.map { $0.progress >= 1 } ?? true
        // A thrown skater was flailing, not aiming the board: any angle is fine unless he
        // hits too hard.
        let angleOK = wasThrown ? -rel.dot(s.normal) <= Tuning.throwBailImpact
            : abs(wrap(state.angle - sAngle)) < Tuning.maxCleanLandingAngle
        state.position = point
        state.surfaceID = s.id
        ownerID = s.ownerID
        prevOwnerVelocity = s.ownerVelocity
        vertOwner = nil
        holdTime = 0
        state.velocity = s.direction * speed + s.ownerVelocity
        state.angle = sAngle
        state.trick = nil
        let sign: CGFloat = s.direction.dx < -1e-6 ? -1 : 1
        if abs(speed) > 1 { state.facing = speed > 0 ? sign : -sign }
        if bailed { return }
        state.crouch = max(state.crouch, Tuning.landingCrouch)
        if trickOK && angleOK {
            events.append(.landed(clean: true))
            if s.grindable && input.grind {
                setPhase(.grinding)
                events.append(.grindStart)
            } else {
                setPhase(.rolling)
            }
        } else {
            events.append(.landed(clean: false))
            events.append(.bail)
            setPhase(.bailed(remaining: Tuning.bailDuration))
        }
    }

    // MARK: Walls

    private struct WallResult { var position: CGPoint; var velocity: CGVector; var hit: Bool }

    private func collideWalls(from p0: CGPoint, to p1: CGPoint, velocity v: CGVector, world: WorldSnapshot,
                              h: CGFloat) -> WallResult {
        var p = p1
        var vel = v
        var hit = false
        // Screen walls (no owner) go last so an obstacle wall on the same line can't undo them.
        let walls = world.surfaces.filter { $0.kind == .wall && $0.length > 1e-3 }
            .sorted { ($0.ownerID == nil ? 1 : 0) < ($1.ownerID == nil ? 1 : 0) }
        for s in walls {
            let n = s.normal
            let q0 = p0 + s.ownerVelocity * h
            let d0 = (q0 - s.a).dot(n)
            let d1 = (p - s.a).dot(n)
            let side: CGFloat
            if d0 >= 0 && d1 < 0 { side = 1 }
            else if !s.oneWay && d0 < 0 && d1 > 0 { side = -1 }
            else { continue }
            let u = d0 / (d0 - d1)
            guard u.isFinite else { continue }
            let hp = q0 + (p - q0) * u
            let t = (hp - s.a).dot(s.direction)
            guard t >= -1, t <= s.length + 1 else { continue }
            p = p + n * (side * 0.5 - d1)
            let vn = (vel - s.ownerVelocity).dot(n)
            if vn * side < 0 { vel = vel - n * (vn * (1 + Tuning.wallBounce)) }
            hit = true
        }
        return WallResult(position: p, velocity: vel, hit: hit)
    }

    // MARK: Respawn

    private func needsRespawn(_ world: WorldSnapshot) -> Bool {
        guard let minY = world.screens.map(\.minY).min() else { return false }
        let p = state.position
        if p.y < minY - Tuning.respawnMargin { return true }
        let m = Tuning.respawnMargin
        return !world.screens.contains { p.x >= $0.minX - m && p.x <= $0.maxX + m }
    }

    private func respawnPoint(_ world: WorldSnapshot) -> CGPoint? {
        let x = state.position.x.isFinite ? state.position.x : 0
        let screen = world.screens.min { a, b in
            horizontalDistance(x, a) < horizontalDistance(x, b)
        }
        return screen.map { CGPoint(x: $0.midX, y: $0.maxY - Tuning.respawnDrop) }
    }

    private func horizontalDistance(_ x: CGFloat, _ r: CGRect) -> CGFloat {
        x < r.minX ? r.minX - x : (x > r.maxX ? x - r.maxX : 0)
    }

    // MARK: Geometry helpers

    private func setPhase(_ phase: SkaterPhase) {
        let changed: Bool
        switch (state.phase, phase) {
        case (.bailed, .bailed): changed = false
        default: changed = state.phase != phase
        }
        state.phase = phase
        if changed { state.phaseTime = 0 }
    }

    private func surfaceBelow(_ p: CGPoint, world: WorldSnapshot) -> Surface? {
        var best: Surface?
        var bestGap = CGFloat.infinity
        for s in world.surfaces where s.kind != .wall && s.length > 1e-3 && s.normal.dy > 0.05 {
            let lo = min(s.a.x, s.b.x), hi = max(s.a.x, s.b.x)
            guard hi - lo > 1e-3, p.x >= lo, p.x <= hi else { continue }
            let y = s.a.y + (s.b.y - s.a.y) * (p.x - s.a.x) / (s.b.x - s.a.x)
            let gap = p.y - y
            guard gap >= -1, gap <= Tuning.angleRaycastDistance, gap < bestGap else { continue }
            bestGap = gap
            best = s
        }
        return best
    }

    private func distance(_ p: CGPoint, to s: Surface) -> CGFloat {
        let t = min(max((p - s.a).dot(s.direction), 0), s.length)
        return (p - (s.a + s.direction * t)).length
    }

    private func angle(of s: Surface) -> CGFloat {
        let d = s.direction
        return atan2(d.dy, d.dx)
    }

    private func wrap(_ a: CGFloat) -> CGFloat { atan2(sin(a), cos(a)) }

    private func isFinite(_ s: SkaterState) -> Bool {
        s.position.x.isFinite && s.position.y.isFinite && s.velocity.dx.isFinite && s.velocity.dy.isFinite
            && s.angle.isFinite && speed.isFinite
    }
}
