import CSSH2
import Darwin
import Dispatch
import Foundation
import Net

/// A tunnel carried over an SSH session.
///
/// Every socket here is driven by GCD rather than blocking calls. That is not
/// a style choice: a blocking `accept()` or `read()` inside an actor holds the
/// actor for as long as it waits, so the very work it is waiting to hand off
/// can never start. The symptom is a forward that accepts a connection and
/// then does nothing at all.
public actor PortForward {
    public enum Direction: Sendable {
        /// Listen here, connect there. `ssh -L`.
        case local
        /// Listen here as a SOCKS5 proxy, connect wherever each client asks.
        /// `ssh -D`.
        case dynamic
        /// Listen *there*, connect here. `ssh -R`.
        ///
        /// The mirror image of a local forward, and the one that lets a
        /// service on this machine serve the server -- a proxy running here,
        /// for instance, without the server needing any route back to us.
        case remote
    }

    public struct Statistics: Sendable, Equatable {
        public var connections = 0
        public var bytesOut: UInt64 = 0
        public var bytesIn: UInt64 = 0

        public init() {}
    }

    public enum Failure: Error, CustomStringConvertible {
        case bind(String)
        public var description: String {
            switch self { case .bind(let m): "cannot bind: \(m)" }
        }
    }

    private let session: SSHSession
    /// Only local and dynamic forwards listen on this machine. A remote
    /// forward's listening socket belongs to the server.
    private let listener: Listener?
    private var remoteListener: SSHSession.RemoteListener?
    private var acceptLoop: Task<Void, Never>?
    /// Called when the tunnel stops carrying anything without being asked to.
    ///
    /// A remote forward can end from the far side -- the session drops, or the
    /// server cancels the listener -- and there is nothing local to notice it.
    /// Without this the forward sits there looking healthy while the port on
    /// the server is gone.
    private var onClosed: (@Sendable () -> Void)?
    public let direction: Direction
    public nonisolated let bindHost: String
    public nonisolated let bindPort: UInt16
    private let targetHost: String
    private let targetPort: UInt16

    private var statistics = Statistics()
    private var isRunning = false
    /// What the server actually bound, once it has said. Only interesting for
    /// a remote forward that asked for port 0.
    public private(set) var boundPort: UInt16 = 0

    public init(session: SSHSession, direction: Direction,
                bindHost: String = "127.0.0.1", bindPort: UInt16,
                targetHost: String = "", targetPort: UInt16 = 0) throws {
        self.session = session
        self.direction = direction
        self.bindHost = bindHost
        self.targetHost = targetHost
        self.targetPort = targetPort

        if direction == .remote {
            // Nothing is bound here; asking the server to bind happens in
            // `start`, because it needs the session and can be refused.
            self.listener = nil
            self.bindPort = bindPort
        } else {
            let listener = try Listener(host: bindHost, port: bindPort)
            self.listener = listener
            // Port 0 asked for whatever was free; report what was given.
            self.bindPort = listener.port
        }
    }

    public func stats() -> Statistics { statistics }

    public func start(onClosed: (@Sendable () -> Void)? = nil) async throws {
        guard !isRunning else { return }
        self.onClosed = onClosed

        if direction == .remote {
            // May be refused -- sshd can forbid forwarding outright, and it
            // holds a forwarded port for a while after a dropped session, so
            // reconnecting quickly can meet its own ghost.
            let (handle, port) = try await session.listenRemote(bindHost: bindHost,
                                                                port: bindPort)
            remoteListener = handle
            boundPort = port
            isRunning = true
            acceptLoop = Task { [weak self] in await self?.acceptFromServer(handle) }
        } else {
            isRunning = true
            listener?.start { [weak self] client in
                Task { await self?.serve(client) }
            }
        }
    }

    public func stop() async {
        // Cleared first: a deliberate stop is not the failure `onClosed`
        // exists to report, and firing it here would set off a reconnect for
        // a tunnel the user just switched off.
        onClosed = nil
        isRunning = false
        acceptLoop?.cancel()
        acceptLoop = nil
        listener?.stop()
        if let handle = remoteListener {
            remoteListener = nil
            await session.closeRemote(handle)
        }
    }

    /// Takes the connections the server sends us and joins each to a socket
    /// opened here.
    ///
    /// Polled rather than waited on: an accepted channel arrives inside the
    /// session's own byte stream, so there is nothing to select on but the
    /// session socket itself, and a short poll is what keeps a new connection
    /// from sitting in the queue.
    private func acceptFromServer(_ handle: SSHSession.RemoteListener) async {
        while !Task.isCancelled && isRunning {
            let channel: SSHSession.DirectChannel?
            do {
                channel = try await session.acceptRemote(handle)
            } catch {
                // The session is gone; the listener with it. Reported rather
                // than swallowed, because from outside this looks exactly like
                // a tunnel that is up and simply quiet.
                reportClosed()
                return
            }
            guard let channel else {
                await session.awaitActivity(timeout: 0.05)
                continue
            }
            statistics.connections += 1
            Task { await self.serveFromServer(channel) }
        }
        // Falling out of the loop without being stopped is the same news.
        if isRunning { reportClosed() }
    }

    private func reportClosed() {
        guard let onClosed else { return }
        self.onClosed = nil
        isRunning = false
        onClosed()
    }

    /// One connection the server handed us, joined to its destination here.
    private func serveFromServer(_ channel: SSHSession.DirectChannel) async {
        guard let fd = try? await DirectTransport().connect(host: targetHost,
                                                            port: targetPort) else {
            // Nothing is listening on this side. Closing the channel is what
            // tells the program on the server that its connection was refused,
            // rather than leaving it waiting.
            await session.close(channel)
            return
        }
        await pump(client: fd, channel: channel)
    }

    private func serve(_ client: Int32) async {
        statistics.connections += 1

        var host = targetHost
        var port = targetPort

        if direction == .dynamic {
            // A SOCKS5 client says where it wants to go, one connection at a
            // time -- the whole point of a dynamic forward. The handshake is a
            // few short exchanges, so it is done with blocking reads on a
            // background queue before the socket joins the event-driven path.
            guard let destination = await Self.negotiateSOCKS5(on: client) else {
                Darwin.close(client)
                return
            }
            host = destination.host
            port = destination.port
        }

        guard let channel = try? await session.openDirectTCPIP(host: host, port: port) else {
            Darwin.close(client)
            return
        }
        await pump(client: client, channel: channel)
    }

    private static func negotiateSOCKS5(on client: Int32) async -> SOCKS5Server.Destination? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning:
                    try? SOCKS5Server.negotiate(on: FileDescriptorStream(fd: client)))
            }
        }
    }

    /// Copies bytes both ways until either side finishes.
    ///
    /// One loop, not two tasks. libssh2 tolerates concurrent work across
    /// channels but not within one, so both directions are advanced together
    /// in a single call that never suspends midway. Byte counts are kept here
    /// because this is the only place both directions are visible, and
    /// per-forward traffic is what makes a forwarding table worth looking at.
    private func pump(client: Int32, channel: SSHSession.DirectChannel) async {
        let socket = SocketPipe(fd: client)
        defer { socket.close() }

        // Client bytes arrive on their own queue and are buffered here, so the
        // loop below is the only thing that ever touches the channel.
        let outbound = OutboundBuffer()
        let reader = Task {
            for await chunk in socket.incoming { outbound.append(chunk) }
            outbound.finish()
        }
        defer { reader.cancel() }

        while true {
            let pending = outbound.peek()
            guard let turn = try? await session.pump(channel, sending: pending) else { break }
            if turn.isFinished { break }

            if turn.sent > 0 {
                outbound.consume(turn.sent)
                statistics.bytesOut += UInt64(turn.sent)
            }
            if !turn.received.isEmpty {
                socket.write(turn.received)
                statistics.bytesIn += UInt64(turn.received.count)
            }

            if outbound.isFinishedAndEmpty && turn.received.isEmpty { break }
            if turn.isIdle {
                // Nothing moved: wait for the session rather than spinning.
                // A short timeout keeps the client's side responsive too,
                // since its bytes arrive on another queue entirely.
                await session.awaitActivity(timeout: 0.05)
            }
        }

        await session.close(channel)
    }

    private func count(out bytes: UInt64) { statistics.bytesOut += bytes }
    private func count(in bytes: UInt64) { statistics.bytesIn += bytes }
}

