import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ObstacleManager.shared.restore()
        GameController.shared.start()
        StatusMenu.shared.install()
        ModeController.shared.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ObstacleManager.shared.save()
    }
}
