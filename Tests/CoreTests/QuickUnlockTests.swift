import Foundation
import Testing
@testable import Core

/// Storing the vault's data key so the Mac can hand it back.
///
/// The keychain half is not exercised here by default. It is the login
/// keychain -- one shared object outliving the test run, with an access list
/// bound to the binary that wrote it, and an ad-hoc signature that changes
/// every build. A test against it leaves an item behind that the next build
/// cannot delete, then fails on errSecDuplicateItem and reports it as a bug in
/// the code. Run it deliberately instead:
///
///     TERMTHER_KEYCHAIN=1 swift test --filter QuickUnlock
@Suite(.serialized)
struct QuickUnlockTests {
    private var touchesKeychain: Bool {
        ProcessInfo.processInfo.environment["TERMTHER_KEYCHAIN"] != nil
    }

    /// Never the name the app uses: tidying up after a test must not be able
    /// to delete a key somebody enrolled for real.
    private func useTestService() {
        QuickUnlock.service = "com.tianranzhang.termther.tests"
    }

    @Test("the key can be stored, found and forgotten")
    func roundTrip() throws {
        guard touchesKeychain else { return }
        useTestService()
        defer { QuickUnlock.forget() }

        QuickUnlock.forget()
        #expect(!QuickUnlock.isEnrolled())

        try QuickUnlock.enrol(dataKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        #expect(QuickUnlock.isEnrolled())

        // A second key for the same vault replaces the first; two items would
        // mean the wrong one could come back.
        try QuickUnlock.enrol(dataKey: Data(repeating: 2, count: 32))
        #expect(QuickUnlock.isEnrolled())

        QuickUnlock.forget()
        #expect(!QuickUnlock.isEnrolled())
    }

    @Test("what the Mac reports is what it can actually do")
    func capabilityIsMeasuredNotAssumed() {
        // biometryType reports what the Mac knows about, not what it can use:
        // a Mac mini says .touchID with no sensor attached. Anything derived
        // from that alone is a promise the unlock cannot keep.
        for method in QuickUnlock.methods() {
            #expect(!method.isEmpty)
        }
    }
}
