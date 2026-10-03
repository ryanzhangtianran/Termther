import Foundation
import Testing
@testable import Core

/// Editing the tools' own files.
///
/// The Codex tests compare whole files: the promise is that nothing outside
/// the edited lines moves, and only the full text can show that.
struct AgentConfigTests {
    /// A `config.toml` with everything an editor must not disturb.
    let sample = """
    model_provider = "OpenAI"
    model = "gpt-6-sol"
    review_model = "gpt-5.6-sol"  # trailing comment
    disable_response_storage = true

    notify = ["/Applications/Some App.app/Contents/MacOS/notify", "turn-ended"]
    model_reasoning_effort = "none"

    [model_providers.OpenAI]
    name = "OpenAI"
    base_url = "http://172.16.10.253:8080"
    wire_api = "responses"
    requires_openai_auth = true

    [plugins."browser@openai-bundled"]
    enabled = true

    [mcp_servers]

    [mcp_servers.computer-use]
    type = "stdio"
    command = "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"
    args = ["mcp"]
    cwd = "."
    enabled = false

    [mcp_servers.node_repl]
    args = []
    command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
    startup_timeout_sec = 120

    [mcp_servers.node_repl.env]
    NODE_REPL_NODE_PATH = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
    NODE_REPL_TRUSTED_SERVICES = '{"browser":"/x/browser-service.mjs","sky":"@oai/sky/service"}'

    [hooks.state."ponytail@ponytail:hooks/claude-codex-hooks.json:session_start:0:0"]
    trusted_hash = "sha256:5f81d38f47448a1581c08ec877e044d9e04dd6f814dce3f2671f7a8edadd719b"

    """

