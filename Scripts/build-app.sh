#!/bin/bash
# Builds Oatmeal.app from the SwiftPM package (no Xcode required).
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Oatmeal"
APP=".build/Oatmeal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oatmeal"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature for personal use. Phase 7 swaps this for Developer ID + notarization.
codesign --force --sign - --entitlements Support/Oatmeal.entitlements "$APP"

echo "Built $APP"
echo "Run with: open $APP"
