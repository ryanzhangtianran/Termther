import AppKit
import GhosttyVt
import Metal
import QuartzCore

/// An NSView that shows a terminal.
///
/// The view owns the emulator and the renderer and knows nothing about where
/// bytes come from: it hands keystrokes to `onInput` and expects someone to
/// feed `write(_:)`. That keeps a local shell, an SSH channel and a replay file
/// interchangeable.
@MainActor
public final class TerminalView: NSView {
    public let terminal: Terminal
    private(set) var renderer: CellRenderer
    private let metalLayer = CAMetalLayer()
    private var displayTimer: Timer?

    /// Rounds the view's own corners.
    ///
    /// A `CAMetalLayer` draws straight to the screen and ignores whatever
    /// SwiftUI clipped around it, so a terminal inside a rounded card keeps
    /// square corners over a rounded background -- which reads as the card's
    /// radius changing whenever the terminal is resized.
    public var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    /// Bytes the user typed, to be sent to whatever is on the other end.
    public var onInput: (([UInt8]) -> Void)?
    /// The grid was resized; the far end usually needs telling.
    public var onResize: ((UInt16, UInt16) -> Void)?
    /// The view took the keyboard, by a click or by being given it.
    public var onFocus: (() -> Void)?

    public init(terminal: Terminal, renderer: CellRenderer) {
        self.terminal = terminal
        self.renderer = renderer
        super.init(frame: .zero)

        wantsLayer = true
        // The Metal layer goes *inside* a container rather than being the
        // view's own layer. A CAMetalLayer presents its drawable straight to
        // the compositor and ignores its own cornerRadius, so the only way to
        // round a terminal is to mask the layer above it.
        let container = CALayer()
        container.masksToBounds = true
        container.addSublayer(metalLayer)
        layer = container

        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true

        // Pull frames at display rate. `nextFrame()` returns nil when nothing
        // changed, so an idle terminal costs one cheap call per tick rather
        // than a redraw.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Added to the main run loop, so it fires on the main thread.
            MainActor.assumeIsolated { self?.pullFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Stops the frame timer. The view holds it through the run loop, so it
    /// has to be broken explicitly rather than left to deallocation.
    public func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    public override var isFlipped: Bool { true }

    // MARK: - sizing

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func layout() {
        super.layout()
        // Without disabling actions the sublayer animates to each new size,
        // which during a sidebar toggle looks like the corners changing shape.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
        if let searchBar {
            searchBar.frame.origin = NSPoint(x: bounds.width - searchBar.frame.width - 12, y: 12)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followBackingScale()
        updateDrawableSize()
    }

    /// Called when the window moves to a screen of another density, among
    /// other things.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        followBackingScale()
        updateDrawableSize()
    }

    /// Rasterises at the window's own density. A renderer made for another
    /// screen measures its cells in the wrong pixels, so the grid is sized
    /// wrongly for the drawable and every glyph is scaled on the way out.
    private func followBackingScale() {
        guard let scale = window?.backingScaleFactor, scale != renderer.scale else { return }
        replaceRenderer(fonts: renderer.fonts, scale: scale)
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixels.width > 0, pixels.height > 0 else { return }
        metalLayer.drawableSize = pixels

        let cell = renderer.cellSizeInPixels
        let cols = UInt16(max(1, Int(pixels.width / cell.width)))
        let rows = UInt16(max(1, Int(pixels.height / cell.height)))

        // Numbered, so a measurement that loses the race to the terminal is
        // dropped instead of undoing a newer one; see `Terminal.fit`.
        measurements += 1
        let order = measurements
        Task {
            guard await terminal.fit(cols: cols, rows: rows,
                                     cellWidth: UInt32(cell.width),
                                     cellHeight: UInt32(cell.height), order: order),
                  order > reported else { return }
            // And the far end hears only the newest, in order.
            reported = order
            onResize?(cols, rows)
        }
    }

    private var measurements = 0
    private var reported = 0

    /// New fonts, or new line height and letter spacing, in a terminal that
    /// is already running: a renderer at the new cell size, the grid refitted
    /// to it, and everything redrawn -- the contents did not change, so
    /// nothing else would redraw them.
    public func setFonts(_ fonts: FontStack) {
        replaceRenderer(fonts: fonts, scale: renderer.scale)
        updateDrawableSize()
    }

    /// A new renderer carrying the old one's settings, and a full redraw to
    /// fill it: it starts with an empty grid.
    private func replaceRenderer(fonts: FontStack, scale: CGFloat) {
        guard let replacement = try? CellRenderer(device: renderer.device, fonts: fonts,
                                                  scale: scale) else { return }
        replacement.cursorMotion = renderer.cursorMotion
        replacement.preedit = renderer.preedit
        renderer = replacement
        Task { await terminal.invalidate() }
    }

    // MARK: - drawing

    public func write(_ bytes: [UInt8]) {
        Task { await terminal.write(bytes) }
    }

    /// The renderer has something the screen does not show yet: a frame that
    /// found no drawable, or a change to the composition.
    private var isStale = false
    /// A frame is on its way from the terminal. A tick that finds one is
    /// skipped: the terminal keeps what changed until it is asked, so the
    /// next pull brings all of it, and a flood of output is not answered by
    /// a queue of pulls each drawing a full frame.
    private var isPulling = false

    private func pullFrame() {
        guard !isPulling else { return }
        isPulling = true
        Task {
            let frame = await terminal.nextFrame()
            isPulling = false
            // Applied whether or not there is anything to draw into: the
            // terminal has already forgotten what changed, and a frame
            // dropped here would leave those rows stale until they next
            // change.
            if let frame {
                renderer.apply(frame)
                isStale = true
                if let cursor = frame.cursor { cursorCell = cursor }
            }
            // A nil frame means the terminal did not change -- but the
            // cursor may still be easing into place, which needs redraws of
            // its own. Skipping only when all are idle is what keeps an
            // idle terminal at zero GPU work.
            if isStale || renderer.isAnimating, let drawable = metalLayer.nextDrawable() {
                isStale = false
                renderer.draw(to: drawable)
            }
            // Output can bring matches with it, or take them away.
            if frame != nil, searchBar?.isHidden == false { await showMatchCount() }
        }
    }

    // MARK: - search

    /// The find bar, once it has been asked for.
    private var searchBar: SearchBar?

    /// Shows the find bar, with the keyboard in it.
    public func beginSearch() {
        let bar = searchBar ?? makeSearchBar()
        bar.isHidden = false
        needsLayout = true
        window?.makeFirstResponder(bar.field)
        // What was there last time is searched again, and offered up to be
        // typed over.
        if !bar.field.stringValue.isEmpty { bar.onChange?(bar.field.stringValue) }
        bar.field.selectText(nil)
    }

    /// Hides the bar and puts the keyboard back in the terminal.
    public func endSearch() {
        guard let searchBar, !searchBar.isHidden else { return }
        searchBar.isHidden = true
        Task { await terminal.endSearch() }
        window?.makeFirstResponder(self)
    }

    private func makeSearchBar() -> SearchBar {
        let bar = SearchBar()
        bar.onChange = { [weak self] needle in
            guard let self else { return }
            Task {
                await self.terminal.search(needle)
                // Straight to the nearest match, as typing in Terminal.app
                // does; Enter then goes on from it.
                if await self.terminal.currentMatchIndex == nil { await self.terminal.nextMatch() }
                await self.showMatchCount()
            }
        }
        bar.onStep = { [weak self] forward in self?.stepMatch(forward: forward) }
        bar.onClose = { [weak self] in self?.endSearch() }
        addSubview(bar)
        searchBar = bar
        return bar
    }

    private func stepMatch(forward: Bool) {
        Task {
            if forward { await terminal.nextMatch() } else { await terminal.previousMatch() }
            await showMatchCount()
        }
    }

    private func showMatchCount() async {
        let index = await terminal.currentMatchIndex
        let total = await terminal.matchCount
        searchBar?.show(index: index, of: total)
    }

    /// ⌘G and ⇧⌘G step through the matches while the bar is open, whether
    /// the keyboard is in it or back in the terminal. Asked before the menu
    /// is, and of every terminal in the window, so only the focused one
    /// answers.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let searchBar, !searchBar.isHidden,
              window?.firstResponder === self || searchBar.field.currentEditor() != nil,
              modifiers.subtracting(.shift) == .command,
              event.charactersIgnoringModifiers == "g"
        else { return super.performKeyEquivalent(with: event) }
        stepMatch(forward: !modifiers.contains(.shift))
        return true
    }

    // MARK: - input

    public override func keyDown(with event: NSEvent) {
        // Command chords belong to the app -- copy, paste, new tab -- not to
        // the terminal. Passing them on lets the menu and the responder chain
        // handle them; swallowing them here made ⌘C type the letter "c".
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        // The input method sees every key first: it may be composing --
        // Pinyin, kana, a dead key's accent -- and then the key is its. What
        // it commits arrives through `insertText`, collected here.
        let wasComposing = hasMarkedText()
        committed = []
        interpretKeyEvents([event])
        let text = committed ?? []
        committed = nil
        if wasComposing || hasMarkedText() {
            if !text.isEmpty { send(text.joined()) }
            return
        }

        // Page Up and Page Down (fn-↑, fn-↓) page through the scrollback, as
        // in Terminal.app; in a full-screen program they are its keys.
        let page = [116: -1, 121: 1][event.keyCode]
        Task {
            if let page, await terminal.scrollPage(page) { return }
            // Typing returns to the live screen, where the typing shows.
            await terminal.scrollToBottom()
            let bytes = await self.encode(event, text: text.isEmpty ? nil : text.joined())
            guard !bytes.isEmpty else { return }
            self.onInput?(bytes)
        }
    }

    /// Text an input method committed during the current `keyDown`; nil
    /// outside one.
    private var committed: [String]?
    /// What the input method is composing, not yet sent.
    private var marked = NSMutableAttributedString()
    /// Where the cursor was last seen, for placing the input method's window.
    private var cursorCell: Cursor?

    /// Committed text, straight to the far end.
    private func send(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        Task {
            await terminal.scrollToBottom()
            self.onInput?(bytes)
        }
    }

    // MARK: - scrolling

    /// Rows not yet scrolled: a trackpad moves in points, a fraction of a row
    /// at a time.
    private var pendingRows: CGFloat = 0

    public override func scrollWheel(with event: NSEvent) {
        let rowHeight = renderer.cellSizeInPixels.height / (window?.backingScaleFactor ?? 2)
        // A trackpad reports points; a wheel reports notches, three rows each.
        pendingRows += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / max(rowHeight, 1)
            : event.scrollingDeltaY * 3
        let rows = Int(pendingRows)
        guard rows != 0 else { return }
        pendingRows -= CGFloat(rows)
        let cell = gridPosition(of: event)
        Task {
            // Content follows the fingers: moving them down shows what is above.
            let bytes = await terminal.scroll(lines: -rows, column: cell.column, row: cell.row)
            guard !bytes.isEmpty else { return }
            self.onInput?(bytes)
        }
    }

    /// Turns a key press into bytes.
    ///
    /// Three paths, because the emulator's encoder and the platform each know
    /// something the other does not:
    ///
    ///   1. Special keys -- Enter, Tab, Backspace, arrows -- always go to the
    ///      encoder, because their bytes depend on modes the remote program
    ///      set. AppKit reports arrows as private-use characters that must
    ///      never be sent.
    ///   2. Control chords go to the encoder too, so Ctrl+\\ and Ctrl+] work
    ///      and not just the letters AppKit happens to transform.
    ///   3. Everything else is ordinary typing, where the platform is
    ///      authoritative: it has already applied Shift, the keyboard layout
    ///      and whatever an input method composed.
    ///
    /// Named and control keys are described by key, modifiers and the
    /// unshifted codepoint. Keeping platform text out of that path avoids
    /// making its precedence part of this view's contract.
    ///
    /// `text` is what the input method made of the key, when it made
    /// anything; it stands in for the event's own characters.
    func encode(_ event: NSEvent, text: String? = nil) async -> [UInt8] {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }

        let key = KeyMap.key(for: event.keyCode)
        let isSpecial = KeyMap.isSpecial(event.keyCode)
        let isKeypad = KeyMap.isKeypad(event.keyCode)
        let holdsControl = modifiers.contains(.control)

        if let key, isSpecial || isKeypad || holdsControl {
            let reported = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            let codepoint = KeyMap.codepoint(from: reported)
            // The keypad's digits and operators are typing, unless the program
            // asked for application keypad mode; the encoder decides, given
            // the character for when they are.
            let typed = isKeypad && !holdsControl ? KeyMap.text(event.characters ?? "") : ""
            let encoded = await terminal.encode(key: key, modifiers: modifiers, text: typed,
                                                unshiftedCodepoint: codepoint)
            if !encoded.isEmpty { return encoded }

            // Safety net for control chords the encoder declines to produce --
            // Ctrl+[ among them, which vim users press instead of Escape all
            // day. The ASCII rule is the low five bits of the character.
            if holdsControl, let source = codepoint.asciiControlSource {
                return [source & 0x1f]
            }
            return []
        }

        // AppKit's function-key scalars are never text, whatever key they
        // came from.
        let typed = (text ?? event.characters ?? "").unicodeScalars
            .filter { !KeyMap.isFunctionKeyScalar($0.value) }
        return Array(String(String.UnicodeScalarView(typed)).utf8)
    }

