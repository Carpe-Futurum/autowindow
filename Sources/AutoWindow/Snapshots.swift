import AppKit
import AutoWindowCore

/// Named snapshots: every window on every display and desktop, restored the same way.
@MainActor
enum Snapshots {
    /// Captures all windows on all desktops.
    static func capture(name: String, id: String = UUID().uuidString) async -> Layout {
        let displays = Displays.current()
        let entries = await WindowManager.catalog().entries
        let spaces = Spaces.displays()
        var layout = Layout(
            signature: Layout.signature(for: displays),
            name: name,
            displays: displays,
            windows: WindowManager.records(for: entries, displays: displays, spaces: spaces)
        )
        layout.id = id
        layout.session = BootSession.current
        layout.spaceCounts = Dictionary(spaces.map { ($0.uuid, max($0.desktops.count, 1)) }, uniquingKeysWith: { a, _ in a })
        layout.activeSpaces = Dictionary(spaces.compactMap { s in s.currentIndex.map { (s.uuid, $0) } }, uniquingKeysWith: { a, _ in a })
        return layout
    }

    struct Report {
        var placed = 0
        var movedDesktop = 0
        var notFound = 0
        var fullScreen = 0
        var problems: [String] = []

        var summary: String {
            var parts = ["placed \(placed) windows"]
            if movedDesktop > 0 { parts.append("\(movedDesktop) moved to another desktop") }
            if notFound > 0 { parts.append("\(notFound) not found (closed, minimized or unreachable)") }
            if fullScreen > 0 { parts.append("\(fullScreen) full-screen left alone") }
            return parts.joined(separator: ", ") + (problems.isEmpty ? "" : ". " + problems.joined(separator: " "))
        }
    }

    /// Puts every open window back on its saved display, desktop, position and size, then shows the
    /// desktops that were showing at capture. Windows change desktop by being dragged while the desktop
    /// switches, so the screen visibly flips through desktops while this runs; the pointer is put back after.
    /// Holding Esc stops it after the window being moved.
    static func restore(_ layout: Layout) async -> Report {
        var report = Report()
        SpaceMover.cancelled = false
        let displays = Dictionary(Displays.current().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let catalog = await WindowManager.catalog().entries
        let desktops = Set(Spaces.displays().flatMap(\.desktops))
        let live = catalog.map { LiveWindowInfo(bundleID: $0.bundleID, title: $0.title, index: $0.index, windowID: $0.id) }
        let pairs = Matcher.match(records: layout.recordsForMatching(session: BootSession.current), live: live)
        report.notFound = layout.windows.count - pairs.count
        let pointer = CGEvent(source: nil)?.location
        let startCurrent = Dictionary(Spaces.displays().map { ($0.uuid, $0.current) }, uniquingKeysWith: { a, _ in a })

        struct Job { let window: AXWindow; let id: CGWindowID; let target: CGRect; let display: DisplaySnapshot; let desktop: Int? }
        var jobs: [Job] = []
        for (liveIndex, record) in pairs {
            guard let display = displays[record.displayUUID] else { continue }
            let entry = catalog[liveIndex]
            // Full-screen windows are left alone: no resize, and no drag (their title bar isn't where a click would land).
            if WindowManager.isFullScreen(entry, desktops: desktops) { report.fullScreen += 1; continue }
            jobs.append(Job(window: entry.window, id: entry.id,
                            target: Geometry.absolute(record.relativeFrame, on: display),
                            display: display, desktop: record.spaceIndex))
        }

        // Pass 1: position and size. Windows already on the right desktop are done after this.
        for job in jobs { job.window.setFrame(job.target) }
        report.placed = jobs.count

        // Pass 2: windows on the wrong desktop (or display) get dragged across, grouped by where they are now.
        var missingShortcuts = Set<Int>()
        var failedDrags = 0
        let order = jobs.map { ($0, Spaces.spaces(forWindow: $0.id).first ?? 0) }.sorted { $0.1 < $1.1 }.map(\.0)
        for job in order {
            if SpaceMover.escapeHeld() { SpaceMover.cancelled = true }
            if SpaceMover.cancelled { break }
            guard let targetDisplay = Spaces.displays().first(where: { $0.uuid == job.display.uuid }),
                  !targetDisplay.desktops.isEmpty else { continue }
            let wanted = min(max(job.desktop ?? targetDisplay.currentIndex ?? 1, 1), targetDisplay.desktops.count)
            let targetSpace = targetDisplay.desktops[wanted - 1]
            let windowSpaces = Spaces.spaces(forWindow: job.id)
            if windowSpaces.contains(targetSpace) || (job.desktop == nil && windowSpaces.contains(where: targetDisplay.desktops.contains)) {
                continue
            }
            switch await SpaceMover.move(job.window, id: job.id, to: job.target, display: job.display, desktop: wanted) {
            case .moved: report.movedDesktop += 1
            case .noShortcut(let n): missingShortcuts.insert(n)
            case .failed: failedDrags += 1
            case .cancelled: SpaceMover.cancelled = true
            }
        }

        // Show the desktops that were showing at capture; else the ones showing before the restore.
        if !SpaceMover.cancelled {
            for display in Spaces.displays() where display.desktops.count > 1 {
                let wanted = layout.activeSpaces?[display.uuid]
                    ?? startCurrent[display.uuid].flatMap { display.index(of: $0) }
                if let wanted, wanted <= display.desktops.count, display.currentIndex != wanted {
                    _ = await SpaceMover.switchTo(display: display.uuid, desktop: wanted)
                }
            }
        }
        if let pointer { CGWarpMouseCursorPosition(pointer) }

        if SpaceMover.cancelled { report.problems.append("Stopped with Esc.") }
        if !missingShortcuts.isEmpty {
            let list = missingShortcuts.sorted().map(String.init).joined(separator: ", ")
            report.problems.append("Turn on \"Switch to Desktop \(list)\" or \"Move left/right a space\" in System Settings → Keyboard → Keyboard Shortcuts → Mission Control to move windows there.")
        }
        if failedDrags > 0 { report.problems.append("\(failedDrags) windows wouldn't move to their desktop.") }
        if layout.hasDesktops, Spaces.reordersAutomatically {
            report.problems.append("macOS is set to rearrange desktops automatically, so desktop numbers may have shifted since this was saved.")
        }
        return report
    }
}

/// Moves a window to another desktop the way a person does: hold its title bar, switch desktop, let go.
@MainActor
enum SpaceMover {
    enum Result { case moved, noShortcut(Int), failed, cancelled }

