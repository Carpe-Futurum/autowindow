import Foundation

/// Persists layouts as JSON, keyed by `Layout.storeKey`: the display signature for automatic
/// layouts (layouts.json), the snapshot id for named snapshots (snapshots.json).
public final class LayoutStore {
    public let fileURL: URL
    public private(set) var layouts: [String: Layout] = [:]
    /// Set when the file (or some entries in it) couldn't be read. The original was copied aside first,
    /// so saving over it loses nothing.
    public private(set) var loadProblem: String?

    public init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoWindow", isDirectory: true)
    }

    public static var defaultURL: URL { directory.appendingPathComponent("layouts.json") }
    public static var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }

    public func layout(for key: String) -> Layout? { layouts[key] }

    public func save(_ layout: Layout) {
        layouts[layout.storeKey] = layout
        persist()
    }

    public func remove(key: String) {
        layouts[key] = nil
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Entry by entry, so one bad entry (a hand edit, a newer version's file) doesn't hide the rest.
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            loadProblem = "Couldn't read \(fileURL.lastPathComponent); kept a copy as \(setAside() ?? "?")"
            return
        }
        var unreadable = 0
        for item in items {
            if let one = try? JSONSerialization.data(withJSONObject: item),
               let layout = try? decoder.decode(Layout.self, from: one) {
                layouts[layout.storeKey] = layout
            } else {
                unreadable += 1
            }
        }
        if unreadable > 0 {
            loadProblem = "\(unreadable) entries in \(fileURL.lastPathComponent) couldn't be read; kept a copy as \(setAside() ?? "?")"
        }
    }

    /// Copies the file next to itself under a dated name; returns that name.
    private func setAside() -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = fileURL.deletingPathExtension().lastPathComponent + ".unreadable-\(stamp).json"
        let copy = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        return (try? FileManager.default.copyItem(at: fileURL, to: copy)) != nil ? name : nil
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let list = layouts.values.sorted { $0.name < $1.name }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(list).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AutoWindow: failed to save layouts: \(error)")
        }
    }
}
