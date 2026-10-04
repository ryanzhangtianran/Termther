import Foundation

/// A skill: a directory with a `SKILL.md` whose front matter names and
/// describes it. Both tools use the same layout, which is what makes copying
/// one across a plain directory copy.
public struct AgentSkill: Identifiable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// The skill's directory.
    public var path: URL
    /// Where it came from, when not put under `skills/` by hand: a plugin's
    /// name, "synced" for Claude's synced set, "system" for Codex's own. Those
    /// are the tool's to update and remove, so `isOwn` is false for them.
    public var source: String?

    public var id: String { path.path }
    public var isOwn: Bool { source == nil }

    /// Every skill a tool can see: under `skills/`, at any depth, and in each
    /// installed plugin's `skills/`. By name, the user's own first.
    public static func list(_ paths: AgentPaths) -> [AgentSkill] {
        // Symlinks resolved on both, as the walk may hand back either form.
        let root = paths.skills.resolvingSymlinksInPath().pathComponents
        var skills = found(under: paths.skills) { directory in
            // The first path component under skills/ says whose it is.
            let top = directory.resolvingSymlinksInPath().pathComponents.dropFirst(root.count).first
            if top == "synced" { return "synced" }
            if top == ".system" { return "system" }
            return nil
        }
        for (name, directory) in plugins(paths) {
            skills += found(under: directory.appending(path: "skills", directoryHint: .isDirectory)) { _ in name }
        }
        return skills.sorted {
            ($0.isOwn ? 0 : 1, $0.name.lowercased()) < ($1.isOwn ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Each directory under `root` holding a `SKILL.md`, hidden ones aside
    /// (Codex's `.system` and Claude's `.openclaw` copies excepted only via
    /// `source`).
    private static func found(under root: URL, source: (URL) -> String?) -> [AgentSkill] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsPackageDescendants]) else { return [] }
        var skills: [AgentSkill] = []
        for case let file as URL in walker where file.lastPathComponent == "SKILL.md" {
            let directory = file.deletingLastPathComponent()
            // A skill's own subfolders are not more skills.
            walker.skipDescendants()
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let front = frontMatter(text)
            skills.append(AgentSkill(name: front["name"] ?? directory.lastPathComponent,
                                     description: front["description"] ?? "",
                                     path: directory, source: source(directory)))
        }
        return skills
    }

    /// The installed plugins, by name, with the directory each is unpacked in.
    /// Claude Code lists them in `plugins/installed_plugins.json`; Codex keeps
    /// them under `plugins/cache/<marketplace>/<plugin>/<version>`.
    static func plugins(_ paths: AgentPaths) -> [(name: String, directory: URL)] {
        let manager = FileManager.default
        let root = paths.directory.appending(path: "plugins", directoryHint: .isDirectory)
        switch paths.tool {
        case .claude:
            guard let data = try? Data(contentsOf: root.appending(path: "installed_plugins.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plugins = json["plugins"] as? [String: [[String: Any]]] else { return [] }
            return plugins.sorted { $0.key < $1.key }.compactMap { name, installs in
                installs.first?["installPath"].flatMap { $0 as? String }
                    .map { (name, URL(fileURLWithPath: $0, isDirectory: true)) }
            }
        case .codex:
            let cache = root.appending(path: "cache", directoryHint: .isDirectory)
            let places = (try? manager.contentsOfDirectory(atPath: cache.path)) ?? []
            return places.sorted().flatMap { place -> [(String, URL)] in
                let market = cache.appending(path: place, directoryHint: .isDirectory)
                let names = (try? manager.contentsOfDirectory(atPath: market.path)) ?? []
                return names.sorted().compactMap { name in
                    let plugin = market.appending(path: name, directoryHint: .isDirectory)
                    let versions = ((try? manager.contentsOfDirectory(atPath: plugin.path)) ?? [])
                        .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                    return versions.last.map { ("\(name)@\(place)", plugin.appending(path: $0, directoryHint: .isDirectory)) }
                }
            }
        }
    }

    /// Only the user's own: a plugin's or the tool's would come back.
    public static func remove(_ skill: AgentSkill) throws {
        guard skill.isOwn else { throw Failure.notOwn(skill.name) }
        try FileManager.default.removeItem(at: skill.path)
    }

    public enum Failure: Error, CustomStringConvertible {
        case notOwn(String)
        public var description: String {
            switch self {
            case .notOwn(let name): "\(name) belongs to a plugin or the tool itself, and is theirs to remove"
            }
        }
    }

    /// Copies a skill's directory in, under its own name -- from a folder, or
    /// from the other tool's `skills/`. Refuses to replace one already there.
    public static func install(from directory: URL, into paths: AgentPaths) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        try manager.copyItem(at: directory,
                             to: paths.skills.appending(path: directory.lastPathComponent, directoryHint: .isDirectory))
    }

    /// The `key: value` lines between the `---` fences at the top of a file,
    /// with surrounding quotes taken off. Enough YAML for a name and a
    /// description; a multi-line value comes back as its first line.
    static func frontMatter(_ text: String) -> [String: String] {
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()
        var fields: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                // Inside double quotes, a quote or a backslash is written escaped.
                if first == "\"" {
                    value = value.replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
            }
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }
}
