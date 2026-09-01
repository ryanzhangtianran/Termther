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

    try await io.start(cols: 80, rows: 24, onOutput: { _ in }, onExit: {})

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
