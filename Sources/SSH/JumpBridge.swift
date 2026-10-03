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
    /// The pump runs both directions in a single non-suspending turn, because
    /// libssh2 tolerates concurrent work across channels but not within one.
    ///
    /// `ownsSession` hands this session to the bridge: it is kept alive while
    /// the bridge runs and disconnected when it ends. A jump host's outer
    /// session exists for the bridge alone, and nothing else holds it.
    public func bridgeDirectTCPIP(host: String, port: UInt16,
                                  ownsSession: Bool = false) async throws -> Int32 {
        let channel = try await openDirectTCPIP(host: host, port: port)
        let pair = try SocketPairBridge.make()

        Task.detached { [self] in
            defer { Darwin.close(pair.local) }
            _ = fcntl(pair.local, F_SETFL, fcntl(pair.local, F_GETFL, 0) | O_NONBLOCK)

            // Both directions are buffered, and each is only filled while the
            // other side keeps up: the socket pair holds a few kilobytes, and
            // what does not fit waits here rather than being dropped.
            let limit = 256 * 1024
            var toChannel = [UInt8]()
            var toLocal = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)

            loop: while true {
                var read = 0
                if toChannel.count < limit {
                    read = buffer.withUnsafeMutableBytes {
                        Darwin.read(pair.local, $0.baseAddress, $0.count)
                    }
                    if read > 0 { toChannel += buffer[0..<read] }
                    if read == 0 { break }
                }

                guard let turn = try? await pump(channel, sending: toChannel.prefix(32 * 1024),
                                                 receiving: toLocal.count < limit)
                else { break }
                if turn.isFinished { break }
                if turn.sent > 0 { toChannel.removeFirst(turn.sent) }
                toLocal += turn.received

                var wrote = 0
                while !toLocal.isEmpty {
                    let n = toLocal.withUnsafeBytes {
                        Darwin.write(pair.local, $0.baseAddress, $0.count)
                    }
                    if n > 0 { toLocal.removeFirst(n); wrote += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 && errno == EAGAIN { break }
                    break loop  // the inner session is gone
                }

                if turn.isIdle && read <= 0 && wrote == 0 {
                    if toLocal.isEmpty {
                        // Nothing moved either way; wait rather than spin.
                        await awaitActivity(timeout: 0.05)
                    } else {
                        // The inner session is behind; give it a moment to read.
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
            }

            await close(channel)
            if ownsSession { await disconnect() }
        }

        return pair.remote
    }
}
