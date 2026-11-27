import AppKit
import ApplicationServices
import AutoWindowCore
import Carbon.HIToolbox
import SwiftUI

/// Moves the front window to half, a quarter or a third of its screen, to another screen, or back.
/// Works from the menu and from global shortcuts (⌃⌥ plus a key, the same ones Magnet uses).
@MainActor
enum Snapper {
    /// Frames from before a window was first snapped, for Restore.
    private static var before: [CGWindowID: CGRect] = [:]

    /// Snaps `window`, or the front window when none is given.
    static func perform(_ action: SnapAction, window given: AXWindow? = nil) {
        guard AXWindow.isTrusted, let window = given ?? frontWindow(), let frame = window.frame else { NSSound.beep(); return }
        let areas = screenAreas()
        guard let index = WindowSnap.areaIndex(for: frame, in: areas) else { NSSound.beep(); return }
        let id = window.windowID

        let target: CGRect?
        switch action {
        case .restore:
            target = id.flatMap { before.removeValue(forKey: $0) }
        case .nextDisplay, .previousDisplay:
            guard areas.count > 1 else { NSSound.beep(); return }
            let step = action == .nextDisplay ? 1 : areas.count - 1
            target = WindowSnap.move(frame, from: areas[index], to: areas[(index + step) % areas.count])
        default:
            target = WindowSnap.frame(action, window: frame, in: areas[index])
            if let id, before[id] == nil { before[id] = frame }
        }
        guard let target else { NSSound.beep(); return }
        window.setFrame(target)
    }

    /// The focused window of the frontmost app.
    private static func frontWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: value as! AXUIElement, app: app)
    }

    /// Each screen's usable area (no menu bar, no Dock) in Accessibility coordinates (top-left origin),
    /// left to right.
    static func screenAreas() -> [CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens
            .map { s in
                let v = s.visibleFrame
                return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
            }
            .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    // MARK: - Shortcuts

    /// Apps that snap windows too. With one of them running, the same keys and the green button can go to either app.
    static let otherWindowApps: [String: String] = [
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.divisiblebyzero.Spectacle": "Spectacle",
        "com.manytricks.Moom": "Moom",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.mizage.Divvy": "Divvy",
        "com.mizage.direct.Divvy": "Divvy",
        "com.amethyst.Amethyst": "Amethyst",
        "com.MrKai77.Loop": "Loop",
        "co.highlyopinionated.swish": "Swish",
    ]

    /// Window apps from `otherWindowApps` running now.
    static func runningOtherWindowApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier.map { otherWindowApps[$0] != nil } == true
        }
    }

    /// Shortcuts macOS refused because another app already has them: the generic check, for apps not in the list.
    private(set) static var takenShortcuts: [SnapAction] = []

    /// The key and modifiers for each action, as Magnet ships them.
    static func shortcut(for action: SnapAction) -> (keyCode: Int, key: KeyEquivalent, command: Bool) {
        switch action {
        case .left: (kVK_LeftArrow, .leftArrow, false)
        case .right: (kVK_RightArrow, .rightArrow, false)
        case .top: (kVK_UpArrow, .upArrow, false)
        case .bottom: (kVK_DownArrow, .downArrow, false)
        case .topLeft: (kVK_ANSI_U, "u", false)
        case .topRight: (kVK_ANSI_I, "i", false)
        case .bottomLeft: (kVK_ANSI_J, "j", false)
        case .bottomRight: (kVK_ANSI_K, "k", false)
        case .leftThird: (kVK_ANSI_D, "d", false)
        case .centerThird: (kVK_ANSI_F, "f", false)
        case .rightThird: (kVK_ANSI_G, "g", false)
        case .leftTwoThirds: (kVK_ANSI_E, "e", false)
        case .centerTwoThirds: (kVK_ANSI_R, "r", false)
        case .rightTwoThirds: (kVK_ANSI_T, "t", false)
        case .nextDisplay: (kVK_RightArrow, .rightArrow, true)
        case .previousDisplay: (kVK_LeftArrow, .leftArrow, true)
        case .maximize: (kVK_Return, .return, false)
        case .center: (kVK_ANSI_C, "c", false)
        case .restore: (kVK_Delete, .delete, false)
        }
    }

    /// "⌃⌥←" and so on, as menus show it.
    static func shortcutLabel(for action: SnapAction) -> String {
        let s = shortcut(for: action)
        let key: String
        switch s.key {
        case .leftArrow: key = "←"
        case .rightArrow: key = "→"
        case .upArrow: key = "↑"
        case .downArrow: key = "↓"
        case .return: key = "↩"
        case .delete: key = "⌫"
        default: key = String(s.key.character).uppercased()
        }
        return "⌃⌥" + (s.command ? "⌘" : "") + key
    }

    private static var hotKeys: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?

    /// Turns the global shortcuts on or off. Carbon hot keys need no extra permission.
    static func setShortcutsEnabled(_ enabled: Bool) {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        takenShortcuts = []
        guard enabled else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let all = SnapAction.allCases
                if Int(hk.id) < all.count {
                    let action = all[Int(hk.id)]
                    DispatchQueue.main.async { MainActor.assumeIsolated { Snapper.perform(action) } }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (i, action) in SnapAction.allCases.enumerated() {
            let s = shortcut(for: action)
            let mods = UInt32(controlKey | optionKey | (s.command ? cmdKey : 0))
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4157_534E), id: UInt32(i)) // "AWSN"
            if RegisterEventHotKey(UInt32(s.keyCode), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                hotKeys.append(ref)
            } else {
                takenShortcuts.append(action)
            }
        }
    }
}
