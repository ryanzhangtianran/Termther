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
    let renderer: CellRenderer
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
            Task { @MainActor in self?.pullFrame() }
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
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
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

        Task {
            let current = await (terminal.cols, terminal.rows)
            guard current != (cols, rows) else { return }
            await terminal.resize(cols: cols, rows: rows,
                                  cellWidth: UInt32(cell.width),
                                  cellHeight: UInt32(cell.height))
            await MainActor.run { self.onResize?(cols, rows) }
        }
    }

    // MARK: - drawing

    public func write(_ bytes: [UInt8]) {
        Task { await terminal.write(bytes) }
    }

    @MainActor
    private func pullFrame() {
        Task {
            let frame = await terminal.nextFrame()
            await MainActor.run {
                // A nil frame means the terminal did not change -- but the
                // cursor may still be easing into place, which needs redraws of
                // its own. Skipping only when both are idle is what keeps an
                // idle terminal at zero GPU work.
                guard frame != nil || self.renderer.isAnimating else { return }
                guard let drawable = self.metalLayer.nextDrawable() else { return }
                if let frame { try? self.renderer.apply(frame) }
                self.renderer.draw(into: drawable.texture)
                drawable.present()
            }
        }
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
        Task {
            let bytes = await self.encode(event)
            guard !bytes.isEmpty else { return }
            await MainActor.run { self.onInput?(bytes) }
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
    /// The encoder must never be given the platform's text. Doing so makes it
    /// take the modifyOtherKeys path, which turns Return into "0", Backspace
    /// into nothing, and the letter "a" into "P".
    func encode(_ event: NSEvent) async -> [UInt8] {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }

        let key = KeyMap.key(for: event.keyCode)
        let isSpecial = KeyMap.isSpecial(event.keyCode)
        let holdsControl = modifiers.contains(.control)

        if let key, isSpecial || holdsControl {
            let codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            let encoded = await terminal.encode(key: key, modifiers: modifiers,
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

        return Array((event.characters ?? "").utf8)
    }

    // MARK: - copy and paste

    @objc public func copy(_ sender: Any?) {
        Task {
            guard let text = await terminal.selectedText(), !text.isEmpty else { return }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task {
            // Bracketed paste when the far end asked for it: it tells the shell
            // this is pasted text, so a multi-line paste is not executed line
            // by line as it arrives.
            let bytes = await terminal.encodePaste(text)
            await MainActor.run { self.onInput?(bytes) }
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

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedAt = gridPosition(of: event)
        isDragging = false
        Task { await terminal.clearSelection() }
    }

    public override func mouseDragged(with event: NSEvent) {
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
    }

    public override func mouseUp(with event: NSEvent) {
        pressedAt = nil
        isDragging = false
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

    private static let specials: Set<UInt16> = [
        0x24, 0x30, 0x33, 0x35, 0x75,               // enter tab backspace esc delete
        0x7B, 0x7C, 0x7D, 0x7E,                     // arrows
        0x73, 0x77, 0x74, 0x79,                     // home end page up/down
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
    ]
}
