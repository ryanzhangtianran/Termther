import Foundation
import os

/// A plugin, as the tool's own `plugin list --json` describes one.
///
/// Both tools name a plugin `name@marketplace` on the command line, and both
/// keep whether it is on in their settings file. Installing, removing and
/// updating one is left to the tool: those commands fetch, and may ask, so
/// they are run in a tab where the user can see them. Only the switch is
/// edited here, in place.
public struct AgentPlugin: Identifiable, Equatable, Sendable {
    /// `name@marketplace`.
    public var id: String
    public var name: String
    public var marketplace: String
    public var version: String
    public var enabled: Bool
    public var installPath: URL?

    public enum Failure: Error, CustomStringConvertible {
        case notInstalled(AgentTool)
        case timedOut(AgentTool, seconds: Int)
        case failed(AgentTool, String)
        case unexpected(AgentTool)

        public var description: String {
            switch self {
            case .notInstalled(let tool): "\(tool.title) is not installed at ~/.local/bin/\(tool.command)"
            case .timedOut(let tool, let seconds): "\(tool.command) did not answer within \(seconds) seconds"
            case .failed(let tool, let message): "\(tool.command) plugin list failed: \(message)"
            case .unexpected(let tool): "\(tool.command) plugin list did not print the JSON expected"
            }
        }
    }

    // MARK: - listing

    /// Asks the tool, which is the only thing that knows every marketplace.
    public static func list(_ paths: AgentPaths) async throws -> [AgentPlugin] {
        // Codex refreshes every remote marketplace before it answers, one
        // after another: 40 seconds and more has been seen.
        try parse(try await run(paths, ["plugin", "list", "--json"], within: 90), tool: paths.tool)
    }

    /// Claude Code prints an array of `{id, version, enabled, installPath}`;
    /// Codex prints `{installed: [{pluginId, name, marketplaceName, version,
    /// enabled, source: {path}}]}`. By id.
    public static func parse(_ json: Data, tool: AgentTool) throws -> [AgentPlugin] {
        guard let object = try? JSONSerialization.jsonObject(with: json) else { throw Failure.unexpected(tool) }
        let entries = switch tool {
        case .claude: object as? [[String: Any]] ?? []
        case .codex: (object as? [String: Any])?["installed"] as? [[String: Any]] ?? []
        }
        return entries.compactMap { entry -> AgentPlugin? in
            guard let id = entry[tool == .claude ? "id" : "pluginId"] as? String else { return nil }
            let at = id.firstIndex(of: "@")
            let path = tool == .claude ? entry["installPath"] : (entry["source"] as? [String: Any])?["path"]
            return AgentPlugin(
                id: id,
                name: entry["name"] as? String ?? at.map { String(id[..<$0]) } ?? id,
                marketplace: entry["marketplaceName"] as? String ?? at.map { String(id[id.index(after: $0)...]) } ?? "",
                version: entry["version"] as? String ?? "",
                enabled: entry["enabled"] as? Bool ?? true,
                installPath: (path as? String).map { URL(fileURLWithPath: $0, isDirectory: true) })
        }.sorted { $0.id < $1.id }
    }

    /// The tool's version, or nil when it is not there or will not say.
    public static func version(_ paths: AgentPaths) async -> String? {
        guard let data = try? await run(paths, ["--version"]) else { return nil }
        return versionNumber(in: String(decoding: data, as: UTF8.self))
    }

