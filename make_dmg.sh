#!/bin/bash
# Build Macindows.app and package it as a drag-to-Applications DMG.
#
#   ./make_dmg.sh                       # signs with "Apple Development" (local testing only)
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make_dmg.sh
#   NOTARY_PROFILE=macindows ./make_dmg.sh   # also notarize + staple (needs Developer ID)
#
# Buyers' Macs only open the app without warnings when it is signed with a
# Developer ID certificate AND notarized. "Apple Development" works on this
# machine only.
set -e

APPNAME="Macindows"
BUNDLE="$APPNAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="$APPNAME-$VERSION.dmg"
STAGING="$(mktemp -d)/dmg"

./build.sh

mkdir -p "$STAGING"
cp -R "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$APPNAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

# Sign the DMG itself with the same identity
SIGN_ID="${SIGN_ID:-Apple Development}"
codesign --force --sign "$SIGN_ID" "$DMG"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "Notarizing…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Done: $DMG"
