#!/bin/sh
# Builds a release binary and wraps it in build/Landfill.app.
#   usage: Scripts/bundle.sh [--universal]
# Signing: ad-hoc by default. Set CODESIGN_IDENTITY to a "Developer ID Application: ..."
# identity to sign for distribution (hardened runtime is turned on in that case).
set -e
cd "$(dirname "$0")/.."

ARCHS=""
[ "$1" = "--universal" ] && ARCHS="--arch arm64 --arch x86_64"
IDENTITY="${CODESIGN_IDENTITY:--}"

# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)/Landfill"
APP=build/Landfill.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Landfill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"
