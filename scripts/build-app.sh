#!/bin/bash
# Builds Tasjeel.app into dist/.
#
#   scripts/build-app.sh             build dist/Tasjeel.app
#   scripts/build-app.sh --install   also copy it to /Applications
#
# The app is signed with your Apple Development certificate when you have one,
# so macOS keeps its Screen Recording, Camera and Microphone permissions across
# rebuilds. Without one it is ad-hoc signed and macOS asks again after each
# rebuild. Set TASJEEL_SIGN_IDENTITY to choose a specific identity, or to "-"
# to force ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Tasjeel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tasjeel "$APP/Contents/MacOS/Tasjeel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${TASJEEL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with a developer certificate."
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signed (macOS will ask for permissions again after each rebuild)."
fi

echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Tasjeel.app"
    ditto "$APP" "/Applications/Tasjeel.app"
    echo "Installed /Applications/Tasjeel.app"
fi
