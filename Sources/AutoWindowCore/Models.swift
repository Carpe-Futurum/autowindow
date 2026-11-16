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

    public init(bundleID: String, appName: String, title: String, index: Int, displayUUID: String, relativeFrame: CGRect) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.index = index
        self.displayUUID = displayUUID
        self.relativeFrame = relativeFrame
    }
}

/// All window placements for one particular set of connected displays.
public struct Layout: Codable, Hashable, Sendable {
    /// Key derived from the set of connected display UUIDs.
    public var signature: String
    public var name: String
    public var displays: [DisplaySnapshot]
    public var windows: [WindowRecord]
    public var updatedAt: Date

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
        result.windows = kept + fresh.windows
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
