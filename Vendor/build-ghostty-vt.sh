#!/bin/sh
# Builds libghostty-vt into Vendor/ghostty-vt.xcframework.
#
# Ghostty's own build emits the xcframework (macOS universal + iOS) and ships a
# module.modulemap inside it, so nothing has to be written by hand: the package
# just imports GhosttyVt. Needs zig >= 0.16.0.
set -e
cd "$(dirname "$0")"
REF=${GHOSTTY_REF:-main}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v zig >/dev/null || { echo "zig not found (brew install zig)"; exit 1; }

echo "--- cloning ghostty ($REF)"
git clone --depth 1 --branch "$REF" https://github.com/ghostty-org/ghostty.git "$WORK/ghostty" 2>/dev/null

echo "--- zig build -Demit-lib-vt=true"
( cd "$WORK/ghostty" && zig build -Demit-lib-vt=true --prefix ./zig-out >/dev/null )

rm -rf ghostty-vt.xcframework
cp -R "$WORK/ghostty/zig-out/lib/ghostty-vt.xcframework" .

echo "built Vendor/ghostty-vt.xcframework ($(du -sh ghostty-vt.xcframework | cut -f1))"
