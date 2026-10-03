import AppKit
import Core
import Foundation
import Network
import Observation
import SSH

/// One SSH session per server, shared by everything that is not a terminal:
/// the port forwards and the load monitor.
///
/// Neither borrows a terminal's session. Tying a tunnel to a tab would mean
/// closing the tab quietly kills the tunnel something else is using -- and
/// would make a forward impossible to start without opening a shell first.
/// Nor does each dial its own: libssh2 is happy with several channels at
/// once, and a second login to the same server buys nothing. So a server has
/// one session here, held by whoever asked for it and closed when the last
/// of them lets go.
@MainActor
@Observable
final class ServerSessions {
    /// Who can hold a session open.
    enum User: Hashable { case forwards, monitor }

    private(set) var sessions: [Int64: SSHSession] = [:]
    /// Logins begun, counted so a test can see two callers share one.
    private(set) var logins = 0
    /// Told when a session is closed from underneath its users, and why: a
    /// keepalive that got no answer, the Mac waking, the network changing.
    @ObservationIgnored var onSessionDied: ((Int64, String) -> Void)?

    private var users: [Int64: Set<User>] = [:]
    /// Logins in progress, so two callers starting together share one
    /// rather than opening two sessions and leaking the first.
    private var connecting: [Int64: Task<SSHSession, Error>] = [:]
    private var keepalives: [Int64: Task<Void, Never>] = [:]
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    /// The network as last seen: interfaces and gateways, so a move between
    /// two Wi-Fi networks -- same interface, new gateway -- counts as a change.
    private var lastNetwork: [String]?

    /// Opening a session needs the route and the credentials, and the model is
    /// where those two meet.
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// A server's session, if one is up. For work that should ride along
    /// without keeping the session open on its own account.
    func existing(_ serverID: Int64) -> SSHSession? { sessions[serverID] }

    /// The server's session, opened if need be, and held by `user` until
    /// released.
    func session(for server: Server, as user: User) async throws -> SSHSession {
        guard let id = server.id else { throw Failure.unsaved }
        let session: SSHSession
        if let existing = sessions[id] {
            session = existing
        } else if let pending = connecting[id] {
            session = try await pending.value
        } else {
            session = try await login(to: server, id: id)
        }
        // Retired while this waited: handed over anyway, to fail where it is
        // used, but not held -- there is nothing to hold.
        if sessions[id] === session { users[id, default: []].insert(user) }
        return session
    }

    private func login(to server: Server, id: Int64) async throws -> SSHSession {
        guard let model else { throw Failure.unsaved }
        logins += 1
        let login = Task { @MainActor [weak self] () throws -> SSHSession in
            let session = try await model.connectedSession(to: server)
            // A forwarding session can sit silent for hours, and silence is what
            // makes servers and NAT tables forget it exists.
            await session.enableKeepalive(every: 30)
            guard let self else { await session.disconnect(); throw Failure.unsaved }
            self.sessions[id] = session
            self.keepalives[id] = self.keepaliveTask(for: id, session: session)
            return session
        }
        connecting[id] = login
        defer { if connecting[id] == login { connecting[id] = nil } }
        return try await login.value
    }

    private func keepaliveTask(for serverID: Int64, session: SSHSession) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard await session.sendKeepalive() != nil else {
                    // The peer is gone. Better to say so than to leave a
                    // listening socket that accepts and then hangs.
                    await self?.retire(serverID, because: "connection lost")
                    return
                }
            }
        }
    }

    /// Lets go of a server's session; the last user out closes it.
    func release(_ serverID: Int64, by user: User) async {
        users[serverID]?.remove(user)
        if users[serverID]?.isEmpty ?? true { await retire(serverID) }
    }

    func releaseAll(by user: User) async {
        for serverID in Array(users.keys) { await release(serverID, by: user) }
    }

    /// Closes a server's session whoever holds it. With a reason, the users
    /// are told afterwards, so they find it gone at once rather than waiting
    /// on a dead socket.
    func retire(_ serverID: Int64, because reason: String? = nil) async {
        users[serverID] = nil
        keepalives.removeValue(forKey: serverID)?.cancel()
        guard let session = sessions.removeValue(forKey: serverID) else { return }
        await session.disconnect()
        if let reason { onSessionDied?(serverID, reason) }
    }

    /// Drops every session now. Supervised tunnels come back through their
    /// usual retry, over a fresh connection.
    func retireAll(because reason: String) async {
        for serverID in Array(sessions.keys) { await retire(serverID, because: reason) }
    }

    // MARK: - stale connections

    /// Waking from sleep and changing networks both leave SSH connections
    /// that look alive and are not. Rebuilding them straight away beats
    /// waiting minutes for TCP to notice. Started once, by the app.
    func watchForStaleConnections() {
        guard pathMonitor == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.retireAll(because: "the Mac woke from sleep") }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network = path.availableInterfaces.map(\.name)
                + path.gateways.map { "\($0)" }
            let isUp = path.status == .satisfied
            Task { @MainActor in await self?.networkChanged(to: network, isUp: isUp) }
        }
        monitor.start(queue: DispatchQueue(label: "termther.network"))
        pathMonitor = monitor
    }

    private func networkChanged(to network: [String], isUp: Bool) async {
        defer { lastNetwork = network }
        guard Self.isChange(from: lastNetwork, to: network, isUp: isUp) else { return }
        await retireAll(because: "the network changed")
    }

    /// Whether a network report is worth reconnecting over. The first is the
    /// network as it already is; a report while down has nothing to rebuild
    /// on -- the one after, when it is back, does the work.
    nonisolated static func isChange(from last: [String]?, to network: [String], isUp: Bool) -> Bool {
        guard let last else { return false }
        return isUp && last != network
    }

    enum Failure: Error, CustomStringConvertible {
        case unsaved
        public var description: String { "the server has not been saved yet" }
    }
}
