import Foundation

/// Persists layouts as JSON, one per display signature.
public final class LayoutStore {
    public let fileURL: URL
    public private(set) var layouts: [String: Layout] = [:]

    public init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoWindow", isDirectory: true)
            .appendingPathComponent("layouts.json")
    }

    public func layout(for signature: String) -> Layout? { layouts[signature] }

    public func save(_ layout: Layout) {
        layouts[layout.signature] = layout
        persist()
    }

    public func remove(signature: String) {
        layouts[signature] = nil
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([Layout].self, from: data) {
            layouts = Dictionary(list.map { ($0.signature, $0) }, uniquingKeysWith: { $1 })
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
