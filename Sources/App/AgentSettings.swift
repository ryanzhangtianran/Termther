import AppKit
import Core
import SwiftUI

/// One coding agent's page in Settings: its settings profiles, MCP
/// servers, prompt file and skills, and the sessions it has left behind.
///
/// Everything is read from and written to the tool's own files through
/// `Agents`; the only thing in the store is the launcher switch.
struct AgentSettings: View {
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    @Bindable var model: AppModel
    let workspace: Workspace

    @State private var editingServer: Editing<MCPServer>?
    @State private var installingPlugin = false
    @State private var confirmingUninstall: AgentPlugin?
    @State private var syncServerID: Int64?
    @State private var syncing = false

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
        mcpSection
        pluginsSection
        promptSection
        syncSection
        skillsSection
        usageSection
        AgentSessionsView(tool: tool, agents: agents, workspace: workspace)
    }

    // MARK: - the tool

    /// The tool itself: its version, its updater, and for Claude Code the
    /// launcher switch -- on, `~/.local/bin/claude` is a copy of the current
    /// version named `claude`, and is kept one as versions come and go.
    private var toolSection: some View {
        Section(tool.title) {
            LabeledContent("Version") {
                HStack(spacing: 10) {
                    if let news = info.updateNews {
                        Text(news)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(info.version ?? "Not installed")
                        .foregroundStyle(theme.secondaryText)
                    if info.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check for Updates") { Task { await agents.updateTool(tool) } }
                            .disabled(info.version == nil)
                    }
                }
            }
            if tool == .claude {
                Toggle("Show process as claude",
                       isOn: Binding(get: { info.launcherCopy },
                                     set: { on in Task { await agents.setLauncherCopy(on) } }))
                .disabled(info.latestVersion == nil)
            }
        }
    }

    // MARK: - MCP servers

    private var mcpSection: some View {
        Section {
            ForEach(info.mcp) { server in
                Toggle(isOn: Binding(
                    get: { server.enabled },
                    set: { on in
                        var servers = info.mcp
                        if let index = servers.firstIndex(where: { $0.name == server.name }) {
                            servers[index].enabled = on
                        }
                        Task { await agents.setMCP(servers, for: tool) }
                    })) {
                    Text(server.name)
                        .help(server.url.isEmpty
                              ? ([server.command] + server.args).joined(separator: " ") : server.url)
                }
                .help(tool == .claude ? "Off removes it from ~/.claude.json"
                                      : "Off disables it in config.toml")
                .contextMenu {
                    Button("Edit\u{2026}") { editingServer = Editing(value: server) }
                    Button("Copy to \(other.title)") { Task { await agents.copyMCP(server, to: other) } }
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task { await agents.setMCP(info.mcp.filter { $0.name != server.name }, for: tool) }
                    }
                }
            }
            if info.mcp.isEmpty {
                Text("No MCP servers")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("MCP Servers")
                Spacer()
                Button { editingServer = Editing(value: MCPServer(name: "")) } label: {
                    Image(systemName: "plus").font(.headerPlus)
                }
                .buttonStyle(.plain)
                .help("Add Server")
            }
        }
        .task {
            await agents.refresh(tool)
            await agents.refreshSessions(tool)
            await agents.refreshPlugins(tool)
        }
        .sheet(item: $editingServer) { editing in
            MCPServerEditor(server: editing.value) { server in
                var servers = info.mcp.filter { $0.name != editing.value.name && $0.name != server.name }
                servers.append(server)
                Task { await agents.setMCP(servers, for: tool) }
            }
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
                    Button("Uninstall\u{2026}", role: .destructive) { confirmingUninstall = plugin }
                }
            }
            if let plugins = info.plugins, plugins.isEmpty {
                Text("No plugins")
                    .foregroundStyle(theme.secondaryText)
            } else if info.plugins == nil {
                Text("Loading\u{2026}")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Plugins")
                Spacer()
                Button { installingPlugin = true } label: { Image(systemName: "plus").font(.headerPlus) }
                    .buttonStyle(.plain)
                    .help("Install\u{2026}")
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

    /// The file the agent reads before every session, edited in vim in a
    /// tab of its own, as `~/.ssh/config` is.
    private var promptSection: some View {
        let file = agents.paths(tool).prompt
        return Section(file.lastPathComponent) {
            LabeledContent((file.path as NSString).abbreviatingWithTildeInPath) {
                Button("Edit") {
                    workspace.openLocal(title: file.lastPathComponent,
                                        command: "vim \(shellQuoted(file.path))", directory: nil)
                }
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
                    .disabled(syncing || model.servers.isEmpty || info.syncItems.isEmpty)
                }
            }
            ForEach(info.syncItems, id: \.self) { item in
                Text(item)
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
            }
            if info.syncItems.isEmpty {
                Text("Nothing to sync")
                    .foregroundStyle(theme.secondaryText)
            }
            if let last = info.lastSync {
                Text("Last synced to \(last.server), \(last.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            Text("Sync to Server")
        }
    }

    // MARK: - skills

    /// The user's own: a plugin's or a synced one is the plugin's business.
    private var ownSkills: [AgentSkill] { info.skills.filter(\.isOwn) }

    private var skillsSection: some View {
        Section {
            ForEach(ownSkills) { skill in
                // One line: the name and what it is for.
                HStack(spacing: 10) {
                    Text(skill.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(skill.description)
                        .font(theme.ui(12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
                Button(action: installSkill) { Image(systemName: "plus").font(.headerPlus) }
                    .buttonStyle(.plain)
                    .help("Install\u{2026}")
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

    private var usageSection: some View {
        Section("Usage") {
            LabeledContent("Input", value: info.usage.input.formatted())
            LabeledContent("Output", value: info.usage.output.formatted())
            LabeledContent("Cache read", value: info.usage.cacheRead.formatted())
            LabeledContent("Cache write", value: info.usage.cacheWrite.formatted())
            LabeledContent("Total tokens", value: info.usage.total.formatted())
        }
    }
}

/// An MCP server's fields, as both tools describe one: a command with its
/// arguments and environment, or a URL.
private struct MCPServerEditor: View {
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
