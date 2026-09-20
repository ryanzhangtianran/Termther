# Vendor

Three engines Termther links but does not maintain. Each script is
self-contained and rebuilds its `.xcframework` from source.

| | Source | Licence | Build |
|---|---|---|---|
| `libssh2.xcframework` | libssh2 1.11.1 + OpenSSL | BSD-3 / Apache-2.0 | `./build-libssh2.sh` |
| `ghostty-vt.xcframework` | ghostty-org/ghostty | MIT | `./build-ghostty-vt.sh` |
| `ecshim.xcframework` | `easierconnect/` (see its NOTICE) | AGPL-3.0 | `./build-ecshim.sh` |

```sh
./build-libssh2.sh && ./build-ghostty-vt.sh && ./build-ecshim.sh
../Scripts/swift-local.sh test # every engine is called for real, not just linked
```

Needs `zig >= 0.16.0` and `go` (`brew install zig go`).

Go commands should go through `go-local.sh`, which keeps both the module cache
and the build cache under `Vendor/.go/` instead of writing to `~/go/pkg/mod`
and `~/Library/Caches/go-build`:

```sh
./go-local.sh ecshim mod download
./go-local.sh easierconnect test ./...
```

`build-ecshim.sh` already uses this wrapper. `Vendor/.go/` is a disposable,
ignored cache; `go.mod` and `go.sum` remain beside each module's source.

None of them needs a hand-written module map target: Ghostty ships one inside
its xcframework (`import GhosttyVt`), and the other two scripts generate one
(`CSSH2`, `CECShim`).

Each build finishes by putting its headers below a module-specific directory
inside the XCFramework while leaving `HeadersPath` at the common `Headers`
root. SwiftPM 6.4 copies binary-target headers into one include tree, so three
plain `Headers/module.modulemap` paths otherwise collide.

## Known gaps before shipping

- **arm64 only.** OpenSSL comes from Homebrew, which ships no x86_64 slice.
  Build OpenSSL from source in `build-libssh2.sh` and add the slice if Intel
  Macs matter. Ghostty's xcframework is already macOS-universal plus iOS.
- **The engine used to kill the process on tunnel errors.** One `os.Exit(2)` and
  three `panic()` calls in `stack/gvisor/stack.go`; `resolve/resolver.go` and
  `internal/ippool` add a `log.Fatal` and a `panic` on the FakeIP path we do
  not use. The shim's pump goroutine wraps `Run()` in `recover()`, which cannot
  catch the `os.Exit`. Fork and patch those four sites to return errors, and
  offer it upstream — the CLI loses nothing, since `main` can exit on the error
  itself. See `spikes/README.md`.
