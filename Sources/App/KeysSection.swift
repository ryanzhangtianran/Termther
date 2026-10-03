import AppKit
import Core
import SwiftUI

/// The keys in the keys folder -- `~/.ssh` unless General says otherwise --
/// on the SSH Config page: generate one, copy one, or pair one with a server
/// so it logs in without a password.
struct KeysSection: View {
    @Environment(Theme.self) private var theme
    /// Where the keys are read from and written to.
    let directory: URL
    /// The hosts in the config, offered as places to pair a key with.
    let entries: [SSHConfigDocument.Entry]
    /// Points a config host at a key.
    let useKey: (_ alias: String, _ privateKeyPath: String) -> Void

    @State private var keys: [SSHKeys.PublicKey] = []
    @State private var generating = false
    @State private var pairing: SSHKeys.PublicKey?
    @State private var deleting: SSHKeys.PublicKey?
    @State private var failure: String?

    var body: some View {
        Section {
            ForEach(keys) { key in
                HStack(spacing: 10) {
                    Text(key.name)
                    Spacer()
                    Button("Pair\u{2026}") { pairing = key }
                }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.path)])
                    }
                    Divider()
                    Button("Delete\u{2026}", role: .destructive) { deleting = key }
                }
            }
            if keys.isEmpty {
                Text("No keys")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Keys")
                Spacer()
                Button { generating = true } label: {
                    Image(systemName: "plus").font(.headerPlus)
                }
                .buttonStyle(.plain)
                .help("Generate Key")
            }
        }
        .task(id: directory) { reload() }
        .sheet(isPresented: $generating) {
            GenerateKeySheet(directory: directory, taken: Set(keys.map(\.name))) { reload() }
        }
        .sheet(item: $pairing) { key in
            PairKeySheet(key: key, entries: entries, useKey: useKey)
        }
        .alert(item: $deleting) { key in
            Alert(title: Text("Delete \u{201C}\(key.name)\u{201D}?"),
                  message: Text("Both halves are deleted from \(folder)."),
                  primaryButton: .destructive(Text("Delete")) {
                      do { try SSHKeys.remove(key) } catch { failure = String(describing: error) }
                      reload()
                  },
                  secondaryButton: .cancel())
        }
        .alert("Could not delete key", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var folder: String { (directory.path as NSString).abbreviatingWithTildeInPath }

    private func reload() { keys = SSHKeys.publicKeys(in: directory) }

}

/// A new key pair, written to the keys folder by ssh-keygen.
private struct GenerateKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let directory: URL
    /// Names already in the folder: generating replaces a file, so these are refused.
    let taken: Set<String>
    let onGenerated: () -> Void

    @State private var name = ""
    @State private var kind = SSHKeys.Kind.ed25519
    @State private var comment = "\(NSUserName())@\(Host.current().localizedName ?? "Mac")"
    @State private var isWorking = false
    @State private var failure: String?

    private var fileName: String { SSHKeys.fileName(kind: kind, name: name) }
    private var isTaken: Bool { taken.contains(fileName) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // Empty is allowed: it is the name the prompt shows, and the file below.
                    TextField("Name", text: $name, prompt: Text("key"))
                    LabeledContent("Type") {
                        PopUpMenu(SSHKeys.Kind.allCases.map { ($0.title, $0) }, selection: $kind)
                    }
                    TextField("Comment", text: $comment)
                    LabeledContent("File", value: (directory.appending(path: fileName).path as NSString)
                        .abbreviatingWithTildeInPath)
                        .foregroundStyle(isTaken ? .red : .secondary)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            // Not the rows of the Settings page this sheet opened from.
            .labeledContentStyle(.automatic)
            Divider()
            HStack {
                if isTaken {
                    Text("Already exists")
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate", action: generate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTaken || isWorking)
            }
            .padding(12)
        }
        .frame(width: 440, height: 300)
    }

    private func generate() {
        isWorking = true
        Task {
            do {
                _ = try await SSHKeys.generate(kind: kind, name: name, comment: comment, in: directory)
                onGenerated()
                dismiss()
            } catch {
                failure = String(describing: error)
            }
            isWorking = false
        }
    }
}

/// Puts a public key on a server, the way ssh-copy-id does: the password is
/// used for that one connection and not kept.
private struct PairKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeys.PublicKey
    let entries: [SSHConfigDocument.Entry]
    let useKey: (_ alias: String, _ privateKeyPath: String) -> Void

    /// The config host being paired, or "" for one typed in.
    @State private var alias = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var usesKeyForHost = true
    @State private var isWorking = false
    @State private var outcome: KeyInstall.Outcome?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Key", value: key.name)
                    LabeledContent("Server") {
                        PopUpMenu([("Other", "")] + entries.map { ($0.alias, $0.alias) },
                                  selection: $alias)
                    }
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    TextField("User", text: $user)
                    SecureField("Password", text: $password)
                    if !alias.isEmpty, key.privateKeyPath != nil {
                        Toggle("Set as IdentityFile for \(alias)",
                               isOn: $usesKeyForHost)
                    }
                }
                if let outcome {
                    Section { result(outcome) }
                }
            }
            .formStyle(.grouped)
            // Not the rows of the Settings page this sheet opened from.
            .labeledContentStyle(.automatic)
            .toggleStyle(.automatic)
            Divider()
            HStack {
                Spacer()
                Button(outcome == .installed ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || user.isEmpty || password.isEmpty
                              || Int(port) == nil || isWorking || outcome == .installed)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
        .onChange(of: alias) { fill(from: alias) }
    }

    @ViewBuilder
    private func result(_ outcome: KeyInstall.Outcome) -> some View {
        switch outcome {
        case .installed:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected(let why):
            Label("Password refused: \(why)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .failed(let why):
            Label(why, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func fill(from alias: String) {
        guard let entry = entries.first(where: { $0.alias == alias }) else { return }
        host = entry.hostName.isEmpty ? entry.alias : entry.hostName
        port = entry.port.isEmpty ? "22" : entry.port
        user = entry.user
    }

    private func pair() {
        isWorking = true
        Task {
            let result = await KeyInstall.install(
                publicKey: key.text, host: host, port: UInt16(port) ?? 22,
                username: user, password: password)
            password = ""
            if result == .installed, !alias.isEmpty, usesKeyForHost,
               let path = key.privateKeyPath {
                // Written as ~/.ssh/… so the config stays readable and portable.
                useKey(alias, (path as NSString).abbreviatingWithTildeInPath)
            }
            outcome = result
            isWorking = false
        }
    }
}
