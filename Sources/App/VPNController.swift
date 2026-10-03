import Core
import Darwin
import VPN
import Foundation
import Net
import Observation

/// The campus tunnel, as the window sees it.
///
/// One tunnel at a time, however many gateways are saved. With that rule the
/// panel can show one clear answer, connected or not, instead of a list of
/// maybes.
@MainActor
@Observable
final class VPNController {
    enum State: Equatable {
        case off
        case connecting
        /// Connected, holding the address the gateway assigned. That address
        /// only exists inside a real tunnel, which makes it the honest proof
        /// there is one.
        case on(address: String)
        case failed(String)

        var isOn: Bool { if case .on = self { true } else { false } }
    }

    private(set) var state: State = .off
    /// What the gateway will route. Worth showing, because traffic outside it
    /// is dropped rather than refused, which looks like a hang.
    private(set) var routing: EasyConnect.Routing?
    /// The gateway. Singular on purpose: the engine holds process-global
    /// state and can only carry one tunnel, so a list would be a list of
    /// things that cannot coexist.
    private(set) var profile: VPNProfile?
    /// The result of the last gateway check, for the editor to show.
    /// The last Test Gateway: whether it is an EasyConnect gateway (nil while
    /// asking), and the gateway's own words for when it is not.
    struct Probe {
        var succeeded: Bool?
        var detail: String
    }
    private(set) var lastProbe: Probe?

    /// Called when a tunnel comes up, so whatever was waiting on it can go.
    var onConnected: (() -> Void)?
    /// Called when it goes away, so nothing is left waiting on a dead socket.
    var onDropped: (() -> Void)?

    private let store: Store
    private let vault: Vault
    private var engine: EasyConnect?
    /// Watches for the tunnel dying on its own.
    private var watchdog: Task<Void, Never>?

    init(store: Store, vault: Vault) {
        self.store = store
        self.vault = vault
    }

    /// The route out for a server, which is the tunnel only for the servers
    /// that asked for it.
    ///
    /// A gateway routes the ranges it advertises and silently drops the rest,
    /// so sending every connection through a live tunnel would turn every host
    /// outside the campus into a timeout.
    func transport(for server: Server) -> any SSHTransport {
        guard server.routesThroughVPN, state.isOn, let engine else { return DirectTransport() }
        return EasyConnectTransport(vpn: engine)
    }

    /// True when a server wants the tunnel and there is not one.
    func needsTunnel(_ server: Server) -> Bool { server.routesThroughVPN && !state.isOn }

    // MARK: - profiles

    /// Re-reads the gateway. Explicit rather than observed, for the reason
    /// spelled out in `Forwards.refresh()`: an observation racing with the
    /// edit that caused it puts the old value back for a moment.
    func refresh() async {
        profile = (try? await store.vpnProfiles())?.first
    }

    func forget() {
        profile = nil
    }

    /// Saves the gateway, replacing whatever was there.
    ///
    /// One row, always: saving a second gateway is editing the first, because
    /// there is only ever one tunnel to have.
    @discardableResult
    func save(_ profile: VPNProfile) async -> VPNProfile? {
        var profile = profile
        profile.id = profile.id ?? self.profile?.id
        let saved = try? await store.save(profile)
        await refresh()
        return saved
    }

    /// Seals a profile's secrets. Kept here so the editor never holds a vault.
    func seal(password: String, totp: String?) async -> (Vault.Sealed, Vault.Sealed?)? {
        guard let sealed = try? await vault.seal(password, context: VPNProfile.passwordContext)
        else { return nil }
        guard let totp, !totp.isEmpty else { return (sealed, nil) }
        let sealedTOTP = try? await vault.seal(totp, context: VPNProfile.totpContext)
        return (sealed, sealedTOTP)
    }

    // MARK: - the tunnel

