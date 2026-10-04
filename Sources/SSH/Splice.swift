import Darwin
import Dispatch
import Net

extension SSHSession {
    /// Copies bytes both ways between `channel` and the local socket `local`
    /// until either side finishes, then closes both. A forwarded client and
    /// a jump host's socket pair are joined here alike.
    ///
    /// One loop, not two tasks. libssh2 tolerates concurrent work across
    /// channels but not within one, so both directions are advanced together
    /// in a single call that never suspends midway.
    ///
    /// The local socket is read and written here too, without blocking.
    /// Each direction is buffered up to `limit` and only read while below it,
    /// so a fast sender and a slow receiver -- either way round -- cannot
    /// hold a whole transfer in memory. A local side that closes its sending
    /// half (`nc -N`, a plain HTTP/1.0 request) is passed on as EOF on the
    /// channel, and the answer still comes back to it; what the far end sent
    /// before it finished is delivered before the socket is closed.
    ///
    /// `counting` hears the bytes sent and received each turn, on the
    /// caller's actor.
    func splice(_ channel: DirectChannel, with local: Int32, limit: Int,
                            isolation: isolated (any Actor)? = #isolation,
                            counting: (_ sent: Int, _ received: Int) -> Void = { _, _ in }) async {
        SocketOptions.setBlocking(local, false)
        // Closed once the readiness sources on it are gone, never before.
        let sources = DispatchGroup()
        defer { sources.notify(queue: .global()) { Darwin.close(local) } }

        var toChannel = ByteQueue()
        var toLocal = ByteQueue()
        var localSentAll = false
        var eofSent = false
        var serverDone = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        loop: while true {
            var moved = false

            if !localSentAll && toChannel.count < limit {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(local, $0.baseAddress, $0.count) }
                if n > 0 {
                    toChannel.append(buffer[0..<n])
                    moved = true
                } else if n == 0 {
                    localSentAll = true
                    moved = true
                } else if errno != EAGAIN && errno != EINTR {
                    break   // reset by the local side
                }
            }

            if !serverDone {
                guard let turn = try? await pump(channel, sending: toChannel.peek(256 * 1024),
                                                 budget: min(limit - toLocal.count, 256 * 1024))
                else { break }
                if turn.sent > 0 || !turn.received.isEmpty {
                    toChannel.consume(turn.sent)
                    toLocal.append(turn.received)
                    counting(turn.sent, turn.received.count)
                    moved = true
                }
                if turn.isFinished { serverDone = true }
            }

            while toLocal.count > 0 {
                let n = toLocal.peek(64 * 1024).withUnsafeBytes {
                    Darwin.write(local, $0.baseAddress, $0.count)
                }
                if n > 0 { toLocal.consume(n); moved = true; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { break }
                break loop   // the local side has gone
            }

            // The server has finished and all of it has been delivered.
            if serverDone && toLocal.count == 0 { break }
            // All the local side will send has gone out: the server hears
            // EOF, and still gets to answer.
            if localSentAll && toChannel.count == 0 && !eofSent {
                eofSent = true
                try? await sendEOF(channel)
            }

            if !moved {
                // Nothing moved: wait for either socket rather than spinning.
                // The local one only in a direction there is room for, or a
                // socket at EOF or a full buffer would wake it at once.
                await awaitActivity(timeout: 0.05, local: LocalWatch(
                    fd: local, readable: !localSentAll && toChannel.count < limit,
                    writable: toLocal.count > 0, sources: sources))
            }
        }

        await close(channel)
    }
}
