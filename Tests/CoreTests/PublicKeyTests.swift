import Foundation
import Testing
@testable import Core

/// Listing the public keys in a `.ssh` directory.
struct PublicKeyTests {
    @Test("a public key line is read whole, named after its file")
    func parse() throws {
        let key = try #require(SSHKeys.PublicKey.parse(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI ryan@mac (Termther)\n", path: "/x/work.pub"))
        #expect(key.name == "work")
        #expect(key.text == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI ryan@mac (Termther)")
    }

    @Test("files that are not public keys are skipped, and the private half is found")
    func listing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "ssh-rsa AAAAB3 b@host".write(to: directory.appending(path: "b.pub"),
                                         atomically: true, encoding: .utf8)
        try "-----BEGIN OPENSSH PRIVATE KEY-----".write(to: directory.appending(path: "b"),
                                                        atomically: true, encoding: .utf8)
        try "ecdsa-sha2-nistp256 AAAAE2 a@host".write(to: directory.appending(path: "a.pub"),
                                                      atomically: true, encoding: .utf8)
        try "not a key".write(to: directory.appending(path: "notes.pub"),
                              atomically: true, encoding: .utf8)

        let keys = SSHKeys.publicKeys(in: directory)
        #expect(keys.map(\.name) == ["a", "b"])
        #expect(keys[0].privateKeyPath == nil)
        #expect(keys[1].privateKeyPath == directory.appending(path: "b").path)
    }
}

@Test("a key generated into a directory is listed there, keeps a taken name free, and goes with both halves on removal")
func generateAndRemove() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try await SSHKeys.generate(kind: .ed25519, name: "Work", comment: "test", in: directory)
    #expect(first.publicKeyPath == directory.appending(path: "work_id_ed25519.pub").path)
    #expect(first.privateKey.contains("PRIVATE KEY"))
    let keys = SSHKeys.publicKeys(in: directory)
    #expect(keys.map(\.name) == ["work_id_ed25519"])
    #expect(keys[0].text.hasPrefix("ssh-ed25519 ") && keys[0].text.hasSuffix(" test"))
    #expect(SSHKeys.discover(in: directory).map(\.lastPathComponent) == ["work_id_ed25519"])

    // The same name again is numbered, not written over.
    let second = try await SSHKeys.generate(kind: .ed25519, name: "Work", comment: "test", in: directory)
    #expect(second.publicKeyPath.hasSuffix("work_id_ed25519-2.pub"))

    try SSHKeys.remove(keys[0])
    #expect(SSHKeys.publicKeys(in: directory).map(\.name) == ["work_id_ed25519-2"])
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "work_id_ed25519").path))
}

@Test("a private key with no .pub beside it is listed too, its public line worked out from it")
func privateKeyAlone() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let pair = try await SSHKeys.generate(kind: .ed25519, name: "Lab", comment: "test", in: directory)
    try FileManager.default.removeItem(atPath: pair.publicKeyPath)
    let privatePath = String(pair.publicKeyPath.dropLast(".pub".count))

    let keys = SSHKeys.publicKeys(in: directory)
    #expect(keys.map(\.path) == [privatePath])
    // ssh-keygen -y gives the line without the comment.
    #expect(pair.publicKey.hasPrefix(try #require(keys.first?.text)))
    #expect(keys.first?.text.isEmpty == false)
}
