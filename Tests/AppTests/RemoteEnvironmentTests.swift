import Core
import Testing
@testable import App

/// What an SSH terminal runs before its login shell.
@MainActor
struct RemoteEnvironmentTests {
    private func model() async throws -> AppModel {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        return model
    }

    @Test("a server's valid variables are exported before its login shell")
    func exportsServerVariables() async throws {
        let model = try await model()
        var server = Server(name: "gpu", host: "gpu.example.edu", username: "me")
        server.environment = [.init(name: "EDITOR", value: "nvim"),
                              .init(name: "2BAD", value: "x"),
                              .init(name: "GREETING", value: "hello world")]

        let command = try #require(model.remoteShellCommand(for: server))
        #expect(command.hasPrefix("export EDITOR="))
        #expect(command.contains("nvim"))
        #expect(command.contains("GREETING='hello world'"))
        #expect(!command.contains("2BAD"))
        #expect(command.hasSuffix("exec \"$SHELL\" -l"))
    }

    @Test("with nothing to export, the server gets its plain login shell")
    func nothingToExport() async throws {
        let model = try await model()
        let server = Server(name: "gpu", host: "gpu.example.edu", username: "me")
        #expect(model.remoteShellCommand(for: server) == nil)
    }

    @Test("the local table stays local")
    func localTableIsNotSent() async throws {
        let model = try await model()
        model.shellEnvironment.variables = [.init(name: "http_proxy",
                                                  value: "http://127.0.0.1:6152")]
        let server = Server(name: "gpu", host: "gpu.example.edu", username: "me")
        #expect(model.remoteShellCommand(for: server) == nil)
    }
}