    /// `2.1.285 (Claude Code)` and `codex-cli 0.157.1` both hold one number.
    static func versionNumber(in text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }.map(String.init)
    }

    // MARK: - the switch

    /// Claude Code keeps `enabledPlugins: {id: bool}` in `settings.json`;
    /// Codex keeps `[plugins."id"]` with `enabled` in `config.toml`. Only
    /// that key moves.
    public static func setEnabled(_ enabled: Bool, _ plugin: AgentPlugin, paths: AgentPaths) throws {
        switch paths.tool {
        case .claude:
            var settings = try JSONFile.read(paths.settings)
            var plugins = settings["enabledPlugins"] as? [String: Any] ?? [:]
            plugins[plugin.id] = enabled
            settings["enabledPlugins"] = plugins
            try JSONFile.write(settings, to: paths.settings)
        case .codex:
            var document = TOMLDocument(text: try CodexConfig.read(paths.settings))
            document.set("enabled", to: .bool(enabled), in: ["plugins", plugin.id])
            try CodexConfig.write(document.text, to: paths.settings)
        }
    }

    // MARK: - what to type

    /// The rest go through the tool in a terminal: they fetch, print, and
    /// sometimes ask.
    public static func installCommand(id: String, tool: AgentTool) -> String {
        "\(tool.command) plugin \(tool == .claude ? "install" : "add") \(id)"
    }

    public static func uninstallCommand(id: String, tool: AgentTool) -> String {
        "\(tool.command) plugin \(tool == .claude ? "uninstall" : "remove") \(id)"
    }

    /// Codex has no update: its marketplaces are refreshed, and adding the
    /// plugin again takes the newest.
    public static func updateCommand(id: String, tool: AgentTool) -> String {
        switch tool {
        case .claude: "claude plugin update \(id)"
        case .codex: "codex plugin marketplace upgrade && codex plugin add \(id)"
        }
    }

    // MARK: - running the tool

    /// Updates the tool itself, quietly: `claude update` / `codex update`,
    /// given up to three minutes, since it downloads. What it printed comes
    /// back, for one line of news.
    public static func updateTool(_ paths: AgentPaths) async throws -> String {
        let data = try await run(paths, ["update"], within: 180)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Who the tool is signed in as with its own account, in a few words --
    /// "me@example.com · Max", "ChatGPT", "API key" -- or nil when it is not.
    public static func account(_ paths: AgentPaths) async throws -> String? {
        switch paths.tool {
        case .claude:
            let object = try JSONFile.object(try await run(paths, ["auth", "status"]))
            guard object["loggedIn"] as? Bool == true else { return nil }
            return [object["email"] as? String, (object["subscriptionType"] as? String)?.capitalized]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
        case .codex:
            // Said on standard error: "Logged in using ChatGPT", or "... using
            // an API key - sk-…", or "Not logged in" with a failing status.
            let said = String(decoding: try await run(paths, ["login", "status"], errorsAsOutput: true),
                              as: UTF8.self)
            return account(fromCodexStatus: said)
        }
    }

    static func account(fromCodexStatus said: String) -> String? {
        let prefix = "Logged in using "
        guard let line = said.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let how = line.dropFirst(prefix.count).split(separator: " - ").first.map(String.init) ?? ""
        return how == "an API key" ? "API key" : how
    }

    /// Signs the tool in with its own account: both open the browser and
    /// wait, on a port of their own, for it to come back. Ten minutes to
    /// finish in; cancelling the task ends the wait.
    public static func login(_ paths: AgentPaths) async throws {
        _ = try await run(paths, paths.tool == .claude ? ["auth", "login"] : ["login"], within: 600)
    }

    /// Runs the tool with `arguments` under `paths.home` and returns what it
    /// printed, within `seconds`. Its launcher is a script that looks for
    /// itself on the PATH, so `~/.local/bin` is put there.
    private static func run(_ paths: AgentPaths, _ arguments: [String],
                            within seconds: Double = 20, errorsAsOutput: Bool = false) async throws -> Data {
        let command = paths.command
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw Failure.notInstalled(paths.tool)
        }
        // The child's pid, for a cancellation that arrives while it runs:
        // the detached task below is blocked reading it and cannot notice.
        let running = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let process = Process()
                process.executableURL = command
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                // Through the system proxy, Surge's when it is set as one:
                // the tool reads only the variables, and an app opened from
                // Finder has none.
                environment.merge(ProxyEnvironment.system) { _, system in system }
                environment["HOME"] = paths.home.path
                environment["PATH"] = command.deletingLastPathComponent().path + ":"
                    + (environment["PATH"] ?? "/usr/bin:/bin")
                process.environment = environment
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                try process.run()
                // The pid alone is captured: a `Process` is not Sendable.
                let pid = process.processIdentifier
                running.withLock { $0 = pid }
                let timer = DispatchWorkItem { kill(pid, SIGTERM) }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                timer.cancel()
                if errorsAsOutput, process.terminationReason == .exit { return data + errorData }
                if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
                    throw Failure.timedOut(paths.tool, seconds: Int(seconds))
                }
                guard process.terminationStatus == 0 else {
                    throw Failure.failed(paths.tool, message.isEmpty ? "exit \(process.terminationStatus)" : message)
                }
                return data
            }.value
        } onCancel: {
            if let pid = running.withLock({ $0 }) { kill(pid, SIGTERM) }
        }
    }
}
