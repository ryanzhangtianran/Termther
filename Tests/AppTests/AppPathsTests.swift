import Core
import Foundation
import Testing
@testable import App

/// General's locations, over an in-memory store: the defaults, and a change
/// that outlives the object that made it.
@MainActor
struct AppPathsTests {
    @Test("the locations default to ~/.termther, ~/.ssh and ~/.ssh/config")
    func defaults() async throws {
        let paths = AppPaths(store: try Store(inMemory: true))
        await paths.restore()
        let home = URL.homeDirectory.path
        #expect(paths[.data].path == home + "/.termther")
        #expect(paths[.keys].path == home + "/.ssh")
        #expect(paths[.sshConfig].path == home + "/.ssh/config")
    }

    @Test("a changed location is remembered, and read back by a fresh AppPaths")
    func persists() async throws {
        let store = try Store(inMemory: true)
        let keys = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        let config = FileManager.default.temporaryDirectory.appending(path: "config-\(UUID().uuidString)")
        let paths = AppPaths(store: store)
        try await paths.set(.keys, to: keys)
        try await paths.set(.sshConfig, to: config)
        #expect(paths[.keys] == keys)
        #expect(try await store.setting("path.keys") == keys.path)

        let again = AppPaths(store: store)
        await again.restore()
        #expect(again[.keys].path == keys.path)
        #expect(again[.sshConfig].path == config.path)
        #expect(again[.data] == AppPaths.defaultData)
    }
}
