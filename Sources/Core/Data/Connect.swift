import Foundation
import Net
import SSH

/// Turns a saved server into a way of reaching it.
///
/// This is where the stored configuration and the transport protocol meet, and
/// it is deliberately the only place that happens: every other layer sees
/// either a `Server` row or an `SSHTransport`, never both. Adding a new kind of
/// route -- a second VPN, a different proxy -- changes this file alone.
public struct Connector: Sendable {
    private let store: Store
    private let vault: Vault
    /// How to reach the outside world at all. The campus VPN, when there is
    /// one, wraps everything else.
    private let outermost: any SSHTransport

    public init(store: Store, vault: Vault, over outermost: any SSHTransport = DirectTransport()) {
        self.store = store
        self.vault = vault
        self.outermost = outermost
    }

    public enum Failure: Error, CustomStringConvertible {
        case noCredential(server: String)
        case unknownJumpHost(id: Int64)
        case jumpLoop(server: String)

        public var description: String {
            switch self {
            case .noCredential(let s): "\(s) has no credential"
            case .unknownJumpHost(let id): "jump host \(id) no longer exists"
            case .jumpLoop(let s): "\(s) is reachable only through itself"
            }
        }
    }

    /// Builds the transport for a server, innermost hop last.
    ///
    /// Reading outward: the campus VPN, then the server's proxy, then any jump
    /// hosts. Each layer only knows it produces a connected descriptor, which
    /// is why they compose in any order without special cases.
    public func transport(for server: Server, visited: Set<Int64> = []) async throws -> any SSHTransport {
        var visited = visited
        if let id = server.id {
            guard visited.insert(id).inserted else { throw Failure.jumpLoop(server: server.name) }
        }

        var route = outermost

        if let kind = server.proxyKind, let host = server.proxyHost, let port = server.proxyPort {
            let password = try await proxyPassword(for: server)
            route = switch kind {
            case .socks5:
                SOCKS5Transport(proxyHost: host, proxyPort: UInt16(port),
                                username: server.proxyUsername, password: password,
                                over: route)
            case .httpConnect:
                HTTPConnectTransport(proxyHost: host, proxyPort: UInt16(port),
                                     username: server.proxyUsername, password: password,
                                     over: route)
            }
        }

        if let jumpID = server.jumpHostId {
            guard let jump = try await store.server(id: jumpID) else {
                throw Failure.unknownJumpHost(id: jumpID)
            }
            // The jump host is reached the same way anything else is --
            // recursively, so a chain of gateways needs no extra machinery.
            let jumpRoute = try await transport(for: jump, visited: visited)
            route = JumpHostTransport(
                through: jump, credentials: try await credentials(for: jump),
                over: jumpRoute)
        }

        return route
    }

    /// How to log in, decrypted only now.
    ///
    /// The kind travels with the secret because the two are useless apart: a
    /// private key offered as a password fails with "authentication failed"
    /// and no indication that the wrong method was tried.
    public struct Login: Sendable {
        public var username: String
        public var secret: String
        public var kind: Credential.Kind

        public init(username: String, secret: String, kind: Credential.Kind) {
            self.username = username
            self.secret = secret
            self.kind = kind
        }
    }

    public func credentials(for server: Server) async throws -> Login {
        guard let credentialID = server.credentialId,
              let credential = try await store.credential(id: credentialID)
        else { throw Failure.noCredential(server: server.name) }

        let secret = try await vault.openText(credential.sealed, context: credential.context)
        return Login(username: credential.username ?? server.username,
                     secret: secret, kind: credential.kind)
    }

    private func proxyPassword(for server: Server) async throws -> String? {
        guard let sealed = server.proxySealed else { return nil }
        return try await vault.openText(sealed, context: "proxy.password")
    }
}

public extension SSHSession {
    /// Logs in with whichever kind of credential was configured.
    func authenticate(_ login: Connector.Login) async throws {
        switch login.kind {
        case .password:
            try await authenticate(username: login.username, password: login.secret)
        case .privateKey:
            try await authenticate(username: login.username, privateKey: login.secret)
        }
    }
}

/// Reaches a host through another SSH server.
///
/// The outer session opens a `direct-tcpip` channel, and a socketpair turns
/// that channel into an ordinary descriptor -- so the inner session performs a
/// completely normal handshake and never learns it is nested. That is what lets
/// jump hosts chain without each layer knowing the depth.
public struct JumpHostTransport: SSHTransport {
    let jump: Server
    let credentials: Connector.Login
    let inner: any SSHTransport

    public init(through jump: Server, credentials: Connector.Login,
                over inner: any SSHTransport) {
        self.jump = jump
        self.credentials = credentials
        self.inner = inner
    }

    public var pathDescription: String {
        "jump \(jump.host):\(jump.port) -> \(inner.pathDescription)"
    }

    public func connect(host: String, port: UInt16) async throws -> Int32 {
        let session = SSHSession()
        try await session.connect(to: jump.host, port: UInt16(jump.port), over: inner)
        try await session.authenticate(credentials)
        return try await session.bridgeDirectTCPIP(host: host, port: port)
    }
}
