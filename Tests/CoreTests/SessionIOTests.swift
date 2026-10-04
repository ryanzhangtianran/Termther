import Foundation
import Testing
@testable import Core

/// A terminal drives its IO from whichever task has bytes to send -- a key
/// press on the main actor, output on a reader queue, a resize from a layout
/// pass. So every `SessionIO` has to tolerate being called from anywhere.
///
/// This exists because an implementation once reached for main-actor state with
/// `MainActor.assumeIsolated`, which is an assertion rather than a check: the
/// first keystroke that arrived off the main actor killed the process.
@Test("a session can be driven from any isolation without trapping")
func sessionIOIsCallableFromAnywhere() async throws {
    let shell = LocalShell()
    let io: any SessionIO = shell
    defer { shell.terminate() }

    try await io.start(cols: 80, rows: 24, onOutput: { _ in }, onExit: { _ in })

    // From a detached task, which is neither the main actor nor the caller's.
    await Task.detached {
        await io.send(Array("echo hello\n".utf8))
        await io.resize(cols: 100, rows: 30)
    }.value

    // And from the main actor.
    await MainActor.run { }
    await io.send([0x04])
    await io.stop()
}

@Test("a local shell is at its prompt until it runs a program, and not while it does")
func localShellKnowsItsPrompt() async throws {
    let shell = LocalShell()
    defer { shell.terminate() }
    try await shell.start(cols: 80, rows: 24, onOutput: { _ in }, onExit: { _ in })

    // Startup files may run programs of their own first.
    func becomes(_ expected: Bool) async -> Bool {
        for _ in 0..<50 {
            if await shell.isAtPrompt() == expected { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    #expect(await becomes(true))
    await shell.send(Array("sleep 3\n".utf8))
    #expect(await becomes(false))
}

@Test("a local shell that ends has not lost a link")
func localShellEndIsNotALostLink() async throws {
    let shell = LocalShell()
    let io: any SessionIO = shell
    let ended = AsyncStream.makeStream(of: Bool.self)
    try await io.start(cols: 80, rows: 24, onOutput: { _ in }) { ended.continuation.yield($0) }
    await io.send(Array("exit\n".utf8))
    var lost: Bool?
    for await value in ended.stream { lost = value; break }
    #expect(lost == false)
}

/// Needs a reachable SSH server:
///   TERMTHER_SSH_HOST=127.0.0.1 TERMTHER_SSH_USER=you SSHPASS=... swift test
@Test("a remote shell that exits ends without a lost link; a dropped session loses it")
func remoteShellEndReason() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["TERMTHER_SSH_HOST"], let user = env["TERMTHER_SSH_USER"],
          let password = env["SSHPASS"], !password.isEmpty else { return }   // skipped without a server
    let login = Connector.Login(username: user, secret: password, kind: .password)

    for (typed, expected) in [("exit\n", false), ("kill -9 $PPID\n", true)] {
        let shell = RemoteShell(.init(host: host, login: login))
        let ended = AsyncStream.makeStream(of: Bool.self)
        try await shell.start(cols: 80, rows: 24, onOutput: { _ in }) { ended.continuation.yield($0) }
        await shell.send(Array(typed.utf8))
        var lost: Bool?
        for await value in ended.stream { lost = value; break }
        #expect(lost == expected, "after \(typed.dropLast())")
        await shell.stop()
    }
}