/// A TCP listener that accepts on its own queue.
private final class Listener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let queue = DispatchQueue(label: "termther.forward.accept")
    private var source: DispatchSourceRead?

    init(host: String, port requested: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PortForward.Failure.bind(String(cString: strerror(errno)))
        }
        fd = descriptor

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 64) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw PortForward.Failure.bind("\(host):\(requested): \(reason)")
        }

        // Port 0 means "any free port"; report back the one the kernel chose,
        // so a caller can tell clients where to go.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = requested == 0 ? UInt16(bigEndian: actual.sin_port) : requested
    }

    func start(onAccept: @escaping @Sendable (Int32) -> Void) {
        // Non-blocking, or the drain loop below blocks its queue thread on the
        // accept that finds nothing left.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [fd] in
            // One readiness event can cover several pending connections.
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                onAccept(client)
            }
        }
        // The descriptor is closed here and nowhere else. Closing it while the
        // source still refers to it is a use-after-close, and it crashes.
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else {
            // Never started, so nothing owns the descriptor yet.
            Darwin.close(fd)
            return
        }
        self.source = nil
        source.cancel()
    }
}

/// Bytes read from the client, waiting to go out on the channel.
///
/// The reader task fills it from a GCD queue; the pump loop drains it from the
/// actor. A lock rather than an actor, because the pump must be able to look
/// at it without suspending.
private final class OutboundBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var readerFinished = false

    func append(_ chunk: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bytes += chunk
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        readerFinished = true
    }

    func peek() -> ArraySlice<UInt8> {
        lock.lock(); defer { lock.unlock() }
        // Bounded, so one enormous paste cannot monopolise a turn.
        return bytes.prefix(32 * 1024)
    }

    func consume(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        bytes.removeFirst(min(count, bytes.count))
    }

    var isFinishedAndEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return readerFinished && bytes.isEmpty
    }
}

