import Foundation
import Testing
@testable import Core

@Test("a config entry becomes a server")
func parsesEntries() {
    let hosts = SSHConfig.parse("""
    Host hpc
        HostName hpc.example.edu
        User tzhang
        Port 2222
        IdentityFile ~/.ssh/id_ed25519

    Host lab
        HostName 10.0.0.5
    """)

    #expect(hosts.count == 2)
    #expect(hosts[0].alias == "hpc")
    #expect(hosts[0].address == "hpc.example.edu")
    #expect(hosts[0].port == 2222)
    #expect(hosts[0].user == "tzhang")
    #expect(hosts[0].identityFile?.hasSuffix("/.ssh/id_ed25519") == true)
    #expect(hosts[0].identityFile?.hasPrefix("~") == false, "the tilde should be expanded")

    // Defaults where the entry is silent.
    #expect(hosts[1].port == 22)
    #expect(hosts[1].user.isEmpty)
}

@Test("a bare entry uses its own name as the address")
func aliasIsTheAddress() {
    // `Host example.com` with nothing else is a valid, common entry.
    let hosts = SSHConfig.parse("Host example.com\n    User me")
    #expect(hosts.first?.address == "example.com")
}

@Test("patterns are rules, not destinations")
func patternsAreSkipped() {
    // `Host *` sets defaults for everything; it is not somewhere to connect.
    let hosts = SSHConfig.parse("""
    Host *
        ServerAliveInterval 60

    Host real
        HostName real.example
    """)
    #expect(hosts.map(\.alias) == ["real"])
}

@Test("keywords are case-insensitive and comments are ignored")
func tolerantParsing() {
    let hosts = SSHConfig.parse("""
    # a comment
    HOST gateway
        hostname   gw.example
        PORT 2200
    """)
    #expect(hosts.first?.address == "gw.example")
    #expect(hosts.first?.port == 2200)
}

@Test("ProxyJump becomes a jump host once both ends are imported")
func importsProxyJump() async throws {
    // The jump host may be named after the entry that uses it, so the link is
    // made in a second pass rather than as each entry is read.
    let store = try Store(inMemory: true)
    let hosts = SSHConfig.parse("""
    Host inside
        HostName 10.0.0.9
        User me
        ProxyJump gateway

    Host gateway
        HostName gw.example
        User me
    """)

    try await store.importHosts(hosts)
    let servers = try await store.servers()
    let inside = try #require(servers.first { $0.name == "inside" })
    let gateway = try #require(servers.first { $0.name == "gateway" })
    #expect(inside.jumpHostId == gateway.id)
}

@Test("importing reports what is already saved rather than duplicating it")
func classifiesBeforeImporting() async throws {
    let store = try Store(inMemory: true)
    _ = try await store.save(Server(name: "known", host: "known.example", username: "me"))

    let classified = try await store.classify(SSHConfig.parse("""
    Host known
        HostName known.example

    Host fresh
        HostName fresh.example
    """))

    #expect(classified.first { $0.host.alias == "known" }?.outcome == .alreadySaved)
    #expect(classified.first { $0.host.alias == "fresh" }?.outcome == .new)
}

@Test("an entry with no IdentityFile still resolves to the key ssh would use")
func fallsBackToDefaultKey() {
    // Most config entries name no key at all and rely on ssh trying the
    // standard names. Importing without that fallback leaves every such
    // server unable to log in, reported as having no credential.
    let host = SSHConfig.Host(alias: "plain", hostName: "example", port: 22, user: "me")

    let directory = URL.homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)
    let defaults = ["id_ed25519", "id_ecdsa", "id_rsa"]
        .map { directory.appending(path: $0).path }
        .filter { FileManager.default.fileExists(atPath: $0) }

    if let expected = defaults.first {
        #expect(host.effectiveIdentityFile == expected)
    } else {
        #expect(host.effectiveIdentityFile == nil, "no default key exists to fall back to")
    }
}

@Test("a named IdentityFile that no longer exists falls back too")
func missingIdentityFileFallsBack() {
    var host = SSHConfig.Host(alias: "stale", hostName: "example", port: 22, user: "me")
    host.identityFile = "/nowhere/id_missing"
    // Either a real default was found, or there is none -- but never the path
    // that is not there.
    #expect(host.effectiveIdentityFile != "/nowhere/id_missing")
}

@Test("one key file becomes one credential, however many servers use it")
func keysAreSharedAcrossServers() async throws {
    let store = try Store(inMemory: true)
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    let key = try await store.save(Credential(
        name: "id_ed25519", kind: .privateKey,
        sealed: try await vault.seal("KEY", context: "credential.privateKey")))
    let keyID = try #require(key.id)

    let hosts = SSHConfig.parse("""
    Host a
        HostName a.example
    Host b
        HostName b.example
    """)
    // Both entries use the same key file, so both point at the same credential
    // rather than storing it twice.
    try await store.importHosts(hosts, credentials: ["a": keyID, "b": keyID])

    let servers = try await store.servers()
    #expect(servers.count == 2)
    #expect(servers.allSatisfy { $0.credentialId == keyID })
    #expect(try await store.credentials().count == 1)
}

@Test("a tags comment becomes tags, and ssh still sees a valid file")
func parsesTagComments() {
    // ssh has no notion of tags but ignores comments, so a file carrying them
    // is still one `ssh` will read.
    let hosts = SSHConfig.parse("""
    Host gpu-01
        # tags: cluster, gpu
        HostName 10.0.1.1
        User me

    Host plain
        HostName 10.0.1.2
    """)

    #expect(hosts[0].tags == ["cluster", "gpu"])
    #expect(hosts[1].tags.isEmpty)
}

@Test("tags reach the saved server")
func importsTags() async throws {
    let store = try Store(inMemory: true)
    try await store.importHosts(SSHConfig.parse("""
    Host gpu-01
        #tags: cluster,gpu
        HostName 10.0.1.1
    """))

    let server = try #require(try await store.servers().first)
    #expect(server.tagList == ["cluster", "gpu"])
}

@Test("a hundred entries import in one go, with their jump hosts intact")
func importsAtScale() async throws {
    // Writing them out in a file is the point of this path; it has to hold up
    // at the size that makes it worth doing.
    var text = """
    Host gateway
        HostName gw.example
        User me

    """
    for index in 1...100 {
        text += """
        Host node-\(index)
            # tags: cluster
            HostName 10.0.0.\(index)
            User me
            ProxyJump gateway

        """
    }

    let hosts = SSHConfig.parse(text)
    #expect(hosts.count == 101)

    let store = try Store(inMemory: true)
    try await store.importHosts(hosts)

    let servers = try await store.servers()
    #expect(servers.count == 101)
    let gateway = try #require(servers.first { $0.name == "gateway" })
    let nodes = servers.filter { $0.name.hasPrefix("node-") }
    #expect(nodes.count == 100)
    #expect(nodes.allSatisfy { $0.jumpHostId == gateway.id })
    #expect(nodes.allSatisfy { $0.tagList == ["cluster"] })
}
