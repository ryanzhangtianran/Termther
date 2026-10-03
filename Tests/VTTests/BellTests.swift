import Foundation
import Testing
@testable import VT

/// A program that wants attention rings the bell, or says so in words.
///
/// Claude Code does both when it waits for input; a tab that is not showing
/// has to be able to say so.
@Test("the bell handler is called once per BEL")
func bellRingsOncePerBEL() async throws {
    final class Count: @unchecked Sendable {
        let lock = NSLock()
        var rings = 0
    }
    let count = Count()
    let terminal = try Terminal(cols: 40, rows: 10)
    await terminal.onBell { count.lock.withLock { count.rings += 1 } }

    await terminal.write("a\u{07}b")
    #expect(count.lock.withLock { count.rings } == 1)
    await terminal.write("\u{07}\u{07}")
    #expect(count.lock.withLock { count.rings } == 3)
}

@Test("an OSC 9 notification arrives with its body")
func notificationCarriesItsBody() async throws {
    final class Received: @unchecked Sendable {
        let lock = NSLock()
        var notes: [(title: String, body: String)] = []
    }
    let received = Received()
    let terminal = try Terminal(cols: 40, rows: 10)
    await terminal.onNotification { title, body in
        received.lock.withLock { received.notes.append((title, body)) }
    }

    await terminal.write("\u{1b}]9;Waiting for input\u{07}")
    let notes = received.lock.withLock { received.notes }
    #expect(notes.count == 1)
    #expect(notes.first?.body == "Waiting for input")
}
