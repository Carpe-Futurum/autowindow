import AppKit
import ApplicationServices

/// Finds every standard window of the running apps on all desktops, with its window ID.
///
/// The Accessibility API only lists an app's windows on the desktops showing right now. Windows on other
/// desktops are found by asking for the app's AX elements by number ("remote token"), the same trick
/// window managers like yabai use; it needs only the Accessibility permission.
enum WindowCatalog {
    struct Entry {
        let window: AXWindow
        let id: CGWindowID
        let bundleID: String
        /// Order among the app's windows: front-to-back on visible desktops first, then the others.
        let index: Int
    }

    static func all(apps: [NSRunningApplication] = WindowManager.regularApps()) -> [Entry] {
        let cgByPID = candidateWindowIDs()
        var result: [Entry] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            var seen = Set<CGWindowID>()
            var windows: [(AXWindow, CGWindowID)] = []
            for w in AXWindow.allElements(of: app) {
                guard let id = w.windowID, seen.insert(id).inserted else { continue }
                windows.append((w, id))
            }
            let missing = (cgByPID[app.processIdentifier] ?? []).subtracting(seen)
            if !missing.isEmpty {
                for (w, id) in remoteWindows(of: app, looking: missing) where seen.insert(id).inserted {
                    windows.append((w, id))
                }
            }
            // Windows on other desktops often don't answer the subrole question; the window server already
            // vouched for them (normal level, real size), so a readable frame is enough.
            let usable = windows.filter { w, _ in
                (w.isStandard || (w.subrole == nil && w.frame != nil)) && !w.isMinimized
            }
            for (i, (w, id)) in usable.enumerated() {
                result.append(Entry(window: w, id: id, bundleID: bundleID, index: i))
            }
        }
        return result
    }

    /// Per-app breakdown of what AX and the window server report, for autowindow://debug/catalog.
    static func diagnostics() -> String {
        let cgByPID = candidateWindowIDs()
        var out = ""
        for app in WindowManager.regularApps() {
            let ax = AXWindow.allElements(of: app)
            let axIDs = Set(ax.compactMap(\.windowID))
            let cg = cgByPID[app.processIdentifier] ?? []
            let missing = cg.subtracting(axIDs)
            let start = Date()
            let remote = missing.isEmpty ? [] : remoteWindows(of: app, looking: missing)
            out += "\(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)\n"
            out += "  ax: " + ax.map { "\($0.windowID.map(String.init) ?? "nil")[\($0.subrole ?? "-") min=\($0.isMinimized)]" }.joined(separator: " ") + "\n"
            out += "  cg: \(cg.sorted())  missing: \(missing.sorted())\n"
            out += "  remote found: " + remote.map { "\($0.1)[\($0.0.subrole ?? "-")]" }.joined(separator: " ")
                + String(format: " (%.2fs)\n", Date().timeIntervalSince(start))
        }
        return out
    }

    /// Normal-level, reasonably sized windows per process, on any desktop.
    private static func candidateWindowIDs() -> [pid_t: Set<CGWindowID>] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var out: [pid_t: Set<CGWindowID>] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 60,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0
            else { continue }
            out[pid, default: []].insert(id)
        }
        return out
    }

    /// Walks the app's AX element numbers until every missing window is found (or a time limit passes).
    private static func remoteWindows(of app: NSRunningApplication, looking missing: Set<CGWindowID>) -> [(AXWindow, CGWindowID)] {
        guard let create = AXPrivate.createWithRemoteToken else { return [] }
        var remaining = missing
        var found: [(AXWindow, CGWindowID)] = []
        let deadline = Date().addingTimeInterval(1.5)
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: app.processIdentifier, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self) // "coco"
        }
        for elementID in UInt64(0)..<0x7fff {
            if remaining.isEmpty || (elementID % 256 == 0 && Date() > deadline) { break }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            let w = AXWindow(element: element, app: app)
            // Any element reports its window's ID; only the window itself is wanted.
            guard let id = w.windowID, remaining.contains(id), w.role == (kAXWindowRole as String) else { continue }
            remaining.remove(id)
            found.append((w, id))
        }
        return found
    }
}

enum AXPrivate {
    typealias CreateFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    static let createWithRemoteToken: CreateFn? = dlsym(handle, "_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: CreateFn.self) }
    static let getWindow: GetWindowFn? = dlsym(handle, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }
}

extension AXWindow {
    var windowID: CGWindowID? {
        guard let fn = AXPrivate.getWindow else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }

    /// All window elements AX lists for the app (visible desktops only), unfiltered.
    static func allElements(of app: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.map { AXWindow(element: $0, app: app) }
    }

    var role: String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    var subrole: String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// A point on the title bar that's safe to drag: just right of the green zoom button, which keeps clear
    /// of tabs in apps like Chrome; otherwise a little in from the top-left corner.
    var grabPoint: CGPoint? {
        guard let frame else { return nil }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &raw) == .success, let raw {
            let button = AXWindow(element: raw as! AXUIElement, app: app)
            if let b = button.frame { return CGPoint(x: b.maxX + 8, y: b.midY) }
        }
        return CGPoint(x: frame.minX + 80, y: frame.minY + 10)
    }
}
