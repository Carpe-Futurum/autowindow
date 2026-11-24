import Foundation

/// Persists layouts as JSON, keyed by `Layout.storeKey`: the display signature for automatic
/// layouts (layouts.json), the snapshot id for named snapshots (snapshots.json).
public final class LayoutStore {
    public let fileURL: URL
    public private(set) var layouts: [String: Layout] = [:]

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
        if let list = try? decoder.decode([Layout].self, from: data) {
            layouts = Dictionary(list.map { ($0.storeKey, $0) }, uniquingKeysWith: { $1 })
        }
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
