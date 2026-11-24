import AppKit
import ApplicationServices

/// Finds every standard window of the running apps on all desktops, with its window ID.
///
/// The Accessibility API only lists an app's windows on the desktops showing right now. Windows on other
/// desktops are found by asking for the app's AX elements by number ("remote token"), the same trick
/// window managers like yabai use; it needs only the Accessibility permission.
///
/// Everything here is safe to call off the main thread, and `all` should be: one app can take a second.
enum WindowCatalog {
    struct Entry: @unchecked Sendable {
        let window: AXWindow
        let id: CGWindowID
        let bundleID: String
        let appName: String
        /// Order among the app's windows: front-to-back on visible desktops first, then the others.
        let index: Int
        let title: String
        let frame: CGRect
        /// Spaces the window is on (several only for "all desktops" windows).
        let spaces: [UInt64]
    }

    static func all(apps: [NSRunningApplication]) -> [Entry] {
        let cgByPID = candidateWindowIDs()
        let visible = Set(Spaces.displays().map(\.current))
        var result: [Entry] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            var seen = Set<CGWindowID>()
            var windows: [(AXWindow, CGWindowID)] = []
            for w in AXWindow.allElements(of: app) {
                guard let id = w.windowID, seen.insert(id).inserted else { continue }
                windows.append((w, id))
            }
            let hidden = offscreenCandidates(cgByPID[app.processIdentifier] ?? [], notIn: seen, visible: visible)
            if !hidden.isEmpty {
                for (w, id) in remoteWindows(of: app, looking: hidden) where seen.insert(id).inserted {
                    windows.append((w, id))
                }
            }
            var index = 0
            for (w, id) in windows {
                // Windows on other desktops often don't answer the subrole question; the window server already
                // vouched for them (normal level, real size), so a readable frame is enough.
                guard !w.isMinimized, let frame = w.frame, w.isStandard || w.subrole == nil else { continue }
                result.append(Entry(window: w, id: id, bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                    index: index, title: w.title, frame: frame, spaces: Spaces.spaces(forWindow: id)))
                index += 1
            }
        }
        return result
    }

    /// Window-server windows AX didn't list that sit on a desktop that isn't showing. Ones on a showing
    /// desktop that AX left out aren't real windows (tab bars, helper surfaces), so they're never searched for.
    private static func offscreenCandidates(_ ids: Set<CGWindowID>, notIn seen: Set<CGWindowID>, visible: Set<UInt64>) -> Set<CGWindowID> {
        ids.subtracting(seen).filter { id in
            guard !isUnfindable(id) else { return false }
            let spaces = Spaces.spaces(forWindow: id)
            return !spaces.isEmpty && visible.isDisjoint(with: spaces)
        }
    }

    /// Per-app breakdown of what AX and the window server report, for autowindow://debug/catalog.
    static func diagnostics(apps: [NSRunningApplication]) -> String {
        let cgByPID = candidateWindowIDs()
        let visible = Set(Spaces.displays().map(\.current))
        var out = ""
        for app in apps {
            let ax = AXWindow.allElements(of: app)
            let axIDs = Set(ax.compactMap(\.windowID))
            let cg = cgByPID[app.processIdentifier] ?? []
            let hidden = offscreenCandidates(cg, notIn: axIDs, visible: visible)
            let start = Date()
            let remote = hidden.isEmpty ? [] : remoteWindows(of: app, looking: hidden)
            out += "\(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)\n"
            out += "  ax: " + ax.map { "\($0.windowID.map(String.init) ?? "nil")[\($0.subrole ?? "-") min=\($0.isMinimized)]" }.joined(separator: " ") + "\n"
            out += "  window server: \(cg.sorted())  on hidden desktops: \(hidden.sorted())\n"
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

    /// Walks the app's AX element numbers until every wanted window is found (or a time limit passes).
    private static func remoteWindows(of app: NSRunningApplication, looking wanted: Set<CGWindowID>) -> [(AXWindow, CGWindowID)] {
        guard let create = AXPrivate.createWithRemoteToken else { return [] }
        var remaining = wanted
        var found: [(AXWindow, CGWindowID)] = []
        let deadline = Date().addingTimeInterval(0.75)
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
        remaining.forEach(noteMiss)
        return found
    }

    // Window IDs that two searches couldn't find: not searched again, so one odd window
    // doesn't cost every later capture its full time limit. IDs aren't reused within a login session.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var misses: [CGWindowID: Int] = [:]

    private static func isUnfindable(_ id: CGWindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (misses[id] ?? 0) >= 2
    }

    private static func noteMiss(_ id: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        misses[id, default: 0] += 1
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

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }

    private func string(_ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
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
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &raw) == .success, let raw,
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let button = AXWindow(element: raw as! AXUIElement, app: app)
            if let b = button.frame, frame.contains(CGPoint(x: b.maxX + 8, y: b.midY)) {
                return CGPoint(x: b.maxX + 8, y: b.midY)
            }
        }
        return CGPoint(x: frame.minX + 80, y: frame.minY + 10)
    }
}
