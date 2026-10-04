import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

/// The SSH Config page: the file itself, its hosts as a table edited where
/// they are, and the keys in the keys folder. Both are where
/// General says, `~/.ssh` and `~/.ssh/config` unless moved.
///
/// Every change is written straight back through `SSHConfigDocument`, which
/// touches only the lines it must. A host that is a connection is kept in
/// step with it (see `AppModel`'s config sync); making one a connection is
/// the Connections page's Import. Rules that are not a single host --
/// `Host *`, `Match` -- are left to the file's own editor.
struct SSHConfigSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    /// The file as read, so a save can tell whether something else changed it.
    @State private var original = ""
    @State private var document = SSHConfigDocument(text: "")
    @State private var editing: SSHConfigDocument.Entry?
    @State private var failure: String?
    @State private var editingFile = false

    private var url: URL { model.paths[.sshConfig] }

    var body: some View {
        // The file itself, opened whole in the app's own editor; where it is
        // says General.
        Section {
            // Named, with where it is beside the button, as General's rows
            // are: a bare path alone in the row read as a stray string.
            LabeledContent {
                HStack(spacing: 8) {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose") { model.choosePath(.sshConfig) }
                        .buttonStyle(.plate)
                    Button("Open in Editor") { editingFile = true }
                        .buttonStyle(.plate)
                }
            } label: {
                Text("Config File")
            }
            .sheet(isPresented: $editingFile) {
                TextFileEditor(url: url)
            }
        }

        Section {
            HostRow.header
            ForEach(document.entries) { entry in
                HostRow(entry: entry) { editing = entry }
            }
            if document.entries.isEmpty {
                Text("No hosts")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack(spacing: 12) {
                Text("Hosts")
                Spacer()
                TileButton(symbol: "plus", size: 20, help: "Add Host") { editing = .init(alias: "") }
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

        // The page follows the file's change, as it follows any other.
        KeysSection(directory: model.paths[.keys], entries: document.entries) { alias, path in
            Task { await model.useKey(path, for: alias) }
        }
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
}

/// One host across the table: its alias, where it goes, its key and the
/// host it jumps through, each in a column of its own width.
private struct HostRow: View {
    @Environment(Theme.self) private var theme
    let entry: SSHConfigDocument.Entry
    let open: () -> Void

    /// Fixed widths, the room left over at the row's end rather than
    /// between the columns, where it pushed Key and Jump far from Address.
    enum Column {
        static let alias: CGFloat = 140
        static let address: CGFloat = 230
        static let key: CGFloat = 170
        static let jump: CGFloat = 110
    }

    static var header: some View { Header() }

    private struct Header: View {
        @Environment(Theme.self) private var theme
        var body: some View {
            HStack(spacing: 16) {
                Text("Alias").frame(width: Column.alias, alignment: .leading)
                Text("Address").frame(width: Column.address, alignment: .leading)
                Text("Key").frame(width: Column.key, alignment: .leading)
                Text("Jump").frame(width: Column.jump, alignment: .leading)
                Spacer(minLength: 0)
            }
            .groupTitle(theme)
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                Text(entry.alias)
                    .lineLimit(1)
                    .frame(width: Column.alias, alignment: .leading)
                cell(address)
                    .frame(width: Column.address, alignment: .leading)
                cell(entry.identityFile.isEmpty ? nil
                     : URL(fileURLWithPath: entry.identityFile).lastPathComponent)
                    .frame(width: Column.key, alignment: .leading)
                cell(entry.proxyJump.isEmpty ? nil : entry.proxyJump, color: theme.ansi(12))
                    .frame(width: Column.jump, alignment: .leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `user@host:port`, with whatever the entry leaves to ssh's defaults left out.
    private var address: String {
        var text = entry.hostName.isEmpty ? entry.alias : entry.hostName
        if !entry.user.isEmpty { text = "\(entry.user)@\(text)" }
        if !entry.port.isEmpty { text += ":\(entry.port)" }
        return text
    }

    private func cell(_ text: String?, color: Color? = nil) -> some View {
        Text(text ?? "\u{2013}")
            .foregroundStyle(text == nil ? theme.secondaryText.opacity(0.5) : color ?? theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
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
            PopUpMenu(choices([("Default", ""), ("Yes", "yes"), ("No", "no")], value.wrappedValue),
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
        // Folded unless the host sets any: most set none. A section of its
        // own rather than a disclosure group, whose rows had no separators
        // and sat crowded against each other.
        Section {
            if showsOptions {
                yesNo("ForwardAgent", $entry.forwardAgent)
                TextField("ServerAliveInterval", text: $entry.serverAliveInterval, prompt: Text("0"))
                yesNo("Compression", $entry.compression)
                yesNo("IdentitiesOnly", $entry.identitiesOnly)
                LabeledContent("StrictHostKeyChecking") {
                    PopUpMenu(choices([("Default", ""), ("Yes", "yes"), ("No", "no"),
                                       ("Accept New", "accept-new"), ("Off", "off")],
                                      entry.strictHostKeyChecking),
                              selection: $entry.strictHostKeyChecking)
                }
                LabeledContent("RequestTTY") {
                    PopUpMenu(choices([("Default", ""), ("Yes", "yes"), ("No", "no"),
                                       ("Force", "force"), ("Auto", "auto")], entry.requestTTY),
                              selection: $entry.requestTTY)
                }
                TextField("RemoteCommand", text: $entry.remoteCommand)
                // Anything else, one `Keyword value` a line.
                TextField("Other", text: $otherOptions, prompt: Text("Keyword value"), axis: .vertical)
                    .lineLimit(2...6)
            }
        } header: {
            Button { showsOptions.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Options")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsOptions ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
