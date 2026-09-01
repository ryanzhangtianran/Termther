#!/bin/sh
# Builds Termther.app.
#
# SwiftPM can only produce a bare executable. A terminal needs to be a real
# bundle: to own a Dock icon, to be launched from Finder, to be told about
# secure input and full-disk access by name, and to carry the resource bundle
# the renderer loads its shaders from.
set -e
cd "$(dirname "$0")/.."

CONFIGURATION=${CONFIGURATION:-release}
APP="build/Termther.app"
VERSION=$(git describe --tags --always 2>/dev/null || echo "0.1.0")

echo "--- building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product termther

BIN=$(swift build -c "$CONFIGURATION" --product termther --show-bin-path)

echo "--- assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/termther" "$APP/Contents/MacOS/Termther"

# The icon. Drawn by Scripts/make-icon.swift; regenerated only when that
# changes, because it is the same picture every time.
[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The renderer loads shaders.metal from here at startup.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Termther</string>
    <key>CFBundleDisplayName</key><string>Termther</string>
    <key>CFBundleIdentifier</key><string>com.tianranzhang.termther</string>
    <key>CFBundleExecutable</key><string>Termther</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- A terminal runs whatever the user runs; it is not a document editor. -->
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Termther runs commands you type.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the app to run locally and to keep the same
# identity across rebuilds, which is what macOS keys permissions off.
echo "--- signing"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "built $APP ($(du -sh "$APP" | cut -f1))"
echo
echo "  open $APP          # run it"
echo "  cp -R $APP /Applications/"
