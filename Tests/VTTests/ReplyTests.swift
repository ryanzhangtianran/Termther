import Foundation
import Testing
@testable import VT

/// A program that asks the terminal something gets an answer.
///
/// atuin asks where the cursor is (CSI 6n) before drawing its search, and
/// gave up with "the cursor position could not be read" when the emulator's
/// reply was dropped instead of sent back.
@Test("a cursor position query is answered")
func cursorPositionQueryIsAnswered() async throws {
    final class Replies: @unchecked Sendable {
        let lock = NSLock()
        var bytes: [UInt8] = []
    }
    let replies = Replies()
    let terminal = try Terminal(cols: 40, rows: 10)
    await terminal.onReply { bytes in replies.lock.withLock { replies.bytes += bytes } }

    await terminal.write("ab\r\ncd")            // cursor on row 2, column 3
    await terminal.write("\u{1b}[6n")
    #expect(replies.lock.withLock { String(decoding: replies.bytes, as: UTF8.self) }
            == "\u{1b}[2;3R")
}
