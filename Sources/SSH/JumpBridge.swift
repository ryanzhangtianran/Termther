import Darwin
import Foundation
import Net

extension SSHSession {
    /// Opens a channel to `host:port` and returns it as an ordinary descriptor.
    ///
    /// libssh2 can only be handed a real socket, and a channel is not one. A
    /// socketpair bridges them: bytes are pumped between the channel and one
    /// end, and the other end is a plain BSD socket that
    /// `libssh2_session_handshake()` accepts without knowing anything unusual
    /// happened. The same adapter serves the campus VPN's userspace TCP stack.
    ///
    /// The splice runs both directions in a single non-suspending turn,
    /// because libssh2 tolerates concurrent work across channels but not
    /// within one.
    ///
    /// `ownsSession` hands this session to the bridge: it is kept alive while
    /// the bridge runs and disconnected when it ends. A jump host's outer
    /// session exists for the bridge alone, and nothing else holds it.
    public func bridgeDirectTCPIP(host: String, port: UInt16,
                                  ownsSession: Bool = false) async throws -> Int32 {
        let channel = try await openDirectTCPIP(host: host, port: port)
        let pair = try SocketPairBridge.make()

        Task.detached { [self] in
            // The socket pair holds a few kilobytes; what does not fit waits
            // in the splice rather than being dropped.
            await splice(channel, with: pair.local, limit: 256 * 1024)
            if ownsSession { await disconnect() }
        }

        return pair.remote
    }
}
