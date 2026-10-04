#!/bin/sh
# Builds libssh2 and OpenSSL into Vendor/libssh2.xcframework.
#
# OpenSSL is built from source rather than borrowed from Homebrew: a package
# manager's build targets whatever macOS it was made on, which makes every link
# emit "built for newer macOS version" for hundreds of object files, and pins
# the result to one architecture. Building it here also removes Homebrew from
# the dependency list entirely.
#
# Takes several minutes the first time; the result is cached in Vendor/openssl.
set -e
cd "$(dirname "$0")"
VERSION=1.11.1
OPENSSL_VERSION=3.6.3
DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
OPENSSL="$PWD/openssl"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$OPENSSL/lib/libcrypto.a" ]; then
    echo "--- building OpenSSL $OPENSSL_VERSION (this takes a few minutes)"
    curl -sSL -o "$WORK/openssl.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
    tar xzf "$WORK/openssl.tar.gz" -C "$WORK"
    ( cd "$WORK/openssl-$OPENSSL_VERSION" && \
      ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
          --prefix="$OPENSSL" \
          -mmacosx-version-min="$DEPLOYMENT_TARGET" >/dev/null && \
      make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1 && \
      make install_sw >/dev/null 2>&1 )
    echo "--- OpenSSL cached in Vendor/openssl"
fi

echo "--- fetching libssh2 $VERSION"
curl -sSL -o "$WORK/src.tar.gz" "https://libssh2.org/download/libssh2-$VERSION.tar.gz"
tar xzf "$WORK/src.tar.gz" -C "$WORK"
SRC="$WORK/libssh2-$VERSION"

echo "--- configuring"
( cd "$SRC" && ./configure \
    --prefix="$WORK/install" \
    --with-crypto=openssl --with-libssl-prefix="$OPENSSL" \
    --disable-shared --enable-static \
    --disable-examples-build --disable-docker-tests --disable-sshd-tests \
    CFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET" >/dev/null )

echo "--- building"
( cd "$SRC" && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )

echo "--- combining libssh2 + libssl + libcrypto"
libtool -static -o "$WORK/libssh2-combined.a" \
    "$WORK/install/lib/libssh2.a" "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" 2>/dev/null

echo "--- headers + modulemap"
mkdir -p "$WORK/Headers"
cp "$WORK/install/include/"*.h "$WORK/Headers/"
cat > "$WORK/Headers/module.modulemap" <<'MM'
module CSSH2 {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    export *
}
MM

echo "--- packaging xcframework"
./make-xcframework.sh libssh2.xcframework "$WORK/libssh2-combined.a" "$WORK/Headers"
./namespace-xcframework-headers.sh libssh2.xcframework CSSH2

echo "built Vendor/libssh2.xcframework ($(du -sh libssh2.xcframework | cut -f1))"
