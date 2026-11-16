#!/bin/bash
# Builds AutoWindow.app into ./build. Usage: scripts/build-app.sh [--install] [--run]
#   --install  copy to /Applications (stable path keeps the Accessibility grant and Launch at Login working)
#   --run      launch the built app afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP=build/AutoWindow.app
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc; set to a Developer ID to keep the AX grant across rebuilds

swift build -c "$CONFIG" --product AutoWindow
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AutoWindow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoWindow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier nl.carpefuturum.autowindow "$APP"
echo "Built $APP"

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
