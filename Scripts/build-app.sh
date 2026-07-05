#!/bin/bash
# Builds Oatmeal.app from the SwiftPM package (no Xcode required).
# Usage: Scripts/build-app.sh [debug|release]
#
# Optional environment: SWIFT, SDKROOT, OATMEAL_SIGNING_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
if [ "$#" -gt 1 ] || { [ "$CONFIG" != "debug" ] && [ "$CONFIG" != "release" ]; }; then
    echo "Usage: bash Scripts/build-app.sh [debug|release]" >&2
    exit 2
fi
SWIFT="${SWIFT:-swift}"
SWIFT_VERSION="$("$SWIFT" --version)"
echo "Using: $SWIFT"
echo "$SWIFT_VERSION"

# Use the selected developer SDK unless explicitly overridden.
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"

"$SWIFT" build -c "$CONFIG"

BIN="$("$SWIFT" build -c "$CONFIG" --show-bin-path)/Oatmeal"
APP=".build/Oatmeal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oatmeal"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/Oatmeal.icns ]; then
    cp Support/Oatmeal.icns "$APP/Contents/Resources/Oatmeal.icns"
fi

# Signing is explicit; never select a certificate from a developer's setup.
SIGN_ID="${OATMEAL_SIGNING_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ]; then
    echo "NOTE: ad-hoc signing; rebuilding may require granting capture permissions again."
    echo "      See docs/signing.md for an explicit signing identity."
fi
codesign --force --sign "$SIGN_ID" --entitlements Support/Oatmeal.entitlements "$APP"
echo "Signed with: $SIGN_ID"

# Register the generated bundle with LaunchServices.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo "Built $APP ($SWIFT_VERSION)"
echo "Run with: open $APP"
