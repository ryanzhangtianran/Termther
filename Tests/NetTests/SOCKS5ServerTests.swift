import Darwin
import Testing
@testable import Net

/// The client and server halves of SOCKS5 are tested against each other: one
/// reading of the RFC, and each half is the other's fixture. A disagreement
/// here would mean dynamic forwarding silently talks to itself wrongly.
@Test("the client and server halves agree, hostname form")
func socks5RoundTripHostname() async throws {
    let (serverSide, clientSide) = try SocketPairBridge.make()
    defer { close(serverSide); close(clientSide) }

    let server = Task.detached {
        try SOCKS5Server.negotiate(on: FileDescriptorStream(fd: serverSide))
    }
    try SOCKS5.negotiate(on: FileDescriptorStream(fd: clientSide),
                         host: "hpc.example.edu", port: 22)

    let destination = try await server.value
    #expect(destination.host == "hpc.example.edu")
    #expect(destination.port == 22)
}

@Test("the client and server halves agree, IPv4 literal form")
func socks5RoundTripLiteral() async throws {
    let (serverSide, clientSide) = try SocketPairBridge.make()
    defer { close(serverSide); close(clientSide) }

    let server = Task.detached {
        try SOCKS5Server.negotiate(on: FileDescriptorStream(fd: serverSide))
    }
    try SOCKS5.negotiate(on: FileDescriptorStream(fd: clientSide),
                         host: "10.121.10.28", port: 443)

    let destination = try await server.value
    #expect(destination.host == "10.121.10.28")
    #expect(destination.port == 443)
}

@Test("the server refuses what it cannot do, rather than pretending")
func socks5ServerRefusesBind() async throws {
    let (serverSide, clientSide) = try SocketPairBridge.make()
    defer { close(serverSide); close(clientSide) }

    let server = Task.detached {
        try SOCKS5Server.negotiate(on: FileDescriptorStream(fd: serverSide))
    }
    let client = FileDescriptorStream(fd: clientSide)
    try client.write([0x05, 0x01, 0x00])
    _ = try client.readExactly(2)
    // Command 0x02 is BIND, which a terminal has no use for.
    try client.write([0x05, 0x02, 0x00, 0x01] + [10, 0, 0, 1] + [0, 22])

    await #expect(throws: TransportError.self) { try await server.value }
    let reply = try client.readExactly(10)
    #expect(reply[1] == 0x07, "expected 'command not supported'")
}
