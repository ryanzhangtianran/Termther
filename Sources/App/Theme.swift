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

    /// One of the scheme's sixteen colours -- black, red, green, yellow, blue,
    /// magenta, cyan, white, then the bright eight -- so what the chrome
    /// colours is coloured as the terminal beside it is, and changes with it.
    public func ansi(_ index: Int) -> SwiftUI.Color { palette.ansi[index].swiftUI }

    /// Up and answering, waiting, and failing: the scheme's bright green,
    /// yellow and red, which read on the dark chrome.
    public var online: SwiftUI.Color { ansi(10) }
    public var waiting: SwiftUI.Color { ansi(11) }
    public var failing: SwiftUI.Color { ansi(9) }



    // MARK: - fonts

    /// The chrome's typeface: Nunito, which the app carries, at `weight`;
    /// the system's rounded face where it is not there -- the tests, which
    /// run outside the app bundle.
    public func ui(_ size: CGFloat? = nil, weight: Font.Weight? = nil) -> Font {
        let size = size ?? 14
        guard let face = Self.nunito(size: size, weight: weight ?? .regular) else {
            return .system(size: size, weight: weight ?? .regular, design: .rounded)
        }
        return Font(face)
    }

    /// Whether the app's own typeface is there to use.
    public static let hasNunito = NSFontManager.shared.availableFontFamilies.contains("Nunito")

    /// Nunito is one variable font; a weight is asked for on its `wght`
    /// axis. Asked for by trait, light came out as ExtraLight.
    static func nunito(size: CGFloat, weight: Font.Weight) -> NSFont? {
        guard hasNunito else { return nil }
        let value: Int = switch weight {
        case .ultraLight, .thin: 200
        case .light:      300
        case .medium:     500
        case .semibold:   600
        case .bold:       700
        case .heavy:      800
        case .black:      900
        default:          400
        }
        let key = FaceKey(size: size, weight: value)
        if let face = faces[key] { return face }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Nunito",
            .variation: [NSNumber(value: 0x7767_6874): value],  // 'wght'
        ])
        let face = NSFont(descriptor: descriptor, size: size)
        faces[key] = face
        return face
    }

    /// Each face made once: `ui` is asked for in every row's body, and a
    /// descriptor with a variation axis is not cheap to resolve.
    private struct FaceKey: Hashable { let size: CGFloat; let weight: Int }
    private static var faces: [FaceKey: NSFont?] = [:]

    /// The terminal's own face, for what shows the terminal itself -- the
    /// preview in Settings, the text editor. SF Mono when it is missing.
    public func terminalFace(size: CGFloat? = nil) -> NSFont {
        let size = size ?? terminalFontSize
        return NSFontManager.shared.font(withFamily: terminalFontFamily, traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
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
        // 13.5, as the sidebar's rows are: forms, tables and menus included,
        // so every label on screen is set alike, in the app's own face.
        environment(\.font, theme.ui(13.5))
            // A little air between the lines of anything that wraps.
            .lineSpacing(2.5)
            // Rounded, for anything that falls back to the system's face.
            // Not with Nunito there: the design overrides a face given by
            // name, and every word would come out in SF Rounded instead.
            .fontDesign(Theme.hasNunito ? nil : .rounded)
            // And the lighter controls throughout: switches, sliders and
            // buttons at their regular size read heavy beside 12pt type.
            .controlSize(.small)
            .foregroundStyle(theme.text)
    }
}

extension Locale {
    /// The chrome's own: its words are English, so its dates and numbers are
    /// formatted in English too, whatever the Mac's language -- "3 hours ago"
    /// beside English labels, not a translation of it.
    static let chrome = Locale(identifier: "en_US")
}
