import AppKit
import AutoWindowCore
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isTrusted = AXWindow.isTrusted
    @Published private(set) var currentSignature = ""
    @Published private(set) var currentName = ""
    @Published private(set) var layouts: [Layout] = []
    @Published private(set) var lastEvent = "Started"

    @Published var autoRestore: Bool { didSet { defaults.set(autoRestore, forKey: Keys.autoRestore) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Keys.autoSave) } }
    @Published var restoreOnAppLaunch: Bool { didSet { defaults.set(restoreOnAppLaunch, forKey: Keys.restoreOnAppLaunch) } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let store = LayoutStore()
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
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
    }

    var currentLayout: Layout? { store.layout(for: currentSignature) }

    // MARK: - Actions

    func saveNow() {
        guard isTrusted else { return requestAccess() }
        // Manual save is a full snapshot: it replaces the layout, forgetting apps not running now.
        var fresh = WindowManager.capture()
        fresh.name = currentLayout?.name ?? fresh.name
        store.save(fresh)
        refreshDisplays()
        reloadLayouts()
        lastEvent = "Saved \(fresh.windows.count) windows at \(Self.time())"
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

    func forget(_ layout: Layout) {
        store.remove(signature: layout.signature)
        reloadLayouts()
    }

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
        guard autoRestore, isTrusted, let layout = currentLayout else {
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
        guard restoreOnAppLaunch, isTrusted, let bundleID, let layout = currentLayout,
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
        layouts = store.layouts.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastEvent = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    private static func time() -> String {
        Date().formatted(date: .omitted, time: .shortened)
    }
}
