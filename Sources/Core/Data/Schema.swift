import Foundation
import GRDB

/// The database, and how it got to its current shape.
///
/// Migrations are append-only and never edited once shipped: a released
/// migration has already run on a real database, so changing it means two
/// machines disagree about what the schema is. Corrections are new migrations.
public enum Schema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // One row. Holds nothing secret: without the password none of it
            // is useful, which is why it can live in the same file.
            try db.create(table: "vaultMetadata") { table in
                table.primaryKey("id", .integer).notNull()
                table.column("version", .integer).notNull()
                table.column("salt", .blob).notNull()
                table.column("wrappedDataKey", .blob).notNull()
                table.column("wrappedDataKeyNonce", .blob).notNull()
                table.column("verifier", .blob).notNull()
                table.column("verifierNonce", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
            }

            // A credential is separate from the servers using it so one key can
            // serve many hosts without being stored -- or re-encrypted -- once
            // per host.
            try db.create(table: "credential") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("username", .text)
                table.column("secret", .blob).notNull()
                table.column("secretNonce", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "server") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull().defaults(to: 22)
                table.column("username", .text).notNull()
                table.column("credentialId", .integer)
                    .references("credential", onDelete: .setNull)
                // Self-referencing: a jump host is just another saved server,
                // so it carries its own credentials and proxy settings and can
                // itself be reached through a jump host.
                table.column("jumpHostId", .integer)
                    .references("server", onDelete: .setNull)
                table.column("proxyKind", .text)
                table.column("proxyHost", .text)
                table.column("proxyPort", .integer)
                table.column("proxyUsername", .text)
                table.column("proxySecret", .blob)
                table.column("proxySecretNonce", .blob)
                table.column("tags", .text).notNull().defaults(to: "")
                table.column("sortOrder", .integer).notNull().defaults(to: 0)
                table.column("lastConnectedAt", .datetime)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "server_sortOrder", on: "server", columns: ["sortOrder"])

            try db.create(table: "portForward") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("serverId", .integer).notNull()
                    .references("server", onDelete: .cascade)
                table.column("direction", .text).notNull()
                table.column("bindHost", .text).notNull().defaults(to: "127.0.0.1")
                table.column("bindPort", .integer).notNull()
                table.column("targetHost", .text).notNull().defaults(to: "")
                table.column("targetPort", .integer).notNull().defaults(to: 0)
                table.column("autoStart", .boolean).notNull().defaults(to: false)
                table.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // Trust on first use: a fingerprint that changes later is either a
            // reinstalled server or an attack, and the user has to be asked.
            try db.create(table: "knownHost") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("fingerprint", .text).notNull()
                table.column("firstSeenAt", .datetime).notNull()
                table.uniqueKey(["host", "port"])
            }

            // Non-secret preferences. A key-value table rather than columns,
            // because settings come and go and none of them is queried.
            try db.create(table: "setting") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // Whether a server is reached through the campus tunnel. Off for
            // everything that already exists, which is the honest default: a
            // host that was reachable directly still is.
            try db.alter(table: "server") { table in
                table.add(column: "routesThroughVPN", .boolean)
                    .notNull().defaults(to: false)
            }

            // Several may be saved; the engine only ever has one up.
            try db.create(table: "vpnProfile") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("gateway", .text).notNull()
                table.column("username", .text).notNull()
                table.column("secret", .blob).notNull()
                table.column("secretNonce", .blob).notNull()
                table.column("totpSecret", .blob)
                table.column("totpSecretNonce", .blob)
                table.column("interfaceName", .text)
                table.column("dnsServer", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3") { db in
            // Reverse forwards brought two properties with them: one that puts
            // a dropped tunnel back up, and one that tells the server's
            // terminals the tunnel is there to be used.
            try db.alter(table: "portForward") { table in
                table.add(column: "keepAlive", .boolean).notNull().defaults(to: false)
                table.add(column: "exportsEnvironment", .boolean)
                    .notNull().defaults(to: false)
            }
        }

        return migrator
    }

    /// Opens the database, creating and migrating it as needed.
    public static func open(at url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        // Foreign keys are off by default in SQLite, which would let a delete
        // leave a server pointing at a credential that no longer exists.
        configuration.foreignKeysEnabled = true

        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try migrator().migrate(queue)
        return queue
    }

    /// The store's usual home.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Termther", directoryHint: .isDirectory)
            .appending(path: "termther.sqlite")
    }
}
