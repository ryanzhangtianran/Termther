import CSSH2
import Foundation

extension SSHSession {
    /// A TCP connection made by the server on our behalf: `direct-tcpip`.
    ///
    /// This is the primitive under both port forwarding and jump hosts. For a
    /// jump host the channel is bridged onto a socketpair and handed to a
    /// second session, which then has no idea it is nested.
    public struct DirectChannel: Sendable, Hashable {
        let id: Int
    }

    /// Asks the server to connect to `host:port` and give us the stream.
    public func openDirectTCPIP(host: String, port: UInt16,
                                originHost: String = "127.0.0.1",
                                originPort: UInt16 = 0) async throws -> DirectChannel {
        let session = try requireSession()
        let raw = try await retryPointer("direct_tcpip") {
            libssh2_channel_direct_tcpip_ex(session,
                                            host, Int32(port),
                                            originHost, Int32(originPort))
        }
        let channel = DirectChannel(id: nextChannelID)
        nextChannelID += 1
        directChannels[channel] = raw
        return channel
    }

    /// What one turn of the pump did.
    public struct Turn: Sendable {
        /// Bytes received from the far end this turn.
        public var received: [UInt8] = []
        /// Bytes of the pending buffer the channel accepted this turn.
        public var sent = 0
        /// The far end closed.
        public var isFinished = false
        /// Neither direction made progress; the caller should wait.
        public var isIdle: Bool { received.isEmpty && sent == 0 && !isFinished }
    }

    /// Moves a tunnel one step in both directions.
    ///
    /// Read and write happen here, together, with no suspension between them.
    /// That is the whole point: libssh2 permits concurrent work on *different*
    /// channels, but a read and a write interleaved on the *same* channel
    /// corrupt it -- a read that parks on EAGAIN leaves the channel mid-
    /// operation, and a write slipping in crashes inside
    /// `_libssh2_transport_send` when the window adjustment that follows a read
    /// runs against changed state.
    ///
    /// Because this function never awaits, the actor cannot be re-entered while
    /// it runs, which is what makes that impossible by construction.
    public func pump(_ channel: DirectChannel, sending pending: ArraySlice<UInt8>) throws -> Turn {
        guard let raw = directChannels[channel] else {
            return Turn(received: [], sent: 0, isFinished: true)
        }
        var turn = Turn()

        if !pending.isEmpty {
            let written = pending.withUnsafeBytes { region in
                libssh2_channel_write_ex(
                    raw, 0,
                    region.baseAddress!.assumingMemoryBound(to: CChar.self),
                    region.count)
            }
            if written > 0 {
                turn.sent = written
            } else if written != Int(LIBSSH2_ERROR_EAGAIN) && written < 0 {
                throw error(Int32(written), at: "channel_write")
            }
        }

        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let n = buffer.withUnsafeMutableBytes { region in
            libssh2_channel_read_ex(raw, 0,
                                    region.baseAddress!.assumingMemoryBound(to: CChar.self),
                                    region.count)
        }
        if n > 0 {
            turn.received = Array(buffer[0..<n])
        } else if n == 0 {
            // Zero means "nothing right now"; only EOF ends the stream.
            if libssh2_channel_eof(raw) == 1 { turn.isFinished = true }
        } else if n != Int(LIBSSH2_ERROR_EAGAIN) {
            throw error(Int32(n), at: "channel_read")
        }

        return turn
    }

    /// Waits until the session's socket has something to say, so an idle pump
    /// costs nothing. False means the wait expired with nothing to read.
    ///
    /// Expiring is not a failure, and saying so matters: a tunnel carrying a
    /// keep-alive HTTP connection is silent for minutes at a time, and an
    /// earlier version treated that silence as an error and closed it. The
    /// timeout is the caller's polling interval, not a deadline for the
    /// connection.
    @discardableResult
    public func awaitActivity(timeout: TimeInterval = 30) async -> Bool {
        do {
            try await waitReady(Int32(LIBSSH2_SESSION_BLOCK_INBOUND),
                                at: "pump_idle", timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// Reads from the channel, waiting if nothing has arrived. Empty means the
    /// far end closed.
    public func read(_ channel: DirectChannel) async throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            // Re-fetched after every suspension: `disconnect` frees channels,
            // and a pointer held across an `await` becomes a use-after-free.
            guard let raw = directChannels[channel] else { return [] }

            let n = buffer.withUnsafeMutableBytes { region in
                libssh2_channel_read_ex(raw, 0,
                                        region.baseAddress!.assumingMemoryBound(to: CChar.self),
                                        region.count)
            }
            if n > 0 { return Array(buffer[0..<n]) }
            if n == 0 {
                // Zero means "nothing right now"; only EOF ends the stream.
                if libssh2_channel_eof(raw) == 1 { return [] }
                try await waitReadable(at: "direct_read")
                continue
            }
            if n == Int(LIBSSH2_ERROR_EAGAIN) {
                try await waitReady(libssh2_session_block_directions(session), at: "direct_read")
                continue
            }
            throw error(Int32(n), at: "direct_read")
        }
    }

    public func write(_ channel: DirectChannel, _ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            guard let raw = directChannels[channel] else { return }
            let written = try await retryInt("direct_write") {
                bytes.withUnsafeBytes { region in
                    libssh2_channel_write_ex(
                        raw, 0,
                        region.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                        region.count - offset)
                }
            }
            offset += written
        }
    }

    public func close(_ channel: DirectChannel) async {
        guard let raw = directChannels.removeValue(forKey: channel) else { return }
        _ = try? await retry("direct_close") { libssh2_channel_close(raw) }
        libssh2_channel_free(raw)
    }
}
