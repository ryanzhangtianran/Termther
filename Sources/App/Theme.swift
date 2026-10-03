import AppKit
import SwiftUI
import VT

/// The look, derived from one source.
///
/// The chrome takes its surfaces from the terminal's palette rather
/// than having its own: a terminal window is mostly the palette anyway, and
/// picking a scheme changes everything at once. Its text and accent are the
/// system's, which read better on every scheme than tinted ones did.
@MainActor
@Observable
public final class Theme {
    public var palette: Palette = .kanagawaWave
    public var terminalFontFamily = "Maple Mono Normal NL NF"
    public var terminalFontSize: CGFloat = 14
    /// Fixed rather than chosen: regular, with macOS's stroke-thickening
    /// smoothing, is how the face reads best on this app's dark palettes.
    public let terminalFontWeight: FontStack.Weight = .regular
    public let terminalFontThickens = true
    public var terminalLineHeight: CGFloat = 1.2
    public var terminalLetterSpacing: CGFloat = 1.0

    public init() {}

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

    /// What the window's own chrome should match, so the buttons and any
    /// system menus render for the right side of the light/dark divide.
    public var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public var border: SwiftUI.Color {
        palette.foreground.swiftUI.opacity(isDark ? 0.10 : 0.14)
    }

    /// The system's own label colours, not the scheme's foreground: a tinted
    /// foreground (Kanagawa's is cream) read as off-colour text in the chrome.
    /// White on a dark scheme and black on a light one, since the window's
    /// appearance follows the scheme.
    public var text: SwiftUI.Color { .primary }
    public var secondaryText: SwiftUI.Color { .secondary }

    /// The system accent, as every other Mac app uses: the scheme's cursor
    /// colour made buttons and switches read as a different app's.
    public var accent: SwiftUI.Color { .accentColor }

    public var hover: SwiftUI.Color { palette.foreground.swiftUI.opacity(0.07) }

    // MARK: - fonts

    public func ui(_ size: CGFloat? = nil, weight: Font.Weight? = nil) -> Font {
        .system(size: size ?? 14, weight: weight ?? .regular, design: .rounded)
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

extension SwiftUI.Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

extension View {
    /// Applies the system type scale and text colour to everything below.
    ///
    /// SwiftUI has no global font setting the way Flutter's `fontFamily` is;
    /// the environment default is the closest equivalent, and Text and most
    /// controls inherit from it.
    func themed(_ theme: Theme) -> some View {
        // 14 rather than the system's 13: forms, tables and menus included.
        environment(\.font, .system(size: 14))
            // One typeface for every word of the chrome, sheets included:
            // anything that names no design of its own takes this.
            .fontDesign(.rounded)
            // And the lighter controls throughout: switches, sliders and
            // buttons at their regular size read heavy beside 12pt type.
            .controlSize(.small)
            .foregroundStyle(theme.text)
    }
}

extension Font {
    /// The + beside a section title in Settings: small, so it marks the
    /// section rather than competing with its name.
    static let headerPlus = Font.system(size: 12, weight: .regular)
}
