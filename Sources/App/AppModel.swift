import AppKit
import Core
import Foundation
import Net
import Observation
import SSH
import VT

/// Everything the window needs that outlives a single terminal.
///
/// One object owns the store, the vault and the connector, because they are
/// only useful together: a server row is inert without the vault to open its
/// credential, and the connector is the one place those two meet.
@MainActor
@Observable
public final class AppModel {
    public enum State: Equatable {
        /// Until `openAtLaunch` has decided; nothing is shown for it.
        case opening
        /// Waiting on the Mac's confirmation, or -- for a vault from before
        /// the key was kept in the keychain -- on its password, once.
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

    public private(set) var state: State = .opening
    public private(set) var servers: [Server] = []
    public private(set) var lastError: String?

    let store: Store
    let vault = Vault()
    private var observation: Task<Void, Never>?

    /// The campus tunnel, and the forwards running over SSH. Both outlive any
    /// one terminal, which is why they live here rather than in a panel.
    @ObservationIgnored private(set) lazy var vpn = VPNController(store: store, vault: vault)
    @ObservationIgnored private(set) lazy var forwards = Forwards(store: store, model: self)
    /// The servers' shared sessions, which the forwards and the monitor ride.
    @ObservationIgnored private(set) lazy var sessions = ServerSessions(model: self)
    /// The servers' load, over whatever sessions are up; the Connections
    /// page, while open, has it open the rest.
    @ObservationIgnored private(set) lazy var monitor = ServerMonitor(model: self)
    /// Terminals on this machine going out through the proxy. Separate from
    /// the tunnels: a local shell needs telling, not tunnelling.
    @ObservationIgnored private(set) lazy var localProxy = LocalProxy()
    /// What new local terminals start with: Settings' variables.
    @ObservationIgnored private(set) lazy var shellEnvironment = ShellEnvironment(store: store)
    /// The coding agents' files, under `agentHome`; their profiles under
    /// the Data folder.
    @ObservationIgnored private(set) lazy var agents = Agents(
        model: self, home: agentHome ?? .homeDirectory, data: agentHome == nil ? nil : paths[.data])
    /// Where the files are: General's Data, Keys and SSH Config.
    let paths: AppPaths

    /// The ssh config the servers are kept in line with: the one General
    /// points at, or the one a test gives. A test or a preview that gives
    /// none has none, so the user's is never touched.
    var sshConfig: URL? { fixedSSHConfig ?? (agentHome == nil ? nil : paths[.sshConfig]) }
    private let fixedSSHConfig: URL?
    /// The home whose `~/.claude` and `~/.codex` are read at unlock. Only
    /// the app's own model has one; a test gives `Agents` a home of its own.
    let agentHome: URL?

    public init(store: Store, sshConfig: URL? = nil, agentHome: URL? = nil) {
        self.store = store
        self.fixedSSHConfig = sshConfig
        self.agentHome = agentHome
        self.paths = AppPaths(store: store)
    }

    public convenience init() {
        // A failure here means the database cannot be opened at all, which is
        // not something the app can carry on from.
        self.init(store: try! Store(), agentHome: .homeDirectory)
    }

    /// Runs keychain work off the main thread. A read can wait on macOS asking
    /// whether to allow access -- after every rebuild of an ad-hoc-signed
    /// build, since the signature changes -- and the window must not freeze
    /// while that question is open.
    nonisolated static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached { try work() }.value
    }

