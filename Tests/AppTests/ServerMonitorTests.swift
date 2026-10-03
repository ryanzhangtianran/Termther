import Core
import Testing
@testable import App

/// The load probing, without a server to probe.
@MainActor
struct ServerMonitorTests {
    private func model(with server: Server) async throws -> (AppModel, Int64) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let saved = try await model.store.save(server)
        // The model loads its servers in the background.
        for _ in 0..<100 where !model.servers.contains(where: { $0.id == saved.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.servers.contains { $0.id == saved.id })
        return (model, saved.id!)
    }

    @Test("a server behind a VPN that is down is left alone, not dialled")
    func tunnelDownIsNotDialled() async throws {
        let (model, id) = try await model(with:
            Server(name: "lab", host: "10.0.0.2", username: "me", routesThroughVPN: true))
        model.monitor.watch(all: true)
        try await Task.sleep(for: .milliseconds(100))
        defer { model.monitor.stop() }

        #expect(model.monitor.probing.isEmpty)
        #expect(model.monitor.errors[id] == nil)
        #expect(model.monitor.loads.isEmpty)
    }

    @Test("a server with no session up is not dialled unless the page asks")
    func doesNotDialOnItsOwn() async throws {
        let (model, id) = try await model(with:
            Server(name: "db", host: "127.0.0.1", port: 1, username: "me"))
        // Unlocking started the monitor; a tick has happened.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.monitor.probing.isEmpty)
        #expect(model.monitor.errors[id] == nil)

        model.monitor.watch(all: true)
        try await Task.sleep(for: .milliseconds(300))
        defer { model.monitor.stop() }
        // Dialled now, and the dial failed: no credential, nothing listening.
        #expect(model.sessions.logins == 1)
        #expect(model.monitor.errors[id] != nil)
    }
}
