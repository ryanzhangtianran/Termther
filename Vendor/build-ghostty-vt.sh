#!/bin/sh
# Builds libghostty-vt into Vendor/ghostty-vt.xcframework.
#
# Ghostty builds the static library and public headers. Its xcframework step
# calls xcodebuild, which is intentionally not a dependency of this project, so
# make-xcframework.sh packages the native library instead. Needs zig >= 0.16.0.
set -e
cd "$(dirname "$0")"
REF=${GHOSTTY_REF:-main}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v zig >/dev/null || { echo "zig not found (brew install zig)"; exit 1; }

echo "--- cloning ghostty ($REF)"
git clone --depth 1 --branch "$REF" https://github.com/ghostty-org/ghostty.git "$WORK/ghostty" 2>/dev/null

echo "--- zig build -Demit-lib-vt=true -Demit-xcframework=false"
( cd "$WORK/ghostty" && \
  zig build -Demit-lib-vt=true -Demit-xcframework=false \
      --prefix ./zig-out >/dev/null )

echo "--- headers + modulemap"
mkdir -p "$WORK/Headers"
cp -R "$WORK/ghostty/zig-out/include/ghostty" "$WORK/Headers/"
cat > "$WORK/Headers/module.modulemap" <<'MM'
module GhosttyVt {
    umbrella header "ghostty/vt.h"
    export *
}
MM

echo "--- packaging xcframework"
./make-xcframework.sh ghostty-vt.xcframework \
    "$WORK/ghostty/zig-out/lib/libghostty-vt.a" "$WORK/Headers"
./namespace-xcframework-headers.sh ghostty-vt.xcframework GhosttyVt

echo "built Vendor/ghostty-vt.xcframework ($(du -sh ghostty-vt.xcframework | cut -f1))"
