import Foundation
import GhosttyVt

extension Terminal {
    // MARK: - paste

    /// Turns pasted text into the bytes to send.
    ///
    /// Two things happen here that a naive `write` would get wrong. Control
    /// bytes are stripped, so a pasted escape sequence cannot drive the
    /// terminal. And when the far end has asked for bracketed paste, the text
    /// is wrapped in the markers that tell the shell "this is a paste" -- which
    /// is what stops a multi-line paste from executing line by line as it
    /// arrives, before the user has read it.
    public func encodePaste(_ text: String) -> [UInt8] {
        var input = Array(text.utf8).map { CChar(bitPattern: $0) }
        guard !input.isEmpty else { return [] }

        // Mode 2004 is bracketed paste. Queried rather than tracked, because
        // the remote program turns it on and off as it pleases.
        var query = GhosttyTerminalModeConfig()
        query.mode = ghostty_mode_new(2004, false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &query)
        let bracketedFlag = query.value

        // The encoder is asked for the size first; the wrapping makes the
        // result longer than the input.
        var needed = 0
        _ = ghostty_paste_encode(&input, input.count, bracketedFlag, nil, 0, &needed)

        var output = [CChar](repeating: 0, count: max(needed, input.count + 16))
        var written = 0
        guard ghostty_paste_encode(&input, input.count, bracketedFlag,
                                   &output, output.count, &written) == GHOSTTY_SUCCESS
        else { return [] }
        return output[0..<written].map { UInt8(bitPattern: $0) }
    }

    // MARK: - selection

    /// Starts a selection at a cell, as a click does.
    public func beginSelection(column: UInt16, row: UInt16) {
        dropAnchor()
        var tracked: GhosttyTrackedGridRef?
        guard ghostty_terminal_grid_ref_track(terminal, point(column: column, row: row),
                                              &tracked) == GHOSTTY_SUCCESS else { return }
        anchor = tracked
        anchorScreen = activeScreen
        extendSelection(column: column, row: row)
    }

    /// Moves the far end of the selection, as a drag does.
    ///
    /// The start is read afresh from the tracked anchor each time: output
    /// that arrived since the last call has moved the text, and the anchor
    /// with it. It belongs to the screen it was made on, so a switch to the
    /// other one ends the drag rather than handing over a foreign cell.
    public func extendSelection(column: UInt16, row: UInt16) {
        guard let anchor, anchorScreen == activeScreen else { return }
        var start = GhosttyGridRef()
        guard ghostty_tracked_grid_ref_snapshot(anchor, &start) == GHOSTTY_SUCCESS,
              let end = gridRef(column: column, row: row) else { return }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        selection.rectangle = false
        install(selection)
    }

    public func selectAll() {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS else { return }
        install(selection)
    }

    public func clearSelection() {
        dropAnchor()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    /// The selected text, or nil when nothing is selected.
    public func selectedText() -> String? {
        // A nil selection means "whatever the terminal currently has selected".
        formatted(selection: nil, trim: true)
    }

    /// A selection as plain text; nil when there is nothing in it.
    func formatted(selection: UnsafePointer<GhosttySelection>?, trim: Bool) -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = trim
        options.selection = selection

        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(terminal, nil, options,
                                                      &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer, length > 0
        else { return nil }
        defer { ghostty_free(nil, pointer, length) }

        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func dropAnchor() {
        ghostty_tracked_grid_ref_free(anchor)
        anchor = nil
    }

    /// A cell of the viewport, clamped to the grid.
    private func point(column: UInt16, row: UInt16) -> GhosttyPoint {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = min(column, cols > 0 ? cols - 1 : 0)
        point.value.coordinate.y = UInt32(min(row, rows > 0 ? rows - 1 : 0))
        return point
    }

    private func gridRef(column: UInt16, row: UInt16) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, point(column: column, row: row),
                                        &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    func install(_ selection: GhosttySelection) {
        var selection = selection
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }
}
