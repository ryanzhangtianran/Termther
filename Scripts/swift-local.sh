#!/bin/bash
# Runs Swift with the Command Line Tools selected on this host.
#
# Keeping compiler caches in the repository avoids stale modules from another
# CLT release and makes builds work when the user's cache directories are not
# writable. Set DEVELOPER_DIR explicitly to override xcode-select.
set -e
cd "$(dirname "$0")/.."

DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
export DEVELOPER_DIR

case "$DEVELOPER_DIR" in
    */CommandLineTools|*/Xcode.app/Contents/Developer) ;;
    *)
        echo "unsupported developer directory: $DEVELOPER_DIR" >&2
        exit 2
        ;;
esac

SWIFT=$(xcrun --find swift)
SDKROOT=${TERMTHER_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}

# CLT 27.0 ships a macOS 27 SDK whose SwiftUI property wrappers require the
# SwiftUIMacros plugin, but the CLT package itself omits that plugin. The same
# installation retains the macOS 26 SDK, which works with its current Swift
# compiler and still supports Termther's macOS 14 deployment target.
if [ -z "${TERMTHER_SDKROOT:-}" ] \
    && [ ! -f "$DEVELOPER_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
    && [ -d "$DEVELOPER_DIR/SDKs/MacOSX26.sdk" ]; then
    SDKROOT="$DEVELOPER_DIR/SDKs/MacOSX26.sdk"
fi
CACHE_ROOT="$PWD/.build/toolchain-cache"
SWIFTPM_ROOT="$PWD/.build/swiftpm"
mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swift" "$CACHE_ROOT/xdg" \
    "$SWIFTPM_ROOT/cache" "$SWIFTPM_ROOT/config" "$SWIFTPM_ROOT/security"

export SDKROOT
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swift"
export XDG_CACHE_HOME="$CACHE_ROOT/xdg"

# Swift Build in CLT 27 appends two Xcode-only search paths to every target.
# They cannot be overridden by package settings, and ld reports each missing
# directory once per target. Filter only those known diagnostics; all other
# compiler and linker warnings remain visible.
run_swift() {
    set +e
    "$@" 2>&1 \
        | grep -Fv "warning: search path '$DEVELOPER_DIR/Developer/usr/lib' not found" \
        | grep -Fv "warning: search path '$DEVELOPER_DIR/Developer/Library/Frameworks' not found"
    local command_status=${PIPESTATUS[0]}
    set -e
    return "$command_status"
}

# CLT 27 keeps Swift Testing's interop library below Library/Developer, while
# SwiftPM asks the linker to search Developer/usr/lib. Supply the real path for
# both linking and execution of test bundles.
CLT_LIBRARY_PATH="$DEVELOPER_DIR/Library/Developer/usr/lib"
if [ -d "$CLT_LIBRARY_PATH" ]; then
    export LIBRARY_PATH="$CLT_LIBRARY_PATH${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export DYLD_LIBRARY_PATH="$CLT_LIBRARY_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi

case "${1:-}" in
    test)
        COMMAND=$1
        shift
        run_swift "$SWIFT" "$COMMAND" \
            --disable-sandbox \
            --cache-path "$SWIFTPM_ROOT/cache" \
            --config-path "$SWIFTPM_ROOT/config" \
            --security-path "$SWIFTPM_ROOT/security" \
            ${CLT_LIBRARY_PATH:+-Xlinker -L$CLT_LIBRARY_PATH} \
            ${CLT_LIBRARY_PATH:+-Xlinker -rpath -Xlinker $CLT_LIBRARY_PATH} \
            "$@"
        ;;
    build|run|package)
        COMMAND=$1
        shift
        run_swift "$SWIFT" "$COMMAND" \
            --disable-sandbox \
            --cache-path "$SWIFTPM_ROOT/cache" \
            --config-path "$SWIFTPM_ROOT/config" \
            --security-path "$SWIFTPM_ROOT/security" \
            "$@"
        ;;
    *) run_swift "$SWIFT" "$@" ;;
esac
