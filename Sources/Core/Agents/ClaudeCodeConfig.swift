import Foundation

/// Claude Code's `~/.claude.json`, where its MCP servers are declared.
///
/// Its `settings.json` is not interpreted here: a profile keeps it whole, and
/// the user edits it in an editor.
public enum ClaudeCodeConfig {
    // MARK: - MCP servers

    public static func mcpServers(_ paths: AgentPaths) throws -> [MCPServer] {
        let servers = try JSONFile.read(paths.mcpConfig)["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            return MCPServer(
                name: name,
                command: entry["command"] as? String ?? "",
                args: entry["args"] as? [String] ?? [],
                env: entry["env"] as? [String: String] ?? [:],
                url: entry["url"] as? String ?? "")
        }
    }

    /// Makes `~/.claude.json` list exactly these servers, minus the disabled
    /// ones -- Claude Code has no way to keep a server without running it. A
    /// server already there keeps the keys this app does not know, `headers`
    /// and an `sse` type among them.
    public static func setMCPServers(_ servers: [MCPServer], paths: AgentPaths) throws {
        var config = try JSONFile.read(paths.mcpConfig)
        let existing = config["mcpServers"] as? [String: Any] ?? [:]
        var written: [String: Any] = [:]
        for server in servers where server.enabled {
            var entry = existing[server.name] as? [String: Any] ?? [:]
            if server.url.isEmpty {
                entry["command"] = server.command
                entry["args"] = server.args
                entry["env"] = server.env
                entry.removeValue(forKey: "url")
                entry.removeValue(forKey: "type")
            } else {
                entry["url"] = server.url
                if entry["type"] == nil { entry["type"] = "http" }
                for key in ["command", "args", "env"] { entry.removeValue(forKey: key) }
            }
            written[server.name] = entry
        }
        config["mcpServers"] = written
        try JSONFile.write(config, to: paths.mcpConfig)
    }
}