    /// Opens the vault the way this Mac is set up to, at launch.
    ///
    /// The key lives in the keychain, so normally the vault simply opens. Only
    /// the app calls this -- never a test or a preview -- because it creates a
    /// vault and writes its key when there is none, and a scratch vault must
    /// never replace the key of the real one.
    public func openAtLaunch() async {
        lastError = nil
        do {
            requiresMacUnlock = (try? await store.setting("unlockWithMac")) == "on"
            guard let metadata = try await store.vaultMetadata() else {
                // First run: a vault whose key nobody ever types. The password
                // it is made with is thrown away; the keychain holds the key.
                let unused = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                let metadata = try await vault.create(password: unused.base64EncodedString())
                // The key into the keychain before the vault into the store:
                // the other way round, a keychain that refuses leaves a vault
                // saved whose only key is gone, and it can never be opened.
                // This way the next launch simply starts again.
                let key = try await vault.exportDataKey()
                try await Self.offMain { try QuickUnlock.store(dataKey: key) }
                try await store.save(metadata)
                await didUnlock()
                return
            }
            // Made with a password, before the key was kept here: that
            // password opens it once, and the gate asks for it.
            guard QuickUnlock.isEnrolled() else {
                state = .locked
                return
            }
            if requiresMacUnlock {
                state = .locked
                await unlockWithMac()
                return
            }
            let key = try await Self.offMain { try QuickUnlock.read() }
            try await vault.unlock(dataKey: key, metadata: metadata)
            await didUnlock()
        } catch {
            lastError = String(describing: error)
            state = .locked
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
                throw Vault.Failure.notInitialized
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

    /// Whether opening asks the Mac to confirm the owner first. Off unless
    /// turned on in Settings.
    public private(set) var requiresMacUnlock = false

    /// Turns the Mac's confirmation on or off. Turning it on asks once, there
    /// and then, so a switch that cannot be satisfied never gets set.
    public func setRequiresMacUnlock(_ on: Bool) async -> Bool {
        lastError = nil
        do {
            if on {
                if !QuickUnlock.isEnrolled() {
                    let key = try await vault.exportDataKey()
                    try await Self.offMain { try QuickUnlock.store(dataKey: key) }
                }
                _ = try await QuickUnlock.retrieve(reason: "require this to open Termther")
            }
            try await store.setSetting("unlockWithMac", to: on ? "on" : "off")
            requiresMacUnlock = on
            return true
        } catch QuickUnlock.Failure.cancelled {
            return false
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// After a vault from before is opened with its password: keeps its key
    /// in the keychain, so that password is never asked for again. Called by
    /// the gate, not by `unlock(password:)`, which tests use freely.
    public func rememberKey() async {
        do {
            let key = try await vault.exportDataKey()
            try await Self.offMain { try QuickUnlock.store(dataKey: key) }
        } catch {
            lastError = String(describing: error)
        }
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
                throw Vault.Failure.notInitialized
            }
            try await vault.unlock(password: password, metadata: metadata)
            await didUnlock()
        } catch Vault.Failure.wrongPassword {
            // Said plainly: a wrong password is the expected outcome, not a
            // malfunction, and dressing it up as one is unhelpful.
            lastError = "Wrong password"
        } catch {
            lastError = String(describing: error)
        }
    }

    public func lock() {
        observation?.cancel()
        observation = nil
        servers = []
        vpn.forget()
        monitor.stop()
        Task {
            // Tunnels first: a forward outliving the vault would keep serving
            // traffic on credentials the user has just put away.
            await forwards.stopAll()
            await vpn.disconnect()
            await vault.lock()
        }
        state = .locked
    }

    /// Moves the proxy on this Mac: the servers' tunnels and the local
    /// terminals' switches both follow, so neither points at a port nothing
    /// listens on.
    func setProxyPort(_ port: Int) async {
        await forwards.setProxyLocalPort(port)
        localProxy.port = forwards.proxyLocalPort
    }

    /// Moves this Mac's SOCKS5 port the same way; 0 turns that half off.
    func setProxySocksPort(_ port: Int) async {
        await forwards.setProxySocksLocalPort(port)
        localProxy.socksPort = forwards.proxySocksLocalPort
    }

    private func didUnlock() async {
        state = .unlocked
        // Before anything reads a file by its path.
        await paths.restore()
        startObservingServers()
        await syncConfig()
        await vpn.refresh()
        await forwards.loadProxySettings()
        localProxy.port = forwards.proxyLocalPort
        localProxy.socksPort = forwards.proxySocksLocalPort
        await shellEnvironment.restore()
        // A campus server's tunnels cannot come up before the VPN does, and
        // the VPN is not up when the vault opens.
        vpn.onConnected = { [weak self] in
            Task { await self?.forwards.resumeWaitingOnTunnel() }
        }
        vpn.onDropped = { [weak self] in
            Task { await self?.forwards.suspendThoseNeedingTunnel() }
        }
        await forwards.startAutomatic()
        monitor.start()
        // Providers and the launcher only; the sessions wait for their page.
        if agentHome != nil {
            for tool in AgentTool.allCases { await agents.refresh(tool) }
        }
    }

    /// Moves one of General's locations. The agents' profiles follow the
    /// Data folder and the servers follow the config; nothing on disk moves.
    func setPath(_ location: AppPaths.Location, to url: URL) async {
        do { try await paths.set(location, to: url) } catch { report(error); return }
        switch location {
        case .data:
            agents.data = url
            if agentHome != nil {
                for tool in AgentTool.allCases { await agents.refresh(tool) }
            }
        case .sshConfig:
            await syncConfig()
        case .keys:
            break
        }
    }

    /// For the controllers, whose errors are shown where the model's are.
    func report(_ error: any Error) { lastError = String(describing: error) }
    func dismissError() { lastError = nil }

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
        await serialized { await self.performSave(server) }
    }

    private func performSave(_ server: Server) async -> Server? {
        var server = server
        var previous: Server?
        if let id = server.id {
            previous = try? await store.server(id: id)
        } else {
            // A new server goes to the end of a list that may have been reordered.
            server.sortOrder = (try? await store.nextSortOrder()) ?? 0
        }
        // Whether the Host under its old name was this server's: of two
        // servers sharing a name, only the first is written to the file.
        let oldAlias = previous?.configAlias
        let before = (try? await store.servers()) ?? []
        let ownedOld = oldAlias != nil
            && before.first { $0.configAlias == oldAlias }?.id == server.id
        do {
            let saved = try await store.save(server)
            guard let all = try? await store.servers() else { return saved }
            let renamed = oldAlias != nil && oldAlias != saved.configAlias
            let ownsNew = all.first { $0.configAlias == saved.configAlias }?.id == saved.id
            // The server the old name now belongs to, if another has it too.
            let heir = renamed ? all.first { $0.configAlias == oldAlias } : nil
            // Hosts that jump through a renamed server follow it to its new name.
            let followers = renamed ? all.filter { $0.jumpHostID == saved.id } : []
            editConfig { document in
                if renamed, ownedOld, ownsNew, heir == nil {
                    try self.write(saved, previousAlias: oldAlias, all: all, into: &document)
                } else {
                    if renamed, ownedOld, let oldAlias {
                        // The old Host is left behind: handed to the server
                        // that shares the name, or removed when it holds
                        // nothing of the user's own.
                        if let heir {
                            try self.write(heir, previousAlias: nil, all: all, into: &document)
                        } else if document.holdsOnlyServerFields(alias: oldAlias) {
                            try document.remove(alias: oldAlias)
                        }
                    }
                    try self.write(saved, previousAlias: nil, all: all, into: &document)
                }
                for follower in followers {
                    try self.write(follower, previousAlias: nil, all: all, into: &document)
                }
            }
            return saved
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    public func delete(_ server: Server) async {
        await serialized { await self.performDelete(server) }
    }

    private func performDelete(_ server: Server) async {
        guard let id = server.id else { return }
        // Its forwards go with it in SQL, but the running ones hold ports and
        // a session until they are stopped.
        await forwards.stopAll(forServer: id)
        do { try await store.delete(serverID: id) }
        catch {
            // Still a server, so still a host: the file is left as it is.
            lastError = String(describing: error)
            return
        }
        let alias = server.configAlias
        // Kept while another server still goes by the name.
        guard let rest = try? await store.servers(), !rest.contains(where: { $0.configAlias == alias })
        else { return }
        // A Host with lines of the user's own -- an IdentityFile, a rule,
        // other names -- stays: removing a server must not take those with it.
        editConfig { document in
            if document.holdsOnlyServerFields(alias: alias) { try document.remove(alias: alias) }
        }
    }

    // MARK: - ~/.ssh/config

    // Adding, editing or removing a server does the same to its `Host` in
    // ~/.ssh/config. Only what
    // the file can hold goes across -- address, user, port, jump host;
    // credentials, the tunnel and tags stay here. The file's other hosts are
    // not servers until imported: becoming one copies their keys into the
    // vault, which is not something to do to a file just by opening the app.

    /// Runs one change to the servers or the file after those before it.
    /// Each reads both and then writes, awaiting in between; two at once would
    /// import the same new host twice, or sync against a list just changed.
    @ObservationIgnored private var configQueue: Task<Void, Never>?

    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = configQueue
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        configQueue = Task { _ = await task.value }
        return await task.value
    }

    /// Brings the two into line for the servers, file first: a server whose
    /// name is a Host takes the file's address, user, port and jump host, and
    /// one the file lacks is written into it. A Host that is not a server is
    /// left alone -- and its key with it -- until it is chosen in Import from
    /// File. Removing a host in the settings does delete its server.
    public func syncConfig() async {
        await serialized { await self.performSync() }
    }

    private func performSync() async {
        guard let sshConfig else { return }
        let hosts: [SSHConfig.Host]
        do { hosts = SSHConfig.parse(try SSHConfigDocument.read(sshConfig)) }
        catch {
            lastError = String(describing: error)
            return
        }
        guard var all = try? await store.servers() else { return }
        func named(_ alias: String) -> Server? { all.first { $0.configAlias == alias } }

        for host in hosts {
            // Only the server that owns the name takes the file's values; a
            // second server of the same name is not written, so is not read.
            guard var server = named(host.alias) else { continue }
            let before = server
            server.host = host.address
            server.port = host.port
            if !host.user.isEmpty { server.username = host.user }
            if let jump = host.proxyJump {
                if let id = named(jump)?.id { server.jumpHostID = id }
            } else {
                server.jumpHostID = nil
            }
            if server != before { _ = try? await store.save(server) }
        }
        let missing = all.filter { server in !hosts.contains { $0.alias == server.configAlias } }
        guard !missing.isEmpty else { return }
        all = (try? await store.servers()) ?? all
        // One write for all of them.
        editConfig { document in
            for server in missing {
                do { try self.write(server, previousAlias: nil, all: all, into: &document) }
                catch { self.lastError = "~/.ssh/config: \(server.name): \(error)" }
            }
        }
    }

    /// Changes what a server's Host holds beyond the server -- its key, its
    /// options -- after the server is saved, once the block is there. A
    /// host the file does not hold as one block is left alone.
    public func editConfigHost(_ alias: String,
                               _ change: @escaping @MainActor (inout SSHConfigDocument.Entry) -> Void) async {
        await serialized {
            self.editConfig { document in
                guard var entry = document.entries.first(where: { $0.alias == alias }) else { return }
                change(&entry)
                try document.save(entry, replacing: alias)
            }
        }
    }

    /// The settings renamed a host; its server follows.
    public func configHostRenamed(from old: String, to new: String) async {
        await serialized {
            guard var server = try? await self.store.servers().first(where: { $0.configAlias == old })
            else { return }
            server.name = new
            _ = try? await self.store.save(server)
        }
    }

    /// The settings removed a host; its server goes too. The Host is already
    /// gone, so nothing more is written to the file.
    public func configHostRemoved(_ alias: String) async {
        await serialized {
            guard let server = try? await self.store.servers().first(where: { $0.configAlias == alias })
            else { return }
            await self.performDelete(server)
        }
    }

    /// Puts one server into `document`, unless another server owns its name.
    private func write(_ server: Server, previousAlias: String?, all: [Server],
                       into document: inout SSHConfigDocument) throws {
        // Two servers of one name would take turns overwriting one Host; the first keeps it.
        guard all.first(where: { $0.configAlias == server.configAlias })?.id == server.id else { return }
        let jump = server.jumpHostID.flatMap { id in all.first { $0.id == id } }
        try document.write(server, previousAlias: previousAlias,
                           jumpAlias: jump?.configAlias, serverAliases: Set(all.map(\.configAlias)))
    }

    /// One edit to ~/.ssh/config, written only if it changed something.
    /// Nothing is awaited between reading and writing, so edits cannot interleave.
    private func editConfig(_ change: (inout SSHConfigDocument) throws -> Void) {
        guard let url = sshConfig else { return }
        do {
            let original = try SSHConfigDocument.read(url)
            var document = SSHConfigDocument(text: original)
            try change(&document)
            if document.text != original { try document.save(to: url, original: original) }
        } catch {
            lastError = "~/.ssh/config: \(error)"
        }
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

    /// A connected, logged-in session of its own, by the same route a
    /// terminal takes -- VPN, jump host and all. For port forwards, which
    /// must not share a channel with anything else.
    func connectedSession(to server: Server) async throws -> SSHSession {
        let route = try await route(to: server)
        let session = SSHSession()
        try await session.connect(to: server.host, port: try Connector.port(server.port),
                                  over: route.transport)
        try await session.authenticate(route.login)
        return session
    }

    /// True when a server asks for the tunnel and there is not one up.
    func needsTunnel(_ server: Server) -> Bool { vpn.needsTunnel(server) }

    /// What it takes to open a shell on this server.
    func session(for server: Server) async throws -> RemoteShell {
        let route = try await route(to: server)
        return RemoteShell(
            .init(host: server.host, port: try Connector.port(server.port), login: route.login,
                  shellCommand: remoteShellCommand(for: server)),
            over: route.transport)
    }

    /// What a new SSH terminal runs: the exports, then the account's own
    /// login shell. The server's own variables first, then the proxy
    /// tunnel's, so its proxy switch wins over a name in the list.
    ///
    /// The tunnel's only when it is actually up. Exporting `http_proxy` at a
    /// port nothing is listening on is worse than not exporting it: every
    /// command fails with a connection refused instead of quietly going direct.
    func remoteShellCommand(for server: Server) -> String? {
        var exports = server.environment.filter(\.isValid).map { ($0.name, $0.value) }
        if let id = server.id,
           let preset = forwards.proxyBack(for: id),
           let presetID = preset.id, forwards.isRunning(presetID) {
            // The SOCKS5 half joins in only while it too is up.
            let socks = forwards.proxySocks(for: id)
                .flatMap { socks in socks.id.map { forwards.isRunning($0) } == true ? socks : nil }
            exports += ProxyEnvironment.variables(port: preset.bindPort,
                                                  socksPort: socks?.bindPort)
        }
        return exports.isEmpty ? nil : ProxyEnvironment.loginCommand(exporting: exports)
    }

    /// Puts one SSH terminal's shell through the server's proxy tunnel, or
    /// takes it off. The tunnel itself is the server row's switch; this one
    /// is the shell's, since a running shell keeps the environment it
    /// started with. Turning a shell on brings the tunnel up if it is down,
    /// as there is nothing to point it at otherwise; turning one off leaves
    /// the tunnel, and the other shells, alone.
    ///
    /// Refused with a beep while a program has the terminal, since the line
    /// would land in it.
    func toggleProxy(for session: TerminalSession, serverID: Int64) async {
        guard !session.isSwitchingProxy else { return }
        session.isSwitchingProxy = true
        defer { session.isSwitchingProxy = false }
        guard await session.isAtPrompt() else { NSSound.beep(); return }
        if session.usesProxy {
            if await session.typeAtPrompt(ProxyEnvironment.unsetCommand) { session.usesProxy = false }
            return
        }
        if !(forwards.proxyBack(for: serverID).map { forwards.status(of: $0).isLive } ?? false) {
            await forwards.toggleProxyBack(for: serverID)
        }
        // Checked as it is typed: starting the tunnel takes a moment.
        guard let http = forwards.proxyBack(for: serverID), let id = http.id,
              forwards.isRunning(id) else { NSSound.beep(); return }
        let socks = forwards.proxySocks(for: serverID)
            .flatMap { socks in socks.id.map { forwards.isRunning($0) } == true ? socks : nil }
        let command = ProxyEnvironment.exportCommand(port: http.bindPort, socksPort: socks?.bindPort)
        if await session.typeAtPrompt(command) { session.usesProxy = true }
    }

    /// Imports config entries, bringing their keys in with them.
    ///
    /// A server without a credential cannot connect at all, so the key each
    /// entry would have used is read and sealed here -- one credential per key
    /// file, shared by every server that uses it, which is how a single
    /// `id_ed25519` ends up serving a dozen hosts.
    public func importHosts(_ hosts: [SSHConfig.Host]) async {
        await serialized {
            await self.importIntoStore(hosts)
            // From another file, they are new to ~/.ssh/config too.
            await self.performSync()
        }
    }

    private func importIntoStore(_ hosts: [SSHConfig.Host]) async {
        // Chosen twice, or already a server under that name: once is enough.
        let existing = Set(((try? await store.servers()) ?? []).map(\.configAlias))
        let hosts = hosts.filter { !existing.contains($0.alias) }
        guard !hosts.isEmpty else { return }
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

        let inUse = Set(servers.compactMap(\.credentialID))
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
            try? await store.setSetting("fontSize", to: String(Int(theme.terminalFontSize)))
            try? await store.setSetting("lineHeight", to: String(format: "%.2f", theme.terminalLineHeight))
            try? await store.setSetting("letterSpacing", to: String(format: "%.2f", theme.terminalLetterSpacing))
        }
    }

    /// Restores what was chosen last time. Anything missing or no longer
    /// installed falls back rather than failing.
    func restoreAppearance() async {
        guard let theme else { return }
        if let name = try? await store.setting("palette"), let palette = Palette.named(name) {
            theme.palette = palette
        }
        if let size = try? await store.setting("fontSize").flatMap(Double.init) {
            theme.terminalFontSize = size
        }
        if let height = try? await store.setting("lineHeight").flatMap(Double.init) {
            theme.terminalLineHeight = height
        }
        if let spacing = try? await store.setting("letterSpacing").flatMap(Double.init) {
            theme.terminalLetterSpacing = spacing
        }
        onAppearanceChanged?()
    }


    public var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public var libssh2Version: String { SSHLinkCheck.libssh2Version }
}
