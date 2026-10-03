import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

/// The SSH Config page: the hosts in the config file, edited where they are,
/// the file's other rules, and the keys in the keys folder. Both are where
/// General says, `~/.ssh` and `~/.ssh/config` unless moved.
///
/// Every change is written straight back through `SSHConfigDocument`, which
/// touches only the lines it must. A host that is a connection is kept in
/// step with it (see `AppModel`'s config sync); making one a connection is
/// the Connections page's Import. Rules that are not a single host --
/// `Host *`, `Match` -- are listed but left to a text editor.
struct SSHConfigSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let workspace: Workspace
    /// The file as read, so a save can tell whether something else changed it.
    @State private var original = ""
    @State private var document = SSHConfigDocument(text: "")
    @State private var editing: SSHConfigDocument.Entry?
    @State private var failure: String?

    private var url: URL { model.paths[.sshConfig] }

    var body: some View {
        Section {
            ForEach(document.entries) { entry in
                Button {
                    editing = entry
                } label: {
                    LabeledContent(entry.alias) {
                        Text(summary(entry))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if document.entries.isEmpty {
                Text("No hosts")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack(spacing: 12) {
                Text("Hosts")
                Spacer()
                // The file itself, in vim; where it is says General.
                Button("Edit", action: openInEditor)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
                Button { editing = .init(alias: "") } label: {
                    Image(systemName: "plus").font(.headerPlus)
                }
                .buttonStyle(.plain)
                .help("Add Host")
            }
        }
        // Edits made in a text editor come across whenever the page opens,
        // and the page follows the file when General moves it.
        .task(id: url) {
            await model.syncConfig()
            load()
            // Then whenever the file changes under the page -- saved from
            // vim, or by a server saved elsewhere.
            guard let changes = DirectoryWatcher.changes(in: url.deletingLastPathComponent()) else { return }
            for await _ in changes {
                await model.syncConfig()
                load()
            }
        }
        .sheet(item: $editing) { target in
            // A new host starts with no name, which no saved host can have.
            let old = target.alias.isEmpty ? nil : target.alias
            HostEditor(entry: target, isNew: old == nil,
                       keys: SSHKeys.discover(in: model.paths[.keys]),
                       hosts: document.entries.map(\.alias).filter { $0 != target.alias },
                       save: { entry in
                           guard commit({ try $0.save(entry, replacing: old) }) else { return false }
                           Task {
                               if let old, old != entry.alias {
                                   await model.configHostRenamed(from: old, to: entry.alias)
                               }
                               await model.syncConfig()
                           }
                           return true
                       },
                       delete: {
                           guard commit({ try $0.remove(alias: target.alias) }) else { return false }
                           Task { await model.configHostRemoved(target.alias) }
                           return true
                       })
        }
        .alert("Could not save", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }

        if !document.otherBlocks.isEmpty {
            Section("Other Rules") {
                ForEach(document.otherBlocks, id: \.self) { rule in
                    Text(rule)
                        .font(theme.ui(13))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }

        // The page follows the file's change, as it follows any other.
        KeysSection(directory: model.paths[.keys], entries: document.entries) { alias, path in
            Task { await model.editConfigHost(alias) { $0.identityFile = path } }
        }
    }

    /// `user@host:port`, with whatever the entry leaves to ssh's defaults left out.
    private func summary(_ entry: SSHConfigDocument.Entry) -> String {
        var text = entry.hostName.isEmpty ? entry.alias : entry.hostName
        if !entry.user.isEmpty { text = "\(entry.user)@\(text)" }
        if !entry.port.isEmpty { text += ":\(entry.port)" }
        return text
    }

    private func load() {
        do {
            original = try SSHConfigDocument.read(url)
        } catch {
            // Shown empty, and every save refused: `save` reads it again.
            original = ""
            failure = String(describing: error)
        }
        document = SSHConfigDocument(text: original)
    }

    /// Applies one edit and writes the file; false, with the reason shown, when
    /// the edit is refused or the file cannot be written.
    private func commit(_ change: (inout SSHConfigDocument) throws -> Void) -> Bool {
        var updated = document
        do {
            try change(&updated)
            try updated.save(to: url, original: original)
            document = updated
            original = updated.text
            return true
        } catch {
            failure = String(describing: error)
            return false
        }
    }

    /// In vim, in a terminal tab of its own; the file is read again as it
    /// is saved.
    private func openInEditor() {
        workspace.openLocal(title: "config", command: "vim \(shellQuoted(url.path))", directory: nil)
    }
}

/// One host's fields, with Delete for one that exists.
private struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: SSHConfigDocument.Entry
    let isNew: Bool
    /// The keys folder's keys, for `IdentityFile`.
    let keys: [URL]
    /// The file's other hosts, for `ProxyJump`.
    let hosts: [String]
    let save: (SSHConfigDocument.Entry) -> Bool
    let delete: () -> Bool

    @State private var confirmingDelete = false
    @State private var otherOptions = ""
    @State private var showsOptions = false

    /// Default, yes or no: what ssh takes for the option.
    private func yesNo(_ keyword: String, _ value: Binding<String>) -> some View {
        LabeledContent(keyword) {
            PopUpMenu(choices([("Default", ""), ("yes", "yes"), ("no", "no")], value.wrappedValue),
                      selection: value)
        }
    }

    /// The menu's choices, with the file's own value added when it is not
    /// one of them, so nothing is lost by being shown.
    private func choices(_ options: [(String, String)], _ current: String) -> [(String, String)] {
        options.contains { $0.1 == current } ? options : options + [(current, current)]
    }

    /// The options past the address, each as ssh reads it, with its default
    /// where there is a free value: the file is `Keyword value`, and so is this.
    private var optionsSection: some View {
        // Folded unless the host sets any: most set none.
        Section {
            DisclosureGroup("Options", isExpanded: $showsOptions) {
            yesNo("ForwardAgent", $entry.forwardAgent)
            TextField("ServerAliveInterval", text: $entry.serverAliveInterval, prompt: Text("0"))
            yesNo("Compression", $entry.compression)
            yesNo("IdentitiesOnly", $entry.identitiesOnly)
            LabeledContent("StrictHostKeyChecking") {
                PopUpMenu(choices([("Default", ""), ("yes", "yes"), ("no", "no"),
                                   ("accept-new", "accept-new"), ("off", "off")],
                                  entry.strictHostKeyChecking),
                          selection: $entry.strictHostKeyChecking)
            }
            LabeledContent("RequestTTY") {
                PopUpMenu(choices([("Default", ""), ("yes", "yes"), ("no", "no"),
                                   ("force", "force"), ("auto", "auto")], entry.requestTTY),
                          selection: $entry.requestTTY)
            }
            TextField("RemoteCommand", text: $entry.remoteCommand)
            // Anything else, one `Keyword value` a line.
            TextField("Other", text: $otherOptions, prompt: Text("Keyword value"), axis: .vertical)
                .lineLimit(2...6)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Host", text: $entry.alias)
                    TextField("HostName", text: $entry.hostName)
                    TextField("User", text: $entry.user)
                    TextField("Port", text: $entry.port, prompt: Text("22"))
                    // One of the keys in the Keys folder below, as ssh will
                    // read it; a path the file has that is not one is kept.
                    LabeledContent("IdentityFile") {
                        PopUpMenu(choices([("None", "")] + keys.map {
                            ($0.lastPathComponent, ($0.path as NSString).abbreviatingWithTildeInPath)
                        }, entry.identityFile), selection: $entry.identityFile)
                    }
                    LabeledContent("ProxyJump") {
                        PopUpMenu(choices([("None", "")] + hosts.map { ($0, $0) }, entry.proxyJump),
                                  selection: $entry.proxyJump)
                    }
                }
                optionsSection
            }
            .formStyle(.grouped)
            .onAppear {
                otherOptions = entry.other.joined(separator: "\n")
                showsOptions = ![entry.forwardAgent, entry.serverAliveInterval, entry.compression,
                                 entry.identitiesOnly, entry.strictHostKeyChecking, entry.requestTTY,
                                 entry.remoteCommand, otherOptions].allSatisfy(\.isEmpty)
            }
            // Not the rows of the Settings page this sheet opened from.
            .labeledContentStyle(.automatic)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var entry = entry
                    entry.other = otherOptions.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if save(entry) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.alias.isEmpty || !entry.port.allSatisfy(\.isNumber))
            }
            .padding(12)
        }
        .frame(width: 460, height: showsOptions ? 640 : 400)
        .animation(.easeOut(duration: 0.15), value: showsOptions)
        .alert("Delete \u{201C}\(entry.alias)\u{201D}?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if delete() { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
