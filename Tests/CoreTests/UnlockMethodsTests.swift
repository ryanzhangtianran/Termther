import Testing
@testable import Core

/// Naming what the Mac will accept.
///
/// One policy covers Touch ID, an Apple Watch and the login password, and
/// macOS picks whichever is to hand at the moment it asks. So the button can
/// only be honest by naming all of them or none: "Apple Watch" stops being
/// true the day a Touch ID keyboard is plugged in, or the same vault is opened
/// on a laptop.
struct UnlockMethodsTests {
    @Test("the password is always the last resort, and always listed")
    func passwordIsAlwaysThere() {
        let methods = QuickUnlock.methods()
        guard !methods.isEmpty else { return }   // a Mac with no policy at all
        // The policy falls back to it, so a list without it would be short of
        // the one thing that always works.
        #expect(methods.last == "your Mac password")
    }

    @Test("the sentence reads as a list, not a single promise")
    func description() {
        guard let text = QuickUnlock.methodsDescription() else { return }
        let methods = QuickUnlock.methods()
        for method in methods {
            #expect(text.contains(method), "\(method) missing from: \(text)")
        }
        if methods.count > 1 { #expect(text.contains(" or ")) }
    }

    @Test("availability and the list agree")
    func availabilityMatchesTheList() {
        // Two ways of asking the same question; if they can disagree, one of
        // them is showing a button the other says cannot work.
        #expect(QuickUnlock.isAvailable == !QuickUnlock.methods().isEmpty)
    }
}
