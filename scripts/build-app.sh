#!/bin/bash
# Builds AutoWindow.app into ./build. Usage: scripts/build-app.sh [--install] [--run]
#   --install  copy to /Applications (stable path keeps the Accessibility grant and Launch at Login working)
#   --run      launch the built app afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP=build/AutoWindow.app
# Sign with a real identity so macOS keeps the Accessibility grant across rebuilds (ad-hoc "-" loses it every time).
# Default: the first "Developer ID Application" identity in the keychain; override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"

swift build -c "$CONFIG" --product AutoWindow
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AutoWindow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoWindow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier nl.carpefuturum.autowindow "$APP"
echo "Built $APP (signed: $IDENTITY)"

TARGET="$APP"
for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x AutoWindow 2>/dev/null || true
      rm -rf /Applications/AutoWindow.app
      cp -R "$APP" /Applications/
      TARGET=/Applications/AutoWindow.app
      echo "Installed $TARGET" ;;
  esac
done
for arg in "$@"; do
  [ "$arg" = "--run" ] && { pkill -x AutoWindow 2>/dev/null || true; open "$TARGET"; }
done
exit 0
