# Working on Termther

## Build and test

The Command Line Tools are enough; full Xcode is not needed. If you find
yourself reaching for `xcodebuild`, look at `Vendor/make-xcframework.sh` first
-- that dependency was removed on purpose and is easy to reintroduce.

```sh
swift build
swift test                   # everything that does not need a network
./Scripts/build-app.sh       # build/Termther.app
```

Some tests only run when asked, because they touch something shared and real:

```sh
TERMTHER_SSH_HOST=... TERMTHER_SSH_USER=... TERMTHER_SSH_KEY=... swift test
TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=... swift test --filter liveProbe
TERMTHER_KEYCHAIN=1 swift test --filter QuickUnlock
```

A test that reaches the login keychain, a real server or a real gateway must
gate itself this way. One that does not will one day fail for its own reasons,
and a test failing for its own reasons is indistinguishable from a bug.

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
* **The Go runtime copies the environment once, at process start.** A `setenv`
  from Swift is invisible to `os.Getenv`. Configuration crosses that boundary
  through the C ABI, never through the environment.
* **The VPN engine ends the process when its tunnel breaks** -- upstream
  panics on a read or write and calls `os.Exit(2)` on a server shutdown. The
  fork in `Vendor/easierconnect` reports instead. Keep it that way; a library
  that can kill the app is not a library. What that fork is and what was
  changed in it is in its `NOTICE`, which the licence requires and which
  stays.
* **`withTaskGroup` waits for every child, and cancelling one only sets a flag.**
  A task blocked in a synchronous C call ignores it. Race two independent tasks
  instead, or a two-second budget becomes a permanent hang.
* **A test that cannot observe the failure gives false confidence.** The
  powerline bug survived several rounds because the test canvas was one cell
  tall and clipped the overflow.
