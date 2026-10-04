import GhosttyVt
import Testing
@testable import VT

/// Named keys are fully described by key + modifiers. Passing the platform's
/// text alongside them makes the encoder take the modifyOtherKeys path and emit
/// nonsense -- Return became 0x30, the character "0", and Backspace vanished.
/// These pin the encodings that a shell will not work without.
@Test("the keys a shell cannot live without encode correctly")
func essentialKeys() async throws {
    let terminal = try Terminal()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER) == [0x0d])
    #expect(await terminal.encode(key: GHOSTTY_KEY_TAB) == [0x09])
    #expect(await terminal.encode(key: GHOSTTY_KEY_BACKSPACE) == [0x7f])
    #expect(await terminal.encode(key: GHOSTTY_KEY_ESCAPE) == [0x1b])
}

@Test("named keys remain correct when the event also carries text")
func textDoesNotPoisonNamedKeys() async throws {
    // Current Ghostty releases correctly prioritize the named key. Keep this
    // pinned because older releases took the modifyOtherKeys path instead.
    let terminal = try Terminal()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER, text: "\r") == [0x0d])
}

@Test("the virtual key codes a terminal needs are all mapped")
func keyMapCoverage() {
    #expect(KeyMap.key(for: 0x24) == GHOSTTY_KEY_ENTER)
    #expect(KeyMap.key(for: 0x30) == GHOSTTY_KEY_TAB)
    #expect(KeyMap.key(for: 0x33) == GHOSTTY_KEY_BACKSPACE)
    #expect(KeyMap.key(for: 0x35) == GHOSTTY_KEY_ESCAPE)
    #expect(KeyMap.key(for: 0x7E) == GHOSTTY_KEY_ARROW_UP)

    // Letters are mapped too. Leaving them to AppKit's own character
    // transformation makes Ctrl+C work only by accident and Ctrl+[ not at all,
    // because the encoder never sees which key was pressed.
    #expect(KeyMap.key(for: 0x08) == GHOSTTY_KEY_C)
    #expect(KeyMap.key(for: 0x21) == GHOSTTY_KEY_BRACKET_LEFT)
    #expect(KeyMap.key(for: 0x2A) == GHOSTTY_KEY_BACKSLASH)
}

@Test("control chords encode to their control bytes")
func controlChords() async throws {
    let terminal = try Terminal()
    // The ones a shell user reaches for constantly.
    #expect(await terminal.encode(key: GHOSTTY_KEY_C, modifiers: .control) == [0x03])  // interrupt
    #expect(await terminal.encode(key: GHOSTTY_KEY_D, modifiers: .control) == [0x04])  // EOF
    #expect(await terminal.encode(key: GHOSTTY_KEY_Z, modifiers: .control) == [0x1a])  // suspend
    #expect(await terminal.encode(key: GHOSTTY_KEY_L, modifiers: .control) == [0x0c])  // clear
    #expect(await terminal.encode(key: GHOSTTY_KEY_A, modifiers: .control) == [0x01])  // line start
    #expect(await terminal.encode(key: GHOSTTY_KEY_BRACKET_RIGHT, modifiers: .control) == [0x1d])
    #expect(await terminal.encode(key: GHOSTTY_KEY_BACKSLASH, modifiers: .control) == [0x1c])

    // Ctrl+[ is the exception: the encoder returns nothing for it, so the view
    // derives the byte itself. Left as a note rather than a workaround here,
    // since this is upstream behaviour that may change.
    #expect(await terminal.encode(key: GHOSTTY_KEY_BRACKET_LEFT, modifiers: .control).isEmpty)
}

@Test("a click clears the selection instead of making one")
func clickDoesNotSelect() async throws {
    // Starting a selection on mouse-down selects the single cell under the
    // pointer, which paints a block on screen every time the terminal is
    // clicked just to focus it.
    let terminal = try Terminal(cols: 20, rows: 3)
    await terminal.write("hello world")

    await terminal.selectAll()
    #expect(await terminal.selectedText()?.isEmpty == false, "nothing was selected to begin with")

    await terminal.clearSelection()
    #expect(await terminal.selectedText()?.isEmpty ?? true)
}

@Test("a drag selects the range it covers")
func dragSelects() async throws {
    let terminal = try Terminal(cols: 20, rows: 3)
    await terminal.write("hello world")

    await terminal.beginSelection(column: 0, row: 0)
    await terminal.extendSelection(column: 4, row: 0)

    let selected = await terminal.selectedText()
    #expect(selected == "hello", "expected the dragged range, got \(selected ?? "nil")")
}

