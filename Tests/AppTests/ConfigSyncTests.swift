import Core
import Foundation
import Testing
@testable import App

/// Servers and `~/.ssh/config` kept as one list, against a config of the
/// test's own: the user's is never touched.
@MainActor
struct ConfigSyncTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        let config: URL
        let model: AppModel

        init(config text: Data) async throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "configsync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = directory.appending(path: "config")
            try text.write(to: config)
            model = AppModel(store: try Store(inMemory: true), sshConfig: config)
            await model.createVault(password: "test-password")
        }

        /// A file an `IdentityFile` can name that is not a key, so importing
        /// reads nothing of the user's own ~/.ssh.
        var notAKey: String {
            let url = directory.appending(path: "not-a-key")
            try? Data("x".utf8).write(to: url)
            return url.path
        }

        var text: String { (try? String(contentsOf: config, encoding: .utf8)) ?? "" }
        func names() async throws -> [String] { try await model.store.servers().map(\.name) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("opening the app imports nothing; deleting a server removes the Host the app wrote, but keeps one with the user's own lines")
    func deleting() async throws {
        let fixture = try await Fixture(config: Data())
        try Data("Host keyed\n    HostName k.example\n    IdentityFile \(fixture.notAKey)\n".utf8)
            .write(to: fixture.config)
        let model = fixture.model

        await model.syncConfig()
        #expect(try await fixture.names().isEmpty, "a host became a server without being imported")
        await model.importHosts(SSHConfig.read(at: fixture.config))
        #expect(try await fixture.names() == ["keyed"])

        let mine = try #require(await model.save(Server(name: "mine", host: "m.example", username: "me")))
        #expect(fixture.text.contains("Host mine"))
        await model.delete(mine)
        #expect(!fixture.text.contains("Host mine"))

        let keyed = try #require(try await model.store.servers().first { $0.name == "keyed" })
        await model.delete(keyed)
        #expect(fixture.text.contains("IdentityFile"), "the user's own line went with the server")
        await model.syncConfig()
        #expect(try await fixture.names().isEmpty, "the deleted server came back")
    }

    @Test("a config that is not UTF-8 is never written over")
    func notText() async throws {
        let latin1 = Data("# caf".utf8) + Data([0xE9]) + Data("\nHost pi\n".utf8)
        let fixture = try await Fixture(config: latin1)

        _ = await fixture.model.save(Server(name: "new", host: "n.example", username: "me"))
        await fixture.model.syncConfig()

        #expect(try Data(contentsOf: fixture.config) == latin1)
        #expect(fixture.model.lastError != nil)
    }

    @Test("renaming a server renames its Host, and the next sync imports nothing twice")
    func renaming() async throws {
        let fixture = try await Fixture(config: Data())
        let model = fixture.model

        var server = try #require(await model.save(Server(name: "lab", host: "10.0.0.5", username: "me")))
        server.name = "lab two"
        _ = await model.save(server)
        #expect(fixture.text.contains("Host lab-two"))
        #expect(!fixture.text.contains("Host lab\n"))

        await model.syncConfig()
        #expect(try await fixture.names() == ["lab two"])
    }

    @Test("importing the same host twice at once makes one server")
    func concurrentImports() async throws {
        let fixture = try await Fixture(config: Data("Host web\n    HostName w.example\n".utf8))
        let model = fixture.model
        let hosts = SSHConfig.read(at: fixture.config)

        async let first: Void = model.importHosts(hosts)
        async let second: Void = model.importHosts(hosts)
        _ = await (first, second)
        #expect(try await fixture.names() == ["web"])
    }
}
