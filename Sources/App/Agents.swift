import Core
import Foundation
import Observation
import SSH

/// The coding agents on this Mac, as the sidebar and their Settings pages
/// see them: the settings profiles each can switch between, its servers,
/// skills and sessions.
///
/// Everything here is read from the tools' own files under `home`, and
/// written straight back; a profile is a copy of those files. The file reads
/// run off the main thread -- listing sessions reads every transcript -- and
/// the results land here.
@MainActor
@Observable
final class Agents {
    /// One tool's state, as last read.
    struct Info {
        /// What the last update said, or that one is running.
        var updateNews: String?
        var isUpdating = false
        var profiles: [AgentProfile] = []
        /// What each profile's files say, by profile id, for its row.
        var summaries: [String: String] = [:]
        /// The profile the tool's files match; nil when they match none,
        /// which is to say they were edited since.
        var activeProfile: AgentProfile?
        var mcp: [MCPServer] = []
        var skills: [AgentSkill] = []
        var sessions: [AgentSession] = []
        var usage: TokenUsage { sessions.reduce(TokenUsage()) { $0 + $1.tokens } }
        /// What `--version` says; nil when the tool is not installed.
        var version: String?
        /// Nil until the tool has been asked, which takes a moment.
        var plugins: [AgentPlugin]?
        /// Claude Code only: the launcher, the newest version installed,
        /// and whether the launcher is kept a copy of it.
        var launcher: ClaudeLauncher.State?
        var latestVersion: String?
        var launcherCopy = false
        /// What a sync would send, one line each, and the last one made.
        var syncItems: [String] = []
        var lastSync: (server: String, date: Date)?
    }

    /// The switch that keeps the launcher a copy, in the store.
    static let launcherCopyKey = "claudeLauncherCopy"

    private(set) var info: [AgentTool: Info] = [:]
    let home: URL
    /// Where the profiles are kept; General's Data folder, or the test's own.
    var data: URL?
    private weak var model: AppModel?
    /// The directories Claude Code's updater writes, watched so the launcher
    /// copy follows an update while the app is running.
    private var watchers: [String: Task<Void, Never>] = [:]

    init(model: AppModel, home: URL, data: URL? = nil) {
        self.model = model
        self.home = home
        self.data = data
    }

    subscript(tool: AgentTool) -> Info { info[tool] ?? Info() }

    func paths(_ tool: AgentTool) -> AgentPaths { tool.paths(home: home, data: data) }

    // MARK: - reading

    /// Re-reads everything but the sessions. For Claude Code, also makes
    /// sure the launcher is what the switch says.
    /// Updates the tool in the background and says what came of it; the
    /// version shown follows. Claude Code's updater rewrites the launcher,
    /// which the launcher watcher then puts back as a copy if asked.
    func updateTool(_ tool: AgentTool) async {
        guard !self[tool].isUpdating else { return }
        info[tool, default: Info()].isUpdating = true
        info[tool, default: Info()].updateNews = nil
        let before = self[tool].version
        do {
            let said = try await AgentPlugin.updateTool(paths(tool))
            await refresh(tool)
            let after = self[tool].version
            info[tool, default: Info()].updateNews = after != before
                ? "Updated to \(after ?? "?")"
                : (said.split(separator: "\n").last.map(String.init) ?? "Up to date")
        } catch {
            info[tool, default: Info()].updateNews = String(describing: error)
        }
        info[tool, default: Info()].isUpdating = false
    }

