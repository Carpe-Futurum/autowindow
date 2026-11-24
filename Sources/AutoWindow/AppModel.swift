import AppKit
import AutoWindowCore
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isTrusted = AXWindow.isTrusted
    @Published private(set) var currentSignature = ""
    @Published private(set) var currentName = ""
    /// Automatic layouts, one per display set.
    @Published private(set) var layouts: [Layout] = []
    /// Named snapshots, newest first.
    @Published private(set) var snapshots: [Layout] = []
    @Published private(set) var isRestoring = false
    @Published private(set) var lastEvent = "Started"

    @Published var autoRestore: Bool { didSet { defaults.set(autoRestore, forKey: Keys.autoRestore) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Keys.autoSave) } }
    @Published var restoreOnAppLaunch: Bool { didSet { defaults.set(restoreOnAppLaunch, forKey: Keys.restoreOnAppLaunch) } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let store = LayoutStore()
    private let snapshotStore = LayoutStore(fileURL: LayoutStore.snapshotsURL)
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private var urlHandler: URLEventHandler?
    private var autosaveTimer: Timer?
    private var trustTimer: Timer?
    private var pendingDisplayChange: DispatchWorkItem?
    /// No autosave until this time: right after a display change macOS has scrambled
    /// the windows, and saving then would overwrite the good layout.
    private var autosaveSuppressedUntil = Date()

    private enum Keys {
        static let autoRestore = "autoRestore"
        static let autoSave = "autoSave"
        static let restoreOnAppLaunch = "restoreOnAppLaunch"
    }

    static let autosaveInterval: TimeInterval = 30
    static let displaySettleDelay: TimeInterval = 2.5
    /// Wait after launch before the startup snapshot, so apps opened at login have their windows up.
    static let startupSnapshotDelay: TimeInterval = 20
    static let startupSnapshotID = "startup"

    init() {
        defaults.register(defaults: [Keys.autoRestore: true, Keys.autoSave: true, Keys.restoreOnAppLaunch: true])
        autoRestore = defaults.bool(forKey: Keys.autoRestore)
        autoSave = defaults.bool(forKey: Keys.autoSave)
        restoreOnAppLaunch = defaults.bool(forKey: Keys.restoreOnAppLaunch)

        refreshDisplays()
        reloadLayouts()
        observe()

        if !isTrusted {
            AXWindow.requestTrust()
            // Poll until the user grants Accessibility; there's no notification for it.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkTrust() }
            }
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosaveTick() }
        }
        urlHandler = URLEventHandler { [weak self] url in self?.handleURL(url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupSnapshotDelay) { [weak self] in
            Task { @MainActor in self?.saveStartupSnapshot() }
        }
    }

    var currentLayout: Layout? { store.layout(for: currentSignature) }

    // MARK: - Actions

    /// Asks for a name, then saves. Prefilled with the current name, so Return keeps it.
    func saveNow() {
        guard isTrusted else { return requestAccess() }
        refreshDisplays()
        guard let name = Self.promptForName(
            title: "Save Layout",
            message: "Name this layout for \(currentName).",
            initial: currentLayout?.name ?? currentName,
            confirm: "Save"
        ) else { return }
        // Manual save is a full snapshot: it replaces the layout, forgetting apps not running now.
        var fresh = WindowManager.capture()
        fresh.name = name
        store.save(fresh)
        refreshDisplays()
        reloadLayouts()
        lastEvent = "Saved \"\(name)\" (\(fresh.windows.count) windows) at \(Self.time())"
    }

    func rename(_ layout: Layout) {
        guard let name = Self.promptForName(
            title: layout.isSnapshot ? "Rename Snapshot" : "Rename Layout",
            message: "New name for \"\(layout.name)\".",
            initial: layout.name,
            confirm: "Rename"
        ) else { return }
        rename(layout, to: name)
    }

    func rename(_ layout: Layout, to name: String) {
        // Rename the stored copy: `layout` may be older than the latest autosave.
        let target = storeFor(layout)
        guard var stored = target.layout(for: layout.storeKey) else { return }
        stored.name = name
        target.save(stored)
        reloadLayouts()
        lastEvent = "Renamed to \"\(name)\""
    }

    func restoreNow() {
        guard isTrusted else { return requestAccess() }
        guard let layout = currentLayout else {
            lastEvent = "No saved layout for these displays"
            return
        }
        let moved = WindowManager.restore(layout)
        lastEvent = "Restored \(moved) windows at \(Self.time())"
        autosaveSuppressedUntil = Date().addingTimeInterval(5)
    }

    /// Stores window positions edited in the Saved Layouts window. With these displays connected it also
    /// moves the windows there; otherwise the next autosave would capture the live positions over the edits.
    func saveEdits(_ edited: Layout) {
        let target = storeFor(edited)
        guard var stored = target.layout(for: edited.storeKey) else { return }
        stored.windows = edited.windows
        stored.updatedAt = Date()
        target.save(stored)
        reloadLayouts()
        if stored.isSnapshot {
            if stored.signature == currentSignature { restoreSnapshot(stored) } else { lastEvent = "Saved edits to \"\(stored.name)\"" }
            return
        }
        if edited.signature == currentSignature, isTrusted {
            let moved = WindowManager.restore(stored)
            autosaveSuppressedUntil = Date().addingTimeInterval(5)
            lastEvent = "Applied edits to \"\(stored.name)\", moved \(moved) windows"
        } else {
            lastEvent = "Saved edits to \"\(stored.name)\""
        }
    }

    func forget(_ layout: Layout) {
        storeFor(layout).remove(key: layout.storeKey)
        reloadLayouts()
    }

    // MARK: - Snapshots

    /// Asks for a name, then saves every window on every display and desktop as a new snapshot.
    func saveSnapshot() {
        guard isTrusted else { return requestAccess() }
        refreshDisplays()
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        guard let name = Self.promptForName(
            title: "Save Snapshot",
            message: "Saves which windows are on which display and desktop, and where.",
            initial: "\(currentName) – \(stamp)",
            confirm: "Save"
        ) else { return }
        let snapshot = Snapshots.capture(name: name)
        snapshotStore.save(snapshot)
        reloadLayouts()
        lastEvent = "Saved snapshot \"\(name)\": \(snapshot.windows.count) windows"
    }

    /// Puts windows back as the snapshot has them, including desktops. Runs for a few seconds
    /// (the screen flips through desktops), so it's async and ignores a second request meanwhile.
    func restoreSnapshot(_ snapshot: Layout) {
        guard isTrusted else { return requestAccess() }
        guard !isRestoring else { return }
        refreshDisplays()
        guard snapshot.signature == currentSignature else {
            lastEvent = "\"\(snapshot.name)\" is for other displays (\(Layout.defaultName(for: snapshot.displays)))"
            return
        }
        isRestoring = true
        lastEvent = "Restoring \"\(snapshot.name)\"…"
        autosaveSuppressedUntil = .distantFuture
        Task { @MainActor in
            let report = await Snapshots.restore(snapshot)
            isRestoring = false
            autosaveSuppressedUntil = Date().addingTimeInterval(5)
            lastEvent = "Restored \"\(snapshot.name)\": \(report.summary)"
            EventLog.write(lastEvent)
        }
    }

    /// Snapshot taken shortly after AutoWindow starts, replacing the previous startup snapshot.
    private func saveStartupSnapshot() {
        guard isTrusted, !isRestoring else { return }
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let snapshot = Snapshots.capture(name: "At startup (\(stamp))", id: Self.startupSnapshotID)
        guard !snapshot.windows.isEmpty else { return }
        snapshotStore.save(snapshot)
        reloadLayouts()
        lastEvent = "Startup snapshot: \(snapshot.windows.count) windows"
    }

    /// autowindow://snapshot/save?name=Desk  ·  autowindow://snapshot/restore?name=Desk
    /// (no name: restore takes the newest snapshot for these displays). For Shortcuts, Raycast, scripts.
    func handleURL(_ url: URL) {
        if url.scheme == "autowindow", url.host == "debug", url.path == "/catalog" {
            let file = LayoutStore.directory.appendingPathComponent("debug-catalog.txt")
            try? WindowCatalog.diagnostics().write(to: file, atomically: true, encoding: .utf8)
            return
        }
        guard url.scheme == "autowindow", url.host == "snapshot" else { return }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "name" }?.value
        switch url.path {
        case "/save":
            guard isTrusted else { return requestAccess() }
            refreshDisplays()
            let label = name ?? "\(currentName) – \(Date().formatted(date: .abbreviated, time: .shortened))"
            var snapshot = Snapshots.capture(name: label)
            // Saving under an existing name replaces that snapshot.
            if let existing = snapshots.first(where: { $0.name == label }) { snapshot.id = existing.id }
            snapshotStore.save(snapshot)
            reloadLayouts()
            lastEvent = "Saved snapshot \"\(label)\": \(snapshot.windows.count) windows"
        case "/restore":
            refreshDisplays()
            let candidates = snapshots.filter { $0.signature == currentSignature }
            if let snapshot = name.map({ n in candidates.first { $0.name == n } }) ?? candidates.first {
                restoreSnapshot(snapshot)
            } else {
                lastEvent = "No snapshot \(name.map { "\"\($0)\" " } ?? "")for these displays"
            }
        default:
            break
        }
    }

    private func storeFor(_ layout: Layout) -> LayoutStore { layout.isSnapshot ? snapshotStore : store }

    func requestAccess() {
        AXWindow.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func revealLayoutsFile() {
        let url = store.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Events

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        })

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.appLaunched(bundleID) }
        })
        observers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        })
    }

    /// Display changes arrive in bursts; wait for them to settle, then restore.
    private func displaysChanged() {
        autosaveSuppressedUntil = Date().addingTimeInterval(Self.displaySettleDelay + 10)
        pendingDisplayChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.handleSettledDisplays() }
        }
        pendingDisplayChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displaySettleDelay, execute: work)
    }

    private func handleSettledDisplays() {
        refreshDisplays()
        guard autoRestore, isTrusted, !isRestoring, let layout = currentLayout else {
            lastEvent = "Displays changed: \(currentName)"
            return
        }
        let moved = WindowManager.restore(layout)
        lastEvent = "Displays changed, restored \(moved) windows"
        // Some apps re-layout a moment later; a second pass catches stragglers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in
                guard let self, let layout = self.currentLayout else { return }
                WindowManager.restore(layout)
            }
        }
    }

    private func appLaunched(_ bundleID: String?) {
        guard restoreOnAppLaunch, isTrusted, !isRestoring, let bundleID, let layout = currentLayout,
              layout.windows.contains(where: { $0.bundleID == bundleID }) else { return }
        autosaveSuppressedUntil = Date().addingTimeInterval(8)
        // Windows appear after launch; try a few times.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let layout = self?.currentLayout else { return }
                    WindowManager.restore(layout, onlyBundleID: bundleID)
                }
            }
        }
    }

    private func autosaveTick() {
        guard autoSave, isTrusted, Date() >= autosaveSuppressedUntil else { return }
        refreshDisplays()
        let fresh = WindowManager.capture()
        guard !fresh.windows.isEmpty else { return }
        let running = Set(WindowManager.regularApps().compactMap(\.bundleIdentifier))
        let merged = currentLayout.map { $0.merging(fresh, runningBundleIDs: running) } ?? fresh
        guard merged.windows != currentLayout?.windows else { return }
        store.save(merged)
        reloadLayouts()
    }

    private func checkTrust() {
        isTrusted = AXWindow.isTrusted
        if isTrusted {
            trustTimer?.invalidate()
            trustTimer = nil
            lastEvent = "Accessibility access granted"
        }
    }

    // MARK: - Helpers

    private func refreshDisplays() {
        let displays = Displays.current()
        currentSignature = Layout.signature(for: displays)
        currentName = Layout.defaultName(for: displays)
    }

    private func reloadLayouts() {
        snapshots = snapshotStore.layouts.values.sorted { $0.updatedAt > $1.updatedAt }
        layouts = store.layouts.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastEvent = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    /// Modal name prompt. Returns nil on Cancel; an empty entry falls back to `initial`.
    private static func promptForName(title: String, message: String, initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Menu bar apps aren't frontmost; without this the alert opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? initial : name
    }

    private static func time() -> String {
        Date().formatted(date: .omitted, time: .shortened)
    }
}

/// Receives autowindow:// URLs. Apple Event handlers need an NSObject target.
final class URLEventHandler: NSObject {
    private let onURL: @MainActor (URL) -> Void

    init(onURL: @escaping @MainActor (URL) -> Void) {
        self.onURL = onURL
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated { onURL(url) }
    }
}
