import Foundation
import Testing
@testable import Core

struct AgentProviderTests {
    @Test("Claude Code's endpoint, key and model go into env, beside what else the file holds")
    func claudeRoundTrip() throws {
        let directory = try temporaryHome()
        try write(#"{"theme":"dark","env":{"ANTHROPIC_API_KEY":"old","DISABLE_TELEMETRY":"1"}}"#,
                  to: directory.appending(path: "settings.json"))
        #expect(try AgentProvider.read(from: directory, tool: .claude).apiKey == "old")

        let provider = AgentProvider(baseURL: "https://api.deepseek.com/anthropic", apiKey: " sk-1 ",
                                     model: "deepseek-chat")
        try AgentProvider.write(provider, to: directory, tool: .claude)
        let object = try JSONFile.read(directory.appending(path: "settings.json"))
        let env = try #require(object["env"] as? [String: Any])
        #expect(object["theme"] as? String == "dark")
        #expect(env["DISABLE_TELEMETRY"] as? String == "1")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] as? String == "sk-1")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(try AgentProvider.read(from: directory, tool: .claude)
                == AgentProvider(baseURL: provider.baseURL, apiKey: "sk-1", model: "deepseek-chat"))
        #expect(try !AgentProvider.read(from: directory, tool: .claude).baseURL.isEmpty)
    }

    @Test("emptied fields are removed, and an env left with nothing goes too")
    func claudeEmptied() throws {
        let directory = try temporaryHome()
        try AgentProvider.write(AgentProvider(baseURL: "https://x", apiKey: "k", model: "m"),
                                to: directory, tool: .claude)
        try AgentProvider.write(AgentProvider(), to: directory, tool: .claude)
        #expect(try JSONFile.read(directory.appending(path: "settings.json"))["env"] == nil)
        #expect(try AgentProvider.read(from: directory, tool: .claude) == AgentProvider())
    }

    @Test("Codex gets a provider table of its own, the key in auth.json, and loses both when emptied")
    func codexRoundTrip() throws {
        let directory = try temporaryHome()
        try write("model_reasoning_effort = \"high\"\n", to: directory.appending(path: "config.toml"))
        try write(#"{"tokens":{"id":"t"}}"#, to: directory.appending(path: "auth.json"))

        let provider = AgentProvider(baseURL: "https://relay.example/v1", apiKey: "sk-2", model: "gpt-5")
        try AgentProvider.write(provider, to: directory, tool: .codex)
        #expect(try AgentProvider.read(from: directory, tool: .codex) == provider)
        let config = TOMLDocument(text: try String(contentsOf: directory.appending(path: "config.toml"), encoding: .utf8))
        #expect(config.value("model_reasoning_effort", in: [])?.string == "high")
        #expect(config.value("model_provider", in: [])?.string == "custom")
        #expect(try JSONFile.read(directory.appending(path: "auth.json"))["tokens"] != nil)

        try AgentProvider.write(AgentProvider(), to: directory, tool: .codex)
        let emptied = TOMLDocument(text: try String(contentsOf: directory.appending(path: "config.toml"), encoding: .utf8))
        #expect(emptied.value("model_provider", in: []) == nil)
        #expect(emptied.tables(under: ["model_providers"]).isEmpty)
        #expect(emptied.value("model_reasoning_effort", in: [])?.string == "high")
        #expect(try JSONFile.read(directory.appending(path: "auth.json"))["OPENAI_API_KEY"] == nil)
    }

    @Test("Official clears a provider the user named themselves, not only Termther's")
    func codexOfficialOverOwnProvider() throws {
        let directory = try temporaryHome()
        try write("""
            model_provider = "OpenAI"

            [model_providers.OpenAI]
            base_url = "http://relay.example"
            """, to: directory.appending(path: "config.toml"))
        #expect(try AgentProvider.read(from: directory, tool: .codex).baseURL == "http://relay.example")

        try AgentProvider.write(AgentProvider(), to: directory, tool: .codex)
        #expect(try AgentProvider.read(from: directory, tool: .codex).baseURL.isEmpty)
    }
}

struct AccountStatusTests {
    @Test("Codex's login status reads as how it is signed in, without the key")
    func codexStatus() {
        #expect(AgentPlugin.account(fromCodexStatus: "Logged in using ChatGPT\n") == "ChatGPT")
        #expect(AgentPlugin.account(fromCodexStatus: "Logged in using an API key - sk-d2b***\n") == "API key")
        #expect(AgentPlugin.account(fromCodexStatus: "Not logged in\n") == nil)
    }
}

struct LoginTests {
    @Test("cancelling a sign-in ends the tool's wait rather than leaving it running")
    func cancelEndsLogin() async throws {
        let home = try temporaryHome()
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appending(path: "codex")
        try write("#!/bin/sh\nexec sleep 30\n", to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let started = Date()
        let login = Task { try await AgentPlugin.login(AgentTool.codex.paths(home: home)) }
        try await Task.sleep(for: .milliseconds(500))
        login.cancel()
        _ = await login.result
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