@Test("a drag keeps its start while output streams and the grid reflows")
func anchorIsTracked() async throws {
    let terminal = try Terminal(cols: 20, rows: 3)
    await terminal.write("one\r\nhello world\r\nthree")
    await terminal.beginSelection(column: 0, row: 1)

    // Output scrolls "hello world" up a row, and a resize reflows every page;
    // a plain grid ref taken before either points at nothing that exists.
    await terminal.write("\r\nfour")
    await terminal.resize(cols: 30, rows: 3)
    await terminal.extendSelection(column: 4, row: 0)

    let selected = await terminal.selectedText()
    #expect(selected == "hello", "expected the start to follow its text, got \(selected ?? "nil")")
}

@Test("function keys and the keypad are known to the map")
func functionAndKeypadKeys() {
    let functionKeys: [(UInt16, GhosttyKey)] = [
        (0x7A, GHOSTTY_KEY_F1), (0x78, GHOSTTY_KEY_F2), (0x63, GHOSTTY_KEY_F3),
        (0x76, GHOSTTY_KEY_F4), (0x60, GHOSTTY_KEY_F5), (0x61, GHOSTTY_KEY_F6),
        (0x62, GHOSTTY_KEY_F7), (0x64, GHOSTTY_KEY_F8), (0x65, GHOSTTY_KEY_F9),
        (0x6D, GHOSTTY_KEY_F10), (0x67, GHOSTTY_KEY_F11), (0x6F, GHOSTTY_KEY_F12),
    ]
    for (keyCode, key) in functionKeys {
        #expect(KeyMap.key(for: keyCode) == key)
        #expect(KeyMap.isSpecial(keyCode))
    }
    // Keypad Enter is reported as 0x03; left to the platform's text it
    // interrupted whatever was running.
    #expect(KeyMap.key(for: 0x4C) == GHOSTTY_KEY_NUMPAD_ENTER)
    #expect(KeyMap.isSpecial(0x4C))
    #expect(KeyMap.key(for: 0x72) == GHOSTTY_KEY_INSERT)
    #expect(KeyMap.key(for: 0x52) == GHOSTTY_KEY_NUMPAD_0)
    #expect(KeyMap.key(for: 0x5C) == GHOSTTY_KEY_NUMPAD_9)
    #expect(KeyMap.isKeypad(0x45))
}

@Test("function keys and the keypad encode as a terminal expects")
func functionAndKeypadEncoding() async throws {
    let terminal = try Terminal()
    #expect(await terminal.encode(key: GHOSTTY_KEY_F1) == Array("\u{1b}OP".utf8))
    #expect(await terminal.encode(key: GHOSTTY_KEY_F5) == Array("\u{1b}[15~".utf8))
    #expect(await terminal.encode(key: GHOSTTY_KEY_NUMPAD_ENTER) == [0x0d])
    #expect(await terminal.encode(key: GHOSTTY_KEY_NUMPAD_1, text: "1") == Array("1".utf8))
    #expect(await terminal.encode(key: GHOSTTY_KEY_NUMPAD_ADD, text: "+") == Array("+".utf8))
}

@Test("platform text with control or function-key scalars is not passed on")
func platformTextIsFiltered() {
    #expect(KeyMap.text("\u{3}") == "")          // keypad Enter
    #expect(KeyMap.text("\u{F704}") == "")       // F1
    #expect(KeyMap.text("1") == "1")
    #expect(KeyMap.text("é") == "é")
}

/// What may be handed to the encoder as a character.
///
/// The rule is one line and has broken the keyboard twice: once when the
/// platform's text was passed for Return and Backspace, and again when the
/// arrows' private-use scalars were. Both times every key still produced
/// *something*, which is why it took a while to notice.
struct EncoderCodepointTests {
    @Test("AppKit's function-key scalars are never passed as text")
    func privateUseIsDropped() {
        // 0xF702 is what AppKit reports for Left. Sent as a codepoint it makes
        // the encoder answer for a character nobody typed.
        for scalar: UInt32 in [0xF700, 0xF702, 0xF703, 0xF729, 0xF8FF] {
            #expect(KeyMap.codepoint(from: scalar) == 0, "0x\(String(scalar, radix: 16))")
        }
    }

