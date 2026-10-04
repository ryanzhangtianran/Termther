import Foundation

/// SOCKS5 (RFC 1928 + RFC 1929 username/password auth).
///
/// Wraps another transport: the inner one reaches the proxy, this one turns
/// that connection into a tunnel to the real destination. Composing rather
/// than inheriting is what lets a proxy sit in front of a jump host, or a jump
/// host in front of a proxy, without either knowing about the other.
public struct SOCKS5Transport: SSHTransport {
    public var proxyHost: String
    public var proxyPort: UInt16
    public var username: String?
    public var password: String?
    public var inner: any SSHTransport

    public init(proxyHost: String, proxyPort: UInt16,
                username: String? = nil, password: String? = nil,
                over inner: any SSHTransport = DirectTransport()) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
        self.inner = inner
    }

    public var pathDescription: String {
        "SOCKS5 \(proxyHost):\(proxyPort) -> \(inner.pathDescription)"
    }

    public func connect(host: String, port: UInt16) async throws -> Int32 {
        let fd = try await inner.connect(host: proxyHost, port: proxyPort)
        do {
            try SOCKS5.negotiate(on: FileDescriptorStream(fd: fd),
                                 host: host, port: port,
                                 username: username, password: password)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}

/// The wire protocol, as a free function over a `ByteStream` so it can be
/// tested without a proxy.
public enum SOCKS5 {
    static let version: UInt8 = 0x05
    static let noAuth: UInt8 = 0x00
    static let userPassAuth: UInt8 = 0x02
    static let noAcceptable: UInt8 = 0xFF

    public static func negotiate(on stream: ByteStream,
                                 host: String, port: UInt16,
                                 username: String? = nil, password: String? = nil) throws {
        // Greeting: offer no-auth, plus username/password when we have some.
        var methods: [UInt8] = [noAuth]
        if username != nil { methods.append(userPassAuth) }
        try stream.write([version, UInt8(methods.count)] + methods)

        let choice = try stream.readExactly(2)
        guard choice[0] == version else {
            throw TransportError.proxyRejected("not SOCKS5 (version byte \(choice[0]))")
        }
        switch choice[1] {
        case noAuth:
            break
        case userPassAuth:
            guard let username, let password else {
                throw TransportError.proxyRejected("proxy wants credentials, none configured")
            }
            try authenticate(on: stream, username: username, password: password)
        case noAcceptable:
            throw TransportError.proxyRejected("no acceptable authentication method")
        default:
            throw TransportError.proxyRejected("unsupported auth method \(choice[1])")
        }

        try requestConnect(on: stream, host: host, port: port)
    }

    private static func authenticate(on stream: ByteStream,
                                     username: String, password: String) throws {
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count <= 255, pass.count <= 255 else {
            throw TransportError.proxyRejected("username or password exceeds 255 bytes")
        }
        // RFC 1929 is its own sub-negotiation with its own version byte (0x01).
        try stream.write([0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
        let reply = try stream.readExactly(2)
        guard reply[1] == 0x00 else {
            throw TransportError.proxyRejected("proxy refused the credentials")
        }
    }

    private static func requestConnect(on stream: ByteStream, host: String, port: UInt16) throws {
        var request: [UInt8] = [version, 0x01, 0x00]   // CONNECT, reserved

        // Hand the proxy the name when we have one: it resolves on the far
        // side, which is the whole point when the destination only exists
        // there.
        if let v4 = IPv4Address(host) {
            request += [0x01] + v4.octets
        } else {
            let name = Array(host.utf8)
            guard name.count <= 255 else {
                throw TransportError.proxyRejected("hostname exceeds 255 bytes")
            }
            request += [0x03, UInt8(name.count)] + name
        }
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        try stream.write(request)

        let head = try stream.readExactly(4)
        guard head[0] == version else {
            throw TransportError.proxyRejected("malformed reply")
        }
        guard head[1] == 0x00 else {
            throw TransportError.proxyRejected(replyMessage(head[1]))
        }
        // Drain the bound address so the descriptor starts clean.
        switch head[3] {
        case 0x01: _ = try stream.readExactly(4 + 2)
        case 0x04: _ = try stream.readExactly(16 + 2)
        case 0x03:
            let length = try stream.readExactly(1)[0]
            _ = try stream.readExactly(Int(length) + 2)
        default:
            throw TransportError.proxyRejected("unknown address type \(head[3])")
        }
    }

    static func replyMessage(_ code: UInt8) -> String {
        switch code {
        case 0x01: "general SOCKS server failure"
        case 0x02: "connection not allowed by ruleset"
        case 0x03: "network unreachable"
        case 0x04: "host unreachable"
        case 0x05: "connection refused"
        case 0x06: "TTL expired"
        case 0x07: "command not supported"
        case 0x08: "address type not supported"
        default:   "reply code \(code)"
        }
    }
}

/// Just enough parsing to tell a literal from a name.
struct IPv4Address {
    let octets: [UInt8]
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets = [UInt8]()
        for part in parts {
            guard let value = UInt8(part), String(value) == part else { return nil }
            octets.append(value)
        }
        self.octets = octets
    }
}
