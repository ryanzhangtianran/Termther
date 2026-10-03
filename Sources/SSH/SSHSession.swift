// libssh2 driven from Swift structured concurrency.
//
// libssh2 in non-blocking mode is a synchronous API that returns
// LIBSSH2_ERROR_EAGAIN when it cannot make progress, plus
// libssh2_session_block_directions() telling you which way the socket has to
// become ready. Swift wants `await`. The whole adaptation is one function --
// `retry` -- so the EAGAIN state machine never leaks into call sites.
//
// One actor per session gives the serialisation libssh2 requires (a session is
// not thread-safe). Reentrancy at `await` points is fine and in fact wanted:
// two channels on one session interleave there, and each has already recorded
// its own block direction before suspending.

import Darwin
import Dispatch
import Foundation
import CSSH2
import Net

/// libssh2's initialisation is global, not per session.
///
/// Calling `libssh2_init` per session is harmless, but the matching
/// `libssh2_exit` tears down state every other session is still using -- so
/// closing one tab would take every other connection with it, from inside C.
/// A Swift global is initialised exactly once and never torn down, which is
/// what this library actually wants.
private let libssh2IsInitialized: Bool = {
    libssh2_init(0) == 0
}()

public enum SSHError: Error, CustomStringConvertible {
    case socket(String)
    case libssh2(code: Int32, message: String, at: String)
    case timedOut(String)
    case auth(String)

    public var description: String {
        switch self {
        case .socket(let m):                   return "socket: \(m)"
        case .libssh2(let c, let m, let at):    return "\(at): libssh2 error \(c): \(m)"
        case .timedOut(let at):                 return "\(at): timed out"
        case .auth(let m):                      return "authentication failed: \(m)"
        }
    }
}

/// Decides whether a server's host key is the one to trust.
///
/// Every connection passes through `SSHSession.connect` -- jump hosts, the
/// proxy tunnel, key installs -- so the key is checked there, once, before a
/// password or key is offered. The app installs a check backed by its store at
/// launch. Until something is installed nothing is checked, which is what
/// tests and one-off tools get.
public enum HostKeyCheck {
    public typealias Verify = @Sendable (_ host: String, _ port: UInt16, _ fingerprint: String) async throws -> Void

    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var verify: Verify?
    }
    private static let slot = Slot()

    public static func install(_ verify: Verify?) { slot.lock.withLock { slot.verify = verify } }
    static var installed: Verify? { slot.lock.withLock { slot.verify } }
}

/// Resumes exactly once, from whichever readiness source fires first, and
/// tears the others down. Finishing it before it has begun -- a task already
/// cancelled -- is kept and delivered when it does.
private final class ReadinessWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var sources: [DispatchSourceProtocol] = []
    private var result: Result<Void, Error>?

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func arm(_ built: [DispatchSourceProtocol]) {
        lock.lock()
        // If something already fired we must not resume these; cancel instead.
        guard result == nil else { lock.unlock(); built.forEach { $0.activate(); $0.cancel() }; return }
        sources = built
        lock.unlock()
        built.forEach { $0.activate() }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let c = continuation
        continuation = nil
        let toCancel = sources
        sources = []
        lock.unlock()
        toCancel.forEach { $0.cancel() }
        c?.resume(with: result)
    }
}

