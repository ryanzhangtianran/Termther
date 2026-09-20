import AppKit
import SwiftUI
import VT

/// The look, derived from one source.
///
/// The chrome takes its colours from the terminal's palette rather than having
/// its own. A terminal window is mostly the palette anyway, and a sidebar in
/// system grey beside a Nord terminal looks like two applications stapled
/// together. Picking a scheme changes everything at once.
@MainActor
@Observable
public final class Theme {
    public var palette: Palette
    public var terminalFontFamily: String
    public var terminalFontSize: CGFloat
    public var terminalFontWeight: FontStack.Weight
    public var terminalLineHeight: CGFloat
    public var terminalLetterSpacing: CGFloat
    public var cursorStyle: CursorStyle

    /// Where the window's own buttons start, so the cards can line up with
    /// them. Measured from the window rather than assumed, since the number is
    /// AppKit's to choose.
    public var windowButtonInset: CGFloat = 7

    public init(palette: Palette = .kanagawaWave,
                terminalFontFamily: String = "Maple Mono Normal NL NF",
                terminalFontSize: CGFloat = 13,
                terminalFontWeight: FontStack.Weight = .regular,
                terminalLineHeight: CGFloat = 1.15,
                terminalLetterSpacing: CGFloat = 1.0,
                cursorStyle: CursorStyle = .bar) {
        self.palette = palette
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSize = terminalFontSize
        self.terminalFontWeight = terminalFontWeight
        self.terminalLineHeight = terminalLineHeight
        self.terminalLetterSpacing = terminalLetterSpacing
        self.cursorStyle = cursorStyle
    }

    // MARK: - colours

    /// Whether the scheme is a dark one, from the background's brightness.
    ///
    /// Asked rather than declared, so a scheme added later does not have to
    /// remember to say which it is.
    public var isDark: Bool { palette.background.luminance < 0.5 }

    /// Behind everything: a shade off the terminal's own background, so the
    /// cards read as sitting on a surface rather than floating in the void.
    ///
    /// Lighter than the cards on a dark scheme, not darker. The window's own
    /// close/minimise/zoom buttons sit on this surface, and when it is the
    /// darkest thing on screen the inactive buttons -- dim grey circles --
    /// disappear into it until the pointer brings them back.
    public var windowBackground: SwiftUI.Color {
        palette.background.shifted(by: isDark ? 0.10 : -0.05).swiftUI
    }

    /// The cards themselves.
    public var panelBackground: SwiftUI.Color { palette.background.swiftUI }

    /// A card that should sit slightly proud of its neighbours.
    public var raisedBackground: SwiftUI.Color {
        palette.background.shifted(by: isDark ? 0.18 : -0.03).swiftUI
    }

    /// What the window's own chrome should match, so the buttons and any
    /// system menus render for the right side of the light/dark divide.
    public var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public var border: SwiftUI.Color {
        palette.foreground.swiftUI.opacity(isDark ? 0.10 : 0.14)
    }

    public var text: SwiftUI.Color { palette.foreground.swiftUI }
    public var secondaryText: SwiftUI.Color { palette.foreground.swiftUI.opacity(0.6) }

    /// Selections and the accent. The cursor colour, because a scheme has
    /// already chosen it to stand out against everything else in the palette.
    public var accent: SwiftUI.Color { palette.cursor.swiftUI }

    public var selection: SwiftUI.Color { accent.opacity(isDark ? 0.28 : 0.18) }
    public var hover: SwiftUI.Color { palette.foreground.swiftUI.opacity(0.07) }

    // MARK: - fonts

    /// A monospaced face for the chrome: fingerprints, ports, shell commands.
    public func mono(_ size: CGFloat) -> Font {
        .custom(terminalFontFamily, size: size)
    }

    public func ui(_ size: CGFloat? = nil, weight: Font.Weight? = nil) -> Font {
        .system(size: size ?? 13, weight: weight ?? .regular)
    }

}

extension VT.Color {
    var swiftUI: SwiftUI.Color {
        SwiftUI.Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Perceived brightness, for deciding whether a scheme is dark.
    var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }

    /// Lightens or darkens, staying in range.
    func shifted(by amount: Double) -> VT.Color {
        func adjust(_ channel: UInt8) -> UInt8 {
            let value = Double(channel) + amount * 255
            return UInt8(max(0, min(255, value)))
        }
        return VT.Color(red: adjust(red), green: adjust(green), blue: adjust(blue))
    }
}

private extension SwiftUI.Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

extension View {
    /// Applies the system type scale and accent to everything below.
    ///
    /// SwiftUI has no global font setting the way Flutter's `fontFamily` is;
    /// the environment default is the closest equivalent, and Text and most
    /// controls inherit from it.
    func themed(_ theme: Theme) -> some View {
        environment(\.font, .body)
            .tint(theme.accent)
            .foregroundStyle(theme.text)
    }
}
