import AppKit
import CoreGraphics

/// Mission Control desktops ("Spaces"), read through SkyLight. These are private calls, but read-only ones
/// that work with System Integrity Protection on. Moving windows between desktops is done elsewhere
/// (`SpaceMover`) by dragging, because the private "move window to space" call no longer works without SIP off.
enum Spaces {
    struct Display {
        let uuid: String
        /// User desktops in Mission Control order; full-screen app spaces are left out.
        let desktops: [UInt64]
        let current: UInt64

        /// 1-based desktop number on this display, nil for a full-screen space.
        func index(of space: UInt64) -> Int? { desktops.firstIndex(of: space).map { $0 + 1 } }
        var currentIndex: Int? { index(of: current) }
    }

    /// Desktops per display, in Mission Control order. Empty if SkyLight isn't available.
    static func displays() -> [Display] {
        guard let conn = SL.connection,
              let raw = SL.copyManagedDisplaySpaces?(conn)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let mainUUID = Displays.current().first(where: \.isMain)?.uuid
        return raw.compactMap { entry in
            guard var uuid = entry["Display Identifier"] as? String else { return nil }
            // "Main" when Displays-have-separate-Spaces is off: one set of desktops for all displays.
            if uuid == "Main", let mainUUID { uuid = mainUUID }
            let spaces = entry["Spaces"] as? [[String: Any]] ?? []
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["id64"] as? UInt64 }
            let current = (entry["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
            return Display(uuid: uuid.uppercased(), desktops: desktops, current: current)
        }
    }

    /// The space(s) a window is on (more than one only for "all desktops" windows).
    static func spaces(forWindow id: CGWindowID) -> [UInt64] {
        guard let conn = SL.connection, let fn = SL.copySpacesForWindows else { return [] }
        return fn(conn, 7, [id] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    }

    /// Mission Control's global "Desktop N" number (what Ctrl+N switches to): desktops are numbered
    /// across displays in Mission Control order.
    static func globalNumber(display uuid: String, index: Int, in displays: [Display]) -> Int? {
        var offset = 0
        for d in displays {
            if d.uuid == uuid { return index <= d.desktops.count ? offset + index : nil }
            offset += d.desktops.count
        }
        return nil
    }

    private enum SL {
        typealias ConnFn = @convention(c) () -> Int32
        typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

        static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        static let connection: Int32? = sym("SLSMainConnectionID", ConnFn.self)?()
        static let copyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces", DisplaySpacesFn.self)
        static let copySpacesForWindows = sym("SLSCopySpacesForWindows", SpacesForWindowsFn.self)

        static func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
    }
}

/// Appends to ~/Library/Application Support/AutoWindow/events.log (restore steps, for troubleshooting).
enum EventLog {
    static func write(_ line: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoWindow/events.log")
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// The "Switch to Desktop N" keyboard shortcuts from System Settings → Keyboard → Keyboard Shortcuts → Mission Control.
enum DesktopShortcuts {
    struct Shortcut { let keyCode: CGKeyCode; let flags: CGEventFlags }

    /// Shortcut for Desktop `number` (1…16), nil if it's turned off.
    static func shortcut(forDesktop number: Int) -> Shortcut? {
        guard (1...16).contains(number),
              let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(117 + number)] as? [String: Any],
              (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
              let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3
        else { return nil }
        return Shortcut(keyCode: CGKeyCode(params[1]), flags: CGEventFlags(rawValue: UInt64(params[2])))
    }

    static func press(_ s: Shortcut) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: s.keyCode, keyDown: down)
            e?.flags = s.flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
