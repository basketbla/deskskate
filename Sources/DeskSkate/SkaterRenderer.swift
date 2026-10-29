import AppKit
import DeskSkateCore

/// Draws the procedural skater. (US-004)
///
/// Everything is plain Core Graphics. The skater is posed in a local frame whose origin is
/// `state.position` (midpoint of the wheels, on the surface), +y is the surface normal and +x
/// points the way the skater faces. That frame is rotated by `state.angle` and mirrored by
/// `state.facing` to land in global AppKit space. Effect particles live in global space.
final class SkaterRenderer {

    /// While held, the board's wheel midpoint hangs this far below the grab point
    /// (`state.position`) when the skater is not swinging. Offset the grab point by this on
    /// release so physics picks up the board where it was drawn.
    static let heldBoardOffset: CGFloat = 38

    // MARK: Palette

    private enum Palette {
        static let body = CGColor(srgbRed: 0x1d / 255, green: 0x1f / 255, blue: 0x24 / 255, alpha: 1)
        static let halo = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88)
        static let shirt = CGColor(srgbRed: 0.93, green: 0.33, blue: 0.22, alpha: 1)
        static let beanie = CGColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 1)
        static let skin = CGColor(srgbRed: 0.98, green: 0.86, blue: 0.74, alpha: 1)
        static let deck = CGColor(srgbRed: 0.80, green: 0.53, blue: 0.27, alpha: 1)
        static let grip = CGColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
        static let underside = CGColor(srgbRed: 0.20, green: 0.55, blue: 0.85, alpha: 1)
        static let truck = CGColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 1)
        static let wheel = CGColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 1)
        static let star = CGColor(srgbRed: 1.0, green: 0.84, blue: 0.22, alpha: 1)
    }

    // MARK: Dimensions (points)

    private let wheelRadius: CGFloat = 2.6
    private let wheelX: CGFloat = 11
    private let deckY: CGFloat = 6.5          // deck centre line height
    private let deckThickness: CGFloat = 3
    private var deckTop: CGFloat { deckY + deckThickness / 2 }
    private let footX: CGFloat = 8
    private let thigh: CGFloat = 11.5
    private let shin: CGFloat = 11.5
    private let upperArm: CGFloat = 7.5
    private let forearm: CGFloat = 7.5
    private let torsoLength: CGFloat = 12
    private let headRadius: CGFloat = 5.5
    private let limbWidth: CGFloat = 3.2
    private let haloWidth: CGFloat = 1.6

    // MARK: Effects state

    private enum ParticleKind { case spark, dust, pop }

    private struct Particle {
        var kind: ParticleKind
        var position: CGPoint
        var velocity: CGVector
        var life: Double
        var maxLife: Double
        var size: CGFloat
    }

    private var particles: [Particle] = []
    private let maxParticles = 200
    private var lastState: SkaterState?
    private var clock: Double = 0
    private var sparkAccumulator: Double = 0
    private var bailStarTime: Double = 0
    private var bailStarDuration: Double = 1.2
    private var lastHeadWorld: CGPoint?

    // Held: pendulum swing driven by the drag velocity, and the "surprise" marks on grab.
    private var swingAngle: CGFloat = 0
    private var swingVelocity: CGFloat = 0
    private var smoothedDragDX: CGFloat = 0
    private var surpriseTime: Double = 0
    private let surpriseDuration: Double = 0.5

    // Push cycle (rolling slowly while speeding up).
    private var prevSpeed: CGFloat?
    private var smoothedAccel: CGFloat = 0
    private var pushBlend: CGFloat = 0
    private var pushClock: Double = 0

    // MARK: API

    /// Feed events from each physics step so effects (sparks, dust, bail stars) can spawn.
    func handle(events: [SkaterEvent], state: SkaterState) {
        lastState = state
        for event in events {
            switch event {
            case .ollie:
                spawnPop(state)
            case .landed:
                spawnDust(state)
            case .bail:
                if case .bailed(let r) = state.phase { bailStarDuration = max(0.4, r) } else { bailStarDuration = 1.2 }
                bailStarTime = bailStarDuration
                spawnDust(state)
            case .grabbed:
                bailStarTime = 0
                surpriseTime = surpriseDuration
                swingAngle = 0
                swingVelocity = 0
                smoothedDragDX = 0
            case .thrown:
                bailStarTime = 0
                surpriseTime = 0
            case .respawned:
                particles.removeAll()
                bailStarTime = 0
                pushBlend = 0
            case .grindStart:
                spawnSparks(state, count: 6)
            case .grindEnd, .trickStarted:
                break
            }
        }
    }

    /// Advance effect particles.
    func update(dt: Double) {
        guard dt > 0 else { return }
        let dt = min(dt, 0.1)
        clock += dt
        bailStarTime = max(0, bailStarTime - dt)
        surpriseTime = max(0, surpriseTime - dt)

        if let s = lastState {
            // Pendulum: hang opposite the horizontal drag, with a little overshoot.
            if s.phase == .held {
                let fdt = CGFloat(dt)
                smoothedDragDX += (s.velocity.dx - smoothedDragDX) * min(1, fdt * 10)
                let target = max(-0.6, min(0.6, -smoothedDragDX * 0.0013))
                let stiffness: CGFloat = 70, damping: CGFloat = 7
                swingVelocity += ((target - swingAngle) * stiffness - swingVelocity * damping) * fdt
                swingAngle = max(-0.9, min(0.9, swingAngle + swingVelocity * fdt))
            } else {
                swingAngle = 0; swingVelocity = 0; smoothedDragDX = 0
            }

            // Grind sparks, rate scaled by speed.
            if s.phase == .grinding {
                let speed = Double(s.velocity.length)
                sparkAccumulator += dt * (25 + min(speed, 600) * 0.12)
                let n = Int(sparkAccumulator)
                if n > 0 { sparkAccumulator -= Double(n); spawnSparks(s, count: n) }
            } else {
                sparkAccumulator = 0
            }

            // Push detection: slow, rolling and accelerating.
            let speed = s.velocity.length
            if let p = prevSpeed {
                let accel = (speed - p) / CGFloat(dt)
                smoothedAccel += (accel - smoothedAccel) * min(1, CGFloat(dt) * 8)
            }
            prevSpeed = speed
            let wantPush = s.phase == .rolling && s.crouch < 0.2 && speed < 170 && smoothedAccel > 15
            let target: CGFloat = wantPush ? 1 : 0
            let step = CGFloat(dt) * 4
            pushBlend += max(-step, min(step, target - pushBlend))
            if pushBlend > 0 { pushClock += dt } else { pushClock = 0 }
        }

        let gravity: CGFloat = -520
        var i = 0
        while i < particles.count {
            particles[i].life -= dt
            if particles[i].life <= 0 {
                particles.swapAt(i, particles.count - 1)
                particles.removeLast()
                continue
            }
            var p = particles[i]
            switch p.kind {
            case .spark:
                p.velocity.dy += gravity * CGFloat(dt)
            case .dust, .pop:
                p.velocity = p.velocity * CGFloat(max(0, 1 - dt * 4))
                p.size += CGFloat(dt) * (p.kind == .dust ? 14 : 18)
            }
            p.position = p.position + p.velocity * CGFloat(dt)
            particles[i] = p
            i += 1
        }
    }

    /// Draw in global AppKit coordinates — the caller has already translated `ctx` so that
    /// global points land in the right place on this screen.
    func draw(_ state: SkaterState, in ctx: CGContext) {
        lastState = state
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        drawBackParticles(in: ctx)

        let base = CGAffineTransform(translationX: state.position.x, y: state.position.y)
            .rotated(by: state.angle)
            .scaledBy(x: state.facing < 0 ? -1 : 1, y: 1)

        if case .bailed(let remaining) = state.phase {
            drawBail(state, remaining: remaining, base: base, in: ctx)
        } else if state.phase == .held {
            drawHeld(state, in: ctx)
        } else {
            drawRiding(state, base: base, in: ctx)
        }

        drawFrontParticles(in: ctx)
        drawBailStars(in: ctx)
        drawSurprise(in: ctx)
        ctx.restoreGState()
    }

    // MARK: - Riding

    private struct BoardPose {
        var lift: CGFloat = 0
        var tilt: CGFloat = 0
        /// Rotation about the long axis (kickflip/heelflip), radians.
        var flip: CGFloat = 0
        /// Rotation about the vertical axis (shuvit), radians.
        var shuv: CGFloat = 0
        /// Small in-plane wobble while flipping.
        var wobble: CGFloat = 0
    }

    private struct Pose {
        var hip: CGPoint
        var lean: CGFloat                 // torso tilt, + = forward
        var frontFoot: CGPoint
        var backFoot: CGPoint
        var frontHand: CGPoint            // relative to shoulder
        var backHand: CGPoint             // relative to shoulder
        var headTilt: CGFloat = 0
    }

    private func drawRiding(_ state: SkaterState, base: CGAffineTransform, in ctx: CGContext) {
        let t = state.phaseTime
        let speed = state.velocity.length
        var board = BoardPose()
        var feetLift: CGFloat = 0
        let crouch = max(0, min(1, state.crouch))

        if let trick = state.trick {
            let p = CGFloat(max(0, min(1, trick.progress)))
            let arc = sin(p * .pi)
            board.lift = arc * 7
            feetLift = arc * 13
            let turn = p * 2 * .pi
            switch trick.kind {
            case .kickflip:
                board.flip = turn
                board.wobble = sin(turn) * 0.12
            case .heelflip:
                board.flip = -turn
                board.wobble = -sin(turn) * 0.12
            case .shuvit:
                board.shuv = p * .pi
            case .threeSixtyFlip:
                board.flip = turn
                board.shuv = turn
                board.wobble = sin(turn) * 0.08
            }
        }

        var pose: Pose
        switch state.phase {
        case .grinding:
            board.tilt = 0.12
            let wob = CGFloat(sin(t * 9)) * 0.05
            let c = max(crouch, 0.45)
            pose = Pose(hip: CGPoint(x: 0.5, y: 26 - 12 * c),
                        lean: 0.12 + wob,
                        frontFoot: .zero, backFoot: .zero,
                        frontHand: CGPoint(x: 13, y: 2 + wob * 20),
                        backHand: CGPoint(x: -13, y: 1 - wob * 20))
        case .airborne:
            let c = max(crouch, 0.55)
            let flail = CGFloat(sin(t * 7)) * 1.5
            pose = Pose(hip: CGPoint(x: 0.5, y: 26 - 12 * c + feetLift * 0.6),
                        lean: 0.22,
                        frontFoot: .zero, backFoot: .zero,
                        frontHand: CGPoint(x: 11, y: 4 + flail),
                        backHand: CGPoint(x: -11, y: 3 - flail))
        default:
            let relax = CGFloat(sin(t * 2.2))
            let speedLean = min(speed / 900, 0.12)
            let hipY = 25.5 - 12 * crouch - 0.6 * relax * (1 - crouch)
            let relaxedFront = CGPoint(x: 2 + relax * 1.5, y: -13)
            let relaxedBack = CGPoint(x: -2 - relax * 1.5, y: -13)
            let forwardFront = CGPoint(x: 11, y: -5)
            let forwardBack = CGPoint(x: 8, y: -8)
            pose = Pose(hip: CGPoint(x: 1.5 * crouch, y: hipY),
                        lean: 0.06 + speedLean + 0.38 * crouch,
                        frontFoot: .zero, backFoot: .zero,
                        frontHand: lerp(relaxedFront, forwardFront, crouch),
                        backHand: lerp(relaxedBack, forwardBack, crouch))
        }

        // Feet on the deck, following the board's lift and tilt (not the flip).
        let boardT = boardTransform(board)
        let spread: CGFloat = state.trick != nil ? footX + 1 : footX
        pose.frontFoot = CGPoint(x: spread, y: deckTop).applying(boardT)
        pose.backFoot = CGPoint(x: -spread, y: deckTop).applying(boardT)
        pose.frontFoot.y += feetLift
        pose.backFoot.y += feetLift

        // Push cycle: back foot steps off, sweeps the ground, comes back.
        if case .rolling = state.phase, pushBlend > 0.01 {
            let cyc = CGFloat((pushClock / 0.85).truncatingRemainder(dividingBy: 1))
            let ground: CGPoint
            if cyc < 0.25 {
                let k = smooth(cyc / 0.25)
                ground = lerp(pose.backFoot, CGPoint(x: -1, y: 0.8), k)
            } else if cyc < 0.65 {
                let k = smooth((cyc - 0.25) / 0.4)
                ground = lerp(CGPoint(x: -1, y: 0.8), CGPoint(x: -13, y: 0.8), k)
            } else {
                let k = smooth((cyc - 0.65) / 0.35)
                var p = lerp(CGPoint(x: -13, y: 0.8), pose.backFoot, k)
                p.y += sin(k * .pi) * 4
                ground = p
            }
            let b = pushBlend
            pose.backFoot = lerp(pose.backFoot, ground, b)
            pose.frontFoot = lerp(pose.frontFoot, CGPoint(x: 5, y: deckTop), b)
            pose.hip = lerp(pose.hip, CGPoint(x: 3, y: 19), b)
            pose.lean += 0.18 * b
            let swing = CGFloat(sin(Double(cyc) * 2 * .pi))
            pose.frontHand = lerp(pose.frontHand, CGPoint(x: 6 * swing, y: -12), b)
            pose.backHand = lerp(pose.backHand, CGPoint(x: -6 * swing, y: -12), b)
        }

        ctx.saveGState()
        ctx.concatenate(base)
        drawBoard(board, in: ctx)
        let head = drawFigure(pose, in: ctx)
        ctx.restoreGState()
        lastHeadWorld = head.applying(base)
    }

    private func boardTransform(_ b: BoardPose) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: b.lift).rotated(by: b.tilt + b.wobble)
    }

    // MARK: - Board

    private func drawBoard(_ b: BoardPose, in ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(boardTransform(b))
        // Flip about the deck's long axis and shuv about the vertical axis.
        let flipScale = cos(b.flip)
        let shuvScale = cos(b.shuv)
        ctx.translateBy(x: 0, y: deckY)
        ctx.scaleBy(x: abs(shuvScale) < 0.08 ? (shuvScale < 0 ? -0.08 : 0.08) : shuvScale,
                    y: abs(flipScale) < 0.06 ? (flipScale < 0 ? -0.06 : 0.06) : flipScale)
        ctx.translateBy(x: 0, y: -deckY)

        // Deck centreline with kicktails.
        let deck = CGMutablePath()
        deck.move(to: CGPoint(x: -16, y: deckY + 3.2))
        deck.addQuadCurve(to: CGPoint(x: -11.5, y: deckY), control: CGPoint(x: -13.6, y: deckY))
        deck.addLine(to: CGPoint(x: 11.5, y: deckY))
        deck.addQuadCurve(to: CGPoint(x: 16, y: deckY + 3.2), control: CGPoint(x: 13.6, y: deckY))

        // Trucks + wheels.
        for sx in [-wheelX, wheelX] {
            stroke(ctx, [CGPoint(x: sx, y: wheelRadius), CGPoint(x: sx, y: deckY - 1)],
                   width: 2.6 + haloWidth * 1.5, color: Palette.halo)
        }
        for sx in [-wheelX, wheelX] {
            stroke(ctx, [CGPoint(x: sx - 1.6, y: deckY - 1.4), CGPoint(x: sx, y: wheelRadius),
                         CGPoint(x: sx + 1.6, y: deckY - 1.4)], width: 1.6, color: Palette.truck)
            let r = CGRect(x: sx - wheelRadius, y: 0, width: wheelRadius * 2, height: wheelRadius * 2)
            ctx.setFillColor(Palette.wheel)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(Palette.body)
            ctx.setLineWidth(0.9)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.45, dy: 0.45))
            ctx.setFillColor(Palette.truck)
            ctx.fillEllipse(in: CGRect(x: sx - 0.7, y: wheelRadius - 0.7, width: 1.4, height: 1.4))
        }

        // Halo, then the deck. Mid-flip the deck shows its face: grip or graphic.
        let face = abs(sin(b.flip))
        let deckWidth = deckThickness + 5 * face
        ctx.addPath(deck)
        ctx.setStrokeColor(Palette.halo)
        ctx.setLineWidth(deckWidth + haloWidth * 1.5)
        ctx.strokePath()

        let showingGrip = sin(b.flip) > 0
        let deckColor: CGColor
        if face > 0.35 { deckColor = showingGrip ? Palette.grip : Palette.underside } else { deckColor = Palette.deck }
        ctx.addPath(deck)
        ctx.setStrokeColor(deckColor)
        ctx.setLineWidth(deckWidth)
        ctx.strokePath()

        if face <= 0.35 {
            // Grip tape on top (moves under the deck automatically when flipped past 90°),
            // and a hint of the graphic underneath.
            ctx.addPath(deck.copy(using: [CGAffineTransform(translationX: 0, y: 1.1)])!)
            ctx.setStrokeColor(Palette.grip)
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.addPath(deck.copy(using: [CGAffineTransform(translationX: 0, y: -1.1)])!)
            ctx.setStrokeColor(Palette.underside)
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Figure

    /// Draws the figure in the current (local) frame and returns the head centre.
    @discardableResult
    private func drawFigure(_ pose: Pose, in ctx: CGContext) -> CGPoint {
        let up = CGVector(dx: sin(pose.lean), dy: cos(pose.lean))
        let neck = pose.hip + up * torsoLength
        let shoulder = pose.hip + up * (torsoLength - 1.5)
        let head = neck + CGVector(dx: up.dx * (headRadius + 1) + 0.6, dy: up.dy * (headRadius + 1))

        let frontKnee = ik(pose.hip, pose.frontFoot, thigh, shin, bend: 1)
        let backKnee = ik(pose.hip, pose.backFoot, thigh, shin, bend: 1)
        let frontFoot = reach(pose.hip, frontKnee, pose.frontFoot, shin)
        let backFoot = reach(pose.hip, backKnee, pose.backFoot, shin)

        let fh = shoulder + CGVector(dx: pose.frontHand.x, dy: pose.frontHand.y)
        let bh = shoulder + CGVector(dx: pose.backHand.x, dy: pose.backHand.y)
        let frontElbow = ik(shoulder, fh, upperArm, forearm, bend: -1)
        let backElbow = ik(shoulder, bh, upperArm, forearm, bend: -1)
        let frontHand = reach(shoulder, frontElbow, fh, forearm)
        let backHand = reach(shoulder, backElbow, bh, forearm)

        let limbs: [[CGPoint]] = [
            [shoulder, backElbow, backHand],
            [pose.hip, backKnee, backFoot],
            [backFoot + CGVector(dx: -0.8, dy: 0), backFoot + CGVector(dx: 2.6, dy: 0)],
            [pose.hip, frontKnee, frontFoot],
            [frontFoot + CGVector(dx: -0.8, dy: 0), frontFoot + CGVector(dx: 2.6, dy: 0)],
            [shoulder, frontElbow, frontHand],
        ]
        let torso = [pose.hip, neck]
        let haloW = limbWidth + haloWidth * 2

        // Light halo pass underneath everything.
        for l in limbs { stroke(ctx, l, width: haloW, color: Palette.halo) }
        stroke(ctx, torso, width: 5 + haloWidth * 2, color: Palette.halo)
        ctx.setFillColor(Palette.halo)
        ctx.fillEllipse(in: circle(head, headRadius + haloWidth))

        // Back limbs, torso (shirt), front limbs.
        stroke(ctx, limbs[0], width: limbWidth, color: Palette.body)
        stroke(ctx, limbs[1], width: limbWidth, color: Palette.body)
        stroke(ctx, limbs[2], width: limbWidth, color: Palette.body)
        stroke(ctx, torso, width: 5, color: Palette.shirt)
        stroke(ctx, [pose.hip, pose.hip + up * 2.5], width: 5, color: Palette.body)
        stroke(ctx, limbs[3], width: limbWidth, color: Palette.body)
        stroke(ctx, limbs[4], width: limbWidth, color: Palette.body)
        stroke(ctx, limbs[5], width: limbWidth, color: Palette.body)

        // Head with a beanie, tilted with the torso; pom-pom and brim give it a front.
        ctx.setFillColor(Palette.body)
        ctx.fillEllipse(in: circle(head, headRadius))
        ctx.setFillColor(Palette.skin)
        ctx.fillEllipse(in: circle(head + CGVector(dx: 1.3, dy: -0.9), headRadius - 1.6))
        ctx.setFillColor(Palette.body)
        ctx.fillEllipse(in: circle(head + CGVector(dx: 2.7, dy: -0.2), 0.75))

        let a = atan2(up.dy, up.dx)
        let cap = CGMutablePath()
        cap.addArc(center: head, radius: headRadius + 0.2, startAngle: a - 1.45, endAngle: a + 1.6, clockwise: false)
        cap.closeSubpath()
        ctx.addPath(cap)
        ctx.setFillColor(Palette.beanie)
        ctx.fillPath()
        let pom = head + CGVector(dx: cos(a + 0.5) * (headRadius + 0.8), dy: sin(a + 0.5) * (headRadius + 0.8))
        ctx.setFillColor(Palette.shirt)
        ctx.fillEllipse(in: circle(pom, 1.6))
        return head
    }

    // MARK: - Bail

    private func drawBail(_ state: SkaterState, remaining: Double, base: CGAffineTransform, in ctx: CGContext) {
        let total = max(0.3, state.phaseTime + max(0, remaining))
        let u = CGFloat(max(0, min(1, state.phaseTime / total)))

        // Board shoots ahead and settles, slightly tipped while it slides.
        let slide = smooth(min(1, u / 0.35))
        var board = BoardPose()
        board.tilt = -0.25 * (1 - slide) * CGFloat(u < 0.35 ? 1 : 0)
        ctx.saveGState()
        ctx.concatenate(base)
        ctx.translateBy(x: 6 + 14 * slide, y: 0)
        drawBoard(board, in: ctx)
        ctx.restoreGState()

        // Figure: tumbles backward, lies on the ground, gets back up.
        let lyingRot = CGFloat.pi / 2
        let lyingHip: CGFloat = 6
        let standHip: CGFloat = 23
        var rot: CGFloat
        var hipY: CGFloat
        var figX: CGFloat
        var kick: CGFloat = 0
        if u < 0.33 {
            let k = smooth(u / 0.33)
            rot = k * (lyingRot + 2 * .pi)
            hipY = standHip + (lyingHip - standHip) * k + sin(k * .pi) * 9
            figX = -8 * k
        } else if u < 0.78 {
            rot = lyingRot
            hipY = lyingHip
            figX = -8
            kick = CGFloat(sin(Double(u) * 40)) * 2.5
        } else {
            let k = smooth((u - 0.78) / 0.22)
            rot = lyingRot * (1 - k)
            hipY = lyingHip + (standHip - lyingHip) * k
            figX = -8 + 6 * k
        }

        let flail = CGFloat(sin(Double(u) * 30))
        let pose = Pose(hip: .zero, lean: 0,
                        frontFoot: CGPoint(x: 3 + kick, y: -21),
                        backFoot: CGPoint(x: -3 - kick, y: -21),
                        frontHand: CGPoint(x: 9, y: 6 + 3 * flail),
                        backHand: CGPoint(x: -9, y: 6 - 3 * flail))
        let fig = CGAffineTransform(translationX: figX, y: hipY).rotated(by: rot)
        ctx.saveGState()
        ctx.concatenate(base)
        ctx.concatenate(fig)
        let head = drawFigure(pose, in: ctx)
        ctx.restoreGState()
        lastHeadWorld = head.applying(fig).applying(base)
    }

    // MARK: - Held

    /// Dangling from the mouse. Local frame: origin at the grab point (neck), y up, +x the
    /// way he faces; rotated by the pendulum swing, mirrored by `facing`.
    private func drawHeld(_ state: SkaterState, in ctx: CGContext) {
        let t = state.phaseTime
        let idle = CGFloat(sin(t * 2.1)) * 0.04
        let base = CGAffineTransform(translationX: state.position.x, y: state.position.y)
            .rotated(by: swingAngle + idle)
            .scaledBy(x: state.facing < 0 ? -1 : 1, y: 1)

        // Legs pedal together, so the board bobs and wiggles but stays on his feet.
        let kick = CGFloat(sin(t * 9))
        var board = BoardPose()
        board.lift = kick * 1.6
        board.tilt = -0.2 + kick * 0.09 + swingAngle * 0.25
        let boardOrigin = CGAffineTransform(translationX: 0, y: -Self.heldBoardOffset)
        let boardT = boardTransform(board).concatenating(boardOrigin)

        let wave = CGFloat(sin(t * 11))
        let wave2 = CGFloat(sin(t * 11 + 1.7))
        let footSpread: CGFloat = 6
        let pose = Pose(hip: CGPoint(x: 0.5, y: -12.5),
                        lean: 0.05 * wave,
                        frontFoot: CGPoint(x: footSpread, y: deckTop).applying(boardT),
                        backFoot: CGPoint(x: -footSpread, y: deckTop).applying(boardT),
                        frontHand: CGPoint(x: 9 + 1.5 * wave2, y: 9 + 3 * wave),
                        backHand: CGPoint(x: -9 - 1.5 * wave, y: 8 - 3 * wave2))

        ctx.saveGState()
        ctx.concatenate(base)
        ctx.saveGState()
        ctx.concatenate(boardOrigin)
        drawBoard(board, in: ctx)
        ctx.restoreGState()
        let head = drawFigure(pose, in: ctx)
        ctx.restoreGState()
        lastHeadWorld = head.applying(base)
    }

    /// Three little lines popping out above the head when he's grabbed.
    private func drawSurprise(in ctx: CGContext) {
        guard surpriseTime > 0, let head = lastHeadWorld else { return }
        let u = CGFloat(1 - surpriseTime / surpriseDuration)       // 0 → 1
        let fade = min(1, (1 - u) / 0.35)
        let pop = smooth(min(1, u / 0.25))
        let angles: [CGFloat] = [CGFloat.pi / 2, CGFloat.pi / 2 + 0.6, CGFloat.pi / 2 - 0.6]
        let r0: CGFloat = headRadius + 3 + 2 * pop
        let r1: CGFloat = r0 + 6 * pop
        let halo = Palette.halo.copy(alpha: 0.88 * fade) ?? Palette.halo
        let ink = Palette.body.copy(alpha: fade) ?? Palette.body
        for a in angles {
            let dir = CGVector(dx: cos(a), dy: sin(a))
            let inner = head + dir * r0
            let outer = head + dir * r1
            stroke(ctx, [inner, outer], width: 2 + haloWidth * 2, color: halo)
            stroke(ctx, [inner, outer], width: 2, color: ink)
        }
    }

    // MARK: - Particles

    private func add(_ p: Particle) {
        if particles.count >= maxParticles { particles.removeFirst() }
        particles.append(p)
    }

    private func world(_ local: CGPoint, _ s: SkaterState) -> CGPoint {
        local.applying(CGAffineTransform(translationX: s.position.x, y: s.position.y)
            .rotated(by: s.angle).scaledBy(x: s.facing < 0 ? -1 : 1, y: 1))
    }

    private func spawnSparks(_ s: SkaterState, count: Int) {
        let origin = world(CGPoint(x: -wheelX - 2, y: 0.5), s)
        let back = -s.facing
        for _ in 0..<count {
            let v = CGVector(dx: back * .random(in: 40...150) + s.velocity.dx * 0.2,
                             dy: .random(in: 30...140))
            add(Particle(kind: .spark, position: origin, velocity: v,
                         life: .random(in: 0.18...0.32), maxLife: 0.32, size: .random(in: 0.9...1.6)))
        }
    }

    private func spawnDust(_ s: SkaterState) {
        let tangent = CGVector(dx: cos(s.angle), dy: sin(s.angle))
        let normal = tangent.perpendicular
        for i in 0..<8 {
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            let along = side * .random(in: 4...16)
            let pos = s.position + tangent * along + normal * 1.5
            let v = tangent * (side * .random(in: 25...70)) + normal * .random(in: 4...22)
            add(Particle(kind: .dust, position: pos, velocity: v,
                         life: .random(in: 0.3...0.4), maxLife: 0.4, size: .random(in: 2...3.5)))
        }
    }

    private func spawnPop(_ s: SkaterState) {
        let tail = world(CGPoint(x: -15, y: 0.5), s)
        for _ in 0..<5 {
            let v = CGVector(dx: .random(in: -40...40), dy: .random(in: 0...35))
            add(Particle(kind: .pop, position: tail, velocity: v,
                         life: .random(in: 0.18...0.26), maxLife: 0.26, size: .random(in: 1.5...2.5)))
        }
    }

    private func drawBackParticles(in ctx: CGContext) {
        for p in particles where p.kind != .spark {
            let f = CGFloat(max(0, p.life / p.maxLife))
            let r = circle(p.position, p.size)
            if p.kind == .dust {
                ctx.setFillColor(CGColor(srgbRed: 0.62, green: 0.62, blue: 0.64, alpha: 0.5 * f))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 0.75 * f))
            }
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.33, alpha: 0.35 * f))
            ctx.setLineWidth(0.6)
            ctx.strokeEllipse(in: r)
        }
    }

    private func drawFrontParticles(in ctx: CGContext) {
        for p in particles where p.kind == .spark {
            let f = CGFloat(max(0, p.life / p.maxLife))
            let tailV = p.velocity.normalized * (2 + 4 * f)
            let a = p.position
            let b = p.position - tailV
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.45 + 0.45 * f, blue: 0.1 + 0.3 * f, alpha: f))
            ctx.setLineWidth(p.size)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
    }

    private func drawBailStars(in ctx: CGContext) {
        guard bailStarTime > 0, let head = lastHeadWorld else { return }
        let fade = CGFloat(min(1, bailStarTime / 0.3, (bailStarDuration - bailStarTime) / 0.1 + 0.2))
        let n = 4
        let centre = head + CGVector(dx: 0, dy: headRadius + 4)
        for i in 0..<n {
            let a = clock * 5 + Double(i) * 2 * .pi / Double(n)
            let p = centre + CGVector(dx: CGFloat(cos(a)) * 10, dy: CGFloat(sin(a)) * 3.5)
            let r: CGFloat = 2.6 + 0.6 * CGFloat(sin(a))  // nearer stars a touch bigger
            let path = starPath(p, outer: r, inner: r * 0.45, spin: CGFloat(clock * 3))
            ctx.addPath(path)
            ctx.setFillColor(Palette.star.copy(alpha: fade) ?? Palette.star)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(Palette.body.copy(alpha: 0.8 * fade) ?? Palette.body)
            ctx.setLineWidth(0.7)
            ctx.strokePath()
        }
    }

    // MARK: - Helpers

    private func stroke(_ ctx: CGContext, _ pts: [CGPoint], width: CGFloat, color: CGColor) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private func starPath(_ c: CGPoint, outer: CGFloat, inner: CGFloat, spin: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<10 {
            let r = i % 2 == 0 ? outer : inner
            let a = spin + CGFloat(i) * .pi / 5 + .pi / 2
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Two-bone IK: the joint between `a` and `b`. `bend` picks the side (+1 = left of a→b,
    /// which is "forward" for a leg pointing down).
    private func ik(_ a: CGPoint, _ b: CGPoint, _ l1: CGFloat, _ l2: CGFloat, bend: CGFloat) -> CGPoint {
        let v = b - a
        let d = max(0.001, min(v.length, l1 + l2 - 0.001))
        let u = v.normalized
        let along = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        let h = (max(0, l1 * l1 - along * along)).squareRoot()
        return a + u * along + u.perpendicular * (bend * h)
    }

    /// Where the end effector actually lands (clamped to the limb's reach).
    private func reach(_ root: CGPoint, _ joint: CGPoint, _ target: CGPoint, _ len: CGFloat) -> CGPoint {
        let v = target - joint
        let l = v.length
        if l <= len + 0.01 { return target }
        return joint + v.normalized * len
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func smooth(_ t: CGFloat) -> CGFloat {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}
