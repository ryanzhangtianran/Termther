import Core
import Foundation
import Testing
@testable import App

/// The agents' controller, over a home directory that exists for one test,
/// so nothing here reads or writes the real `~/.claude` or `~/.codex`.
@MainActor
struct AgentsTests {
    /// The model is handed back to be held: `Agents` only keeps a weak
    /// reference, and does nothing once it is gone.
    private func fixture() async throws -> (model: AppModel, agents: Agents, home: URL) {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        let home = FileManager.default.temporaryDirectory
            .appending(path: "agents-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (model, Agents(model: model, home: home), home)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("saving a profile keeps the files, applying another puts its files in place, and the active one is recognised")
    func profiles() async throws {
        let (model, agents, _) = try await fixture()
        let paths = agents.paths(.claude)
        try write("{\"env\": {\"ANTHROPIC_MODEL\": \"a\"}}", to: paths.settings)
        // With nothing saved, the files as they are become "Default".
        await agents.refresh(.claude)
        #expect(agents[.claude].activeProfile?.name == "Default")
        await agents.renameProfile(agents[.claude].profiles[0], to: "A", for: .claude)
        #expect(agents[.claude].activeProfile?.name == "A")

        // An edit made outside is A's: the files are always some profile's.
        try write("{\"env\": {\"ANTHROPIC_MODEL\": \"a2\"}}", to: paths.settings)
        await agents.refresh(.claude)
        #expect(agents[.claude].activeProfile?.name == "A")
        #expect(agents[.claude].summaries[agents[.claude].profiles[0].id] == "settings.json \u{00B7} a2")
        try write("{\"env\": {\"ANTHROPIC_MODEL\": \"a\"}}", to: paths.settings)
        await agents.updateProfile(agents[.claude].profiles[0], for: .claude)

        try write("{\"env\": {\"ANTHROPIC_MODEL\": \"b\"}}", to: paths.settings)
        await agents.saveProfile(named: "B", for: .claude)
        #expect(agents[.claude].profiles.map(\.name) == ["A", "B"])
        #expect(agents[.claude].activeProfile?.name == "B")
        #expect(agents[.claude].summaries[agents[.claude].profiles[1].id] == "settings.json \u{00B7} b")

        await agents.applyProfile(agents[.claude].profiles[0], for: .claude)
        #expect(agents[.claude].activeProfile?.name == "A")
        // Written afresh, so the formatting is the app's; the content is A's.
        let env = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settings)) as? [String: [String: String]]
        #expect(env == ["env": ["ANTHROPIC_MODEL": "a"]])

        // A second "A" is refused and reported, not silently replaced.
        await agents.saveProfile(named: "A", for: .claude)
        #expect(model.lastError != nil)
        model.dismissError()

        await agents.renameProfile(agents[.claude].profiles[0], to: "C", for: .claude)
        #expect(agents[.claude].profiles.map(\.name) == ["B", "C"])
        #expect(agents[.claude].activeProfile?.name == "C")
        await agents.deleteProfile(agents[.claude].profiles[0], for: .claude)
        #expect(agents[.claude].profiles.map(\.name) == ["C"])
        #expect(model.lastError == nil)
    }

    @Test("with the switch on, the launcher is made a copy and follows a new version on the next refresh")
    func launcherCopy() async throws {
        let (model, agents, _) = try await fixture()
        let paths = agents.paths(.claude)
        try write("#!/bin/sh\necho 1\n", to: paths.versions.appending(path: "2.1.9"))
        try FileManager.default.createDirectory(at: paths.command.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.9"))
        await agents.refresh(.claude)
        #expect(agents[.claude].launcher == .symlink(version: "2.1.9"))
        #expect(!agents[.claude].launcherCopy)

        await agents.setLauncherCopy(true)
        #expect(try await model.store.setting(Agents.launcherCopyKey) == "on")
        #expect(agents[.claude].launcher == .copy(version: "2.1.9"))

        // The updater installs a version and points the symlink at it.
        try write("#!/bin/sh\necho 2\n", to: paths.versions.appending(path: "2.1.10"))
        try FileManager.default.removeItem(at: paths.command)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.10"))
        await agents.refresh(.claude)
        #expect(agents[.claude].launcher == .copy(version: "2.1.10"))
        #expect(agents[.claude].latestVersion == "2.1.10")

        await agents.setLauncherCopy(false)
        #expect(agents[.claude].launcher == .symlink(version: "2.1.10"))
        #expect(model.lastError == nil)
    }


    @Test("deleting sessions removes their transcripts")
    func deleteSessions() async throws {
        let (model, agents, _) = try await fixture()
        let paths = agents.paths(.claude)
        let file = paths.sessions.appending(path: "-repo/abc.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"type":"user","message":{"role":"user","content":"hello"},"cwd":"/repo"}"#
            .write(to: file, atomically: true, encoding: .utf8)

        await agents.refreshSessions(.claude)
        #expect(agents[.claude].sessions.map(\.title) == ["hello"])

        await agents.deleteSessions(agents[.claude].sessions)
        #expect(agents[.claude].sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(model.lastError == nil)
    }
}
