import Core
import Testing
@testable import App

/// The switch on a server that puts its traffic through this Mac.
///
/// It is one switch to the user and an ordinary reverse forward underneath.
/// These pin that translation, because getting it wrong in either direction is
/// silent: a tunnel with no environment behind it does nothing, and an
/// environment with no tunnel behind it breaks every command on the server.
@MainActor
struct ProxyBackTests {
    private func fixture() async throws -> (AppModel, Server) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let server = try await model.store.save(
            Server(name: "gpu", host: "example.com", username: "me"))
        return (model, server)
    }

    @Test("switching it on creates a reverse forward, left for the user to start")
    func createsTheForward() async throws {
        let (model, server) = try await fixture()
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 16152)

        let saved = try await model.store.portForwards(serverID: server.id!)
        #expect(saved.count == 1)
        let preset = try #require(saved.first)
        #expect(preset.direction == .remote)
        // The server's port is the one it listens on; ours is where the
        // connections come out.
        #expect(preset.bindPort == 16152)
        #expect(preset.targetPort == 6152)
        #expect(preset.exportsEnvironment)
        // Not automatic: coming up on its own would dial a server the moment
        // the vault opens. Kept alive once started, because a tunnel that
        // drops while in use takes the server's whole route out with it.
        #expect(preset.autoStart == false)
        #expect(preset.keepAlive)
    }

    @Test("changing the server's port edits the same forward rather than adding one")
    func editsInPlace() async throws {
        let (model, server) = try await fixture()
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 16152)
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 17890)

        let saved = try await model.store.portForwards(serverID: server.id!)
        #expect(saved.count == 1)
        #expect(saved.first?.bindPort == 17890)
        // The port on this Mac is not a per-server choice: it is where the
        // proxy runs, and it is set once for the machine.
        #expect(saved.first?.targetPort == model.forwards.proxyLocalPort)
    }

    @Test("switching it off takes the forward with it")
    func removesTheForward() async throws {
        let (model, server) = try await fixture()
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 16152)
        await model.forwards.setProxyBack(false, for: server.id!, remotePort: 16152)

        let saved = try await model.store.portForwards(serverID: server.id!)
        #expect(saved.isEmpty)
        #expect(model.forwards.proxyBack(for: server.id!) == nil)
    }

    @Test("the tunnel shows up in the forwards panel like any other")
    func appearsInTheList() async throws {
        let (model, server) = try await fixture()
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 16152)

        // The panel groups by server and reads exactly this. A switch that
        // created something invisible would be a switch with no way to see
        // whether it worked.
        let listed = model.forwards.presets(forServer: server.id!)
        #expect(listed.count == 1)
        #expect(listed.first?.direction == .remote)
    }

    @Test("the proxy tunnel is kept out of the server's own forward list")
    func notListedTwice() async throws {
        let (model, server) = try await fixture()
        _ = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .local,
                              bindPort: 8080, targetHost: "127.0.0.1", targetPort: 80))
        await model.forwards.setProxyBack(true, for: server.id!, remotePort: 16152)
        await model.forwards.startAutomatic()

        // Both exist, but the proxy tunnel has a panel of its own; showing it
        // under the server as well would read as two separate tunnels.
        #expect(model.forwards.presets(forServer: server.id!).count == 2)
        let plain = model.forwards.plainPresets(forServer: server.id!)
        #expect(plain.count == 1)
        #expect(plain.first?.direction == .local)
    }

    @Test("moving the local proxy port moves every tunnel with it")
    func portChangeAppliesToAll() async throws {
        let (model, first) = try await fixture()
        let second = try await model.store.save(
            Server(name: "cpu", host: "example.net", username: "me"))
        await model.forwards.setProxyBack(true, for: first.id!, remotePort: 16152)
        await model.forwards.setProxyBack(true, for: second.id!, remotePort: 16152)

        await model.forwards.setProxyLocalPort(7890)

        // They all mean "the proxy on this Mac", so they cannot be allowed to
        // drift apart -- one left behind would point at nothing.
        let saved = try await model.store.portForwards()
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.targetPort == 7890 })
        #expect(model.forwards.proxyLocalPort == 7890)
    }

    @Test("an ordinary reverse forward is not mistaken for the proxy switch")
    func plainReverseForwardIsNotTheSwitch() async throws {
        let (model, server) = try await fixture()
        _ = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .remote,
                              bindPort: 9000, targetHost: "127.0.0.1",
                              targetPort: 9000))
        await model.forwards.startAutomatic()   // loads the list

        // Same direction, but it does not export anything, so the server
        // editor's switch must stay off rather than claiming this one.
        #expect(model.forwards.proxyBack(for: server.id!) == nil)
    }
}