    func refresh(_ tool: AgentTool) async {
        guard let model else { return }
        var current = self[tool]
        let paths = paths(tool)
        do {
            if tool == .claude {
                current.launcherCopy = try await model.store.setting(Self.launcherCopyKey) == "on"
                if current.launcherCopy { _ = try await AppModel.offMain { try ClaudeLauncher.keepCopy(paths) } }
                watchLauncher()
            }
            // The files are always some profile's: the one last put in place
            // takes an edit made since, and with none saved yet the files
            // become "Default". So there is never an unsaved state to show.
            let last = try await model.store.setting(Self.lastProfileKey(tool))
            let read = try await AppModel.offMain {
                var profiles = AgentProfile.list(paths)
                if AgentProfile.active(paths) == nil {
                    if let own = profiles.first(where: { $0.name == last }) {
                        try AgentProfile.update(own, from: paths)
                    } else if profiles.isEmpty {
                        try AgentProfile.save(named: "Default", from: paths)
                        profiles = AgentProfile.list(paths)
                    }
                }
                return (profiles: profiles,
                        summaries: Dictionary(uniqueKeysWithValues: profiles.map {
                            ($0.id, AgentProfile.summary($0, paths: paths)) }),
                        active: AgentProfile.active(paths), mcp: try Self.mcpServers(paths),
                        skills: AgentSkill.list(paths),
                        syncItems: try AgentSync.items(for: paths),
                        launcher: tool == .claude ? ClaudeLauncher.state(paths) : nil,
                        latest: tool == .claude ? ClaudeLauncher.latestVersion(paths) : nil)
            }
            current.profiles = read.profiles
            current.summaries = read.summaries
            current.activeProfile = read.active
            if let active = read.active, active.name != last {
                try await model.store.setSetting(Self.lastProfileKey(tool), to: active.name)
            }
            current.mcp = read.mcp
            current.skills = read.skills
            current.syncItems = read.syncItems
            current.launcher = read.launcher
            current.latestVersion = read.latest
            current.version = await AgentPlugin.version(paths)
        } catch {
            model.report(error)
        }
        info[tool] = current
    }

    /// Asks the tool for its plugins. Apart from `refresh` because it runs
    /// the tool, which takes a second or two.
    func refreshPlugins(_ tool: AgentTool) async {
        do { info[tool, default: Info()].plugins = try await AgentPlugin.list(paths(tool)) }
        catch { model?.report(error) }
    }

    /// Re-reads the sessions and their token totals. Apart from `refresh`
    /// because it reads every transcript, and a page opens more often than
    /// the list changes.
    func refreshSessions(_ tool: AgentTool) async {
        let paths = paths(tool)
        info[tool, default: Info()].sessions = await Task.detached { AgentSession.list(paths) }.value
    }

    // MARK: - profiles

    /// The profile last matching the files, whose they are until another is
    /// put in place.
    private static func lastProfileKey(_ tool: AgentTool) -> String { "agentProfile.\(tool.rawValue)" }

    func saveProfile(named name: String, for tool: AgentTool) async {
        await write(tool) { try AgentProfile.save(named: name, from: $0) }
    }

    func updateProfile(_ profile: AgentProfile, for tool: AgentTool) async {
        await write(tool) { try AgentProfile.update(profile, from: $0) }
    }

    /// Copies the profile's files over the tool's.
    func applyProfile(_ profile: AgentProfile, for tool: AgentTool) async {
        await write(tool) { try AgentProfile.apply(profile, to: $0) }
    }

    func renameProfile(_ profile: AgentProfile, to name: String, for tool: AgentTool) async {
        await write(tool) { _ in try AgentProfile.rename(profile, to: name) }
    }

    func deleteProfile(_ profile: AgentProfile, for tool: AgentTool) async {
        await write(tool) { _ in try AgentProfile.delete(profile) }
    }

    // MARK: - files

    func setMCP(_ servers: [MCPServer], for tool: AgentTool) async {
        info[tool, default: Info()].mcp = servers
        await write(tool) { try Self.setMCPServers(servers, paths: $0) }
    }

    /// Adds a server to the other tool's list, replacing one of the same name.
    func copyMCP(_ server: MCPServer, to tool: AgentTool) async {
        await write(tool) { paths in
            let others = try Self.mcpServers(paths).filter { $0.name != server.name }
            try Self.setMCPServers(others + [server], paths: paths)
        }
    }

    func removeSkill(_ skill: AgentSkill, from tool: AgentTool) async {
        await write(tool) { _ in try AgentSkill.remove(skill) }
    }

    /// A skill's directory copied in: from a folder picked, or from the
    /// other tool.
    func installSkill(from directory: URL, into tool: AgentTool) async {
        await write(tool) { try AgentSkill.install(from: directory, into: $0) }
    }

    // MARK: - syncing to a server

