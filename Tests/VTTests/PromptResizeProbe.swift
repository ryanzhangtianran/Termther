import Testing
@testable import VT

/// A resized window leaves the prompt where zsh redraws it.
///
/// On SIGWINCH zsh moves up from the cursor as many rows as its prompt took
/// at the old width, clears to the end and draws it again. Reflow has
/// already re-wrapped those rows by then, so unless the emulator puts the
/// cursor back, the redraw lands a row off: a blank or half a stale prompt
/// above it, one more every time the window narrows. The bytes here are what
/// zsh 5.9 actually wrote, captured from a pty.
@Test("zsh redraws a resized prompt in place", arguments: [
    // A prompt that opens with a blank line, as Starship's does.
    ("\r\nuser@host ~/some/long/path > ", UInt16(40), UInt16(20), "\r\r\u{1b}[A\u{1b}[J"),
    ("\r\nuser@host ~/some/long/path > ", UInt16(20), UInt16(40), "\r\r\u{1b}[A\u{1b}[A\u{1b}[J"),
    ("user@host ~/some/long/path > ", UInt16(40), UInt16(20), "\r\r\u{1b}[J"),
    ("user@host ~/some/long/path > ", UInt16(20), UInt16(40), "\r\r\u{1b}[A\u{1b}[J"),
])
func promptRedrawsInPlace(prompt: String, from: UInt16, to: UInt16, winch: String) async throws {
    let mark = "\u{1b}]133;A\u{07}", input = "\u{1b}]133;B\u{07}"
    func screen(resizing: Bool) async throws -> String {
        let terminal = try Terminal(cols: resizing ? from : to, rows: 8)
        await terminal.write("out1\r\nout2\r\n" + mark + prompt + input)
        guard resizing else { return await terminal.plainText() }
        await terminal.resize(cols: to, rows: 8, cellWidth: 8, cellHeight: 16)
        await terminal.write(winch + prompt + input)
        return await terminal.plainText()
    }
    #expect(try await screen(resizing: true) == screen(resizing: false))
}

/// Without shell integration there is no prompt to find, and a resize
/// leaves the cursor wherever reflow put it.
@Test("an unmarked prompt is left alone")
func unmarkedPromptIsLeftAlone() async throws {
    let terminal = try Terminal(cols: 40, rows: 8)
    await terminal.write("out1\r\nuser@host ~/some/long/path > ")
    await terminal.resize(cols: 20, rows: 8, cellWidth: 8, cellHeight: 16)
    await terminal.write("X")
    #expect(await terminal.plainText() == "out1\nuser@host ~/some/lon\ng/path > X")
}
