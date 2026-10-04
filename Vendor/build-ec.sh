#!/bin/sh
# Builds the EasyConnect engine (EC, Rust) into Vendor/ec.xcframework.
#
# The same crate is the termther-ec SOCKS5 proxy on Linux; here it is linked
# as a static library behind the C ABI in EC/include/termther_ec.h.
set -e
cd "$(dirname "$0")"
DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "--- building EC"
MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET \
    cargo build --release --lib --target aarch64-apple-darwin --manifest-path ../EC/Cargo.toml
LIB=../EC/target/aarch64-apple-darwin/release/libtermther_ec.a

echo "--- headers + modulemap"
mkdir -p "$WORK/Headers"
cp ../EC/include/termther_ec.h "$WORK/Headers/"
cat > "$WORK/Headers/module.modulemap" <<'MM'
module CEC {
    header "termther_ec.h"
    export *
}
MM

echo "--- packaging xcframework"
./make-xcframework.sh ec.xcframework "$LIB" "$WORK/Headers"
./namespace-xcframework-headers.sh ec.xcframework CEC

echo "built Vendor/ec.xcframework ($(du -sh ec.xcframework | cut -f1))"
