#!/bin/sh
# Builds the EasyConnect shim into Vendor/ecshim.xcframework.
#
# The engine in ../easierconnect (AGPL-3.0, like this project) implements the
# Sangfor protocol in
# Go. `go build -buildmode=c-archive` turns it into a static library Swift can
# link, so the VPN runs in-process: no TUN device, no root, no helper process.
set -e
cd "$(dirname "$0")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v go >/dev/null || { echo "go not found (brew install go)"; exit 1; }

# Must match the package's platform floor, or every object file draws a
# "built for newer macOS version" warning at link time.
DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}

echo "--- go build -buildmode=c-archive (macOS $DEPLOYMENT_TARGET)"
( cd ecshim && MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    CGO_CFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET" \
    CGO_LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET" \
    go build -buildmode=c-archive -o "$WORK/libecshim.a" . )

echo "--- headers + modulemap"
mkdir -p "$WORK/Headers"
cp "$WORK/libecshim.h" "$WORK/Headers/"
cat > "$WORK/Headers/module.modulemap" <<'MM'
module CECShim {
    header "libecshim.h"
    export *
}
MM

echo "--- packaging xcframework"
./make-xcframework.sh ecshim.xcframework "$WORK/libecshim.a" "$WORK/Headers"

echo "built Vendor/ecshim.xcframework ($(du -sh ecshim.xcframework | cut -f1))"
