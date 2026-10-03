import Foundation

/// Codex's `config.toml`, as far as its MCP servers go.
///
/// The rest of it, and `auth.json`, are not interpreted here: a profile
/// keeps them whole, and the user edits them in an editor.
public enum CodexConfig {
    public enum Failure: Error, CustomStringConvertible {
        case notText(URL)

        public var description: String {
            switch self {
            case .notText(let url): "\(url.path) is not UTF-8 text, so Termther leaves it alone."
            }
        }
    }

    // MARK: - MCP servers

    public static func mcpServers(_ paths: AgentPaths) throws -> [MCPServer] {
        let document = TOMLDocument(text: try read(paths.settings))
        return document.tables(under: ["mcp_servers"]).filter { $0.count == 2 }.map { table in
            let env = document.tables(under: table).first { $0.count == 3 && $0[2] == "env" }
            return MCPServer(
                name: table[1],
                command: document.value("command", in: table)?.string ?? "",
                args: document.value("args", in: table)?.strings ?? [],
                env: env.map { environment(in: $0, of: document) } ?? [:],
                url: document.value("url", in: table)?.string ?? "",
                enabled: document.value("enabled", in: table)?.bool ?? true)
        }
    }

    /// Makes `config.toml` list exactly these servers. A server already there
    /// keeps its table, and any keys in it this app does not know; one no
    /// longer in the list loses its table.
    public static func setMCPServers(_ servers: [MCPServer], paths: AgentPaths) throws {
        var document = TOMLDocument(text: try read(paths.settings))
        let names = Set(servers.map(\.name))
        for table in document.tables(under: ["mcp_servers"]) where table.count == 2 && !names.contains(table[1]) {
            document.removeTable(table)
        }
        for server in servers {
            let table = ["mcp_servers", server.name]
            document.set("command", to: server.command.isEmpty ? nil : .string(server.command), in: table)
            document.set("args", to: server.command.isEmpty ? nil : .array(server.args.map(TOMLDocument.Value.string)),
                         in: table)
            document.set("url", to: server.url.isEmpty ? nil : .string(server.url), in: table)
            document.set("enabled", to: server.enabled ? nil : .bool(false), in: table)
            let env = table + ["env"]
            if server.env.isEmpty {
                document.removeTable(env)
            } else {
                for key in environment(in: env, of: document).keys where server.env[key] == nil {
                    document.set(key, to: nil, in: env)
                }
                for (key, value) in server.env.sorted(by: { $0.key < $1.key }) {
                    document.set(key, to: .string(value), in: env)
                }
            }
        }
        try write(document.text, to: paths.settings)
    }

    private static func environment(in table: [String], of document: TOMLDocument) -> [String: String] {
        var env: [String: String] = [:]
        for key in document.keys(in: table) {
            // Only strings: a process's environment is strings, and anything
            // else here is something Codex itself would refuse.
            env[key] = document.value(key, in: table)?.string
        }
        return env
    }

    // MARK: - files

    /// The file's text, "" when there is none yet.
    static func read(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8)
        else { throw Failure.notText(url) }
        return text
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
