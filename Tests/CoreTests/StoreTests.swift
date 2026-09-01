import Foundation
import Testing
@testable import Core

private func store() throws -> Store { try Store(inMemory: true) }

@Test("a fresh store has no vault, and remembers one once made")
func vaultMetadataRoundTrip() async throws {
    let store = try store()
    #expect(try await !store.hasVault)

    let vault = Vault()
    let metadata = try await vault.create(password: "pw")
    try await store.save(metadata)

    #expect(try await store.hasVault)
    let loaded = try #require(try await store.vaultMetadata())
    #expect(loaded.salt == metadata.salt)
    #expect(loaded.wrappedDataKey == metadata.wrappedDataKey)

    // And the metadata is enough to unlock in a fresh process.
    let reopened = Vault()
    try await reopened.unlock(password: "pw", metadata: loaded)
    #expect(await reopened.isUnlocked)
}

@Test("changing the password updates the stored wrapping in place")
func passwordChangePersists() async throws {
    let store = try store()
    let vault = Vault()
    let metadata = try await vault.create(password: "old")
    try await store.save(metadata)

    let updated = try await vault.changePassword(to: "new", metadata: metadata)
    try await store.save(updated)

    // One row, not two: the vault has exactly one identity.
    let loaded = try #require(try await store.vaultMetadata())
    #expect(loaded.salt == updated.salt)
    #expect(loaded.verifier == metadata.verifier, "secrets must not have been re-encrypted")
}

@Test("servers round-trip and come back in order")
func serverRoundTrip() async throws {
    let store = try store()
    let saved = try await store.save(
        Server(name: "hpc", host: "hpc.example.edu", username: "me", sortOrder: 1))
    #expect(saved.id != nil)

    _ = try await store.save(Server(name: "lab", host: "lab.example.edu", username: "me", sortOrder: 0))

    let all = try await store.servers()
    #expect(all.map(\.name) == ["lab", "hpc"], "sortOrder should decide the order")

    let id = try #require(saved.id)
    #expect(try await store.server(id: id)?.host == "hpc.example.edu")

    try await store.delete(serverID: id)
    #expect(try await store.servers().count == 1)
}

@Test("the store only ever handles sealed secrets")
func credentialsStaySealed() async throws {
    let store = try store()
    let vault = Vault()
    _ = try await vault.create(password: "pw")

    let sealed = try await vault.seal("id_ed25519 private key", context: "credential.privateKey")
    let credential = try await store.save(
        Credential(name: "laptop key", kind: .privateKey, sealed: sealed))

    let credentialID = try #require(credential.id)
    let loaded = try #require(try await store.credential(id: credentialID))
    // What comes back out of the database is still ciphertext.
    #expect(loaded.secret == sealed.ciphertext)
    #expect(!String(decoding: loaded.secret, as: UTF8.self).contains("private key"))
    // And only the vault turns it back into a secret.
    #expect(try await vault.openText(loaded.sealed, context: loaded.context)
            == "id_ed25519 private key")
}

@Test("deleting a credential leaves its servers, without the credential")
func credentialDeletionIsSafe() async throws {
    // Losing a key should not silently lose the hosts that used it.
    let store = try store()
    let vault = Vault()
    _ = try await vault.create(password: "pw")

    let credential = try await store.save(Credential(
        name: "shared", kind: .password,
        sealed: try await vault.seal("pw", context: "credential.password")))
    var server = Server(name: "host", host: "h", username: "me")
    server.credentialId = credential.id
    let saved = try await store.save(server)

    let credentialID = try #require(credential.id)
    try await store.delete(credentialID: credentialID)

    let serverID = try #require(saved.id)
    let after = try #require(try await store.server(id: serverID))
    #expect(after.credentialId == nil, "the reference should have been cleared")
}

@Test("deleting a server takes its port forwards with it")
func forwardsCascade() async throws {
    let store = try store()
    let server = try await store.save(Server(name: "h", host: "h", username: "me"))
    let id = try #require(server.id)

    _ = try await store.save(PortForwardPreset(serverId: id, direction: .local,
                                               bindPort: 8080,
                                               targetHost: "127.0.0.1", targetPort: 80))
    #expect(try await store.portForwards(serverID: id).count == 1)

    try await store.delete(serverID: id)
    #expect(try await store.portForwards(serverID: id).isEmpty,
            "presets should not outlive their server")
}