    /// Set when Esc was held during a restore; the restore stops after the current window.
    static var cancelled = false

    static func escapeHeld() -> Bool { CGEventSource.keyState(.combinedSessionState, key: 53) }

    static func move(_ window: AXWindow, id: CGWindowID, to target: CGRect, display: DisplaySnapshot, desktop: Int) async -> Result {
        // 1. Show the desktop the window is on now, and bring the window to the front.
        if let current = Spaces.spaces(forWindow: id).first,
           let holder = Spaces.displays().first(where: { $0.desktops.contains(current) }),
           holder.current != current, let index = holder.index(of: current) {
            let shown = await switchTo(display: holder.uuid, desktop: index)
            guard case .moved = shown else { return shown }
        }
        window.app.activate()
        window.raise()
        try? await Task.sleep(for: .milliseconds(250))

        guard let frame = window.frame, let grab = window.grabPoint else { return .failed }
        let offset = CGPoint(x: grab.x - frame.minX, y: grab.y - frame.minY)
        // Stay off the very top edge of the display: dragging a window there opens Mission Control.
        let drop = CGPoint(x: target.minX + offset.x, y: max(target.minY + offset.y, display.bounds.minY + 12))

        // Only press the mouse if this window really is what's under the grab point. If raising it didn't
        // work (a sheet, a floating panel, a slow app), the press would grab something else.
        guard topWindow(at: grab) == id else {
            EventLog.write("move window \(id): not frontmost at its title bar, left where it is")
            return .failed
        }

        // 2. Hold the title bar and carry it to where it belongs (possibly another display).
        post(.mouseMoved, at: grab)
        post(.leftMouseDown, at: grab)
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseDragged, at: CGPoint(x: grab.x + 6, y: grab.y))
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseDragged, at: drop)
        try? await Task.sleep(for: .milliseconds(120))

