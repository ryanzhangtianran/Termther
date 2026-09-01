import Darwin
import Foundation
import Net
import Testing
@testable import SSH

@Test("libssh2 links and reports a version")
func libssh2Links() {
    let version = SSHLinkCheck.libssh2Version
    #expect(!version.isEmpty)
    #expect(version.hasPrefix("1."))
}

private struct RefusingTransport: SSHTransport {
    var pathDescription: String { "refusing" }
    func connect(host: String, port: UInt16) async throws -> Int32 {
        throw TransportError.connect(host: host, port: port, reason: "test refusal")
    }
}

@Test("a transport failure surfaces as itself, not as an SSH error")
func transportFailurePropagates() async {
    let session = SSHSession()
    await #expect(throws: TransportError.self) {
        try await session.connect(to: "example", over: RefusingTransport())
    }
    await session.disconnect()
}

@Test("the pump gives up rather than hanging when the peer never speaks SSH")
func handshakeTimesOut() async throws {
    // A socketpair whose far end says nothing: the handshake will wait for a
    // version string that never arrives. The readiness timeout is what has to
    // fire -- a pump without one would hang here forever.
    let (silent, ours) = try SocketPairBridge.make()
    defer { close(silent) }

    let session = SSHSession(readinessTimeout: 0.5)
    try await session.adopt(ours)

    let started = Date()
    await #expect(throws: SSHError.self) { try await session.handshake() }
    #expect(Date().timeIntervalSince(started) < 5)
    await session.disconnect()
}
