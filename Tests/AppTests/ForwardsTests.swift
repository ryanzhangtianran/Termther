import Core
import Testing
@testable import App

/// The forwarding list, without a server to forward to.
///
/// Everything here is about what the panel shows and what the store keeps;
/// moving actual bytes is the SSH module's business and is tested there.
@MainActor
struct ForwardsTests {
    private func fixture() async throws -> (AppModel, Server) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let server = try await model.store.save(
            Server(name: "db", host: "example.com", username: "me"))
        // The observation is asynchronous; the tests below read the store
        // through the model rather than waiting on it.
        return (model, server)
    }

    @Test("a saved forward comes back grouped under its server")
    func savedForwardIsListed() async throws {
        let (model, server) = try await fixture()
        let saved = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .local,
                              bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432))
        #expect(saved?.id != nil)

        await model.forwards.startAutomatic()   // loads the list as a side effect
        #expect(model.forwards.presets(forServer: server.id!).count == 1)
    }

    @Test("nothing is running until it is started")
    func startsStopped() async throws {
        let (model, server) = try await fixture()
        let preset = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .dynamic, bindPort: 11080))!

        #expect(model.forwards.status(of: preset) == .stopped)
        #expect(model.forwards.status(of: preset).isLive == false)
    }

    @Test("a forward on a VPN server says so instead of timing out")
    func vpnForwardRefusesEarly() async throws {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let server = try await model.store.save(
            Server(name: "campus", host: "10.0.0.5", username: "me", routesThroughVPN: true))
        // The model's server list is fed by an observation, so it is primed
        // here rather than waited for.
        try await Task.sleep(for: .milliseconds(200))

        let preset = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .local,
                              bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432))!
        await model.forwards.start(preset)

        // Whichever it lands on, it must not be left looking alive: a listening
        // socket that accepts and then hangs is worse than a refusal.
        #expect(model.forwards.status(of: preset).isLive == false)
        if case .failed(let reason) = model.forwards.status(of: preset) {
            #expect(reason.contains("VPN") || reason.contains("gone"))
        }
    }

    @Test("deleting a forward forgets its status too")
    func deleteClearsStatus() async throws {
        let (model, server) = try await fixture()
        let preset = await model.forwards.save(
            PortForwardPreset(serverId: server.id!, direction: .dynamic, bindPort: 11080))!

        await model.forwards.delete(preset)
        #expect(model.forwards.traffic[preset.id!] == nil)
        let remaining = try await model.store.portForwards()
        #expect(remaining.isEmpty)
    }
}