    @Test("real characters are passed through")
    func charactersSurvive() {
        // Control chords need these: Ctrl+[ is only encodable from the "[".
        for scalar: UInt32 in [0x61, 0x5B, 0x5C, 0x5D, 0x20, 0x30, 0x4E2D] {
            #expect(KeyMap.codepoint(from: scalar) == scalar)
        }
    }

    @Test("the arrows are special keys, and are known to the map")
    func arrowsAreMapped() {
        // 0x7B..0x7E are Left, Right, Down, Up. Missing from either set and
        // they fall through to the platform's text, which is the private-use
        // scalar the first test rejects -- so nothing would be sent at all.
        for keyCode: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E] {
            #expect(KeyMap.isSpecial(keyCode), "keyCode 0x\(String(keyCode, radix: 16))")
            #expect(KeyMap.key(for: keyCode) != nil)
        }
    }
}

@Test("the Kitty keyboard protocol a dead program left on is turned off at the prompt")
func keyboardProtocolReset() async throws {
    let terminal = try Terminal(cols: 20, rows: 5)
    await terminal.write("\u{1b}[>13u")
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER) == [0x1b, 0x5b, 0x31, 0x33, 0x75])
    await terminal.resetKeyboardProtocol()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER) == [0x0d])
    #expect(await terminal.encode(key: GHOSTTY_KEY_C, modifiers: .control, unshiftedCodepoint: 99) == [0x03])
}

@Test("the keyboard protocol is left alone on the alternate screen, where a program is using it")
func keyboardProtocolKeptForAProgram() async throws {
    let terminal = try Terminal(cols: 20, rows: 5)
    await terminal.write("\u{1b}[?1049h\u{1b}[>13u")
    await terminal.resetKeyboardProtocol()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER) == [0x1b, 0x5b, 0x31, 0x33, 0x75])
    await terminal.write("\u{1b}[?1049l")
    await terminal.resetKeyboardProtocol()
    #expect(await terminal.encode(key: GHOSTTY_KEY_ENTER) == [0x0d])
}

@Test("a frame marks exactly the selected cells, row by row")
func frameMarksSelection() async throws {
    let terminal = try Terminal(cols: 20, rows: 4)
    await terminal.write("hello world\r\nsecond line\r\nthird")
    _ = await terminal.nextFrame()

    await terminal.beginSelection(column: 6, row: 0)
    await terminal.extendSelection(column: 3, row: 1)
    await terminal.invalidate()
    let frame = try #require(await terminal.nextFrame())
    let selected = Dictionary(uniqueKeysWithValues: frame.dirtyRows.map { row in
        (Int(row.y), row.cells.indices.filter { row.cells[$0].isSelected })
    })
    // From the start to the end of the first row, then up to the end column.
    #expect(selected[0] == Array(6..<20))
    #expect(selected[1] == [0, 1, 2, 3])
    #expect(selected[2] == [])
    #expect(selected[3] == [])
}

// MARK: - the mouse

@Test("a click goes to a program only once it asks for the mouse, in the protocol it chose")
func clickReportsOnlyWhenAsked() async throws {
    let terminal = try Terminal(cols: 80, rows: 24)
    // Cells 10 by 20 pixels; the click lands in column 2, row 3.
    let size = GhosttyMouseEncoderSize(size: MemoryLayout<GhosttyMouseEncoderSize>.size,
                                       screen_width: 800, screen_height: 480, cell_width: 10, cell_height: 20,
                                       padding_top: 0, padding_bottom: 0, padding_right: 0, padding_left: 0)
    func click(_ action: GhosttyMouseAction) async -> String {
        String(decoding: await terminal.encodeMouse(action, button: GHOSTTY_MOUSE_BUTTON_LEFT, x: 25, y: 65,
                                                    size: size, isPressed: action == GHOSTTY_MOUSE_ACTION_PRESS),
               as: UTF8.self)
    }
    #expect(!terminal.wantsMouse)
    #expect(await click(GHOSTTY_MOUSE_ACTION_PRESS).isEmpty)

    await terminal.write("\u{1b}[?1000h\u{1b}[?1006h")
    #expect(terminal.wantsMouse)
    #expect(await click(GHOSTTY_MOUSE_ACTION_PRESS) == "\u{1b}[<0;3;4M")
    #expect(await click(GHOSTTY_MOUSE_ACTION_RELEASE) == "\u{1b}[<0;3;4m")

    await terminal.write("\u{1b}[?1000l")
    #expect(!terminal.wantsMouse)
}
