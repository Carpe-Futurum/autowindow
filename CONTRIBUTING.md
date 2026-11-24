# Contributing

Thanks for helping. Bug reports, fixes and small features are all welcome.

## Reporting a bug

Window behaviour depends heavily on the setup, so please include:

- macOS version and Mac model (Apple silicon or Intel)
- how many displays, and how many desktops on each
- whether "Displays have separate Spaces" and "Automatically rearrange Spaces" are on
- which app's window misbehaved, and what you expected
- the last lines of `~/Library/Application Support/AutoWindow/events.log` for restore problems

Check files before attaching them: they can contain window titles.

For security problems, see [SECURITY.md](SECURITY.md) instead of opening an issue.
Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Building

```bash
swift build                       # debug build
swift test                        # core logic tests
scripts/build-app.sh --run        # build/AutoWindow.app, then launch it
```

Without a Developer ID in your keychain the app is ad-hoc signed, and macOS forgets the Accessibility grant on
every rebuild: remove AutoWindow under System Settings → Privacy & Security → Accessibility and add it again.

## Pull requests

- Keep changes focused; one topic per pull request.
- Logic that doesn't need AppKit belongs in `Sources/AutoWindowCore`, with a test.
- Run `swift test`.
- Say how you tested window behaviour: macOS version, displays, desktops. Much of it can't be unit-tested.
- Don't add network code, and don't require turning off System Integrity Protection.

## Testing desktop moves

`autowindow://` links are the easiest way to drive a restore while watching `events.log`. Turn on "Allow
Control by autowindow:// Links" first. To exercise the Ctrl+arrow path instead of the numbered shortcuts:

```bash
defaults write nl.carpefuturum.autowindow arrowShortcutsOnly -bool true   # relaunch; delete the key after
```
