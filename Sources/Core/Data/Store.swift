import Foundation
import GRDB
import Net

/// Everything Termther remembers.
///
/// The store never decrypts anything: it moves sealed bytes in and out, and the
/// vault is asked to open them only at the moment a connection is actually
/// made. That keeps plaintext secrets out of the model layer entirely, so no
/// list, no export and no log can leak one by accident.
public actor Store {
    private let database: DatabaseQueue

    public init(at url: URL = Schema.defaultURL) throws {
        database = try Schema.open(at: url)
    }

    /// In-memory, for tests.
    public init(inMemory: Bool) throws {
        database = try DatabaseQueue()
        try Schema.migrator().migrate(database)
    }

    // MARK: - vault metadata

    public func vaultMetadata() throws -> Vault.Metadata? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM vaultMetadata WHERE id = 1")
            else { return nil }
            return Vault.Metadata(
                version: row["version"],
                salt: row["salt"],
                wrappedDataKey: .init(ciphertext: row["wrappedDataKey"],
                                      nonce: row["wrappedDataKeyNonce"]),
                verifier: .init(ciphertext: row["verifier"], nonce: row["verifierNonce"]),
                createdAt: row["createdAt"])
        }
    }

    public func save(_ metadata: Vault.Metadata) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO vaultMetadata
                    (id, version, salt, wrappedDataKey, wrappedDataKeyNonce,
                     verifier, verifierNonce, createdAt)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    version = excluded.version,
                    salt = excluded.salt,
                    wrappedDataKey = excluded.wrappedDataKey,
                    wrappedDataKeyNonce = excluded.wrappedDataKeyNonce
                """, arguments: [
                    metadata.version, metadata.salt,
                    metadata.wrappedDataKey.ciphertext, metadata.wrappedDataKey.nonce,
                    metadata.verifier.ciphertext, metadata.verifier.nonce,
                    metadata.createdAt,
                ])
        }
    }

    public var hasVault: Bool {
        get throws { try vaultMetadata() != nil }
    }

    // MARK: - servers

    public func servers() throws -> [Server] {
        try database.read { db in
            try Server.order(Column("sortOrder"), Column("name")).fetchAll(db)
        }
    }

    public func server(id: Int64) throws -> Server? {
        try database.read { db in try Server.fetchOne(db, key: id) }
    }

    @discardableResult
    public func save(_ server: Server) throws -> Server {
        var server = server
        server.updatedAt = Date()
        try database.write { db in try server.save(db) }
        return server
    }

    public func delete(serverID: Int64) throws {
        // Forward presets go with it (cascade); credentials do not, since they
        // may be shared, and jump-host references fall back to null.
        _ = try database.write { db in try Server.deleteOne(db, key: serverID) }
    }

    /// Reorders in one transaction, so a drag never leaves a half-applied list.
    public func reorderServers(_ ids: [Int64]) throws {
        try database.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE server SET sortOrder = ? WHERE id = ?",
                               arguments: [index, id])
            }
        }
    }

    public func markConnected(serverID: Int64, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE server SET lastConnectedAt = ? WHERE id = ?",
                           arguments: [date, serverID])
        }
    }

    /// Emits the server list, and again whenever it changes.
    public nonisolated func observeServers() -> AsyncValueObservation<[Server]> {
        ValueObservation
            .tracking { db in try Server.order(Column("sortOrder"), Column("name")).fetchAll(db) }
            .values(in: database)
    }

    // MARK: - credentials

    public func credentials() throws -> [Credential] {
        try database.read { db in try Credential.order(Column("name")).fetchAll(db) }
    }

    public func credential(id: Int64) throws -> Credential? {
        try database.read { db in try Credential.fetchOne(db, key: id) }
    }

    @discardableResult
    public func save(_ credential: Credential) throws -> Credential {
        var credential = credential
        credential.updatedAt = Date()
        try database.write { db in try credential.save(db) }
        return credential
    }

    public func delete(credentialID: Int64) throws {
        _ = try database.write { db in try Credential.deleteOne(db, key: credentialID) }
    }

    // MARK: - port forwards

    public func portForwards(serverID: Int64) throws -> [PortForwardPreset] {
        try database.read { db in
            try PortForwardPreset
                .filter(Column("serverId") == serverID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    @discardableResult
    public func save(_ preset: PortForwardPreset) throws -> PortForwardPreset {
        var preset = preset
        try database.write { db in try preset.save(db) }
        return preset
    }

    /// Every forward, for the panel that lists them all at once.
    public func portForwards() throws -> [PortForwardPreset] {
        try database.read { db in
            try PortForwardPreset.order(Column("serverId"), Column("sortOrder")).fetchAll(db)
        }
    }

    public func delete(portForwardID: Int64) throws {
        _ = try database.write { db in try PortForwardPreset.deleteOne(db, key: portForwardID) }
    }

    // MARK: - VPN profiles

    public func vpnProfiles() throws -> [VPNProfile] {
        try database.read { db in try VPNProfile.order(Column("name")).fetchAll(db) }
    }

    @discardableResult
    public func save(_ profile: VPNProfile) throws -> VPNProfile {
        var profile = profile
        profile.updatedAt = Date()
        try database.write { db in try profile.save(db) }
        return profile
    }

    public func delete(vpnProfileID: Int64) throws {
        _ = try database.write { db in try VPNProfile.deleteOne(db, key: vpnProfileID) }
    }

    // MARK: - known hosts

    public func knownHost(host: String, port: Int) throws -> KnownHost? {
        try database.read { db in
            try KnownHost
                .filter(Column("host") == host && Column("port") == port)
                .fetchOne(db)
        }
    }

    /// Records a fingerprint the first time, and reports a mismatch after that.
    ///
    /// A changed key is either a reinstalled server or someone in the middle,
    /// and the difference is not something this layer can decide -- so it says
    /// what it saw and leaves the choice to the user.
    public enum HostKeyVerdict: Sendable, Equatable {
        case firstSight
        case known
        case changed(previous: String)
    }

    public func verify(host: String, port: Int, fingerprint: String) throws -> HostKeyVerdict {
        if let existing = try knownHost(host: host, port: port) {
            return existing.fingerprint == fingerprint
                ? .known
                : .changed(previous: existing.fingerprint)
        }
        var record = KnownHost(host: host, port: port, fingerprint: fingerprint)
        try database.write { db in try record.insert(db) }
        return .firstSight
    }

    /// Accepts a changed key, after the user has been asked.
    public func trust(host: String, port: Int, fingerprint: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO knownHost (host, port, fingerprint, firstSeenAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(host, port) DO UPDATE SET fingerprint = excluded.fingerprint
                """, arguments: [host, port, fingerprint, Date()])
        }
    }

    // MARK: - settings

    public func setting(_ key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?",
                                arguments: [key])
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try database.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }
}