    // MARK: - copy and paste

    /// Right-click: Copy and Paste, as Terminal.app offers. Sent to this view,
    /// which is where the selection and the pasteboard handling live.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc public func copy(_ sender: Any?) {
        Task {
            guard let text = await terminal.selectedText(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task {
            // Bracketed paste when the far end asked for it: it tells the shell
            // this is pasted text, so a multi-line paste is not executed line
            // by line as it arrives.
            await terminal.scrollToBottom()
            let bytes = await terminal.encodePaste(text)
            self.onInput?(bytes)
        }
    }

    @objc public override func selectAll(_ sender: Any?) {
        Task { await terminal.selectAll() }
    }

    // MARK: - selection

    /// Where a press landed, and whether it has turned into a drag.
    ///
    /// A selection is only started once the pointer actually moves. Beginning
    /// one on mouse-down instead selects the single cell under the pointer,
    /// which paints a block on the screen every time someone clicks the
    /// terminal to focus it.
    private var pressedAt: (column: UInt16, row: UInt16)?
    private var isDragging = false
    /// While the pointer is dragged past the top or bottom edge, the
    /// scrollback moves under it and the selection follows, as long as it
    /// stays out: mouseDragged only fires on movement.
    private var edgeScroll: Timer?
    private var edgeRows = 0

    /// Whether the press under way went to the program rather than to a
    /// selection, so its drag and release follow it there.
    private var reportsPress = false

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A program that asked for the mouse gets the click -- Claude Code's
        // buttons, vim's cursor, htop's rows. Shift keeps it the terminal's,
        // for selecting text, as in Ghostty and iTerm.
        if terminal.wantsMouse, !event.modifierFlags.contains(.shift) {
            reportsPress = true
            reportMouse(GHOSTTY_MOUSE_ACTION_PRESS, event)
            return
        }
        pressedAt = gridPosition(of: event)
        isDragging = false
        Task { await terminal.clearSelection() }
    }

