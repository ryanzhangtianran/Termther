#!/bin/sh
# Gives an XCFramework's headers a module-specific directory.
#
# SwiftPM 6.4 copies binary-target headers into one include directory. When
# several XCFrameworks all use Headers/module.modulemap, those copy operations
# collide. A distinct HeadersPath keeps each module map and its headers apart.
set -e

FRAMEWORK=$1
MODULE=$2
[ -d "$FRAMEWORK" ] && [ -n "$MODULE" ] || {
    echo "usage: namespace-xcframework-headers.sh <framework> <module>" >&2
    exit 2
}

PLIST="$FRAMEWORK/Info.plist"
INDEX=0
while HEADERS=$(/usr/libexec/PlistBuddy \
    -c "Print :AvailableLibraries:$INDEX:HeadersPath" "$PLIST" 2>/dev/null); do
    SLICE=$(/usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$INDEX:LibraryIdentifier" "$PLIST")
    ROOT="$FRAMEWORK/$SLICE/Headers"
    TARGET="$ROOT/$MODULE"

    if [ "$HEADERS" != "Headers" ]; then
        /usr/libexec/PlistBuddy \
            -c "Set :AvailableLibraries:$INDEX:HeadersPath Headers" "$PLIST"
    fi

    if [ "$HEADERS" != "Headers" ]; then
        SOURCE="$FRAMEWORK/$SLICE/$HEADERS"
        OLD="$FRAMEWORK/$SLICE/.termther-headers"
        rm -rf "$OLD"
        mv "$SOURCE" "$OLD"
        mkdir -p "$ROOT"
        find "$OLD" -mindepth 1 -maxdepth 1 -exec mv {} "$ROOT/" \;
        rmdir "$OLD"
    fi

    mkdir -p "$TARGET"
    if [ -f "$ROOT/module.modulemap" ]; then
        mv "$ROOT/module.modulemap" "$TARGET/module.modulemap"
    fi

    # An earlier namespaced layout put every header below the module directory.
    # Move them back to the public include root: headers such as Ghostty's use
    # <ghostty/...> imports and therefore require `ghostty` to be at that root.
    find "$TARGET" -mindepth 1 -maxdepth 1 ! -name module.modulemap \
        -exec mv {} "$ROOT/" \;

    # The module map moved one level below the headers it names.
    if [ -f "$TARGET/module.modulemap" ]; then
        sed -E -i '' \
            -e 's/^([[:space:]]*)\((umbrella[[:space:]]+)?header /\1\2header /' \
            -e '/header "\.\.\//! s/header "/header "..\//' \
            "$TARGET/module.modulemap"
    fi
    INDEX=$((INDEX + 1))
done

plutil -lint "$PLIST" >/dev/null
