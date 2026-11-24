import AppKit
import AutoWindowCore

enum Displays {
    /// Currently active displays, in global top-left coordinates (matches AX).
    static func current() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let names: [CGDirectDisplayID: String] = Dictionary(
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { ($0.uint32Value, screen.localizedName) }
            },
            uniquingKeysWith: { a, _ in a }
        )

        return ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay } // skip mirror targets
            .map { id in
                DisplaySnapshot(
                    uuid: uuidString(for: id),
                    name: names[id] ?? "Display \(id)",
                    bounds: CGDisplayBounds(id),
                    isMain: CGDisplayIsMain(id) != 0
                )
            }
    }

    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { uuidString(for: $0.uint32Value) == uuid } == true
        }
    }

    private static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "id-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
