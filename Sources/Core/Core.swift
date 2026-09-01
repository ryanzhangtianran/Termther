import EC
import Net
import SSH

public enum Termther {
    /// Confirms every vendored engine linked and runs, by calling into each
    /// one rather than merely referencing it.
    public static func selfCheck() async -> [(engine: String, ok: Bool)] {
        let vpn = EasyConnect()
        // Port 1 on loopback has nothing listening: the answer we want is a
        // clean "unreachable" from the Go side, proving the call path works.
        let vpnReachedGo: Bool = switch await vpn.probe(gateway: "127.0.0.1:1") {
        case .unreachable: true
        default: false
        }
        return [
            ("libssh2", SSHLinkCheck.libssh2Version.hasPrefix("1.")),
            ("easyconnect", vpnReachedGo),
        ]
    }
}
