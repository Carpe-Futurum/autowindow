# AutoWindow

**A macOS menu bar app that remembers where your windows go, on every monitor and every desktop, and puts them back.**

Plug in your monitors and your windows return to where they were. Save a named snapshot of your whole setup
(which window is on which monitor, on which Mission Control desktop, at which position and size) and bring it
back with one click.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![Test](https://github.com/Carpe-Futurum/autowindow/actions/workflows/test.yml/badge.svg)](https://github.com/Carpe-Futurum/autowindow/actions/workflows/test.yml)

## Features

- **Automatic layouts per monitor setup.** AutoWindow remembers the window arrangement for each set of
  connected displays (laptop only, laptop + one monitor, the full desk…). When displays change (dock or
  undock, monitor on or off, wake from sleep) it puts every window back. When an app launches, its windows go
  to their remembered place. The layout updates itself every 30 seconds and covers windows on every desktop
  (they keep the desktop they're on; only snapshots move windows between desktops).
- **Snapshots with desktops (Spaces).** Press ⌘S in the menu to save a named snapshot of every window on every
  display *and* every desktop. Restoring moves each window back to its display, desktop, position and size,
  and shows the desktops that were showing when you saved. A snapshot is also taken shortly after AutoWindow
  starts.
- **Visual editor.** The Layouts & Snapshots window (⌘L) draws each layout as a map of your displays with every
  window on it.
  - Drag windows to move them (across displays too) and drag the handles to resize.
  - Edges snap to displays and other windows; hold ⌘ while dragging to stop snapping.
  - Arrow keys nudge the selected window.
  - Type exact positions and sizes, or use left/right/top/bottom half, fill and center.
  - Edits are a draft with undo until you Apply or Save.
- **Scriptable.** Save and restore snapshots from Shortcuts, Raycast, a cron job or the terminal:

  ```bash
  open "autowindow://snapshot/save?name=Desk"
  open "autowindow://snapshot/restore?name=Desk"
  ```

  Links are **off by default**, because any app or web page can open one; turn on **Allow Control by
  autowindow:// Links** in the menu to use them. Without a name, restore picks the newest snapshot for the
  connected displays; with a name used several times, the newest of those. A link always saves a new snapshot
  and never replaces or deletes one.

## Install

There are no prebuilt releases yet; build it from source (about a minute).

Requirements: macOS 14 Sonoma or later, Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/Carpe-Futurum/autowindow.git
cd autowindow
scripts/build-app.sh --install --run
```

This builds `AutoWindow.app`, copies it to `/Applications` and starts it. A window icon appears in the menu bar.
Turn on **Launch at Login** in its menu to keep it running.

## Setup

### 1. Accessibility permission (required)

AutoWindow moves windows through the macOS Accessibility API. On first launch it asks for access:
**System Settings → Privacy & Security → Accessibility → AutoWindow**. The menu shows a "Grant Accessibility
Access…" item until it's on.

### 2. Stop macOS from rearranging desktops (for snapshots with several desktops)

Turn **off** **System Settings → Desktop & Dock → Mission Control → Automatically rearrange Spaces based on
most recent use**. It's on by default, and while it's on macOS reorders your desktops, so "desktop 3" in a
snapshot can be a different desktop a day later. AutoWindow shows a warning in its menu while it's on.

### 3. Desktop shortcuts (for snapshots with several desktops)

AutoWindow switches desktops with your Mission Control keyboard shortcuts (**System Settings → Keyboard →
Keyboard Shortcuts… → Mission Control**), whatever keys you assigned:

- **Switch to Desktop 1, 2, 3…** (off by default): fastest. Turn them on for the desktops you use.
- **Move left / right a space** (Ctrl+← / Ctrl+→, on by default): used when a "Switch to Desktop N" shortcut is
  off or doesn't land on the expected desktop. Slower, one desktop per step.

With both kinds off, windows still get the right display, position and size, and the restore message says
which shortcuts are missing.

### Signing and rebuilds

`scripts/build-app.sh` signs with the first "Developer ID Application" identity in your keychain, if you have
one, with the hardened runtime; set `CODESIGN_IDENTITY` to use a different one. Without one the app is ad-hoc signed, and macOS treats
every rebuild as a new app. In that case remove AutoWindow from the Accessibility list and add it again after
each rebuild.

## Using it

| Menu item | What it does |
| --- | --- |
| Save Snapshot… (⌘S) | Name and save every window on every display and desktop |
| *snapshot name* → Restore | Put every window back as saved (the screen flips through desktops briefly) |
| Update Automatic Layout… | Save the automatic layout for these displays now, with a name |
| Restore Automatic Layout (⌘R) | Put windows back to the automatic layout |
| Show Layouts & Snapshots… (⌘L) | Open the visual editor |
| *snapshot or layout* → Delete… / Forget… | Delete it, after a confirmation |
| Restore When Displays Change | Restore automatically on dock/undock, monitor changes and wake |
| Restore Apps When They Launch | Place an app's windows when it starts |
| Keep Layout Updated Automatically | Update the automatic layout every 30 s |
| Allow Control by autowindow:// Links | Let links save and restore snapshots (off by default) |

## How desktops (Spaces) work

macOS has no public API to move a window to another desktop. The private one window managers used stopped
working in macOS 14.5 unless System Integrity Protection is turned off, and AutoWindow does not ask you to do
that. Instead it does what you would do by hand: it holds the window's title bar, presses the "Switch to
Desktop N" shortcut, and lets go. The pointer is put back afterwards.

Limitations:

- The screen visibly flips through desktops for a few seconds during a restore. Don't use the mouse meanwhile.
  **Hold Esc** to stop: the window being moved is released and the rest are left where they are.
- Only open windows are placed. AutoWindow doesn't launch apps or reopen windows; a restore reports how many
  saved windows weren't open.
- "Displays have separate Spaces" turned off, and Stage Manager, are untested.
- AutoWindow doesn't create desktops. If a display now has fewer desktops than in the snapshot, those windows
  go to its last desktop.
- Full-screen windows are left alone.
- Reading which desktop a window is on uses private, read-only macOS functions (SkyLight and Accessibility
  "remote tokens"). They work with SIP on, but a future macOS update could change them.

## Privacy

AutoWindow has no network code. It stores window positions, app names and window titles locally in
`~/Library/Application Support/AutoWindow/`:

| File | Contents |
| --- | --- |
| `layouts.json` | Automatic layouts, one per set of displays |
| `snapshots.json` | Named snapshots |
| `events.log` | Restore steps, for troubleshooting (starts over at 256 KB) |

Nothing leaves your Mac.

## How it works

| Piece | File |
| --- | --- |
| Display identity (stable UUIDs, top-left global coordinates) | `Sources/AutoWindow/Displays.swift` |
| Accessibility window read/move | `Sources/AutoWindow/AXWindow.swift` |
| All windows on all desktops, with window IDs | `Sources/AutoWindow/WindowCatalog.swift` |
| Desktops (Spaces) and desktop shortcuts | `Sources/AutoWindow/Spaces.swift` |
| Snapshot capture and restore, moving windows between desktops | `Sources/AutoWindow/Snapshots.swift` |
| Automatic layout capture and restore | `Sources/AutoWindow/WindowManager.swift` |
| Events, autosave, settings, `autowindow://` links | `Sources/AutoWindow/AppModel.swift` |
| Layouts & Snapshots window and editor | `Sources/AutoWindow/LayoutsWindow.swift`, `LayoutPreview.swift` |
| Models, matching, geometry, editing and snapping, JSON store (no AppKit; unit-tested) | `Sources/AutoWindowCore/` |

- An automatic layout is keyed by the sorted UUIDs of the connected displays.
- Window frames are stored relative to their display, so rearranging displays in System Settings doesn't
  break a layout.
- Saved windows are matched to open ones by window ID (while the app keeps running), then by exact title,
  then by window order within the app.
- Autosave pauses for about 12 s after a display change, so the scrambled state macOS leaves behind isn't saved
  over the good layout.
- With links allowed, `autowindow://debug/catalog` writes `debug-catalog.txt` next to the layouts: what the Accessibility API and
  the window server report per app.

## Development

```bash
swift build                     # debug build
swift test                      # core logic tests (AutoWindowCore)
scripts/build-app.sh            # build/AutoWindow.app
scripts/build-app.sh --run      # build and launch
scripts/build-app.sh --install  # also copy to /Applications
scripts/release.sh              # universal, signed, notarized zip in dist/ (needs a Developer ID and notary credentials)
```

It's a plain Swift package with no Xcode project; `scripts/build-app.sh` wraps the binary into an app bundle.

## Roadmap

- Prebuilt, notarized releases
- A screenshot in this README
- Per-app exclusions in the UI
- Creating missing desktops

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request, and describe how
you tested window behaviour: on which macOS version, and with how many displays and desktops.

## License

[MIT](LICENSE) © 2026 Carpe Futurum BV
