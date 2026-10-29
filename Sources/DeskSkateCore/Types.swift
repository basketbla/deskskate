import CoreGraphics
import Foundation

// Shared contract between the simulation and the app.
//
// Coordinates: global AppKit space. y points UP, origin is the bottom-left of the
// primary screen, units are points. Everything in the core speaks this space; the app
// converts CGWindowList's top-left-origin rects before handing them over.

// MARK: - Vector helpers

public extension CGPoint {
    static func + (a: CGPoint, b: CGVector) -> CGPoint { CGPoint(x: a.x + b.dx, y: a.y + b.dy) }
    static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
    static func - (a: CGPoint, b: CGVector) -> CGPoint { CGPoint(x: a.x - b.dx, y: a.y - b.dy) }
}

public extension CGVector {
    static func + (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy) }
    static func - (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx - b.dx, dy: a.dy - b.dy) }
    static func * (a: CGVector, s: CGFloat) -> CGVector { CGVector(dx: a.dx * s, dy: a.dy * s) }
    static prefix func - (a: CGVector) -> CGVector { CGVector(dx: -a.dx, dy: -a.dy) }
    var length: CGFloat { (dx * dx + dy * dy).squareRoot() }
    var normalized: CGVector { let l = length; return l > 0 ? CGVector(dx: dx / l, dy: dy / l) : .zero }
    func dot(_ o: CGVector) -> CGFloat { dx * o.dx + dy * o.dy }
    /// Left-hand perpendicular (rotate +90°).
    var perpendicular: CGVector { CGVector(dx: -dy, dy: dx) }
}

// MARK: - World

/// Something solid the skater can stand on, grind, or bounce off.
///
/// A surface is a segment from `a` to `b`. The solid side is to the RIGHT of a→b and the
/// outward normal is `(b - a).normalized.perpendicular` (the left-hand side). So a flat floor
/// runs left→right (normal points up), a quarter pipe rising to the right runs left→right
/// and up (normal points up-left). Walls: the world's left wall runs top→bottom (normal +x,
/// into the world) and its right wall runs bottom→top (normal −x). Always use `normal`.
public struct Surface: Equatable {
    public enum Kind: String { case ground, ledge, ramp, rail, wall }

    public var id: String
    public var a: CGPoint
    public var b: CGPoint
    public var kind: Kind
    /// One-way surfaces only collide when approached from the normal side (jump up through a
    /// window ledge, land on it from above). Walls and the screen floor are two-way.
    public var oneWay: Bool
    /// Ledges (window top edges), rails and box edges can be ground along.
    public var grindable: Bool
    /// The window or obstacle this belongs to, if any. Surfaces chain into a polyline when
    /// one segment's `b` equals the next one's `a` with the same owner.
    public var ownerID: UInt32?
    /// How fast the owner moved this frame (points/second). A skater standing on a surface
    /// is carried by it, and keeps this velocity when it leaves the surface.
    public var ownerVelocity: CGVector

    public init(id: String, a: CGPoint, b: CGPoint, kind: Kind, oneWay: Bool, grindable: Bool,
                ownerID: UInt32? = nil, ownerVelocity: CGVector = .zero) {
        self.id = id; self.a = a; self.b = b; self.kind = kind; self.oneWay = oneWay
        self.grindable = grindable; self.ownerID = ownerID; self.ownerVelocity = ownerVelocity
    }

    public var direction: CGVector { (b - a).normalized }
    public var normal: CGVector { direction.perpendicular }
    public var length: CGFloat { (b - a).length }
}

/// One on-screen window as the tracker last saw it.
public struct TrackedWindow: Equatable {
    public var id: UInt32
    public var frame: CGRect
    /// Points/second, measured between the last two polls. Zero when `teleported`.
    public var velocity: CGVector
    /// The window jumped further than any drag could move it in one poll (Mission Control,
    /// Space switch, Stage Manager, snapping). Treat as a new position, not a velocity.
    public var teleported: Bool
    /// 0 = frontmost. Higher numbers are further back.
    public var zIndex: Int

    public init(id: UInt32, frame: CGRect, velocity: CGVector = .zero, teleported: Bool = false, zIndex: Int) {
        self.id = id; self.frame = frame; self.velocity = velocity; self.teleported = teleported; self.zIndex = zIndex
    }
}

public enum ObstacleKind: String, Codable, CaseIterable {
    case quarterPipe, kicker, rail, box

    public var displayName: String {
        switch self {
        case .quarterPipe: "Quarter Pipe"
        case .kicker: "Kicker"
        case .rail: "Rail"
        case .box: "Box"
        }
    }

    /// Default size when dropped onto the desktop.
    public var defaultSize: CGSize {
        switch self {
        case .quarterPipe: CGSize(width: 140, height: 120)
        case .kicker: CGSize(width: 110, height: 44)
        case .rail: CGSize(width: 220, height: 40)
        case .box: CGSize(width: 180, height: 46)
        }
    }
}

