import Foundation

/// App-wide settings the menu, hotkeys and game loop share. Changes post `.appStateChanged`.
final class AppState {
    static let shared = AppState()

    enum Mode: String { case autonomous, keyboard }

    var mode: Mode = .autonomous { didSet { if mode != oldValue { changed() } } }
    /// Hide the skater and obstacles without quitting.
    var hidden = false { didSet { if hidden != oldValue { changed() } } }
    var paused = false { didSet { if paused != oldValue { changed() } } }
    /// Obstacles fall onto window tops / the floor and ride windows when dropped.
    var obstacleGravity = UserDefaults.standard.bool(forKey: "obstacleGravity") {
        didSet {
            UserDefaults.standard.set(obstacleGravity, forKey: "obstacleGravity")
            if obstacleGravity != oldValue { changed() }
        }
    }
    /// The controls card in keyboard mode (toggled with `/`).
    var showControls = true { didSet { if showControls != oldValue { changed() } } }
    /// Draw the collision surfaces over the desktop (debug).
    var showSurfaces = false { didSet { if showSurfaces != oldValue { changed() } } }

    private func changed() {
        NotificationCenter.default.post(name: .appStateChanged, object: self)
    }
}

extension Notification.Name {
    static let appStateChanged = Notification.Name("DeskSkate.appStateChanged")
}
