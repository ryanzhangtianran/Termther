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
    public func bridgeDirectTCPIP(host: String, port: UInt16) async throws -> Int32 {
        let channel = try await openDirectTCPIP(host: host, port: port)
        let pair = try SocketPairBridge.make()

        Task.detached { [weak self] in
            defer { Darwin.close(pair.local) }
            _ = fcntl(pair.local, F_SETFL, fcntl(pair.local, F_GETFL, 0) | O_NONBLOCK)

            var pending = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)

            while let session = self {
                // Take whatever the inner session wants to send.
                let read = buffer.withUnsafeMutableBytes {
                    Darwin.read(pair.local, $0.baseAddress, $0.count)
                }
                if read > 0 { pending += buffer[0..<read] }
                if read == 0 { break }

                guard let turn = try? await session.pump(channel, sending: pending.prefix(32 * 1024))
                else { break }
                if turn.isFinished { break }
                if turn.sent > 0 { pending.removeFirst(turn.sent) }

                if !turn.received.isEmpty {
                    var offset = 0
                    turn.received.withUnsafeBytes { raw in
                        while offset < raw.count {
                            let n = Darwin.write(pair.local,
                                                 raw.baseAddress!.advanced(by: offset),
                                                 raw.count - offset)
                            if n <= 0 { break }
                            offset += n
                        }
                    }
                }

                if turn.isIdle && read <= 0 {
                    // Nothing moved either way; wait rather than spin.
                    await session.awaitActivity(timeout: 0.05)
                }
            }

            await self?.close(channel)
        }

        return pair.remote
    }
}
