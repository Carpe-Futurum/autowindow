import AppKit
import AutoWindowCore

/// Named snapshots: every window on every display and desktop, restored the same way.
@MainActor
enum Snapshots {
    /// Captures all windows on all desktops.
    static func capture(name: String, id: String = UUID().uuidString) -> Layout {
        let displays = Displays.current()
        let spaces = Spaces.displays()
        let spaceByDisplay = Dictionary(spaces.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [WindowRecord] = []

        for entry in WindowCatalog.all() {
            guard let frame = entry.window.frame,
                  let display = Geometry.display(for: frame, in: displays) else { continue }
            let windowSpaces = Spaces.spaces(forWindow: entry.id)
            // On no desktop at all: hidden or ordered-out windows, nothing to put back.
            if windowSpaces.isEmpty { continue }
            var spaceIndex: Int?
            if let s = spaceByDisplay[display.uuid] {
                // Full-screen windows live in their own space; leave them to macOS.
                if let first = windowSpaces.first, windowSpaces.count == 1 {
                    guard let i = s.index(of: first) else { continue }
                    spaceIndex = i
                }
            }
            records.append(WindowRecord(
                bundleID: entry.bundleID,
                appName: entry.window.app.localizedName ?? entry.bundleID,
                title: entry.window.title,
                index: entry.index,
                displayUUID: display.uuid,
                relativeFrame: Geometry.relative(frame, to: display),
                windowID: entry.id,
                spaceIndex: spaceIndex
            ))
        }

        var layout = Layout(
            signature: Layout.signature(for: displays),
            name: name,
            displays: displays,
            windows: records
        )
        layout.id = id
        layout.spaceCounts = Dictionary(spaces.map { ($0.uuid, max($0.desktops.count, 1)) }, uniquingKeysWith: { a, _ in a })
        layout.activeSpaces = Dictionary(spaces.compactMap { s in s.currentIndex.map { (s.uuid, $0) } }, uniquingKeysWith: { a, _ in a })
        return layout
    }

    struct Report {
        var placed = 0
        var movedDesktop = 0
        var notFound = 0
        var problems: [String] = []

        var summary: String {
            var parts = ["placed \(placed) windows"]
            if movedDesktop > 0 { parts.append("\(movedDesktop) moved to another desktop") }
            if notFound > 0 { parts.append("\(notFound) not open") }
            return parts.joined(separator: ", ") + (problems.isEmpty ? "" : ". " + problems.joined(separator: " "))
        }
    }

    /// Puts every open window back on its saved display, desktop, position and size, then shows the
    /// desktops that were showing at capture. Windows change desktop by being dragged while the desktop
    /// switches, so the screen visibly flips through desktops while this runs; the pointer is put back after.
    static func restore(_ layout: Layout) async -> Report {
        var report = Report()
        let displays = Dictionary(Displays.current().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let catalog = WindowCatalog.all()
        let live = catalog.map { LiveWindowInfo(bundleID: $0.bundleID, title: $0.window.title, index: $0.index, windowID: $0.id) }
        let pairs = Matcher.match(records: layout.windows, live: live)
        report.notFound = layout.windows.count - pairs.count
        let pointer = CGEvent(source: nil)?.location
        let startSpaces = Spaces.displays()
        let startCurrent = Dictionary(startSpaces.map { ($0.uuid, $0.current) }, uniquingKeysWith: { a, _ in a })

        struct Job { let window: AXWindow; let id: CGWindowID; let target: CGRect; let displayUUID: String; let desktop: Int? }
        var jobs: [Job] = []
        for (liveIndex, record) in pairs {
            guard let display = displays[record.displayUUID] else { continue }
            let entry = catalog[liveIndex]
            jobs.append(Job(window: entry.window, id: entry.id,
                            target: Geometry.absolute(record.relativeFrame, on: display),
                            displayUUID: display.uuid, desktop: record.spaceIndex))
        }

        // Pass 1: position and size. Windows already on the right desktop are done after this.
        for job in jobs { job.window.setFrame(job.target) }
        report.placed = jobs.count

        // Pass 2: windows on the wrong desktop (or display) get dragged across.
        var missingShortcuts = Set<Int>()
        var failedDrags = 0
        for job in jobs.sorted(by: { (Spaces.spaces(forWindow: $0.id).first ?? 0) < (Spaces.spaces(forWindow: $1.id).first ?? 0) }) {
            let spaces = Spaces.displays()
            guard let targetDisplay = spaces.first(where: { $0.uuid == job.displayUUID }), !targetDisplay.desktops.isEmpty else { continue }
            let wanted = min(max(job.desktop ?? targetDisplay.currentIndex ?? 1, 1), targetDisplay.desktops.count)
            let targetSpace = targetDisplay.desktops[wanted - 1]
            let windowSpaces = Spaces.spaces(forWindow: job.id)
            if windowSpaces.contains(targetSpace) || (job.desktop == nil && windowSpaces.contains(where: targetDisplay.desktops.contains)) {
                continue
            }
            switch await SpaceMover.move(job.window, id: job.id, to: job.target,
                                         display: job.displayUUID, desktop: wanted) {
            case .moved: report.movedDesktop += 1
            case .noShortcut(let n): missingShortcuts.insert(n)
            case .failed: failedDrags += 1
            }
        }

        // Show the desktops that were showing at capture; else the ones showing before the restore.
        for display in Spaces.displays() where display.desktops.count > 1 {
            let wanted = layout.activeSpaces?[display.uuid]
                ?? startCurrent[display.uuid].flatMap { display.index(of: $0) }
            if let wanted, display.currentIndex != wanted {
                _ = await SpaceMover.switchTo(display: display.uuid, desktop: wanted)
            }
        }
        if let pointer { CGWarpMouseCursorPosition(pointer) }

        if !missingShortcuts.isEmpty {
            let list = missingShortcuts.sorted().map(String.init).joined(separator: ", ")
            report.problems.append("Turn on \"Switch to Desktop \(list)\" in System Settings → Keyboard → Keyboard Shortcuts → Mission Control to move windows there.")
        }
        if failedDrags > 0 { report.problems.append("\(failedDrags) windows wouldn't move to their desktop.") }
        return report
    }
}

/// Moves a window to another desktop the way a person does: hold its title bar, switch desktop, let go.
@MainActor
enum SpaceMover {
    enum Result { case moved, noShortcut(Int), failed }

    static func move(_ window: AXWindow, id: CGWindowID, to target: CGRect, display uuid: String, desktop: Int) async -> Result {
        // 1. Show the desktop the window is on now, and bring the window to the front.
        if let current = Spaces.spaces(forWindow: id).first,
           let holder = Spaces.displays().first(where: { $0.desktops.contains(current) }),
           holder.current != current, let index = holder.index(of: current) {
            switch await switchTo(display: holder.uuid, desktop: index) {
            case .noShortcut(let n): return .noShortcut(n)
            case .failed: return .failed
            case .moved: break
            }
        }
        window.app.activate()
        window.raise()
        try? await Task.sleep(for: .milliseconds(250))

        guard let frame = window.frame, let grab = window.grabPoint else { return .failed }
        let offset = CGPoint(x: grab.x - frame.minX, y: grab.y - frame.minY)
        let drop = CGPoint(x: target.minX + offset.x, y: target.minY + offset.y)

        // 2. Hold the title bar and carry it to where it belongs (possibly another display).
        post(.mouseMoved, at: grab)
        post(.leftMouseDown, at: grab)
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseDragged, at: CGPoint(x: grab.x + 6, y: grab.y))
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseDragged, at: drop)
        try? await Task.sleep(for: .milliseconds(120))

        // 3. Switch that display to the right desktop while holding, then let go.
        let result = await switchTo(display: uuid, desktop: desktop, holding: drop)
        post(.leftMouseUp, at: drop)
        try? await Task.sleep(for: .milliseconds(200))
        window.setFrame(target)

        EventLog.write("move window \(id) to desktop \(desktop): \(result)")
        guard case .moved = result else { return result }
        let spaces = Spaces.displays().first { $0.uuid == uuid }
        let arrived = spaces.map { Spaces.spaces(forWindow: id).contains($0.desktops[desktop - 1]) } ?? false
        return arrived ? .moved : .failed
    }

