#!/bin/bash
# Build a Release ppaste and install it to /Applications.
# Set CODESIGN_IDENTITY to a stable signing identity so macOS keeps the Accessibility grant across updates.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:--}"
xcodegen generate >/dev/null
xcodebuild -project PPaste.xcodeproj -scheme PPaste -configuration Release \
  -derivedDataPath build build | tail -1

APP="build/Build/Products/Release/PPaste.app"
pkill -f "PPaste.app/Contents/MacOS/PPaste" 2>/dev/null || true
sleep 0.5
rm -rf /Applications/PPaste.app
cp -R "$APP" /Applications/PPaste.app
codesign --force --deep --sign "$IDENTITY" /Applications/PPaste.app
open /Applications/PPaste.app
echo "Installed to /Applications/PPaste.app (signed with: $IDENTITY)"
