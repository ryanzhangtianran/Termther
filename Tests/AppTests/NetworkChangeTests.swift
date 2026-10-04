import Testing
@testable import App

/// When a report from the network monitor should rebuild the tunnels.
struct NetworkChangeTests {
    let wifi = ["en0", "192.168.1.1:0"]

    @Test("the first report is the network as it is, not a change")
    func firstReport() {
        #expect(!ServerSessions.isChange(from: nil, to: wifi, isUp: true))
    }

    @Test("the same network again is not a change")
    func unchanged() {
        #expect(!ServerSessions.isChange(from: wifi, to: wifi, isUp: true))
    }

    @Test("another Wi-Fi on the same interface is, by its gateway")
    func newGateway() {
        #expect(ServerSessions.isChange(from: wifi, to: ["en0", "10.0.0.1:0"], isUp: true))
    }

    @Test("nothing is rebuilt while the network is down")
    func down() {
        #expect(!ServerSessions.isChange(from: wifi, to: [], isUp: false))
    }
}
