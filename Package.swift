// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeskSkate",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure simulation: geometry, physics, autopilot. No AppKit.
        .target(name: "DeskSkateCore"),
        // The menu bar app: overlay windows, window tracking, rendering, input.
        .executableTarget(name: "DeskSkate", dependencies: ["DeskSkateCore"]),
        // Headless physics scenarios: `swift run simcheck`.
        .executableTarget(name: "simcheck", dependencies: ["DeskSkateCore"]),
    ]
)
