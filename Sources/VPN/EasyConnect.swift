import CEC
import Darwin
import Foundation
import Net

/// A session on a Sangfor EasyConnect gateway.
///
/// The protocol runs in this process, in the Rust engine in `EC/` (linked as
/// `CEC`): the login, the packet tunnel and a small TCP/IP stack on top of it.
/// The same engine is `termther-ec` on Linux. There is no TUN device, no root
/// access, no system-wide routing change and no helper app. Only Termther's
/// own traffic goes through the tunnel.
///
/// What stays here is what is particular to macOS: finding the physical
/// interface and its DHCP resolver.
public actor EasyConnect {
    public struct Credentials: Sendable {
        public var username: String
        public var password: String
        /// Base32 TOTP secret, when the account carries a second factor.
        public var totpSecret: String?

        public init(username: String, password: String, totpSecret: String? = nil) {
            self.username = username
            self.password = password
            self.totpSecret = totpSecret
        }
    }

    /// How the engine's own outbound socket reaches the gateway.
    ///
    /// These exist because of local TUN proxies. Surge, Clash and sing-box take
    /// the default route and answer DNS with addresses in 198.18.0.0/15, so
    /// without pinning an interface and a resolver the engine dials the proxy
    /// instead of the gateway and fails during the TLS handshake -- which
    /// reads, misleadingly, as the gateway being down.
    public struct Underlay: Sendable {
        /// Physical interface to bind to, e.g. "en1".
        public var interfaceName: String?
        /// Resolver for the gateway's own hostname, e.g. "10.90.63.2".
        public var dnsServer: String?

        public init(interfaceName: String? = nil, dnsServer: String? = nil) {
            self.interfaceName = interfaceName
            self.dnsServer = dnsServer
        }

        /// Fills in whatever was left blank by looking at the machine.
        ///
        /// This exists because half-pinning is worse than not pinning at all.
        /// The engine already binds to a physical interface whether or not it
        /// was told to, so leaving the resolver blank produces the one
        /// combination that cannot work: the name is resolved by the proxy,
        /// which answers with an address that only means something inside the
        /// proxy, and then dialled from a socket that deliberately bypasses
        /// it. Every connection fails, and the error says the gateway is
        /// unreachable.
        public func resolved() -> Underlay {
            if interfaceName != nil && dnsServer != nil { return self }
            let found = Underlay.discover()
            return Underlay(interfaceName: interfaceName ?? found.interfaceName,
                            dnsServer: dnsServer ?? found.dnsServer)
        }

        /// The first physical interface with an address and a resolver of its
        /// own.
        ///
        /// The resolver comes from the DHCP lease rather than the system
        /// configuration, because that is the one place a TUN proxy does not
        /// overwrite: it changes what the machine resolves with, not what the
        /// network handed out.
        static func discover() -> Underlay {
            for name in physicalInterfaces() {
                guard let dns = dhcpResolver(for: name),
                      !ProxyPlaceholder.matches(dns) else { continue }
                return Underlay(interfaceName: name, dnsServer: dns)
            }
            return Underlay()
        }

        /// Ethernet and Wi-Fi interfaces that currently have an IPv4 address.
        static func physicalInterfaces() -> [String] {
            var addresses: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
            defer { freeifaddrs(addresses) }

            var found: [String] = []
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(pointer.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                      pointer.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
                else { continue }
                let name = String(cString: pointer.pointee.ifa_name)
                // en* is Ethernet and Wi-Fi; utun* and friends are exactly
                // what this is trying to get out from under.
                guard name.hasPrefix("en"), !found.contains(name) else { continue }
                found.append(name)
            }
            return found
        }

        /// What DHCP told this interface to use, if anything.
        static func dhcpResolver(for interface: String) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getoption", interface, "domain_name_server"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case login(String)
        case notConnected
        case resolve(String)
        case dial(String)

        public var description: String {
            switch self {
            case .login(let d):          "EasyConnect login failed: \(d)"
            case .notConnected:          "not connected to the VPN"
            case .resolve(let d):        "resolve through tunnel: \(d)"
            case .dial(let d):           "dial through tunnel: \(d)"
            }
        }
    }

    public enum Probe: Sendable, Equatable {
        case easyConnect(detail: String)
        case somethingElse(detail: String)
        case unreachable(detail: String)
    }

    private var session: Handle?
    private let underlay: Underlay

    public init(underlay: Underlay = Underlay()) {
        self.underlay = underlay
    }

    /// The tunnel address the gateway handed this client, once connected.
    /// Distinct from any local address, and only obtainable through a real
    /// tunnel -- which makes it the honest proof that one exists.
    public var address: String? { session?.address }

    /// Asks a gateway what it is, without credentials.
    ///
    /// A Sangfor EasyConnect gateway answers `/por/login_auth.csp` with XML and
    /// a TWFID cookie. Anything else is most likely aTrust, Sangfor's newer
    /// product, which speaks a different protocol.
    public func probe(gateway: String) -> Probe {
        let underlay = underlay.resolved()
        var detail: UnsafeMutablePointer<CChar>?
        let kind = ec_probe(gateway, underlay.interfaceName ?? "", underlay.dnsServer ?? "", &detail)
        let text = take(detail) ?? ""
        switch kind {
        case 0: return .easyConnect(detail: text)
        case 1: return .somethingElse(detail: text)
        default: return .unreachable(detail: text)
        }
    }

    @discardableResult
    public func login(gateway: String, credentials: Credentials) throws -> String {
        logout()
        let underlay = underlay.resolved()
        var error: UnsafeMutablePointer<CChar>?
        guard let raw = ec_login(gateway, credentials.username, credentials.password,
                                 credentials.totpSecret ?? "", underlay.interfaceName ?? "",
                                 underlay.dnsServer ?? "", &error)
        else { throw Failure.login(take(error) ?? "unknown error") }
        let session = Handle(raw)
        self.session = session
        return session.address
    }

    public func logout() {
        session?.close()
        session = nil
    }

    /// Why the tunnel stopped carrying traffic, or nil while it still does.
    /// A tunnel that breaks and cannot be reopened reports the reason here and
    /// ends. It never takes the app down with it.
    public func tunnelFailure() -> String? { session.flatMap { take(ec_failure($0.raw)) } }

    /// What the gateway will route for this session: allowed ranges, ports and
    /// DNS servers. Worth showing, because traffic outside the list is silently
    /// dropped instead of refused, which looks like a hang.
    public struct Routing: Sendable, Codable, Equatable {
        public struct Range: Sendable, Codable, Equatable, Identifiable {
            public var from: String
            public var to: String
            public var portMin: Int
            public var portMax: Int
            public var protocolName: String

            public var id: String { "\(from)-\(to)-\(portMin)-\(portMax)-\(protocolName)" }

            enum CodingKeys: String, CodingKey {
                case from, to, portMin, portMax
                case protocolName = "protocol"
            }

            /// `10.0.0.0 – 10.255.255.255`, or the single address.
            public var addresses: String {
                from == to ? from : "\(from) \u{2013} \(to)"
            }

            /// Zero for both ends means the gateway did not restrict ports.
            public var ports: String {
                if portMin == 0 && portMax == 0 { return "all ports" }
                if portMin == portMax { return "port \(portMin)" }
                return "ports \(portMin)\u{2013}\(portMax)"
            }
        }

        public var ip: [Range] = []
        public var domains: [String] = []
        public var dns: [String] = []

        public var isEmpty: Bool { ip.isEmpty && domains.isEmpty && dns.isEmpty }
    }

    public func routing() throws -> Routing {
        guard let session else { throw Failure.notConnected }
        return session.routing
    }

    /// Resolves a name using the DNS servers the gateway advertised, over the
    /// tunnel. This is the only way to reach split-horizon names.
    public func resolve(_ host: String) async throws -> String {
        guard let session else { throw Failure.notConnected }
        return try await Self.blocking {
            var error: UnsafeMutablePointer<CChar>?
            guard let address = take(ec_resolve(session.raw, host, &error)) else {
                throw Failure.resolve(take(error) ?? "unknown error")
            }
            return address
        }
    }

    /// Opens a TCP connection inside the tunnel and returns a real descriptor:
    /// one end of a socketpair, with the stack pumping the other end.
    public func dial(host: String, port: UInt16) async throws -> Int32 {
        guard let session else { throw Failure.notConnected }
        return try await Self.blocking {
            var error: UnsafeMutablePointer<CChar>?
            let fd = ec_dial(session.raw, host, port, &error)
            guard fd >= 0 else { throw Failure.dial(take(error) ?? "unknown error") }
            return fd
        }
    }

    /// Runs a blocking engine call on its own thread, so a slow dial holds up
    /// neither the actor nor Swift's cooperative pool. The closure keeps the
    /// handle alive, so a logout meanwhile makes the call fail, not crash.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Re-reads the machine's interface and resolver and hands them over.
    ///
    /// Worth doing periodically rather than once. The session reopens a broken
    /// stream on its own, dialing with whatever it was last told. Values
    /// discovered on one network are wrong on the next, and a resolver that no
    /// longer answers turns every lookup into a timeout.
    public func refreshUnderlay() {
        guard let session else { return }
        let underlay = underlay.resolved()
        ec_set_underlay(session.raw, underlay.interfaceName ?? "", underlay.dnsServer ?? "")
    }
}

/// Owns one engine session. `ec_free` runs when the last reference goes, which
/// is after any call still using it has returned.
private final class Handle: @unchecked Sendable {
    let raw: OpaquePointer
    let address: String
    let routing: EasyConnect.Routing

    init(_ raw: OpaquePointer) {
        self.raw = raw
        address = take(ec_address(raw)) ?? ""
        routing = take(ec_routing_json(raw))
            .flatMap { try? JSONDecoder().decode(EasyConnect.Routing.self, from: Data($0.utf8)) }
            ?? EasyConnect.Routing()
    }

    deinit { ec_free(raw) }

    func close() { ec_close(raw) }
}

/// Copies a string the engine returned, and frees it.
private func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
    guard let string else { return nil }
    defer { ec_string_free(string) }
    return String(cString: string)
}
