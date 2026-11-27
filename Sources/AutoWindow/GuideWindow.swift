import AppKit
import SwiftUI

/// The welcome window: what the app does in two sentences, and a setup checklist that shows what's
/// already right and opens the right settings pane for what isn't. Shown on first launch, whenever
/// Accessibility access is missing at launch, and from "How AutoWindow Works…" in the menu.
@MainActor
enum GuideWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: GuideView(model: model)))
            w.title = "Welcome to AutoWindow"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

private struct GuideView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AutoWindow puts your windows back").font(.title2.weight(.semibold))
                    HStack(spacing: 4) {
                        Text("It lives in the menu bar. Look for")
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                card("arrow.triangle.2.circlepath", "Automatic",
                     "Nothing to do. AutoWindow remembers where your windows are for each set of monitors, and puts them back when you plug in, unplug or wake your Mac.")
                card("camera.viewfinder", "Snapshots",
                     "Save your whole setup under a name, desktops included. Click the name in the menu to bring it back.")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Setup").font(.headline)
                // The settings below change outside the app; look again every two seconds while this is open.
                TimelineView(.periodic(from: .now, by: 2)) { _ in checklist }
            }

            HStack {
                Text("Nothing leaves your Mac.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { GuideWindow.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private func card(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var checklist: some View {
        let setup = SetupStatus.current()
        VStack(alignment: .leading, spacing: 10) {
            step(done: model.isTrusted, required: true,
                 title: "Accessibility access",
                 detail: model.isTrusted
                    ? "On. AutoWindow can see and move windows."
                    : "Needed to see and move windows. Turn on AutoWindow in the list that opens.",
                 button: model.isTrusted ? nil : "Grant Access…") { model.requestAccess() }

            if setup.desktops > 1 {
                step(done: !setup.reorders, required: false,
                     title: "Keep desktops in a fixed order",
                     detail: setup.reorders
                        ? "macOS reorders your desktops by recent use, so a snapshot can put windows on the wrong one. Turn off \"Automatically rearrange Spaces based on most recent use\" under Mission Control."
                        : "On. Desktop numbers in a snapshot stay right.",
                     button: setup.reorders ? "Open Desktop & Dock…" : nil) { model.openDesktopSettings() }

                step(done: setup.canSwitch, required: false,
                     title: "Shortcuts to switch desktops",
                     detail: setup.shortcutDetail,
                     button: setup.numbered < setup.desktops ? "Open Keyboard Settings…" : nil) { model.openKeyboardSettings() }
            } else {
                step(done: true, required: false,
                     title: "Desktops",
                     detail: "You use one desktop per monitor, so there's nothing to set up. If you add desktops in Mission Control, open this window again.",
                     button: nil) {}
            }

            Toggle(isOn: $model.launchAtLogin) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start AutoWindow when you log in")
                    Text("So your windows are always remembered.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.leading, 30)
        }
    }

    private func step(done: Bool, required: Bool, title: String, detail: String, button: String?,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle.dashed"))
                .font(.title3)
                .foregroundStyle(done ? Color.green : (required ? Color.orange : Color.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title + (required || done ? "" : " (for snapshots with several desktops)"))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button { Button(button, action: action) }
        }
    }
}

/// What the Mission Control settings look like right now.
struct SetupStatus {
    /// Desktops over all displays.
    var desktops = 1
    var reorders = false
    /// How many of those desktops have their "Switch to Desktop N" shortcut on.
    var numbered = 0
    var arrows = false

    var canSwitch: Bool { arrows || numbered >= desktops }

    var shortcutDetail: String {
        if numbered >= desktops { return "On: \"Switch to Desktop 1–\(desktops)\". Windows move between desktops the fast way." }
        if arrows {
            return "Works with \"Move left/right a space\". For faster restores, also turn on \"Switch to Desktop 1–\(desktops)\" under Keyboard Shortcuts → Mission Control."
        }
        return "AutoWindow moves windows between desktops with your Mission Control shortcuts, and they're off. Turn on \"Switch to Desktop 1–\(desktops)\" under Keyboard Shortcuts → Mission Control."
    }

    static func current() -> SetupStatus {
        let displays = Spaces.displays()
        var status = SetupStatus()
        status.desktops = max(displays.map(\.desktops.count).reduce(0, +), 1)
        status.reorders = Spaces.reordersAutomatically
        status.numbered = (1...status.desktops).filter { DesktopShortcuts.shortcut(forDesktop: $0) != nil }.count
        status.arrows = DesktopShortcuts.previousDesktop != nil && DesktopShortcuts.nextDesktop != nil
        return status
    }
}
