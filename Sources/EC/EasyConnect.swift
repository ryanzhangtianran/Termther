import CECShim
import Darwin
import Foundation
import Net

/// A session on a Sangfor EasyConnect gateway.
///
/// The protocol is implemented by the EasyConnect engine in
/// Vendor/easierconnect (AGPL-3.0), linked as a Go c-archive so the tunnel
/// lives inside this process: no TUN device, no root, no system-wide routing
/// change, no helper app. Only Termther's own traffic goes through it.
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
        case notEasyConnect(String)
        case unreachable(String)
        case login(String)
        case notConnected
        case resolve(String)
        case dial(String)

        public var description: String {
            switch self {
            case .notEasyConnect(let d): "gateway does not speak EasyConnect: \(d)"
            case .unreachable(let d):    "gateway unreachable: \(d)"
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

    private var assignedAddress: String?
    private let underlay: Underlay

    public init(underlay: Underlay = Underlay()) {
        self.underlay = underlay
    }

    /// The tunnel address the gateway handed this client, once connected.
    /// Distinct from any local address, and only obtainable through a real
    /// tunnel -- which makes it the honest proof that one exists.
    public var address: String? { assignedAddress }

    /// Asks a gateway what it is, without credentials.
    ///
    /// A Sangfor EasyConnect gateway answers `/por/login_auth.csp` with XML and
    /// a TWFID cookie. Anything else is most likely aTrust, Sangfor's newer
    /// product, which speaks a different protocol.
    public func probe(gateway: String) -> Probe {
        applyUnderlay()
        let raw = withCStrings([gateway]) { argv in
            ec_detect(argv[0]).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? ""
        }
        let fields = raw.split(separator: "|", maxSplits: 2).map(String.init)
        let detail = fields.dropFirst().joined(separator: " | ")
        return switch fields.first {
        case "easyconnect":  .easyConnect(detail: detail)
        case "unreachable":  .unreachable(detail: detail)
        default:             .somethingElse(detail: detail)
        }
    }

    @discardableResult
    public func login(gateway: String, credentials: Credentials) throws -> String {
        applyUnderlay()
        let address = withCStrings([gateway, credentials.username,
                                    credentials.password, credentials.totpSecret ?? ""]) { argv in
            ec_login(argv[0], argv[1], argv[2], argv[3]).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? ""
        }
        guard !address.isEmpty else { throw Failure.login(lastError()) }
        assignedAddress = address
        return address
    }

    public func logout() {
        ec_logout()
        assignedAddress = nil
    }

    /// Why the tunnel stopped carrying traffic, or nil while it still is.
    ///
    /// Upstream ends the process at these points -- a panic on a read or write
    /// failure, `os.Exit` on a server-initiated shutdown -- which inside an app
    /// means the whole thing vanishes when the network changes. The vendored
    /// fork reports here instead; see Vendor/easierconnect, every change marked
    /// TERMTHER PATCH.
    public func tunnelFailure() -> String? {
        guard let raw = ec_tunnel_failure() else { return nil }
        defer { free(raw) }
        let message = String(cString: raw)
        return message.isEmpty ? nil : message
    }

    /// What the gateway will route for this session: allowed ranges, ports and
    /// DNS servers. Worth surfacing, because traffic outside the list is
    /// silently dropped rather than refused, which looks like a hang.
    public func resources() throws -> String {
        guard assignedAddress != nil else { throw Failure.notConnected }
        guard let raw = ec_resources() else { throw Failure.notConnected }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// What the gateway routes, in a form something can lay out.
    ///
    /// The same list as `resources()`, which stays because it is what the
    /// command-line probe prints. This one exists so a panel does not have to
    /// parse formatted columns back apart.
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
        guard assignedAddress != nil else { throw Failure.notConnected }
        guard let raw = ec_resources_json() else { throw Failure.notConnected }
        defer { free(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8), !text.isEmpty else {
            throw Failure.notConnected
        }
        return try JSONDecoder().decode(Routing.self, from: data)
    }

    /// Resolves a name using the DNS servers the gateway advertised, over the
    /// tunnel -- the only way to reach split-horizon names.
    public func resolve(_ host: String) throws -> String {
        guard assignedAddress != nil else { throw Failure.notConnected }
        let address = withCStrings([host]) { argv in
            ec_resolve(argv[0]).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? ""
        }
        guard !address.isEmpty else { throw Failure.resolve(lastError()) }
        return address
    }

    /// Opens a TCP connection inside the tunnel and returns a real descriptor.
    ///
    /// EasyConnect is an L3 tunnel, so the connection is made by a userspace
    /// TCP/IP stack and arrives as a Go `net.Conn`, which is not a descriptor.
    /// A socketpair bridges the two -- the same adapter a jump host uses.
    public func dial(host: String, port: UInt16) throws -> Int32 {
        guard assignedAddress != nil else { throw Failure.notConnected }
        let fd = withCStrings([host]) { argv in ec_dial_tcp(argv[0], Int32(port)) }
        guard fd >= 0 else { throw Failure.dial(lastError()) }
        return fd
    }

    private func lastError() -> String {
        guard let raw = ec_last_error() else { return "unknown" }
        defer { free(raw) }
        let message = String(cString: raw)
        return message.isEmpty ? "unknown" : message
    }

    /// Hands the underlay to the engine before every call that dials.
    ///
    /// Through the C ABI, not the environment. A Go runtime linked as a
    /// c-archive copies the environment once, when the process starts, so a
    /// `setenv` from Swift afterwards is invisible to `os.Getenv` -- the
    /// values silently stayed empty, the dialer bound to a physical interface
    /// with the proxy's resolver, and every connection timed out with a
    /// message blaming the gateway. Nothing about that is visible from here,
    /// which is what made it expensive.
    ///
    /// Anything the profile left blank is worked out first; see
    /// `Underlay.resolved()` for why a half-filled underlay is the worst of
    /// the three states.
    private func applyUnderlay() {
        let underlay = self.underlay.resolved()
        withCStrings([underlay.interfaceName ?? "", underlay.dnsServer ?? ""]) { argv in
            ec_set_underlay(argv[0], argv[1])
        }
    }

    /// Re-reads the machine's interface and resolver and hands them over.
    ///
    /// Worth doing periodically rather than once: the engine re-logs-in by
    /// itself after a drop, building a new dialer from whatever it was last
    /// told. Values discovered on one network are wrong on the next, and a
    /// resolver that no longer answers turns every lookup into a timeout.
    public func refreshUnderlay() { applyUnderlay() }

    /// What the engine will actually use, for a panel to show.
    public nonisolated func effectiveUnderlay() -> Underlay { underlay.resolved() }
}
