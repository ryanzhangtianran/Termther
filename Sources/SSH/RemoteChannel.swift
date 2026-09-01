import CSSH2
import Foundation

/// The other direction: the server listens, and the connections come to us.
///
/// `ssh -R`. Where a local forward asks the server to dial out, a remote
/// forward asks it to accept -- so a service running on this machine can be
/// reached from the server without the server being reachable from here. That
/// is what lets a Mac's proxy serve the machines it connects to.
extension SSHSession {
    public struct RemoteListener: Sendable, Hashable {
        let id: Int
    }

    public enum ForwardRefusal: Error, CustomStringConvertible {
        case refused(host: String, port: UInt16, detail: String)

        public var description: String {
            switch self {
            case .refused(let host, let port, let detail):
                // The real error first. An earlier version led with a guess at
                // the cause -- a held port or forwarding being disabled -- and
                // that guess was printed for every failure, including the ones
                // where the session itself had just gone away. A message that
                // confidently names the wrong cause is worse than a blunt one.
                "cannot listen on \(host):\(port) on the server: \(detail)"
            }
        }
    }

    /// Asks the server to listen on `bindHost:port` and send us what arrives.
    ///
    /// Returns the port actually bound, which matters when 0 was asked for.
    /// Binding anything but a loopback address needs `GatewayPorts` on the
    /// server; 127.0.0.1 always works where forwarding is allowed at all.
    public func listenRemote(bindHost: String = "127.0.0.1",
                             port: UInt16) async throws -> (RemoteListener, UInt16) {
        let session = try requireSession()
        var boundPort: Int32 = 0

        let raw: OpaquePointer
        do {
            raw = try await retryPointer("forward_listen") {
                libssh2_channel_forward_listen_ex(session, cachedCString(bindHost),
                                                  Int32(port), &boundPort, 16)
            }
        } catch {
            throw ForwardRefusal.refused(host: bindHost, port: port,
                                         detail: String(describing: error))
        }

        let listener = RemoteListener(id: nextListenerID)
        nextListenerID += 1
        remoteListeners[listener] = raw
        return (listener, port == 0 ? UInt16(boundPort) : port)
    }

    /// Takes one waiting connection, or nil when there is none yet.
    ///
    /// Deliberately not a blocking accept: the caller polls this between waits
    /// on the socket, so one task can watch a listener without occupying the
    /// session while nothing is happening.
    public func acceptRemote(_ listener: RemoteListener) throws -> DirectChannel? {
        let session = try requireSession()
        guard let raw = remoteListeners[listener] else { return nil }

        guard let accepted = libssh2_channel_forward_accept(raw) else {
            let rc = libssh2_session_last_errno(session)
            if rc == LIBSSH2_ERROR_EAGAIN { return nil }
            throw error(rc, at: "forward_accept")
        }

        // Registered in the same table as any other tunnel channel, so the
        // pump, the byte counting and the teardown are shared rather than
        // written twice.
        let channel = DirectChannel(id: nextChannelID)
        nextChannelID += 1
        directChannels[channel] = accepted
        return channel
    }

    public func closeRemote(_ listener: RemoteListener) async {
        guard let raw = remoteListeners.removeValue(forKey: listener) else { return }
        _ = try? await retry("forward_cancel") { libssh2_channel_forward_cancel(raw) }
    }
}

/// libssh2 takes a mutable `char *` for the bind address and keeps no copy, so
/// the string has to outlive the call. A cache rather than a leak per call:
/// the same handful of addresses are used over and over.
private final class BindAddresses: @unchecked Sendable {
    static let shared = BindAddresses()
    private let lock = NSLock()
    private var cache: [String: UnsafeMutablePointer<CChar>] = [:]

    func pointer(for host: String) -> UnsafeMutablePointer<CChar> {
        lock.lock(); defer { lock.unlock() }
        if let existing = cache[host] { return existing }
        let copy = strdup(host)!
        cache[host] = copy
        return copy
    }
}

func cachedCString(_ host: String) -> UnsafeMutablePointer<CChar> {
    BindAddresses.shared.pointer(for: host)
}