/// A ramp or obstacle the user dropped on the desktop. `frame` is its bounding box in global
/// AppKit coordinates. `flipped` mirrors it horizontally (quarter pipe facing left, etc.).
public struct ObstacleModel: Codable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ObstacleKind
    public var frame: CGRect
    public var flipped: Bool
    /// Owner id used on the surfaces this obstacle produces; set by the app, stable per session.
    public var ownerID: UInt32
    public var velocity: CGVector

    public init(id: UUID = UUID(), kind: ObstacleKind, frame: CGRect, flipped: Bool = false,
                ownerID: UInt32 = 0, velocity: CGVector = .zero) {
        self.id = id; self.kind = kind; self.frame = frame; self.flipped = flipped
        self.ownerID = ownerID; self.velocity = velocity
    }

    enum CodingKeys: String, CodingKey { case id, kind, frame, flipped }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ObstacleKind.self, forKey: .kind)
        frame = try c.decode(CGRect.self, forKey: .frame)
        flipped = try c.decode(Bool.self, forKey: .flipped)
        ownerID = 0
        velocity = .zero
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind)
        try c.encode(frame, forKey: .frame); try c.encode(flipped, forKey: .flipped)
    }
}

/// Everything the skater can collide with this frame.
public struct WorldSnapshot {
    public var surfaces: [Surface]
    /// Visible frames of every screen (menu bar and Dock excluded).
    public var screens: [CGRect]

    public init(surfaces: [Surface], screens: [CGRect]) {
        self.surfaces = surfaces; self.screens = screens
    }

    public func surface(id: String) -> Surface? { surfaces.first { $0.id == id } }
}

// MARK: - Skater

/// One frame of controls, from the keyboard or the autopilot.
public struct SkaterInput: Equatable {
    public var left = false
    public var right = false
    /// Held: crouch to load an ollie. Released: pop. (`jumpPressed`/`jumpReleased` are edges.)
    public var jump = false
    public var jumpPressed = false
    public var jumpReleased = false
    /// Edge: start a flip trick in the air.
    public var trickPressed = false
    /// Held: lock into a grind when landing on a grindable surface.
    public var grind = false

    public init(left: Bool = false, right: Bool = false, jump: Bool = false, jumpPressed: Bool = false,
                jumpReleased: Bool = false, trickPressed: Bool = false, grind: Bool = false) {
        self.left = left; self.right = right; self.jump = jump; self.jumpPressed = jumpPressed
        self.jumpReleased = jumpReleased; self.trickPressed = trickPressed; self.grind = grind
    }
}

public enum SkaterPhase: Equatable {
    case rolling
    case airborne
    case grinding
    /// Fell off. `remaining` counts down to getting back up.
    case bailed(remaining: Double)
}

public enum TrickKind: String, CaseIterable { case kickflip, heelflip, shuvit, threeSixtyFlip }

public struct TrickState: Equatable {
    public var kind: TrickKind
    /// 0…1 through the animation. A trick that hasn't reached 1 when the board lands is a bail.
    public var progress: Double
    public init(kind: TrickKind, progress: Double) { self.kind = kind; self.progress = progress }
}

/// What the renderer and autopilot can read about the skater.
public struct SkaterState: Equatable {
    /// Midpoint of the board's wheels, on the surface when rolling.
    public var position: CGPoint
    /// World velocity, points/second (includes the carrying surface's motion).
    public var velocity: CGVector
    /// +1 facing/rolling right, -1 left.
    public var facing: CGFloat
    /// Board angle in radians (0 = flat). Matches the surface when rolling/grinding.
    public var angle: CGFloat
    public var phase: SkaterPhase
    /// 0…1, how deep the skater is crouched (loading an ollie, landing impact).
    public var crouch: CGFloat
    public var trick: TrickState?
    /// Surface currently under the board, if rolling or grinding.
    public var surfaceID: String?
    /// Seconds since the phase last changed — handy for animation.
    public var phaseTime: Double

    public init(position: CGPoint, velocity: CGVector = .zero, facing: CGFloat = 1, angle: CGFloat = 0,
                phase: SkaterPhase = .airborne, crouch: CGFloat = 0, trick: TrickState? = nil,
                surfaceID: String? = nil, phaseTime: Double = 0) {
        self.position = position; self.velocity = velocity; self.facing = facing; self.angle = angle
        self.phase = phase; self.crouch = crouch; self.trick = trick; self.surfaceID = surfaceID
        self.phaseTime = phaseTime
    }
}

/// Things that happened during a step, for sound, particles and the autopilot.
public enum SkaterEvent: Equatable {
    case ollie
    case landed(clean: Bool)
    case grindStart
    case grindEnd
    case bail
    case trickStarted(TrickKind)
    case respawned
}
