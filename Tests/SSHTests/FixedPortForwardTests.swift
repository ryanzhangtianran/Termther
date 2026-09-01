import Foundation
import Net
import Testing
@testable import SSH

private struct Target {
    let host: String, port: UInt16, user: String, key: String
    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TERMTHER_SSH_HOST"], let user = env["TERMTHER_SSH_USER"],
              let path = env["TERMTHER_SSH_KEY"],
              let key = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        self.host = host
        self.user = user
        self.key = key
        self.port = env["TERMTHER_SSH_PORT"].flatMap { UInt16($0) } ?? 22
    }

    func session() async throws -> SSHSession {
        let session = SSHSession()
        try await session.connect(to: host, port: port)
        try await session.authenticate(username: user, privateKey: key)
        return session
    }
}

/// A named port, the way the app asks for one.
///
/// The end-to-end test asks the server to pick a port, which is the easy case.
/// Every forward the app actually makes names its port, and a named port can
/// already be taken -- including by this application's own previous session,
/// which is what makes it worth its own test.
@Test("a forward on a named port comes up")
func namedPortListens() async throws {
    guard let target = Target() else { return }

    let session = try await target.session()
    defer { Task { await session.disconnect() } }

    let forward = try PortForward(session: session, direction: .remote,
                                  bindHost: "127.0.0.1", bindPort: 16152,
                                  targetHost: "127.0.0.1", targetPort: 6152)
    try await forward.start()
    let bound = await forward.boundPort
    #expect(bound == 16152, "asked for 16152, got \(bound)")
    await forward.stop()
}

@Test("the same port twice, on two sessions, is refused rather than silently shadowed")
func namedPortTwice() async throws {
    guard let target = Target() else { return }

    let first = try await target.session()
    let second = try await target.session()
    defer { Task { await first.disconnect(); await second.disconnect() } }

    let held = try PortForward(session: first, direction: .remote,
                               bindHost: "127.0.0.1", bindPort: 16153,
                               targetHost: "127.0.0.1", targetPort: 6152)
    try await held.start()
    defer { Task { await held.stop() } }

    // The second must fail rather than appear to work: two listeners on one
    // port means connections go to whichever the server picked, and that is
    // worse than a refusal.
    let clashing = try PortForward(session: second, direction: .remote,
                                   bindHost: "127.0.0.1", bindPort: 16153,
                                   targetHost: "127.0.0.1", targetPort: 6152)
    await #expect(throws: (any Error).self) { try await clashing.start() }
}