/// A socket as an async byte stream in, and a queued writer out.
private final class SocketPipe: @unchecked Sendable {
    let incoming: AsyncStream<[UInt8]>
    private let shutdown: Shutdown
    private let io: DispatchIO
    private let queue: DispatchQueue

    /// Stopping a DispatchIO twice is not allowed, and both the reader
    /// finishing and the pump returning try to do it. Kept in its own object so
    /// the stream's termination handler can hold it without capturing a
    /// half-built SocketPipe.
    private final class Shutdown: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let io: DispatchIO

        init(io: DispatchIO) { self.io = io }

        func close() {
            lock.lock()
            let alreadyDone = done
            done = true
            lock.unlock()
            guard !alreadyDone else { return }
            io.close(flags: .stop)
        }
    }

    init(fd: Int32) {
        let queue = DispatchQueue(label: "termther.forward.io")
        // DispatchIO owns the descriptor and closes it when torn down, which
        // also unblocks whichever side is still waiting.
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            Darwin.close(fd)
        }
        io.setLimit(lowWater: 1)
        let shutdown = Shutdown(io: io)

        self.queue = queue
        self.io = io
        self.shutdown = shutdown
        incoming = AsyncStream { continuation in
            // length .max streams until the socket ends rather than reading
            // once, so there is no polling loop.
            io.read(offset: 0, length: .max, queue: queue) { done, data, error in
                if let data, !data.isEmpty { continuation.yield([UInt8](data)) }
                if done || error != 0 { continuation.finish() }
            }
            continuation.onTermination = { _ in shutdown.close() }
        }
    }

    func write(_ bytes: [UInt8]) {
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: data, queue: queue) { _, _, _ in }
    }

    func close() { shutdown.close() }
}
