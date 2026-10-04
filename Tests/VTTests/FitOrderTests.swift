import Testing
@testable import VT

/// The view's sizes can reach the terminal out of order; the newest wins.
///
/// When a stale, shorter size was applied after a newer one, the grid had
/// fewer rows than the window: text scrolled while blank space sat below it.
@Test("a stale size does not undo a newer one")
func aStaleSizeDoesNotUndoANewerOne() async throws {
    let terminal = try Terminal(cols: 80, rows: 24)
    #expect(await terminal.fit(cols: 100, rows: 40, cellWidth: 8, cellHeight: 16, order: 2))
    #expect(await terminal.fit(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16, order: 1) == false)
    #expect(await terminal.rows == 40)
    // The same size again changes nothing worth reporting.
    #expect(await terminal.fit(cols: 100, rows: 40, cellWidth: 8, cellHeight: 16, order: 3) == false)
}
