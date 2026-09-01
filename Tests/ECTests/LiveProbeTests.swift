import Foundation
import Testing
@testable import EC

/// A live probe, run by hand:
///   TERMTHER_EC_GATEWAY=remote.example.edu.cn:443 swift test --filter liveProbe
///
/// Two shapes on purpose. The engine's underlay can be handed in as a value or
/// left to the environment, and if those two disagree the value is being
/// dropped somewhere between Swift and Go -- which is invisible from the app,
/// where it just looks like the gateway is down.
@Test("a live gateway answers when the underlay is passed as a value")
func liveProbeWithValueUnderlay() async {
    guard let gateway = ProcessInfo.processInfo.environment["TERMTHER_EC_GATEWAY"]
    else { return }   // skipped unless asked for

    let found = EasyConnect.Underlay.discover()
    let engine = EasyConnect(underlay: found)
    let result = await engine.probe(gateway: gateway)

    print("underlay: \(found.interfaceName ?? "-") / \(found.dnsServer ?? "-")")
    print("probe: \(result)")
    if case .easyConnect = result {} else {
        Issue.record("value underlay did not reach the gateway: \(result)")
    }
}
