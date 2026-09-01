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

@Test("passing text alongside a named key is what broke them")
func textPoisonsNamedKeys() async throws {
    // Kept as a guard: if this ever stops differing, the view can stop caring.
    let terminal = try Terminal()
    let poisoned = await terminal.encode(key: GHOSTTY_KEY_ENTER, text: "\r")
    #expect(poisoned != [0x0d], "if this now matches, the view's special case is obsolete")
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
