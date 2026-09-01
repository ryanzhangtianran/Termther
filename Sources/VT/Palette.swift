import Foundation
import GhosttyVt

/// A terminal colour scheme.
///
/// The sixteen ANSI colours plus the three the terminal itself owns. Everything
/// above 15 in the 256-colour space is a fixed cube and greyscale ramp defined
/// by the standard, so it is generated rather than stored: a scheme that
/// redefined it would render other people's output wrongly.
public struct Palette: Sendable, Equatable, Codable {
    public var name: String
    public var foreground: Color
    public var background: Color
    public var cursor: Color
    /// black, red, green, yellow, blue, magenta, cyan, white, then the eight
    /// bright variants.
    public var ansi: [Color]

    public init(name: String, foreground: Color, background: Color,
                cursor: Color, ansi: [Color]) {
        precondition(ansi.count == 16, "a palette needs all sixteen ANSI colours")
        self.name = name
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
    }

    /// The full 256 entries: the sixteen from this scheme, then the standard
    /// 6×6×6 cube and 24-step greyscale.
    public var full256: [Color] {
        var colors = ansi
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for red in steps {
            for green in steps {
                for blue in steps {
                    colors.append(Color(red: red, green: green, blue: blue))
                }
            }
        }
        for step in 0..<24 {
            let value = UInt8(8 + step * 10)
            colors.append(Color(red: value, green: value, blue: value))
        }
        return colors
    }
}

public extension Palette {
    /// Schemes that ship with the app. Chosen to cover the usual tastes rather
    /// than to be exhaustive; anything else is a matter of adding four lines.
    static let builtIn: [Palette] = [
        .kanagawaWave, .termther, .tokyoNight, .nord,
        .catppuccinMocha, .catppuccinMacchiato, .catppuccinFrappe, .catppuccinLatte,
        .solarizedDark, .solarizedLight, .gruvboxDark,
    ]

    static func named(_ name: String) -> Palette? {
        builtIn.first { $0.name == name }
    }

    /// The default.
    ///
    /// Kanagawa takes its colours from Hokusai's wave: an ink-blue ground with
    /// muted earth tones on it. Low contrast on purpose -- nothing in it is at
    /// full brightness -- which is what makes a full screen of text readable
    /// for a long stretch rather than merely legible.
    static let kanagawaWave = Palette(
        name: "Kanagawa Wave",
        foreground: .hex(0xDCD7BA), background: .hex(0x1F1F28), cursor: .hex(0xC8C093),
        ansi: [
            .hex(0x16161D), .hex(0xC34043), .hex(0x76946A), .hex(0xC0A36E),
            .hex(0x7E9CD8), .hex(0x957FB8), .hex(0x6A9589), .hex(0xC8C093),
            .hex(0x727169), .hex(0xE82424), .hex(0x98BB6C), .hex(0xE6C384),
            .hex(0x7FB4CA), .hex(0x938AA9), .hex(0x7AA89F), .hex(0xDCD7BA),
        ])

    /// Near-black rather than pure black, so a maximised window is not a hole
    /// in the screen, with the teal the rest of the app uses.
    static let termther = Palette(
        name: "Termther",
        foreground: .hex(0xC8CDD4), background: .hex(0x14161A), cursor: .hex(0x0F766E),
        ansi: [
            .hex(0x22262C), .hex(0xE05A5A), .hex(0x6FBF73), .hex(0xD8A657),
            .hex(0x5E9CD3), .hex(0xB58AD1), .hex(0x0F9B92), .hex(0xB4BAC2),
            .hex(0x3A4048), .hex(0xF07A7A), .hex(0x8FD993), .hex(0xE8C177),
            .hex(0x7FB8E8), .hex(0xCFA8E4), .hex(0x2ABDB3), .hex(0xE4E8ED),
        ])

    static let tokyoNight = Palette(
        name: "Tokyo Night",
        foreground: .hex(0xC0CAF5), background: .hex(0x1A1B26), cursor: .hex(0xC0CAF5),
        ansi: [
            .hex(0x15161E), .hex(0xF7768E), .hex(0x9ECE6A), .hex(0xE0AF68),
            .hex(0x7AA2F7), .hex(0xBB9AF7), .hex(0x7DCFFF), .hex(0xA9B1D6),
            .hex(0x414868), .hex(0xF7768E), .hex(0x9ECE6A), .hex(0xE0AF68),
            .hex(0x7AA2F7), .hex(0xBB9AF7), .hex(0x7DCFFF), .hex(0xC0CAF5),
        ])

    static let nord = Palette(
        name: "Nord",
        foreground: .hex(0xD8DEE9), background: .hex(0x2E3440), cursor: .hex(0xD8DEE9),
        ansi: [
            .hex(0x3B4252), .hex(0xBF616A), .hex(0xA3BE8C), .hex(0xEBCB8B),
            .hex(0x81A1C1), .hex(0xB48EAD), .hex(0x88C0D0), .hex(0xE5E9F0),
            .hex(0x4C566A), .hex(0xBF616A), .hex(0xA3BE8C), .hex(0xEBCB8B),
            .hex(0x81A1C1), .hex(0xB48EAD), .hex(0x8FBCBB), .hex(0xECEFF4),
        ])

    static let solarizedDark = Palette(
        name: "Solarized Dark",
        foreground: .hex(0x839496), background: .hex(0x002B36), cursor: .hex(0x93A1A1),
        ansi: [
            .hex(0x073642), .hex(0xDC322F), .hex(0x859900), .hex(0xB58900),
            .hex(0x268BD2), .hex(0xD33682), .hex(0x2AA198), .hex(0xEEE8D5),
            .hex(0x002B36), .hex(0xCB4B16), .hex(0x586E75), .hex(0x657B83),
            .hex(0x839496), .hex(0x6C71C4), .hex(0x93A1A1), .hex(0xFDF6E3),
        ])

