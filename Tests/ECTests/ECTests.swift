import Net
import Testing
@testable import EC

@Test("probing a dead address reaches the Go engine and comes back cleanly")
func probeUnreachable() async {
    let vpn = EasyConnect()
    let result = await vpn.probe(gateway: "127.0.0.1:1")
    guard case .unreachable = result else {
        Issue.record("expected unreachable, got \(result)")
        return
    }
}

@Test("every call refuses politely before login rather than crashing")
func requiresLogin() async {
    let vpn = EasyConnect()
    #expect(await vpn.address == nil)
    await #expect(throws: EasyConnect.Failure.self) { try await vpn.dial(host: "10.0.0.1", port: 22) }
    await #expect(throws: EasyConnect.Failure.self) { try await vpn.resolve("example") }
    await #expect(throws: EasyConnect.Failure.self) { _ = try await vpn.resources() }
}

@Test("the VPN is usable anywhere a transport is")
func isATransport() async {
    let transport: any SSHTransport = EasyConnectTransport(vpn: EasyConnect())
    #expect(transport.pathDescription == "EasyConnect tunnel")
    // Not logged in, so it must refuse rather than dial.
    await #expect(throws: EasyConnect.Failure.self) {
        _ = try await transport.connect(host: "10.0.0.1", port: 22)
    }
}