    public override func mouseDragged(with event: NSEvent) {
        if reportsPress { reportMouse(GHOSTTY_MOUSE_ACTION_MOTION, event); return }
        guard let start = pressedAt else { return }
        let point = gridPosition(of: event)

        if !isDragging {
            // Ignore the pixel of travel a click picks up on its way to being
            // released, so a click stays a click.
            guard point != start else { return }
            isDragging = true
            Task { await terminal.beginSelection(column: start.column, row: start.row) }
        }
        Task { await terminal.extendSelection(column: point.column, row: point.row) }

        // Past an edge: a row a tick in that direction, faster further out.
        let local = convert(event.locationInWindow, from: nil)
        let past = local.y < 0 ? local.y : local.y > bounds.height ? local.y - bounds.height : 0
        edgeRows = Int((past / 20).rounded(.awayFromZero))
        if edgeRows != 0, edgeScroll == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scrollSelectionEdge(column: point.column) }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgeScroll = timer
        } else if edgeRows == 0 {
            edgeScroll?.invalidate()
            edgeScroll = nil
        }
    }

    private func scrollSelectionEdge(column: UInt16) {
        let rows = edgeRows
        guard rows != 0, isDragging else { return }
        Task {
            await terminal.scrollViewport(by: rows)
            let edge: UInt16 = rows < 0 ? 0 : await terminal.rows - 1
            await terminal.extendSelection(column: column, row: edge)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if reportsPress {
            reportsPress = false
            reportMouse(GHOSTTY_MOUSE_ACTION_RELEASE, event)
            return
        }
        pressedAt = nil
        isDragging = false
        edgeScroll?.invalidate()
        edgeScroll = nil
    }

    /// Sends a left-button press, drag or release to the program, in the
    /// pixels and protocol it asked for.
    private func reportMouse(_ action: GhosttyMouseAction, _ event: NSEvent) {
        let scale = window?.backingScaleFactor ?? 2
        let local = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSizeInPixels
        let size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: UInt32(max(0, bounds.width * scale)), screen_height: UInt32(max(0, bounds.height * scale)),
            cell_width: UInt32(max(1, cell.width)), cell_height: UInt32(max(1, cell.height)),
            padding_top: 0, padding_bottom: 0, padding_right: 0, padding_left: 0)
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        let x = Float(max(0, local.x * scale)), y = Float(max(0, local.y * scale))
        Task {
            let bytes = await terminal.encodeMouse(action, button: GHOSTTY_MOUSE_BUTTON_LEFT, x: x, y: y,
                                                   size: size, modifiers: modifiers,
                                                   isPressed: action != GHOSTTY_MOUSE_ACTION_RELEASE)
            guard !bytes.isEmpty else { return }
            self.onInput?(bytes)
        }
    }

    /// Converts a click to a grid cell, clamped so a drag past the edge selects
    /// to the edge rather than doing nothing.
    private func gridPosition(of event: NSEvent) -> (column: UInt16, row: UInt16) {
        let local = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        let cell = renderer.cellSizeInPixels
        let column = max(0, (local.x * scale) / cell.width)
        let row = max(0, (local.y * scale) / cell.height)
        return (UInt16(min(column, 9999)), UInt16(min(row, 9999)))
    }

}