/// A proxy tunnel as a saved thing you edit, rather than a switch with
/// defaults behind it.
@MainActor
struct ProxyEditingTests {
    private func fixture() async throws -> (AppModel, Server, Server) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let first = try await model.store.save(
            Server(name: "gpu", host: "a.example.com", username: "me"))
        let second = try await model.store.save(
            Server(name: "cpu", host: "b.example.com", username: "me"))
        return (model, first, second)
    }

    @Test("saving fills in everything that makes it a proxy tunnel")
    func savingFillsTheInvariants() async throws {
        let (model, server, _) = try await fixture()
        // Only the parts a person chooses are set here; the rest is what being
        // a proxy tunnel means.
        let saved = await model.forwards.saveProxy(
            PortForwardPreset(serverId: server.id!, direction: .local,
                              bindPort: 16152, autoStart: true, keepAlive: true))

        let preset = try #require(saved)
        #expect(preset.direction == .remote)
        #expect(preset.exportsEnvironment)
        #expect(preset.bindHost == "127.0.0.1")
        #expect(preset.targetHost == "127.0.0.1")
        #expect(preset.targetPort == model.forwards.proxyLocalPort)
    }

    @Test("editing keeps one tunnel rather than leaving the old one behind")
    func editingMovesTheSameRow() async throws {
        let (model, first, second) = try await fixture()
        var preset = try #require(await model.forwards.saveProxy(
            PortForwardPreset(serverId: first.id!, direction: .remote, bindPort: 16152)))

        // Pointed at a different server, which is the edit most likely to
        // leave a stray tunnel listening on the first one.
        preset.serverId = second.id!
        preset.bindPort = 16200
        await model.forwards.saveProxy(preset)

        let saved = try await model.store.portForwards()
        #expect(saved.count == 1)
        #expect(saved.first?.serverId == second.id!)
        #expect(saved.first?.bindPort == 16200)
        #expect(model.forwards.proxyBack(for: first.id!) == nil)
        #expect(model.forwards.proxyBack(for: second.id!) != nil)
    }

    @Test("a supervised tunnel is not left claiming to run after it drops")
    func retriesRatherThanLyingAboutIt() async throws {
        let (model, server) = try await (fixture().0, fixture().1)
        _ = server
        // A server that cannot be reached: starting fails, and with keepAlive
        // the honest state is "retrying", not "failed" and not "running".
        let saved = try await model.store.save(
            Server(name: "gone", host: "127.0.0.1", port: 1, username: "me"))
        let preset = try #require(await model.forwards.saveProxy(
            PortForwardPreset(serverId: saved.id!, direction: .remote,
                              bindPort: 16152, autoStart: true, keepAlive: true)))
        await model.forwards.startAutomatic()

        let status = model.forwards.status(of: preset)
        #expect(status != .running)
        if case .retrying = status {} else if case .failed = status {} else {
            Issue.record("expected a retry or a failure, got \(status)")
        }
    }
}

/// The whole chain: off campus, through the VPN, onto a server, and the
/// server's traffic back out through this Mac.
///
/// The pieces are tested apart; what is easy to get wrong is the order they
/// come up in, which is what these are about.
@MainActor
struct TunnelOrderTests {
    private func fixture() async throws -> (AppModel, Server) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let server = try await model.store.save(
            Server(name: "campus", host: "10.0.0.5", username: "me",
                   routesThroughVPN: true))
        // The server list is fed by an observation.
        try await Task.sleep(for: .milliseconds(200))
        return (model, server)
    }

    @Test("a campus tunnel says what it is waiting for, rather than timing out")
    func waitsForTheVPN() async throws {
        let (model, server) = try await fixture()
        let preset = try #require(await model.forwards.saveProxy(
            PortForwardPreset(serverId: server.id!, direction: .remote,
                              bindPort: 16152, autoStart: true, keepAlive: true)))

        // Started at unlock, before anyone has connected the VPN.
        await model.forwards.startAutomatic()

        // Not running, and the reason names the switch to flip rather than
        // reporting a connection that went nowhere.
        #expect(model.forwards.status(of: preset) != .running)
        let reason = model.forwards.status(of: preset).detail ?? ""
        #expect(reason.contains("VPN"), "expected the VPN to be named, got: \(reason)")
    }

    @Test("a tunnel switched off by hand is not restarted by connecting the VPN")
    func manualStopSurvivesTheVPNComingUp() async throws {
        let (model, server) = try await fixture()
        let preset = try #require(await model.forwards.saveProxy(
            PortForwardPreset(serverId: server.id!, direction: .remote,
                              bindPort: 16152, autoStart: true, keepAlive: true)))
        await model.forwards.startAutomatic()

        await model.forwards.stop(preset.id!)
        #expect(model.forwards.status(of: preset) == .stopped)

        // Connecting a VPN is not a request to undo a deliberate stop.
        await model.forwards.resumeWaitingOnTunnel()
        #expect(model.forwards.status(of: preset) == .stopped)
    }
}
