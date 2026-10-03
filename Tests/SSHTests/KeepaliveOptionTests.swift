import Darwin
import Testing
@testable import SSH

/// The kernel's dead-peer detection, set on every SSH socket.
@Test("a TCP socket probes a silent peer after 30s, every 10s, three times")
func tcpKeepaliveIsSet() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }

    SSHSession.enableTCPKeepalive(on: fd)

    func get(_ level: Int32, _ option: Int32) -> Int32 {
        var value: Int32 = -1
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, level, option, &value, &size)
        return value
    }
    #expect(get(SOL_SOCKET, SO_KEEPALIVE) != 0)
    #expect(get(IPPROTO_TCP, TCP_KEEPALIVE) == 30)
    #expect(get(IPPROTO_TCP, TCP_KEEPINTVL) == 10)
    #expect(get(IPPROTO_TCP, TCP_KEEPCNT) == 3)
}