// MARK: - input methods

/// Just enough of a text view for input methods to work: composition shown
/// at the cursor, committed text sent, and the candidate window placed beside
/// the cursor. There is no document to edit, so the ranges are all relative
/// to the composition itself.
extension TerminalView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        // Inside `keyDown` the key's own handling decides what is sent; from
        // anywhere else -- the character viewer, dictation -- it is sent now.
        if committed != nil { committed?.append(text) } else { send(text) }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString).map(NSMutableAttributedString.init)
            ?? NSMutableAttributedString(string: (string as? String) ?? "")
        showComposition()
    }

    public func unmarkText() {
        guard marked.length > 0 else { return }
        marked = NSMutableAttributedString()
        showComposition()
    }

    private func showComposition() {
        renderer.preedit = marked.length > 0 ? marked.string : nil
        isStale = true
    }

    public func hasMarkedText() -> Bool { marked.length > 0 }

    public func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length)
                          : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: marked.length, length: 0)
    }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        let whole = NSRange(location: 0, length: marked.length)
        let clipped = NSIntersectionRange(range, whole)
        guard clipped.length > 0 else { return nil }
        actualRange?.pointee = clipped
        return marked.attributedSubstring(from: clipped)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The cursor's cell, in screen coordinates, which is where the input
    /// method puts its candidates.
    public func firstRect(forCharacterRange range: NSRange,
                          actualRange: NSRangePointer?) -> NSRect {
        let pixels = renderer.cellSizeInPixels
        let cell = NSSize(width: pixels.width / renderer.scale,
                          height: pixels.height / renderer.scale)
        let local = NSRect(x: CGFloat(cursorCell?.x ?? 0) * cell.width,
                           y: CGFloat(cursorCell?.y ?? 0) * cell.height,
                           width: cell.width, height: cell.height)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Keys the input method did not want arrive as commands -- `insertNewline:`,
    /// `moveLeft:` -- and are ignored here: `keyDown` encodes them itself, by
    /// the modes the far end set. Overridden, too, so they do not beep.
    public override func doCommand(by selector: Selector) {}
}

