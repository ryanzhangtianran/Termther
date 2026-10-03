import Darwin
import Foundation
import Net
import Testing
@testable import SSH

/// Needs a reachable SSH server, like the rest of the live tests:
///   TERMTHER_SSH_HOST=127.0.0.1 TERMTHER_SSH_USER=you SSHPASS=... swift test
private struct Target {
    let host: String, port: UInt16, user: String
    /// Either a password or a private key; a self-test server is easier to
    /// stand up with a key, and a real one is usually reached with a password.
    let password: String?
    let privateKey: String?

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMTHER_SSH_HOST"], let user = env["TERMTHER_SSH_USER"]
        else { return nil }
        self.host = host
        self.user = user
        self.port = env["TERMTHER_SSH_PORT"].flatMap { UInt16($0) } ?? 22

        let password = env["SSHPASS"]
        let key = env["TERMTHER_SSH_KEY"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard password?.isEmpty == false || key != nil else { return nil }
        self.password = password?.isEmpty == false ? password : nil
        self.privateKey = key
    }

    func authenticate(_ session: SSHSession) async throws {
        if let privateKey {
            try await session.authenticate(username: user, privateKey: privateKey)
        } else if let password {
            try await session.authenticate(username: user, password: password)
        }
    }
}

/// A trivial TCP server on this machine, standing in for whatever the tunnel
/// is meant to reach -- a proxy, usually.
private final class EchoServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "test.echo")
    private var source: DispatchSourceRead?

    init() throws {
        // Everything below works on a local, so nothing touches `self` before
        // both stored properties are set.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(descriptor, 8)

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        fd = descriptor
        port = UInt16(bigEndian: actual.sin_port)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [fd] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = read(client, &buffer, buffer.count)
                if n > 0 { _ = buffer.withUnsafeBytes { write(client, $0.baseAddress, n) } }
                close(client)
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    func stop() { source?.cancel() }
}

@Test("a reverse forward carries a connection made on the server back here")
func reverseForwardCarriesTraffic() async throws {
    guard let target = Target() else { return }   // skipped without a server

    let echo = try EchoServer()
    echo.start()
    defer { echo.stop() }

    let session = SSHSession()
    try await session.connect(to: target.host, port: target.port)
    try await target.authenticate(session)
    defer { Task { await session.disconnect() } }

    // Port 0: let the server pick, so a leftover listener from an earlier run
    // cannot make this fail for the wrong reason.
    let forward = try PortForward(session: session, direction: .remote,
                                 bindHost: "127.0.0.1", bindPort: 0,
                                 targetHost: "127.0.0.1", targetPort: echo.port)
    try await forward.start()
    defer { Task { await forward.stop() } }

    let bound = await forward.boundPort
    #expect(bound != 0, "the server did not report which port it bound")

    // Run on the server: open its own loopback port and speak to whatever
    // answers. Nothing on that machine is listening -- the bytes come here.
    // Through bash explicitly: /dev/tcp is a bash feature, and the account's
    // login shell -- which is what sshd runs a command with -- is zsh on
    // macOS, where the same line fails with "no such file or directory" and
    // no connection is ever made. The test then fails for its own reasons and
    // says nothing about the forward.
    let result = try await session.exec("""
        /bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/\(bound) && printf ping >&3 && head -c 4 <&3'
        """)
    let detail = "stdout=\(result.stdout) stderr=\(result.stderr) exit=\(result.exitStatus)"
    #expect(result.stdout.contains("ping"),
            "the server's connection did not reach this machine. \(detail)")

    let stats = await forward.stats()
    #expect(stats.connections == 1)
    #expect(stats.bytesIn >= 4)
}

@Test("listening on a session that was never connected is an error, not a crash")
func remoteListenWithoutASession() async {
    let session = SSHSession()
    await #expect(throws: (any Error).self) {
        _ = try await session.listenRemote(port: 0)
    }
}

@Test("a reverse forward with nowhere to send connections still tears down")
func reverseForwardWithoutADestination() async throws {
    // No session, so `start` fails; the point is that constructing and
    // stopping one binds nothing locally and leaves nothing behind.
    let session = SSHSession()
    let forward = try PortForward(session: session, direction: .remote,
                                  bindHost: "127.0.0.1", bindPort: 16152,
                                  targetHost: "127.0.0.1", targetPort: 6152)
    await #expect(throws: (any Error).self) { try await forward.start() }
    await forward.stop()
}