        // 3. Switch that display to the right desktop while holding, then let go (always, even on failure).
        let result = await switchTo(display: display.uuid, desktop: desktop, holding: drop)
        post(.leftMouseUp, at: drop)
        try? await Task.sleep(for: .milliseconds(200))
        window.setFrame(target)

        EventLog.write("move window \(id) to desktop \(desktop): \(result)")
        guard case .moved = result else { return result }
        let spaces = Spaces.displays().first { $0.uuid == display.uuid }
        let arrived = spaces.map { desktop <= $0.desktops.count && Spaces.spaces(forWindow: id).contains($0.desktops[desktop - 1]) } ?? false
        return arrived ? .moved : .failed
    }

    /// Shows desktop `desktop` (1-based) on a display. Tries the "Switch to Desktop N" shortcut first; if it's
    /// off, or lands somewhere else (the numbering across displays is Mission Control's, not ours), steps there
    /// with "Move left/right a space", which acts on the display under the pointer.
    static func switchTo(display uuid: String, desktop: Int, holding: CGPoint? = nil) async -> Result {
        let all = Spaces.displays()
        guard let display = all.first(where: { $0.uuid == uuid }), (1...max(display.desktops.count, 1)).contains(desktop),
              desktop <= display.desktops.count else { return .failed }
        let target = display.desktops[desktop - 1]
        if display.current == target { return .moved }

        let number = Spaces.globalNumber(display: uuid, index: desktop, in: all)
        if let number, let shortcut = DesktopShortcuts.shortcut(forDesktop: number) {
            EventLog.write("switch display \(uuid.prefix(8)) to desktop \(desktop) (Desktop \(number) shortcut), showing \(display.currentIndex ?? 0)")
            DesktopShortcuts.press(shortcut)
            switch await wait(holding: holding, timeout: 2, until: { showing(uuid) == target }) {
            case .met: return .moved
            case .cancelled: return .cancelled
            case .timedOut: EventLog.write("  didn't get there with the number shortcut; stepping with arrows")
            }
        }

        // Step there one desktop at a time.
        guard let previous = DesktopShortcuts.previousDesktop, let next = DesktopShortcuts.nextDesktop else {
            return number.map { .noShortcut($0) } ?? .failed
        }
        if holding == nil, let bounds = Displays.current().first(where: { $0.uuid == uuid })?.bounds {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            CGWarpMouseCursorPosition(center)
            post(.mouseMoved, at: center)
            try? await Task.sleep(for: .milliseconds(80))
        }
        for _ in 0...display.desktops.count {
            guard let now = Spaces.displays().first(where: { $0.uuid == uuid }), let index = now.currentIndex else { return .failed }
            if index == desktop { return .moved }
            EventLog.write("step display \(uuid.prefix(8)) from desktop \(index) toward \(desktop)")
            DesktopShortcuts.press(index < desktop ? next : previous)
            switch await wait(holding: holding, timeout: 1.5, until: { showing(uuid) != now.current }) {
            case .met: continue
            case .cancelled: return .cancelled
            case .timedOut:
                EventLog.write("  step timed out")
                return number.flatMap { DesktopShortcuts.shortcut(forDesktop: $0) == nil ? .noShortcut($0) : nil } ?? .failed
            }
        }
        return .failed
    }

    /// The frontmost ordinary or floating window at a point (menu bar, Dock and screen overlays are ignored).
    private static func topWindow(at point: CGPoint) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list { // front to back
            guard let layer = w[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.contains(point) else { continue }
            return w[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    private static func showing(_ uuid: String) -> UInt64? {
        Spaces.displays().first { $0.uuid == uuid }?.current
    }

    private enum Wait { case met, timedOut, cancelled }

    /// Polls `condition`, keeping a drag alive at `holding`; ends early if Esc is held.
    private static func wait(holding: CGPoint?, timeout: TimeInterval, until condition: () -> Bool) async -> Wait {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if escapeHeld() { cancelled = true; return .cancelled }
            if let holding { post(.leftMouseDragged, at: holding) }
            if condition() {
                try? await Task.sleep(for: .milliseconds(350)) // let the slide animation finish
                return .met
            }
        }
        return .timedOut
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
