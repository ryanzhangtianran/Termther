import Darwin
import Foundation
import Testing
@testable import Net

// MARK: - a stream that records what was written and replays canned replies

final class FakeStream: ByteStream {
    private(set) var written = [UInt8]()
    private var toRead: [UInt8]
    init(replies: [UInt8]) { self.toRead = replies }

    func write(_ bytes: [UInt8]) throws { written += bytes }
    func readExactly(_ count: Int) throws -> [UInt8] {
        guard toRead.count >= count else {
            throw TransportError.truncated(expected: count, got: toRead.count)
        }
        defer { toRead.removeFirst(count) }
        return Array(toRead.prefix(count))
    }
}

// MARK: - SOCKS5

@Test("SOCKS5 no-auth CONNECT sends a hostname and accepts success")
func socks5Hostname() throws {
    let stream = FakeStream(replies:
        [0x05, 0x00] +                              // choose no-auth
        [0x05, 0x00, 0x00, 0x01] + [0,0,0,0, 0,0])  // success, bound 0.0.0.0:0
    try SOCKS5.negotiate(on: stream, host: "hpc.example.edu", port: 22)

    // greeting: version, 1 method, no-auth
    #expect(Array(stream.written.prefix(3)) == [0x05, 0x01, 0x00])
    // request: version, CONNECT, reserved, name type, length
    let request = Array(stream.written.dropFirst(3))
    #expect(Array(request.prefix(5)) == [0x05, 0x01, 0x00, 0x03, 15])
    #expect(Array(request.suffix(2)) == [0x00, 0x16])   // port 22
}

@Test("SOCKS5 sends an IPv4 literal as an address, not a name")
func socks5Literal() throws {
    let stream = FakeStream(replies: [0x05, 0x00] + [0x05, 0x00, 0x00, 0x01] + [0,0,0,0, 0,0])
    try SOCKS5.negotiate(on: stream, host: "10.121.10.28", port: 443)
    let request = Array(stream.written.dropFirst(3))
    #expect(Array(request.prefix(4)) == [0x05, 0x01, 0x00, 0x01])
    #expect(Array(request[4..<8]) == [10, 121, 10, 28])
}

@Test("SOCKS5 username/password sub-negotiation is offered and used")
func socks5Auth() throws {
    let stream = FakeStream(replies:
        [0x05, 0x02] +                              // proxy picks user/pass
        [0x01, 0x00] +                              // credentials accepted
        [0x05, 0x00, 0x00, 0x01] + [0,0,0,0, 0,0])
    try SOCKS5.negotiate(on: stream, host: "example", port: 22,
                         username: "u", password: "pw")
    #expect(Array(stream.written.prefix(4)) == [0x05, 0x02, 0x00, 0x02])
    // RFC 1929 carries its own version byte, 0x01 -- not SOCKS5's 0x05.
    #expect(Array(stream.written[4..<11]) == [0x01, 1, 0x75, 2, 0x70, 0x77, 0x05])
}

@Test("SOCKS5 surfaces the proxy's refusal reason")
func socks5Refused() throws {
    let stream = FakeStream(replies: [0x05, 0x00] + [0x05, 0x05, 0x00, 0x01])
    #expect(throws: TransportError.proxyRejected("connection refused")) {
        try SOCKS5.negotiate(on: stream, host: "example", port: 22)
    }
}

@Test("SOCKS5 refuses to guess when the proxy demands credentials we lack")
func socks5MissingCredentials() throws {
    let stream = FakeStream(replies: [0x05, 0x02])
    #expect(throws: TransportError.self) {
        try SOCKS5.negotiate(on: stream, host: "example", port: 22)
    }
}

// MARK: - HTTP CONNECT

@Test("CONNECT names the authority in both the request line and Host")
func httpConnectRequest() {
    let request = HTTPConnect.request(host: "hpc.example.edu", port: 22,
                                      username: nil, password: nil)
    #expect(request.hasPrefix("CONNECT hpc.example.edu:22 HTTP/1.1\r\n"))
    #expect(request.contains("Host: hpc.example.edu:22\r\n"))
    #expect(!request.contains("Proxy-Authorization"))
    #expect(request.hasSuffix("\r\n\r\n"))
}

@Test("CONNECT carries Basic credentials when configured")
func httpConnectAuth() {
    let request = HTTPConnect.request(host: "h", port: 22, username: "u", password: "pw")
    // base64("u:pw")
    #expect(request.contains("Proxy-Authorization: Basic dTpwdw==\r\n"))
}

@Test("CONNECT accepts any 2xx and reports anything else verbatim")
func httpConnectResponses() throws {
    try HTTPConnect.checkResponse("HTTP/1.1 200 Connection Established\r\n\r\n")
    #expect(throws: TransportError.proxyRejected("HTTP/1.1 407 Proxy Authentication Required")) {
        try HTTPConnect.checkResponse("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
    }
}

// MARK: - composition and the socketpair bridge

private struct StubTransport: SSHTransport {
    let fd: Int32
    var pathDescription: String { "stub" }
    func connect(host: String, port: UInt16) async throws -> Int32 { fd }
}

@Test("transports compose, and the path reads outside-in")
func composition() {
    let path = SOCKS5Transport(
        proxyHost: "127.0.0.1", proxyPort: 1080,
        over: HTTPConnectTransport(proxyHost: "proxy", proxyPort: 8080)
    ).pathDescription
    #expect(path == "SOCKS5 127.0.0.1:1080 -> HTTP CONNECT proxy:8080 -> direct")
}

@Test("a socketpair really carries bytes both ways")
func socketPairBridge() throws {
    let (local, remote) = try SocketPairBridge.make()
    defer { close(local); close(remote) }

    try FileDescriptorStream(fd: local).write(Array("SSH-2.0-Termther".utf8))
    let seen = try FileDescriptorStream(fd: remote).readExactly(16)
    #expect(String(decoding: seen, as: UTF8.self) == "SSH-2.0-Termther")

    try FileDescriptorStream(fd: remote).write([0x01, 0x02])
    #expect(try FileDescriptorStream(fd: local).readExactly(2) == [0x01, 0x02])
}

@Test("a SOCKS5 handshake runs end to end over a real descriptor")
func socks5OverSocketPair() async throws {
    // One end plays the proxy; the transport talks to the other.
    let (proxySide, clientSide) = try SocketPairBridge.make()
    defer { close(proxySide) }

    let proxy = Task.detached {
        let stream = FileDescriptorStream(fd: proxySide)
        _ = try stream.readExactly(3)                       // greeting
        try stream.write([0x05, 0x00])                      // no-auth
        _ = try stream.readExactly(4 + 1 + 7 + 2)           // CONNECT "example" :22
        try stream.write([0x05, 0x00, 0x00, 0x01] + [0,0,0,0, 0,0])
    }

    let fd = try await SOCKS5Transport(proxyHost: "unused", proxyPort: 0,
                                       over: StubTransport(fd: clientSide))
        .connect(host: "example", port: 22)
    try await proxy.value
    #expect(fd == clientSide)
    close(fd)
}
