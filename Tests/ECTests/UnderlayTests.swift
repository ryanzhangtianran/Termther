import Net
import Testing
@testable import EC

/// Working out how to get out from under a local TUN proxy.
///
/// This is here because the half-filled case was a real bug: the engine binds
/// to a physical interface whether or not it was told to, so an underlay with
/// an interface and no resolver dials an address that only exists inside the
/// proxy, from a socket that deliberately bypasses it. Every connection failed
/// and the message blamed the gateway.
struct UnderlayTests {
    @Test("what the profile says is kept, whatever the machine looks like")
    func explicitValuesWin() {
        let underlay = EasyConnect.Underlay(interfaceName: "en3", dnsServer: "1.1.1.1")
        let resolved = underlay.resolved()
        #expect(resolved.interfaceName == "en3")
        #expect(resolved.dnsServer == "1.1.1.1")
    }

    @Test("a resolver on its own does not drag an interface in with it")
    func halfFilledIsCompleted() {
        // The other half is filled from the machine rather than left blank,
        // which is the whole point.
        let resolved = EasyConnect.Underlay(dnsServer: "1.1.1.1").resolved()
        #expect(resolved.dnsServer == "1.1.1.1")
        if let interface = resolved.interfaceName {
            #expect(interface.hasPrefix("en"))
        }
    }

    @Test("discovery finds a real interface and a real resolver, or neither")
    func discoveryIsConsistent() {
        let found = EasyConnect.Underlay.discover()
        // Never one without the other: an interface with no resolver is the
        // combination that cannot work.
        #expect((found.interfaceName == nil) == (found.dnsServer == nil))
        if let dns = found.dnsServer {
            // Never the proxy's own placeholder -- that is what it is escaping.
            #expect(!ProxyPlaceholder.matches(dns))
        }
    }

    @Test("only physical interfaces are considered")
    func skipsTunnels() {
        let names = EasyConnect.Underlay.physicalInterfaces()
        // utun, bridge, awdl and the rest are exactly what is being escaped.
        #expect(names.allSatisfy { $0.hasPrefix("en") })
        #expect(Set(names).count == names.count)
    }
}
