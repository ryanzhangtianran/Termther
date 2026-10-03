import Foundation

/// The server half of SOCKS5, for dynamic port forwarding.
///
/// `SOCKS5Transport` speaks this protocol to reach a proxy; this answers it, so
/// a browser pointed at Termther can send anything through an SSH session. The
/// two halves live side by side deliberately: they share one reading of the
/// RFC, and one of them is the test fixture for the other.
public enum SOCKS5Server {
    public struct Destination: Sendable, Equatable {
        public var host: String
        public var port: UInt16
    }

    /// Completes the handshake and returns where the client wants to go.
    ///
    /// Only the no-authentication method is offered: the listener is bound to
    /// loopback, so anything that can reach it can already run code as this
    /// user, and a password would be theatre.
    public static func negotiate(on stream: ByteStream) throws -> Destination {
        let greeting = try stream.readExactly(2)
        guard greeting[0] == 0x05 else {
            throw TransportError.proxyRejected("not SOCKS5 (version \(greeting[0]))")
        }
        let methods = try stream.readExactly(Int(greeting[1]))
        guard methods.contains(0x00) else {
            try stream.write([0x05, 0xFF])
            throw TransportError.proxyRejected("client offered no acceptable auth method")
        }
        try stream.write([0x05, 0x00])

        let request = try stream.readExactly(4)
        guard request[0] == 0x05 else {
            throw TransportError.proxyRejected("malformed request")
        }
        guard request[1] == 0x01 else {
            // BIND and UDP ASSOCIATE are not what a terminal needs.
            try reply(on: stream, code: 0x07)
            throw TransportError.proxyRejected("only CONNECT is supported")
        }

        let host: String
        switch request[3] {
        case 0x01:
            host = try stream.readExactly(4).map(String.init).joined(separator: ".")
        case 0x03:
            let length = try stream.readExactly(1)[0]
            host = String(decoding: try stream.readExactly(Int(length)), as: UTF8.self)
        case 0x04:
            let bytes = try stream.readExactly(16)
            host = stride(from: 0, to: 16, by: 2)
                .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
                .joined(separator: ":")
        default:
            try reply(on: stream, code: 0x08)
            throw TransportError.proxyRejected("unknown address type \(request[3])")
        }

        let portBytes = try stream.readExactly(2)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])

        // Success is reported before the far end is dialled. Waiting would be
        // more honest, but every SOCKS client tolerates this and it keeps the
        // handshake off the SSH session's critical path.
        try reply(on: stream, code: 0x00)
        return Destination(host: host, port: port)
    }

    private static func reply(on stream: ByteStream, code: UInt8) throws {
        try stream.write([0x05, code, 0x00, 0x01] + [0, 0, 0, 0] + [0, 0])
    }
}
