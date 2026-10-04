import Foundation

/// An HTTP proxy used through the CONNECT verb.
public struct HTTPConnectTransport: SSHTransport {
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
        "HTTP CONNECT \(proxyHost):\(proxyPort) -> \(inner.pathDescription)"
    }

    public func connect(host: String, port: UInt16) async throws -> Int32 {
        let fd = try await inner.connect(host: proxyHost, port: proxyPort)
        do {
            let stream = FileDescriptorStream(fd: fd)
            try stream.write(Array(HTTPConnect.request(host: host, port: port,
                                                       username: username,
                                                       password: password).utf8))
            try HTTPConnect.checkResponse(try stream.readUntilHeaderEnd())
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}

public enum HTTPConnect {
    public static func request(host: String, port: UInt16,
                               username: String?, password: String?) -> String {
        let authority = "\(host):\(port)"
        var lines = [
            "CONNECT \(authority) HTTP/1.1",
            "Host: \(authority)",
            "Proxy-Connection: Keep-Alive",
        ]
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    public static func checkResponse(_ response: String) throws {
        guard let statusLine = response.split(separator: "\r\n").first else {
            throw TransportError.proxyRejected("empty response")
        }
        let fields = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count >= 2, let status = Int(fields[1]) else {
            throw TransportError.proxyRejected("malformed status line: \(statusLine)")
        }
        guard (200..<300).contains(status) else {
            throw TransportError.proxyRejected(String(statusLine))
        }
    }
}
