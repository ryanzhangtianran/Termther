import CSSH2
import Foundation

extension SSHSession {
    /// An open interactive shell on this session.
    ///
    /// A handle rather than a pointer, so the channel stays inside the actor
    /// that serialises libssh2 and callers cannot use it after it closes.
    public struct Shell: Sendable, Hashable {
        let id: Int
    }

    /// Opens a shell on a pseudo-terminal.
    ///
    /// The pty is what makes it interactive: without one, programs see a pipe,
    /// suppress colour, line-buffer their output and refuse to run full-screen.
    /// `term` is the capability name the far end will trust, so it must match
    /// what the emulator actually implements.
    /// `command` replaces the plain login shell, on the same pty.
    ///
    /// sshd runs it through the account's own shell, so it is the way to set
    /// something up before handing the terminal over -- environment variables,
    /// most usefully. A command that ends with `exec "$SHELL" -l` is still an
    /// ordinary interactive login as far as the user is concerned.
    public func openShell(term: String = "xterm-256color",
                          cols: UInt16 = 80, rows: UInt16 = 24,
                          command: String? = nil) async throws -> Shell {
        let session = try requireSession()
        let channel = try await retryPointer("channel_open") {
            libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
        }

        do {
            try await retry("request_pty") {
                libssh2_channel_request_pty_ex(
                    channel, term, UInt32(term.utf8.count),
                    nil, 0,
                    Int32(cols), Int32(rows), 0, 0)
            }
            if let command {
                try await retry("channel_exec") {
                    libssh2_channel_process_startup(channel, "exec", 4,
                                                    command, UInt32(command.utf8.count))
                }
            } else {
                try await retry("channel_shell") {
                    libssh2_channel_process_startup(channel, "shell", 5, nil, 0)
                }
            }
        } catch {
            libssh2_channel_free(channel)
            throw error
        }

        let shell = Shell(id: nextShellID)
        nextShellID += 1
        shells[shell] = channel
        return shell
    }

    /// Reads whatever the far end has sent, waiting if nothing has arrived yet.
    /// An empty result means the shell ended.
    public func read(_ shell: Shell) async throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            // Re-fetched every time round, because every `await` below is a
            // point at which `disconnect` can run and free this channel.
            // Holding the pointer across a suspension is a use-after-free that
            // takes the whole app down when a tab is closed.
            guard let channel = shells[shell] else { return [] }

            let n = buffer.withUnsafeMutableBytes { raw in
                libssh2_channel_read_ex(channel, 0,
                                        raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                        raw.count)
            }
            if n > 0 { return Array(buffer[0..<n]) }
            if n == 0 {
                // Zero means no data right now. Only EOF ends the stream; the
                // difference matters, because treating a quiet moment as EOF
                // would close a perfectly healthy shell.
                if libssh2_channel_eof(channel) == 1 { return [] }
                try await waitReadable(at: "channel_read")
                continue
            }
            if n == Int(LIBSSH2_ERROR_EAGAIN) {
                try await waitReady(libssh2_session_block_directions(session), at: "channel_read")
                continue
            }
            throw error(Int32(n), at: "channel_read")
        }
    }

    /// A stream of everything the shell prints, ending when the shell does.
    public func output(_ shell: Shell) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let chunk = try await self.read(shell)
                        if chunk.isEmpty { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ shell: Shell, _ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            guard let channel = shells[shell] else { return }
            let written = try await retryInt("channel_write") {
                bytes.withUnsafeBytes { raw in
                    libssh2_channel_write_ex(
                        channel, 0,
                        raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                        raw.count - offset)
                }
            }
            // A partial write is normal: the channel window fills and the rest
            // goes out once the far end acknowledges.
            offset += written
        }
    }

    /// Tells the far end the window changed, which is what makes SIGWINCH fire
    /// and full-screen programs redraw.
    public func resize(_ shell: Shell, cols: UInt16, rows: UInt16) async throws {
        guard let channel = shells[shell] else { return }
        try await retry("pty_size") {
            libssh2_channel_request_pty_size_ex(channel, Int32(cols), Int32(rows), 0, 0)
        }
    }

    public func close(_ shell: Shell) async {
        guard let channel = shells.removeValue(forKey: shell) else { return }
        _ = try? await retry("channel_close") { libssh2_channel_close(channel) }
        libssh2_channel_free(channel)
    }
}
