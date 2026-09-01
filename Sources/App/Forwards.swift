import Core
import Foundation
import Net
import Observation
import SSH

/// The running port forwards.
///
/// A forward keeps its own SSH session rather than borrowing a terminal's.
/// Tying it to a tab would mean closing the tab quietly kills the tunnel
/// something else is using -- and would make a forward impossible to start
/// without opening a shell first. Forwards on the same server do share one
/// session: libssh2 is happy with several channels at once, and a second login
/// buys nothing.
@MainActor
@Observable
final class Forwards {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        /// Down, but supervised: a retry is scheduled. Distinct from failed,
        /// because the answer is "wait" rather than "do something".
        case retrying(String)
        case failed(String)

        /// Whether the button should offer to stop it.
        ///
        /// Retrying counts: the supervision is the thing being stopped, and a
        /// forward that keeps coming back after being switched off would be a
        /// bug the user cannot work around.
        var isLive: Bool {
            switch self { case .running, .starting, .retrying: true; default: false }
        }
    }

    /// Where the proxy on this Mac is listening. One setting for the machine,
    /// not one per server: it is this Mac's proxy, and every tunnel back here
    /// arrives at the same place.
    private(set) var proxyLocalPort = ProxyEnvironment.defaultLocalPort

    /// Keyed by preset id.
    private(set) var status: [Int64: Status] = [:]
    private(set) var traffic: [Int64: PortForward.Statistics] = [:]
    private(set) var presets: [PortForwardPreset] = []

    private var forwards: [Int64: PortForward] = [:]
    /// Which server each running forward belongs to, so the last one out can
    /// close the session.
    private var owner: [Int64: Int64] = [:]
    private var sessions: [Int64: SSHSession] = [:]
    private var keepalives: [Int64: Task<Void, Never>] = [:]
    /// Scheduled retries for the presets that ask to be kept alive.
    private var retries: [Int64: Task<Void, Never>] = [:]
    private var poller: Task<Void, Never>?

    private let store: Store
    /// Opening a session needs the route and the credentials, and the model is
    /// where those two meet.
    private weak var model: AppModel?

    init(store: Store, model: AppModel) {
        self.store = store
        self.model = model
    }

    func status(of preset: PortForwardPreset) -> Status {
        preset.id.flatMap { status[$0] } ?? .stopped
    }

    func presets(forServer id: Int64) -> [PortForwardPreset] {
        presets.filter { $0.serverId == id }
    }

    // MARK: - the list

    /// Re-reads the forwards.
    ///
    /// Deliberately not a live observation. Everything that changes a forward
    /// goes through this class, so the list can be refreshed at exactly the
    /// points it changes -- and an observation would race with those edits: a
    /// snapshot taken before a delete, delivered after it, puts the deleted
    /// row back for as long as it takes the next snapshot to arrive. The one
    /// change that comes from outside is a server being deleted, which takes
    /// its forwards with it in SQL; the model refreshes here when that lands.
    func refresh() async {
        presets = (try? await store.portForwards()) ?? []
    }

    @discardableResult
    func save(_ preset: PortForwardPreset) async -> PortForwardPreset? {
        let saved = try? await store.save(preset)
        await refresh()
        return saved
    }

    func delete(_ preset: PortForwardPreset) async {
        guard let id = preset.id else { return }
        await stop(id)
        retries.removeValue(forKey: id)?.cancel()
        try? await store.delete(portForwardID: id)
        await refresh()
        status[id] = nil
        traffic[id] = nil
    }

    /// Reads the machine-wide proxy port. Called with the rest of the startup.
    func loadProxySettings() async {
        if let saved = try? await store.setting("proxyLocalPort"), let port = Int(saved) {
            proxyLocalPort = port
        }
    }

    /// Points every tunnel back here at a different local port.
    ///
    /// Applied to all of them at once, because they all mean the same thing --
    /// "the proxy running on this Mac" -- and letting them drift apart would
    /// mean a server quietly using a port nothing listens on.
    func setProxyLocalPort(_ port: Int) async {
        guard port != proxyLocalPort, port > 0 else { return }
        proxyLocalPort = port
        try? await store.setSetting("proxyLocalPort", to: String(port))

        // Re-saved rather than edited in place: `saveProxy` is the one place
        // that decides what a proxy tunnel looks like, and going through it
        // means a moved port also restarts the tunnels.
        for preset in proxyPresets { await saveProxy(preset) }
    }

    /// Brings up everything marked automatic. Called once the vault opens.
    ///
    /// Reads the list itself rather than waiting for the observation to
    /// deliver it, so starting does not depend on which arrived first.
    func startAutomatic() async {
        await refresh()
        for preset in presets where preset.autoStart { await start(preset) }
    }

    // MARK: - running

    func toggle(_ preset: PortForwardPreset) async {
        guard let id = preset.id else { return }
        if status(of: preset).isLive { await stop(id) } else { await start(preset) }
    }

    func start(_ preset: PortForwardPreset) async {
        await start(preset, attempt: 0)
    }

    private func start(_ preset: PortForwardPreset, attempt: Int) async {
        guard let id = preset.id else { return }
        // A retry is allowed to run while the status still says retrying;
        // anything else that is live is left alone.
        if attempt == 0 && status[id] == .running { return }
        if attempt == 0 && status[id] == .starting { return }
        retries.removeValue(forKey: id)?.cancel()
        guard let model, let server = model.servers.first(where: { $0.id == preset.serverId })
        else {
            status[id] = .failed("its server is gone")
            return
        }
        if model.needsTunnel(server) {
            // Said plainly rather than left to time out inside the handshake:
            // the tunnel is a switch the user can flip, and the message is
            // useless if it does not say which one.
            status[id] = .failed("connect the VPN first")
            return
        }

        status[id] = .starting
        do {
            let route = server.routesThroughVPN ? " through the VPN" : ""
            let note = "termther: forward \(id) starting \(preset.summary) on "
                + "\(server.host):\(server.port)\(route)\n"
            FileHandle.standardError.write(Data(note.utf8))
            let session = try await session(for: server)
            let forward = try PortForward(
                session: session,
                direction: preset.direction.engineDirection,
                bindHost: preset.bindHost, bindPort: UInt16(preset.bindPort),
                targetHost: preset.targetHost, targetPort: UInt16(preset.targetPort))
            try await forward.start { [weak self] in
                // Reported from the far side: the session dropped, or the
                // server cancelled the listener. Without this the row would
                // stay green while the port on the server was gone.
                Task { @MainActor in await self?.tunnelClosed(id) }
            }

            forwards[id] = forward
            owner[id] = preset.serverId
            traffic[id] = .init()
            status[id] = .running
            startPolling()
        } catch {
            var reason = String(describing: error)
            // A refusal carries no reason in the protocol, so ask while the
            // session is still up rather than leaving the user with "denied".
            if error is SSHSession.ForwardRefusal, let session = sessions[preset.serverId] {
                reason += " \u{2014} " + (await ForwardDiagnosis.explain(
                    port: preset.bindPort, over: session))

                // A port held by a session of ours that already died is not
                // something to wait out: sshd does not probe its clients, so
                // the listener outlives the connection by hours. Taking it
                // back and going again is the only thing that gets the tunnel
                // up today.
                if attempt < 2 {
                    let outcome = await ForwardDiagnosis.reclaim(
                        port: preset.bindPort, over: session)
                    if outcome == .reclaimed {
                        note("forward \(id) reclaimed port \(preset.bindPort) from a "
                             + "dropped session; trying again")
                        await start(preset, attempt: attempt + 1)
                        return
                    }
                    if let advice = outcome.advice(port: preset.bindPort) {
                        reason += " " + advice
                    }

                }
            }
            await retireSessionIfIdle(preset.serverId)
            fail(preset, reason: reason, attempt: attempt)
        }
    }

    /// Stops the tunnels that ride on the campus VPN, now that it is gone.
    ///
    /// Without this each one discovers the loss on its own, and discovering it
    /// means waiting out a read on a socket that no longer goes anywhere. Half
    /// a dozen of those in parallel is what makes changing networks feel like
    /// the app has hung.
    func suspendThoseNeedingTunnel() async {
        guard let model else { return }
        for preset in presets {
            guard let id = preset.id, status[id]?.isLive == true,
                  let server = model.servers.first(where: { $0.id == preset.serverId }),
                  server.routesThroughVPN
            else { continue }
            await stop(id)
            status[id] = .retrying("waiting for the VPN")
        }
    }

    /// Brings back the tunnels that were only waiting for the campus tunnel.
    ///
    /// Order at startup is the problem this solves: forwards come up when the
    /// vault opens, which is before anyone has connected the VPN, so every
    /// tunnel to a campus server fails on the way up. Supervision would fetch
    /// them within half a minute, but the moment the VPN connects is when they
    /// can actually succeed, and waiting out a backoff for no reason is the
    /// kind of delay that reads as broken.
    ///
    /// Only the ones that were trying. A tunnel switched off by hand stays
    /// off: connecting a VPN is not a request to undo that.
    func resumeWaitingOnTunnel() async {
        guard let model else { return }
        for preset in presets {
            guard let id = preset.id,
                  let server = model.servers.first(where: { $0.id == preset.serverId }),
                  server.routesThroughVPN
            else { continue }

            switch status[id] {
            case .failed, .retrying: await start(preset, attempt: 0)
            default: break
            }
        }
    }

    /// A running tunnel that ended without being asked to.
    private func tunnelClosed(_ presetID: Int64) async {
        guard forwards[presetID] != nil else { return }   // already stopped
        forwards.removeValue(forKey: presetID)
        let serverID = owner.removeValue(forKey: presetID)
        if let serverID { await retireSessionIfIdle(serverID, force: true) }

        if let preset = presets.first(where: { $0.id == presetID }) {
            fail(preset, reason: "the tunnel closed", attempt: 0)
        } else {
            status[presetID] = .failed("the tunnel closed")
        }
    }

    /// Records a failure, and schedules another go when the preset asks for it.
    ///
    /// The backoff is the usual doubling capped at half a minute: a server
    /// that is rebooting should not be hammered, and one that is briefly
    /// unreachable should not take half a minute to come back.
    private func fail(_ preset: PortForwardPreset, reason: String, attempt: Int) {
        guard let id = preset.id else { return }
        // Also to stderr: the panel shows one line of this, and one line is
        // not enough to work out why a tunnel will not come up.
        note("forward \(id) (\(preset.summary)) failed: \(reason)")
        guard preset.keepAlive else {
            status[id] = .failed(reason)
            return
        }

        let delay = min(30, 1 << min(attempt + 1, 5))
        status[id] = .retrying("\(reason) -- retrying in \(delay)s")
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.start(preset, attempt: attempt + 1)
        }
    }

    func stop(_ presetID: Int64) async {
        // Stopping means stopping: a supervised forward that came back after
        // being switched off would be a bug with no way around it.
        retries.removeValue(forKey: presetID)?.cancel()
        guard let forward = forwards.removeValue(forKey: presetID) else {
            status[presetID] = .stopped
            return
        }
        await forward.stop()
        status[presetID] = .stopped
        let serverID = owner.removeValue(forKey: presetID)
        if let serverID { await retireSessionIfIdle(serverID) }
        if forwards.isEmpty { poller?.cancel(); poller = nil }
    }

    func stopAll() async {
        for id in Array(forwards.keys) { await stop(id) }
    }

    // MARK: - sessions

    private func session(for server: Server) async throws -> SSHSession {
        guard let id = server.id else { throw Failure.unsaved }
        if let existing = sessions[id] { return existing }
        guard let model else { throw Failure.unsaved }

        let session = SSHSession()
        let route = try await model.route(to: server)
        try await session.connect(to: server.host, port: UInt16(server.port), over: route.transport)
        try await session.authenticate(route.login)

        // A forwarding session can sit silent for hours, and silence is what
        // makes servers and NAT tables forget it exists.
        await session.enableKeepalive(every: 30)
        sessions[id] = session
        keepalives[id] = keepaliveTask(for: id, session: session)
        return session
    }

    private func keepaliveTask(for serverID: Int64, session: SSHSession) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard await session.sendKeepalive() != nil else {
                    // The peer is gone. Better to say so than to leave a
                    // listening socket that accepts and then hangs.
                    await self?.sessionDied(serverID)
                    return
                }
            }
        }
    }

    private func sessionDied(_ serverID: Int64) async {
        for (presetID, owningServer) in owner where owningServer == serverID {
            forwards.removeValue(forKey: presetID)
            owner.removeValue(forKey: presetID)
            if let preset = presets.first(where: { $0.id == presetID }) {
                fail(preset, reason: "connection lost", attempt: 0)
            } else {
                status[presetID] = .failed("connection lost")
            }
        }
        await retireSessionIfIdle(serverID, force: true)
    }

    /// Closes a server's session once nothing is using it.
    private func retireSessionIfIdle(_ serverID: Int64, force: Bool = false) async {
        if !force && owner.values.contains(serverID) { return }
        keepalives.removeValue(forKey: serverID)?.cancel()
        guard let session = sessions.removeValue(forKey: serverID) else { return }
        await session.disconnect()
    }

    // MARK: - traffic

    /// Byte counts, refreshed while anything is running.
    ///
    /// Polled rather than pushed: the counters live in an actor per forward,
    /// and a view that redraws on every packet would spend more time drawing
    /// than the tunnel spends moving bytes.
    private func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.sampleTraffic()
            }
        }
    }

    private func sampleTraffic() async {
        for (id, forward) in forwards {
            traffic[id] = await forward.stats()
        }
    }

    // MARK: - the proxy back to this Mac

    /// The preset that sends a server's traffic back here, if it has one.
    ///
    /// Identified by what it does rather than by a flag on the server: the
    /// preset row is the whole feature, so there is one thing to edit, one
    /// thing to delete, and no way for a switch and a tunnel to disagree.
    /// Every tunnel that carries a server's traffic back to this Mac.
    var proxyPresets: [PortForwardPreset] {
        presets.filter { $0.direction == .remote && $0.exportsEnvironment }
    }

    /// The forwards the Port Forwards panel shows: everything except the
    /// proxy tunnels, which have a panel of their own.
    func plainPresets(forServer id: Int64) -> [PortForwardPreset] {
        presets.filter { $0.serverId == id
                         && !($0.direction == .remote && $0.exportsEnvironment) }
    }

    func proxyBack(for serverID: Int64) -> PortForwardPreset? {
        presets.first { $0.serverId == serverID && $0.direction == .remote
                        && $0.exportsEnvironment }
    }

    /// Saves a proxy tunnel, filling in everything that makes it one.
    ///
    /// The caller chooses the server, the port on it, and whether it is
    /// supervised. The rest is what being a proxy tunnel means, and is not
    /// worth offering as a choice: reverse direction, arriving at this Mac's
    /// proxy port, with the environment exported so the server actually uses
    /// it.
    @discardableResult
    func saveProxy(_ preset: PortForwardPreset) async -> PortForwardPreset? {
        var preset = preset
        preset.direction = .remote
        preset.bindHost = "127.0.0.1"
        preset.targetHost = "127.0.0.1"
        preset.targetPort = proxyLocalPort
        preset.exportsEnvironment = true

        guard let saved = await save(preset), let id = saved.id else { return nil }
        // Restarted, so edited ports take effect now rather than at the next
        // unlock -- and so a tunnel switched from one server to another does
        // not leave the old one listening.
        if status[id]?.isLive == true { await stop(id) }
        if saved.autoStart { await start(saved) }
        return saved
    }

    /// Turns the proxy tunnel on or off for one server.
    ///
    /// Reads the store rather than the observed list, because this is called
    /// straight after a server is first saved and the observation may not have
    /// caught up.
    func setProxyBack(_ enabled: Bool, for serverID: Int64, remotePort: Int) async {
        let saved = (try? await store.portForwards(serverID: serverID)) ?? []
        let existing = saved.first { $0.direction == .remote && $0.exportsEnvironment }

        guard enabled else {
            if let existing { await delete(existing) }
            return
        }

        var preset = existing ?? PortForwardPreset(serverId: serverID, direction: .remote,
                                                   bindPort: remotePort)
        preset.bindPort = remotePort
        // Started by hand, kept alive once started. Coming up on its own means
        // reaching a server the moment the vault opens, which is a connection
        // nobody asked for -- but a tunnel that drops while in use takes the
        // server's whole route out with it, so that half stays on.
        preset.keepAlive = true
        await saveProxy(preset)
    }

    /// The running forward for a preset, if it is up. Used to decide whether
    /// a new terminal can be told to use the tunnel.
    func isRunning(_ presetID: Int64) -> Bool { status[presetID] == .running }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("termther: \(message)\n".utf8))
    }

    enum Failure: Error, CustomStringConvertible {
        case unsaved
        public var description: String { "the server has not been saved yet" }
    }
}

extension PortForwardPreset.Direction {
    /// The saved direction, as the engine names it. Two enums rather than one
    /// because the stored spelling must survive changes to the engine's.
    var engineDirection: PortForward.Direction {
        switch self {
        case .local:   .local
        case .dynamic: .dynamic
        case .remote:  .remote
        }
    }
}