    static let solarizedLight = Palette(
        name: "Solarized Light",
        foreground: .hex(0x657B83), background: .hex(0xFDF6E3), cursor: .hex(0x586E75),
        ansi: [
            .hex(0x073642), .hex(0xDC322F), .hex(0x859900), .hex(0xB58900),
            .hex(0x268BD2), .hex(0xD33682), .hex(0x2AA198), .hex(0xEEE8D5),
            .hex(0x002B36), .hex(0xCB4B16), .hex(0x586E75), .hex(0x657B83),
            .hex(0x839496), .hex(0x6C71C4), .hex(0x93A1A1), .hex(0xFDF6E3),
        ])

    static let gruvboxDark = Palette(
        name: "Gruvbox Dark",
        foreground: .hex(0xEBDBB2), background: .hex(0x282828), cursor: .hex(0xEBDBB2),
        ansi: [
            .hex(0x282828), .hex(0xCC241D), .hex(0x98971A), .hex(0xD79921),
            .hex(0x458588), .hex(0xB16286), .hex(0x689D6A), .hex(0xA89984),
            .hex(0x928374), .hex(0xFB4934), .hex(0xB8BB26), .hex(0xFABD2F),
            .hex(0x83A598), .hex(0xD3869B), .hex(0x8EC07C), .hex(0xEBDBB2),
        ])

    // MARK: - Catppuccin
    //
    // Four of them, and they are not four themes: they are one theme at four
    // levels of contrast, so a person can move between rooms and daylight
    // without relearning which colour means what. The accent hues are the same
    // in all four; only the grounds and the muting change.

    static let catppuccinMocha = Palette(
        name: "Catppuccin Mocha",
        foreground: .hex(0xCDD6F4), background: .hex(0x1E1E2E), cursor: .hex(0xF5E0DC),
        ansi: [
            .hex(0x45475A), .hex(0xF38BA8), .hex(0xA6E3A1), .hex(0xF9E2AF),
            .hex(0x89B4FA), .hex(0xF5C2E7), .hex(0x94E2D5), .hex(0xBAC2DE),
            .hex(0x585B70), .hex(0xF38BA8), .hex(0xA6E3A1), .hex(0xF9E2AF),
            .hex(0x89B4FA), .hex(0xF5C2E7), .hex(0x94E2D5), .hex(0xA6ADC8),
        ])

    static let catppuccinMacchiato = Palette(
        name: "Catppuccin Macchiato",
        foreground: .hex(0xCAD3F5), background: .hex(0x24273A), cursor: .hex(0xF4DBD6),
        ansi: [
            .hex(0x494D64), .hex(0xED8796), .hex(0xA6DA95), .hex(0xEED49F),
            .hex(0x8AADF4), .hex(0xF5BDE6), .hex(0x8BD5CA), .hex(0xB8C0E0),
            .hex(0x5B6078), .hex(0xED8796), .hex(0xA6DA95), .hex(0xEED49F),
            .hex(0x8AADF4), .hex(0xF5BDE6), .hex(0x8BD5CA), .hex(0xA5ADCB),
        ])

    static let catppuccinFrappe = Palette(
        name: "Catppuccin Frapp\u{00E9}",
        foreground: .hex(0xC6D0F5), background: .hex(0x303446), cursor: .hex(0xF2D5CF),
        ansi: [
            .hex(0x51576D), .hex(0xE78284), .hex(0xA6D189), .hex(0xE5C890),
            .hex(0x8CAAEE), .hex(0xF4B8E4), .hex(0x81C8BE), .hex(0xB5BFE2),
            .hex(0x626880), .hex(0xE78284), .hex(0xA6D189), .hex(0xE5C890),
            .hex(0x8CAAEE), .hex(0xF4B8E4), .hex(0x81C8BE), .hex(0xA5ADCE),
        ])

    static let catppuccinLatte = Palette(
        name: "Catppuccin Latte",
        foreground: .hex(0x4C4F69), background: .hex(0xEFF1F5), cursor: .hex(0xDC8A78),
        ansi: [
            .hex(0x5C5F77), .hex(0xD20F39), .hex(0x40A02B), .hex(0xDF8E1D),
            .hex(0x1E66F5), .hex(0xEA76CB), .hex(0x179299), .hex(0xACB0BE),
            .hex(0x6C6F85), .hex(0xD20F39), .hex(0x40A02B), .hex(0xDF8E1D),
            .hex(0x1E66F5), .hex(0xEA76CB), .hex(0x179299), .hex(0xBCC0CC),
        ])
}

public extension Color {
    /// From the 0xRRGGBB form every scheme is published in.
    static func hex(_ value: UInt32) -> Color {
        Color(red: UInt8((value >> 16) & 0xFF),
              green: UInt8((value >> 8) & 0xFF),
              blue: UInt8(value & 0xFF))
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension Terminal {
    /// Applies a scheme to this terminal.
    ///
    /// Set on the emulator rather than the renderer, because a program can ask
    /// what the colours are (OSC 10/11, CSI ? 996 n) and must be told the
    /// truth -- otherwise it picks a theme that clashes with the one on screen.
    public func apply(_ palette: Palette) {
        var foreground = palette.foreground.ghostty
        var background = palette.background.ghostty
        var cursor = palette.cursor.ghostty
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)

        var entries = palette.full256.map(\.ghostty)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &entries)
    }

}

extension Color {
    var ghostty: GhosttyColorRgb {
        GhosttyColorRgb(r: red, g: green, b: blue)
    }
}
