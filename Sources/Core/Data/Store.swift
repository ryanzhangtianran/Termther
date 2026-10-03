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
                    wrappedDataKeyNonce = excluded.wrappedDataKeyNonce,
                    verifier = excluded.verifier,
                    verifierNonce = excluded.verifierNonce,
                    createdAt = excluded.createdAt
                """, arguments: [
                    metadata.version, metadata.salt,
                    metadata.wrappedDataKey.ciphertext, metadata.wrappedDataKey.nonce,
                    metadata.verifier.ciphertext, metadata.verifier.nonce,
                    metadata.createdAt,
                ])
        }
    }

    // MARK: - servers

    public func servers() throws -> [Server] {
        try database.read { db in
            try Server.order(Column("sortOrder"), Column("name")).fetchAll(db)
        }
    }

    /// The place after every server there is. Not the count: once a server
    /// has been deleted from a reordered list, the count is a place taken.
    public func nextSortOrder() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) + 1 FROM server") ?? 0
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

    /// Puts the servers in this order, in one write so the list never shows
    /// it half done. Servers not named keep their place after these.
    public func setServerOrder(_ ids: [Int64]) throws {
        try database.write { db in
            for (index, id) in ids.enumerated() {
                guard var server = try Server.fetchOne(db, key: id), server.sortOrder != index
                else { continue }
                server.sortOrder = index
                try server.update(db)
            }
        }
    }

    /// `ids` with `id` moved to where `target` is: after it when moved down
    /// the list, before it when moved up, as a list's own reordering does.
    public nonisolated static func order(_ ids: [Int64], moving id: Int64, onto target: Int64) -> [Int64] {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target)
        else { return ids }
        var ids = ids
        ids.remove(at: from)
        let landing = ids.firstIndex(of: target)!
        ids.insert(id, at: from < to ? landing + 1 : landing)
        return ids
    }

    public func delete(serverID: Int64) throws {
        // Forward presets go with it (cascade); credentials do not, since they
        // may be shared, and jump-host references fall back to null.
        _ = try database.write { db in try Server.deleteOne(db, key: serverID) }
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

    /// Forgets a server's key, so the next connection records whatever it
    /// presents. For a server that was reinstalled.
    public func forgetHostKey(host: String, port: Int) throws {
        _ = try database.write { db in
            try KnownHost.filter(Column("host") == host && Column("port") == port).deleteAll(db)
        }
    }

    /// The check the app installs in `HostKeyCheck`: a key is remembered the
    /// first time and must match after that, as OpenSSH does it.
    public func checkHostKey(host: String, port: UInt16, fingerprint: String) throws {
        if case .changed(let previous) = try verify(host: host, port: Int(port), fingerprint: fingerprint) {
            throw HostKeyChanged(host: host, port: port, previous: previous, presented: fingerprint)
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

/// A server presented a different key from the one it had before.
public struct HostKeyChanged: Error, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public let previous: String
    public let presented: String

    public var description: String {
        "the host key of \(host):\(port) has changed (was \(previous), now \(presented)). "
            + "Someone may be intercepting the connection. If the server was reinstalled, "
            + "choose Forget Host Key on it and connect again."
    }
}
