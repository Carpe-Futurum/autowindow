/// A window that exists right now, as seen by whatever enumerates windows.
public struct LiveWindowInfo: Hashable, Sendable {
    public var bundleID: String
    public var title: String
    public var index: Int
    public var windowID: UInt32?

    public init(bundleID: String, title: String, index: Int, windowID: UInt32? = nil) {
        self.bundleID = bundleID
        self.title = title
        self.index = index
        self.windowID = windowID
    }
}

public enum Matcher {
    /// Pairs saved records with live windows of the same app.
    /// Pass 0: same window ID (the app hasn't restarted). Pass 1: exact title. Pass 2: leftovers by capture order.
    /// Returns (index into `live`, record) pairs.
    public static func match(records: [WindowRecord], live: [LiveWindowInfo]) -> [(Int, WindowRecord)] {
        var result: [(Int, WindowRecord)] = []
        let byApp = Dictionary(grouping: records, by: \.bundleID)

        for (bundleID, appRecords) in byApp {
            var pendingRecords = appRecords.sorted { $0.index < $1.index }
            var pendingLive = live.indices
                .filter { live[$0].bundleID == bundleID }
                .sorted { live[$0].index < live[$1].index }

            for record in pendingRecords {
                guard let id = record.windowID,
                      let pos = pendingLive.firstIndex(where: { live[$0].windowID == id }) else { continue }
                result.append((pendingLive.remove(at: pos), record))
                pendingRecords.removeAll { $0 == record }
            }
            for record in pendingRecords where !record.title.isEmpty {
                if let pos = pendingLive.firstIndex(where: { live[$0].title == record.title }) {
                    result.append((pendingLive.remove(at: pos), record))
                    pendingRecords.removeAll { $0 == record }
                }
            }
            for (liveIdx, record) in zip(pendingLive, pendingRecords) {
                result.append((liveIdx, record))
            }
        }
        return result
    }
}
