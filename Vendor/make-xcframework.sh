#!/bin/sh
# Packages a static library and its headers as an .xcframework.
#
#     make-xcframework.sh <output.xcframework> <library.a> <headers-directory>
#
# This is what `xcodebuild -create-xcframework` does, and it is the only thing
# in the build that needed full Xcode: `xcodebuild` does not ship with the
# Command Line Tools. An .xcframework is a directory with a plist in it, the
# format is published, and writing it here means a clone can be built with the
# Command Line Tools, Go and Zig -- nothing else.
set -e

OUT=$1
LIB=$2
HEADERS=$3
[ -n "$OUT" ] && [ -f "$LIB" ] && [ -d "$HEADERS" ] || {
    echo "usage: make-xcframework.sh <output.xcframework> <library.a> <headers>" >&2
    exit 2
}

# The identifier is platform and architectures, joined the way Xcode joins
# them: macos-arm64, or macos-arm64_x86_64 for a universal library. Read from
# the library rather than assumed, so a universal build is labelled honestly.
ARCHS=$(lipo -archs "$LIB")
IDENTIFIER="macos-$(echo "$ARCHS" | tr ' ' '_')"
NAME=$(basename "$LIB")

rm -rf "$OUT"
mkdir -p "$OUT/$IDENTIFIER"
cp "$LIB" "$OUT/$IDENTIFIER/$NAME"
cp -R "$HEADERS" "$OUT/$IDENTIFIER/Headers"

{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '\t<key>AvailableLibraries</key>\n\t<array>\n\t\t<dict>\n'
    printf '\t\t\t<key>BinaryPath</key><string>%s</string>\n' "$NAME"
    printf '\t\t\t<key>HeadersPath</key><string>Headers</string>\n'
    printf '\t\t\t<key>LibraryIdentifier</key><string>%s</string>\n' "$IDENTIFIER"
    printf '\t\t\t<key>LibraryPath</key><string>%s</string>\n' "$NAME"
    printf '\t\t\t<key>SupportedArchitectures</key>\n\t\t\t<array>\n'
    for arch in $ARCHS; do
        printf '\t\t\t\t<string>%s</string>\n' "$arch"
    done
    printf '\t\t\t</array>\n'
    printf '\t\t\t<key>SupportedPlatform</key><string>macos</string>\n'
    printf '\t\t</dict>\n\t</array>\n'
    printf '\t<key>CFBundlePackageType</key><string>XFWK</string>\n'
    printf '\t<key>XCFrameworkFormatVersion</key><string>1.0</string>\n'
    printf '</dict>\n</plist>\n'
} > "$OUT/Info.plist"

# A malformed plist here fails at link time with a message about a missing
# module, which points nowhere near the cause.
plutil -lint "$OUT/Info.plist" >/dev/null
