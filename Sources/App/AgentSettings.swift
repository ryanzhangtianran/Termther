import AppKit
import Core
import SwiftUI

/// One coding agent's page in Settings: its settings profiles, MCP
/// servers, prompt file and skills, and the sessions it has left behind.
///
/// Everything is read from and written to the tool's own files through
/// `Agents`.
struct AgentSettings: View {
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    @Bindable var model: AppModel
    let workspace: Workspace

    @State private var installingPlugin = false
    @State private var confirmingUninstall: AgentPlugin?
    @State private var syncServerID: Int64?
    @State private var syncing = false
    @State private var editingPrompt = false

    /// The tool's own colour, as its page in the sidebar has it.

    /// Something being edited in a sheet; a fresh id each time, so opening
    /// the same one twice opens the sheet twice.
    private struct Editing<Value>: Identifiable {
        let value: Value
        let id = UUID()
    }

    private var agents: Agents { model.agents }
    private var info: Agents.Info { agents[tool] }
    private var other: AgentTool { tool == .claude ? .codex : .claude }

    var body: some View {
        toolSection
        AgentProfilesView(tool: tool, agents: agents)
        pluginsSection
        promptSection
        syncSection
        skillsSection
        usageSection
    }

    // MARK: - the tool

    /// The tool itself, as one row like those under it: its mark, its
    /// version and its updater, and under it what the last update said.
    private var toolSection: some View {
        Section {
            // An ordinary row: its name, and the figure and the button
            // at its end, as every other row has them.
            LabeledContent("Version") {
                HStack(spacing: 10) {
                    Text(info.version ?? "Not Installed")
                        .monospacedDigit()
                        .foregroundStyle(info.version == nil ? theme.waiting : theme.secondaryText)
                    if info.isUpdating {
                        // The updater prints nothing to measure by, so no bar.
                        ProgressView().controlSize(.small)
                        Text("Updating\u{2026}")
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Button("Check for Updates") { Task { await agents.updateTool(tool) } }
                            .buttonStyle(.plate)
                            .disabled(info.version == nil)
                    }
                }
            }
            if let news = info.updateNews {
                HStack {
                    Label(news.text, systemImage: news.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(news.failed ? .red : .green)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    TileButton(symbol: "xmark", size: 20, help: "Close") { agents.dismissUpdateNews(tool) }
                }
            }
        }
        .task(id: tool) {
            // Side by side: the sessions take seconds to read, the rest a
            // fraction of one, and none needs another.
            async let sessions: Void = agents.refreshSessions(tool)
            await agents.refresh(tool)
            await agents.refreshPlugins(tool)
            await sessions
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - plugins

    /// The tool's plugins, each with its switch. Adding, updating and
    /// removing one is the tool's own command, run in a tab: it fetches,
    /// prints, and may ask.
    private var pluginsSection: some View {
        Section {
            ForEach(info.plugins ?? []) { plugin in
                Toggle(isOn: Binding(
                    get: { plugin.enabled },
                    set: { on in Task { await agents.setPluginEnabled(on, plugin, for: tool) } })) {
                    Text(plugin.name)
                    .help("@\(plugin.marketplace) \u{00B7} \(plugin.version)")
                }
                .contextMenu {
                    Button("Update") {
                        workspace.openLocal(title: "Update \(plugin.name)",
                                            command: AgentPlugin.updateCommand(id: plugin.id, tool: tool),
                                            directory: nil)
                    }
                    if let path = plugin.installPath {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    }
                    Divider()
                    Button("Uninstall", role: .destructive) { confirmingUninstall = plugin }
                }
            }
            if let plugins = info.plugins, plugins.isEmpty {
                Text("No plugins")
                    .foregroundStyle(theme.secondaryText)
            } else if info.plugins == nil, let why = info.pluginsError {
                LabeledContent {
                    Button("Retry") { Task { await agents.refreshPlugins(tool) } }
                        .buttonStyle(.plate)
                } label: {
                    Text(why)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else if info.plugins == nil {
                Text("Loading\u{2026}")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Plugins")
                Spacer()
                TileButton(symbol: "plus", size: 20, help: "Install") { installingPlugin = true }
            }
        }
        .sheet(isPresented: $installingPlugin) {
            NameSheet(title: "Install plugin", prompt: "name@marketplace", button: "Install",
                      isValid: Self.isPluginID) { id in
                workspace.openLocal(title: "Install \(id)", command: AgentPlugin.installCommand(id: id, tool: tool),
                                    directory: nil)
            }
        }
        .alert(item: $confirmingUninstall) { plugin in
            Alert(title: Text("Uninstall \u{201C}\(plugin.name)\u{201D}?"),
                  primaryButton: .destructive(Text("Uninstall")) {
                      workspace.openLocal(title: "Uninstall \(plugin.name)",
                                          command: AgentPlugin.uninstallCommand(id: plugin.id, tool: tool),
                                          directory: nil)
                  },
                  secondaryButton: .cancel())
        }
    }

    /// `name@marketplace`, in the characters a plugin name is made of --
    /// this goes to a shell.
    private static func isPluginID(_ id: String) -> Bool {
        let parts = id.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
        }
    }

    // MARK: - the prompt file

    /// The file the agent reads before every session, edited in the app's
    /// own editor, as `~/.ssh/config` is.
    private var promptSection: some View {
        let file = agents.paths(tool).prompt
        // Named only: the tool decides where it is, so the path is on hover.
        return Section {
            LabeledContent {
                Button("Edit") { editingPrompt = true }
                    .buttonStyle(.plateProminent)
            } label: {
                Text(file.lastPathComponent)
                    .help((file.path as NSString).abbreviatingWithTildeInPath)
            }
            .sheet(isPresented: $editingPrompt) {
                TextFileEditor(url: file)
            }
        }
    }

    // MARK: - syncing to a server

    /// The same setup on a server: the files sent whole, into the same
    /// places under the account's home.
    private var syncSection: some View {
        let selected = syncServerID ?? model.servers.first?.id
        return Section {
            LabeledContent("Server") {
                HStack(spacing: 10) {
                    PopUpMenu(model.servers.map { ($0.name, $0.id) },
                              selection: Binding(get: { selected }, set: { syncServerID = $0 }))
                    Button(syncing ? "Syncing\u{2026}" : "Sync") {
                        guard let server = model.servers.first(where: { $0.id == selected }) else { return }
                        syncing = true
                        Task {
                            await agents.sync(tool, to: server)
                            syncing = false
                        }
                    }
                    .buttonStyle(.plateProminent)
                    .disabled(syncing || model.servers.isEmpty || info.syncItems.isEmpty)
                    // What goes, and when it last went, on hover.
                    .help(syncDetail)
                }
            }
        } header: {
            Text("Sync to Server")
        }
    }

    private var syncDetail: String {
        var lines = info.syncItems.isEmpty ? ["Nothing to sync"] : info.syncItems
        if let last = info.lastSync {
            lines.append("Last synced to \(last.server), \(last.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.chrome)))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - skills

    /// The user's own: a plugin's or a synced one is the plugin's business.
    private var ownSkills: [AgentSkill] { info.skills.filter(\.isOwn) }

    private var skillsSection: some View {
        Section {
            ForEach(ownSkills) { skill in
                // The name; what it is for is on hover.
                Text(skill.name)
                    .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(skill.description)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Copy to \(other.title)") { Task { await agents.installSkill(from: skill.path, into: other) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.path]) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task { await agents.removeSkill(skill, from: tool) }
                    }
                }
            }
            if ownSkills.isEmpty {
                Text("No skills")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Skills")
                Spacer()
                TileButton(symbol: "plus", size: 20, help: "Install", action: installSkill)
            }
        }
    }

    /// A folder holding a `SKILL.md`, copied in under its own name.
    private func installSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "A folder containing SKILL.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Listed only with a SKILL.md, so one without would vanish on install.
            guard FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path) else {
                NSSound.beep()
                return
            }
            Task { await agents.installSkill(from: url, into: tool) }
        }
    }

    // MARK: - usage

    /// The tokens, as a plate like every other section: the total and the
    /// four kinds in one row of equal columns, then how much of the input
    /// the cache answered. No icons or colours of their own: colour is kept
    /// for state, and a cache hit is the one thing here going well or not.
    private var usageSection: some View {
        let usage = info.usage
        let prompted = usage.input + usage.cacheRead + usage.cacheWrite
        let hitRate = prompted == 0 ? 0 : Double(usage.cacheRead) / Double(prompted)
        return Section("Tokens") {
            HStack(alignment: .top, spacing: 0) {
                usageFigure("Total", usage.total)
                usageFigure("Input", usage.input)
                usageFigure("Output", usage.output)
                usageFigure("Cache write", usage.cacheWrite)
                usageFigure("Cache read", usage.cacheRead)
            }
            .padding(.vertical, 6)
            HStack(spacing: 12) {
                Text("Cache hit")
                    .foregroundStyle(theme.secondaryText)
                GeometryReader { space in
                    Capsule().fill(theme.text.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.online).frame(width: space.size.width * hitRate)
                        }
                }
                .frame(height: 4)
                Text(hitRate.formatted(.percent.precision(.fractionLength(1)).locale(.chrome)))
                    .monospacedDigit()
                    .foregroundStyle(theme.online)
            }
        }
    }

    /// One kind of token: its name over the count, a fifth of the row; the
    /// exact count on hover.
    private func usageFigure(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(theme.ui(12))
                .foregroundStyle(theme.secondaryText)
            Text(count.formatted(.number.notation(.compactName).locale(.chrome)))
                .font(theme.ui(20, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(count.formatted(.number.locale(.chrome)))
    }
}

/// An MCP server's fields, as both tools describe one: a command with its
/// arguments and environment, or a URL.
struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServer
    let onSave: (MCPServer) -> Void

    @State private var args: String
    @State private var env: String
    private let isNew: Bool

    init(server: MCPServer, onSave: @escaping (MCPServer) -> Void) {
        isNew = server.name.isEmpty
        _server = State(initialValue: server)
        _args = State(initialValue: server.args.joined(separator: "\n"))
        _env = State(initialValue: server.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !server.name.isEmpty && (!server.command.isEmpty || !server.url.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("github"))
                    TextField("Command", text: $server.command, prompt: Text("npx"))
                    TextField("Arguments", text: $args, prompt: Text("One per line"), axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Environment", text: $env, prompt: Text("KEY=value"),
                              axis: .vertical)
                        .lineLimit(2...6)
                    TextField("URL", text: $server.url)
                }
            }
            .formStyle(.grouped)
            // Not the rows of the Settings page this sheet opened from.
            .labeledContentStyle(.automatic)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var server = server
                    server.args = lines(args)
                    server.env = Dictionary(lines(env).compactMap { line -> (String, String)? in
                        guard let equals = line.firstIndex(of: "=") else { return nil }
                        return (String(line[..<equals]), String(line[line.index(after: equals)...]))
                    }, uniquingKeysWith: { _, last in last })
                    onSave(server)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 440, height: 380)
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
