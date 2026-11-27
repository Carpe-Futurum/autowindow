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
        "How AutoWindow Works…":
            "What AutoWindow does, and a checklist of the macOS settings it needs.",
        "Undo Last Restore":
            "Move windows back to where they were before the last restore you asked for.",
        "Update to Current Windows…":
            "Replace this snapshot with the windows as they are now, keeping its name. Asks first.",
        "Open Missing Apps When Restoring":
            "Before restoring a snapshot, open its apps that aren't running, so their windows are placed too.",
        "Ticked apps are never recorded or moved":
            "Tick an app to leave its windows alone: not remembered, not put back, not in new snapshots.",
        "About AutoWindow":
            "Show the version.",
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
        "Edit Layouts & Snapshots…":
            "See and edit saved layouts and snapshots.",
        "Allow Control by autowindow:// Links":
            "Let Shortcuts, Raycast or scripts save and restore snapshots with autowindow:// links. Any app or web page can then do the same.",
        "Launch at Login":
            "Start AutoWindow when you log in.",
        "Show Data Folder":
            "Show the file with your saved layouts in Finder.",
        "Use These Shortcuts Everywhere":
            "Snap the front window with these shortcuts from any app, without opening this menu.",
        "Show This List on the Green Button":
            "Rest the pointer on a window's green button and this list appears beside it. Click a position to snap that window.",
        "Restore":
            "Put the front window back where it was before you first snapped it.",
        "Quit AutoWindow":
            "Stop AutoWindow. Saved layouts and snapshots are kept.",
    ]

    /// Snapshot names: an item titled with one restores it. Kept current by `AppModel`.
    static var snapshotNames: Set<String> = []
    private static let restoreTip =
        "Put windows back on their saved monitor, desktop, position and size. Minimized and hidden ones come back too. Hold Esc to stop."

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
            } else if let tip = tips[item.title] ?? (snapshotNames.contains(item.title) ? restoreTip : nil), item.toolTip != tip {
                // Setting a tip can post another change; the check above ends that after one round.
                item.toolTip = tip
            }
        }
    }
}
