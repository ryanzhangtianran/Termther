import Foundation

/// A saved copy of a tool's settings files, kept under
/// `~/.termther/agents/<tool>/<name>/`.
///
/// A profile is the part of the files that is its own: whatever the user's
/// editor left in `settings.json`, or in `config.toml` and `auth.json`, less
/// the parts every profile shares -- MCP servers, plugins, marketplaces,
/// permissions, hooks -- which live only in the tool's files and are kept as
/// they are when a profile is applied. So a plugin switched on under one
/// profile is on under them all. Which profile is active is not recorded
/// anywhere; it is the one whose files match the tool's own part, so an edit
/// made outside Termther simply shows as unsaved.
public struct AgentProfile: Identifiable, Equatable, Sendable {
    public var name: String
    public var directory: URL

    public var id: String { directory.path }

    public init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
    }

    public enum Failure: Error, CustomStringConvertible {
        case badName(String)
        case exists(String)

        public var description: String {
            switch self {
            case .badName(let name): "\u{201C}\(name)\u{201D} cannot name a profile."
            case .exists(let name): "A profile named \u{201C}\(name)\u{201D} already exists."
            }
        }
    }

    /// What a previous file is renamed to when a profile is applied over it.
    public static let backupSuffix = "termther-backup"

    /// What is the tool's rather than a profile's: in Claude Code's
    /// settings.json, these keys; in Codex's config.toml, these tables.
    public static let sharedKeys = ["enabledPlugins", "permissions", "hooks", "extraKnownMarketplaces"]
    public static let sharedTables = ["mcp_servers", "plugins", "marketplaces", "projects"]

    /// The profile's part of a file: what is there, less what is shared.
    /// Nil for no file.
    static func ownPart(of file: URL, named name: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        switch name {
        case "settings.json":
            var object = try JSONFile.object(data)
            for key in sharedKeys { object.removeValue(forKey: key) }
            return try JSONFile.data(object)
        case "config.toml":
            guard let text = String(data: data, encoding: .utf8) else { throw CodexConfig.Failure.notText(file) }
            var document = TOMLDocument(text: text)
            for table in sharedTables { document.removeTable([table]) }
            return Data(document.text.utf8)
        default:
            return data
        }
    }

    /// A profile's part of a file with the shared part of the tool's own
    /// file put back, which is what applying writes. Nil for no file.
    static func merged(_ own: Data?, withSharedOf live: URL, named name: String) throws -> Data? {
        guard let own else { return nil }
        let liveData = FileManager.default.fileExists(atPath: live.path) ? try Data(contentsOf: live) : nil
        switch name {
        case "settings.json":
            var object = try JSONFile.object(own)
            let current = try liveData.map(JSONFile.object) ?? [:]
            for key in sharedKeys { object[key] = current[key] }
            return try JSONFile.data(object)
        case "config.toml":
            guard let text = String(data: own, encoding: .utf8) else { throw CodexConfig.Failure.notText(live) }
            var document = TOMLDocument(text: text)
            for table in sharedTables { document.removeTable([table]) }
            let current = TOMLDocument(text: liveData.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            let shared = sharedTables.map { current.text(ofTable: [$0]) }.filter { !$0.isEmpty }
            var result = document.text.trimmingCharacters(in: .newlines)
            for block in shared { result += "\n\n" + block }
            return Data((result + "\n").utf8)
        default:
            return own
        }
    }

    /// Every profile of a tool, by name.
    public static func list(_ paths: AgentPaths) -> [AgentProfile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.profiles.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { AgentProfile(name: $0, directory: paths.profiles.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The tool's files as they are now, kept under `name`. Refuses a name
    /// already taken, so a save cannot silently replace another profile.
    @discardableResult
    public static func save(named name: String, from paths: AgentPaths) throws -> AgentProfile {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw Failure.badName(name) }
        let profile = AgentProfile(name: name, directory: paths.profiles.appending(path: name, directoryHint: .isDirectory))
        guard !FileManager.default.fileExists(atPath: profile.directory.path) else { throw Failure.exists(name) }
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try update(profile, from: paths)
        return profile
    }

    /// Overwrites the profile with its part of the tool's files as they are
    /// now. A file the tool no longer has leaves the profile too, so the two
    /// stay equal.
    public static func update(_ profile: AgentProfile, from paths: AgentPaths) throws {
        for name in paths.profileFiles {
            try put(try ownPart(of: paths.directory.appending(path: name), named: name),
                    at: profile.directory.appending(path: name))
        }
    }

    /// Writes the profile's files over the tool's, the shared parts of the
    /// tool's kept, each replaced in one step with the previous one beside it
    /// as `<file>.termther-backup`.
    public static func apply(_ profile: AgentProfile, to paths: AgentPaths) throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        for name in paths.profileFiles {
            let live = paths.directory.appending(path: name)
            let own = FileManager.default.fileExists(atPath: profile.directory.appending(path: name).path)
                ? try Data(contentsOf: profile.directory.appending(path: name)) : nil
            try put(try merged(own, withSharedOf: live, named: name), at: live,
                    backup: paths.directory.appending(path: "\(name).\(backupSuffix)"))
        }
    }

    public static func delete(_ profile: AgentProfile) throws {
        try FileManager.default.removeItem(at: profile.directory)
    }

    @discardableResult
    public static func rename(_ profile: AgentProfile, to name: String) throws -> AgentProfile {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw Failure.badName(name) }
        let target = profile.directory.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        guard name == profile.name || !FileManager.default.fileExists(atPath: target.path) else {
            throw Failure.exists(name)
        }
        try FileManager.default.moveItem(at: profile.directory, to: target)
        return AgentProfile(name: name, directory: target)
    }

    /// The profile whose files are the tool's own part, byte for byte; nil
    /// when that matches none, which is to say the files were edited since.
    public static func active(_ paths: AgentPaths) -> AgentProfile? {
        let current = paths.profileFiles.map { name in
            try? ownPart(of: paths.directory.appending(path: name), named: name)
        }
        return list(paths).first { profile in
            paths.profileFiles.indices.allSatisfy { index in
                current[index] == (try? Data(contentsOf: profile.directory.appending(path: paths.profileFiles[index])))
            }
        }
    }

    /// One line saying what a profile holds, for a list: its files, and the
    /// model and endpoint they name when they name one.
    public static func summary(_ profile: AgentProfile, paths: AgentPaths) -> String {
        var parts = [paths.profileFiles.joined(separator: " + ")]
        switch paths.tool {
        case .claude:
            let env = (try? JSONFile.read(profile.directory.appending(path: "settings.json")))?["env"] as? [String: Any]
            parts += [env?["ANTHROPIC_MODEL"] as? String, env?["ANTHROPIC_BASE_URL"] as? String].compactMap { $0 }
        case .codex:
            let text = try? String(contentsOf: profile.directory.appending(path: "config.toml"), encoding: .utf8)
            let document = TOMLDocument(text: text ?? "")
            parts += [document.value("model", in: [])?.string, document.value("model_provider", in: [])?.string]
                .compactMap { $0 }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// `data` put in place of `target` in one `rename`, staged beside it
    /// first; nil removes `target`. With `backup`, the previous `target`
    /// survives under that name.
    private static func put(_ data: Data?, at target: URL, backup: URL? = nil) throws {
        let manager = FileManager.default
        if let backup {
            try? manager.removeItem(at: backup)
            if manager.fileExists(atPath: target.path) { try manager.linkItem(at: target, to: backup) }
        }
        guard let data else { try? manager.removeItem(at: target); return }
        let staged = target.appendingPathExtension("termther-tmp")
        try data.write(to: staged)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        _ = try manager.replaceItemAt(target, withItemAt: staged)
    }
}
