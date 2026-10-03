import AppKit
import Core
import SwiftUI

/// Adds or edits one server.
struct ServerEditor: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var server: Server
    @State private var password = ""
    /// The outbound proxy's password, typed afresh; blank keeps the stored one.
    @State private var proxyPassword = ""
    @State private var credentials: [Credential] = []
    @State private var credentialChoice: CredentialChoice = .password
    @State private var keyKind: SSHKeys.Kind = .ed25519
    @State private var importedKey: String?
    @State private var importedKeyName: String?
    @State private var discovered: [URL] = []
    /// The host's `IdentityFile` as the file has it, for offering that key.
    @State private var identityFile = ""
    @State private var isWorking = false
    @State private var generated: SSHKeys.Pair?
    @State private var installsKey = true
    @State private var installOutcome: KeyInstall.Outcome?
    /// The reverse tunnel that puts this server's outbound traffic through
    /// this Mac. Kept as its own switch because that is how it is thought
    /// about; it is an ordinary forward underneath.
    @State private var proxiesBack = false
    @State private var proxyRemotePort = ProxyEnvironment.defaultRemotePort
    @State private var proxySocksRemotePort = ProxyEnvironment.defaultSocksRemotePort
    /// The server's tunnels, edited here and written on save, so Cancel
    /// discards them the way it discards a changed hostname.
    @State private var tunnels: [PortForwardPreset] = []
    @State private var removedTunnels: [PortForwardPreset] = []
    @State private var editingTunnel: TunnelDraft?

    /// A tunnel on its way through the editor. Identified by its own handle
    /// rather than by a database id, because the new ones do not have one.
    private struct TunnelDraft: Identifiable {
        let id = UUID()
        /// Nil for one being added.
        var index: Int?
        var preset: PortForwardPreset
    }
    @Environment(\.dismiss) private var dismiss

    /// A server either reuses a saved credential or brings a new one. Keeping
    /// that a single choice avoids the usual muddle where both a picker and a
    /// password field are filled in and neither obviously wins.
    private enum CredentialChoice: Hashable {
        case password
        case generateKey
        case importKey
        /// A key file in the keys folder: sealed as a credential, and named
        /// as the host's `IdentityFile` so ssh in a terminal uses it too.
        case key(String)
        case existing(Int64)
    }

    init(model: AppModel, server: Server) {
        self.model = model
        _server = State(initialValue: server)
        _credentialChoice = State(initialValue:
            server.credentialID.map(CredentialChoice.existing) ?? .password)
    }

    private var isNew: Bool { server.id == nil }

    private var canSave: Bool {
        guard !server.host.isEmpty, !server.username.isEmpty, !isWorking,
              Connector.isPort(server.port), Connector.isPort(proxyRemotePort),
              Connector.isPort(proxySocksRemotePort) else { return false }
        if server.proxyKind != nil {
            guard let host = server.proxyHost, !host.isEmpty,
                  Connector.isPort(server.proxyPort ?? 0) else { return false }
        }
        return switch credentialChoice {
        case .password: !password.isEmpty || !isNew
        case .importKey: importedKey != nil
        case .generateKey: !installsKey || !password.isEmpty
        case .key, .existing: true
        }
    }

    var body: some View {
        // Importing from ~/.ssh/config lives on the SSH Config page of Settings.
        form
        .frame(width: 470, height: 540)
        .task {
            credentials = (try? await model.store.credentials()) ?? []
            // The keys folder, and ~/.ssh too when the folder was moved
            // away from it, so keys made by hand are still offered.
            discovered = SSHKeys.discover(in: model.paths[.keys])
            if model.paths[.keys] != SSHKeys.sshDirectory { discovered += SSHKeys.discover() }
            if let url = model.sshConfig, let text = try? SSHConfigDocument.read(url),
               let entry = SSHConfigDocument(text: text).entries.first(where: { $0.alias == server.configAlias }) {
                identityFile = entry.identityFile
                // The key the file names is the one to offer, when it is here.
                let path = (entry.identityFile as NSString).expandingTildeInPath
                if discovered.contains(where: { $0.path == path }) { credentialChoice = .key(path) }
            }
            if let id = server.id {
                if let preset = model.forwards.proxyBack(for: id) {
                    proxiesBack = true
                    proxyRemotePort = preset.bindPort
                }
                if let socks = model.forwards.proxySocks(for: id) {
                    proxySocksRemotePort = socks.bindPort
                }
                tunnels = model.forwards.plainPresets(forServer: id)
            }
        }
        .sheet(item: $generated) { pair in
            GeneratedKeySheet(pair: pair, outcome: installOutcome) { dismiss() }
        }
        .sheet(item: $editingTunnel) { draft in
            ForwardEditor(preset: draft.preset) { edited in
                if let index = draft.index {
                    tunnels[index] = edited
                } else {
                    tunnels.append(edited)
                }
            }
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text(server.host))
                    TextField("Host", text: $server.host)
                    TextField("Port", value: $server.port, format: .number.grouping(.never))
                    TextField("User", text: $server.username)
                }

                Section("Credential") {
                    LabeledContent("Use") {
                        PopUpMenu(sections: [
                            [(isNew ? "Password" : "Replace password", .password),
                             ("Generate key", .generateKey),
                             ("Import key\u{2026}", .importKey)],
                            credentials.map { ($0.name, .existing($0.id ?? -1)) },
                            // What is already in the keys folder, so the
                            // common case does not need a file dialog at all.
                            discovered.map { ($0.lastPathComponent, .key($0.path)) },
                        ], selection: $credentialChoice)
                    }

                    switch credentialChoice {
                    case .password:
                        SecureField("Password", text: $password,
                                    prompt: isNew ? nil : Text("********"))

                    case .generateKey:
                        LabeledContent("Type") {
                            PopUpMenu(SSHKeys.Kind.allCases.map { ($0.title, $0) }, selection: $keyKind)
                        }
                        Toggle("Install on server", isOn: $installsKey)
                        if installsKey {
                            SecureField("Password", text: $password)
                        }

                    case .importKey:
                        HStack(spacing: 8) {
                            Button("Choose File\u{2026}") { chooseKeyFile() }
                                .controlSize(.small)
                            if let name = importedKeyName {
                                Text(name)
                                    .font(theme.ui(12))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                    case .key, .existing:
                        EmptyView()
                    }
                }

                Section("Route") {
                    if model.vpn.profile != nil {
                        Toggle("Through the VPN", isOn: $server.routesThroughVPN)
                    }
                    // Reaching the server by way of a proxy -- not the proxy
                    // back to this Mac, which is the section below.
                    LabeledContent("Via proxy") {
                        PopUpMenu([("None", Server.ProxyKind?.none),
                                   ("SOCKS5", .socks5), ("HTTP CONNECT", .httpConnect)],
                                  selection: $server.proxyKind)
                    }
                    if server.proxyKind != nil {
                        TextField("Proxy host", text: Binding(
                            get: { server.proxyHost ?? "" }, set: { server.proxyHost = $0 }))
                        TextField("Proxy port", value: Binding(
                            get: { server.proxyPort ?? 1080 }, set: { server.proxyPort = $0 }),
                                  format: .number.grouping(.never))
                        TextField("Proxy user", text: Binding(
                            get: { server.proxyUsername ?? "" },
                            set: { server.proxyUsername = $0.isEmpty ? nil : $0 }))
                        SecureField("Proxy password", text: $proxyPassword,
                                    prompt: server.proxySealed == nil ? nil : Text("********"))
                    }
                    LabeledContent("Jump host") {
                        // A server cannot be its own way in.
                        PopUpMenu([("None", Int64?.none)]
                                  + model.servers.filter { $0.id != server.id }.map {
                                      ($0.displayName, Int64?.some($0.id ?? -1))
                                  },
                                  selection: $server.jumpHostID)
                    }
                    TextField("Tags", text: $server.tags)
                }

                Section("Forwards") {
                    ForEach(Array(tunnels.enumerated()), id: \.offset) { index, tunnel in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: tunnel.direction))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tunnel.summary)
                                    .font(theme.ui(13))
                                Text(note(for: tunnel))
                                    .font(theme.ui(11))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            Button("Edit") {
                                editingTunnel = TunnelDraft(index: index, preset: tunnel)
                            }
                            .controlSize(.small)
                            Button {
                                if tunnel.id != nil { removedTunnels.append(tunnel) }
                                tunnels.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                    }

                    Button("Add Forward\u{2026}") {
                        editingTunnel = TunnelDraft(
                            index: nil,
                            preset: PortForwardPreset(serverID: server.id ?? 0,
                                                      direction: .local, bindPort: 8080,
                                                      targetHost: "127.0.0.1", targetPort: 80))
                    }
                    .controlSize(.small)
                }

                EnvironmentTable(title: "Environment", variables: $server.environment)


                // Kept apart from the variables above: these are exported only
                // while the proxy is on -- switched on the server's row -- so a
                // server never points at a tunnel that is not there.
                Section("Proxy") {
                    TextField("HTTP port on server", value: $proxyRemotePort,
                              format: .number.grouping(.never))
                    if model.forwards.proxySocksLocalPort > 0 {
                        TextField("SOCKS5 port on server", value: $proxySocksRemotePort,
                                  format: .number.grouping(.never))
                    }
                }

            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = URL.homeDirectory.appending(path: ".ssh")
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importedKey = try SSHKeys.read(at: url)
            importedKeyName = url.lastPathComponent
        } catch {
            importedKeyName = String(describing: error)
        }
    }

    private func save() {
        var server = self.server
        if server.name.isEmpty { server.name = server.host }
        isWorking = true

        Task {
            // The outbound proxy: its fields go with the kind, and a password
            // typed here is sealed; none typed keeps what was there.
            if server.proxyKind == nil {
                server.proxyHost = nil
                server.proxyPort = nil
                server.proxyUsername = nil
                server.proxySecret = nil
                server.proxySecretNonce = nil
            } else if !proxyPassword.isEmpty,
                      let sealed = try? await model.vault.seal(proxyPassword, context: "proxy.password") {
                server.proxySecret = sealed.ciphertext
                server.proxySecretNonce = sealed.nonce
            }

            switch credentialChoice {
            case .existing(let id):
                server.credentialID = id

            case .password where !password.isEmpty:
                server.credentialID = await store(secret: password, kind: .password,
                                                  name: "\(server.username)@\(server.host)")

            case .password:
                break   // editing without changing the password

            case .importKey:
                if let key = importedKey {
                    server.credentialID = await store(secret: key, kind: .privateKey,
                                                      name: importedKeyName ?? "imported key")
                }

            case .key(let path):
                if let key = try? SSHKeys.read(at: URL(fileURLWithPath: path)) {
                    server.credentialID = await store(secret: key, kind: .privateKey,
                                                      name: (path as NSString).lastPathComponent)
                }

            case .generateKey:
                guard let pair = try? await SSHKeys.generate(
                    kind: keyKind, name: server.name,
                    comment: "\(server.username)@\(server.host) (Termther)",
                    in: model.paths[.keys])
                else { break }

                server.credentialID = await store(secret: pair.privateKey, kind: .privateKey,
                                                  name: "\(server.name) \(pair.kind.title)")
                if let saved = await model.save(server) { server = saved }
                await applyProxySetting(to: server)
                await applyTunnels(to: server)
                await applyOptions(to: server)

                if installsKey, !password.isEmpty {
                    // The password authenticates one connection whose only job
                    // is to append the key, and is never stored.
                    installOutcome = await KeyInstall.install(
                        publicKey: pair.publicKey,
                        // In range: `canSave` checked it.
                        host: server.host, port: UInt16(clamping: server.port),
                        username: server.username, password: password)
                    password = ""
                }

                // Shown rather than dismissed: the user needs to know whether
                // the key is actually usable, and what to do if it is not.
                isWorking = false
                generated = pair
                return
            }

            if let saved = await model.save(server) { server = saved }
            await applyProxySetting(to: server)
            await applyTunnels(to: server)
            await applyOptions(to: server)
            isWorking = false
            dismiss()
        }
    }

    /// Updates the port of the reverse tunnel that carries this server's
    /// traffic back here, when it has one; the row's switch makes and starts
    /// it. Runs after the save, because a new server has no id until then.
    private func applyProxySetting(to server: Server) async {
        guard let id = server.id else { return }
        // Only once there is a proxy, or its ports were changed from the
        // defaults: otherwise every saved server would grow two idle tunnels.
        let customized = proxyRemotePort != ProxyEnvironment.defaultRemotePort
            || proxySocksRemotePort != ProxyEnvironment.defaultSocksRemotePort
        guard proxiesBack || customized else { return }
        await model.forwards.setProxyBack(for: id, remotePort: proxyRemotePort,
                                          socksPort: proxySocksRemotePort)
    }

    /// Writes the tunnel edits. Deletions first, so a forward being replaced
    /// by one on the same port does not meet itself still listening.
    private func applyTunnels(to server: Server) async {
        guard let id = server.id else { return }
        for tunnel in removedTunnels { await model.forwards.delete(tunnel) }
        for var tunnel in tunnels {
            tunnel.serverID = id
            let before = model.forwards.presets.first { $0.id != nil && $0.id == tunnel.id }
            guard let saved = await model.forwards.save(tunnel) else { continue }
            // Started only when newly automatic. Every automatic forward, as
            // before, brought back the ones the user had switched off.
            if saved.autoStart, before?.autoStart != true { await model.forwards.start(saved) }
        }
    }

    /// Writes the chosen key's path as the server's Host's IdentityFile, so
    /// ssh in a terminal uses it too. After the save: a new server's block
    /// exists only then.
    private func applyOptions(to server: Server) async {
        guard model.sshConfig != nil, case .key(let path) = credentialChoice else { return }
        // Written as ~/.ssh/… so the config stays readable and portable.
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        guard abbreviated != identityFile else { return }
        await model.editConfigHost(server.configAlias) { $0.identityFile = abbreviated }
    }

    private func icon(for direction: PortForwardPreset.Direction) -> String {
        switch direction {
        case .local:   "arrow.right"
        case .remote:  "arrow.left"
        case .dynamic: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    private func note(for tunnel: PortForwardPreset) -> String {
        var parts: [String] = []
        switch tunnel.direction {
        case .local:   parts.append("Local")
        case .remote:  parts.append("Reverse")
        case .dynamic: parts.append("SOCKS5")
        }
        if tunnel.autoStart { parts.append("automatic") }
        if tunnel.keepAlive { parts.append("kept alive") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Seals a secret and saves it, returning the credential to point at.
    ///
    /// A key that is already stored is reused rather than stored again, so
    /// importing or re-entering the same one does not fill the picker with
    /// duplicates.
    private func store(secret: String, kind: Credential.Kind, name: String) async -> Int64? {
        if kind == .privateKey, let existing = await model.existingCredential(holding: secret) {
            return existing
        }
        guard let sealed = try? await model.vault.seal(secret, context: "credential.\(kind.rawValue)")
        else { return nil }
        let credential = try? await model.store.save(
            Credential(name: name, kind: kind, sealed: sealed))
        return credential?.id
    }
}

/// What to do with a key that was just made.
private struct GeneratedKeySheet: View {
    @Environment(Theme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let pair: SSHKeys.Pair
    /// Nil when the key was not installed from here.
    let outcome: KeyInstall.Outcome?
    let onFinished: () -> Void

    private var needsManualInstall: Bool {
        if case .installed = outcome { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if needsManualInstall {
                Text("Run on the server:")
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)

                Text(SSHKeys.installCommand(publicKey: pair.publicKey))
                    .font(theme.ui(12))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.hover)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if needsManualInstall {
                    Button("Copy Command") { copyToPasteboard(SSHKeys.installCommand(publicKey: pair.publicKey)) }
                    Button("Copy Public Key") { copyToPasteboard(pair.publicKey) }
                }
                Spacer()
                Button("Done") { dismiss(); onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 540)
    }

    @ViewBuilder
    private var header: some View {
        switch outcome {
        case .installed:
            Label("Key created and installed", systemImage: "checkmark.circle.fill")
                .font(theme.ui(15, weight: .medium))
                .foregroundStyle(.green)

        case .rejected(let reason), .failed(let reason):
            Label(outcome == .rejected(reason) ? "Key created; password refused"
                                               : "Key created; not installed",
                  systemImage: "exclamationmark.triangle.fill")
                .font(theme.ui(15, weight: .medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(theme.ui(12))
                .foregroundStyle(theme.secondaryText)

        case nil:
            Text("Key created")
                .font(theme.ui(15, weight: .medium))
        }
    }
}
