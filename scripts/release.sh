#!/bin/bash
# Builds a downloadable AutoWindow: universal, Developer ID signed, notarized, stapled, zipped into ./dist.
# Usage: scripts/release.sh [--skip-notarize]
#
# Notarization credentials, one of:
#   NOTARY_PROFILE=<name>   a profile saved with `xcrun notarytool store-credentials <name>`
#   NOTARY_KEY=<AuthKey.p8> NOTARY_KEY_ID=<id> [NOTARY_ISSUER=<uuid>]   an App Store Connect API key
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain (set CODESIGN_IDENTITY)." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=dist/AutoWindow.app
ZIP="dist/AutoWindow-$VERSION.zip"

swift build -c release --arch arm64 --arch x86_64 --product AutoWindow
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AutoWindow"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoWindow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Hardened runtime and a secure timestamp are both required for notarization.
codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier nl.carpefuturum.autowindow "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/AutoWindow"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${1:-}" = "--skip-notarize" ]; then
  echo "Built $ZIP (signed: $IDENTITY, NOT notarized: Gatekeeper will block it on other Macs)"
  exit 0
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ]; then
  AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
  [ -n "${NOTARY_ISSUER:-}" ] && AUTH+=(--issuer "$NOTARY_ISSUER")
else
  echo "Set NOTARY_PROFILE, or NOTARY_KEY and NOTARY_KEY_ID (see the top of this script)." >&2
  exit 1
fi

xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait
xcrun stapler staple "$APP"
# Zip again so the download carries the stapled ticket and opens offline.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Built $ZIP (signed: $IDENTITY, notarized and stapled)"
