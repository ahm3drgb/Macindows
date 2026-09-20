#!/bin/bash
set -e

APPNAME="Macindows"
BUNDLE="$APPNAME.app"

echo "Building $APPNAME..."

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

swiftc -framework Cocoa -framework ApplicationServices -framework ServiceManagement -framework ScreenCaptureKit -framework SwiftUI -framework Carbon \
    AppDelegate.swift \
    SettingsView.swift \
    main.swift \
    -o "$BUNDLE/Contents/MacOS/$APPNAME"

cp Info.plist "$BUNDLE/Contents/"
cp AppIcon.icns "$BUNDLE/Contents/Resources/" 2>/dev/null || true

# Sign with a stable identity so Accessibility / Input Monitoring grants survive rebuilds.
# Ad-hoc ("-") signing changes the app identity every build and macOS drops the grants.
SIGN_ID="${SIGN_ID:-Apple Development}"
codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"

echo "Done! Run with: open $BUNDLE"
