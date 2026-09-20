import Foundation
import Net
import Testing
@testable import SSH

/// These need a reachable SSH server. Point them at one with:
///   TERMTHER_SSH_HOST=127.0.0.1 TERMTHER_SSH_USER=you SSHPASS=... swift test
private struct Target {
    let host: String, user: String, password: String
    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMTHER_SSH_HOST"],
              let user = env["TERMTHER_SSH_USER"],
              let password = env["SSHPASS"], !password.isEmpty
        else { return nil }
        self.host = host; self.user = user; self.password = password
    }
}

@Test("a pty shell echoes what is typed and reports its size")
func interactiveShell() async throws {
    guard let target = Target() else { return }   // skipped without a server

    let session = SSHSession()
    try await session.connect(to: target.host)
    try await session.authenticate(username: target.user, password: target.password)

    let shell = try await session.openShell(cols: 100, rows: 30)

    // A pty is what makes this interactive at all: over a plain pipe the shell
    // would neither echo nor answer `tput`.
    try await session.write(shell, Array("echo COLS=$(tput cols) ROWS=$(tput lines)\n".utf8))

    var transcript = ""
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !transcript.contains("COLS=100") {
        let chunk = try await session.read(shell)
        if chunk.isEmpty { break }
        transcript += String(decoding: chunk, as: UTF8.self)
    }
    #expect(transcript.contains("COLS=100"), "pty size not honoured; got: \(transcript.suffix(200))")
    #expect(transcript.contains("ROWS=30"))

    // Resizing must reach the far end, or full-screen programs draw at the
    // wrong size after a window drag.
    try await session.resize(shell, cols: 120, rows: 40)
    try await session.write(shell, Array("echo NEW=$(tput cols)\n".utf8))

    let resizeDeadline = Date().addingTimeInterval(10)
    while Date() < resizeDeadline, !transcript.contains("NEW=120") {
        let chunk = try await session.read(shell)
        if chunk.isEmpty { break }
        transcript += String(decoding: chunk, as: UTF8.self)
    }
    #expect(transcript.contains("NEW=120"))

    await session.close(shell)
    await session.disconnect()
}

@Test("SFTP lists, writes, reads back and removes")
func sftpRoundTrip() async throws {
    guard let target = Target() else { return }   // skipped without a server

    let session = SSHSession()
    try await session.connect(to: target.host)
    try await session.authenticate(username: target.user, password: target.password)

    let sftp = try await session.openSFTP()
    let home = try await session.realpath(sftp, path: ".")
    #expect(home.hasPrefix("/"), "realpath should resolve '.' to an absolute path, got \(home)")

    let path = "\(home)/.termther-sftp-test"
    let payload = Data("termther sftp round trip \(UUID())".utf8)

    try await session.write(sftp, path: path, data: payload)
    let listing = try await session.list(sftp, path: home)
    #expect(listing.contains { $0.name == ".termther-sftp-test" && !$0.isDirectory })

    let stat = try await session.stat(sftp, path: path)
    #expect(stat?.size == UInt64(payload.count))

    #expect(try await session.read(sftp, path: path) == payload)

    try await session.remove(sftp, path: path)
    #expect(try await session.stat(sftp, path: path) == nil, "the file should be gone")

    await session.closeSFTP(sftp)
    await session.disconnect()
}

@Test("a local forward carries traffic and counts it")
func localPortForward() async throws {
    guard let target = Target() else { return }

    let session = SSHSession()
    try await session.connect(to: target.host)
    try await session.authenticate(username: target.user, password: target.password)

    // Forward to the SSH server itself: it greets on connect, so the tunnel is
    // proven by the banner coming back through it.
    let forward = try PortForward(session: session, direction: .local,
                                  bindPort: 0,
                                  targetHost: "127.0.0.1", targetPort: 22)
    try await forward.start()
    let port = forward.bindPort
    #expect(port != 0, "port 0 should have been resolved to the one actually bound")

    let fd = try await DirectTransport().connect(host: "127.0.0.1", port: port)
    defer { close(fd) }

    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 128)
    let n = read(fd, &buffer, buffer.count)

    #expect(n > 0, "nothing came back through the forward")
    let banner = String(decoding: buffer[0..<max(0, n)], as: UTF8.self)
    #expect(banner.hasPrefix("SSH-"), "expected an SSH banner, got \(banner.prefix(40))")

    let stats = await forward.stats()
    #expect(stats.connections == 1)
    #expect(stats.bytesIn > 0, "per-forward traffic should be counted")

    await forward.stop()
    await session.disconnect()
}

@Test("a dynamic forward routes wherever each client asks")
func dynamicPortForward() async throws {
    guard let target = Target() else { return }

    let session = SSHSession()
    try await session.connect(to: target.host)
    try await session.authenticate(username: target.user, password: target.password)

    // A SOCKS5 proxy over the session: no fixed destination, each client says
    // where it wants to go.
    let forward = try PortForward(session: session, direction: .dynamic, bindPort: 0)
    try await forward.start()
    let port = forward.bindPort

    // Reach the SSH server through it -- the transport built for talking to a
    // proxy, pointed at our own.
    let fd = try await SOCKS5Transport(proxyHost: "127.0.0.1", proxyPort: port)
        .connect(host: "127.0.0.1", port: 22)
    defer { close(fd) }

    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 128)
    let n = read(fd, &buffer, buffer.count)

    #expect(n > 0, "nothing came back through the dynamic forward")
    #expect(String(decoding: buffer[0..<max(0, n)], as: UTF8.self).hasPrefix("SSH-"))

    await forward.stop()
    await session.disconnect()
}
