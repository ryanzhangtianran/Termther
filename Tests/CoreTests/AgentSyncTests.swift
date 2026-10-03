import Foundation
import Testing
@testable import Core

/// The sync script, run by `/bin/sh` against a second temporary home that
/// stands in for the server's.
struct AgentSyncTests {
    /// Runs the commands `exec` would run, in order, with `HOME` at `home`,
    /// and hands back what they printed.
    private func run(_ commands: [String], home: URL) throws -> (output: String, status: Int32) {
        var output = ""
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            output += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return (output, process.terminationStatus) }
        }
        return (output, 0)
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    @Test("a Claude home's settings, MCP servers, prompt and own skills come back byte for byte under another home")
    func claude() throws {
        let local = AgentPaths(.claude, home: try temporaryHome())
        let settings = "{\"env\": {\"ANTHROPIC_MODEL\": \"it's\"}, \"enabledPlugins\": {\"x@y\": true}}\n"
        try write(settings, to: local.settings)
        try write("# Be brief.\nDon't `echo \"$HOME\"`.\n", to: local.prompt)
        try write(#"{"numStartups": 3, "mcpServers": {"gh": {"command": "npx", "args": ["gh"]}}}"#,
                  to: local.mcpConfig)
        try write("---\nname: morning\n---\n# Morning\n", to: local.skills.appending(path: "morning/SKILL.md"))
        try write("notes", to: local.skills.appending(path: "morning/extra/notes.txt"))
        try write("---\nname: pdf\n---", to: local.skills.appending(path: "synced/abc/pdf/SKILL.md"))

        #expect(try AgentSync.items(for: local)
            == ["settings.json", "MCP servers (1) into ~/.claude.json", "CLAUDE.md", "Skills: morning"])
        let script = try AgentSync.script(for: local)
        #expect(script.contains(Data(settings.utf8).base64EncodedString()))
        #expect(script.contains(try bytes(local.prompt).base64EncodedString()))
        #expect(script.contains("rm -rf 'morning' "))
        #expect(!script.contains("pdf"))

        // The server already has a ~/.claude.json of its own, which keeps
        // what the sync does not speak of.
        let remote = AgentPaths(.claude, home: try temporaryHome())
        try write(#"{"numStartups": 7, "mcpServers": {"old": {}}}"#, to: remote.mcpConfig)
        let (output, status) = try run(AgentSync.commands(running: script), home: remote.home)
        #expect(status == 0, "\(output)")
        #expect(output.hasSuffix("\(AgentSync.doneMarker)\n"))
        #expect(output.contains("wrote \(remote.settings.path)\n"))
        #expect(try bytes(remote.settings) == bytes(local.settings))
        #expect(try bytes(remote.prompt) == bytes(local.prompt))
        #expect(try bytes(remote.skills.appending(path: "morning/extra/notes.txt")) == Data("notes".utf8))
        #expect(!FileManager.default.fileExists(atPath: remote.skills.appending(path: "synced").path))
        let merged = try JSONFile.read(remote.mcpConfig)
        #expect(merged["numStartups"] as? Int == 7)
        #expect((merged["mcpServers"] as? [String: Any])?.keys.sorted() == ["gh"])
        let mode = try FileManager.default.attributesOfItem(atPath: remote.settings.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!FileManager.default.fileExists(atPath: remote.home.appending(path: ".termther-sync").path))

        // Run again over a skill that has grown a file: the directory is
        // replaced, not merged.
        try write("stale", to: remote.skills.appending(path: "morning/old.txt"))
        #expect(try run(AgentSync.commands(running: script), home: remote.home).status == 0)
        #expect(!FileManager.default.fileExists(atPath: remote.skills.appending(path: "morning/old.txt").path))
    }

    @Test("a Codex home's config.toml, auth.json and AGENTS.md come back byte for byte, in more than one piece")
    func codex() throws {
        let local = AgentPaths(.codex, home: try temporaryHome())
        try write("model = \"gpt-6\"\n\n[mcp_servers.gh]\ncommand = \"npx\"\n", to: local.settings)
        try write("{\"OPENAI_API_KEY\": \"sk-'quoted'\"}", to: local.directory.appending(path: "auth.json"))
        // Big enough that the script goes over in more than one command.
        try write(String(repeating: "Be brief. ", count: 20_000), to: local.prompt)

        #expect(try AgentSync.items(for: local) == ["config.toml", "auth.json, with its key", "AGENTS.md"])
        let commands = AgentSync.commands(running: try AgentSync.script(for: local))
        #expect(commands.count > 2)

        let remote = AgentPaths(.codex, home: try temporaryHome())
        let (output, status) = try run(commands, home: remote.home)
        #expect(status == 0, "\(output)")
        #expect(output.hasSuffix("\(AgentSync.doneMarker)\n"))
        for name in ["config.toml", "auth.json", "AGENTS.md"] {
            #expect(try bytes(remote.directory.appending(path: name)) == bytes(local.directory.appending(path: name)))
        }
        #expect(!FileManager.default.fileExists(atPath: remote.skills.path))
    }

    @Test("a home with nothing in it has nothing to send, and the script still finishes")
    func empty() throws {
        let local = AgentPaths(.claude, home: try temporaryHome())
        #expect(try AgentSync.items(for: local) == [])
        let remote = try temporaryHome()
        let (output, status) = try run(AgentSync.commands(running: try AgentSync.script(for: local)), home: remote)
        #expect(status == 0, "\(output)")
        #expect(output == "\(AgentSync.doneMarker)\n")
    }
}
