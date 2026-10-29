import AppKit
import Carbon

/// Global hotkeys and switching keyboard focus in and out of the overlay. (US-009)
///
/// ⌃⌥S toggles autonomous/keyboard, ⌃⌥H hides/shows. Carbon `RegisterEventHotKey` needs no
/// Accessibility or Input Monitoring permission. Entering keyboard mode remembers the frontmost
/// app and activates DeskSkate; leaving it (Esc, ⌃⌥S, menu) hands focus back. Clicking another
/// app keeps keyboard mode (the skater just stops getting keys); ⌃⌥S then takes focus back
/// instead of switching modes.
final class ModeController {
    static let shared = ModeController()

    private static let signature: OSType = 0x44534B54 // 'DSKT'
    private static let toggleModeID: UInt32 = 1
    private static let toggleHiddenID: UInt32 = 2

    private var installed = false
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []

    private var previousMode: AppState.Mode = .autonomous
    private var rememberedApp: NSRunningApplication?

    func install() {
        guard !installed else { return }
        installed = true
        previousMode = AppState.shared.mode
        installHotKeys()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.stateChanged()
        })
    }

    // MARK: Hotkeys

    private func installHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == ModeController.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            DispatchQueue.main.async { ModeController.shared.hotKeyPressed(id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("DeskSkate: InstallEventHandler failed (\(status))") }

        let mods = UInt32(controlKey | optionKey)
        register(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, id: Self.toggleModeID)
        register(keyCode: UInt32(kVK_ANSI_H), modifiers: mods, id: Self.toggleHiddenID)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("DeskSkate: RegisterEventHotKey(\(keyCode)) failed (\(status))")
        }
    }

    private func hotKeyPressed(_ id: UInt32) {
        let state = AppState.shared
        switch id {
        case Self.toggleModeID:
            if state.mode == .keyboard && !NSApp.isActive {
                refocusKeyboard()
            } else {
                state.mode = state.mode == .keyboard ? .autonomous : .keyboard
            }
        case Self.toggleHiddenID:
            state.hidden.toggle()
        default:
            break
        }
    }

    // MARK: Focus handling

    private func stateChanged() {
        let mode = AppState.shared.mode
        guard mode != previousMode else { return }
        previousMode = mode
        switch mode {
        case .keyboard: enterKeyboard()
        case .autonomous: leaveKeyboard()
        }
    }

    private func enterKeyboard() {
        rememberFrontApp()
        AppState.shared.showControls = true
        if AppState.shared.hidden { AppState.shared.hidden = false }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keyboard mode, but the user clicked into another app: take the keys back.
    private func refocusKeyboard() {
        rememberFrontApp()
        if AppState.shared.hidden { AppState.shared.hidden = false }
        NSApp.activate(ignoringOtherApps: true)
        GameController.shared.focusKeyboardPanel()
    }

    private func rememberFrontApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            rememberedApp = front
        }
    }

    private func leaveKeyboard() {
        defer { rememberedApp = nil }
        guard NSApp.isActive,
              let app = rememberedApp, !app.isTerminated else { return }
        app.activate()
    }
}
