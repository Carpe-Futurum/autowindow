# AutoWindow

macOS menu bar app that remembers where your windows go and puts them back.

- Remembers, per set of connected displays, which app's windows sit on which screen, with position and size.
- Restores automatically when displays change (dock/undock, monitor on/off, wake), and when an app launches.
- Keeps the layout up to date every 30 s, so the last arrangement for each desk setup is what comes back.
  Apps that are not running keep their remembered place.
- Uses the Accessibility API (needs Accessibility permission).

## Build

Requires Xcode 16+ / Swift 6, macOS 14+.

```bash
scripts/build-app.sh            # build/AutoWindow.app
scripts/build-app.sh --install  # also copy to /Applications
scripts/build-app.sh --run      # launch after build
swift test                      # core logic tests
```

Builds are ad-hoc signed by default, so macOS treats each rebuild as a new app and the Accessibility
grant must be renewed (remove and re-add AutoWindow in System Settings → Privacy & Security → Accessibility).
Set `CODESIGN_IDENTITY` to a Developer ID or Apple Development identity to keep the grant across builds.

## How it works

| Piece | File |
| --- | --- |
| Display identity (stable UUIDs, top-left global coords) | `Sources/AutoWindow/Displays.swift` |
| AX window read/move | `Sources/AutoWindow/AXWindow.swift` |
| Capture / restore | `Sources/AutoWindow/WindowManager.swift` |
| Events, autosave, settings | `Sources/AutoWindow/AppModel.swift` |
| Models, matching, geometry, JSON store | `Sources/AutoWindowCore/` |

- A layout is keyed by the sorted UUIDs of the connected displays.
- Window frames are stored relative to their display, so rearranging displays in System Settings doesn't break a layout.
- Windows are matched to saved records by app bundle ID, then exact title, then window order.
- Autosave is paused for ~12 s after a display change, so the scrambled state macOS leaves isn't saved over the good layout.
- Layouts live in `~/Library/Application Support/AutoWindow/layouts.json`.

## Not yet

- Spaces / full-screen windows (no public API for moving windows between Spaces).
- Named, manually switchable layouts per display set.
- Per-app exclusions in the UI.
