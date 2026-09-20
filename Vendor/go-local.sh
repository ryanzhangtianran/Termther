#!/bin/sh
# Runs Go for one of the vendored modules without touching caches in $HOME.
#
#     ./go-local.sh ecshim mod download
#     ./go-local.sh easierconnect test ./...
set -e
cd "$(dirname "$0")"

MODULE=$1
shift || true
case "$MODULE" in
    ecshim|easierconnect) ;;
    *)
        echo "usage: go-local.sh <ecshim|easierconnect> <go arguments...>" >&2
        exit 2
        ;;
esac

ROOT="$PWD/.go"
mkdir -p "$ROOT/pkg/mod" "$ROOT/build-cache" "$ROOT/tmp"

export GOPATH="$ROOT"
export GOMODCACHE="$ROOT/pkg/mod"
export GOCACHE="$ROOT/build-cache"
export GOTMPDIR="$ROOT/tmp"
# Ignore any per-user `go env -w` settings. The module files in this repository
# and the environment above are the complete build configuration.
export GOENV=off

cd "$MODULE"
exec go "$@"
