import GhosttyVt
import Testing
@testable import VT

// MARK: - bytes in

@Test("a sequence split across two writes still parses")
func resumesAcrossWrites() async throws {
    // An SSH read ends wherever the packet ends, including halfway through an
    // escape sequence. Nothing may be lost at that boundary.
    let terminal = try Terminal(cols: 80, rows: 24)
    await terminal.write("first line\r\nsecond\r\nthird\r\n\u{1b}[")
    await terminal.write("2;1Hrewritten\r\n")

    let screen = await terminal.plainText()
    #expect(screen.contains("first line"))
    #expect(screen.contains("rewritten"))
    #expect(!screen.contains("second"))
}

// MARK: - frames out

@Test("an idle terminal produces no frame at all")
func idleProducesNothing() async throws {
    let terminal = try Terminal()
    await terminal.write("hello")
    #expect(await terminal.nextFrame() != nil)     // the write
    #expect(await terminal.nextFrame() == nil)     // nothing since
    #expect(await terminal.nextFrame() == nil)
}

@Test("the first frame is a full redraw, later ones are incremental")
func framesAreIncremental() async throws {
    let terminal = try Terminal(cols: 80, rows: 24)
    await terminal.write("hello")

    let first = try #require(await terminal.nextFrame())
    #expect(first.isFullRedraw)
    #expect(first.dirtyRows.count == 24)

    await terminal.write("\u{1b}[10;1Hrow ten")
    let second = try #require(await terminal.nextFrame())
    #expect(!second.isFullRedraw)
    // The touched row, plus the row the cursor left.
    #expect(second.dirtyRows.contains { $0.y == 9 })
    #expect(second.dirtyRows.count <= 2)
}

@Test("cells carry text, colour and attributes")
func cellContents() async throws {
    let terminal = try Terminal(cols: 20, rows: 3)
    // Bold, in RGB green.
    await terminal.write("\u{1b}[1;38;2;0;255;0mAB\u{1b}[0m")

    let frame = try #require(await terminal.nextFrame())
    let row = try #require(frame.dirtyRows.first { $0.y == 0 })

    #expect(row.cells[0].text == "A")
    #expect(row.cells[1].text == "B")
    #expect(row.cells[0].attributes.contains(.bold))
    #expect(row.cells[0].foreground == Color(red: 0, green: 255, blue: 0))
    // Past the written text there is no styling to report.
    #expect(row.cells[5].text == "")
    #expect(row.cells[5].attributes.isEmpty)
}

@Test("a grapheme cluster stays one cell")
func graphemeClusters() async throws {
    let terminal = try Terminal(cols: 20, rows: 3)
    await terminal.write("é写")

    let frame = try #require(await terminal.nextFrame())
    let row = try #require(frame.dirtyRows.first { $0.y == 0 })
    #expect(row.cells[0].text == "é")
    // A wide character occupies its cell; the next cell is its empty tail.
    #expect(row.cells[1].text == "写")
}

@Test("the cursor is reported where the writes left it")
func cursorPosition() async throws {
    let terminal = try Terminal(cols: 80, rows: 24)
    await terminal.write("\u{1b}[5;10Hx")

    let frame = try #require(await terminal.nextFrame())
    let cursor = try #require(frame.cursor)
    #expect(cursor.y == 4)       // 0-indexed
    #expect(cursor.x == 10)      // one past the 'x' written at column 9
    #expect(cursor.isVisible)
}

@Test("resize reflows and forces a full redraw")
func resizeReflows() async throws {
    let terminal = try Terminal(cols: 80, rows: 24)
    await terminal.write("hello")
    _ = await terminal.nextFrame()

    await terminal.resize(cols: 100, rows: 30)
    #expect(await terminal.cols == 100)
    #expect(await terminal.rows == 30)

    let frame = try #require(await terminal.nextFrame())
    #expect(frame.isFullRedraw)
    #expect(frame.cols == 100)
    #expect(frame.dirtyRows.count == 30)
}

// MARK: - input

@Test("control chords and arrows encode the legacy way by default")
func legacyEncoding() async throws {
    let terminal = try Terminal()
    #expect(await terminal.encode(key: GHOSTTY_KEY_C, modifiers: .control) == [0x03])
    #expect(await terminal.encode(key: GHOSTTY_KEY_ARROW_UP) == Array("\u{1b}[A".utf8))
}

@Test("input follows the terminal into application cursor mode")
func encoderFollowsTerminalModes() async throws {
    // DECCKM is set by the *remote* program; input has to notice, or arrow
    // keys break inside vim and every other full-screen app.
    let terminal = try Terminal()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ARROW_UP) == Array("\u{1b}[A".utf8))

    await terminal.write("\u{1b}[?1h")
    #expect(await terminal.encode(key: GHOSTTY_KEY_ARROW_UP) == Array("\u{1b}OA".utf8))
}
