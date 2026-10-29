import AppKit
import DeskSkateCore

/// The draggable ramps and obstacles on the desktop. (US-008)
final class ObstacleManager {
    static let shared = ObstacleManager()

    func restore() {}
    func save() {}
    func add(_ kind: ObstacleKind) {}
    func removeAll() {}

    /// Obstacles as they are right now (frames follow drags live, with velocity), for the
    /// surface builder. Called once per frame by the game loop.
    func currentModels(dt: Double) -> [ObstacleModel] { [] }
}
