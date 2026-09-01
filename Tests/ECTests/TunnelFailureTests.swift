import Foundation
import Testing
@testable import EC

/// The tunnel ending without ending the app.
///
/// The upstream engine is a command-line program and treats a broken tunnel
/// as terminal: `panic` on a read or write failure, `os.Exit(2)` on a
/// server-initiated shutdown. Inside an app both take the host process with
/// them -- the panic as a SIGABRT raised by the Go runtime, the exit silently
/// and with no crash report to explain it. Changing networks triggers either.
/// The vendored fork reports instead; these check the reporting path exists
/// and behaves.
struct TunnelFailureTests {
    @Test("a fresh engine reports no failure")
    func quietWhenNothingHasHappened() async {
        let engine = EasyConnect()
        #expect(await engine.tunnelFailure() == nil)
    }

    @Test("logging out clears whatever was reported")
    func logoutClears() async {
        let engine = EasyConnect()
        await engine.logout()
        // Not an error state: a session that was never up has nothing to
        // report, and a stale reason would make the next connection look
        // broken before it started.
        #expect(await engine.tunnelFailure() == nil)
    }

    @Test("asking after a failed login does not report a tunnel failure")
    func failedLoginIsNotATunnelFailure() async {
        // A login that never succeeded is a different thing from a tunnel
        // that came up and then died, and the panel says different things
        // about them.
        let engine = EasyConnect()
        _ = try? await engine.login(gateway: "127.0.0.1:1",
                                    credentials: .init(username: "x", password: "y"))
        #expect(await engine.tunnelFailure() == nil)
    }
}
