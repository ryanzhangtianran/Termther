import Foundation
import Testing
@testable import Core

/// Reads from a shell until a marker appears or time runs out.
///
/// Generous, because each of these starts a login shell that sources the
/// user's whole configuration -- prompt frameworks and plugins included -- and
/// that can take seconds on a busy machine.
private func wait(for marker: String, in shell: LocalShell,
                  transcript: @escaping @Sendable () -> String,
                  seconds: Double = 12) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if transcript().contains(marker) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: bytes, as: UTF8.self)
    }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Serialised: each test starts a login shell, and several at once is enough
/// to push any one of them past a reasonable wait.
@Suite(.serialized)
struct LocalShellTests {
    @Test("the shell runs on a controlling terminal, so job control works")
    func controllingTerminal() async throws {
    let shell = LocalShell()
    let transcript = Transcript()
    try shell.start(command: nil, cols: 80, rows: 24) { transcript.append($0) }
    defer { shell.terminate() }

    // `tty` names the terminal, and `ps` reports the process group only when
    // the shell is a session leader with a controlling terminal. Without that
    // construction the line discipline never turns Ctrl+C into SIGINT.
    shell.write(Array("tty; echo MARKER-$?\n".utf8))
    #expect(await wait(for: "MARKER-0", in: shell, transcript: { transcript.value }),
            "tty failed; the shell has no controlling terminal")
    #expect(transcript.value.contains("/dev/ttys"), "expected a pty name, got: \(transcript.value.suffix(200))")
}

    @Test("Ctrl+C interrupts a running program", .timeLimit(.minutes(1)))
    func controlCInterrupts() async throws {
    let shell = LocalShell()
    let transcript = Transcript()
    try shell.start(command: nil, cols: 80, rows: 24) { transcript.append($0) }
    defer { shell.terminate() }

    // Wait for proof the sleep is actually running rather than guessing a
    // delay: under a parallel test run the shell may not have got there yet,
    // and an interrupt sent too early interrupts nothing.
    shell.write(Array("echo RUNNING; sleep 30\n".utf8))
    #expect(await wait(for: "RUNNING\r\n", in: shell, transcript: { transcript.value }),
            "the shell never started the sleep")
    let started = Date()

    // 0x03 is only a byte. Turning it into SIGINT is the line discipline's
    // job, and it only does that for a controlling terminal.
    shell.write([0x03])
    shell.write(Array("echo INTERRUPTED\n".utf8))

    let interrupted = await wait(for: "INTERRUPTED", in: shell, transcript: { transcript.value })
    #expect(interrupted, "Ctrl+C did not interrupt the sleep")
    // Arriving at all is the proof: without an interrupt the prompt would not
    // come back for thirty seconds, and the wait above would have timed out.
    #expect(Date().timeIntervalSince(started) < 5)
}

    @Test("Ctrl+D ends input")
    func controlDSendsEOF() async throws {
    let shell = LocalShell()
    let transcript = Transcript()
    let exited = Transcript()
    try shell.start(command: nil, cols: 80, rows: 24) { transcript.append($0) } onExit: {
        exited.append(Array("EXITED".utf8))
    }
    defer { shell.terminate() }

    shell.write(Array("echo READY\n".utf8))
    _ = await wait(for: "READY", in: shell, transcript: { transcript.value })

    // At an interactive prompt, end-of-file ends the shell.
    shell.write([0x04])
    #expect(await wait(for: "EXITED", in: shell, transcript: { exited.value }),
            "Ctrl+D did not end the shell")
}

    @Test("a new terminal starts in the user's home")
    func startsAtHome() async throws {
    // An app launched from Finder inherits "/" as its working directory, so
    // without an explicit chdir every terminal opens at the root of the disk.
    let shell = LocalShell()
    let transcript = Transcript()
    try shell.start(command: nil, cols: 80, rows: 24) { transcript.append($0) }
    defer { shell.terminate() }

    shell.write(Array("pwd\n".utf8))
    #expect(await wait(for: NSHomeDirectory(), in: shell, transcript: { transcript.value }),
            "expected \(NSHomeDirectory()), got: \(transcript.value.suffix(200))")
}
}
