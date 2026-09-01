import AppKit
import CoreText
import Foundation

/// The fonts a terminal draws with, and the cell grid they imply.
///
/// A terminal grid is defined by the font, not the other way round: every cell
/// is exactly one advance wide and one line tall, and every glyph is placed
/// against that box. Measuring once here is what lets the renderer treat
/// layout as pure arithmetic.
///
/// `@unchecked Sendable` because CTFont is an immutable CoreFoundation type
/// that Apple has not annotated; nothing here mutates one after construction.
public struct FontStack: @unchecked Sendable {
    public struct Metrics: Equatable, Sendable {
        /// Advance width of a single-width cell, in points.
        public var cellWidth: CGFloat
        /// Baseline-to-baseline distance, in points.
        public var cellHeight: CGFloat
        /// How far into the cell a glyph starts, when the cell has been
        /// widened past the font's own advance.
        public var glyphInset: CGFloat = 0
        /// The font's own advance and vertical extent, before any multipliers.
        /// Glyphs that are drawn to fill their cell are mapped from this box,
        /// which is what they were designed against.
        public var naturalAdvance: CGFloat = 0
        public var ascent: CGFloat = 0
        public var descent: CGFloat = 0
        /// Distance from the top of the cell down to the baseline.
        public var baseline: CGFloat
        public var underlinePosition: CGFloat
        public var underlineThickness: CGFloat

        /// The cell in device pixels.
        ///
        /// The single definition. Working it out separately in the renderer,
        /// the atlas and the box-drawing code gave three answers that differed
        /// by a fraction of a pixel -- enough for a powerline separator, which
        /// is supposed to butt against its neighbour, to sit visibly proud of
        /// the cell background beside it.
        public func pixelSize(scale: CGFloat) -> CGSize {
            CGSize(width: (cellWidth * scale).rounded(),
                   height: (cellHeight * scale).rounded())
        }
    }

    public var regular: CTFont
    public var bold: CTFont
    public var italic: CTFont
    public var boldItalic: CTFont
    public var metrics: Metrics

    /// The font actually in use, which may not be the one that was asked for.
    public let resolvedName: String

    /// Tried in order; the first that resolves wins.
    ///
    /// CoreText never fails a font request -- an unknown name silently yields
    /// Helvetica, which in a terminal is both proportional and wrong. Each
    /// candidate is therefore checked against the name that came back.
    public static let preferred = [
        "Maple Mono Normal NL NF",
        "Menlo",
        "SF Mono",
        "Monaco",
    ]

    /// How heavy the regular face is.
    ///
    /// A terminal's bold attribute is relative to this: choosing a Light base
    /// makes `\e[1m` render as Regular rather than Bold, which is how thin
    /// terminal themes are usually built.
    public enum Weight: String, Sendable, CaseIterable, Codable {
        case thin, light, regular, medium, semibold, bold

        /// NSFontManager's 0-15 scale, where 5 is regular and 9 is bold.
        var appKitValue: Int {
            switch self {
            case .thin: 2
            case .light: 3
            case .regular: 5
            case .medium: 6
            case .semibold: 8
            case .bold: 9
            }
        }

        /// What `\e[1m` should reach for: two steps up, capped.
        var bolder: Weight {
            switch self {
            case .thin: .regular
            case .light: .medium
            case .regular: .bold
            case .medium, .semibold, .bold: .bold
            }
        }

        public var title: String { rawValue.capitalized }
    }

    public let weight: Weight
    /// Row height as a multiple of the font's natural line height.
    ///
    /// 1.0 is what the typeface asks for, which for most monospaced faces is
    /// tight enough that underlines and descenders nearly touch the row below.
    /// Loosening it is the single change that most affects how a terminal reads.
    public let lineHeight: CGFloat
    /// Column width as a multiple of the font's natural advance.
    ///
    /// Widening the cell does not stretch the glyph -- it is centred in the
    /// extra room, so the letters keep their shape and only the gaps grow.
    public let letterSpacing: CGFloat

    public init(name: String? = nil, size: CGFloat = 13, weight: Weight = .regular,
                lineHeight: CGFloat = 1.0, letterSpacing: CGFloat = 1.0) {
        let candidates = name.map { [$0] + Self.preferred } ?? Self.preferred
        let chosen = candidates.first { Self.resolves($0) } ?? "Menlo"
        resolvedName = chosen
        self.weight = weight
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing

        func font(_ weight: Weight, italic: Bool) -> CTFont {
            // NSFontManager picks the nearest real face in the family rather
            // than synthesising, so a family without a Light simply stays
            // Regular instead of being smeared thinner.
            let traits: NSFontTraitMask = italic ? .italicFontMask : []
            if let font = NSFontManager.shared.font(withFamily: chosen, traits: traits,
                                                    weight: weight.appKitValue, size: size) {
                return font as CTFont
            }
            let base = CTFontCreateWithName(chosen as CFString, size, nil)
            guard italic,
                  let derived = CTFontCreateCopyWithSymbolicTraits(
                    base, size, nil, .traitItalic, .traitItalic)
            else { return base }
            return derived
        }

        regular = font(weight, italic: false)
        bold = font(weight.bolder, italic: false)
        italic = font(weight, italic: true)
        boldItalic = font(weight.bolder, italic: true)
        metrics = Self.measure(regular, lineHeight: lineHeight, letterSpacing: letterSpacing)
    }

    /// Whether CoreText gave back the family that was asked for, rather than
    /// quietly substituting.
    static func resolves(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 13, nil)
        return (CTFontCopyFamilyName(font) as String) == name
    }

    public func font(for attributes: Cell.Attributes) -> CTFont {
        switch (attributes.contains(.bold), attributes.contains(.italic)) {
        case (true, true):   boldItalic
        case (true, false):  bold
        case (false, true):  italic
        case (false, false): regular
        }
    }

    /// Cell width comes from an advance rather than a bounding box: in a
    /// monospaced face every glyph advances the same amount, and the advance is
    /// what the grid is actually built from. Ink may overflow the box, which is
    /// normal and why glyphs are clipped to their cell only when asked.
    static func measure(_ font: CTFont, lineHeight: CGFloat = 1.0,
                        letterSpacing: CGFloat = 1.0) -> Metrics {
        var glyph = CGGlyph()
        var character: UniChar = 0x4D  // "M"
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let natural = ascent + descent + leading
        let height = (natural * lineHeight).rounded(.up)
        // Extra room is split above and below, so loosening the rows does not
        // slide the text off its own baseline.
        let extra = ((height - natural) / 2).rounded()

        let width = (advance.width * letterSpacing).rounded(.up)

        return Metrics(
            cellWidth: width,
            cellHeight: height,
            glyphInset: ((width - advance.width) / 2).rounded(),
            naturalAdvance: advance.width,
            ascent: ascent,
            descent: descent,
            baseline: (ascent + extra).rounded(),
            underlinePosition: CTFontGetUnderlinePosition(font),
            underlineThickness: max(1, CTFontGetUnderlineThickness(font).rounded()))
    }
}
