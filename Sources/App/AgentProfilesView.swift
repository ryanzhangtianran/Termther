import AppKit
import Core
import SwiftUI

/// The Settings section of an agent's page: the saved copies of its settings
/// files, one row each, and the click that puts one in place.
///
/// A file is edited as text, one sheet per profile -- or for the live files
/// -- since a settings file is JSON or TOML the user already knows. What
/// every profile shares -- MCP servers, plugins, permissions, hooks -- is
/// not in a profile at all; see `AgentProfile`.
struct AgentProfilesView: View {
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    let agents: Agents

    /// A name being asked for: a new profile's, or a renamed one's.
    @State private var naming: Naming?
    @State private var confirmingDeletion: AgentProfile?
    /// The files being edited: a profile's, or the tool's own.
    @State private var editing: Editing?

    private struct Editing: Identifiable {
        let title: String
        let files: [URL]
        var id: String { files.map(\.path).joined() }
    }

    private var paths: AgentPaths { agents.paths(tool) }

    private struct Naming: Identifiable {
        /// Nil saves the current files under the name.
        let renaming: AgentProfile?
        let id = UUID()
    }

    private var info: Agents.Info { agents[tool] }

    var body: some View {
        Section {
            ForEach(info.profiles) { profile in
                row(name: profile.name, detail: info.summaries[profile.id] ?? "",
                    isActive: profile == info.activeProfile,
                    action: { Task { await agents.applyProfile(profile, for: tool) } },
                    edit: { edit(profile) })
                .contextMenu {
                    Button("Use") { Task { await agents.applyProfile(profile, for: tool) } }
                    Button("Edit\u{2026}") { edit(profile) }
                    Button("Update from Current") { Task { await agents.updateProfile(profile, for: tool) } }
                    Button("Rename\u{2026}") { naming = Naming(renaming: profile) }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([profile.directory])
                    }
                    Divider()
                    Button("Delete\u{2026}", role: .destructive) { confirmingDeletion = profile }
                }
            }
        } header: {
            HStack {
                Text("Settings")
                Spacer()
                Button { naming = Naming(renaming: nil) } label: { Image(systemName: "plus").font(.headerPlus) }
                    .buttonStyle(.plain)
                    .help("Save As\u{2026}")
            }
        }
        .sheet(item: $naming) { naming in
            NameSheet(title: naming.renaming == nil ? "Save as" : "Rename",
                      name: naming.renaming?.name ?? "") { name in
                Task {
                    if let profile = naming.renaming {
                        await agents.renameProfile(profile, to: name, for: tool)
                    } else {
                        await agents.saveProfile(named: name, for: tool)
                    }
                }
            }
        }
        .sheet(item: $editing) { editing in
            FilesEditor(title: editing.title, files: editing.files) { Task { await agents.refresh(tool) } }
        }
        .alert(item: $confirmingDeletion) { profile in
            Alert(title: Text("Delete \u{201C}\(profile.name)\u{201D}?"),
                  message: Text("Only the saved copy is deleted."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task { await agents.deleteProfile(profile, for: tool) }
                  },
                  secondaryButton: .cancel())
        }
    }

    private func edit(_ profile: AgentProfile) {
        editing = Editing(title: profile.name,
                          files: paths.profileFiles.map { profile.directory.appending(path: $0) })
    }


    /// A radio-like row: the mark on the active one, a click to make it so,
    /// and a pencil at the end to edit its files.
    private func row(name: String, detail: String, isActive: Bool, action: (() -> Void)?,
                     edit: @escaping () -> Void) -> some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14)
                    .opacity(isActive ? 1 : 0)
                Text(name).help(detail)
                Spacer()
                Button(action: edit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit")
            }
            .contentShape(Rectangle())
        }
        // Not disabled without an action: the pencil inside would be too.
        .buttonStyle(.plain)
    }
}

/// One field asking for a name: a profile's, or a plugin's.
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var prompt = "Work"
    var button = "Save"
    @State var name = ""
    var isValid: (String) -> Bool = { !$0.isEmpty && !$0.contains("/") }
    let done: (String) -> Void

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
            TextField("Name", text: $name, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(button, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid(trimmed))
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func save() {
        guard isValid(trimmed) else { return }
        done(trimmed)
        dismiss()
    }
}

/// The text of one or more files, a tab each, saved together.
private struct FilesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    let title: String
    let files: [URL]
    let saved: () -> Void

    @State private var texts: [String] = []
    @State private var originals: [String] = []
    @State private var shown = 0
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if files.count > 1 {
                LabeledContent("File") {
                    PopUpMenu(files.indices.map { (files[$0].lastPathComponent, $0) }, selection: $shown)
                }
            } else if let file = files.first {
                Text((file.path as NSString).abbreviatingWithTildeInPath)
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
            }
            if texts.indices.contains(shown) {
                TextEditor(text: $texts[shown])
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.text.opacity(0.05)))
            }
            if let failure {
                Text(failure).font(theme.ui(12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(texts == originals)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .onAppear {
            // A file the profile lacks starts empty, and is made on save.
            texts = files.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
            originals = texts
        }
    }

    private func save() {
        do {
            for (file, text) in zip(files, texts) where text != (try? String(contentsOf: file, encoding: .utf8)) ?? "" {
                try Data(text.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            saved()
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}
