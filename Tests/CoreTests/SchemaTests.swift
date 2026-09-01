import Foundation
import GRDB
import Testing
@testable import Core

/// What the migrations do to a database that already has data in it.
///
/// A migration is only ever run once on any real database, and by then it is
/// too late to change it -- so the thing worth testing is not that the schema
/// ends up right on an empty file, but that a v1 database with rows in it
/// survives the step to v2 with those rows intact.
struct SchemaTests {
    /// A database stopped at v1, with one server in it.
    private func v1Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO server (name, host, port, username, tags, sortOrder,
                                    createdAt, updatedAt)
                VALUES ('old', 'example.com', 22, 'me', '', 0, ?, ?)
                """, arguments: [Date(), Date()])
        }
        return queue
    }

    @Test("v2 leaves the servers that were already there alone")
    func migrationKeepsRows() throws {
        let queue = try v1Database()
        try Schema.migrator().migrate(queue)

        let servers = try queue.read { db in try Server.fetchAll(db) }
        #expect(servers.count == 1)
        #expect(servers.first?.host == "example.com")
        // The honest default: a host that was reachable directly still is.
        #expect(servers.first?.routesThroughVPN == false)
    }

    @Test("a gateway survives a round trip through the database")
    func vpnProfileRoundTrips() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        var profile = VPNProfile(
            name: "campus", gateway: "connect.example.edu.cn:443", username: "me",
            sealed: .init(ciphertext: Data([1, 2, 3]), nonce: Data([4, 5])),
            totp: .init(ciphertext: Data([6]), nonce: Data([7])),
            interfaceName: "en0", dnsServer: "10.0.0.1")
        try queue.write { db in try profile.insert(db) }

        let saved = try queue.read { db in try VPNProfile.fetchAll(db) }
        #expect(saved.count == 1)
        #expect(saved.first?.gateway == "connect.example.edu.cn:443")
        #expect(saved.first?.interfaceName == "en0")
        // The second factor is optional, and the columns carrying it have to
        // come back as a pair or not at all.
        #expect(saved.first?.totpSealed?.ciphertext == Data([6]))
    }

    @Test("a gateway without a second factor keeps both TOTP columns empty")
    func totpIsOptional() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        var profile = VPNProfile(name: "campus", gateway: "g", username: "me",
                                 sealed: .init(ciphertext: Data([1]), nonce: Data([2])))
        try queue.write { db in try profile.insert(db) }

        let saved = try queue.read { db in try VPNProfile.fetchOne(db) }
        #expect(saved?.totpSealed == nil)
    }

    @Test("deleting a server takes its forwards with it")
    func forwardsCascade() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try Schema.migrator().migrate(queue)

        try queue.write { db in
            var server = Server(name: "db", host: "example.com", username: "me")
            try server.insert(db)
            var preset = PortForwardPreset(serverId: server.id!, direction: .local,
                                           bindPort: 15432, targetHost: "127.0.0.1",
                                           targetPort: 5432)
            try preset.insert(db)
            try Server.deleteOne(db, key: server.id!)
        }

        let remaining = try queue.read { db in try PortForwardPreset.fetchCount(db) }
        #expect(remaining == 0)
    }
}
