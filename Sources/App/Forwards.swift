import AppKit
import Core
import Foundation
import Net
import Observation
import SSH

/// The running port forwards.
///
/// A forward runs over the server's shared session (`ServerSessions`), not a
/// terminal's: closing a tab must not kill a tunnel something else is using.
/// Forwards on the same server share it, and the last one out lets go of it.
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
    /// Set by hand on the Proxy page and kept in the app's preferences, not
    /// the database: it is a fact about this Mac, not about any server.
    /// No default: nil until it is set, and a proxy tunnel will not start.
    var proxyLocalPort: Int? { defaults.object(forKey: "proxyLocalPort") as? Int }
    /// This Mac's SOCKS5 port; nil when there is none to forward.
    var proxySocksLocalPort: Int? { defaults.object(forKey: "proxySocksLocalPort") as? Int }
    /// Where those two are kept; a test gives it a suite of its own.
    @ObservationIgnored var defaults = UserDefaults.standard

    /// Keyed by preset id.
    private(set) var status: [Int64: Status] = [:]
    private(set) var traffic: [Int64: PortForward.Statistics] = [:]
    /// Bytes per second over the last sample, for a live bandwidth reading.
    private(set) var rates: [Int64: Rate] = [:]
    private var lastSample: ContinuousClock.Instant?

    struct Rate: Equatable {
        var bytesInPerSecond: Double = 0
        var bytesOutPerSecond: Double = 0

        /// From two samples of the running totals, `seconds` apart. A total
        /// that went down -- the tunnel restarted and its counters with it --
        /// reads as idle rather than as a huge or negative rate.
        static func between(_ previous: PortForward.Statistics,
                            _ current: PortForward.Statistics,
                            seconds: Double) -> Rate {
            guard seconds > 0 else { return Rate() }
            func perSecond(_ from: UInt64, _ to: UInt64) -> Double {
                to >= from ? Double(to - from) / seconds : 0
            }
            return Rate(bytesInPerSecond: perSecond(previous.bytesIn, current.bytesIn),
                        bytesOutPerSecond: perSecond(previous.bytesOut, current.bytesOut))
        }
    }
    private(set) var presets: [PortForwardPreset] = []

    private var forwards: [Int64: PortForward] = [:]
    /// Which server each running forward belongs to, so the last one out can
    /// close the session.
    private var owner: [Int64: Int64] = [:]
    /// Bumped by every stop, per preset. A start that finds it moved on when
    /// its login returns was switched off meanwhile, and undoes itself.
    private var epochs: [Int64: Int] = [:]
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
        // A session closed from underneath -- the keepalive got no answer,
        // the Mac woke, the network changed -- takes its forwards with it.
        model.sessions.onSessionDied = { [weak self] serverID, reason in
            Task { @MainActor in await self?.sessionDied(serverID, reason: reason) }
        }
    }

    func status(of preset: PortForwardPreset) -> Status {
        preset.id.flatMap { status[$0] } ?? .stopped
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

    /// Saves a forward; one running is restarted, so an edit to its ports
    /// takes effect rather than waiting for the next time it starts.
    @discardableResult
    func save(_ preset: PortForwardPreset) async -> PortForwardPreset? {
        let before = presets.first { $0.id != nil && $0.id == preset.id }
        let saved = try? await store.save(preset)
        await refresh()
        if let saved, let id = saved.id, let before, before != saved, status[id]?.isLive == true {
            await stop(id)
            await start(saved)
        }
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

    /// Points every tunnel back here at a different local port. A running
    /// one is restarted: a tunnel looks the port up as it starts.
    func setProxyLocalPort(_ port: Int?) async {
        guard port != proxyLocalPort, port.map(Connector.isPort) ?? true else { return }
        defaults.set(port, forKey: "proxyLocalPort")
        for preset in proxyPresets where preset.proxyRole == .http { await restartIfLive(preset) }
    }

    /// Moves, or with nil turns off, the SOCKS5 half on every server.
    func setProxySocksLocalPort(_ port: Int?) async {
        guard port != proxySocksLocalPort, port.map(Connector.isPort) ?? true else { return }
        defaults.set(port, forKey: "proxySocksLocalPort")
        for preset in proxyPresets where preset.proxyRole == .socks {
            if port == nil { await delete(preset) } else { await restartIfLive(preset) }
        }
    }

    private func restartIfLive(_ preset: PortForwardPreset) async {
        guard let id = preset.id, status[id]?.isLive == true else { return }
        await stop(id)
        await start(preset)
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

    func start(_ preset: PortForwardPreset, attempt: Int = 0) async {
        guard let id = preset.id else { return }
        // A retry is allowed to run while the status still says retrying;
        // anything else that is live is left alone.
        if attempt == 0 && status[id] == .running { return }
        if attempt == 0 && status[id] == .starting { return }
        retries.removeValue(forKey: id)?.cancel()
        guard let model, let server = model.servers.first(where: { $0.id == preset.serverID })
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

        // A proxy half with this Mac's port unset has nowhere to arrive, and
        // trying again will not change that.
        guard let target = targetPort(of: preset) else {
            status[id] = .failed("set this Mac's proxy port in Settings \u{2192} Proxy")
            return
        }

        status[id] = .starting
        let epoch = epochs[id, default: 0]
        do {
            let route = server.routesThroughVPN ? " through the VPN" : ""
            note("forward \(id) starting \(preset.summary) on \(server.host):\(server.port)\(route)")
            let session = try await model.sessions.session(for: server, as: .forwards)
            let forward = try PortForward(
                session: session,
                direction: preset.direction.engineDirection,
                bindHost: preset.bindHost, bindPort: try Connector.port(preset.bindPort),
                // A dynamic forward has no target; its port is 0.
                targetHost: preset.targetHost,
                targetPort: try Connector.port(target))
            try await forward.start { [weak self] in
                // Reported from the far side: the session dropped, or the
                // server cancelled the listener. Without this the row would
                // stay green while the port on the server was gone.
                Task { @MainActor in await self?.tunnelClosed(id) }
            }
            // Switched off, or deleted, while it was coming up.
            guard epochs[id, default: 0] == epoch else {
                await forward.stop()
                await retireSessionIfIdle(preset.serverID)
                return
            }

            forwards[id] = forward
            owner[id] = preset.serverID
            traffic[id] = .init()
            status[id] = .running
            startPolling()
        } catch {
            // Switched off while it was coming up: nothing to report or retry.
            guard epochs[id, default: 0] == epoch else {
                await retireSessionIfIdle(preset.serverID)
                return
            }
            var reason = String(describing: error)
            // A refusal carries no reason in the protocol, so ask while the
            // session is still up rather than leaving the user with "denied".
            if error is SSHSession.ForwardRefusal, let session = model.sessions.existing(preset.serverID) {
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
            await retireSessionIfIdle(preset.serverID)
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
                  let server = model.servers.first(where: { $0.id == preset.serverID }),
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
                  let server = model.servers.first(where: { $0.id == preset.serverID }),
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
            guard !Task.isCancelled, let self else { return }
            // Out of the table first: `start` cancels whatever is in it, and
            // that is this task -- every retry failed with CancellationError.
            self.retries[id] = nil
            // As it is now: edited since, it retries with the new ports;
            // deleted, it does not come back.
            guard let current = self.presets.first(where: { $0.id == id }) else { return }
            await self.start(current, attempt: attempt + 1)
        }
    }

    func stop(_ presetID: Int64) async {
        // Stopping means stopping: a supervised forward that came back after
        // being switched off would be a bug with no way around it.
        retries.removeValue(forKey: presetID)?.cancel()
        epochs[presetID, default: 0] += 1
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

    /// Stops everything a server runs, including tunnels still starting or
    /// waiting to retry, before the server goes.
    func stopAll(forServer serverID: Int64) async {
        let ids = Set(presets.filter { $0.serverID == serverID }.compactMap(\.id))
            .union(owner.filter { $0.value == serverID }.map(\.key))
        for id in ids { await stop(id) }
        await retireSessionIfIdle(serverID, force: true)
    }

    private func sessionDied(_ serverID: Int64, reason: String) async {
        var dead: [PortForward] = []
        for (presetID, owningServer) in owner where owningServer == serverID {
            if let forward = forwards.removeValue(forKey: presetID) { dead.append(forward) }
            owner.removeValue(forKey: presetID)
            if let preset = presets.first(where: { $0.id == presetID }) {
                fail(preset, reason: reason, attempt: 0)
            } else {
                status[presetID] = .failed(reason)
            }
        }
        // The session is already gone, so stopping each forward finds it so
        // at once rather than waiting on a dead socket. Stopped, not just
        // dropped: a local listener dropped keeps its port, and every retry
        // after would fail to bind it.
        for forward in dead { await forward.stop() }
    }

    /// Lets go of a server's session once no forward is using it; forced,
    /// closes it under whoever else holds it, for a session known dead.
    private func retireSessionIfIdle(_ serverID: Int64, force: Bool = false) async {
        if force {
            await model?.sessions.retire(serverID)
        } else if !owner.values.contains(serverID) {
            await model?.sessions.release(serverID, by: .forwards)
        }
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
        let now = ContinuousClock.now
        let elapsed = lastSample.map { now - $0 }
        lastSample = now
        let seconds = elapsed.map { $0 / .seconds(1) } ?? 0
        for (id, forward) in forwards {
            let stats = await forward.stats()
            if let previous = traffic[id] {
                let rate = Rate.between(previous, stats, seconds: seconds)
                // Only on a change: every assignment redraws whatever
                // reads it, and an idle tunnel reads the same each second.
                if rates[id] != rate { rates[id] = rate }
            }
            if traffic[id] != stats { traffic[id] = stats }
        }
        // A tunnel that stopped has no bandwidth, not its last reading.
        if rates.keys.contains(where: { forwards[$0] == nil }) {
            rates = rates.filter { forwards[$0.key] != nil }
        }
    }

    // MARK: - the proxy back to this Mac

    /// Every tunnel that carries a server's traffic back to this Mac, both
    /// halves. The tunnels are the feature -- there is no separate flag on
    /// the server -- so a switch and its tunnels cannot disagree.
    var proxyPresets: [PortForwardPreset] {
        presets.filter { $0.proxyRole != nil }
    }

    /// The tunnels a server's editor lists: everything except the proxy's,
    /// which the proxy's own section and the row's switch look after.
    func plainPresets(forServer id: Int64) -> [PortForwardPreset] {
        presets.filter { $0.serverID == id && $0.proxyRole == nil }
    }

    /// A server's proxy back to this Mac: its HTTP half, which the switch
    /// and the exports follow.
    func proxyBack(for serverID: Int64) -> PortForwardPreset? {
        presets.first { $0.serverID == serverID && $0.proxyRole == .http }
    }

    /// Its HTTP half, only while that is running.
    func runningProxyBack(for serverID: Int64) -> PortForwardPreset? {
        proxyBack(for: serverID).flatMap { http in http.id.map(isRunning) == true ? http : nil }
    }

    /// Its SOCKS5 half, when it has one.
    func proxySocks(for serverID: Int64) -> PortForwardPreset? {
        presets.first { $0.serverID == serverID && $0.proxyRole == .socks }
    }

    /// Its SOCKS5 half, only while that is running.
    func runningProxySocks(for serverID: Int64) -> PortForwardPreset? {
        proxySocks(for: serverID).flatMap { socks in socks.id.map(isRunning) == true ? socks : nil }
    }

    /// Saves a proxy tunnel, filling in everything that makes it one.
    ///
    /// The caller chooses the server, the port on it, whether it is
    /// supervised, and which half it is. The rest is what that means:
    /// reverse, arriving at this Mac's HTTP or SOCKS5 port.
    @discardableResult
    func saveProxy(_ preset: PortForwardPreset) async -> PortForwardPreset? {
        var preset = preset
        preset.direction = .remote
        preset.bindHost = "127.0.0.1"
        preset.targetHost = "127.0.0.1"
        let role = preset.proxyRole ?? .http
        preset.proxyRole = role
        // Not stored: the proxy's port is this Mac's, looked up at start.
        preset.targetPort = 0
        preset.exportsEnvironment = role == .http

        guard let saved = await save(preset), let id = saved.id else { return nil }
        // Restarted, so edited ports take effect now rather than at the next
        // unlock -- and so a tunnel switched from one server to another does
        // not leave the old one listening.
        // Failed too: switched off, it must read as off, not as failed.
        if let state = status[id], state != .stopped { await stop(id) }
        if saved.autoStart { await start(saved) }
        return saved
    }

    /// Turns the proxy tunnel on or off for one server.
    ///
    /// Reads the store rather than the observed list, because this is called
    /// straight after a server is first saved and the observation may not have
    /// caught up.
    /// The switch on a server's row. Lit means its traffic is going through
    /// this Mac -- running, or on its way. Off stops the tunnels but keeps
    /// them, ports and all. Both halves go together.
    ///
    /// The switch is remembered as the tunnels' autoStart, so a proxy left on
    /// comes back the next time the vault opens. A tunnel that drops by itself
    /// is not switched off; only this is.
    func toggleProxyBack(for serverID: Int64) async {
        // No port on the server, no tunnel: there is no default, so the
        // ports are set in the server's editor first.
        guard var http = proxyBack(for: serverID) else { NSSound.beep(); return }
        // Failed counts as on, so a click always switches it off: a tunnel
        // that cannot start -- this Mac's port unset -- must not be stuck.
        let isLit = status(of: http) != .stopped
        http.autoStart = !isLit
        http.keepAlive = true
        // Saving stops a live tunnel, and starts one marked autoStart.
        await saveProxy(http)

        guard var socks = proxySocks(for: serverID) else { return }
        socks.autoStart = !isLit
        socks.keepAlive = true
        await saveProxy(socks)
    }

    /// Sets a server's proxy up, or moves it to new ports. `socksPort` is the
    /// SOCKS5 half's port on the server; nil means there is no SOCKS5 half.
    func setProxyBack(for serverID: Int64, remotePort: Int, socksPort: Int? = nil) async {
        let saved = (try? await store.portForwards(serverID: serverID)) ?? []
        let existingHTTP = saved.first { $0.proxyRole == .http }
        let existingSocks = saved.first { $0.proxyRole == .socks }

        var http = existingHTTP ?? PortForwardPreset(serverID: serverID, direction: .remote,
                                                     bindPort: remotePort, proxyRole: .http)
        http.bindPort = remotePort
        // Started by hand, kept alive once started. Coming up on its own means
        // reaching a server the moment the vault opens, which is a connection
        // nobody asked for -- but a tunnel that drops while in use takes the
        // server's whole route out with it, so that half stays on.
        http.keepAlive = true
        await saveProxy(http)

        guard let socksPort else {
            if let existingSocks { await delete(existingSocks) }
            return
        }
        var socks = existingSocks ?? PortForwardPreset(
            serverID: serverID, direction: .remote, bindPort: socksPort,
            autoStart: http.autoStart, proxyRole: .socks)
        socks.bindPort = socksPort
        socks.keepAlive = true
        await saveProxy(socks)
    }

    func isRunning(_ presetID: Int64) -> Bool { status[presetID] == .running }

    /// Where a tunnel arrives: a proxy half at this Mac's proxy as set now,
    /// anything else where it was told; nil while this Mac's port is unset.
    /// A dynamic forward has no target; 0.
    private func targetPort(of preset: PortForwardPreset) -> Int? {
        switch preset.proxyRole {
        case .http?: proxyLocalPort
        case .socks?: proxySocksLocalPort
        case nil: preset.direction == .dynamic ? 0 : preset.targetPort
        }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("termther: \(message)\n".utf8))
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
