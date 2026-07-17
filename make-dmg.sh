#!/bin/zsh
# Packages build/MeetWhisper.app into a drag-to-Applications DMG.
# Usage: ./make-dmg.sh [version]   (default: version from Info.plist)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MeetWhisper.app"
[[ -d "$APP" ]] || { echo "Run ./build.sh first"; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
STAGE="build/dmg-stage"
DMG="build/MeetWhisper-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "MeetWhisper" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
