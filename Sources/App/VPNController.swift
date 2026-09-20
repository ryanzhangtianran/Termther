import Core
import Darwin
import EC
import Foundation
import Net
import Observation

/// The campus tunnel, as the window sees it.
///
/// One tunnel at a time, whatever is saved: the engine is a Go archive with
/// process-global state, so a second login would replace the first without
/// saying so. Making that a rule here means the panel can show one clear
/// answer -- connected, or not -- instead of a list of maybes.
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
    private(set) var activeProfileID: Int64?
    /// What the gateway will route. Worth showing, because traffic outside it
    /// is dropped rather than refused, which looks like a hang.
    private(set) var routing: EasyConnect.Routing?
    /// When the tunnel came up, for the diagnostics line.
    private(set) var connectedAt: Date?
    /// The interface and resolver the engine is actually using. This being
    /// invisible is what let a broken underlay hide behind a timeout.
    private(set) var underlayDescription: String?
    /// The gateway. Singular on purpose: the engine holds process-global
    /// state and can only carry one tunnel, so a list would be a list of
    /// things that cannot coexist.
    private(set) var profile: VPNProfile?
    /// The result of the last gateway check, for the editor to show.
    private(set) var lastProbe: String?

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

    func delete(_ profile: VPNProfile) async {
        guard let id = profile.id else { return }
        if activeProfileID == id { await disconnect() }
        try? await store.delete(vpnProfileID: id)
        await refresh()
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
        guard let id = profile.id else { return }
        if state.isOn { await disconnect() }

        state = .connecting
        activeProfileID = id

        guard let password = try? await vault.openText(profile.sealed,
                                                       context: VPNProfile.passwordContext) else {
            state = .failed("cannot open the saved password")
            activeProfileID = nil
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
            state = .on(address: address)
            connectedAt = Date()
            routing = try? await engine.routing()
            let underlay = engine.effectiveUnderlay()
            underlayDescription = [underlay.interfaceName, underlay.dnsServer]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            startWatchdog(engine)
            onConnected?()
        } catch {
            self.engine = nil
            activeProfileID = nil
            state = .failed(String(describing: error))
        }
    }

    /// Notices the tunnel stopping on its own.
    ///
    /// There is nothing to wait on: the failure happens on a Go goroutine that
    /// used to end the process, and now records a string instead. Polling it is
    /// enough -- the point is that the panel stops claiming to be connected,
    /// not that it notices within a millisecond.
    private func startWatchdog(_ engine: EasyConnect) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                // The engine re-logs-in by itself when the tunnel drops, and
                // it builds a fresh dialer when it does. Handing it current
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
        activeProfileID = nil
        routing = nil
        connectedAt = nil
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
        // change: the Go side can be blocked in a socket that is no longer
        // going anywhere.
        let engine = self.engine
        self.engine = nil
        activeProfileID = nil
        routing = nil
        connectedAt = nil
        underlayDescription = nil
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
        lastProbe = "checking\u{2026}"
        let engine = self.engine ?? EasyConnect()
        let result = await engine.probe(gateway: gateway)
        lastProbe = switch result {
        case .easyConnect(let detail):   "EasyConnect gateway. \(detail)"
        case .somethingElse(let detail): "Answers, but not EasyConnect: \(detail)"
        case .unreachable(let detail):   "Unreachable: \(detail)\(placeholderNote(gateway))"
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
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let sockaddr = first.pointee.ai_addr else { return nil }
        let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        var mutable = address
        guard inet_ntop(AF_INET, &mutable, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
        else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
