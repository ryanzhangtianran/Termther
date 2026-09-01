import AppKit
import Core
import SwiftUI

/// Adds or edits one server.
struct ServerEditor: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var server: Server
    @State private var password = ""
    @State private var credentials: [Credential] = []
    @State private var credentialChoice: CredentialChoice = .password
    @State private var keyKind: SSHKeys.Kind = .ed25519
    @State private var importedKey: String?
    @State private var importedKeyName: String?
    @State private var discovered: [URL] = []
    @State private var discoveredChoice: String?
    @State private var isWorking = false
    @State private var generated: SSHKeys.Pair?
    @State private var installsKey = true
    @State private var installOutcome: KeyInstall.Outcome?
    /// The reverse tunnel that puts this server's outbound traffic through
    /// this Mac. Kept as its own switch because that is how it is thought
    /// about; it is an ordinary forward underneath.
    @State private var proxiesBack = false
    @State private var proxyRemotePort = ProxyEnvironment.defaultRemotePort
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
        case existing(Int64)
    }

    init(model: AppModel, server: Server) {
        self.model = model
        _server = State(initialValue: server)
        _credentialChoice = State(initialValue:
            server.credentialId.map(CredentialChoice.existing) ?? .password)
    }

    private var isNew: Bool { server.id == nil }

    private var canSave: Bool {
        guard !server.host.isEmpty, !server.username.isEmpty, !isWorking else { return false }
        return switch credentialChoice {
        case .password: !password.isEmpty || !isNew
        case .importKey: importedKey != nil
        case .generateKey: !installsKey || !password.isEmpty
        case .existing: true
        }
    }

    /// Adding a server has two shapes, and they belong in one sheet: typing the
    /// details out, or picking from what is already written down. Separating
    /// them into two buttons made the second one easy to miss, which is a
    /// shame when it is usually the faster route.
    private enum Mode: Hashable { case manual, importing }
    @State private var mode: Mode = .manual

    var body: some View {
        VStack(spacing: 0) {
            if isNew {
                Picker("", selection: $mode) {
                    Text("New Server").tag(Mode.manual)
                    Text("From SSH Config").tag(Mode.importing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }

            if mode == .importing {
                ImportList(model: model, onFinished: { dismiss() })
            } else {
                form
            }
        }
        .frame(width: 470, height: 540)
        .task {
            credentials = (try? await model.store.credentials()) ?? []
            discovered = SSHKeys.discoverInSSHDirectory()
            if let id = server.id {
                if let preset = model.forwards.proxyBack(for: id) {
                    proxiesBack = true
                    proxyRemotePort = preset.bindPort
                }
                tunnels = model.forwards.plainPresets(forServer: id)
            }
        }
        .onChange(of: discoveredChoice) {
            guard let path = discoveredChoice else { return }
            let url = URL(fileURLWithPath: path)
            importedKey = try? SSHKeys.read(at: url)
            importedKeyName = url.lastPathComponent
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
                    TextField("Host", text: $server.host, prompt: Text("example.com"))
                    TextField("Port", value: $server.port, format: .number.grouping(.never))
                    TextField("User", text: $server.username)
                }

                Section("Credential") {
                    Picker("Use", selection: $credentialChoice) {
                        Text(isNew ? "Password" : "Replace password").tag(CredentialChoice.password)
                        Text("Generate a new key").tag(CredentialChoice.generateKey)
                        Text("Import a key file\u{2026}").tag(CredentialChoice.importKey)
                        if !credentials.isEmpty { Divider() }
                        ForEach(credentials) { credential in
                            Text(credential.name).tag(CredentialChoice.existing(credential.id ?? -1))
                        }
                    }

                    switch credentialChoice {
                    case .password:
                        SecureField("Password", text: $password,
                                    prompt: Text(isNew ? "Required" : "Leave blank to keep"))

                    case .generateKey:
                        Picker("Type", selection: $keyKind) {
                            ForEach(SSHKeys.Kind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        Toggle("Install it on the server now", isOn: $installsKey)
                        if installsKey {
                            SecureField("Server password", text: $password,
                                        prompt: Text("Used once, not saved"))
                            Text("Logs in with the password once to append the key to "
                                 + "authorized_keys. After that the key is what gets you in.")
                                .font(theme.ui(11))
                                .foregroundStyle(theme.secondaryText)
                        } else {
                            Text("Written to ~/.ssh and stored in the vault. You will need to "
                                 + "put the public half on the server yourself.")
                                .font(theme.ui(11))
                                .foregroundStyle(theme.secondaryText)
                        }

                    case .importKey:
                        HStack(spacing: 8) {
                            Button("Choose File\u{2026}") { chooseKeyFile() }
                                .controlSize(.small)
                            if let name = importedKeyName {
                                Text(name)
                                    .font(theme.ui(11))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        if !discovered.isEmpty && importedKey == nil {
                            // What is already in ~/.ssh, so the common case
                            // does not need a file dialog at all.
                            Picker("In ~/.ssh", selection: $discoveredChoice) {
                                Text("None").tag(String?.none)
                                ForEach(discovered, id: \.self) { url in
                                    Text(url.lastPathComponent).tag(String?.some(url.path))
                                }
                            }
                        }

                    case .existing:
                        EmptyView()
                    }
                }

                Section("Route") {
                    Picker("Jump host", selection: $server.jumpHostId) {
                        Text("None").tag(Int64?.none)
                        // A server cannot be its own way in.
                        ForEach(model.servers.filter { $0.id != server.id }) { candidate in
                            Text(candidate.name.isEmpty ? candidate.host : candidate.name)
                                .tag(Int64?.some(candidate.id ?? -1))
                        }
                    }
                    Toggle("Reach it through the VPN", isOn: $server.routesThroughVPN)
                    if server.routesThroughVPN {
                        Text("Connections to this host are dialled inside the "
                             + "tunnel. Nothing else is.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    TextField("Tags", text: $server.tags, prompt: Text("work, gpu"))
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
                                    .font(theme.ui(12))
                                Text(note(for: tunnel))
                                    .font(theme.ui(10))
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
                            preset: PortForwardPreset(serverId: server.id ?? 0,
                                                      direction: .local, bindPort: 8080,
                                                      targetHost: "127.0.0.1", targetPort: 80))
                    }
                    .controlSize(.small)

                    if tunnels.isEmpty {
                        Text("A tunnel over this server\u{2019}s connection: a local "
                             + "port that reaches something it can see, a SOCKS5 "
                             + "proxy, or a port on the server that reaches back here.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Section("Proxy") {
                    Toggle("Send this server\u{2019}s traffic back through this Mac",
                           isOn: $proxiesBack)
                    if proxiesBack {
                        TextField("Port on the server", value: $proxyRemotePort,
                                  format: .number.grouping(.never))
                        // The port here is a fact about this Mac, not about
                        // this server, so it is set once in the Proxy panel
                        // and only shown here.
                        Text(proxyExplanation)
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
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
            switch credentialChoice {
            case .existing(let id):
                server.credentialId = id

            case .password where !password.isEmpty:
                server.credentialId = await store(secret: password, kind: .password,
                                                  name: "\(server.username)@\(server.host)")

            case .password:
                break   // editing without changing the password

            case .importKey:
                if let key = importedKey {
                    server.credentialId = await store(secret: key, kind: .privateKey,
                                                      name: importedKeyName ?? "imported key")
                }

            case .generateKey:
                guard let pair = try? await SSHKeys.generate(
                    kind: keyKind, name: server.name,
                    comment: "\(server.username)@\(server.host) (Termther)")
                else { break }

                server.credentialId = await store(secret: pair.privateKey, kind: .privateKey,
                                                  name: "\(server.name) \(pair.kind.title)")
                if let saved = await model.save(server) { server = saved }
                await applyProxySetting(to: server)
                await applyTunnels(to: server)

                if installsKey, !password.isEmpty {
                    // The password authenticates one connection whose only job
                    // is to append the key, and is never stored.
                    installOutcome = await KeyInstall.install(
                        publicKey: pair.publicKey,
                        host: server.host, port: UInt16(server.port),
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
            isWorking = false
            dismiss()
        }
    }

    /// Creates, updates or removes the reverse tunnel that carries this
    /// server's traffic back here. Runs after the save, because a brand new
    /// server has no id to hang a forward off until then.
    private func applyProxySetting(to server: Server) async {
        guard let id = server.id else { return }
        await model.forwards.setProxyBack(proxiesBack, for: id, remotePort: proxyRemotePort)
    }

    /// Writes the tunnel edits. Deletions first, so a forward being replaced
    /// by one on the same port does not meet itself still listening.
    private func applyTunnels(to server: Server) async {
        guard let id = server.id else { return }
        for tunnel in removedTunnels { await model.forwards.delete(tunnel) }
        for var tunnel in tunnels {
            tunnel.serverId = id
            await model.forwards.save(tunnel)
        }
        // Picks up anything newly marked automatic; already-running forwards
        // are left alone.
        await model.forwards.startAutomatic()
    }

    /// Built as a plain String, not interpolated into a Text: SwiftUI applies
    /// the locale's number style to an interpolated Int, and a port written
    /// "16,152" is not a port.
    private var proxyExplanation: String {
        let here = String(model.forwards.proxyLocalPort)
        let there = String(proxyRemotePort)
        return "The server\u{2019}s 127.0.0.1:\(there) arrives at 127.0.0.1:\(here) "
            + "on this Mac. New terminals here get http_proxy pointed at it, so "
            + "curl, git and the rest go out through it. Change which local port "
            + "in the Proxy panel."
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
                Text("Run this on the server to let the key in:")
                    .font(theme.ui(11))
                    .foregroundStyle(theme.secondaryText)

                Text(SSHKeys.installCommand(publicKey: pair.publicKey))
                    .font(theme.mono(11))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.hover)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if needsManualInstall {
                    Button("Copy Command") { copy(SSHKeys.installCommand(publicKey: pair.publicKey)) }
                    Button("Copy Public Key") { copy(pair.publicKey) }
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
                .font(theme.ui(14, weight: .medium))
                .foregroundStyle(.green)
            Text("\(pair.kind.title), in your vault and in the server's authorized_keys. "
                 + "Connecting will use it from now on.")
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)

        case .rejected(let reason):
            Label("Key created, but the password was refused",
                  systemImage: "exclamationmark.triangle.fill")
                .font(theme.ui(14, weight: .medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)

        case .failed(let reason):
            Label("Key created, but it could not be installed",
                  systemImage: "exclamationmark.triangle.fill")
                .font(theme.ui(14, weight: .medium))
                .foregroundStyle(.orange)
            Text(reason)
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)

        case nil:
            Text("Key created")
                .font(theme.ui(14, weight: .medium))
            Text("The private half is in your vault. The server will not accept it until "
                 + "the public half is in its authorized_keys.")
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
