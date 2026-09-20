import Core
import Foundation
import Net
import Observation
import SSH
import VT
import SwiftUI

/// Everything the window needs that outlives a single terminal.
///
/// One object owns the store, the vault and the connector, because they are
/// only useful together: a server row is inert without the vault to open its
/// credential, and the connector is the one place those two meet.
@MainActor
@Observable
public final class AppModel {
    public enum State: Equatable {
        /// No vault yet; the user is asked to make one.
        case needsSetup
        case locked
        case unlocked
    }

    public enum Failure: Error, CustomStringConvertible {
        case tunnelDown(server: String)

        public var description: String {
            switch self {
            case .tunnelDown(let name):
                "\(name) is behind the VPN, which is not connected"
            }
        }
    }

    public private(set) var state: State = .locked
    public private(set) var servers: [Server] = []
    public private(set) var lastError: String?

    let store: Store
    let vault = Vault()
    private var observation: Task<Void, Never>?

    /// The campus tunnel, and the forwards running over SSH. Both outlive any
    /// one terminal, which is why they live here rather than in a panel.
    @ObservationIgnored private(set) lazy var vpn = VPNController(store: store, vault: vault)
    @ObservationIgnored private(set) lazy var forwards = Forwards(store: store, model: self)
    /// Terminals on this machine going out through the proxy. Separate from
    /// the tunnels: a local shell needs telling, not tunnelling.
    @ObservationIgnored private(set) lazy var localProxy = LocalProxy(store: store)

    public init(store: Store) {
        self.store = store
        Task { await determineInitialState() }
    }

    public convenience init() {
        // A failure here means the database cannot be opened at all, which is
        // not something the app can carry on from.
        self.init(store: try! Store())
    }

