# Working on Termther

## Build and test

The Command Line Tools are enough; full Xcode is not needed. If you find
yourself reaching for `xcodebuild`, look at `Vendor/make-xcframework.sh` first
-- that dependency was removed on purpose and is easy to reintroduce.

```sh
./Scripts/swift-local.sh build
./Scripts/swift-local.sh test # everything that does not need a network
./Scripts/build-app.sh       # build/Termther.app
```

`swift-local.sh` uses the developer directory selected by `xcode-select` and
keeps compiler module caches under `.build/toolchain-cache`. This avoids stale
modules from another Command Line Tools release and does not require Xcode. If
the selected CLT omits the SwiftUI macro plugin required by its newest SDK, the
script uses the compatible macOS 26 SDK retained in the same CLT installation.

Some tests only run when asked, because they touch something shared and real:

```sh
TERMTHER_SSH_HOST=... TERMTHER_SSH_USER=... TERMTHER_SSH_KEY=... ./Scripts/swift-local.sh test
TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=... ./Scripts/swift-local.sh test --filter liveProbe
(cd EC && TERMTHER_TLS_SERVER=127.0.0.1:4433 cargo test live_tls)  # see the test
TERMTHER_KEYCHAIN=1 ./Scripts/swift-local.sh test --filter QuickUnlock
TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=... TERMTHER_EC_PASSWORD=... ./Scripts/swift-local.sh test --filter liveLogin
```

A test that reaches the login keychain, a real server or a real gateway must
gate itself this way. One that does not will one day fail for its own reasons,
and a test failing for its own reasons is indistinguishable from a bug.

## Naming

* Identifiers use American spelling, as Swift and the SDKs do (`color`,
  `initialized`); prose in comments and docs is free to stay British.
* Acronyms are all capitals: `serverID`, `SSHSession`, `VPNProfile`. Database
  column names keep their old spelling (`serverId`); SQLite and GRDB match
  them case-insensitively, so no migration is involved.
* A module-wide error is `<Module>Error` (`SSHError`, `TransportError`); a
  type's own errors are a nested `Failure`.
* A file is named after the type it holds. `SSHSession`'s extensions are
  named after the feature they add (`DirectChannel.swift`).
* Tests are `@Test("a sentence saying what holds")`, on its own line.
* Environment variables are `TERMTHER_*`; `SSHPASS` keeps sshpass's name.
* Top-level directories are capitalised words; scripts are kebab-case.

## The seam

Everything that reaches a host produces a connected descriptor:

```swift
public protocol SSHTransport: Sendable { func connect(host:port:) async throws -> Int32 }
```

Adding a route -- another proxy, another VPN -- means adding one of these and a
line in `Connector.transport(for:)`. Nothing else should learn about it.

## Things that have already gone wrong

* **libssh2 tolerates concurrent work across channels, never within one.** A
  read and a write interleaved on the same channel corrupt it, and it crashes
  inside `_libssh2_transport_send` rather than returning an error. `pump` does
  both in one call that never suspends, which makes it impossible by
  construction.
* **A channel pointer held across an `await` is a use-after-free.** `disconnect`
  can run in the gap. Re-fetch from the dictionary every time round.
* **A broken tunnel must report, never end the process.** The Go engine that
  used to live here panicked on a read error and called `os.Exit` on a server
  shutdown, so changing networks made the app vanish. `Session` (EC/src/session.rs)
  reopens a broken stream up to five times in a row and then records why in
  `tunnelFailure()`. Every `ec_*` entry point catches panics for the same
  reason, and sockets set `SO_NOSIGPIPE`: in the app, unlike in a Rust
  binary, nothing ignores SIGPIPE.
  Keep it that way: a library that can kill the app is not a library.
* **The EC TLS is hand-written on purpose.** The tunnel needs a ClientHello
  with session ID `L3IP`, TLS 1.1 and RC4, and the token needs the server's
  session ID. Network.framework does neither. Homebrew's OpenSSL has no RC4
  suites, so `live_tls` needs the system LibreSSL for the tunnel hello.
* **The EC engine is Rust, and `Vendor/build-ec.sh` must be rerun after editing
  `EC`.** SwiftPM links the prebuilt `Vendor/ec.xcframework` and will not
  notice a stale one. `Sources/VPN` keeps only what is macOS-specific:
  discovering the physical interface and its DHCP resolver.
* **Host keys were once recorded and never checked.** The store had
  trust-on-first-use from the start, but nothing called it, so any server was
  accepted. The check now lives in `SSHSession.connect`, which every route
  goes through, via `HostKeyCheck`; the app installs the store-backed check
  at launch. A new way of connecting must go through `connect` too.
* **`withTaskGroup` waits for every child, and cancelling one only sets a flag.**
  A task blocked in a synchronous C call ignores it. Race two independent tasks
  instead, or a two-second budget becomes a permanent hang.
* **A wait inside `SSHSession` must end when the session does.** Every EAGAIN
  wait is registered, `disconnect` finishes them all and bumps `generation`,
  and anything that frees a channel after an `await` checks it first -- the
  session has freed it already. A shell read waits with no deadline; a
  30-second one closed every idle tab.
* **`~/.ssh/config` is the user's file.** It is read with
  `SSHConfigDocument.read`, which throws rather than returning "" for a file
  it cannot decode, and a server's removal only removes a `Host` holding
  nothing but what the app writes. Every socket the app writes to sets
  `SO_NOSIGPIPE` (`SocketOptions.noSIGPIPE`).
* **A test that cannot observe the failure gives false confidence.** The
  powerline bug survived several rounds because the test canvas was one cell
  tall and clipped the overflow.