    func connect(_ profile: VPNProfile) async {
        guard profile.id != nil else { return }
        if state.isOn { await disconnect() }

        state = .connecting

        guard let password = try? await vault.openText(profile.sealed,
                                                       context: VPNProfile.passwordContext) else {
            state = .failed("cannot open the saved password")
            return
        }
        var totp: String?
        if let sealed = profile.totpSealed {
            totp = try? await vault.openText(sealed, context: VPNProfile.totpContext)
        }

        let engine = EasyConnect(underlay: .init(interfaceName: profile.interfaceName,
                                                 dnsServer: profile.dnsServer))
        self.engine = engine

        do {
            let address = try await engine.login(
                gateway: profile.gateway,
                credentials: .init(username: profile.username, password: password,
                                   totpSecret: totp))
            // Disconnected, or connected elsewhere, while this logged in: the
            // session belongs to nobody, and claiming it would show a tunnel
            // that is on with no engine behind it.
            guard self.engine === engine else {
                Task.detached { await engine.logout() }
                return
            }
            state = .on(address: address)
            routing = try? await engine.routing()
            startWatchdog(engine)
            onConnected?()
        } catch {
            guard self.engine === engine else { return }
            self.engine = nil
            state = .failed(String(describing: error))
        }
    }

    /// Notices the tunnel stopping on its own.
    ///
    /// There is nothing to wait on: the failure happens on the tunnel's reader
    /// thread, which records a reason and stops. Polling for it is enough. What
    /// matters is that the panel stops claiming to be connected, not that it
    /// notices within a millisecond.
    private func startWatchdog(_ engine: EasyConnect) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                // The engine reopens a broken tunnel stream by itself, with
                // the same token, dialing through whatever interface and
                // resolver it was last handed. Handing it current
                // values each time is what keeps a network change from
                // leaving it pinned to an interface and a resolver that
                // belong to the network just left -- a campus DNS server is
                // unreachable from a hotspot, and every lookup then waits out
                // a timeout.
                await engine.refreshUnderlay()

                guard let failure = await engine.tunnelFailure() else { continue }
                await MainActor.run { self?.tunnelDied(failure) }
                return
            }
        }
    }

    private func tunnelDied(_ reason: String) {
        watchdog?.cancel()
        watchdog = nil
        state = .failed("the tunnel dropped: \(reason)")
        onDropped?()
        routing = nil
        // The engine is kept only long enough to be logged out cleanly.
        let engine = self.engine
        self.engine = nil
        Task { await engine?.logout() }
    }

    func disconnect() async {
        watchdog?.cancel()
        watchdog = nil
        // Dropped first, so the panel is honest immediately. Waiting on the
        // engine to answer is what left the switch stuck on after a network
        // change: the engine can be blocked in a socket that is no longer
        // going anywhere.
        let engine = self.engine
        self.engine = nil
        routing = nil
        state = .off
        onDropped?()

        // Not awaited, and deliberately so. The panel has already moved on;
        // the logout is a courtesy to the gateway, and it can be blocked
        // inside a synchronous call that no cancellation reaches. Waiting on
        // it is how a disconnected VPN kept the switch stuck on.
        Task.detached { await engine?.logout() }
    }

    /// Asks a gateway what it is, before anyone types a password into it.
    func probe(gateway: String) async {
        lastProbe = Probe(succeeded: nil, detail: "")
        let engine = self.engine ?? EasyConnect()
        let result = await engine.probe(gateway: gateway)
        lastProbe = switch result {
        case .easyConnect(let detail):
            Probe(succeeded: true, detail: "EasyConnect gateway. \(detail)")
        case .somethingElse(let detail):
            Probe(succeeded: false, detail: "Answers, but not EasyConnect: \(detail)")
        case .unreachable(let detail):
            Probe(succeeded: false,
                  detail: "Unreachable: \(detail)\(placeholderNote(gateway))")
        }
    }

    /// Says so when the name only resolves because a local proxy answered.
    ///
    /// A TUN proxy -- Surge, Clash, sing-box -- answers every lookup with an
    /// address from its own placeholder range, including for names that do not
    /// exist at all. So a wrong hostname does not fail at DNS the way it
    /// normally would; it fails later, as a connection that goes nowhere, and
    /// the message says the gateway is unreachable rather than that it is not
    /// a real name. That cost a whole afternoon once.
    private func placeholderNote(_ gateway: String) -> String {
        let host = gateway.split(separator: ":").first.map(String.init) ?? gateway
        guard let address = Self.resolve(host), ProxyPlaceholder.matches(address) else { return "" }
        return " \u{2014} but \(host) resolved to \(address), which is a local "
            + "proxy's placeholder rather than a real address. Either the name "
            + "does not exist, or the proxy is holding it: check the hostname, "
            + "then set the interface and DNS under Underlay."
    }

    nonisolated private static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
