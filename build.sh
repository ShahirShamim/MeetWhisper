#!/bin/zsh
# Builds MeetWhisper.app from the SwiftPM executable (Command Line Tools only, no Xcode needed).
# Usage: ./build.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

# Build database (SQLite) fails on this volume's mount options; keep build
# products on the boot disk instead.
SCRATCH="$HOME/.cache/meet-to-text/build"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"

BIN="$SCRATCH/$CONFIG/MeetWhisper"
APP="build/MeetWhisper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MeetWhisper"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for local use; TCC grants may re-prompt after rebuilds.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:  open $APP"
