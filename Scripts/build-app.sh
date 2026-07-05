#!/bin/bash
# Builds Oatmeal.app from the SwiftPM package (no Xcode required).
# Usage: Scripts/build-app.sh [debug|release]
#
# Prefers a Swift 6.3+ toolchain if one is installed under
# ~/Library/Developer/Toolchains. This matters: the Command Line Tools' Swift
# 6.2.x compiler miscompiles main-actor executor hops (OptimizeHopToExecutor
# regression), which crashes SwiftUI button taps on macOS 26. Swift 6.3 fixes it.
# See docs/crash-macos26-executor.md.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"

# Find a Swift 6.3+ toolchain; fall back to the system swift.
SWIFT="swift"
for tc in "$HOME/Library/Developer/Toolchains"/swift-6.3*.xctoolchain \
          /Library/Developer/Toolchains/swift-6.3*.xctoolchain; do
    if [ -x "$tc/usr/bin/swift" ]; then
        SWIFT="$tc/usr/bin/swift"
        break
    fi
done

SWIFT_VERSION="$("$SWIFT" --version 2>/dev/null | head -1)"
echo "Using: $SWIFT"
echo "       $SWIFT_VERSION"
case "$SWIFT_VERSION" in
    *"version 6.2"*|*"version 6.1"*|*"version 6.0"*|*"version 5"*)
        echo "WARNING: Swift < 6.3 detected. SwiftUI button taps may crash on macOS 26."
        echo "         Install a 6.3+ toolchain from https://swift.org/download/" ;;
esac

# Standalone toolchains need the SDK path pointed at the Command Line Tools SDK.
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"

"$SWIFT" build -c "$CONFIG"

BIN=".build/$CONFIG/Oatmeal"
APP=".build/Oatmeal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oatmeal"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable self-signed identity if one is installed, so macOS keeps the
# Screen Recording / Microphone grant across rebuilds. Ad-hoc signatures change
# their cdhash on every build, which makes macOS forget the TCC grant. Phase 7
# swaps this for Developer ID + notarization.
SIGN_ID="-"
for candidate in "Oatmeal Dev" "LocalFlow Dev"; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
        SIGN_ID="$candidate"
        break
    fi
done
if [ "$SIGN_ID" = "-" ]; then
    echo "NOTE: signing ad-hoc. The Screen Recording grant will reset on each rebuild."
    echo "      Create a stable identity (see docs/signing.md) to make it stick."
fi
codesign --force --sign "$SIGN_ID" --entitlements Support/Oatmeal.entitlements "$APP"
echo "Signed with: $SIGN_ID"

# Register with LaunchServices so macOS treats it as a real app (reduces
# startup framework thrash for an ad-hoc bundle run from a build directory).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo "Built $APP ($SWIFT_VERSION)"
echo "Run with: open $APP"
