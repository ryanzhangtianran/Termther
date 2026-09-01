import Foundation
import Testing
@testable import EC

/// Live login, run by hand:
///   TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=you ECPASS=... \
///     swift test --filter liveLogin
///
/// The password is read from the environment and never printed. Use `read -s`
/// rather than typing it on a command line that ends up in shell history.
@Test("a live gateway logs in and hands out a tunnel address",
      .timeLimit(.minutes(1)))
func liveLogin() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let gateway = env["TERMTHER_EC_GATEWAY"],
          let user = env["TERMTHER_EC_USER"],
          let password = env["ECPASS"], !password.isEmpty
    else { return }   // skipped unless asked for

    let engine = EasyConnect(underlay: EasyConnect.Underlay.discover())
    let address = try await engine.login(
        gateway: gateway,
        credentials: .init(username: user, password: password,
                           totpSecret: env["TERMTHER_EC_TOTP"]))
    print("assigned: \(address)")

    // The address is the proof: it comes from the gateway and exists only
    // inside a real tunnel.
    #expect(!address.isEmpty)

    if let routing = try? await engine.routing() {
        print("routes: \(routing.ip.count) ranges, \(routing.dns.count) DNS, "
              + "\(routing.domains.count) domains")
    }
    await engine.logout()
}

/// Proves the login path returns at all.
///
/// It once could not: the underlay fields were guarded by the same mutex
/// ec_login holds for the whole handshake, and a sync.Mutex is not reentrant,
/// so the login deadlocked and the panel sat at "connecting" forever. A wrong
/// password coming back promptly is the thing being tested -- not the wrong
/// password.
@Test("a refused login comes back rather than hanging", .timeLimit(.minutes(1)))
func refusedLoginReturns() async throws {
    guard let gateway = ProcessInfo.processInfo.environment["TERMTHER_EC_GATEWAY"]
    else { return }

    let engine = EasyConnect(underlay: EasyConnect.Underlay.discover())
    let started = Date()
    // A name no account service would issue, so no real account is touched.
    await #expect(throws: (any Error).self) {
        _ = try await engine.login(
            gateway: gateway,
            credentials: .init(username: "termther-selftest-nonexistent",
                               password: "not-a-password"))
    }
    let elapsed = Date().timeIntervalSince(started)
    print("refused after \(String(format: "%.1f", elapsed))s")
    #expect(elapsed < 45, "the login did not come back promptly")
}
