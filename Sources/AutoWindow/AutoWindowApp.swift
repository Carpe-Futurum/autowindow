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
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.isTrusted {
            Button("Grant Accessibility Access…") { model.requestAccess() }
            Divider()
        }

        Text("Displays: \(model.currentName)")
        Text(model.currentLayout.map { "Saved: \($0.windows.count) windows" } ?? "No saved layout for these displays")
        Text(model.lastEvent)

        Divider()

        Button("Save Layout Now") { model.saveNow() }
            .keyboardShortcut("s")
        Button("Restore Layout Now") { model.restoreNow() }
            .keyboardShortcut("r")
            .disabled(model.currentLayout == nil)

        Divider()

        Toggle("Restore When Displays Change", isOn: $model.autoRestore)
        Toggle("Restore Apps When They Launch", isOn: $model.restoreOnAppLaunch)
        Toggle("Keep Layout Updated Automatically", isOn: $model.autoSave)
        Toggle("Launch at Login", isOn: $model.launchAtLogin)

        if !model.layouts.isEmpty {
            Divider()
            Menu("Saved Layouts") {
                ForEach(model.layouts, id: \.signature) { layout in
                    Menu("\(layout.signature == model.currentSignature ? "● " : "")\(layout.name) (\(layout.windows.count))") {
                        Text("Updated \(layout.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        Button("Forget") { model.forget(layout) }
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
