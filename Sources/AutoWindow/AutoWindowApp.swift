import AutoWindowCore
import SwiftUI

@main
struct AutoWindowApp: App {
    @StateObject private var model = AppModel()

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

private func snapshotDetail(_ s: AutoWindowCore.Layout) -> String {
    let desktops = (s.spaceCounts ?? [:]).values.reduce(0, +)
    return "\(s.windows.count) windows · \(desktops) desktops · \(s.updatedAt.formatted(date: .abbreviated, time: .shortened))"
}

/// The menu has two labelled groups, because the app does two different things:
/// snapshots (saved by the user, by name, with desktops) and the automatic layout
/// (kept by the app per monitor setup, never moves windows between desktops).
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.isTrusted {
            Button("Grant Accessibility Access…") { model.requestAccess() }
            Divider()
        }

        Text(model.lastEvent)
        if model.desktopsReorder {
            Button("⚠︎ macOS Rearranges Your Desktops — Turn Off…") { model.openDesktopSettings() }
        }

        Section("Snapshots — saved by you, desktops included") {
            Button("Save Snapshot…") { model.saveSnapshot() }
                .keyboardShortcut("s")
            let here = model.snapshots.filter { $0.signature == model.currentSignature }
            let elsewhere = model.snapshots.filter { $0.signature != model.currentSignature }
            if model.snapshots.isEmpty {
                Text("No snapshots yet")
            }
            ForEach(here, id: \.storeKey) { snapshot in
                Menu(snapshot.name) {
                    Button("Restore") { model.restoreSnapshot(snapshot) }
                        .disabled(model.isRestoring)
                    Text(snapshotDetail(snapshot))
                    Divider()
                    Button("Rename…") { model.rename(snapshot) }
                    Button("Delete…") { model.confirmForget(snapshot) }
                }
            }
            if !elsewhere.isEmpty {
                Menu("For Other Monitors") {
                    ForEach(elsewhere, id: \.storeKey) { snapshot in
                        Menu(snapshot.name) {
                            Text(AutoWindowCore.Layout.defaultName(for: snapshot.displays))
                            Text(snapshotDetail(snapshot))
                            Divider()
                            Button("Rename…") { model.rename(snapshot) }
                            Button("Delete…") { model.confirmForget(snapshot) }
                        }
                    }
                }
            }
        }

        Section("Automatic — for these monitors, no desktops") {
            Text(automaticStatus)
            Button("Put Windows Back Now") { model.restoreNow() }
                .keyboardShortcut("r")
                .disabled(model.currentLayout == nil || model.isRestoring)
            if !model.autoSave {
                Button("Remember Positions Now") { model.saveNow() }
            }
            Toggle("Remember Positions as I Work", isOn: $model.autoSave)
            Toggle("Put Windows Back When Monitors Change", isOn: $model.autoRestore)
            Toggle("Place an App's Windows When It Opens", isOn: $model.restoreOnAppLaunch)
        }

        Divider()
        Button("Show Layouts & Snapshots…") {
            openWindow(id: "layouts")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("l")

        Divider()
        Toggle("Allow Control by autowindow:// Links", isOn: $model.allowLinks)
        Toggle("Launch at Login", isOn: $model.launchAtLogin)
        Button("Show Data Folder") { model.revealLayoutsFile() }
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
