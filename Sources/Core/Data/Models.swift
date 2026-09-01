import Foundation
import GRDB
import Net

/// A saved way of logging in.
///
/// Separate from the servers using it, so one key can serve many hosts without
/// being stored once per host -- and so rotating it is one edit.
public struct Credential: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: Int64?
    public var name: String
    public var kind: Kind
    /// Only set when the credential carries its own user, distinct from the
    /// server's.
    public var username: String?
    /// Ciphertext. Never the secret itself, even in memory here.
    public var secret: Data
    public var secretNonce: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, name: String, kind: Kind, username: String? = nil,
                sealed: Vault.Sealed, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.username = username
        self.secret = sealed.ciphertext
        self.secretNonce = sealed.nonce
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var sealed: Vault.Sealed { .init(ciphertext: secret, nonce: secretNonce) }

    /// The purpose bound into the ciphertext, so a password cannot be opened as
    /// something else.
    public var context: String { "credential.\(kind.rawValue)" }
}

/// A host worth keeping.
public struct Server: Codable, Identifiable, Equatable, Sendable {
    public enum ProxyKind: String, Codable, Sendable, CaseIterable {
        case socks5
        case httpConnect
    }

    public var id: Int64?
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var credentialId: Int64?
    /// Another saved server to reach this one through. Self-referencing, so a
    /// jump host carries its own credentials and can itself be jumped to.
    public var jumpHostId: Int64?
    public var proxyKind: ProxyKind?
    public var proxyHost: String?
    public var proxyPort: Int?
    public var proxyUsername: String?
    public var proxySecret: Data?
    public var proxySecretNonce: Data?
    /// Reached through the campus VPN rather than the open internet.
    ///
    /// Per server rather than global: the gateway only routes the ranges it
    /// advertises, and traffic outside them is dropped rather than refused --
    /// so sending everything through a connected tunnel would turn every other
    /// host into a hang.
    public var routesThroughVPN: Bool
    /// Comma-separated. A join table would be tidier and is not worth it for a
    /// list a person types by hand.
    public var tags: String
    public var sortOrder: Int
    public var lastConnectedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, name: String, host: String, port: Int = 22,
                username: String, credentialId: Int64? = nil, jumpHostId: Int64? = nil,
                routesThroughVPN: Bool = false,
                tags: String = "", sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credentialId = credentialId
        self.jumpHostId = jumpHostId
        self.routesThroughVPN = routesThroughVPN
        self.tags = tags
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var proxySealed: Vault.Sealed? {
        guard let proxySecret, let proxySecretNonce else { return nil }
        return .init(ciphertext: proxySecret, nonce: proxySecretNonce)
    }
}

/// A tunnel worth keeping.
public struct PortForwardPreset: Codable, Identifiable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case local
        case dynamic
        /// The server listens and hands the connections back here. `ssh -R`.
        case remote
    }

    public var id: Int64?
    public var serverId: Int64
    public var direction: Direction
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int
    /// Brought up on its own as soon as the vault is unlocked, rather than
    /// waiting for someone to click it.
    public var autoStart: Bool
    /// Put back up when it drops, with a backoff.
    ///
    /// Distinct from `autoStart`, which is one-shot: a tunnel that something
    /// on the server depends on -- its route to a proxy, say -- is useless if
    /// a brief network blip takes it away for good.
    public var keepAlive: Bool
    /// New terminals on this server are told to use the tunnel.
    ///
    /// Only meaningful for a remote forward. Without it the tunnel exists and
    /// nothing on the server knows to send anything through it.
    public var exportsEnvironment: Bool
    public var sortOrder: Int

    public init(id: Int64? = nil, serverId: Int64, direction: Direction,
                bindHost: String = "127.0.0.1", bindPort: Int,
                targetHost: String = "", targetPort: Int = 0,
                autoStart: Bool = false, keepAlive: Bool = false,
                exportsEnvironment: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.serverId = serverId
        self.direction = direction
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
        self.keepAlive = keepAlive
        self.exportsEnvironment = exportsEnvironment
        self.sortOrder = sortOrder
    }
}

/// A way onto a campus network.
///
/// The engine keeps one tunnel at a time -- it is a Go archive with process-
/// global state -- so several profiles may be saved but only one is ever up.
public struct VPNProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    /// `host` or `host:port`; 443 when no port is given.
    public var gateway: String
    public var username: String
    /// Ciphertext, like every other secret here.
    public var secret: Data
    public var secretNonce: Data
    /// Base32 TOTP seed, for accounts carrying a second factor.
    public var totpSecret: Data?
    public var totpSecretNonce: Data?
    /// Physical interface and resolver to pin the engine's own socket to.
    /// Only needed when a local TUN proxy has taken the default route; see
    /// `EasyConnect.Underlay`.
    public var interfaceName: String?
    public var dnsServer: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, name: String, gateway: String, username: String,
                sealed: Vault.Sealed, totp: Vault.Sealed? = nil,
                interfaceName: String? = nil, dnsServer: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.gateway = gateway
        self.username = username
        self.secret = sealed.ciphertext
        self.secretNonce = sealed.nonce
        self.totpSecret = totp?.ciphertext
        self.totpSecretNonce = totp?.nonce
        self.interfaceName = interfaceName
        self.dnsServer = dnsServer
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var sealed: Vault.Sealed { .init(ciphertext: secret, nonce: secretNonce) }

    public var totpSealed: Vault.Sealed? {
        guard let totpSecret, let totpSecretNonce else { return nil }
        return .init(ciphertext: totpSecret, nonce: totpSecretNonce)
    }

    public static let passwordContext = "vpn.password"
    public static let totpContext = "vpn.totp"
}

/// A host key seen before.
public struct KnownHost: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var host: String
    public var port: Int
    public var fingerprint: String
    public var firstSeenAt: Date

    public init(id: Int64? = nil, host: String, port: Int, fingerprint: String,
                firstSeenAt: Date = Date()) {
        self.id = id
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.firstSeenAt = firstSeenAt
    }
}

// MARK: - persistence

extension Credential: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "credential"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Server: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "server"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension PortForwardPreset: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "portForward"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension VPNProfile: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "vpnProfile"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension KnownHost: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "knownHost"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
