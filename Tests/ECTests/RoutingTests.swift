import Foundation
import Testing
@testable import EC

/// Reading the ACL the gateway grants.
///
/// This matters more than it looks: a Sangfor gateway silently drops traffic
/// to anything outside the list rather than refusing it, so a host missing
/// here is indistinguishable from a broken tunnel unless the list is on
/// screen.
struct RoutingTests {
    private func decode(_ json: String) throws -> EasyConnect.Routing {
        try JSONDecoder().decode(EasyConnect.Routing.self, from: Data(json.utf8))
    }

    @Test("a range with no port restriction says so rather than showing zeroes")
    func allPorts() throws {
        let routing = try decode("""
            {"ip":[{"from":"10.0.0.0","to":"10.255.255.255","portMin":0,
              "portMax":0,"protocol":"tcp"}],"domains":[],"dns":[]}
            """)
        let range = try #require(routing.ip.first)
        #expect(range.ports == "all ports")
        #expect(range.addresses == "10.0.0.0 \u{2013} 10.255.255.255")
        #expect(range.protocolName == "tcp")
    }

    @Test("a single address is not written as a range to itself")
    func singleAddress() throws {
        let routing = try decode("""
            {"ip":[{"from":"10.1.2.3","to":"10.1.2.3","portMin":22,
              "portMax":22,"protocol":"tcp"}],"domains":[],"dns":[]}
            """)
        let range = try #require(routing.ip.first)
        #expect(range.addresses == "10.1.2.3")
        #expect(range.ports == "port 22")
    }

    @Test("a port range reads as one")
    func portRange() throws {
        let routing = try decode("""
            {"ip":[{"from":"10.0.0.1","to":"10.0.0.9","portMin":8000,
              "portMax":8100,"protocol":"tcp"}],"domains":[],"dns":[]}
            """)
        #expect(routing.ip.first?.ports == "ports 8000\u{2013}8100")
    }

    @Test("domains and DNS servers come through")
    func domainsAndDNS() throws {
        let routing = try decode("""
            {"ip":[],"domains":["git.example.edu.cn","mail.example.edu.cn"],
             "dns":["10.10.0.21","10.10.0.22"]}
            """)
        #expect(routing.domains.count == 2)
        #expect(routing.dns == ["10.10.0.21", "10.10.0.22"])
        #expect(!routing.isEmpty)
    }

    @Test("an empty grant is recognised as empty rather than shown as a table")
    func emptyGrant() throws {
        let routing = try decode(#"{"ip":[],"domains":[],"dns":[]}"#)
        #expect(routing.isEmpty)
    }

    @Test("ranges are distinguishable, so a list of them does not collapse")
    func rangesHaveDistinctIdentity() throws {
        let routing = try decode("""
            {"ip":[{"from":"10.0.0.1","to":"10.0.0.1","portMin":22,"portMax":22,"protocol":"tcp"},
                   {"from":"10.0.0.1","to":"10.0.0.1","portMin":80,"portMax":80,"protocol":"tcp"}],
             "domains":[],"dns":[]}
            """)
        // Same addresses, different ports: identified by both, or SwiftUI
        // shows one row where there are two.
        #expect(Set(routing.ip.map(\.id)).count == 2)
    }
}
