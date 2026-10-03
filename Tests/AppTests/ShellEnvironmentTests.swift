import Core
import Foundation
import Testing
@testable import App

/// The variables new local terminals start with.
///
/// Read through `current` rather than the global it is copied to: other suites
/// running alongside write that global too.
@MainActor
struct ShellEnvironmentTests {
    private func model() async throws -> AppModel {
        let model = AppModel(store: try Store(inMemory: true))
        await model.createVault(password: "test-password")
        return model
    }

    @Test("valid names apply; blank and malformed ones are kept but not applied")
    func onlyValidNames() async throws {
        let environment = try await model().shellEnvironment
        environment.variables = [
            .init(name: "EDITOR", value: "nvim"),
            .init(name: "_PRIVATE", value: "1"),
            .init(name: "", value: "orphan"),
            .init(name: "2FAST", value: "x"),
            .init(name: "HAS SPACE", value: "x"),
        ]
        #expect(environment.current == ["EDITOR": "nvim", "_PRIVATE": "1"])
        #expect(environment.variables.count == 5)
    }

    @Test("the table is saved, and comes back in its order")
    func persisted() async throws {
        let model = try await model()
        let rows: [ShellEnvironment.Variable] = [.init(name: "B", value: "2"), .init(name: "A", value: "1")]
        model.shellEnvironment.variables = rows

        // Saved in the background; give it a moment rather than racing it.
        let reloaded = ShellEnvironment(store: model.store)
        for _ in 0..<50 where reloaded.variables.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            await reloaded.restore()
        }
        #expect(reloaded.variables.map(\.name) == ["B", "A"])
        #expect(reloaded.variables.map(\.value) == ["2", "1"])
    }
}
