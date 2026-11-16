import AppKit
import AutoWindowCore

/// Captures and restores window layouts through the Accessibility API.
enum WindowManager {
    static let ignoredBundleIDs: Set<String> = [
        Bundle.main.bundleIdentifier ?? "nl.carpefuturum.autowindow",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
    ]

    static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleIdentifier.map { !ignoredBundleIDs.contains($0) } == true
        }
    }

    static func capture() -> Layout {
        let displays = Displays.current()
        var records: [WindowRecord] = []
        for app in regularApps() {
            guard let bundleID = app.bundleIdentifier else { continue }
            for (index, window) in AXWindow.windows(of: app).enumerated() {
                guard let frame = window.frame,
                      let display = Geometry.display(for: frame, in: displays) else { continue }
                records.append(WindowRecord(
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    title: window.title,
                    index: index,
                    displayUUID: display.uuid,
                    relativeFrame: Geometry.relative(frame, to: display)
                ))
            }
        }
        return Layout(
            signature: Layout.signature(for: displays),
            name: Layout.defaultName(for: displays),
            displays: displays,
            windows: records
        )
    }

    /// Moves live windows to their saved place. `onlyBundleID` limits it to one app (e.g. just launched).
    @discardableResult
    static func restore(_ layout: Layout, onlyBundleID: String? = nil) -> Int {
        let displays = Dictionary(Displays.current().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let records = layout.windows.filter { onlyBundleID == nil || $0.bundleID == onlyBundleID }
        let wanted = Set(records.map(\.bundleID))

        var live: [(AXWindow, LiveWindowInfo)] = []
        for app in regularApps() {
            guard let bundleID = app.bundleIdentifier, wanted.contains(bundleID) else { continue }
            for (index, window) in AXWindow.windows(of: app).enumerated() {
                live.append((window, LiveWindowInfo(bundleID: bundleID, title: window.title, index: index)))
            }
        }

        var moved = 0
        for (liveIndex, record) in Matcher.match(records: records, live: live.map(\.1)) {
            guard let display = displays[record.displayUUID] else { continue }
            let target = Geometry.absolute(record.relativeFrame, on: display)
            let window = live[liveIndex].0
            if let current = window.frame, current.integral == target.integral { continue }
            window.setFrame(target)
            moved += 1
        }
        return moved
    }
}
