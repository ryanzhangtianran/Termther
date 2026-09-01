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
    /// Where the current drag selection started.
    var anchor: GhosttyGridRef?

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
    }

    deinit {
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
        guard ghostty_terminal_resize(terminal, cols, rows,
                                      cellWidth, cellHeight) == GHOSTTY_SUCCESS else { return }
        self.cols = cols
        self.rows = rows
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

    /// Terminal state a caller may need: the reported title, working directory,
    /// and the modes an input encoder has to follow.
    public func kittyKeyboardFlags() -> GhosttyKittyKeyFlags {
        var flags: GhosttyKittyKeyFlags = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags
    }

    // MARK: - frames out

    /// Pulls the next frame, or `nil` when nothing changed.
    ///
    /// Returning `nil` is the common case for an idle terminal and lets the
    /// renderer skip the frame entirely. Every call consumes the dirty state,
    /// so two calls in a row never report the same change twice.
    public func nextFrame() -> Frame? {
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return nil }

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
            defaultBackground: Color(colors.background))

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

        var collected: [Row] = []
        var y: UInt16 = 0
        while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
            guard ghostty_render_state_row_get(rowIterator,
                                               GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                               &cellIterator) == GHOSTTY_SUCCESS
            else { continue }
            collected.append(Row(y: y, cells: collectCells()))
        }
        return collected
    }

    private func collectCells() -> [Cell] {
        var cells: [Cell] = []
        cells.reserveCapacity(Int(cols))

        while ghostty_render_state_row_cells_next(cellIterator) {
            cells.append(Cell(
                text: readCellText(),
                foreground: readCellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR),
                background: readCellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR),
                attributes: readCellAttributes(),
                isSelected: readCellFlag(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED)))
        }
        return cells
    }

    /// The cell's whole grapheme cluster as UTF-8, so "é" or a flag emoji comes
    /// back as one string rather than a base codepoint plus loose marks.
    private func readCellText() -> String {
        var storage = [UInt8](repeating: 0, count: 32)
        return storage.withUnsafeMutableBufferPointer { raw -> String in
            var buffer = GhosttyBuffer(ptr: raw.baseAddress, cap: raw.count, len: 0)
            guard ghostty_render_state_row_cells_get(
                cellIterator,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                &buffer) == GHOSTTY_SUCCESS, buffer.len > 0
            else { return "" }
            return String(decoding: raw.prefix(buffer.len), as: UTF8.self)
        }
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
        if style.blink         { attributes.insert(.blink) }
        if style.inverse       { attributes.insert(.inverse) }
        if style.invisible     { attributes.insert(.invisible) }
        if style.strikethrough { attributes.insert(.strikethrough) }
        if style.overline      { attributes.insert(.overline) }
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
            isVisible: cursor.visible,
            isBlinking: cursor.blinking,
            isPasswordInput: cursor.password_input)
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
                                 modifiers: KeyEncoder.Modifiers(rawValue: modifiers.rawValue),
                                 text: text,
                                 unshiftedCodepoint: unshiftedCodepoint)
    }

    // MARK: - plain text, for search and tests

    /// The visible screen as plain text.
    public func plainText(trimmingTrailingWhitespace trim: Bool = true) -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = trim

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

    public var title: String {
        switch self {
        case .bar: "Bar"
        case .block: "Block"
        case .underline: "Underline"
        case .hollowBlock: "Hollow"
        }
    }

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

extension Color {
    init(_ rgb: GhosttyColorRgb) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
