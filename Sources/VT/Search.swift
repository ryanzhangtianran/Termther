import Foundation
import GhosttyVt

extension Terminal {
    // MARK: - search

    /// Looks for `needle` through the screen and the scrollback, the way an
    /// editor does: a needle in lower case matches any case, one with a
    /// capital in it matches only its own. The matches follow the text as
    /// output arrives; nothing is selected until `nextMatch`.
    public func search(_ needle: String) {
        if search == nil {
            var created: GhosttySearch?
            guard ghostty_search_new(nil, &created, terminal) == GHOSTTY_SUCCESS else { return }
            search = created
        }
        guard needle != searchNeedle else { return }
        searchNeedle = needle
        let bytes = Array(needle.utf8)
        bytes.withUnsafeBufferPointer { raw in
            var string = GhosttyString(ptr: raw.baseAddress, len: raw.count)
            _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
        }
        // A new needle drops the old matches, and the match that was selected
        // with them.
        clearSelection()
        searchIsStale = true
        needsFullRedraw = true
    }

    /// Forgets the matches. The selection stays on the last one found, so it
    /// can still be copied.
    public func endSearch() {
        ghostty_search_free(search)
        search = nil
        searchNeedle = ""
        needsFullRedraw = true
    }

    public var matchCount: Int { caseMatches().count }

    /// Which match is selected, counting from the newest, or nil when none is.
    public var currentMatchIndex: Int? {
        let wanted = caseMatches()
        return selectedIndex().flatMap { wanted.firstIndex(of: $0) }
    }

    /// Selects the next match up from the bottom of the screen into the
    /// scrollback, wrapping round, and scrolls to show it.
    public func nextMatch() { select(GHOSTTY_SEARCH_OPT_SELECT_NEXT) }

    public func previousMatch() { select(GHOSTTY_SEARCH_OPT_SELECT_PREV) }

    private func select(_ direction: GhosttySearchOption) {
        let wanted = Set(caseMatches())
        guard let search, !wanted.isEmpty else { return }
        // Past the matches of the wrong case, which the library counts too.
        for _ in 0..<totalMatches() {
            guard ghostty_search_set(search, direction, nil) == GHOSTTY_SUCCESS else { return }
            if let index = selectedIndex(), wanted.contains(index) { break }
        }
        var match = GhosttySelection()
        match.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH,
                                 &match) == GHOSTTY_SUCCESS else { return }
        install(match)
        needsFullRedraw = true
    }

    private var isCaseSensitive: Bool { searchNeedle.contains(where: \.isUppercase) }

    /// The library only matches regardless of case, so a needle with a
    /// capital keeps the matches that are its case exactly. These are
    /// indices into the library's list, newest first.
    private func caseMatches() -> [Int] {
        catchUp()
        guard isCaseSensitive else { return Array(0..<totalMatches()) }
        let all = matches(GHOSTTY_SEARCH_DATA_MATCHES)
        return all.indices.filter { text(of: all[$0]) == searchNeedle }
    }

    /// Reads the terminal since the last time, which the library does not do
    /// on its own: the search sees nothing of the output until it is fed.
    private func catchUp() {
        guard let search, searchIsStale else { return }
        searchIsStale = false
        _ = ghostty_search_run(search)
    }

    private func totalMatches() -> Int {
        var total = 0
        _ = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        return total
    }

    private func selectedIndex() -> Int? {
        var index = 0
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX,
                                 &index) == GHOSTTY_SUCCESS else { return nil }
        return index
    }

    /// One of the library's lists of matches: asked for its size first.
    private func matches(_ list: GhosttySearchData) -> [GhosttySelection] {
        var probe = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        guard ghostty_search_get(search, list, &probe) == GHOSTTY_OUT_OF_SPACE,
              probe.len > 0 else { return [] }
        var blank = GhosttySelection()
        blank.size = MemoryLayout<GhosttySelection>.size
        var storage = [GhosttySelection](repeating: blank, count: probe.len)
        return storage.withUnsafeMutableBufferPointer { raw in
            var buffer = GhosttySelectionBuffer(ptr: raw.baseAddress, cap: raw.count, len: 0)
            guard ghostty_search_get(search, list, &buffer) == GHOSTTY_SUCCESS else { return [] }
            return Array(raw.prefix(buffer.len))
        }
    }

    private func text(of match: GhosttySelection) -> String? {
        var match = match
        return withUnsafePointer(to: &match) { formatted(selection: $0, trim: false) }
    }

    /// The cells of the matches in view, by row, for the renderer to tint.
    /// The selected one is drawn as the selection it is.
    func matchCells() -> [UInt16: [ClosedRange<Int>]] {
        guard search != nil else { return [:] }
        catchUp()
        var byRow: [UInt16: [ClosedRange<Int>]] = [:]
        for var match in matches(GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES) {
            if isCaseSensitive, text(of: match) != searchNeedle { continue }
            var ordered = GhosttySelection()
            ordered.size = MemoryLayout<GhosttySelection>.size
            var start = GhosttyPointCoordinate()
            var end = GhosttyPointCoordinate()
            // The list covers whole pages; a match off the viewport's edge
            // fails to convert, or lands past the last row.
            guard ghostty_terminal_selection_ordered(terminal, &match, GHOSTTY_SELECTION_ORDER_FORWARD,
                                                     &ordered) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal, &ordered.start, GHOSTTY_POINT_TAG_VIEWPORT,
                                                       &start) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal, &ordered.end, GHOSTTY_POINT_TAG_VIEWPORT,
                                                       &end) == GHOSTTY_SUCCESS,
                  end.y < rows else { continue }
            for y in start.y...end.y {
                let from = y == start.y ? Int(start.x) : 0
                let to = y == end.y ? Int(end.x) : Int(cols) - 1
                byRow[UInt16(y), default: []].append(from...to)
            }
        }
        return byRow
    }
}
