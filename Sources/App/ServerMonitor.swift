import Core
import Foundation
import Observation
import SSH

/// What the servers are doing: CPU, memory, GPUs, load.
///
/// Runs for as long as the vault is open, but never dials on its own: every
/// 15 seconds it asks each server whose session is already up -- for a
/// forward, or for the Connections page -- over that session. The page,
/// while open, asks it to `watch(all:)`, which is what opens a session to
/// the rest; when the page closes it lets go of them, and any nobody else
/// holds is closed. So the sidebar always knows the load of the servers the
/// app is connected to, and opening the page is what connects to the others.
///
/// A probe is one exec, no sleep: the CPU figure is worked out from the
/// counters the previous probe brought back.
@MainActor
@Observable
final class ServerMonitor {
    /// What the last probe said; a server is green with a load and no
    /// error, red with an error, and unmarked with neither. The figures
    /// outlive the session, so a card is not blank while one is reopened.
    private(set) var loads: [Int64: ServerLoad] = [:]
    private(set) var errors: [Int64: String] = [:]
    private(set) var probing: Set<Int64> = []
    private(set) var watchingAll = false

    private var ticker: Task<Void, Never>?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.probeAll()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        watch(all: false)
    }

    /// Whether to open a session to every server that has none, as the
    /// Connections page wants, or only to listen in on the ones that are up.
    func watch(all: Bool) {
        watchingAll = all
        if all {
            probeAll()
        } else {
            Task { await model?.sessions.releaseAll(by: .monitor) }
        }
    }

    private func probeAll() {
        guard let model else { return }
        let servers = model.servers
        let present = Set(servers.compactMap(\.id))
        for server in servers {
            guard let id = server.id, !probing.contains(id) else { continue }
            let isLive = model.sessions.existing(id) != nil
            // Not ours to dial, or ours but behind a VPN that is down: the
            // card says "VPN off" itself, which is not an error of the probe.
            let dial = watchingAll && !model.needsTunnel(server)
            guard isLive || dial else { errors[id] = nil; continue }
            probing.insert(id)
            Task { await self.probe(server, id: id, dial: dial) }
        }
        // A server deleted meanwhile takes its figures with it.
        for id in Set(loads.keys).union(errors.keys) where !present.contains(id) { forget(id) }
    }

    private func probe(_ server: Server, id: Int64, dial: Bool) async {
        defer { probing.remove(id) }
        guard let model else { return }
        let session: SSHSession
        do {
            if dial {
                session = try await model.sessions.session(for: server, as: .monitor)
            } else if let existing = model.sessions.existing(id) {
                session = existing
            } else {
                return
            }
        } catch {
            errors[id] = String(describing: error)
            return
        }

        // Raced against a clock rather than run in a task group: a group
        // waits for every child, and a cancelled exec blocked in libssh2
        // would not notice. The clock retires the session instead, which
        // ends every wait inside it (AGENTS.md) -- a server that cannot run
        // one script in 15 seconds is not carrying anyone's tunnel either.
        let exec = Task { try await session.exec(ServerLoad.script) }
        let clock = Task { () -> Bool in
            do { try await Task.sleep(for: .seconds(15)) } catch { return false }
            await model.sessions.retire(id, because: "no answer within 15 seconds")
            return true
        }
        do {
            let result = try await exec.value
            clock.cancel()
            let previous = loads[id]
            loads[id] = ServerLoad.parse(result.stdout, after: previous)
            errors[id] = nil
            // The CPU figure is a difference between two probes, so the
            // first answer has none; a second a moment later fills it in
            // rather than leaving the row empty for 15 seconds.
            if previous == nil, loads[id]?.cpuPercent == nil {
                try? await Task.sleep(for: .seconds(1))
                if let again = try? await session.exec(ServerLoad.script) {
                    loads[id] = ServerLoad.parse(again.stdout, after: loads[id])
                }
            }
        } catch {
            clock.cancel()
            // Not retired here: a session that cannot open one more channel
            // may still be carrying tunnels, and the keepalive finds a dead
            // one within the half minute.
            errors[id] = await clock.value ? "no answer within 15 seconds" : String(describing: error)
        }
    }

    private func forget(_ id: Int64) {
        loads[id] = nil
        errors[id] = nil
    }
}
