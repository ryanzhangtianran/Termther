import Foundation
import Net
import SSH

/// One terminal's worth of bytes, wherever they come from.
///
/// A terminal does not care whether a shell is local or four hops away: it
/// needs bytes in, bytes out, and to be told when the window changed. Keeping
/// that to three operations is what lets the view be written once.
public protocol SessionIO: Sendable {
    func start(cols: UInt16, rows: UInt16,
               onOutput: @escaping @Sendable ([UInt8]) -> Void,
               onExit: @escaping @Sendable () -> Void) async throws
    func send(_ bytes: [UInt8]) async
    func resize(cols: UInt16, rows: UInt16) async
    func stop() async
}

// MARK: - local

extension LocalShell: SessionIO {
    public func start(cols: UInt16, rows: UInt16,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable () -> Void) async throws {
        try start(command: nil, cols: cols, rows: rows,
                  extraEnvironment: environmentForNewShells,
                  onOutput: onOutput, onExit: onExit)
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

    public init(_ destination: Destination, over transport: any SSHTransport = DirectTransport()) {
        self.destination = destination
        self.transport = transport
    }

    /// The server's host key, for the caller to check against what it trusts.
    public private(set) var hostKeyFingerprint: String?

    public func start(cols: UInt16, rows: UInt16,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable () -> Void) async throws {
        try await session.connect(to: destination.host, port: destination.port, over: transport)
        hostKeyFingerprint = await session.hostKeyFingerprint()
        try await session.authenticate(destination.login)

        let shell = try await session.openShell(cols: cols, rows: rows,
                                                command: destination.shellCommand)
        self.shell = shell

        pump = Task {
            do {
                for try await chunk in await session.output(shell) { onOutput(chunk) }
            } catch {
                // The shell ending and the connection dropping look the same
                // from here; both mean this session is over.
            }
            onExit()
        }
    }

    public func send(_ bytes: [UInt8]) async {
        guard let shell else { return }
        try? await session.write(shell, bytes)
    }

    public func resize(cols: UInt16, rows: UInt16) async {
        guard let shell else { return }
        try? await session.resize(shell, cols: cols, rows: rows)
    }

    public func stop() async {
        // Waited for, not just cancelled: cancellation is cooperative, and
        // tearing the session down while the pump is still inside libssh2 is
        // what turned closing a tab into a crash.
        pump?.cancel()
        _ = await pump?.value
        pump = nil
        await session.disconnect()
        shell = nil
    }
}