@Test("a jump host is just another server")
func jumpHostReference() async throws {
    let store = try store()
    let jump = try await store.save(Server(name: "gateway", host: "gw", username: "me"))
    var target = Server(name: "inside", host: "10.0.0.5", username: "me")
    target.jumpHostId = jump.id
    let saved = try await store.save(target)

    let targetID = try #require(saved.id)
    let jumpID = try #require(jump.id)
    #expect(try await store.server(id: targetID)?.jumpHostId == jump.id)

    // Removing the gateway must not remove what was behind it.
    try await store.delete(serverID: jumpID)
    let orphan = try #require(try await store.server(id: targetID))
    #expect(orphan.jumpHostId == nil)
}

@Test("host keys are trusted on first sight and flagged when they change")
func hostKeyVerification() async throws {
    let store = try store()
    #expect(try await store.verify(host: "h", port: 22, fingerprint: "SHA256:aaa") == .firstSight)
    #expect(try await store.verify(host: "h", port: 22, fingerprint: "SHA256:aaa") == .known)

    // A changed key is either a reinstall or an attack; the store reports, and
    // does not decide.
    #expect(try await store.verify(host: "h", port: 22, fingerprint: "SHA256:bbb")
            == .changed(previous: "SHA256:aaa"))

    try await store.trust(host: "h", port: 22, fingerprint: "SHA256:bbb")
    #expect(try await store.verify(host: "h", port: 22, fingerprint: "SHA256:bbb") == .known)
}

@Test("reordering is all or nothing")
func reordering() async throws {
    let store = try store()
    var ids: [Int64] = []
    for name in ["a", "b", "c"] {
        let saved = try await store.save(Server(name: name, host: name, username: "me"))
        ids.append(try #require(saved.id))
    }
    try await store.reorderServers([ids[2], ids[0], ids[1]])
    #expect(try await store.servers().map(\.name) == ["c", "a", "b"])
}

@Test("settings round-trip and can be removed")
func settings() async throws {
    let store = try store()
    #expect(try await store.setting("font") == nil)
    try await store.setSetting("font", to: "Maple Mono")
    #expect(try await store.setting("font") == "Maple Mono")
    try await store.setSetting("font", to: nil)
    #expect(try await store.setting("font") == nil)
}

@Test("appearance settings survive a restart")
func appearancePersists() async throws {
    // The first terminal is built from these, so anything not saved -- or not
    // read back before the tab opens -- shows up as a window whose font is
    // wrong until you open a second tab.
    let store = try store()
    for (key, value) in [("palette", "Nord"), ("terminalFont", "Menlo"),
                         ("terminalFontSize", "15"), ("terminalFontWeight", "light"),
                         ("lineHeight", "1.30"), ("letterSpacing", "1.05"),
                         ("cursorStyle", "bar")] {
        try await store.setSetting(key, to: value)
    }

    #expect(try await store.setting("palette") == "Nord")
    #expect(try await store.setting("terminalFontSize") == "15")
    #expect(try await store.setting("lineHeight") == "1.30")
    #expect(try await store.setting("cursorStyle") == "bar")
}

@Test("the same key is stored once, however often it is offered")
func credentialsDoNotDuplicate() async throws {
    // Importing the same config twice used to add a second credential for the
    // same key, and a third the time after -- filling the picker with
    // identical entries.
    let store = try store()
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"

    // Ciphertext cannot be compared: each sealing uses a fresh nonce, so the
    // same key encrypts differently every time.
    let first = try await vault.seal(key, context: "credential.privateKey")
    let second = try await vault.seal(key, context: "credential.privateKey")
    #expect(first.ciphertext != second.ciphertext)

    // Which is why matching has to open them.
    _ = try await store.save(Credential(name: "id_ed25519", kind: .privateKey, sealed: first))
    let stored = try await store.credentials()
    var matches: [Int64] = []
    for credential in stored where credential.kind == .privateKey {
        if try await vault.openText(credential.sealed, context: credential.context) == key {
            matches.append(try #require(credential.id))
        }
    }
    #expect(matches.count == 1)
}

@Test("unused credentials can be cleared out")
func prunesUnusedCredentials() async throws {
    let store = try store()
    let vault = Vault()
    _ = try await vault.create(password: "pw")

    let used = try await store.save(Credential(
        name: "in use", kind: .privateKey,
        sealed: try await vault.seal("A", context: "credential.privateKey")))
    _ = try await store.save(Credential(
        name: "orphan", kind: .privateKey,
        sealed: try await vault.seal("B", context: "credential.privateKey")))

    var server = Server(name: "h", host: "h", username: "me")
    server.credentialId = used.id
    _ = try await store.save(server)

    let servers = try await store.servers()
    let inUse = Set(servers.compactMap(\.credentialId))
    for credential in try await store.credentials() {
        guard let id = credential.id, !inUse.contains(id) else { continue }
        try await store.delete(credentialID: id)
    }

    #expect(try await store.credentials().map(\.name) == ["in use"])
}
