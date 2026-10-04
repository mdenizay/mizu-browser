#!/bin/bash
# Builds the Rust ad blocker, the Swift app, and assembles "dist/Mizu.app".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Mizu.app"

echo "==> adblock (Rust)"
(cd "$ROOT/adblock" && MACOSX_DEPLOYMENT_TARGET=26.0 cargo build --release --locked)

echo "==> app (Swift)"
# Use Xcode when it is installed, even if xcode-select still points at the
# Command Line Tools (switching that needs sudo): SwiftUI's macros only ship
# with Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
(cd "$ROOT/app" && swift build -c release)

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/Mizu" "$APP/Contents/MacOS/"
cp "$ROOT/app/Info.plist" "$APP/Contents/"
cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/app/Resources/"* "$APP/Contents/Resources/"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/"
# With a Developer ID certificate in the keychain, sign for distribution
# (hardened runtime, as notarization requires); otherwise sign ad hoc, which
# runs fine locally but is blocked by Gatekeeper on other Macs.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --entitlements "$ROOT/app/Mizu.entitlements" --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "==> $APP"
