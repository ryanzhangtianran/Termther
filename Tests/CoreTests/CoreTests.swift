import VPN
import SSH
import Testing

/// Confirms every vendored engine linked and runs, by calling into each one
/// rather than merely referencing it.
@Test("every vendored engine links and runs")
func enginesLink() async {
    #expect(SSHLinkCheck.libssh2Version.hasPrefix("1."), "libssh2 failed its link check")

    // Port 1 on loopback has nothing listening: the answer we want is a clean
    // "unreachable", proving the call path works.
    let probed = switch await EasyConnect().probe(gateway: "127.0.0.1:1") {
    case .unreachable: true
    default: false
    }
    #expect(probed, "easyconnect failed its link check")
}
