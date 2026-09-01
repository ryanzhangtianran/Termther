import Core
import Foundation
import Testing
@testable import App

/// One gateway, however many times it is saved.
///
/// The engine is a Go archive with process-global state: a second login
/// replaces the first without saying so. Keeping exactly one saved gateway is
/// how that limit is made visible instead of surprising.
@MainActor
struct GatewayTests {
    private func model() async throws -> AppModel {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        return model
    }

    private func profile(_ name: String) -> VPNProfile {
        VPNProfile(name: name, gateway: "\(name).example.edu.cn:443", username: "me",
                   sealed: .init(ciphertext: Data([1]), nonce: Data([2])))
    }

    @Test("saving a second gateway replaces the first")
    func onlyEverOne() async throws {
        let model = try await model()
        await model.vpn.save(profile("first"))
        await model.vpn.save(profile("second"))

        let saved = try await model.store.vpnProfiles()
        #expect(saved.count == 1)
        #expect(saved.first?.name == "second")
        #expect(model.vpn.profile?.name == "second")
    }

    @Test("the saved gateway is there after the vault opens")
    func loadsOnUnlock() async throws {
        let model = try await model()
        await model.vpn.save(profile("campus"))
        model.lock()

        await model.unlock(password: "test-password")
        #expect(model.vpn.profile?.name == "campus")
    }

    @Test("deleting leaves nothing behind")
    func deleteClears() async throws {
        let model = try await model()
        await model.vpn.save(profile("campus"))
        let saved = try #require(model.vpn.profile)

        await model.vpn.delete(saved)
        #expect(model.vpn.profile == nil)
        #expect(try await model.store.vpnProfiles().isEmpty)
    }
}

/// Turning the tunnel on for a server from the VPN panel.
///
/// The same flag as the server editor's toggle, reached from the other side:
/// "which machines is this tunnel for" is a question about the tunnel.
@MainActor
struct RoutedServersTests {
    private func fixture() async throws -> (AppModel, Server) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let server = try await model.store.save(
            Server(name: "gpu", host: "10.0.0.5", username: "me"))
        try await Task.sleep(for: .milliseconds(200))
        return (model, server)
    }

    @Test("ticking a server routes it through the tunnel")
    func ticking() async throws {
        let (model, server) = try await fixture()
        #expect(server.routesThroughVPN == false)

        await model.setRoutesThroughVPN(true, for: server)
        let saved = try await model.store.server(id: server.id!)
        #expect(saved?.routesThroughVPN == true)
    }

    @Test("unticking puts it back")
    func unticking() async throws {
        let (model, server) = try await fixture()
        await model.setRoutesThroughVPN(true, for: server)
        var current = try #require(try await model.store.server(id: server.id!))

        await model.setRoutesThroughVPN(false, for: current)
        current = try #require(try await model.store.server(id: server.id!))
        #expect(current.routesThroughVPN == false)
    }

    @Test("setting it to what it already is writes nothing")
    func noPointlessWrite() async throws {
        let (model, server) = try await fixture()
        let before = try #require(try await model.store.server(id: server.id!))

        await model.setRoutesThroughVPN(false, for: server)
        let after = try #require(try await model.store.server(id: server.id!))
        // updatedAt would have moved on a save, and a row rewritten for no
        // reason is a row that shows up as changed everywhere downstream.
        #expect(before.updatedAt == after.updatedAt)
    }
}
