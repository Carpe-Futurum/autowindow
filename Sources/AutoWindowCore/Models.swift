import CoreGraphics
import Foundation

/// A physical display, identified by its stable UUID (survives reboots and reconnects).
/// `bounds` are in global top-left-origin coordinates, the same space the Accessibility API uses.
public struct DisplaySnapshot: Codable, Hashable, Sendable {
    public var uuid: String
    public var name: String
    public var bounds: CGRect
    public var isMain: Bool

    public init(uuid: String, name: String, bounds: CGRect, isMain: Bool) {
        self.uuid = uuid
        self.name = name
        self.bounds = bounds
        self.isMain = isMain
    }
}

/// One window's remembered placement. The frame is stored relative to its display's
/// origin so a layout still works when macOS rearranges displays in global space.
public struct WindowRecord: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    /// Order of this window among the app's standard windows at capture time.
    public var index: Int
    public var displayUUID: String
    public var relativeFrame: CGRect
    /// CGWindowID at capture. Stays the same while the app keeps running, so it's the best match key.
    public var windowID: UInt32?
    /// Mission Control desktop on its display, 1-based. Nil when not captured (autosave doesn't track desktops).
    public var spaceIndex: Int?

    public init(bundleID: String, appName: String, title: String, index: Int, displayUUID: String, relativeFrame: CGRect,
                windowID: UInt32? = nil, spaceIndex: Int? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.index = index
        self.displayUUID = displayUUID
        self.relativeFrame = relativeFrame
        self.windowID = windowID
        self.spaceIndex = spaceIndex
    }
}

/// All window placements for one particular set of connected displays.
/// Two kinds: the automatic layout per display set (`id` nil, kept up to date by autosave) and
/// named snapshots (`id` set, only changed when the user saves or edits them, include desktops).
public struct Layout: Codable, Hashable, Sendable {
    /// Key derived from the set of connected display UUIDs.
    public var signature: String
    public var name: String
    public var displays: [DisplaySnapshot]
    public var windows: [WindowRecord]
    public var updatedAt: Date
    /// Set for named snapshots.
    public var id: String?
    /// Desktops per display UUID at capture (snapshots only).
    public var spaceCounts: [String: Int]?
    /// Desktop that was showing on each display UUID at capture, 1-based (snapshots only).
    public var activeSpaces: [String: Int]?
    /// Boot session the window IDs belong to (`BootSession.current` at capture). Window IDs start over at
    /// every restart, so they only identify a window within the same session.
    public var session: Int?

    /// The records to match against open windows: window IDs are dropped unless they're from this session.
    public func recordsForMatching(session current: Int) -> [WindowRecord] {
        guard session != current else { return windows }
        return windows.map { var r = $0; r.windowID = nil; return r }
    }

    public var isSnapshot: Bool { id != nil }
    public var storeKey: String { id ?? signature }

    /// Number of desktops a display had at capture (1 if unknown).
    public func spaceCount(forDisplay uuid: String) -> Int { spaceCounts?[uuid] ?? 1 }
    public var hasDesktops: Bool { (spaceCounts ?? [:]).values.contains { $0 > 1 } }

    public init(signature: String, name: String, displays: [DisplaySnapshot], windows: [WindowRecord], updatedAt: Date = Date()) {
        self.signature = signature
        self.name = name
        self.displays = displays
        self.windows = windows
        self.updatedAt = updatedAt
    }

    /// Updates this layout with a fresh capture. Apps in `fresh` replace their old records;
    /// apps not running now keep their remembered windows, so quitting an app doesn't forget it.
    public func merging(_ fresh: Layout, runningBundleIDs: Set<String>) -> Layout {
        let kept = windows.filter { !runningBundleIDs.contains($0.bundleID) }
        var result = fresh
        result.name = name
        // Kept records carry IDs from an older capture; they're from apps not running, so the IDs are dead anyway.
        result.windows = kept.map { var r = $0; r.windowID = nil; return r } + fresh.windows
        return result
    }

    public static func signature(for displays: [DisplaySnapshot]) -> String {
        displays.map(\.uuid).sorted().joined(separator: "+")
    }

    public static func defaultName(for displays: [DisplaySnapshot]) -> String {
        let names = displays.sorted { $0.isMain && !$1.isMain }.map(\.name)
        return names.isEmpty ? "No displays" : names.joined(separator: " + ")
    }
}

/// Identifies the current boot: the kernel's boot time in seconds.
public enum BootSession {
    public static let current: Int = {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 ? Int(time.tv_sec) : 0
    }()
}
