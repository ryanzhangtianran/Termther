# Termther

A terminal for macOS that happens to speak SSH.

Native SwiftUI and Metal, with everything that used to need a helper process
brought in-process: the SSH client is libssh2, the emulator is libghostty-vt,
and the VPN is an EasyConnect client written in Rust (`EC/`), with its own
small TCP/IP stack. No `ssh` subprocess, no TUN device, no root. The same engine
builds on Linux as `termther-ec`, a SOCKS5 proxy into the tunnel.

```sh
Vendor/build-libssh2.sh      # once: the three vendored binaries
Vendor/build-ghostty-vt.sh
Vendor/build-ec.sh           # again whenever EC changes

./Scripts/swift-local.sh test # 260 tests
(cd EC && cargo test)        # the engine's own
./Scripts/build-app.sh       # build/Termther.app
```

Needs the Command Line Tools, plus Zig and Rust (cargo) for two of the vendored
builds.
Not Xcode: `Vendor/make-xcframework.sh` writes the framework layout itself, and
the Metal shaders are compiled at startup rather than by `metal`.
`Scripts/swift-local.sh` always uses the developer directory selected by
`xcode-select` and keeps compiler caches inside `.build`. CLT 27 currently
omits the SwiftUI macro plugin required by its macOS 27 SDK, so the script uses
the compatible macOS 26 SDK from the same installation when necessary.

## Layout

Dependencies run one way, and the direction is the design:

```
Net   <- nothing        byte streams and file descriptors only
SSH   <- Net            sessions, channels, port forwards
EC    <- Net            the campus VPN, as one more transport
VT    <- nothing        emulation and rendering; never sees SSH
Core  <- SSH, EC        models, vault, services
App   <- everything     the window
```

Everything that reaches a host arrives at one seam:

```swift
public protocol SSHTransport: Sendable {
    func connect(host: String, port: UInt16) async throws -> Int32
}
```

Direct, through a SOCKS5 or HTTP proxy, through a jump host, through the VPN --
each produces a connected descriptor, and nothing below that line can tell
which. That is why they compose in any order without special cases.

## Vendored

* **libssh2** 1.11.1 (BSD-3), built against a private OpenSSL.
* **libghostty-vt** (MIT), the emulator core from Ghostty.
* **`EC/`**, this repository's own EasyConnect engine, linked as a static
  library behind the C ABI in `EC/include/termther_ec.h`; `Sources/VPN` is
  the Swift over it.

Each was proved out on its own before any of this existed -- an EasyConnect
tunnel, a terminal core, and a non-blocking SSH session, each reduced to the
one question worth asking of it. Those probes are gone now; what they
established is in the code and in the notes at the end of `AGENTS.md`.

## Licence

AGPL-3.0.
