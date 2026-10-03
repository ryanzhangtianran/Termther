import Foundation
import Testing
@testable import Core

@Test("a vault round-trips secrets")
func vaultRoundTrip() async throws {
    let vault = Vault()
    _ = try await vault.create(password: "correct horse")

    let sealed = try await vault.seal("hunter2", context: "password")
    #expect(sealed.ciphertext != Data("hunter2".utf8), "the secret was not encrypted")
    #expect(try await vault.openText(sealed, context: "password") == "hunter2")
}

@Test("a locked vault refuses to do anything with secrets")
func lockedVaultRefuses() async throws {
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    let sealed = try await vault.seal("secret", context: "password")

    await vault.lock()
    #expect(await !vault.isUnlocked)
    await #expect(throws: Vault.Failure.locked) { _ = try await vault.seal("x", context: "password") }
    await #expect(throws: Vault.Failure.locked) { _ = try await vault.open(sealed, context: "password") }
}

@Test("the wrong password is rejected, not merely unhelpful")
func wrongPassword() async throws {
    let creator = Vault()
    let metadata = try await creator.create(password: "right")

    let opener = Vault()
    await #expect(throws: Vault.Failure.wrongPassword) {
        try await opener.unlock(password: "wrong", metadata: metadata)
    }
    try await opener.unlock(password: "right", metadata: metadata)
    #expect(await opener.isUnlocked)
}

@Test("secrets survive a lock and a fresh unlock")
func unlockRestoresAccess() async throws {
    let creator = Vault()
    let metadata = try await creator.create(password: "pw")
    let sealed = try await creator.seal("private key material", context: "credential")

    let reopened = Vault()
    try await reopened.unlock(password: "pw", metadata: metadata)
    #expect(try await reopened.openText(sealed, context: "credential") == "private key material")
}

@Test("a secret cannot be opened as a different kind of secret")
func contextIsBinding() async throws {
    // The context is authenticated, so moving a value between columns fails
    // loudly rather than being read as something it is not.
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    let sealed = try await vault.seal("s3cret", context: "password")

    await #expect(throws: (any Error).self) {
        _ = try await vault.open(sealed, context: "github-token")
    }
}

@Test("biometric unlock uses the data key and still verifies the vault")
func biometricUnlock() async throws {
    let vault = Vault()
    let metadata = try await vault.create(password: "pw")
    let sealed = try await vault.seal("token", context: "github-token")
    let dataKey = try await vault.exportDataKey()

    // What Touch ID does: skip the password, present the key from the keychain.
    let reopened = Vault()
    try await reopened.unlock(dataKey: dataKey, metadata: metadata)
    #expect(try await reopened.openText(sealed, context: "github-token") == "token")

    // A key belonging to some other vault must not open this one.
    let other = Vault()
    _ = try await other.create(password: "other")
    let foreign = try await other.exportDataKey()
    let third = Vault()
    await #expect(throws: Vault.Failure.self) {
        try await third.unlock(dataKey: foreign, metadata: metadata)
    }
}

@Test("two vaults with the same password do not share a key")
func saltsDiffer() async throws {
    let a = Vault(), b = Vault()
    let first = try await a.create(password: "same")
    let second = try await b.create(password: "same")
    #expect(first.salt != second.salt)
    #expect(first.wrappedDataKey != second.wrappedDataKey)

    // And a secret from one is unreadable by the other.
    let sealed = try await a.seal("mine", context: "password")
    await #expect(throws: (any Error).self) { _ = try await b.open(sealed, context: "password") }
}

@Test("sealing the same text twice produces different ciphertext")
func noncesAreUnique() async throws {
    // A repeated nonce with the same key destroys AES-GCM's guarantees, so
    // this is worth asserting rather than assuming.
    let vault = Vault()
    _ = try await vault.create(password: "pw")
    let first = try await vault.seal("same", context: "password")
    let second = try await vault.seal("same", context: "password")
    #expect(first.nonce != second.nonce)
    #expect(first.ciphertext != second.ciphertext)
}
