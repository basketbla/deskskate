import AppKit
import DeskSkateCore

/// The menu bar item. (US-009) Rebuilt every time it opens so checkmarks track AppState.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "figure.skateboarding",
                                   accessibilityDescription: "DeskSkate") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🛹"
            }
            button.toolTip = "DeskSkate"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuild(menu)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: Building

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AppState.shared

        let auto = action("Autonomous", #selector(setAutonomous))
        auto.state = state.mode == .autonomous ? .on : .off
        let keyboard = action("Keyboard", #selector(setKeyboard))
        keyboard.state = state.mode == .keyboard ? .on : .off
        // Shown next to whichever mode the hotkey would switch to.
        let toggleTarget = state.mode == .autonomous ? keyboard : auto
        toggleTarget.keyEquivalent = "s"
        toggleTarget.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(auto)
        menu.addItem(keyboard)

        menu.addItem(.separator())
        let addItem = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
        let addMenu = NSMenu(title: "Add")
        addMenu.autoenablesItems = false
        for kind in ObstacleKind.allCases {
            let i = action(kind.displayName, #selector(addObstacle(_:)))
            i.representedObject = kind.rawValue
            addMenu.addItem(i)
        }
        addItem.submenu = addMenu
        menu.addItem(addItem)
        menu.addItem(action("Remove All Obstacles", #selector(removeAll)))

        menu.addItem(.separator())
        menu.addItem(action("Respawn Skater", #selector(respawn)))
        let hide = action(state.hidden ? "Show Skater" : "Hide Skater", #selector(toggleHidden))
        hide.keyEquivalent = "h"
        hide.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(hide)
        menu.addItem(action(state.paused ? "Resume" : "Pause", #selector(togglePaused)))
        let surfaces = action("Show Surfaces", #selector(toggleSurfaces))
        surfaces.state = state.showSurfaces ? .on : .off
        menu.addItem(surfaces)

        menu.addItem(.separator())
        let controlsItem = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        let controls = NSMenu(title: "Controls")
        controls.autoenablesItems = false
        for line in [
            "←/→ or A/D — push & turn",
            "Space — hold to crouch, release to ollie",
            "↑, W or F — flip trick (in the air)",
            "↓ or S — hold to grind",
            "R — respawn at the mouse",
            "Esc — back to autonomous",
            "⌃⌥S — switch mode",
            "⌃⌥H — hide/show",
        ] {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            controls.addItem(i)
        }
        controlsItem.submenu = controls
        menu.addItem(controlsItem)

        menu.addItem(.separator())
        let quit = action("Quit DeskSkate", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: Actions

    @objc private func setAutonomous() { AppState.shared.mode = .autonomous }
    @objc private func setKeyboard() { AppState.shared.mode = .keyboard }

    @objc private func addObstacle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ObstacleKind(rawValue: raw) else { return }
        ObstacleManager.shared.add(kind)
    }

    @objc private func removeAll() { ObstacleManager.shared.removeAll() }
    @objc private func respawn() { GameController.shared.respawn() }
    @objc private func toggleHidden() { AppState.shared.hidden.toggle() }
    @objc private func togglePaused() { AppState.shared.paused.toggle() }
    @objc private func toggleSurfaces() { AppState.shared.showSurfaces.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
