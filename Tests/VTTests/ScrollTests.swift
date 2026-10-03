import GhosttyVt
import Testing
@testable import VT

/// Scrolling goes where the program on screen wants it.
struct ScrollTests {
    private func offset(_ terminal: Terminal) async -> UInt64 {
        var bar = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(terminal.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return bar.offset
    }

    @Test("a shell scrolls back through its history")
    func aShellScrollsBackThroughItsHistory() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        for line in 1...30 { await terminal.write("line \(line)\r\n") }
        let live = await offset(terminal)
        #expect(await terminal.scroll(lines: -3, column: 0, row: 0).isEmpty)
        #expect(await offset(terminal) == live - 3)
        #expect(await terminal.scrollPage(-1))
        #expect(await offset(terminal) == live - 7)
        await terminal.scrollToBottom()
        #expect(await offset(terminal) == live)
    }

    @Test("a program with the mouse gets wheel events")
    func aProgramWithTheMouseGetsWheelEvents() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("\u{1b}[?1000h\u{1b}[?1006h")
        let bytes = await terminal.scroll(lines: -2, column: 2, row: 3)
        #expect(String(decoding: bytes, as: UTF8.self) == "\u{1b}[<64;3;4M\u{1b}[<64;3;4M")
    }

    @Test("a full-screen program without it gets arrows")
    func aFullScreenProgramWithoutItGetsArrows() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("\u{1b}[?1049h")
        #expect(String(decoding: await terminal.scroll(lines: 1, column: 0, row: 0), as: UTF8.self)
                == "\u{1b}[B")
        #expect(await terminal.scrollPage(1) == false)
        await terminal.write("\u{1b}[?1h")
        #expect(String(decoding: await terminal.scroll(lines: -1, column: 0, row: 0), as: UTF8.self)
                == "\u{1b}OA")
    }
}

@Test("a line typed unseen knows how many rows its echo and the prompt take")
func rowsToErase() async throws {
    let terminal = try Terminal(cols: 20, rows: 5)
    // A 6-column prompt with no integration marks: only the echo counts.
    await terminal.write("$ abc ")
    #expect(await terminal.rowsToErase(afterTyping: 10) == 1)
    #expect(await terminal.rowsToErase(afterTyping: 14) == 1)   // fills the row exactly
    #expect(await terminal.rowsToErase(afterTyping: 15) == 2)
    #expect(await terminal.rowsToErase(afterTyping: 40) == 3)

    // A two-line prompt marked as one (OSC 133): its first row is counted too.
    await terminal.write("\r\n\u{1b}]133;A\u{7}line one\r\nline two $ \u{1b}]133;B\u{7}")
    #expect(await terminal.rowsToErase(afterTyping: 4) == 2)
}

@Test("a screen drawn under synchronized output is shown once it is finished, not as it arrives")
func synchronizedOutput() async throws {
    let terminal = try Terminal(cols: 20, rows: 5)
    await terminal.write("ready")
    #expect(await terminal.nextFrame() != nil)
    await terminal.write("\u{1b}[?2026hhalf a screen")
    #expect(await terminal.nextFrame() == nil, "shown part-way through")
    await terminal.write(" and the rest\u{1b}[?2026l")
    #expect(await terminal.nextFrame() != nil)
}
