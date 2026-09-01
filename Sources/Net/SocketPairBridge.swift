import Darwin
import Foundation

/// Turns a byte stream that is not a file descriptor into one that is.
///
/// This is the adapter that makes the whole `SSHTransport` idea hold together.
/// Two things in Termther produce bytes without producing a socket -- a jump
/// host's `direct-tcpip` channel, and the campus VPN's userspace TCP/IP stack
/// -- and libssh2 can only be handed a real descriptor. A `socketpair` bridges
/// them: one end is pumped against the stream, the other is an ordinary BSD
/// socket that `libssh2_session_handshake()` accepts unmodified.
///
/// The cost is one extra copy and a kernel round trip per packet, which is
/// irrelevant next to an SSH session's own overhead, and it buys a single
/// uniform seam instead of a special case per source.
public enum SocketPairBridge {
    /// Creates a connected pair. The caller keeps `local` to pump and hands
    /// `remote` to whoever wants a descriptor.
    public static func make() throws -> (local: Int32, remote: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw TransportError.io("socketpair: \(String(cString: strerror(errno)))")
        }
        return (fds[0], fds[1])
    }
}