    /// Shows desktop `desktop` (1-based) on a display via its Ctrl+N shortcut and waits for the animation.
    static func switchTo(display uuid: String, desktop: Int, holding: CGPoint? = nil) async -> Result {
        let all = Spaces.displays()
        guard let display = all.first(where: { $0.uuid == uuid }), desktop <= display.desktops.count else { return .failed }
        let target = display.desktops[desktop - 1]
        if display.current == target { return .moved }
        guard let number = Spaces.globalNumber(display: uuid, index: desktop, in: all) else { return .failed }
        guard let shortcut = DesktopShortcuts.shortcut(forDesktop: number) else { return .noShortcut(number) }
        EventLog.write("switch display \(uuid.prefix(8)) to desktop \(desktop) (Desktop \(number) shortcut), showing \(display.currentIndex ?? 0)")
        DesktopShortcuts.press(shortcut)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let holding { post(.leftMouseDragged, at: holding) } // keep the drag alive during the switch
            if Spaces.displays().first(where: { $0.uuid == uuid })?.current == target {
                try? await Task.sleep(for: .milliseconds(350)) // let the slide animation finish
                return .moved
            }
        }
        let now = Spaces.displays().map { "\($0.uuid.prefix(8))=\($0.currentIndex ?? 0)" }.joined(separator: " ")
        EventLog.write("  switch timed out; showing \(now)")
        return .failed
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
