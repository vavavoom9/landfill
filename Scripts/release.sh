#!/bin/sh
# Packages a distributable build: dist/Landfill-<version>.zip, universal (Apple silicon + Intel).
#   usage: Scripts/release.sh
# Optional, for a build that opens without Gatekeeper warnings:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   sign with your Developer ID
#   NOTARY_PROFILE=<name>   notarize, using a profile saved with `xcrun notarytool store-credentials`
set -e
cd "$(dirname "$0")/.."

swift test
./Scripts/bundle.sh --universal

APP=build/Landfill.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/Landfill-$VERSION.zip"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

codesign --verify --deep --strict "$APP"
echo "Packaged $ZIP ($(lipo -archs "$APP/Contents/MacOS/Landfill"))"
shasum -a 256 "$ZIP"
