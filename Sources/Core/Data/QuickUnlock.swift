import Foundation
import LocalAuthentication
import Security

/// Opening the vault with the Mac itself.
///
/// The vault password stays the only thing that can derive the key -- this
/// does not replace it, it keeps a copy of the already-derived data key and
/// asks macOS to confirm the owner before handing it back. Touch ID, an
/// unlocked Apple Watch and the login password are all one policy to the
/// system, which is why this is one switch rather than three.
///
/// The vault password is still needed the first time, and still works
/// afterwards: this is a shortcut, not a replacement, and a shortcut that
/// cannot be taken must never be the only way in.
///
/// ## What this does and does not protect
///
/// The key goes in the login keychain -- encrypted at rest, tied to this
/// device, and reachable only by this application. The presence check is made
/// by this application before reading it, **not** by the keychain itself.
///
/// The stronger form exists: an item with `kSecAttrAccessControl(.userPresence)`
/// is released by the system only after it has checked, so nothing can read it
/// without that. It needs the `keychain-access-groups` entitlement, which needs
/// a provisioning profile, which needs more than an ad-hoc signature. Measured
/// on this machine: a plain item is accepted, and both `.userPresence` and the
/// data-protection keychain are refused with errSecMissingEntitlement.
///
/// So the honest statement of the difference: someone at your already-unlocked
/// Mac could reach this key without passing Touch ID. Someone holding a copy of
/// the database still gets nothing -- which is the promise the vault actually
/// makes.
public enum QuickUnlock {
    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        case cancelled
        case notEnrolled
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .unavailable(let why): "cannot use this Mac to unlock: \(why)"
            case .cancelled:            "cancelled"
            case .notEnrolled:          "nothing has been stored to unlock with"
            case .keychain(let code):   "keychain error \(code)"
            }
        }
    }

    /// The keychain item this looks at.
    ///
    /// Overridable so a test never reaches for the one the app is using. They
    /// shared a name once, and clearing up after a test run deleted the key a
    /// person had actually enrolled -- silently, because a missing item and a
    /// switch that was never turned on look identical from the gate.
    public nonisolated(unsafe) static var service = "com.tianranzhang.termther.vault"
    static let account = "data-key"

    /// Everything this Mac would accept, right now.
    ///
    /// One policy covers all of them and macOS decides which to use when the
    /// moment comes -- so this is a list, not a choice. Naming a single one on
    /// a button is wrong as soon as a Touch ID keyboard is plugged in, or the
    /// same vault is opened on a laptop.
    public static func methods() -> [String] {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastAvailabilityError = error?.localizedDescription ?? "no reason given"
            return []
        }
        lastAvailabilityError = nil

        var found: [String] = []
        // biometryType says what the Mac knows about, not what it can use: a
        // Mac mini reports .touchID with no sensor attached.
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            let name = switch context.biometryType {
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .faceID:  "Face ID"
            default:       "biometrics"
            }
            found.append(name)
        }
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithWatch, error: nil) {
            found.append("Apple Watch")
        }
        // Always last, and always there: the policy falls back to it.
        found.append("your Mac password")
        return found
    }

    /// The list as a sentence, for a tooltip.
    public static func methodsDescription() -> String? {
        let methods = methods()
        guard !methods.isEmpty else { return nil }
        if methods.count == 1 { return methods[0] }
        return methods.dropLast().joined(separator: ", ") + " or " + methods[methods.count - 1]
    }

    public static var isAvailable: Bool { !methods().isEmpty }

    /// Why the Mac said no, when it did. Kept because the alternative is a
    /// switch that is simply absent, which looks the same as a feature that
    /// was never built.
    public nonisolated(unsafe) private(set) static var lastAvailabilityError: String?

    /// True when a key has been stored. Asked without prompting for anything:
    /// the gate has to know whether to offer the button before anyone touches
    /// a sensor.
    public static func isEnrolled() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Stores the data key.
    public static func enrol(dataKey: Data) throws {
        guard isAvailable else { throw Failure.unavailable("no policy is available") }
        forget()

        var query = baseQuery()
        query[kSecValueData as String] = dataKey
        // ThisDeviceOnly: a vault key must not travel in a backup.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Asks macOS to confirm the owner, then hands back the key.
    ///
    /// The check and the read are two steps rather than one, because binding
    /// them together is the part that needs an entitlement this build cannot
    /// carry. See the note above the type.
    public static func retrieve(reason: String) async throws -> Data {
        let context = LAContext()
        do {
            let confirmed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            guard confirmed else { throw Failure.cancelled }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel, .authenticationFailed:
                throw Failure.cancelled
            default:
                throw Failure.unavailable(error.localizedDescription)
            }
        }

        var query = baseQuery()
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.keychain(status) }
            return data
        case errSecUserCanceled:
            throw Failure.cancelled
        case errSecItemNotFound:
            throw Failure.notEnrolled
        default:
            throw Failure.keychain(status)
        }
    }

    @discardableResult
    public static func forget() -> Bool {
        SecItemDelete(baseQuery() as CFDictionary) == errSecSuccess
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
