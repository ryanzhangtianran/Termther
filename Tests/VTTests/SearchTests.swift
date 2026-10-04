import GhosttyVt
import Testing
@testable import VT

/// Search through the screen and the scrollback.
struct SearchTests {
    private func offset(_ terminal: Terminal) async -> UInt64 {
        var bar = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(terminal.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return bar.offset
    }

    @Test("a needle in lower case counts every case, and next goes up from the bottom and wraps")
    func lowerCaseFindsEveryCase() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("Foo one\r\nbar\r\nfoo two\r\nFOO three\r\n")
        await terminal.search("foo")
        #expect(await terminal.matchCount == 3)
        #expect(await terminal.currentMatchIndex == nil)

        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "FOO")
        #expect(await terminal.currentMatchIndex == 0)
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "foo")
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "Foo")
        #expect(await terminal.currentMatchIndex == 2)
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "FOO", "wraps to the newest")
        await terminal.previousMatch()
        #expect(await terminal.selectedText() == "Foo", "and back the other way")
    }

    @Test("a needle with a capital matches only its own case")
    func capitalsAreExact() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("Foo one\r\nbar\r\nfoo two\r\nFOO three\r\n")
        await terminal.search("Foo")
        #expect(await terminal.matchCount == 1)
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "Foo")
        #expect(await terminal.currentMatchIndex == 0)
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "Foo", "the only one, round again")
        #expect(await terminal.currentMatchIndex == 0)
    }

    @Test("output that arrives is searched too")
    func outputJoinsTheSearch() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("needle\r\n")
        await terminal.search("needle")
        #expect(await terminal.matchCount == 1)
        await terminal.write("hay\r\nneedle again\r\n")
        #expect(await terminal.matchCount == 2)
        await terminal.search("nothing like it")
        #expect(await terminal.matchCount == 0)
        await terminal.endSearch()
        #expect(await terminal.matchCount == 0)
    }

    @Test("a match in the scrollback is scrolled into view, and tinted once it is")
    func scrollbackMatchIsShown() async throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        await terminal.write("needle first\r\n")
        for line in 1...20 { await terminal.write("line \(line)\r\n") }
        let live = await offset(terminal)
        await terminal.search("needle")
        await terminal.nextMatch()
        #expect(await terminal.selectedText() == "needle")
        #expect(await offset(terminal) < live)

        // The selected one is the selection; another in view is a match.
        await terminal.write("needle last\r\n")
        await terminal.scrollToBottom()
        let frame = try #require(await terminal.nextFrame())
        let row = try #require(frame.dirtyRows.first { $0.cells.prefix(6).allSatisfy(\.isMatch) })
        #expect(row.cells[6].isMatch == false)
    }
}
