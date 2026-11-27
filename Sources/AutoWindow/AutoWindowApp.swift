import AutoWindowCore
import SwiftUI

@main
struct AutoWindowApp: App {
    @StateObject private var model = AppModel()

    init() { MenuTips.install() }

    var body: some Scene {
        MenuBarExtra("AutoWindow", systemImage: "macwindow.on.rectangle") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Layouts & Snapshots", id: "layouts") {
            LayoutsWindow(model: model)
        }
        .defaultSize(width: 1320, height: 900)
    }
}

private let snapGroups: [[SnapAction]] = [
    [.left, .right, .top, .bottom],
    [.topLeft, .topRight, .bottomLeft, .bottomRight],
    [.leftThird, .centerThird, .rightThird],
    [.leftTwoThirds, .centerTwoThirds, .rightTwoThirds],
    [.nextDisplay, .previousDisplay],
    [.maximize, .center, .restore],
]

private func snapshotDetail(_ s: AutoWindowCore.Layout) -> String {
    let desktops = (s.spaceCounts ?? [:]).values.reduce(0, +)
    return "\(s.windows.count) windows · \(desktops) desktops · \(s.updatedAt.formatted(date: .abbreviated, time: .shortened))"
}

/// The menu is what you do every day, top to bottom: restore a snapshot with one click, save one,
/// put windows back. Switches you set once sit under Settings; renaming and deleting under Manage Snapshots.
/// A title changed here has to change in `MenuTips` too.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.isTrusted {
            Button("Grant Accessibility Access…") { model.requestAccess() }
            Divider()
        }

        Text(model.lastEvent)
        if model.undoState != nil {
            Button("Undo Last Restore") { model.undoLastRestore() }
                .keyboardShortcut("z")
                .disabled(model.isRestoring)
        }
        if model.desktopsReorder {
            Button("⚠︎ macOS Rearranges Your Desktops — Turn Off…") { model.openDesktopSettings() }
        }

        Menu("Snap Front Window") {
            if model.magnetRunning && model.snapShortcuts {
                Button("Magnet Uses the Same Shortcuts — Quit Magnet") { model.quitMagnet() }
                Divider()
            }
            ForEach(snapGroups, id: \.self) { group in
                ForEach(group, id: \.self) { action in
                    let s = Snapper.shortcut(for: action)
                    Button(action.title) { model.snap(action) }
                        .keyboardShortcut(s.key, modifiers: s.command ? [.control, .option, .command] : [.control, .option])
                }
                Divider()
            }
            Toggle("Use These Shortcuts Everywhere", isOn: $model.snapShortcuts)
            Toggle("Show This List on the Green Button", isOn: $model.greenButtonPanel)
        }

        let here = model.snapshots.filter { $0.signature == model.currentSignature }
        Section("Snapshots — click one to restore it") {
            ForEach(Array(here.enumerated()), id: \.element.storeKey) { index, snapshot in
                if index < 9 {
                    Button(snapshot.name) { model.restoreSnapshot(snapshot) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(model.isRestoring)
                } else {
                    Button(snapshot.name) { model.restoreSnapshot(snapshot) }
                        .disabled(model.isRestoring)
                }
            }
            if here.isEmpty {
                Text(model.snapshots.isEmpty ? "None yet: arrange your windows, then save one" : "None for these monitors yet")
            }
            Button("Save Snapshot…") { model.saveSnapshot() }
                .keyboardShortcut("s")
            if !model.snapshots.isEmpty {
                Menu("Manage Snapshots") {
                    ForEach(model.snapshots, id: \.storeKey) { snapshot in
                        let isHere = snapshot.signature == model.currentSignature
                        Menu(isHere ? snapshot.name : "\(snapshot.name) (other monitors)") {
                            Text(snapshotDetail(snapshot))
                            if !isHere { Text("For \(AutoWindowCore.Layout.defaultName(for: snapshot.displays))") }
                            Divider()
                            if isHere {
                                Button("Update to Current Windows…") { model.updateSnapshot(snapshot) }
                                    .disabled(model.isRestoring)
                            }
                            Button("Rename…") { model.rename(snapshot) }
                            Button("Delete…") { model.confirmForget(snapshot) }
                        }
                    }
                }
            }
        }

        Section("Automatic — for these monitors") {
            Text(automaticStatus)
            Button("Put Windows Back Now") { model.restoreNow() }
                .keyboardShortcut("r")
                .disabled(model.currentLayout == nil || model.isRestoring)
            if !model.autoSave {
                Button("Remember Positions Now") { model.saveNow() }
            }
        }

        Divider()
        Button("Edit Layouts & Snapshots…") {
            openWindow(id: "layouts")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("l")
        Menu("Settings") {
            Section("Automatic") {
                Toggle("Remember Positions as I Work", isOn: $model.autoSave)
                Toggle("Put Windows Back When Monitors Change", isOn: $model.autoRestore)
                Toggle("Place an App's Windows When It Opens", isOn: $model.restoreOnAppLaunch)
            }
            Section("Snapshots") {
                Toggle("Open Missing Apps When Restoring", isOn: $model.launchMissingApps)
                Toggle("Allow Control by autowindow:// Links", isOn: $model.allowLinks)
            }
            Divider()
            Menu(model.ignoredApps.isEmpty ? "Ignored Apps" : "Ignored Apps (\(model.ignoredApps.count))") {
                Text("Ticked apps are never recorded or moved")
                ForEach(model.appChoices) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { model.ignoredApps.contains(app.id) },
                        set: { model.setIgnored(app.id, $0) }
                    ))
                }
            }
            Toggle("Launch at Login", isOn: $model.launchAtLogin)
            Button("Show Data Folder") { model.revealLayoutsFile() }
        }
        Button("How AutoWindow Works…") { model.showGuide() }
        Button("About AutoWindow") { model.showAbout() }

        Divider()
        Button("Quit AutoWindow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var automaticStatus: String {
        guard let layout = model.currentLayout else {
            return model.autoSave ? "Nothing remembered yet for \(model.currentName)" : "Nothing remembered for \(model.currentName)"
        }
        let time = layout.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(layout.windows.count) windows remembered · updated \(time)"
    }
}