/// Every byte a session has put on and taken off the wire, encryption and
/// all. Counted where libssh2 calls the socket, so each channel on the
/// session -- shell, forwards, files -- is in it.
public final class TrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var totals = PortForward.Statistics()

    public var statistics: PortForward.Statistics { lock.withLock { totals } }

    fileprivate func add(in count: Int) { lock.withLock { totals.bytesIn += UInt64(count) } }
    fileprivate func add(out count: Int) { lock.withLock { totals.bytesOut += UInt64(count) } }

    fileprivate static func from(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?)
        -> TrafficCounter? {
        abstract?.pointee.map { Unmanaged<TrafficCounter>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// libssh2's own socket calls, counted. Errors as libssh2 wants them:
/// negated errno, with an interrupted or would-block call as EAGAIN.
private func socketResult(_ count: Int) -> Int {
    guard count < 0 else { return count }
    let error = errno
    return error == EINTR || error == EWOULDBLOCK ? -Int(EAGAIN) : -Int(error)
}

nonisolated(unsafe) private let countedSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32,
                                         UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int
    = { socket, buffer, length, flags, abstract in
        let sent = socketResult(Darwin.send(socket, buffer, length, flags))
        if sent > 0 { TrafficCounter.from(abstract)?.add(out: sent) }
        return sent
    }

nonisolated(unsafe) private let countedReceive: @convention(c) (Int32, UnsafeMutableRawPointer?, Int, Int32,
                                            UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int
    = { socket, buffer, length, flags, abstract in
        let received = socketResult(Darwin.recv(socket, buffer, length, flags))
        if received > 0 { TrafficCounter.from(abstract)?.add(in: received) }
        return received
    }

public actor SSHSession {
    /// What this session has carried so far; readable from anywhere.
    public nonisolated let traffic = TrafficCounter()
    private let ioQueue = DispatchQueue(label: "termther.ssh.io")
    private var fd: Int32 = -1
    var session: OpaquePointer?

    var shells: [Shell: OpaquePointer] = [:]
    var nextShellID = 0
    var directChannels: [DirectChannel: OpaquePointer] = [:]
    var nextChannelID = 0
    var remoteListeners: [RemoteListener: OpaquePointer] = [:]
    var nextListenerID = 0

    /// How long any single EAGAIN wait may block before giving up.
    private let readinessTimeout: TimeInterval

    /// Waits in progress, so `disconnect` can end them before it closes the
    /// descriptor they watch. Left to themselves they would wait out their
    /// timeout -- or, reading a quiet shell, for ever.
    private var waits: [ObjectIdentifier: ReadinessWait] = [:]

    /// How many times this session has been freed. An operation that
    /// suspends notes it first and gives up when it has moved on: the session
    /// and every channel on it are gone, and any pointer it held is dangling.
    private(set) var generation = 0

    public init(readinessTimeout: TimeInterval = 30) {
        self.readinessTimeout = readinessTimeout
    }

    // MARK: - the pump

    /// Suspends until the socket is ready in the direction libssh2 asked for.
    ///
    /// `timeout` overrides the session's own limit, for callers that are
    /// polling rather than waiting on one operation to finish; `.infinity`
    /// waits for as long as the connection lasts. Cancelling the task ends
    /// the wait, as does `disconnect`; either way it throws.
    func waitReady(_ directions: Int32, at what: String,
                   timeout: TimeInterval? = nil) async throws {
        let started = generation
        let wait = ReadinessWait()
        let key = ObjectIdentifier(wait)
        waits[key] = wait
        defer { waits[key] = nil }
        let limit = timeout ?? readinessTimeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                wait.begin(cont)
                var built: [DispatchSourceProtocol] = []

                if directions & Int32(LIBSSH2_SESSION_BLOCK_INBOUND) != 0 {
                    let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
                    s.setEventHandler { wait.finish(.success(())) }
                    built.append(s)
                }
                if directions & Int32(LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0 {
                    let s = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
                    s.setEventHandler { wait.finish(.success(())) }
                    built.append(s)
                }

                // libssh2 asking for neither direction means it wants to be called
                // again shortly; a short nap beats a spin.
                if built.isEmpty {
                    let nap = DispatchSource.makeTimerSource(queue: ioQueue)
                    nap.schedule(deadline: .now() + .milliseconds(5))
                    nap.setEventHandler { wait.finish(.success(())) }
                    built.append(nap)
                }

                if limit.isFinite {
                    let timer = DispatchSource.makeTimerSource(queue: ioQueue)
                    timer.schedule(deadline: .now() + limit)
                    timer.setEventHandler { wait.finish(.failure(SSHError.timedOut(what))) }
                    built.append(timer)
                }

                wait.arm(built)
            }
        } onCancel: {
            wait.finish(.failure(CancellationError()))
        }
        guard generation == started, session != nil else { throw Self.closed }
    }

    static let closed = SSHError.socket("the session was closed")

    /// Runs a libssh2 call that returns a status code or a byte count to
    /// completion across EAGAIN.
    ///
    /// `giveUpAfter` bounds the whole call, for teardown: a packet libssh2
    /// left half sent makes every other one report EAGAIN for good, and with
    /// the socket writable each wait returns at once, so a close would spin.
    @discardableResult
    func retry<Code: BinaryInteger>(_ what: String, giveUpAfter: TimeInterval? = nil,
                                    _ body: () -> Code) async throws -> Code {
        _ = try requireSession()
        let deadline = giveUpAfter.map { Date.now.addingTimeInterval($0) }
        while true {
            let rc = body()
            if rc >= 0 { return rc }
            if rc != Code(LIBSSH2_ERROR_EAGAIN) { throw error(Int32(rc), at: what) }
            if let deadline, Date.now > deadline { throw SSHError.timedOut(what) }
            // Must be read immediately after the EAGAIN, before any other
            // libssh2 call on this session.
            let directions = libssh2_session_block_directions(session)
            try await waitReady(directions, at: what)
        }
    }

    /// Same, for the calls that signal EAGAIN by returning NULL.
    func retryPointer(_ what: String, _ body: () -> OpaquePointer?) async throws -> OpaquePointer {
        let session = try requireSession()
        while true {
            if let p = body() { return p }
            let rc = libssh2_session_last_errno(session)
            if rc != LIBSSH2_ERROR_EAGAIN { throw error(rc, at: what) }
            let directions = libssh2_session_block_directions(session)
            try await waitReady(directions, at: what)
        }
    }

    func error(_ code: Int32, at what: String) -> SSHError {
        guard let session else { return .socket("the session is not connected") }
        var buf: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        libssh2_session_last_error(session, &buf, &len, 0)
        let message = buf.map { String(cString: $0) } ?? "(no message)"
        return .libssh2(code: code, message: message, at: what)
    }

    /// The live session, or an error.
    ///
    /// libssh2 does not tolerate a NULL session: passing one segfaults inside
    /// the library rather than returning an error. Every entry point that
    /// reaches C goes through here, so using a session that was never
    /// connected -- or has since been torn down -- is a thrown error instead of
    /// a crashed process.
    func requireSession() throws -> OpaquePointer {
        guard let session else { throw SSHError.socket("the session is not connected") }
        return session
    }

    /// Waits for the socket to be readable, for the case where libssh2 reports
    /// "no data" without an EAGAIN and therefore without a block direction.
    func waitReadable(at what: String) async throws {
        try await waitReady(Int32(LIBSSH2_SESSION_BLOCK_INBOUND), at: what)
    }

    // MARK: - lifecycle

    /// Opens a session over whatever descriptor `transport` produces.
    ///
    /// The session does not dial. Direct, proxied, jump-hosted and VPN paths
    /// all arrive here as an ordinary connected descriptor, so nothing below
    /// this line knows -- or can behave differently -- based on how the bytes
    /// get to the server.
    public func connect(to host: String, port: UInt16 = 22,
                        over transport: any SSHTransport = DirectTransport()) async throws {
        let descriptor = try await transport.connect(host: host, port: port)
        try adopt(descriptor)
        try await handshake()
        if let verify = HostKeyCheck.installed {
            guard let fingerprint = hostKeyFingerprint() else { throw SSHError.socket("the server sent no host key") }
            try await verify(host, port, fingerprint)
        }
    }

    /// Lets the kernel notice a peer that has gone quiet for good.
    ///
    /// After a sleep or a change of network the connection can look alive
    /// while nothing answers, and without this a write can sit for minutes
    /// before TCP gives up. Probing after 30 idle seconds, every 10, three
    /// times, turns that into about a minute -- then the socket errors and
    /// whatever supervises the session reconnects. The SSH keepalive cannot do
    /// this alone: libssh2 sends it but never says whether it was answered.
    ///
    /// Only for a real TCP socket. A descriptor bridged from a jump host or
    /// the VPN is a local socket pair; these options fail on it, harmlessly,
    /// and that route relies on the wake and network-change reconnects.
    static func enableTCPKeepalive(on fd: Int32) {
        func set(_ level: Int32, _ option: Int32, _ value: Int32) {
            var value = value
            setsockopt(fd, level, option, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(IPPROTO_TCP, TCP_KEEPALIVE, 30)
        set(IPPROTO_TCP, TCP_KEEPINTVL, 10)
        set(IPPROTO_TCP, TCP_KEEPCNT, 3)
    }

    /// Takes ownership of an already-connected descriptor.
    public func adopt(_ descriptor: Int32) throws {
        guard libssh2IsInitialized else { throw SSHError.socket("libssh2_init failed") }
        fd = descriptor

        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // Whichever transport made it: libssh2 writes to it directly.
        SocketOptions.noSIGPIPE(fd)
        Self.enableTCPKeepalive(on: fd)
        // Non-blocking from here on; libssh2 reports EAGAIN and we pump.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        // The counter rides in libssh2's abstract pointer, unretained: the
        // actor holds it for longer than the session it is handed to.
        guard let sess = libssh2_session_init_ex(
            nil, nil, nil, Unmanaged.passUnretained(traffic).toOpaque()) else {
            throw SSHError.socket("libssh2_session_init failed")
        }
        session = sess
        typealias Generic = @convention(c) () -> Void
        _ = libssh2_session_callback_set2(sess, LIBSSH2_CALLBACK_SEND,
                                          unsafeBitCast(countedSend, to: Generic.self))
        _ = libssh2_session_callback_set2(sess, LIBSSH2_CALLBACK_RECV,
                                          unsafeBitCast(countedReceive, to: Generic.self))
        libssh2_session_set_blocking(sess, 0)
    }

    /// Runs the version and key exchange. Separate from `adopt` so a caller can
    /// inspect or configure the session first.
    public func handshake() async throws {
        guard let sess = session else { throw SSHError.socket("not connected") }
        try await retry("handshake") { libssh2_session_handshake(sess, self.fd) }
    }

    /// SHA-256 fingerprint of the server's host key, in the OpenSSH format.
    public func hostKeyFingerprint() -> String? {
        guard let raw = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else { return nil }
        let bytes = UnsafeRawBufferPointer(start: raw, count: 32)
        return "SHA256:" + Data(bytes).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public func authenticate(username: String, password: String) async throws {
        do {
            try await retry("userauth_password") {
                libssh2_userauth_password_ex(
                    self.session,
                    username, UInt32(username.utf8.count),
                    password, UInt32(password.utf8.count),
                    nil)
            }
        } catch let SSHError.libssh2(_, message, _) {
            throw SSHError.auth(message)
        }
        guard libssh2_userauth_authenticated(session) == 1 else {
            throw SSHError.auth("server did not accept the password")
        }
    }

    /// Authenticates with a private key held in memory.
    ///
    /// The key never touches disk on this path -- it comes out of the vault,
    /// goes into libssh2, and that is all. libssh2 derives the public half
    /// itself, which is why none has to be stored alongside it.
    public func authenticate(username: String, privateKey: String,
                             passphrase: String? = nil) async throws {
        let key = Array(privateKey.utf8).map { CChar(bitPattern: $0) }
        do {
            try await retry("userauth_publickey") {
                key.withUnsafeBufferPointer { keyBytes in
                    libssh2_userauth_publickey_frommemory(
                        self.session,
                        username, username.utf8.count,
                        nil, 0,
                        keyBytes.baseAddress, keyBytes.count,
                        passphrase)
                }
            }
        } catch let SSHError.libssh2(_, message, _) {
            throw SSHError.auth(message)
        }
        guard libssh2_userauth_authenticated(session) == 1 else {
            throw SSHError.auth("the server rejected the key")
        }
    }

    public struct CommandResult: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitStatus: Int32
    }

    /// Runs one command on its own channel and collects its output.
    public func exec(_ command: String) async throws -> CommandResult {
        let channel = try await retryPointer("channel_open") {
            // LIBSSH2_CHANNEL_{WINDOW,PACKET}_DEFAULT are expression macros,
            // which Swift cannot import; these are their values.
            libssh2_channel_open_ex(self.session, "session", 7,
                                    2 * 1024 * 1024,   // window
                                    32768,             // max packet
                                    nil, 0)
        }
        // After a disconnect the session has freed it already.
        let started = generation
        defer { if generation == started { libssh2_channel_free(channel) } }

        try await retry("channel_exec") {
            libssh2_channel_process_startup(channel, "exec", 4,
                                            command, UInt32(command.utf8.count))
        }

        var out = Data(), err = Data()
        var buf = [UInt8](repeating: 0, count: 32 * 1024)

        // Drain both streams until EOF. stream 0 is stdout, 1 is stderr.
        for stream in Int32(0)...Int32(1) {
            while true {
                let n = try await retry("channel_read") {
                    buf.withUnsafeMutableBytes { raw in
                        libssh2_channel_read_ex(channel, stream,
                                                raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count)
                    }
                }
                if n == 0 { break }
                if stream == 0 { out.append(contentsOf: buf[0..<n]) }
                else { err.append(contentsOf: buf[0..<n]) }
            }
        }

        try await retry("channel_close", giveUpAfter: 5) { libssh2_channel_close(channel) }
        let status = libssh2_channel_get_exit_status(channel)

        return CommandResult(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitStatus: status)
    }

    public func disconnect() async {
        // Snapshot before closing: `.keys` is a live view of the dictionary and
        // each close removes an entry, so iterating it directly mutates the
        // collection being walked. That corrupts memory rather than failing,
        // and only bites when something is still open at disconnect -- which is
        // exactly the case a port forward leaves behind.
        for shell in Array(shells.keys) { await close(shell) }
        for channel in Array(directChannels.keys) { await close(channel) }
        // Cancelled before the session goes, so the server drops the port now
        // rather than holding it until it notices we are gone.
        for listener in Array(remoteListeners.keys) { await closeRemote(listener) }
        if let sess = session {
            _ = try? await retry("session_disconnect", giveUpAfter: 2) {
                libssh2_session_disconnect_ex(sess, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            }
            // Anything still suspended -- an exec, a write into a full window,
            // a close -- wakes to find the session gone and touches nothing.
            generation += 1
            for wait in waits.values { wait.finish(.failure(Self.closed)) }
            libssh2_session_free(sess)
            session = nil
            shells = [:]
            directChannels = [:]
            remoteListeners = [:]
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        // No libssh2_exit(): it is global, and other sessions may still be
        // running.
    }
}
