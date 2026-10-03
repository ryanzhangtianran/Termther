import Foundation
import GhosttyVt

/// A terminal emulator: bytes in, frames out.
///
/// The emulator has no IO of its own. Bytes arrive from wherever the caller got
/// them -- an SSH channel, a local pty, a replay file -- and nothing in here
/// knows or cares which. That boundary is the reason libghostty-vt was chosen
/// over the full libghostty, whose only IO backend spawns a subprocess.
///
/// An actor because libghostty-vt's terminal is not thread-safe: output arrives
/// on a reader task while the renderer pulls frames on the main actor.
public actor Terminal {
    // Opaque C handles. The actor serialises every use, and deinit only runs
    // once no reference survives, so there is no concurrent access to protect
    // against -- but Swift cannot see that through an OpaquePointer, and a
    // nonisolated deinit has to free them.
    nonisolated(unsafe) var terminal: GhosttyTerminal?
    private nonisolated(unsafe) var renderState: GhosttyRenderState?
    private nonisolated(unsafe) var rowIterator: GhosttyRenderStateRowIterator?
    private nonisolated(unsafe) var cellIterator: GhosttyRenderStateRowCells?
    private let keyEncoder: KeyEncoder?
    /// Where the current drag selection started, and on which screen.
    ///
    /// Tracked rather than a plain grid ref: a plain one is only good until
    /// the next write, and output keeps streaming while a drag goes on.
    nonisolated(unsafe) var anchor: GhosttyTrackedGridRef?
    var anchorScreen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    /// The search in progress, while there is one; see `Search.swift`.
    nonisolated(unsafe) var search: GhosttySearch?
    var searchNeedle = ""
    /// Whether the terminal has changed since the search last read it.
    var searchIsStale = false

    public private(set) var cols: UInt16
    public private(set) var rows: UInt16

    public enum Failure: Error, CustomStringConvertible {
        case create(String)
        public var description: String {
            switch self { case .create(let what): "cannot create \(what)" }
        }
    }

    public init(cols: UInt16 = 80, rows: UInt16 = 24) throws {
        self.cols = cols
        self.rows = rows

        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS else {
            throw Failure.create("terminal")
        }
        self.terminal = terminal

        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS else {
            throw Failure.create("render state")
        }
        self.renderState = state

        var rowIterator: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS else {
            throw Failure.create("row iterator")
        }
        self.rowIterator = rowIterator

        var cellIterator: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &cellIterator) == GHOSTTY_SUCCESS else {
            throw Failure.create("cell iterator")
        }
        self.cellIterator = cellIterator

        self.keyEncoder = try KeyEncoder()

        // Answers to the far end's questions -- where is the cursor, which
        // modes are set -- go back the way keystrokes do. Without this the
        // emulator drops them, and a program that asks (atuin, for the
        // cursor) waits for an answer that never comes.
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
                                 Unmanaged.passUnretained(effects).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            let bytes = Array(UnsafeBufferPointer(start: data, count: length))
            Unmanaged<Effects>.fromOpaque(userdata).takeUnretainedValue().send?(bytes)
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                                 unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        // A program asking for attention: BEL, or OSC 9 / 777 with words.
        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<Effects>.fromOpaque(userdata).takeUnretainedValue().bell?()
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL,
                                 unsafeBitCast(bell, to: UnsafeRawPointer.self))
        let notify: GhosttyTerminalDesktopNotificationFn = { _, userdata, notification in
            guard let userdata, let notification else { return }
            Unmanaged<Effects>.fromOpaque(userdata).takeUnretainedValue()
                .notify?(String(notification.pointee.title), String(notification.pointee.body))
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                                 unsafeBitCast(notify, to: UnsafeRawPointer.self))
    }

    // MARK: - scrolling

    /// A turn of the wheel, `lines` rows (up is negative), with the pointer
    /// over `column`, `row`. Returns bytes for the far end when the program
    /// there takes the scroll itself; otherwise the scrollback moves.
    ///
    /// The same three cases Ghostty and xterm have: a program that asked for
    /// the mouse gets wheel events; a full-screen one that did not -- less,
    /// man -- gets arrow keys, since it has no scrollback to show; and a
    /// shell's screen scrolls back through its history.
    public func scroll(lines: Int, column: UInt16, row: UInt16) -> [UInt8] {
        guard lines != 0 else { return [] }
        var tracking = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        if tracking {
            // Buttons 64 and 65 are the wheel, up and down; once per row.
            let button = lines < 0 ? 64 : 65
            let one: [UInt8] = isSet(mode: 1006)
                ? Array("\u{1b}[<\(button);\(Int(column) + 1);\(Int(row) + 1)M".utf8)
                : [0x1b, 0x5b, 0x4d, UInt8(32 + button),
                   UInt8(min(33 + Int(column), 255)), UInt8(min(33 + Int(row), 255))]
            return Array(repeating: one, count: abs(lines)).flatMap { $0 }
        }
        if isAlternateScreen {
            // Cursor keys as the program has asked for them (DECCKM).
            let arrow = isSet(mode: 1) ? (lines < 0 ? "\u{1b}OA" : "\u{1b}OB")
                                       : (lines < 0 ? "\u{1b}[A" : "\u{1b}[B")
            return Array(String(repeating: arrow, count: abs(lines)).utf8)
        }
        scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA, by: lines)
        return []
    }

    /// A page of scrollback, up (-1) or down (1). False where there is none
    /// -- a full-screen program's -- and the key belongs to the program.
    public func scrollPage(_ direction: Int) -> Bool {
        guard !isAlternateScreen else { return false }
        scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA, by: direction * max(1, Int(rows) - 1))
        return true
    }

    /// The scrollback moved `rows` (down is positive), as a drag past the
    /// edge of the view asks for.
    public func scrollViewport(by rows: Int) {
        guard !isAlternateScreen else { return }
        scrollViewport(GHOSTTY_SCROLL_VIEWPORT_DELTA, by: rows)
    }

    /// Back to the live screen, as typing does.
    public func scrollToBottom() {
        scrollViewport(GHOSTTY_SCROLL_VIEWPORT_BOTTOM, by: 0)
    }

    private func scrollViewport(_ tag: GhosttyTerminalScrollViewportTag, by delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = tag
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, behavior)
        needsFullRedraw = true
        // The search keeps a list of the matches in view, as of its last look.
        searchIsStale = true
    }

    private var isAlternateScreen: Bool { activeScreen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE }

    var activeScreen: GhosttyTerminalScreen {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen
    }

    private func isSet(mode: UInt16) -> Bool {
        var query = GhosttyTerminalModeConfig()
        query.mode = ghostty_mode_new(mode, false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &query)
        return query.value
    }

    /// Where the emulator's side effects go, held for the C callbacks: set
    /// once, before output.
    private final class Effects: @unchecked Sendable {
        var send: (@Sendable ([UInt8]) -> Void)?
        var bell: (@Sendable () -> Void)?
        var notify: (@Sendable (_ title: String, _ body: String) -> Void)?
    }
    private let effects = Effects()

    /// Sends the terminal's replies to queries back to the far end.
    ///
    /// Called during `write`, inside the emulator, so the handler must only
    /// hand the bytes on -- never write into this terminal.
    public func onReply(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        effects.send = handler
    }

    /// Called for every BEL, under the same rule as `onReply`.
    public func onBell(_ handler: @escaping @Sendable () -> Void) {
        effects.bell = handler
    }

    /// Called for a desktop notification (OSC 9, OSC 777) with its title --
    /// empty when the sequence has none -- and body; same rule as `onReply`.
    public func onNotification(_ handler: @escaping @Sendable (_ title: String, _ body: String) -> Void) {
        effects.notify = handler
    }

    deinit {
        ghostty_search_free(search)
        ghostty_tracked_grid_ref_free(anchor)
        ghostty_render_state_row_cells_free(cellIterator)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    // MARK: - bytes in

    /// Feeds output from the far end.
    ///
    /// Safe at any boundary: a read can end mid-escape-sequence and the parser
    /// resumes on the next call, which matters because an SSH packet has no
    /// idea where a sequence starts or ends.
    public func write(_ bytes: [UInt8]) {
        var bytes = bytes
        ghostty_terminal_vt_write(terminal, &bytes, bytes.count)
        searchIsStale = true
    }

    public func write(_ text: String) {
        write(Array(text.utf8))
    }

    /// Resizes the grid.
    ///
    /// The cell pixel size travels with it because some sequences report the
    /// window in pixels; passing the renderer's measured metrics keeps those
    /// answers honest. Zero is fine when nothing is being drawn yet.
    public func resize(cols: UInt16, rows: UInt16,
                       cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        guard cols > 0, rows > 0 else { return }
        let before = rowsIntoPrompt()
        guard ghostty_terminal_resize(terminal, cols, rows,
                                      cellWidth, cellHeight) == GHOSTTY_SUCCESS else { return }
        self.cols = cols
        self.rows = rows
        searchIsStale = true

        // A shell at its prompt redraws it on SIGWINCH, first moving up from
        // the cursor as many rows as the prompt took at the old width. Reflow
        // has just wrapped or unwrapped those rows, so put the cursor back
        // that many rows below the prompt's start; otherwise every redraw
        // lands a row off and leaves a blank or stale one behind. Down is a
        // line feed, which scrolls where a cursor move would stop.
        //
        // Only between sequences: a read that ended part-way through one
        // would take these bytes as the rest of it. A prompt the shell has
        // finished drawing is at ground, so this gives up nothing real.
        if isAtGround, let before, let after = rowsIntoPrompt(), after != before {
            write(after > before ? "\u{1b}[\(after - before)A"
                                 : String(repeating: "\n", count: before - after))
        }
    }

    /// Puts the keyboard back the way a shell expects it: the Kitty keyboard
    /// protocol off, its stack emptied. A program that enabled it and was
    /// killed -- or lost its connection -- leaves it on, and then Enter
    /// arrives at the shell as `CSI 13 u` and Ctrl-C as `CSI 99;5 u`: every
    /// key types gibberish and nothing interrupts. For the shell's prompt,
    /// where only the shell is listening. Skipped mid-sequence.
    ///
    /// Only when the protocol is on, and never on the alternate screen: a
    /// program there -- a history search the shell runs from its own line
    /// editor, so the shell still looks to be at its prompt -- is the one
    /// using it, and would lose its keys mid-way.
    public func resetKeyboardProtocol() {
        var flags: UInt8 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        guard flags != 0, !isAlternateScreen, isAtGround else { return }
        write("\u{1b}[<255u\u{1b}[=0;1u")
    }

    /// Whether the parser is between sequences -- not part-way through an
    /// escape, a control sequence or a UTF-8 character.
    var isAtGround: Bool {
        var consumed = 0
        return ghostty_terminal_vt_write_until_ground(terminal, nil, 0, &consumed) == GHOSTTY_SUCCESS
    }

    /// The newest size the view has asked for, by the order it measured them.
    private var lastFit = 0

    /// Resizes to what the view measured, unless a newer measurement has
    /// already been applied. The view's sizes travel in separate tasks that
    /// can arrive out of order; applying a stale, shorter one last left the
    /// grid rows short of the window, scrolling with blank space below.
    /// True when the grid changed.
    public func fit(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32,
                    order: Int) -> Bool {
        guard order > lastFit else { return false }
        lastFit = order
        let changed = (cols, rows) != (self.cols, self.rows)
        // Called either way: the cell's pixel size may have changed alone.
        resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        return changed && (cols, rows) == (self.cols, self.rows)
    }

    /// How many rows up from where the cursor will be after typing `length`
    /// characters at it and pressing Return the prompt starts: the rows the
    /// echo takes, and those of the prompt above it when shell integration
    /// marks them. What a line typed unseen has to erase.
    public func rowsToErase(afterTyping length: Int) -> Int {
        var x: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        let echo = max(1, (Int(x) + length + Int(cols) - 1) / Int(cols))
        return echo + (rowsIntoPrompt() ?? 0)
    }

    /// How many rows below the start of the prompt the cursor is, while it is
    /// at one. Known only from shell integration's OSC 133 marks.
    private func rowsIntoPrompt() -> Int? {
        var atPrompt = false
        var y: UInt16 = 0
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT,
                                   &atPrompt) == GHOSTTY_SUCCESS, atPrompt,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y,
                                   &y) == GHOSTTY_SUCCESS else { return nil }
        // Up through the rows the prompt covers -- marked ones, and any a
        // marked line wrapped out of -- to the row it starts on. Reflow copies
        // the start mark onto the rows a line wraps into, and unwrapping can
        // drop it, so the top of the run stands in when no clean start is
        // left.
        var top: Int?
        var joinsAbove = false
        for row in stride(from: Int(y), through: 0, by: -1) {
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_ACTIVE
            point.value.coordinate.y = UInt32(row)
            var ref = GhosttyGridRef()
            var line = GhosttyRow()
            var semantic = GHOSTTY_ROW_SEMANTIC_NONE
            var wrapped = false
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS,
                  ghostty_grid_ref_row(&ref, &line) == GHOSTTY_SUCCESS,
                  ghostty_row_get(line, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT,
                                  &semantic) == GHOSTTY_SUCCESS,
                  ghostty_row_get(line, GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
                                  &wrapped) == GHOSTTY_SUCCESS else { return nil }
            guard semantic != GHOSTTY_ROW_SEMANTIC_NONE || joinsAbove else { break }
            top = row
            if semantic == GHOSTTY_ROW_SEMANTIC_PROMPT, !wrapped { break }
            joinsAbove = wrapped
        }
        return top.map { Int(y) - $0 }
    }

    /// libghostty-vt's version, as major.minor.patch.
    public static var libraryVersion: String {
        let parts = [GHOSTTY_BUILD_INFO_VERSION_MAJOR, GHOSTTY_BUILD_INFO_VERSION_MINOR,
                     GHOSTTY_BUILD_INFO_VERSION_PATCH].map { field -> String in
            var value = 0
            return ghostty_build_info(field, &value) == GHOSTTY_SUCCESS ? String(value) : "?"
        }
        return parts.joined(separator: ".")
    }

    /// The shape the cursor takes when nothing has asked for another.
    ///
    /// Set on the emulator rather than forced in the renderer, so a program
    /// that does ask -- vim switching to a bar in insert mode, say -- still
    /// gets what it asked for.
    public func setDefaultCursor(_ style: CursorStyle) {
        var value = style.ghostty
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &value)
    }

    // MARK: - frames out

    var needsFullRedraw = false
    private var syncOutputSince: ContinuousClock.Instant?

    /// Makes the next frame redraw everything, changed or not -- for when the
    /// drawing itself changed, such as a new font, rather than the contents.
    public func invalidate() { needsFullRedraw = true }

    /// Pulls the next frame, or `nil` when nothing changed.
    ///
    /// Returning `nil` is the common case for an idle terminal and lets the
    /// renderer skip the frame entirely. Every call consumes the dirty state,
    /// so two calls in a row never report the same change twice.
    public func nextFrame() -> Frame? {
        // Synchronized output (mode 2026): a program drawing a whole screen
        // asks for it to be shown at once, not line by line as it arrives --
        // Claude Code replaying a transcript, say. Held for at most a second,
        // as the spec allows, in case the program never turns it off.
        if isSet(mode: 2026) {
            syncOutputSince = syncOutputSince ?? .now
            if ContinuousClock.now - syncOutputSince! < .seconds(1) { return nil }
        } else {
            syncOutputSince = nil
        }
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return nil }
        if needsFullRedraw {
            // After the update, which would otherwise decide nothing changed.
            var full = GHOSTTY_RENDER_STATE_DIRTY_FULL
            _ = ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &full)
            needsFullRedraw = false
        }

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty) == GHOSTTY_SUCCESS,
              dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE
        else { return nil }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)

        let frame = Frame(
            cols: cols,
            rows: rows,
            isFullRedraw: dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL,
            dirtyRows: collectDirtyRows(),
            cursor: readCursor(),
            defaultForeground: Color(colors.foreground),
            defaultBackground: Color(colors.background),
            cursorColor: colors.cursor_has_value ? Color(colors.cursor) : nil)

        // Consume the frame. Without this the state stays dirty forever and
        // every frame degenerates into a full redraw.
        _ = ghostty_render_state_clean(renderState)
        return frame
    }

    private func collectDirtyRows() -> [Row] {
        guard ghostty_render_state_get(renderState,
                                       GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                                       &rowIterator) == GHOSTTY_SUCCESS
        else { return [] }

        // Fed first, so the matches are where this frame's text is.
        let matches = matchCells()
        var collected: [Row] = []
        var y: UInt16 = 0
        while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
            guard ghostty_render_state_row_get(rowIterator,
                                               GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                               &cellIterator) == GHOSTTY_SUCCESS
            else { continue }
            collected.append(Row(y: y, cells: collectCells(matching: matches[y] ?? [])))
        }
        return collected
    }

    private func collectCells(matching matches: [ClosedRange<Int>]) -> [Cell] {
        var cells: [Cell] = []
        cells.reserveCapacity(Int(cols))

        while ghostty_render_state_row_cells_next(cellIterator) {
            cells.append(Cell(
                text: readCellText(),
                foreground: readCellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR),
                background: readCellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR),
                attributes: readCellAttributes(),
                isSelected: readCellFlag(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED),
                isMatch: matches.contains { $0.contains(cells.count) }))
        }
        return cells
    }

    /// The cell's whole grapheme cluster as UTF-8, so "é" or a flag emoji comes
    /// back as one string rather than a base codepoint plus loose marks.
    ///
    /// Almost every cluster fits the first buffer. One that does not -- a
    /// letter under a pile of combining marks -- is told how much it needs
    /// and asked again, rather than drawn as nothing.
    private func readCellText(capacity: Int = 32) -> String {
        var storage = [UInt8](repeating: 0, count: capacity)
        var needed = 0
        let text = storage.withUnsafeMutableBufferPointer { raw -> String in
            var buffer = GhosttyBuffer(ptr: raw.baseAddress, cap: raw.count, len: 0)
            let result = ghostty_render_state_row_cells_get(
                cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
            if result == GHOSTTY_OUT_OF_SPACE { needed = buffer.len }
            guard result == GHOSTTY_SUCCESS, buffer.len > 0 else { return "" }
            return String(decoding: raw.prefix(buffer.len), as: UTF8.self)
        }
        return needed > capacity ? readCellText(capacity: needed) : text
    }

    private func readCellColor(_ kind: GhosttyRenderStateRowCellsData) -> Color? {
        var rgb = GhosttyColorRgb()
        // GHOSTTY_INVALID_VALUE here means "no explicit colour", not an error:
        // the caller falls back to the terminal default.
        guard ghostty_render_state_row_cells_get(cellIterator, kind, &rgb) == GHOSTTY_SUCCESS
        else { return nil }
        return Color(rgb)
    }

    private func readCellFlag(_ kind: GhosttyRenderStateRowCellsData) -> Bool {
        var value = false
        _ = ghostty_render_state_row_cells_get(cellIterator, kind, &value)
        return value
    }

    private func readCellAttributes() -> Cell.Attributes {
        // Skip materialising the full style for the overwhelming majority of
        // cells, which carry none.
        guard readCellFlag(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING) else { return [] }

        var style = GhosttyStyle()
        guard ghostty_render_state_row_cells_get(
            cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS
        else { return [] }

        var attributes: Cell.Attributes = []
        if style.bold          { attributes.insert(.bold) }
        if style.italic        { attributes.insert(.italic) }
        if style.faint         { attributes.insert(.faint) }
        if style.inverse       { attributes.insert(.inverse) }
        if style.invisible     { attributes.insert(.invisible) }
        if style.strikethrough { attributes.insert(.strikethrough) }
        // Any of the underline styles -- single, double, curly, dotted, dashed --
        // is drawn as a plain line for now.
        if style.underline != GHOSTTY_SGR_UNDERLINE_NONE.rawValue { attributes.insert(.underline) }
        return attributes
    }

    private func readCursor() -> Cursor? {
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(renderState,
                                       GHOSTTY_RENDER_STATE_DATA_CURSOR,
                                       &cursor) == GHOSTTY_SUCCESS,
              cursor.viewport_has_value
        else { return nil }

        return Cursor(
            x: cursor.viewport_x,
            y: cursor.viewport_y,
            shape: Cursor.Shape(cursor.visual_style),
            isVisible: cursor.visible)
    }

    // MARK: - input

    /// Encodes a key press into the bytes to send back.
    ///
    /// The encoder is re-synced from this terminal on every call, so a mode the
    /// remote program set in the output it just sent is already in effect. That
    /// coupling is why the encoder lives here instead of beside the view: it
    /// cannot be forgotten.
    ///
    /// `text` is what the platform says the keystroke produced. Pass it for
    /// ordinary typing; leave it empty for a control chord, which carries no
    /// text and would otherwise take the long way round.
    public func encode(key: GhosttyKey,
                       modifiers: KeyModifiers = [],
                       text: String = "",
                       unshiftedCodepoint: UInt32 = 0) -> [UInt8] {
        guard let keyEncoder else { return [] }
        keyEncoder.sync(with: terminal)
        return keyEncoder.encode(key: key,
                                 modifiers: modifiers,
                                 text: text,
                                 unshiftedCodepoint: unshiftedCodepoint)
    }

    // MARK: - plain text, for search and tests

    /// The visible screen as plain text.
    public func plainText() -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true

        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal, options) == GHOSTTY_SUCCESS
        else { return "" }
        defer { ghostty_formatter_free(formatter) }

        let sink = TextSink()
        let writer = GhosttyWriter(
            write: { userdata, bytes, len in
                guard let userdata, let bytes else { return false }
                Unmanaged<TextSink>.fromOpaque(userdata).takeUnretainedValue()
                    .data.append(bytes, count: len)
                return true
            },
            userdata: Unmanaged.passUnretained(sink).toOpaque())

        guard ghostty_formatter_format(formatter, writer) == GHOSTTY_SUCCESS else { return "" }
        return String(decoding: sink.data, as: UTF8.self)
    }
}

/// What an unspecified cursor looks like.
public enum CursorStyle: String, Sendable, CaseIterable, Codable {
    case bar
    case block
    case underline
    case hollowBlock

    var ghostty: GhosttyTerminalCursorStyle {
        switch self {
        case .bar: GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
        case .block: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
        case .underline: GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
        case .hollowBlock: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
        }
    }
}

/// Keyboard modifiers, mirroring the emulator's own bitmask.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let option = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let command = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
}

private final class TextSink {
    var data = Data()
}

extension Cursor.Shape {
    init(_ style: GhosttyRenderStateCursorVisualStyle) {
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:          self = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:    self = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: self = .hollowBlock
        default:                                                    self = .block
        }
    }
}

extension String {
    init(_ string: GhosttyString) {
        self.init(decoding: UnsafeBufferPointer(start: string.ptr, count: string.len), as: UTF8.self)
    }
}

extension Color {
    init(_ rgb: GhosttyColorRgb) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
