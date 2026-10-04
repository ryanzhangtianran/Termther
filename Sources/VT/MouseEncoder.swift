import Foundation
import GhosttyVt

/// Turns clicks and drags into the bytes a program that asked for the mouse
/// expects -- X10, SGR, URxvt or pixels, as it chose -- with the modes copied
/// straight off the terminal, as `KeyEncoder` does for keys.
///
/// Owned by `Terminal`; use `Terminal.encodeMouse` rather than this.
final class MouseEncoder {
    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?

    enum Failure: Error { case create }

    init() throws {
        var encoder: GhosttyMouseEncoder?
        guard ghostty_mouse_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { throw Failure.create }
        self.encoder = encoder

        var event: GhosttyMouseEvent?
        guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS else { throw Failure.create }
        self.event = event
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    /// `x` and `y` are pixels from the top left of the grid; `size` says how
    /// big the grid and its cells are, in the same pixels.
    func encode(_ action: GhosttyMouseAction, button: GhosttyMouseButton, x: Float, y: Float,
                size: GhosttyMouseEncoderSize, modifiers: KeyModifiers, isPressed: Bool,
                terminal: GhosttyTerminal?) -> [UInt8] {
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
        var size = size
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = isPressed
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        ghostty_mouse_event_set_action(event, action)
        ghostty_mouse_event_set_button(event, button)
        ghostty_mouse_event_set_mods(event, GhosttyMods(modifiers.rawValue))
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: x, y: y))

        var buffer = [CChar](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS
        else { return [] }
        return buffer[0..<written].map { UInt8(bitPattern: $0) }
    }
}
