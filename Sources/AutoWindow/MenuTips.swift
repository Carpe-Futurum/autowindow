import AppKit

/// Tooltips for the menu bar menu, set on the native items rather than through SwiftUI's `.help`,
/// found by title: a title changed in `MenuContent` has to change here too.
@MainActor
enum MenuTips {
    private static let tips: [String: String] = [
        "Grant Accessibility Access…":
            "AutoWindow needs Accessibility access to see and move windows.",
        "⚠︎ macOS Rearranges Your Desktops — Turn Off…":
            "macOS reorders desktops by recent use, so a snapshot can land on the wrong desktop. Opens Desktop & Dock settings, where you can turn that off.",
        "Save Snapshot…":
            "Save where every open window is, on all monitors and desktops, under a name you choose.",
        "Restore":
            "Put windows back on their saved monitor, desktop, position and size. Minimized and hidden ones come back too. Hold Esc to stop.",
        "Rename…":
            "Give this snapshot another name.",
        "Delete…":
            "Delete this snapshot. Asks first; your windows stay where they are.",
        "Put Windows Back Now":
            "Move windows back to the positions remembered for these monitors. They stay on the desktop they are on.",
        "Remember Positions Now":
            "Remember where windows are now for these monitors.",
        "Remember Positions as I Work":
            "Keep the remembered positions for these monitors up to date while you work.",
        "Put Windows Back When Monitors Change":
            "When you plug in or unplug a monitor, or wake the Mac, put windows back where they were with those monitors.",
        "Place an App's Windows When It Opens":
            "When an app opens, put its windows at their remembered positions.",
        "Show Layouts & Snapshots…":
            "See and edit saved layouts and snapshots.",
        "Allow Control by autowindow:// Links":
            "Let Shortcuts, Raycast or scripts save and restore snapshots with autowindow:// links. Any app or web page can then do the same.",
        "Launch at Login":
            "Start AutoWindow when you log in.",
        "Show Data Folder":
            "Show the file with your saved layouts in Finder.",
        "Quit AutoWindow":
            "Stop AutoWindow. Saved layouts and snapshots are kept.",
    ]

    static func install() {
        // Opening the menu covers what's there; items SwiftUI adds later (submenus are filled when opened) are caught as they come.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                guard Thread.isMainThread, let menu = note.object as? NSMenu else { return }
                MainActor.assumeIsolated { apply(to: menu) }
            }
        }
    }

    private static func apply(to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                apply(to: submenu) // its title can be a snapshot's name, so it gets no tip of its own
            } else if let tip = tips[item.title], item.toolTip != tip {
                // Setting a tip can post another change; the check above ends that after one round.
                item.toolTip = tip
            }
        }
    }
}
