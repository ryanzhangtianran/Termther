import Darwin
import Foundation
import Testing
@testable import SSH

/// The bandwidth readout counts bytes inside libssh2's own socket calls.
///
/// A handshake against something that only pretends to be an SSH server
/// still moves bytes both ways -- libssh2's banner out, the fake one in --
/// and then has to fail cleanly: the counted calls must hand errors and a
/// hang-up back the way libssh2 expects, or it waits forever instead.
@Test(.timeLimit(.minutes(1)))
func trafficIsCountedAtTheSocket() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { close(listener) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, length) == 0 && listen(listener, 1) == 0
                && getsockname(listener, $0, &length) == 0
        }
    }
    try #require(bound)

    // Answers with a banner, reads what comes back, then hangs up.
    Thread.detachNewThread {
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        let banner = Array("SSH-2.0-NotReally\r\n".utf8)
        _ = banner.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        _ = recv(peer, &buffer, capacity, 0)
        close(peer)
    }

    let client = socket(AF_INET, SOCK_STREAM, 0)
    try #require(client >= 0)
    // A write after the fake server hangs up must fail, not end the process.
    var one: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    try #require(connected)

    let session = SSHSession(readinessTimeout: 10)
    try await session.adopt(client)
    await #expect(throws: (any Error).self) { try await session.handshake() }

    let traffic = session.traffic.statistics
    #expect(traffic.bytesOut > 0)
    #expect(traffic.bytesIn >= UInt64("SSH-2.0-NotReally\r\n".utf8.count))
    await session.disconnect()
}
