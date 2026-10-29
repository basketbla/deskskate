import AppKit

/// Frames of the Finder desktop icons, so the skater can ride them like windows.
///
/// Finder is the only source for icon positions. It is asked over AppleScript (via
/// `osascript`, off the main thread) every few seconds; macOS asks once for permission to
/// control Finder. `desktop position` is the icon's centre in top-left-origin global coordinates.
final class DesktopIcons {
    static let shared = DesktopIcons()

    /// Icon image rects in global AppKit coordinates (labels excluded).
    private(set) var frames: [CGRect] = []

    private var timer: Timer?
    private var inFlight = false
    private let queue = DispatchQueue(label: "DeskSkate.desktopIcons", qos: .utility)

    private static let script = """
    tell application "Finder"
        set s to icon size of icon view options of window of desktop
        set p to desktop position of every item of desktop
    end tell
    return {s, p}
    """

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.refresh() }
        } else {
            timer?.invalidate()
            timer = nil
            frames = []
        }
    }

    private func refresh() {
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            let output = Self.runScript()
            let primaryHeight = DispatchQueue.main.sync { WindowTracker.primaryScreenHeight() }
            let frames = output.flatMap { Self.parse($0, primaryHeight: primaryHeight) }
            DispatchQueue.main.async {
                self.inFlight = false
                // Keep the last good answer if Finder didn't reply (busy, permission pending).
                if let frames, self.timer != nil {
                    self.frames = frames
                } else if frames == nil {
                    NSLog("DeskSkate: Finder did not report desktop icons (permission?)")
                }
            }
        }
    }

    private static func runScript() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// "64, 1662, 409, 1538, 857, …" → icon size, then centre x/y pairs.
    static func parse(_ text: String, primaryHeight: CGFloat) -> [CGRect]? {
        let numbers = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard let size = numbers.first, size > 0 else { return nil }
        let side = CGFloat(size)
        var rects: [CGRect] = []
        var i = 1
        while i + 1 < numbers.count {
            let cx = CGFloat(numbers[i]), cy = CGFloat(numbers[i + 1])
            rects.append(CGRect(x: cx - side / 2, y: primaryHeight - cy - side / 2, width: side, height: side))
            i += 2
        }
        return rects
    }
}