    @Test("an untouched TOML document writes back exactly what it read")
    func tomlRoundTrip() {
        let document = TOMLDocument(text: sample)
        #expect(document.text == sample)
        #expect(document.value("model", in: [])?.string == "gpt-6-sol")
        #expect(document.value("review_model", in: [])?.string == "gpt-5.6-sol")
        #expect(document.value("notify", in: [])?.strings
                == ["/Applications/Some App.app/Contents/MacOS/notify", "turn-ended"])
        #expect(document.value("requires_openai_auth", in: ["model_providers", "OpenAI"])?.bool == true)
        #expect(document.value("startup_timeout_sec", in: ["mcp_servers", "node_repl"]) == .integer(120))
        #expect(document.value("enabled", in: ["plugins", "browser@openai-bundled"])?.bool == true)
        #expect(document.tables(under: ["mcp_servers"])
                == [["mcp_servers", "computer-use"], ["mcp_servers", "node_repl"],
                    ["mcp_servers", "node_repl", "env"]])
    }

    @Test("setting a value rewrites its line alone, and setting the same value rewrites nothing")
    func tomlSet() {
        var document = TOMLDocument(text: sample)
        document.set("model", to: .string("gpt-6-sol"), in: [])
        document.set("args", to: .array([.string("mcp")]), in: ["mcp_servers", "computer-use"])
        #expect(document.text == sample)

        document.set("review_model", to: .string("o5"), in: [])
        document.set("cwd", to: nil, in: ["mcp_servers", "computer-use"])
        document.set("startup_timeout_sec", to: .integer(30), in: ["mcp_servers", "node_repl"])
        #expect(document.text == sample
            .replacingOccurrences(of: "review_model = \"gpt-5.6-sol\"  # trailing comment",
                                  with: "review_model = \"o5\"")
            .replacingOccurrences(of: "cwd = \".\"\n", with: "")
            .replacingOccurrences(of: "startup_timeout_sec = 120", with: "startup_timeout_sec = 30"))
    }

    @Test("a string with quotes and a key with a dot survive being written and read back")
    func tomlEscapes() {
        var document = TOMLDocument(text: "")
        document.set("a", to: .string("say \"hi\"\\\n"), in: ["mcp_servers", "my.server", "env"])
        let again = TOMLDocument(text: document.text)
        #expect(again.value("a", in: ["mcp_servers", "my.server", "env"])?.string == "say \"hi\"\\\n")
        #expect(document.text == "[mcp_servers.\"my.server\".env]\na = \"say \\\"hi\\\"\\\\\\n\"\n")
    }

    private func codex() throws -> AgentPaths {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        try write(sample, to: paths.settings)
        try write("{\"OPENAI_API_KEY\": \"sk-old\", \"tokens\": {\"id_token\": \"x\"}}",
                  to: paths.directory.appending(path: "auth.json"))
        return paths
    }

    @Test("a profile is its part of the files as saved, recognised as active while they still match")
    func profiles() throws {
        let paths = try codex()
        #expect(AgentProfile.list(paths).isEmpty)
        #expect(AgentProfile.active(paths) == nil)

        let work = try AgentProfile.save(named: "Work", from: paths)
        #expect(AgentProfile.active(paths) == work)
        // Its own part: the provider and the rest, not the plugins or servers.
        let saved = try String(contentsOf: work.directory.appending(path: "config.toml"), encoding: .utf8)
        #expect(saved.contains("[model_providers.OpenAI]"))
        #expect(!saved.contains("[plugins.") && !saved.contains("[mcp_servers"))
        let attributes = try FileManager.default.attributesOfItem(atPath: work.directory.path)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o700)
        let auth = try FileManager.default.attributesOfItem(atPath: work.directory.appending(path: "auth.json").path)
        #expect((auth[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)

        // An edit outside Termther matches nothing until it is saved.
        try write(sample + "profile = \"fast\"\n", to: paths.settings)
        #expect(AgentProfile.active(paths) == nil)
        let fast = try AgentProfile.save(named: "Fast", from: paths)
        #expect(AgentProfile.list(paths) == [fast, work])
        #expect(AgentProfile.active(paths) == fast)

        // Applying the other puts its part back, and keeps what it replaced.
        try AgentProfile.apply(work, to: paths)
        let applied = try String(contentsOf: paths.settings, encoding: .utf8)
        #expect(!applied.contains("profile = \"fast\""))
        #expect(applied.contains("[mcp_servers.node_repl]"))
        #expect(AgentProfile.active(paths) == work)
        #expect(try String(contentsOf: paths.settings.appendingPathExtension(AgentProfile.backupSuffix),
                           encoding: .utf8) == sample + "profile = \"fast\"\n")
        let authFile = paths.directory.appending(path: "auth.json")
        #expect(try JSONFile.read(authFile)["OPENAI_API_KEY"] as? String == "sk-old")
        #expect(AgentProfile.summary(work, paths: paths) == "config.toml + auth.json \u{00B7} gpt-6-sol \u{00B7} OpenAI")

        try write("{\"OPENAI_API_KEY\": \"sk-new\"}", to: authFile)
        try AgentProfile.update(work, from: paths)
        #expect(AgentProfile.active(paths) == work)
        let renamed = try AgentProfile.rename(work, to: "Home")
        #expect(AgentProfile.list(paths).map(\.name) == ["Fast", "Home"])
        #expect(AgentProfile.active(paths) == renamed)
        try AgentProfile.delete(fast)
        #expect(AgentProfile.list(paths) == [renamed])
    }

    @Test("MCP servers, plugins and permissions are the tool's, kept as they are whichever profile is applied")
    func sharedPartsStayLive() throws {
        let paths = try codex()
        let work = try AgentProfile.save(named: "Work", from: paths)
        try write(sample.replacingOccurrences(of: "gpt-6-sol", with: "gpt-6-mini"), to: paths.settings)
        let mini = try AgentProfile.save(named: "Mini", from: paths)

        // A plugin switched off and a server added under one profile...
        var document = TOMLDocument(text: try String(contentsOf: paths.settings, encoding: .utf8))
        document.set("enabled", to: .bool(false), in: ["plugins", "browser@openai-bundled"])
        document.set("command", to: .string("/usr/bin/fetch"), in: ["mcp_servers", "fetch"])
        try write(document.text, to: paths.settings)
        #expect(AgentProfile.active(paths) == mini, "a shared change must not unmatch the profile")

        // ...are still so under the other.
        try AgentProfile.apply(work, to: paths)
        let live = TOMLDocument(text: try String(contentsOf: paths.settings, encoding: .utf8))
        #expect(live.value("model", in: [])?.string == "gpt-6-sol")
        #expect(live.value("enabled", in: ["plugins", "browser@openai-bundled"])?.bool == false)
        #expect(live.value("command", in: ["mcp_servers", "fetch"])?.string == "/usr/bin/fetch")
        #expect(AgentProfile.active(paths) == work)

        // Claude: enabledPlugins and permissions likewise.
        let claude = AgentPaths(.claude, home: try temporaryHome())
        try write(#"{"model": "a", "enabledPlugins": {"x@y": true}, "permissions": {"allow": ["Bash"]}}"#,
                  to: claude.settings)
        let a = try AgentProfile.save(named: "A", from: claude)
        #expect(try JSONFile.read(a.directory.appending(path: "settings.json")).keys.sorted() == ["model"])
        try write(#"{"model": "b", "enabledPlugins": {"x@y": false}}"#, to: claude.settings)
        try AgentProfile.apply(a, to: claude)
        let settings = try JSONFile.read(claude.settings)
        #expect(settings["model"] as? String == "a")
        #expect((settings["enabledPlugins"] as? [String: Bool]) == ["x@y": false])
        #expect(settings["permissions"] == nil)
        #expect(AgentProfile.active(claude) == a)
    }

    @Test("a second profile cannot take a name already in use")
    func duplicateProfile() throws {
        let paths = try codex()
        try AgentProfile.save(named: "Work", from: paths)
        #expect(throws: AgentProfile.Failure.self) { try AgentProfile.save(named: "Work", from: paths) }
        try AgentProfile.save(named: "Other", from: paths)
        #expect(throws: AgentProfile.Failure.self) { try AgentProfile.rename(AgentProfile.list(paths)[0], to: "Work") }
        #expect(throws: AgentProfile.Failure.self) { try AgentProfile.save(named: "../escape", from: paths) }
    }

    @Test("a Claude profile is settings.json alone, summarised by its model and endpoint")
    func claudeProfile() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        try write("""
        {"env": {"ANTHROPIC_MODEL": "m", "ANTHROPIC_BASE_URL": "https://relay.example"}, "theme": "dark-ansi"}
        """, to: paths.settings)
        let relay = try AgentProfile.save(named: "Relay", from: paths)
        #expect(AgentProfile.summary(relay, paths: paths) == "settings.json \u{00B7} m \u{00B7} https://relay.example")
        #expect(try FileManager.default.contentsOfDirectory(atPath: relay.directory.path) == ["settings.json"])

        // With no settings.json at all, the tool is on its own defaults, and
        // a profile saved then puts it back there.
        try FileManager.default.removeItem(at: paths.settings)
        let bare = try AgentProfile.save(named: "Bare", from: paths)
        #expect(AgentProfile.active(paths) == bare)
        try AgentProfile.apply(relay, to: paths)
        #expect(AgentProfile.active(paths) == relay)
        try AgentProfile.apply(bare, to: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.settings.path))
        #expect(AgentProfile.active(paths) == bare)
    }

    @Test("Codex MCP servers read back as written, and a rewritten list touches only what changed")
    func codexMCPServers() throws {
        let paths = try codex()
        var servers = try CodexConfig.mcpServers(paths)
        #expect(servers.map(\.name) == ["computer-use", "node_repl"])
        #expect(servers[0].enabled == false)
        #expect(servers[0].args == ["mcp"])
        #expect(servers[1].env["NODE_REPL_TRUSTED_SERVICES"]
                == "{\"browser\":\"/x/browser-service.mjs\",\"sky\":\"@oai/sky/service\"}")

        try CodexConfig.setMCPServers(servers, paths: paths)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == sample)

        servers[0].enabled = true
        servers[1].env = ["NODE_REPL_NODE_PATH": "/usr/local/bin/node"]
        servers.append(.init(name: "docs", url: "https://docs.example/mcp"))
        try CodexConfig.setMCPServers(servers, paths: paths)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == sample
            .replacingOccurrences(of: "cwd = \".\"\nenabled = false\n", with: "cwd = \".\"\n")
            .replacingOccurrences(of: "NODE_REPL_NODE_PATH = \"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node\"\nNODE_REPL_TRUSTED_SERVICES = '{\"browser\":\"/x/browser-service.mjs\",\"sky\":\"@oai/sky/service\"}'\n",
                                  with: "NODE_REPL_NODE_PATH = \"/usr/local/bin/node\"\n")
            + "\n[mcp_servers.docs]\nurl = \"https://docs.example/mcp\"\n")

        try CodexConfig.setMCPServers([servers[2]], paths: paths)
        let after = try CodexConfig.mcpServers(paths)
        #expect(after == [.init(name: "docs", url: "https://docs.example/mcp")])
        #expect(TOMLDocument(text: try String(contentsOf: paths.settings, encoding: .utf8))
                    .tables(under: ["mcp_servers", "node_repl"]).isEmpty)
    }

    @Test("Claude Code's MCP list drops a disabled server and keeps what it does not know about the rest")
    func claudeMCPServers() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        try write("""
        {"numStartups": 5, "mcpServers": {
            "fs": {"command": "npx", "args": ["-y", "server-fs"], "env": {"ROOT": "/"}},
            "docs": {"type": "sse", "url": "https://docs.example/sse", "headers": {"Authorization": "Bearer t"}}
        }}
        """, to: paths.mcpConfig)
        var servers = try ClaudeCodeConfig.mcpServers(paths)
        #expect(servers == [.init(name: "docs", url: "https://docs.example/sse"),
                            .init(name: "fs", command: "npx", args: ["-y", "server-fs"], env: ["ROOT": "/"])])

        servers[0].url = "https://docs.example/v2"
        servers[1].enabled = false
        servers.append(.init(name: "web", url: "https://web.example/mcp"))
        try ClaudeCodeConfig.setMCPServers(servers, paths: paths)

        let config = try JSONFile.read(paths.mcpConfig)
        #expect(config["numStartups"] as? Int == 5)
        let written = try #require(config["mcpServers"] as? [String: [String: Any]])
        #expect(written.keys.sorted() == ["docs", "web"])
        #expect(written["docs"]?["type"] as? String == "sse")
        #expect(written["docs"]?["url"] as? String == "https://docs.example/v2")
        #expect((written["docs"]?["headers"] as? [String: String])?["Authorization"] == "Bearer t")
        #expect(written["web"]?["type"] as? String == "http")
    }

    @Test("the prompt file is CLAUDE.md for one tool and AGENTS.md for the other")
    func prompt() throws {
        let home = try temporaryHome()
        #expect(AgentPaths(.codex, home: home).prompt.lastPathComponent == "AGENTS.md")
        #expect(AgentPaths(.claude, home: home).prompt.lastPathComponent == "CLAUDE.md")
    }

    @Test("skills are listed from their front matter, and copy between tools as directories")
    func skills() throws {
        let home = try temporaryHome()
        let claude = AgentPaths(.claude, home: home)
        let codex = AgentPaths(.codex, home: home)
        try write("""
        ---
        name: morning
        description: "Render the brief: styled."
        ---
        # Morning
        """, to: claude.skills.appending(path: "morning/SKILL.md"))
        try write("notes", to: claude.skills.appending(path: "morning/extra/notes.txt"))
        try write("no front matter", to: claude.skills.appending(path: "bare/SKILL.md"))
        try write("", to: claude.skills.appending(path: "not-a-skill/README.md"))

        // A synced set, a plugin's, and Codex's own: seen, named for where
        // they are from, and not the user's to remove.
        try write("---\nname: pdf\n---", to: claude.skills.appending(path: "synced/abc_def/pdf/SKILL.md"))
        let plugin = claude.directory.appending(path: "plugins/cache/ponytail/ponytail/4.10.0")
        try write("---\nname: ponytail\n---", to: plugin.appending(path: "skills/ponytail/SKILL.md"))
        try write(#"{"version": 2, "plugins": {"ponytail@ponytail": [{"installPath": "\#(plugin.path)"}]}}"#,
                  to: claude.directory.appending(path: "plugins/installed_plugins.json"))
        try write("---\nname: imagegen\n---", to: codex.skills.appending(path: ".system/imagegen/SKILL.md"))

        let skills = AgentSkill.list(claude)
        #expect(skills.map(\.name) == ["bare", "morning", "pdf", "ponytail"])
        #expect(skills.map(\.source) == [nil, nil, "synced", "ponytail@ponytail"])
        #expect(skills[1].description == "Render the brief: styled.")
        #expect(throws: AgentSkill.Failure.self) { try AgentSkill.remove(skills[3]) }
        #expect(AgentSkill.list(codex).map(\.source) == ["system"])

        try AgentSkill.install(from: skills[1].path, into: codex)
        #expect(AgentSkill.list(codex).map(\.name) == ["morning", "imagegen"])
        #expect(FileManager.default.fileExists(atPath: codex.skills.appending(path: "morning/extra/notes.txt").path))
        // Twice is a mistake, not a replacement.
        #expect(throws: (any Error).self) { try AgentSkill.install(from: skills[1].path, into: codex) }

        try AgentSkill.remove(skills[0])
        #expect(AgentSkill.list(claude).map(\.name) == ["morning", "pdf", "ponytail"])
    }
}
