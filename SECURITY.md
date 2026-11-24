# Security policy

AutoWindow holds the macOS Accessibility permission, moves other apps' windows and sends synthetic mouse and
keyboard events. Reports of ways to misuse that are welcome.

## Reporting a vulnerability

Please report privately, not in a public issue:

- Use **Security → Report a vulnerability** on the
  [GitHub repository](https://github.com/Carpe-Futurum/autowindow/security/advisories/new).

Include the macOS version, the AutoWindow version, and steps to reproduce. You can expect a first reply within
a week. Please allow time for a fix before publishing details.

## Supported versions

Only the latest release gets fixes.

## What to know about the design

- **No network code.** Nothing is sent anywhere.
- **Links.** `autowindow://` links are ignored unless you turn on "Allow Control by autowindow:// Links". That
  keeps web pages and stray links out. It does not protect against software already running under your macOS
  account: such software can change the setting, and can edit the layout files, which are plain JSON.
- **Synthetic input.** During a snapshot restore AutoWindow presses the mouse on a window's title bar and
  presses your Mission Control shortcuts. It only presses a shortcut made of Control, Option or Command plus a
  digit, arrow or function key, and only presses the mouse after checking the intended window is frontmost at
  that point.
- **Private macOS functions.** Reading desktops uses undocumented, read-only functions. They work with System
  Integrity Protection on; AutoWindow never asks you to turn it off.
