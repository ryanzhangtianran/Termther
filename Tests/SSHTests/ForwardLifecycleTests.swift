import Darwin
import Net
import Testing
@testable import SSH

/// A forward binds a socket and drives it with GCD. Getting the descriptor's
/// lifetime wrong there does not fail a check -- it crashes the process, which
/// is why this exercises start/stop hard and without needing a server.
@Test("binding and tearing down repeatedly is safe")
func forwardLifecycle() async throws {
    let session = SSHSession()   // never connected; nothing is dialled

    for _ in 0..<40 {
        let forward = try PortForward(session: session, direction: .local,
                                      bindPort: 0, targetHost: "127.0.0.1", targetPort: 9)
        let port = forward.bindPort
        #expect(port != 0)
        try await forward.start()
        await forward.stop()
    }
}

@Test("a forward that was never started still releases its port")
func forwardNeverStarted() async throws {
    let session = SSHSession()
    let forward = try PortForward(session: session, direction: .local,
                                  bindPort: 0, targetHost: "127.0.0.1", targetPort: 9)
    let port = forward.bindPort
    await forward.stop()

    // The port must be free again straight away, or stop() leaked the socket.
    let again = try PortForward(session: session, direction: .local,
                                bindHost: "127.0.0.1", bindPort: port,
                                targetHost: "127.0.0.1", targetPort: 9)
    await again.stop()
}

@Test("accepting a connection and dropping it does not crash")
func forwardAcceptsAndDrops() async throws {
    let session = SSHSession()   // not connected, so the dial will fail
    let forward = try PortForward(session: session, direction: .local,
                                  bindPort: 0, targetHost: "127.0.0.1", targetPort: 9)
    try await forward.start()
    let port = forward.bindPort

    // The forward accepts, fails to open a channel, and closes the client.
    // Doing that wrong is a use-after-close rather than a wrong answer.
    for _ in 0..<10 {
        let fd = try await DirectTransport().connect(host: "127.0.0.1", port: port)
        close(fd)
    }
    try await Task.sleep(for: .milliseconds(300))

    let stats = await forward.stats()
    #expect(stats.connections > 0, "connections should have been accepted")
    await forward.stop()
}

@Test("using a session that was never connected is an error, not a crash")
func unconnectedSessionIsSafe() async throws {
    // libssh2 segfaults on a NULL session rather than returning an error, so
    // every entry point has to check before it reaches C. A forward outliving
    // its session would otherwise take the whole app down.
    let session = SSHSession()

    await #expect(throws: SSHError.self) { _ = try await session.openShell() }
    await #expect(throws: SSHError.self) { _ = try await session.openSFTP() }
    await #expect(throws: SSHError.self) { _ = try await session.exec("true") }
    await #expect(throws: SSHError.self) {
        _ = try await session.openDirectTCPIP(host: "127.0.0.1", port: 22)
    }
    await #expect(throws: SSHError.self) {
        _ = try await session.authMethods(username: "someone")
    }
    // Tearing down something that was never set up must also be quiet.
    await session.disconnect()
}

@Test("one session shutting down does not disturb the others")
func concurrentSessionLifetimes() async throws {
    // libssh2's init and exit are global. Pairing them per session means the
    // first session to close tears down state the others are still using, and
    // they then crash inside C -- which in the app would be "closing one tab
    // killed every other connection".
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let session = SSHSession()
                // Never connected, so every call must refuse cleanly...
                _ = try? await session.openShell()
                await session.disconnect()
            }
        }
    }

    // ...and the library must still work afterwards for anyone else.
    let (a, b) = try SocketPairBridge.make()
    defer { close(a); close(b) }
    let survivor = SSHSession(readinessTimeout: 0.3)
    try await survivor.adopt(b)
    // The far end says nothing, so this times out rather than succeeding --
    // the point is that it reaches libssh2 at all instead of crashing.
    await #expect(throws: SSHError.self) { try await survivor.handshake() }
    await survivor.disconnect()
}

@Test("disconnecting with channels still open is safe")
func disconnectWithOpenChannels() async throws {
    // `disconnect` closes whatever is still open. Walking the live `.keys`
    // view while each close removes an entry corrupts memory instead of
    // failing a check, and it only happens when something is genuinely still
    // open -- which a port forward, unlike a shell or an SFTP session, leaves
    // behind as a matter of course.
    for _ in 0..<20 {
        let session = SSHSession()
        _ = try? await session.openShell()
        _ = try? await session.openSFTP()
        _ = try? await session.openDirectTCPIP(host: "127.0.0.1", port: 9)
        await session.disconnect()
    }
}

@Test("disconnecting while reads are in flight does not crash")
func disconnectDuringReads() async throws {
    // Closing a tab tears the session down while its output pump is still
    // inside libssh2. A channel pointer fetched once and held across an
    // `await` is freed underneath it -- a use-after-free that takes the whole
    // app down rather than failing a check.
    for _ in 0..<20 {
        let session = SSHSession(readinessTimeout: 0.2)
        let (far, ours) = try SocketPairBridge.make()
        defer { close(far) }
        try await session.adopt(ours)

        // Readers started against a session that will never handshake: they
        // park inside the pump, which is exactly where the race lives.
        let readers = (0..<4).map { _ in
            Task { _ = try? await session.openShell() }
        }
        try await Task.sleep(for: .milliseconds(10))
        await session.disconnect()
        for reader in readers { _ = await reader.value }
    }
}

@Test("a channel used after its session went away reports rather than crashes")
func channelAfterDisconnect() async throws {
    let session = SSHSession()
    await session.disconnect()

    // Every operation has to notice the session is gone, at any point in its
    // loop -- not only on the way in.
    await #expect(throws: SSHError.self) { _ = try await session.openShell() }
    await #expect(throws: SSHError.self) {
        _ = try await session.openDirectTCPIP(host: "127.0.0.1", port: 9)
    }
}
