# Termther

A terminal for macOS that happens to speak SSH.

Native SwiftUI and Metal, with everything that used to need a helper process
brought in-process: the SSH client is libssh2, the emulator is libghostty-vt,
and the VPN is an EasyConnect engine linked as a Go archive. No `ssh` subprocess,
no TUN device, no root.

```sh
Vendor/build-libssh2.sh      # once: the three vendored binaries
Vendor/build-ghostty-vt.sh
Vendor/build-ecshim.sh

swift test                   # 215 tests
./Scripts/build-app.sh       # build/Termther.app
```

Needs the Command Line Tools, plus Go and Zig for two of the vendored builds.
Not Xcode: `Vendor/make-xcframework.sh` writes the framework layout itself, and
the Metal shaders are compiled at startup rather than by `metal`.

## Layout

Dependencies run one way, and the direction is the design:

```
Net   <- nothing        byte streams and file descriptors only
SSH   <- Net            sessions, channels, SFTP, port forwards
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
* **EasyConnect engine** (AGPL-3.0), in `Vendor/easierconnect`: a trimmed and
  patched fork, cut down to the client and the userspace network stack, and
  changed so a broken tunnel reports rather than ending the process. Every
  change is marked `TERMTHER PATCH`; where it came from and what was done to it
  is in `Vendor/easierconnect/NOTICE`.

Each was proved out on its own before any of this existed -- an EasyConnect
tunnel, a terminal core, and a non-blocking SSH session, each reduced to the
one question worth asking of it. Those probes are gone now; what they
established is in the code and in the notes at the end of `AGENTS.md`.

## Licence

AGPL-3.0, the same as the VPN engine it links. See
`Vendor/easierconnect/NOTICE`.
