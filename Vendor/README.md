# Vendor

The engines Termther links. Each script is self-contained and rebuilds its
`.xcframework` from source. Two are upstream projects; `ec` is this
repository's own `EC`.

| | Source | Licence | Build |
|---|---|---|---|
| `libssh2.xcframework` | libssh2 1.11.1 + OpenSSL | BSD-3 / Apache-2.0 | `./build-libssh2.sh` |
| `ghostty-vt.xcframework` | ghostty-org/ghostty | MIT | `./build-ghostty-vt.sh` |
| `ec.xcframework` | `../EC` | AGPL-3.0 | `./build-ec.sh` |

```sh
./build-libssh2.sh && ./build-ghostty-vt.sh && ./build-ec.sh
../Scripts/swift-local.sh test # every engine is called for real, not just linked
```

Needs `zig >= 0.16.0` (`brew install zig`) and a Rust toolchain (`rustup`).

None of them needs a hand-written module map target: Ghostty ships one inside
its xcframework (`import GhosttyVt`), and `build-libssh2.sh` and
`build-ec.sh` generate one (`CSSH2`, `CEC`).

Each build finishes by putting its headers below a module-specific directory
inside the XCFramework while leaving `HeadersPath` at the common `Headers`
root. SwiftPM 6.4 copies binary-target headers into one include tree, so
plain `Headers/module.modulemap` paths otherwise collide.

## Known gaps before shipping

- **arm64 only.** OpenSSL comes from Homebrew, which ships no x86_64 slice.
  Build OpenSSL from source in `build-libssh2.sh` and add the slice if Intel
  Macs matter. Ghostty's xcframework is already macOS-universal plus iOS.
