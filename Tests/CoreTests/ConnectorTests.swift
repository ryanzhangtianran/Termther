import Foundation
import Net
import Testing
@testable import Core

/// Builds the store and vault a connector needs.
private func fixture() async throws -> (Store, Vault, Connector) {
    let store = try Store(inMemory: true)
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    return (store, vault, Connector(store: store, vault: vault))
}

private func saveServer(_ store: Store, _ vault: Vault, name: String,
                        host: String) async throws -> Server {
    let credential = try await store.save(Credential(
        name: "\(name) password", kind: .password,
        sealed: try await vault.seal("secret-\(name)", context: "credential.password")))
    var server = Server(name: name, host: host, username: "me")
    server.credentialId = credential.id
    return try await store.save(server)
}

@Test("a plain server dials directly")
func directRoute() async throws {
    let (store, vault, connector) = try await fixture()
    let server = try await saveServer(store, vault, name: "plain", host: "example.com")

    let route = try await connector.transport(for: server)
    #expect(route.pathDescription == "direct")
}

@Test("credentials are decrypted only when a connection is actually made")
func credentialsDecryptedLate() async throws {
    let (store, vault, connector) = try await fixture()
    let server = try await saveServer(store, vault, name: "host", host: "h")

    // Everything the store handed back was ciphertext; only now does it become
    // a password.
    let login = try await connector.credentials(for: server)
    #expect(login.username == "me")
    #expect(login.secret == "secret-host")
    // The kind travels with the secret: a key offered as a password fails with
    // nothing to say which method was even tried.
    #expect(login.kind == .password)

    // And a locked vault cannot produce one at all.
    await vault.lock()
    await #expect(throws: Vault.Failure.locked) {
        _ = try await connector.credentials(for: server)
    }
}

@Test("a server with no credential says so instead of connecting anonymously")
func missingCredential() async throws {
    let (store, _, connector) = try await fixture()
    let server = try await store.save(Server(name: "bare", host: "h", username: "me"))
    await #expect(throws: Connector.Failure.self) {
        _ = try await connector.credentials(for: server)
    }
}

@Test("a proxy wraps the dial, outermost first")
func proxyRoute() async throws {
    let (store, vault, connector) = try await fixture()
    var server = try await saveServer(store, vault, name: "behind-proxy", host: "h")
    server.proxyKind = .socks5
    server.proxyHost = "127.0.0.1"
    server.proxyPort = 1080
    server = try await store.save(server)

    let route = try await connector.transport(for: server)
    #expect(route.pathDescription == "SOCKS5 127.0.0.1:1080 -> direct")
}

@Test("a jump host becomes another layer, and chains")
func jumpChain() async throws {
    let (store, vault, connector) = try await fixture()
    let outer = try await saveServer(store, vault, name: "gateway", host: "gw.example")
    var middle = try await saveServer(store, vault, name: "bastion", host: "bastion.internal")
    middle.jumpHostId = outer.id
    middle = try await store.save(middle)
    var target = try await saveServer(store, vault, name: "hpc", host: "10.0.0.5")
    target.jumpHostId = middle.id
    target = try await store.save(target)

    // Read outward: the last hop first, the first hop last.
    let route = try await connector.transport(for: target)
    #expect(route.pathDescription == "jump bastion.internal:22 -> jump gw.example:22 -> direct")
}

@Test("a jump host cycle is refused rather than recursed into")
func jumpLoopIsCaught() async throws {
    // Two servers naming each other is easy to create by accident in a UI, and
    // would otherwise recurse until the stack ran out.
    let (store, vault, connector) = try await fixture()
    var a = try await saveServer(store, vault, name: "a", host: "a")
    var b = try await saveServer(store, vault, name: "b", host: "b")
    a.jumpHostId = b.id
    a = try await store.save(a)
    b.jumpHostId = a.id
    b = try await store.save(b)

    await #expect(throws: Connector.Failure.self) { _ = try await connector.transport(for: a) }
}

@Test("a deleted jump host is reported, not silently ignored")
func danglingJumpHost() async throws {
    let (store, vault, connector) = try await fixture()
    let jump = try await saveServer(store, vault, name: "gone", host: "gw")
    var target = try await saveServer(store, vault, name: "target", host: "t")
    target.jumpHostId = jump.id
    target = try await store.save(target)

    // Deleting through the store clears the reference, so force the dangling
    // case the way a restored backup or a hand-edited file would.
    try await store.delete(serverID: #require(jump.id))
    var orphan = target
    orphan.jumpHostId = 999_999
    await #expect(throws: Connector.Failure.self) {
        _ = try await connector.transport(for: orphan)
    }
}

@Test("an outer transport wraps everything, which is how the campus VPN fits")
func outermostTransportWraps() async throws {
    let store = try Store(inMemory: true)
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    // Stand in for the VPN: any transport at all, as far as this layer knows.
    let connector = Connector(store: store, vault: vault,
                              over: SOCKS5Transport(proxyHost: "vpn", proxyPort: 1080))

    var server = try await saveServer(store, vault, name: "inside", host: "10.0.0.5")
    server.jumpHostId = try await saveServer(store, vault, name: "gw", host: "gw").id
    server = try await store.save(server)

    let route = try await connector.transport(for: server)
    #expect(route.pathDescription == "jump gw:22 -> SOCKS5 vpn:1080 -> direct")
}

@Test("a key credential is reported as a key, not as a password")
func keyCredentialKeepsItsKind() async throws {
    // An imported ssh-config server carries a private key. Offering it as a
    // password is what produced "authentication failed (username/password)"
    // against a server that would have accepted the key.
    let (store, vault, connector) = try await fixture()
    let credential = try await store.save(Credential(
        name: "id_ed25519", kind: .privateKey,
        sealed: try await vault.seal("-----BEGIN OPENSSH PRIVATE KEY-----",
                                     context: "credential.privateKey")))
    var server = Server(name: "keyed", host: "h", username: "me")
    server.credentialId = credential.id
    server = try await store.save(server)

    let login = try await connector.credentials(for: server)
    #expect(login.kind == .privateKey)
    #expect(login.secret.hasPrefix("-----BEGIN"))
}

@Test("a credential's own username wins over the server's")
func credentialUsernameOverrides() async throws {
    // A shared key often belongs to a different account than the one the
    // server row was created with.
    let (store, vault, connector) = try await fixture()
    var credential = Credential(
        name: "shared", kind: .privateKey,
        sealed: try await vault.seal("KEY", context: "credential.privateKey"))
    credential.username = "deploy"
    let saved = try await store.save(credential)

    var server = Server(name: "h", host: "h", username: "me")
    server.credentialId = saved.id
    server = try await store.save(server)

    #expect(try await connector.credentials(for: server).username == "deploy")
}
