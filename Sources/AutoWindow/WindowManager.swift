import AppKit
import AutoWindowCore

/// Captures and restores the automatic layout through the Accessibility API, across all desktops.
/// Windows keep whatever desktop they're on; only snapshots move windows between desktops.
@MainActor
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

    /// Every standard window on every desktop. The search runs off the main thread (it can take a second or two).
    static func catalog(onlyBundleID: String? = nil, includeOutOfSight: Bool = false) async -> WindowCatalog.Result {
        let apps = regularApps().filter { onlyBundleID == nil || $0.bundleIdentifier == onlyBundleID }
        return await Task.detached(priority: .userInitiated) { WindowCatalog.all(apps: apps, includeOutOfSight: includeOutOfSight) }.value
    }

    /// Records for the given windows. A window on a single desktop gets that desktop's number; full-screen
    /// windows (their own space) and windows on no desktop are left out.
    static func records(for entries: [WindowCatalog.Entry], displays: [DisplaySnapshot], spaces: [Spaces.Display]) -> [WindowRecord] {
        let spaceByDisplay = Dictionary(spaces.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [WindowRecord] = []
        for entry in entries {
            guard let display = Geometry.display(for: entry.frame, in: displays) else { continue }
            var spaceIndex: Int?
            if !spaces.isEmpty {
                if entry.spaces.isEmpty { continue }
                if entry.spaces.count == 1, let s = spaceByDisplay[display.uuid] {
                    guard let i = s.index(of: entry.spaces[0]) else { continue }
                    spaceIndex = i
                }
            }
            records.append(WindowRecord(
                bundleID: entry.bundleID,
                appName: entry.appName,
                title: entry.title,
                index: entry.index,
                displayUUID: display.uuid,
                relativeFrame: Geometry.relative(entry.frame, to: display),
                windowID: entry.id,
                spaceIndex: spaceIndex,
                hidden: entry.window.app.isHidden ? true : nil
            ))
        }
        return records
    }

    /// The layout as it is now, plus the apps that didn't answer (their windows are unknown, not gone).
    static func capture() async -> (layout: Layout, unreachable: Set<String>) {
        let displays = Displays.current()
        let found = await catalog()
        var layout = Layout(
            signature: Layout.signature(for: displays),
            name: Layout.defaultName(for: displays),
            displays: displays,
            windows: records(for: found.entries, displays: displays, spaces: Spaces.displays())
        )
        layout.session = BootSession.current
        return (layout, found.unreachable)
    }

    /// Full-screen windows sit in a space of their own that's on no display's desktop list. They're left alone.
    static func isFullScreen(_ entry: WindowCatalog.Entry, desktops: Set<UInt64>) -> Bool {
        !entry.spaces.isEmpty && !entry.spaces.contains(where: desktops.contains)
    }

    /// Moves open windows to their saved place. `onlyBundleID` limits it to one app (e.g. just launched).
    @discardableResult
    static func restore(_ layout: Layout, onlyBundleID: String? = nil) async -> Int {
        let records = layout.recordsForMatching(session: BootSession.current)
            .filter { onlyBundleID == nil || $0.bundleID == onlyBundleID }
        let entries = await catalog(onlyBundleID: onlyBundleID).entries
        let desktops = Set(Spaces.displays().flatMap(\.desktops))
        let displays = Dictionary(Displays.current().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let live = entries.map { LiveWindowInfo(bundleID: $0.bundleID, title: $0.title, index: $0.index, windowID: $0.id) }

        var moved = 0
        for (liveIndex, record) in Matcher.match(records: records, live: live) {
            guard let display = displays[record.displayUUID] else { continue }
            let target = Geometry.absolute(record.relativeFrame, on: display)
            if isFullScreen(entries[liveIndex], desktops: desktops) { continue }
            let window = entries[liveIndex].window
            if let current = window.frame, current.integral == target.integral { continue }
            window.setFrame(target)
            moved += 1
        }
        return moved
    }
}
