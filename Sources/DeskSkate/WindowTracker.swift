import AppKit
import DeskSkateCore

/// Reads other apps' window frames from the window server. (US-003)
///
/// Uses only CGWindowListCopyWindowInfo bounds/layer/alpha/owner fields, which need no
/// Screen Recording permission (window titles are never read).
final class WindowTracker {
    /// Owners whose layer-0 windows are not real app windows.
    private static let ignoredOwners: Set<String> = ["Window Server", "Dock"]

    /// Smoothing factor per poll for the exponential velocity filter.
    private static let smoothing: CGFloat = 0.5
    /// Raw speeds below this (pt/s) count as "stopped".
    private static let stopSpeed: CGFloat = 5
    /// Consecutive slow polls before velocity snaps to zero.
    private static let stopPolls = 2
    /// Polls further apart than this are treated as a fresh sighting.
    private static let maxGap: CFTimeInterval = 0.25
    /// Top-edge jump (pt) in one poll that no drag could produce.
    private static let teleportDistance: CGFloat = 400
    /// Size change (pt, either dimension) in one poll that counts as a teleport.
    private static let teleportResize: CGFloat = 300

    private struct History {
        var frame: CGRect
        var time: CFTimeInterval
        var velocity: CGVector
        var slowPolls: Int
    }

    private let excludedPID: pid_t
    private var history: [UInt32: History] = [:]

    init(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        excludedPID = excludingPID
    }

    /// Current on-screen windows in global AppKit coordinates, with velocities measured
    /// against the previous call. `now` is a monotonic timestamp in seconds.
    func poll(now: CFTimeInterval) -> [TrackedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            history.removeAll()
            return []
        }
        let primaryHeight = Self.primaryScreenHeight()

        var result: [TrackedWindow] = []
        var nextHistory: [UInt32: History] = [:]
        nextHistory.reserveCapacity(history.count)

        for entry in info {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != excludedPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }
            if let owner = entry[kCGWindowOwnerName as String] as? String, Self.ignoredOwners.contains(owner) {
                continue
            }
            guard cgBounds.width >= 60, cgBounds.height >= 40 else { continue }

            let frame = CGRect(x: cgBounds.origin.x,
                               y: primaryHeight - (cgBounds.origin.y + cgBounds.height),
                               width: cgBounds.width,
                               height: cgBounds.height)

            var velocity = CGVector.zero
            var teleported = false
            var state = History(frame: frame, time: now, velocity: .zero, slowPolls: 0)

            if let prev = history[number] {
                let dt = now - prev.time
                if dt > 0, dt <= Self.maxGap {
                    let dTop = CGVector(dx: frame.midX - prev.frame.midX, dy: frame.maxY - prev.frame.maxY)
                    let dw = abs(frame.width - prev.frame.width)
                    let dh = abs(frame.height - prev.frame.height)
                    if dTop.length > Self.teleportDistance || dw > Self.teleportResize || dh > Self.teleportResize {
                        teleported = true
                    } else {
                        let raw = dTop * CGFloat(1 / dt)
                        let slow = raw.length < Self.stopSpeed ? prev.slowPolls + 1 : 0
                        if slow >= Self.stopPolls {
                            velocity = .zero
                        } else {
                            velocity = prev.velocity + (raw - prev.velocity) * Self.smoothing
                        }
                        state.velocity = velocity
                        state.slowPolls = slow
                    }
                }
                // dt out of range: treat as fresh (zero velocity, smoothing reset).
            }

            nextHistory[number] = state
            result.append(TrackedWindow(id: number, frame: frame, velocity: velocity,
                                        teleported: teleported, zIndex: result.count))
        }

        // Windows that disappeared drop out of the history here.
        history = nextHistory
        return result
    }

    /// Height of the primary screen (the one whose frame origin is zero), used to flip
    /// CGWindowList's top-left-origin rects into AppKit's bottom-left space.
    static func primaryScreenHeight() -> CGFloat {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary?.frame.height ?? 0
    }

    /// Visible frames (menu bar and Dock excluded) of every screen.
    static func screenFrames() -> [CGRect] { NSScreen.screens.map(\.visibleFrame) }
}
