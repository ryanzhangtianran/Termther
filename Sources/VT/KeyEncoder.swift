import Foundation
import GhosttyVt

/// Turns key presses into the bytes a remote program expects.
///
/// This is the half of terminal input that is genuinely hard: the same key
/// produces different bytes depending on modes the *remote* program set --
/// application cursor keys, the Kitty keyboard protocol, xterm's
/// modifyOtherKeys. Rather than track those ourselves, the encoder copies them
/// straight off the terminal, so pressing Up sends `CSI A` or `SS3 A` according
/// to what the program actually asked for.
///
/// Owned by `Terminal`, which keeps it in step automatically -- use
/// `Terminal.encode(key:)` rather than driving this directly.
final class KeyEncoder {
    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?

    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt16
        init(rawValue: UInt16) { self.rawValue = rawValue }

        static let shift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
        static let control = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
        static let option = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
        static let command = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    }

    enum Failure: Error { case create }

    init() throws {
        var encoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { throw Failure.create }
        self.encoder = encoder

        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS else { throw Failure.create }
        self.event = event
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    /// Adopts the terminal's current input modes. Called after feeding output,
    /// since that output is what changes them.
    func sync(with terminal: GhosttyTerminal?) {
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
    }

    /// Encodes one key press.
    ///
    /// `text` is what the platform says the keystroke produced -- pass it for
    /// ordinary typing, and leave it empty for a control chord, which carries
    /// no text and would otherwise be encoded the long way round.
    func encode(key: GhosttyKey,
                       modifiers: Modifiers = [],
                       text: String = "",
                       unshiftedCodepoint: UInt32 = 0) -> [UInt8] {
        ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, key)
        ghostty_key_event_set_mods(event, GhosttyMods(modifiers.rawValue))
        ghostty_key_event_set_unshifted_codepoint(event, unshiftedCodepoint)
        text.withCString { ghostty_key_event_set_utf8(event, $0, strlen($0)) }

        var buffer = [CChar](repeating: 0, count: 128)
        var written = 0
        guard ghostty_key_encoder_encode(encoder, event, &buffer,
                                         buffer.count, &written) == GHOSTTY_SUCCESS
        else { return [] }
        return buffer[0..<written].map { UInt8(bitPattern: $0) }
    }
}
