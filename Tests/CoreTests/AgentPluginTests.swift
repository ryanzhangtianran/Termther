import Foundation
import Testing
@testable import Core

/// Plugins as the tools list them, and the switch each keeps in its settings.
///
/// The listings are fixtures: the real `claude` and `codex` are never run.
struct AgentPluginTests {
    let claudeListing = """
    [
      {"id": "ponytail@ponytail", "version": "4.10.0", "scope": "user", "enabled": true,
       "installPath": "/Users/me/.claude/plugins/cache/ponytail/ponytail/4.10.0",
       "installedAt": "2026-09-25T14:39:47.726Z", "lastUpdated": "2026-09-25T14:39:47.726Z", "projectEnabled": false},
      {"id": "swift-lsp@claude-plugins-official", "version": "1.0.0", "scope": "user", "enabled": false,
       "installPath": "/Users/me/.claude/plugins/cache/claude-plugins-official/swift-lsp/1.0.0"},
      {"id": "rust-analyzer-lsp@claude-plugins-official", "version": "1.0.0", "scope": "user", "enabled": true}
    ]
    """

    let codexListing = """
    {"installed": [
      {"pluginId": "pdf@openai-primary-runtime", "name": "pdf", "marketplaceName": "openai-primary-runtime",
       "version": "26.904.11930", "installed": true, "enabled": true,
       "source": {"source": "local", "path": "/Users/me/.cache/codex-runtimes/plugins/pdf"},
       "installPolicy": "AVAILABLE", "authPolicy": "ON_USE"},
      {"pluginId": "browser@openai-bundled", "name": "browser", "marketplaceName": "openai-bundled",
       "version": "1.2.0", "installed": true, "enabled": false, "source": {"source": "bundled"}}
    ]}
    """

    @Test("Claude Code's listing parses by id, split into name and marketplace")
    func parseClaude() throws {
        let plugins = try AgentPlugin.parse(Data(claudeListing.utf8), tool: .claude)
        #expect(plugins.map(\.id) == ["ponytail@ponytail", "rust-analyzer-lsp@claude-plugins-official",
                                      "swift-lsp@claude-plugins-official"])
        #expect(plugins[0] == AgentPlugin(
            id: "ponytail@ponytail", name: "ponytail", marketplace: "ponytail", version: "4.10.0", enabled: true,
            installPath: URL(fileURLWithPath: "/Users/me/.claude/plugins/cache/ponytail/ponytail/4.10.0",
                             isDirectory: true)))
        #expect(plugins[1].installPath == nil)
        #expect(plugins[2].enabled == false)
        #expect(plugins[2].marketplace == "claude-plugins-official")
    }

    @Test("Codex's listing parses from its installed array, the path from a local source")
    func parseCodex() throws {
        let plugins = try AgentPlugin.parse(Data(codexListing.utf8), tool: .codex)
        #expect(plugins.map(\.id) == ["browser@openai-bundled", "pdf@openai-primary-runtime"])
        #expect(plugins[0] == AgentPlugin(id: "browser@openai-bundled", name: "browser", marketplace: "openai-bundled",
                                          version: "1.2.0", enabled: false, installPath: nil))
        #expect(plugins[1].installPath?.path == "/Users/me/.cache/codex-runtimes/plugins/pdf")
        #expect(throws: AgentPlugin.Failure.self) { try AgentPlugin.parse(Data("not json".utf8), tool: .codex) }
    }

    @Test("a version line holds one number, whatever surrounds it")
    func versionNumber() {
        #expect(AgentPlugin.versionNumber(in: "2.1.285 (Claude Code)\n") == "2.1.285")
        #expect(AgentPlugin.versionNumber(in: "codex-cli 0.157.1\n") == "0.157.1")
        #expect(AgentPlugin.versionNumber(in: "") == nil)
    }

    @Test("a tool that is not installed is a clear failure, not a hang")
    func missingTool() async throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        await #expect(throws: AgentPlugin.Failure.self) { try await AgentPlugin.list(paths) }
        #expect(await AgentPlugin.version(paths) == nil)
    }

    @Test("the Claude switch is one key in settings.json, the rest of the file kept")
    func claudeSwitch() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        try write(#"{"theme": "dark", "enabledPlugins": {"ponytail@ponytail": true, "other@m": false}}"#,
                  to: paths.settings)
        let plugin = try AgentPlugin.parse(Data(claudeListing.utf8), tool: .claude)[0]
        try AgentPlugin.setEnabled(false, plugin, paths: paths)
        var settings = try JSONFile.read(paths.settings)
        #expect(settings["theme"] as? String == "dark")
        #expect(settings["enabledPlugins"] as? [String: Bool] == ["ponytail@ponytail": false, "other@m": false])

        try AgentPlugin.setEnabled(true, plugin, paths: paths)
        settings = try JSONFile.read(paths.settings)
        #expect(settings["enabledPlugins"] as? [String: Bool] == ["ponytail@ponytail": true, "other@m": false])

        // No settings.json yet: made, with the one key.
        try FileManager.default.removeItem(at: paths.settings)
        try AgentPlugin.setEnabled(false, plugin, paths: paths)
        #expect(try JSONFile.read(paths.settings)["enabledPlugins"] as? [String: Bool] == ["ponytail@ponytail": false])
    }

    @Test("the Codex switch rewrites one line of config.toml, and adds the table when there is none")
    func codexSwitch() throws {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        let sample = """
        model = "gpt-6-sol"  # kept

        [plugins."pdf@openai-primary-runtime"]
        enabled = true

        [mcp_servers.docs]
        url = "https://docs.example/mcp"

        """
        try write(sample, to: paths.settings)
        let plugins = try AgentPlugin.parse(Data(codexListing.utf8), tool: .codex)
        try AgentPlugin.setEnabled(false, plugins[1], paths: paths)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8)
                == sample.replacingOccurrences(of: "enabled = true", with: "enabled = false"))

        try AgentPlugin.setEnabled(true, plugins[1], paths: paths)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == sample)

        try AgentPlugin.setEnabled(false, plugins[0], paths: paths)
        #expect(try String(contentsOf: paths.settings, encoding: .utf8)
                == sample + "\n[plugins.\"browser@openai-bundled\"]\nenabled = false\n")
    }

    @Test("the commands are the tools' own, and Codex updates by refreshing and adding again")
    func commands() {
        #expect(AgentPlugin.installCommand(id: "a@m", tool: .claude) == "claude plugin install a@m")
        #expect(AgentPlugin.installCommand(id: "a@m", tool: .codex) == "codex plugin add a@m")
        #expect(AgentPlugin.uninstallCommand(id: "a@m", tool: .claude) == "claude plugin uninstall a@m")
        #expect(AgentPlugin.uninstallCommand(id: "a@m", tool: .codex) == "codex plugin remove a@m")
        #expect(AgentPlugin.updateCommand(id: "a@m", tool: .claude) == "claude plugin update a@m")
        #expect(AgentPlugin.updateCommand(id: "a@m", tool: .codex)
                == "codex plugin marketplace upgrade && codex plugin add a@m")
    }
}
