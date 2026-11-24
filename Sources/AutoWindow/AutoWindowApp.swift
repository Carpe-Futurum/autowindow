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

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.isTrusted {
            Button("Grant Accessibility Access…") { model.requestAccess() }
            Divider()
        }

        Text("Displays: \(model.currentName)")
        Text(model.currentLayout.map { "Layout: \($0.name) (\($0.windows.count) windows)" } ?? "No saved layout for these displays")
        Text(model.lastEvent)
        if model.desktopsReorder {
            Button("⚠︎ macOS Rearranges Your Desktops — Turn Off…") { model.openDesktopSettings() }
        }

        Divider()

        Button("Save Snapshot…") { model.saveSnapshot() }
            .keyboardShortcut("s")
        let here = model.snapshots.filter { $0.signature == model.currentSignature }
        let elsewhere = model.snapshots.filter { $0.signature != model.currentSignature }
        if model.snapshots.isEmpty {
            Text("No snapshots yet")
        } else {
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
                Menu("Other Displays") {
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

        Divider()

        Button("Update Automatic Layout…") { model.saveNow() }
        Button("Restore Automatic Layout") { model.restoreNow() }
            .keyboardShortcut("r")
            .disabled(model.currentLayout == nil)

        Divider()

        Toggle("Restore When Displays Change", isOn: $model.autoRestore)
        Toggle("Restore Apps When They Launch", isOn: $model.restoreOnAppLaunch)
        Toggle("Keep Layout Updated Automatically", isOn: $model.autoSave)
        Toggle("Allow Control by autowindow:// Links", isOn: $model.allowLinks)
        Toggle("Launch at Login", isOn: $model.launchAtLogin)

        if !model.layouts.isEmpty || !model.snapshots.isEmpty {
            Divider()
            Button("Show Layouts & Snapshots…") {
                openWindow(id: "layouts")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("l")
            Menu("Automatic Layouts") {
                ForEach(model.layouts, id: \.signature) { layout in
                    Menu("\(layout.signature == model.currentSignature ? "● " : "")\(layout.name) (\(layout.windows.count))") {
                        Text("Updated \(layout.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        Button("Rename…") { model.rename(layout) }
                        Button("Forget…") { model.confirmForget(layout) }
                    }
                }
            }
        }

        Divider()
        Button("Show Layouts File") { model.revealLayoutsFile() }
        Button("Quit AutoWindow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
