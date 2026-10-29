import AppKit
import DeskSkateCore

/// Reads other apps' window frames from the window server. (US-003)
final class WindowTracker {
    init(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) {}

    /// Current on-screen windows in global AppKit coordinates, with velocities measured
    /// against the previous call. `now` is a monotonic timestamp in seconds.
    func poll(now: CFTimeInterval) -> [TrackedWindow] { [] }

    /// Visible frames (menu bar and Dock excluded) of every screen.
    static func screenFrames() -> [CGRect] { NSScreen.screens.map(\.visibleFrame) }
}
