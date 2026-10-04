import Foundation
import Net
import SSH

/// One terminal's worth of bytes, wherever they come from.
///
/// A terminal does not care whether a shell is local or four hops away: it
/// needs bytes in, bytes out, and to be told when the window changed. Keeping
/// that to three operations is what lets the view be written once.
///
/// `onExit` is told whether the link was lost: true when the remote read
/// errored or the watchdog gave up on the server, false when the shell ended
/// of its own accord -- and always for a local shell, which has no link.
public protocol SessionIO: Sendable {
    func start(cols: UInt16, rows: UInt16,
               onOutput: @escaping @Sendable ([UInt8]) -> Void,
               onExit: @escaping @Sendable (_ lost: Bool) -> Void) async throws
    func send(_ bytes: [UInt8]) async
    func resize(cols: UInt16, rows: UInt16) async
    func stop() async
    /// True while the shell itself has the terminal -- at its prompt, rather
    /// than running a program that would take typed text as keystrokes. Nil
    /// when that cannot be told.
    func isAtPrompt() async -> Bool?
    /// What the connection has carried, for a bandwidth readout; nil for a
    /// session with no connection to count.
    func traffic() async -> TrafficCounter?
}

public extension SessionIO {
    func traffic() async -> TrafficCounter? { nil }
}

// MARK: - local

extension LocalShell: SessionIO {
    public func start(cols: UInt16, rows: UInt16,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (_ lost: Bool) -> Void) async throws {
        try start(cols: cols, rows: rows,
                  extraEnvironment: environmentForNewShells,
                  onOutput: onOutput, onExit: { onExit(false) })
    }

    /// What a new local shell should start with, beyond what it inherits.
    ///
    /// Set on the type rather than passed in, because the terminal that opens
    /// it goes through `SessionIO`, which is deliberately three operations
    /// wide and has nowhere to carry a setting.
    public nonisolated(unsafe) static var newShellEnvironment: [String: String] = [:]
    private var environmentForNewShells: [String: String] { Self.newShellEnvironment }
    public func send(_ bytes: [UInt8]) async { write(bytes) }
    public func resize(cols: UInt16, rows: UInt16) async {
        // Disambiguated: the protocol requirement and the pty call share a name.
        setWindowSize(cols: cols, rows: rows)
    }
    public func stop() async { terminate() }

    public func isAtPrompt() async -> Bool? {
        guard let pid = processID, primaryFD >= 0 else { return nil }
        // forkpty made the shell its own process group, which holds the
        // terminal until the shell hands it to a job.
        return tcgetpgrp(primaryFD) == pid
    }
}

// MARK: - remote

/// A shell on an SSH server, reached over any transport.
public actor RemoteShell: SessionIO {
    public struct Destination: Sendable {
        public var host: String
        public var port: UInt16
        public var login: Connector.Login
        /// Run instead of a plain login shell. Used to hand the terminal a
        /// prepared environment -- see `ProxyEnvironment`.
        public var shellCommand: String?

        public init(host: String, port: UInt16 = 22, login: Connector.Login,
                    shellCommand: String? = nil) {
            self.host = host
            self.port = port
            self.login = login
            self.shellCommand = shellCommand
        }
    }

    private let destination: Destination
    private let transport: any SSHTransport
    private let session = SSHSession()
    private var shell: SSHSession.Shell?
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Set once the link, rather than the shell, is known to be gone.
    private var lost = false

    public init(_ destination: Destination, over transport: any SSHTransport = DirectTransport()) {
        self.destination = destination
        self.transport = transport
    }

    /// What the connection has carried, for a bandwidth readout.
    public func traffic() async -> TrafficCounter? { session.traffic }

    public func start(cols: UInt16, rows: UInt16,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (_ lost: Bool) -> Void) async throws {
        try await session.connect(to: destination.host, port: destination.port, over: transport)
        try await session.authenticate(destination.login)

        let shell = try await session.openShell(cols: cols, rows: rows,
                                                command: destination.shellCommand)
        self.shell = shell
        // The window may have changed while this connected; the server
        // hears the size it is now, not the one it started with.
        if let size = latestSize, size != (cols, rows) {
            try? await session.resize(shell, cols: size.cols, rows: size.rows)
        }

        pump = Task {
            do {
                for try await chunk in await session.output(shell) { onOutput(chunk) }
            } catch {
                // A shell that ends reaches EOF; a connection that drops
                // errors the read; `stop` cancels it. The watchdog's
                // disconnect can look like any of these, so it says so itself.
                if !Task.isCancelled { lost = true }
            }
            onExit(lost)
        }

        // A link that died quietly -- a VPN gone, a network left -- never
        // errors the socket, and a shell read waits for ever. So the server
        // is asked for a reply every so often, and one not back in time ends
        // the session, as a plain disconnect would.
        await session.enableKeepalive(every: 20)
        watchdog = Task { [session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                let before = session.traffic.statistics.bytesIn
                guard await session.sendKeepalive() != nil else { return }
                try? await Task.sleep(for: .seconds(15))
                if session.traffic.statistics.bytesIn == before {
                    lost = true
                    await session.disconnect()
                    return
                }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async {
        guard let shell else { return }
        try? await session.write(shell, bytes)
    }

    /// The newest size asked for, kept while there is no shell to give it
    /// to yet. Dropped before, a window laid out or resized during the
    /// connection left the server a smaller screen than the one shown: its
    /// full-screen programs paged early, with blank rows below.
    private var latestSize: (cols: UInt16, rows: UInt16)?

    public func resize(cols: UInt16, rows: UInt16) async {
        latestSize = (cols, rows)
        guard let shell else { return }
        try? await session.resize(shell, cols: cols, rows: rows)
    }

    /// Asked on a channel of its own. sshd's children on this connection are
    /// the shell and the probe, and the shell is at its prompt while its own
    /// process group holds its terminal.
    public func isAtPrompt() async -> Bool? {
        guard shell != nil, let result = try? await session.exec(Self.foregroundProbe)
        else { return nil }
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil  // no ps, an unusual sshd: unknown, so not typed into
        }
    }

    /// `exec sh` keeps sshd as the parent and gives a known syntax: the
    /// account's shell may be fish, which has no `$$`. Where `ps` cannot list
    /// `tpgid` -- BusyBox, on small Linux systems -- `/proc` says the same:
    /// the eighth field of `stat`, counted from after the command name, which
    /// may itself hold spaces. The first shell found answers.
    static let foregroundProbe = #"exec sh -c 'me=$$; up=$PPID; { ps -A -o pid= -o ppid= -o tpgid= 2>/dev/null || for f in /proc/[0-9]*/stat; do IFS= read -r l < "$f" 2>/dev/null || continue; p=${f#/proc/}; set -- ${l##*) }; echo "${p%/stat} $2 $6"; done; } | awk -v me="$me" -v up="$up" "\$2 == up && \$1 != me && \$3 > 0 { print (\$1 == \$3); exit }"'"#

    public func stop() async {
        // Waited for, not just cancelled: cancellation is cooperative, and
        // tearing the session down while the pump is still inside libssh2 is
        // what turned closing a tab into a crash.
        watchdog?.cancel()
        pump?.cancel()
        _ = await pump?.value
        pump = nil
        await session.disconnect()
        shell = nil
    }
}
