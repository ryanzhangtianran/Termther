import Darwin
import Foundation

/// A plain TCP dial.
public struct DirectTransport: SSHTransport {
    /// Bind outbound sockets to this interface (e.g. "en1").
    ///
    /// A local TUN proxy -- Surge, Clash, sing-box -- installs a default route
    /// through a utun device, so by default every socket this process opens is
    /// intercepted. Naming a physical interface escapes that.
    public var interfaceName: String?

    public init(interfaceName: String? = nil) {
        self.interfaceName = interfaceName
    }

    public var pathDescription: String {
        interfaceName.map { "direct via \($0)" } ?? "direct"
    }

    public func connect(host: String, port: UInt16) async throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &head) == 0, head != nil else {
            throw TransportError.resolve(host: host)
        }
        defer { freeaddrinfo(head) }

        var lastReason = "no addresses"
        var candidate = head
        while let info = candidate {
            defer { candidate = info.pointee.ai_next }

            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd < 0 { lastReason = String(cString: strerror(errno)); continue }

            if let name = interfaceName, !name.isEmpty {
                do { try bindToInterface(fd: fd, name: name, family: info.pointee.ai_family) }
                catch { close(fd); throw error }
            }

            if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            lastReason = String(cString: strerror(errno))
            close(fd)
        }
        throw TransportError.connect(host: host, port: port, reason: lastReason)
    }

    private func bindToInterface(fd: Int32, name: String, family: Int32) throws {
        let index = if_nametoindex(name)
        guard index != 0 else { throw TransportError.io("no such interface: \(name)") }
        var scope = Int32(index)
        // IP_BOUND_IF / IPV6_BOUND_IF are the Darwin way to pin a socket to an
        // interface without root; SO_BINDTODEVICE is the Linux equivalent.
        let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
        let option = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
        guard setsockopt(fd, level, option, &scope, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TransportError.io("cannot bind to \(name): \(String(cString: strerror(errno)))")
        }
    }
}
