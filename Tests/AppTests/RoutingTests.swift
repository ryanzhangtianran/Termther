import Core
import Net
import Testing
@testable import App

/// Which route a server gets, and when it is refused one.
///
/// The rule is small and easy to get backwards, and getting it backwards is
/// expensive both ways: sending everything through the tunnel makes every
/// off-campus host hang, and sending nothing through it makes the campus hosts
/// hang. Neither failure says which mistake was made, so it is pinned here.
@MainActor
struct RoutingTests {
    private func model() async throws -> AppModel {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        return model
    }

    @Test("a plain server is reached directly, tunnel or no tunnel")
    func plainServerGoesDirect() async throws {
        let model = try await model()
        let server = Server(name: "web", host: "example.com", username: "me")

        #expect(model.vpn.transport(for: server) is DirectTransport)
        #expect(model.needsTunnel(server) == false)
    }

    @Test("a server behind the VPN is refused while the tunnel is down")
    func vpnServerNeedsTheTunnel() async throws {
        let model = try await model()
        let server = Server(name: "campus", host: "10.0.0.5", username: "me",
                            routesThroughVPN: true)

        #expect(model.needsTunnel(server))
        // Still direct, because there is no tunnel to offer -- the refusal
        // below is what stops it being used.
        #expect(model.vpn.transport(for: server) is DirectTransport)

        await #expect(throws: AppModel.Failure.self) {
            _ = try await model.route(to: server)
        }
    }

    @Test("the refusal names the server and the reason")
    func refusalReadsPlainly() {
        let failure = AppModel.Failure.tunnelDown(server: "campus")
        #expect(failure.description.contains("campus"))
        #expect(failure.description.contains("VPN"))
    }
}