    private func determineInitialState() async {
        do {
            state = try await store.hasVault ? .locked : .needsSetup
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - unlocking with the Mac

    /// Everything this Mac would accept, as a sentence, or nil when it would
    /// accept nothing.
    public var quickUnlockMethods: String? { QuickUnlock.methodsDescription() }
    /// Whether a key has been stored. Asked without prompting for anything.
    public var isQuickUnlockEnrolled: Bool { QuickUnlock.isEnrolled() }

    /// Opens the vault with Touch ID, an Apple Watch or the login password.
    public func unlockWithMac() async {
        lastError = nil
        do {
            guard let metadata = try await store.vaultMetadata() else {
                state = .needsSetup
                return
            }
            let key = try await QuickUnlock.retrieve(reason: "unlock your Termther vault")
            try await vault.unlock(dataKey: key, metadata: metadata)
            await didUnlock()
        } catch QuickUnlock.Failure.cancelled {
            // Not an error worth shouting about: the password field is right
            // there, and saying nothing is what every other app does here.
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Stores the data key so the Mac can open the vault later.
    ///
    /// Only possible while it is open: the key being stored is the one the
    /// password derived, so this is a shortcut created from the long way in.
    public func enableQuickUnlock() async -> Bool {
        do {
            try QuickUnlock.enrol(dataKey: try await vault.exportDataKey())
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    public func disableQuickUnlock() {
        QuickUnlock.forget()
    }

    // MARK: - vault

    public func createVault(password: String) async {
        do {
            let metadata = try await vault.create(password: password)
            try await store.save(metadata)
            await didUnlock()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func unlock(password: String) async {
        lastError = nil
        do {
            guard let metadata = try await store.vaultMetadata() else {
                state = .needsSetup
                return
            }
            try await vault.unlock(password: password, metadata: metadata)
            await didUnlock()
        } catch Vault.Failure.wrongPassword {
            // Said plainly: a wrong password is the expected outcome, not a
            // malfunction, and dressing it up as one is unhelpful.
            lastError = "Wrong password."
        } catch {
            lastError = String(describing: error)
        }
    }

    public func lock() {
        observation?.cancel()
        observation = nil
        servers = []
        vpn.forget()
        Task {
            // Tunnels first: a forward outliving the vault would keep serving
            // traffic on credentials the user has just put away.
            await forwards.stopAll()
            await vpn.disconnect()
            await vault.lock()
        }
        state = .locked
    }

    private func didUnlock() async {
        state = .unlocked
        startObservingServers()
        await vpn.refresh()
        await forwards.loadProxySettings()
        localProxy.port = forwards.proxyLocalPort
        await localProxy.restore()
        // A campus server's tunnels cannot come up before the VPN does, and
        // the VPN is not up when the vault opens.
        vpn.onConnected = { [weak self] in
            Task { await self?.forwards.resumeWaitingOnTunnel() }
        }
        vpn.onDropped = { [weak self] in
            Task { await self?.forwards.suspendThoseNeedingTunnel() }
        }
        await forwards.startAutomatic()
    }

    /// Follows the server list for as long as the vault is open, so an edit
    /// anywhere shows up everywhere without anything having to be told.
    private func startObservingServers() {
        observation?.cancel()
        let stream = store.observeServers()
        observation = Task { [weak self] in
            do {
                for try await servers in stream {
                    await MainActor.run { self?.servers = servers }
                    // A deleted server takes its forwards with it in SQL, so
                    // this is the one change to the list that does not come
                    // through the forwards themselves.
                    await self?.forwards.refresh()
                }
            } catch {
                await MainActor.run { self?.lastError = String(describing: error) }
            }
        }
    }

    // MARK: - servers

    @discardableResult
    public func save(_ server: Server) async -> Server? {
        do { return try await store.save(server) }
        catch {
            lastError = String(describing: error)
            return nil
        }
    }

    public func delete(_ server: Server) async {
        guard let id = server.id else { return }
        do { try await store.delete(serverID: id) }
        catch { lastError = String(describing: error) }
    }

    /// Turns the tunnel on or off for one server.
    ///
    /// Reachable from the VPN panel as well as the server's editor, because
    /// "which machines is this tunnel for" is a question about the tunnel.
    public func setRoutesThroughVPN(_ enabled: Bool, for server: Server) async {
        var server = server
        guard server.routesThroughVPN != enabled else { return }
        server.routesThroughVPN = enabled
        await save(server)
    }

    public func reorder(_ ids: [Int64]) async {
        do { try await store.reorderServers(ids) }
        catch { lastError = String(describing: error) }
    }

    /// Everything needed to reach one server, resolved now rather than stored.
    struct Route {
        var transport: any SSHTransport
        var login: Connector.Login
    }

    /// The route and the credentials, together.
    ///
    /// The connector is built per connection rather than kept, because its
    /// outermost hop is not fixed: the same server is reached directly or
    /// through the tunnel depending on what is up at this moment.
    func route(to server: Server) async throws -> Route {
        guard state == .unlocked else { throw Vault.Failure.locked }
        // Said now rather than after a handshake times out: a host marked as
        // being behind the tunnel is not reachable without one, and a timeout
        // does not say which switch to flip.
        if vpn.needsTunnel(server) { throw Failure.tunnelDown(server: server.name) }
        let connector = Connector(store: store, vault: vault, over: vpn.transport(for: server))
        return Route(transport: try await connector.transport(for: server),
                     login: try await connector.credentials(for: server))
    }

    /// True when a server asks for the tunnel and there is not one up.
    func needsTunnel(_ server: Server) -> Bool { vpn.needsTunnel(server) }

    /// What it takes to open a shell on this server.
    func session(for server: Server) async throws -> RemoteShell {
        let route = try await route(to: server)
        return RemoteShell(
            .init(host: server.host, port: UInt16(server.port), login: route.login,
                  shellCommand: proxyShellCommand(for: server)),
            over: route.transport)
    }

    /// The exports that hand a new terminal the tunnel back to this Mac.
    ///
    /// Only when the tunnel is actually up. Exporting `http_proxy` at a port
    /// nothing is listening on is worse than not exporting it: every command
    /// fails with a connection refused instead of quietly going direct.
    private func proxyShellCommand(for server: Server) -> String? {
        guard let id = server.id,
              let preset = forwards.proxyBack(for: id),
              let presetID = preset.id, forwards.isRunning(presetID)
        else { return nil }
        return ProxyEnvironment.loginCommand(port: preset.bindPort)
    }

    /// Imports config entries, bringing their keys in with them.
    ///
    /// A server without a credential cannot connect at all, so the key each
    /// entry would have used is read and sealed here -- one credential per key
    /// file, shared by every server that uses it, which is how a single
    /// `id_ed25519` ends up serving a dozen hosts.
    public func importHosts(_ hosts: [SSHConfig.Host]) async {
        var byPath: [String: Int64] = [:]
        var byAlias: [String: Int64] = [:]

        for host in hosts {
            guard let path = host.effectiveIdentityFile else { continue }
            if let existing = byPath[path] {
                byAlias[host.alias] = existing
                continue
            }
            guard let key = try? SSHKeys.read(at: URL(fileURLWithPath: path))
            else { continue }

            // Importing the same config twice used to add a second credential
            // for the same key, and a third the time after -- filling the
            // credential picker with identical entries. Matching on the key
            // itself rather than on its name is exact, and needs no extra
            // column to record where it came from.
            if let existing = await existingCredential(holding: key) {
                byPath[path] = existing
                byAlias[host.alias] = existing
                continue
            }

            guard let sealed = try? await vault.seal(key, context: "credential.privateKey"),
                  let credential = try? await store.save(Credential(
                    name: (path as NSString).lastPathComponent,
                    kind: .privateKey, sealed: sealed))
            else { continue }
            byPath[path] = credential.id
            byAlias[host.alias] = credential.id
        }

        do { try await store.importHosts(hosts, credentials: byAlias) }
        catch { lastError = String(describing: error) }
    }

    /// The credential already holding this key, if there is one.
    ///
    /// Ciphertext cannot be compared -- each sealing uses a fresh nonce, so the
    /// same key encrypts differently every time -- which is why this opens them.
    func existingCredential(holding key: String) async -> Int64? {
        guard let credentials = try? await store.credentials() else { return nil }
        for credential in credentials where credential.kind == .privateKey {
            guard let plaintext = try? await vault.openText(credential.sealed,
                                                            context: credential.context)
            else { continue }
            if plaintext == key { return credential.id }
        }
        return nil
    }

    /// Removes credentials no server points at.
    ///
    /// They accumulate from edits and repeated imports, and an unused key in
    /// the picker is worse than absent: it looks like a choice.
    @discardableResult
    public func pruneUnusedCredentials() async -> Int {
        guard let credentials = try? await store.credentials(),
              let servers = try? await store.servers()
        else { return 0 }

        let inUse = Set(servers.compactMap(\.credentialId))
        var removed = 0
        for credential in credentials {
            guard let id = credential.id, !inUse.contains(id) else { continue }
            try? await store.delete(credentialID: id)
            removed += 1
        }
        return removed
    }

    public func credentialCount() async -> Int {
        (try? await store.credentials().count) ?? 0
    }

    public func clearError() { lastError = nil }

    // MARK: - appearance

    /// The theme, so settings can change it and every open terminal follows.
    var theme: Theme?
    /// Called after a change, so live terminals are re-themed rather than only
    /// new ones.
    var onAppearanceChanged: (() -> Void)?

    func apply(_ palette: Palette) {
        theme?.palette = palette
        onAppearanceChanged?()
        Task { try? await store.setSetting("palette", to: palette.name) }
    }

    func saveTerminalLayoutSettings() {
        guard let theme else { return }
        onAppearanceChanged?()
        Task {
            try? await store.setSetting("lineHeight", to: String(format: "%.2f", theme.terminalLineHeight))
            try? await store.setSetting("letterSpacing", to: String(format: "%.2f", theme.terminalLetterSpacing))
            try? await store.setSetting("cursorStyle", to: theme.cursorStyle.rawValue)
        }
    }

    /// Restores what was chosen last time. Anything missing or no longer
    /// installed falls back rather than failing.
    func restoreAppearance() async {
        guard let theme else { return }
        if let name = try? await store.setting("palette"), let palette = Palette.named(name) {
            theme.palette = palette
        }
        if let height = try? await store.setting("lineHeight").flatMap(Double.init) {
            theme.terminalLineHeight = height
        }
        if let spacing = try? await store.setting("letterSpacing").flatMap(Double.init) {
            theme.terminalLetterSpacing = spacing
        }
        if let name = try? await store.setting("cursorStyle"),
           let style = CursorStyle(rawValue: name) {
            theme.cursorStyle = style
        }
        onAppearanceChanged?()
    }


    public var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public var libssh2Version: String { SSHLinkCheck.libssh2Version }
}
