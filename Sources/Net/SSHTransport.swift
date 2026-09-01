import Foundation

/// Anything that can produce a connected file descriptor.
///
/// This is the seam the whole networking story hangs off: a direct dial, a
/// SOCKS5 or HTTP CONNECT proxy, a jump host, or the campus VPN all end up
/// handing back an ordinary BSD socket. Nothing above this protocol -- libssh2
/// least of all -- can tell which one it got.
///
/// The returned descriptor is **blocking** and owned by the caller, who is
/// responsible for closing it. Callers that need non-blocking IO set
/// `O_NONBLOCK` themselves once any handshaking is done.
public protocol SSHTransport: Sendable {
    func connect(host: String, port: UInt16) async throws -> Int32

    /// Shown in diagnostics, e.g. "SOCKS5 127.0.0.1:1080 -> direct".
    var pathDescription: String { get }
}

public enum TransportError: Error, CustomStringConvertible, Equatable {
    case resolve(host: String)
    case connect(host: String, port: UInt16, reason: String)
    case io(String)
    case proxyRejected(String)
    case truncated(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .resolve(let h):              return "cannot resolve \(h)"
        case .connect(let h, let p, let r): return "connect \(h):\(p): \(r)"
        case .io(let m):                    return "io: \(m)"
        case .proxyRejected(let m):         return "proxy rejected the request: \(m)"
        case .truncated(let e, let g):      return "short read: wanted \(e) bytes, got \(g)"
        }
    }
}