private extension UInt32 {
    /// The characters that have a control-code form: @ A-Z [ \\ ] ^ _ and,
    /// by the same rule, the lowercase letters.
    var asciiControlSource: UInt8? {
        switch self {
        case 0x40...0x5F, 0x61...0x7A: UInt8(self)
        default: nil
        }
    }
}

enum KeyMap {
    /// macOS virtual key codes to the emulator's key identifiers.
    ///
    /// Letters and digits are mapped too, not just the special keys: a control
    /// chord has to reach the encoder to be turned into its byte, and relying
    /// on AppKit's own character transformation instead means Ctrl+C works only
    /// by accident and Ctrl+[ or Ctrl+\\ not at all.
    static func key(for keyCode: UInt16) -> GhosttyKey? { table[keyCode] }

    /// Keys that carry no text of their own and must always be encoded.
    ///
    /// AppKit does report `characters` for these -- "\r" for Return, and
    /// private-use scalars for the arrows -- but those are not what a terminal
    /// wants on the wire.
    static func isSpecial(_ keyCode: UInt16) -> Bool { specials.contains(keyCode) }

    /// The keypad's digits and operators. They type their character, but in
    /// application keypad mode a program wants escape sequences for them
    /// instead, so they go to the encoder carrying that character.
    static func isKeypad(_ keyCode: UInt16) -> Bool { keypad.contains(keyCode) }