    /// Recreates the tool's setup under the server's home, over the same
    /// route a terminal takes, and notes when. A run that stops short is
    /// reported with what the script said last.
    func sync(_ tool: AgentTool, to server: Server) async {
        guard let model else { return }
        let paths = paths(tool)
        do {
            let commands = try await AppModel.offMain { AgentSync.commands(running: try AgentSync.script(for: paths)) }
            let session = try await model.connectedSession(to: server)
            var last: SSHSession.CommandResult?
            do {
                for command in commands {
                    last = try await session.exec(command)
                    if last?.exitStatus != 0 { break }
                }
            } catch {
                await session.disconnect()
                throw error
            }
            await session.disconnect()
            guard let last, last.exitStatus == 0, last.stdout.contains(AgentSync.doneMarker) else {
                let said = (last.map { $0.stderr + $0.stdout } ?? "").split(separator: "\n").last.map(String.init)
                throw Failure.syncStopped(server: server.name, said: said ?? "exit \(last?.exitStatus ?? 0)")
            }
            info[tool, default: Info()].lastSync = (server.name, Date())
        } catch {
            model.report(error)
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case syncStopped(server: String, said: String)

        var description: String {
            switch self {
            case .syncStopped(let server, let said): "The sync to \(server) stopped short: \(said)"
            }
        }
    }

    // MARK: - plugins

    /// Flips the switch in the tool's settings file, and the row with it, so
    /// the list need not be asked for again.
    func setPluginEnabled(_ enabled: Bool, _ plugin: AgentPlugin, for tool: AgentTool) async {
        if let index = info[tool]?.plugins?.firstIndex(of: plugin) {
            info[tool]?.plugins?[index].enabled = enabled
        }
        await write(tool) { try AgentPlugin.setEnabled(enabled, plugin, paths: $0) }
    }

    /// One edit to a tool's files, off the main thread, and the tool re-read.
    private func write(_ tool: AgentTool, _ edit: @escaping @Sendable (AgentPaths) throws -> Void) async {
        let paths = paths(tool)
        do { try await AppModel.offMain { try edit(paths) } }
        catch { model?.report(error) }
        await refresh(tool)
    }

    // MARK: - the launcher

    /// Switches the launcher between a copy named `claude` and the
    /// installer's symlink, and remembers which, so `refresh` keeps it so.
    func setLauncherCopy(_ on: Bool) async {
        // The switch reads this straight back; left as it was until the
        // re-read, it springs back and looks stuck.
        info[.claude, default: Info()].launcherCopy = on
        do { try await model?.store.setSetting(Self.launcherCopyKey, to: on ? "on" : "off") }
        catch { model?.report(error) }
        await write(.claude) { on ? try ClaudeLauncher.useCopy($0) : try ClaudeLauncher.restoreSymlink($0) }
    }

    /// Follows `~/.local/bin` and the versions directory: the updater writes
    /// the new binary into one and then moves the symlink in the other, so a
    /// change in either is answered with a re-read a second later, by which
    /// time both steps are done.
    private func watchLauncher() {
        let paths = paths(.claude)
        for directory in [paths.versions, paths.command.deletingLastPathComponent()]
        where watchers[directory.path] == nil {
            // A directory not there yet is tried again at the next refresh.
            guard let changes = DirectoryWatcher.changes(in: directory, settling: 1) else { continue }
            watchers[directory.path] = Task { [weak self] in
                for await _ in changes { await self?.refresh(.claude) }
            }
        }
    }

    // MARK: - sessions

    /// Removes the transcripts, and takes them off the list without reading
    /// every other one again.
    func deleteSessions(_ sessions: [AgentSession]) async {
        for session in sessions {
            let paths = paths(session.tool)
            do {
                try await AppModel.offMain { try AgentSession.delete(session, paths: paths) }
                info[session.tool, default: Info()].sessions.removeAll { $0.id == session.id }
            } catch {
                model?.report(error)
            }
        }
    }

    /// Picks a session up again in a new tab, in the directory it was in.
    func resume(_ session: AgentSession, in workspace: Workspace) {
        workspace.openLocal(title: String(session.title.prefix(30)), command: session.resumeCommand,
                            directory: session.cwd.isEmpty ? nil : session.cwd)
    }

    // MARK: - one API for two tools

    nonisolated static func mcpServers(_ paths: AgentPaths) throws -> [MCPServer] {
        switch paths.tool {
        case .claude: try ClaudeCodeConfig.mcpServers(paths)
        case .codex: try CodexConfig.mcpServers(paths)
        }
    }

    nonisolated static func setMCPServers(_ servers: [MCPServer], paths: AgentPaths) throws {
        switch paths.tool {
        case .claude: try ClaudeCodeConfig.setMCPServers(servers, paths: paths)
        case .codex: try CodexConfig.setMCPServers(servers, paths: paths)
        }
    }
}
