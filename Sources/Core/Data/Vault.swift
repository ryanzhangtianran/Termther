import CommonCrypto
import CryptoKit
import Foundation

/// Encrypts the things that must never be readable from the database file.
///
/// The design is deliberately not "encrypt the database". The store stays an
/// ordinary SQLite file -- inspectable, repairable, copyable -- and only the
/// secrets inside it are ciphertext. Someone who takes the file gets the server
/// list and nothing that lets them log in.
///
/// Keys are layered so the password can change without re-encrypting anything:
///
///     password ──PBKDF2──> wrapping key ──unwraps──> data key ──> every secret
///
/// Changing the password rewraps the data key alone. Biometric unlock keeps a
/// copy of the data key in the keychain, which is why it can skip the password
/// without weakening anything else.
public actor Vault {
    /// Encrypted bytes, with the nonce that produced them.
    public struct Sealed: Sendable, Equatable, Codable {
        public var ciphertext: Data
        public var nonce: Data

        public init(ciphertext: Data, nonce: Data) {
            self.ciphertext = ciphertext
            self.nonce = nonce
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case locked
        case wrongPassword
        case notInitialised
        case alreadyInitialised
        case corrupt(String)

        public var description: String {
            switch self {
            case .locked: "the vault is locked"
            case .wrongPassword: "wrong password"
            case .notInitialised: "no vault has been created yet"
            case .alreadyInitialised: "a vault already exists"
            case .corrupt(let what): "the vault is damaged: \(what)"
            }
        }
    }

    /// What is persisted to unlock the vault later. Contains no secret: without
    /// the password none of it is useful.
    public struct Metadata: Sendable, Equatable, Codable {
        public var version: Int
        public var salt: Data
        public var wrappedDataKey: Sealed
        /// Known plaintext, sealed with the data key, so a wrong password is
        /// detected immediately rather than by producing garbage later.
        public var verifier: Sealed
        public var createdAt: Date
    }

    /// PBKDF2 rounds. High enough to cost a fraction of a second here and a
    /// great deal more to a machine trying every password.
    static let iterations = 600_000
    static let verifierPlaintext = "termther vault v1"

    private var dataKey: SymmetricKey?

    public init() {}

    public var isUnlocked: Bool { dataKey != nil }

    // MARK: - lifecycle

    /// Creates a vault, returning what to store.
    public func create(password: String) throws -> Metadata {
        guard dataKey == nil else { throw Failure.alreadyInitialised }

        let salt = Self.randomBytes(32)
        let wrappingKey = try Self.deriveKey(password: password, salt: salt)
        let dataKey = SymmetricKey(size: .bits256)

        let metadata = Metadata(
            version: 1,
            salt: salt,
            wrappedDataKey: try Self.seal(dataKey.rawBytes, with: wrappingKey, context: "vault-key"),
            verifier: try Self.seal(Data(Self.verifierPlaintext.utf8), with: dataKey, context: "verifier"),
            createdAt: Date())

        self.dataKey = dataKey
        return metadata
    }

    public func unlock(password: String, metadata: Metadata) throws {
        let wrappingKey = try Self.deriveKey(password: password, salt: metadata.salt)
        guard let keyBytes = try? Self.open(metadata.wrappedDataKey, with: wrappingKey, context: "vault-key")
        else { throw Failure.wrongPassword }

        let candidate = SymmetricKey(data: keyBytes)
        guard let verifier = try? Self.open(metadata.verifier, with: candidate, context: "verifier"),
              String(decoding: verifier, as: UTF8.self) == Self.verifierPlaintext
        else { throw Failure.corrupt("the verifier does not match its own key") }

        dataKey = candidate
    }

    /// Unlocks from a data key held elsewhere -- the keychain, after Touch ID.
    public func unlock(dataKey key: Data, metadata: Metadata) throws {
        let candidate = SymmetricKey(data: key)
        guard let verifier = try? Self.open(metadata.verifier, with: candidate, context: "verifier"),
              String(decoding: verifier, as: UTF8.self) == Self.verifierPlaintext
        else { throw Failure.corrupt("the stored key does not match this vault") }
        dataKey = candidate
    }

    public func lock() { dataKey = nil }

    /// The data key, for handing to the keychain when biometric unlock is
    /// switched on. Nothing else should ever ask for it.
    public func exportDataKey() throws -> Data {
        guard let dataKey else { throw Failure.locked }
        return dataKey.rawBytes
    }

    /// Changes the password without touching a single encrypted secret: only
    /// the wrapping of the data key changes.
    public func changePassword(to password: String, metadata: Metadata) throws -> Metadata {
        guard let dataKey else { throw Failure.locked }
        let salt = Self.randomBytes(32)
        let wrappingKey = try Self.deriveKey(password: password, salt: salt)

        var updated = metadata
        updated.salt = salt
        updated.wrappedDataKey = try Self.seal(dataKey.rawBytes, with: wrappingKey, context: "vault-key")
        return updated
    }

    // MARK: - secrets

    /// Encrypts a secret.
    ///
    /// `context` is bound into the ciphertext, so a value sealed as one kind of
    /// secret cannot be silently opened as another -- a password moved into the
    /// token column fails to decrypt rather than being read as a token.
    public func seal(_ plaintext: Data, context: String) throws -> Sealed {
        guard let dataKey else { throw Failure.locked }
        return try Self.seal(plaintext, with: dataKey, context: context)
    }

    public func seal(_ text: String, context: String) throws -> Sealed {
        try seal(Data(text.utf8), context: context)
    }

    public func open(_ sealed: Sealed, context: String) throws -> Data {
        guard let dataKey else { throw Failure.locked }
        return try Self.open(sealed, with: dataKey, context: context)
    }

    public func openText(_ sealed: Sealed, context: String) throws -> String {
        String(decoding: try open(sealed, context: context), as: UTF8.self)
    }

    // MARK: - primitives

    private static func seal(_ plaintext: Data, with key: SymmetricKey, context: String) throws -> Sealed {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce,
                                   authenticating: Data(context.utf8))
        // ciphertext and tag together; the nonce is stored beside them.
        return Sealed(ciphertext: box.ciphertext + box.tag, nonce: Data(nonce))
    }

    private static func open(_ sealed: Sealed, with key: SymmetricKey, context: String) throws -> Data {
        guard sealed.ciphertext.count >= 16 else { throw Failure.corrupt("ciphertext too short") }
        let tagIndex = sealed.ciphertext.count - 16
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: sealed.nonce),
            ciphertext: sealed.ciphertext.prefix(tagIndex),
            tag: sealed.ciphertext.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(password.utf8)
        let salt = [UInt8](salt)

        let status = derived.withUnsafeMutableBufferPointer { output in
            salt.withUnsafeBufferPointer { salt in
                password.withUnsafeBufferPointer { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress, password.count,
                        salt.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        output.baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.corrupt("key derivation failed") }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

private extension SymmetricKey {
    var rawBytes: Data { withUnsafeBytes { Data($0) } }
}
