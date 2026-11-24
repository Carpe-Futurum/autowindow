# AutoWindow

macOS menu bar app that remembers where your windows go and puts them back.

- Remembers, per set of connected displays, which app's windows sit on which screen, with position and size.
- Restores automatically when displays change (dock/undock, monitor on/off, wake), and when an app launches.
- Keeps the layout up to date every 30 s, so the last arrangement for each desk setup is what comes back.
  Apps that are not running keep their remembered place.
- **Show Saved Layouts… (⌘L)** opens a window with a map of each saved layout: displays in their saved
  arrangement (with wallpaper when connected), every window as a tile with its app icon, plus a table of
  positions and sizes. Rename or forget a layout there.
- Edit a layout in that window: drag windows to move them (across displays too), drag the handles to resize,
  arrow keys nudge, edges snap to displays and other windows (hold ⌘ to stop snapping). The inspector takes exact
  X/Y/W/H and has half/fill/center arrangements. Edits are a draft with undo until **Apply** (displays connected:
  saves and moves the open windows) or **Save** (other display sets).
- **Snapshots** (⌘S in the menu): a named save of every window on every display *and desktop* (Mission
  Control Spaces), with position and size. Restore puts each window back on its display and desktop and shows
  the desktops that were showing. A snapshot is also taken 20 s after AutoWindow starts ("At startup", replaced
  each launch). Several snapshots per display set; ones for other displays are listed separately.
- Scriptable: `open "autowindow://snapshot/save?name=Desk"` and `open "autowindow://snapshot/restore?name=Desk"`
  (no name: newest snapshot for the connected displays). Works from Shortcuts, Raycast, cron.
- Uses the Accessibility API (needs Accessibility permission).

## Build

Requires Xcode 16+ / Swift 6, macOS 14+.

```bash
scripts/build-app.sh            # build/AutoWindow.app
scripts/build-app.sh --install  # also copy to /Applications
scripts/build-app.sh --run      # launch after build
swift test                      # core logic tests
```

Builds are signed with the first "Developer ID Application" identity in the keychain, so the Accessibility
grant survives rebuilds. Without one they're ad-hoc signed, and macOS treats each rebuild as a new app (remove
and re-add AutoWindow in System Settings → Privacy & Security → Accessibility). `CODESIGN_IDENTITY` overrides.

## How it works

| Piece | File |
| --- | --- |
| Display identity (stable UUIDs, top-left global coords) | `Sources/AutoWindow/Displays.swift` |
| AX window read/move | `Sources/AutoWindow/AXWindow.swift` |
| Capture / restore | `Sources/AutoWindow/WindowManager.swift` |
| Events, autosave, settings | `Sources/AutoWindow/AppModel.swift` |
| Saved Layouts window and preview | `Sources/AutoWindow/LayoutsWindow.swift`, `LayoutPreview.swift` |
| Models, matching, geometry, editing/snapping, JSON store | `Sources/AutoWindowCore/` |

- A layout is keyed by the sorted UUIDs of the connected displays.
- Window frames are stored relative to their display, so rearranging displays in System Settings doesn't break a layout.
- Windows are matched to saved records by app bundle ID, then exact title, then window order.
- Autosave is paused for ~12 s after a display change, so the scrambled state macOS leaves isn't saved over the good layout.
- Layouts live in `~/Library/Application Support/AutoWindow/layouts.json`, snapshots in `snapshots.json` next to it.

### Desktops (Spaces)

macOS has no public API to move a window to another desktop, and the private one stopped working in 14.5
unless SIP is off. AutoWindow does what a person does: it holds the window's title bar, presses the
"Switch to Desktop N" shortcut, and lets go. So:

- Turn on **System Settings → Keyboard → Keyboard Shortcuts → Mission Control → Switch to Desktop N** for the
  desktops you use (AutoWindow reads whatever keys you assigned). Without them windows still get the right
  display, position and size, and the restore report says which shortcuts are missing.
- The screen flips through desktops for a few seconds during a restore; the pointer is put back after.
- Desktops aren't created: if a display has fewer desktops than in the snapshot, windows go to its last one.
- Full-screen windows are left alone.
- Reading which desktop a window is on uses SkyLight (private, read-only) and AX "remote tokens" to reach
  windows on desktops not showing; both work with SIP on.

## Not yet

- Per-app exclusions in the UI.
- Creating missing desktops.