    /// Whether a scalar is one of AppKit's function-key codes rather than text.
    static func isFunctionKeyScalar(_ scalar: UInt32) -> Bool { (0xF700...0xF8FF).contains(scalar) }

    /// Platform text worth handing the encoder alongside a key: none at all if
    /// it holds a control character or a function-key scalar, which the
    /// encoder must not be given.
    static func text(_ characters: String) -> String {
        characters.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || isFunctionKeyScalar($0.value)
        } ? "" : characters
    }

    /// The scalar worth handing the encoder, or nothing.
    ///
    /// AppKit reports the arrows, Home, End and the function keys as scalars
    /// in the private-use area from 0xF700 up. They are not text, and the
    /// encoder handed one takes the modifyOtherKeys path and answers with the
    /// wrong bytes or none at all -- which is why pressing Left moved nothing.
    /// Only a real character is worth passing, and only a control chord needs
    /// one at all.
    static func codepoint(from reported: UInt32) -> UInt32 {
        isFunctionKeyScalar(reported) ? 0 : reported
    }

    /// Keypad Enter is here and not with the keypad: AppKit reports it as
    /// 0x03, which sent as text is Ctrl+C.
    private static let specials: Set<UInt16> = [
        0x24, 0x30, 0x33, 0x35, 0x75, 0x4C,         // enter tab backspace esc delete, keypad enter
        0x7B, 0x7C, 0x7D, 0x7E,                     // arrows
        0x73, 0x77, 0x74, 0x79, 0x72,               // home end page up/down, help (insert)
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61,         // F1-F6
        0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,         // F7-F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, // F13-F20
    ]

    private static let keypad: Set<UInt16> = [
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,  // 0-9
        0x41, 0x43, 0x45, 0x4B, 0x4E, 0x51, 0x47,                    // . * + / - = clear
    ]

    private static let table: [UInt16: GhosttyKey] = [
        0x00: GHOSTTY_KEY_A, 0x0B: GHOSTTY_KEY_B, 0x08: GHOSTTY_KEY_C, 0x02: GHOSTTY_KEY_D,
        0x0E: GHOSTTY_KEY_E, 0x03: GHOSTTY_KEY_F, 0x05: GHOSTTY_KEY_G, 0x04: GHOSTTY_KEY_H,
        0x22: GHOSTTY_KEY_I, 0x26: GHOSTTY_KEY_J, 0x28: GHOSTTY_KEY_K, 0x25: GHOSTTY_KEY_L,
        0x2E: GHOSTTY_KEY_M, 0x2D: GHOSTTY_KEY_N, 0x1F: GHOSTTY_KEY_O, 0x23: GHOSTTY_KEY_P,
        0x0C: GHOSTTY_KEY_Q, 0x0F: GHOSTTY_KEY_R, 0x01: GHOSTTY_KEY_S, 0x11: GHOSTTY_KEY_T,
        0x20: GHOSTTY_KEY_U, 0x09: GHOSTTY_KEY_V, 0x0D: GHOSTTY_KEY_W, 0x07: GHOSTTY_KEY_X,
        0x10: GHOSTTY_KEY_Y, 0x06: GHOSTTY_KEY_Z,

        0x1D: GHOSTTY_KEY_DIGIT_0, 0x12: GHOSTTY_KEY_DIGIT_1, 0x13: GHOSTTY_KEY_DIGIT_2,
        0x14: GHOSTTY_KEY_DIGIT_3, 0x15: GHOSTTY_KEY_DIGIT_4, 0x17: GHOSTTY_KEY_DIGIT_5,
        0x16: GHOSTTY_KEY_DIGIT_6, 0x1A: GHOSTTY_KEY_DIGIT_7, 0x1C: GHOSTTY_KEY_DIGIT_8,
        0x19: GHOSTTY_KEY_DIGIT_9,

        0x1B: GHOSTTY_KEY_MINUS, 0x18: GHOSTTY_KEY_EQUAL,
        0x21: GHOSTTY_KEY_BRACKET_LEFT, 0x1E: GHOSTTY_KEY_BRACKET_RIGHT,
        0x2A: GHOSTTY_KEY_BACKSLASH, 0x29: GHOSTTY_KEY_SEMICOLON, 0x27: GHOSTTY_KEY_QUOTE,
        0x2B: GHOSTTY_KEY_COMMA, 0x2F: GHOSTTY_KEY_PERIOD, 0x2C: GHOSTTY_KEY_SLASH,
        0x32: GHOSTTY_KEY_BACKQUOTE, 0x31: GHOSTTY_KEY_SPACE,

        0x24: GHOSTTY_KEY_ENTER, 0x30: GHOSTTY_KEY_TAB, 0x33: GHOSTTY_KEY_BACKSPACE,
        0x35: GHOSTTY_KEY_ESCAPE, 0x75: GHOSTTY_KEY_DELETE,
        0x7B: GHOSTTY_KEY_ARROW_LEFT, 0x7C: GHOSTTY_KEY_ARROW_RIGHT,
        0x7D: GHOSTTY_KEY_ARROW_DOWN, 0x7E: GHOSTTY_KEY_ARROW_UP,
        0x73: GHOSTTY_KEY_HOME, 0x77: GHOSTTY_KEY_END,
        0x74: GHOSTTY_KEY_PAGE_UP, 0x79: GHOSTTY_KEY_PAGE_DOWN,
        // Mac keyboards have Help where others have Insert, and send it for
        // Insert on a PC keyboard.
        0x72: GHOSTTY_KEY_INSERT,

        0x7A: GHOSTTY_KEY_F1, 0x78: GHOSTTY_KEY_F2, 0x63: GHOSTTY_KEY_F3, 0x76: GHOSTTY_KEY_F4,
        0x60: GHOSTTY_KEY_F5, 0x61: GHOSTTY_KEY_F6, 0x62: GHOSTTY_KEY_F7, 0x64: GHOSTTY_KEY_F8,
        0x65: GHOSTTY_KEY_F9, 0x6D: GHOSTTY_KEY_F10, 0x67: GHOSTTY_KEY_F11, 0x6F: GHOSTTY_KEY_F12,
        0x69: GHOSTTY_KEY_F13, 0x6B: GHOSTTY_KEY_F14, 0x71: GHOSTTY_KEY_F15, 0x6A: GHOSTTY_KEY_F16,
        0x40: GHOSTTY_KEY_F17, 0x4F: GHOSTTY_KEY_F18, 0x50: GHOSTTY_KEY_F19, 0x5A: GHOSTTY_KEY_F20,

        0x52: GHOSTTY_KEY_NUMPAD_0, 0x53: GHOSTTY_KEY_NUMPAD_1, 0x54: GHOSTTY_KEY_NUMPAD_2,
        0x55: GHOSTTY_KEY_NUMPAD_3, 0x56: GHOSTTY_KEY_NUMPAD_4, 0x57: GHOSTTY_KEY_NUMPAD_5,
        0x58: GHOSTTY_KEY_NUMPAD_6, 0x59: GHOSTTY_KEY_NUMPAD_7, 0x5B: GHOSTTY_KEY_NUMPAD_8,
        0x5C: GHOSTTY_KEY_NUMPAD_9,
        0x41: GHOSTTY_KEY_NUMPAD_DECIMAL, 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x45: GHOSTTY_KEY_NUMPAD_ADD, 0x4B: GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x4E: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x51: GHOSTTY_KEY_NUMPAD_EQUAL,
        0x47: GHOSTTY_KEY_NUMPAD_CLEAR, 0x4C: GHOSTTY_KEY_NUMPAD_ENTER,
    ]
}
