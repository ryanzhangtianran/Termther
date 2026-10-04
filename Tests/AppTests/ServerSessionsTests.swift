import Core
import Testing
@testable import App

/// The one session per server that forwards and the monitor share.
@MainActor
struct ServerSessionsTests {
    @Test("two callers asking for a server at once share one login")
    func concurrentCallersShareOneLogin() async throws {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        // No credential: the route is refused before anything is dialled,
        // so both callers fail fast, and must fail from the same login.
        let server = try await model.store.save(Server(name: "db", host: "127.0.0.1", port: 1, username: "me"))

        async let first = model.sessions.session(for: server, as: .forwards)
        async let second = model.sessions.session(for: server, as: .monitor)
        var failures = 0
        do { _ = try await first } catch { failures += 1 }
        do { _ = try await second } catch { failures += 1 }

        #expect(failures == 2)
        #expect(model.sessions.logins == 1)
        #expect(model.sessions.sessions.isEmpty)
    }

    @Test("a server that has not been saved has no session")
    func unsavedServerIsRefused() async throws {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        await #expect(throws: ServerSessions.Failure.self) {
            _ = try await model.sessions.session(for: Server(name: "x", host: "h", username: "me"), as: .forwards)
        }
        #expect(model.sessions.logins == 0)
    }
}
