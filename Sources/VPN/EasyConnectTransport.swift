import Net

/// The campus VPN, presented as one more way to reach a host.
///
/// With this, `SSHSession.connect(to:over:)` treats a machine behind the campus
/// firewall exactly like one on the open internet. The session never learns a
/// VPN was involved.
public struct EasyConnectTransport: SSHTransport {
    public let vpn: EasyConnect

    public init(vpn: EasyConnect) { self.vpn = vpn }

    public var pathDescription: String { "EasyConnect tunnel" }

    public func connect(host: String, port: UInt16) async throws -> Int32 {
        try await vpn.dial(host: host, port: port)
    }
}
