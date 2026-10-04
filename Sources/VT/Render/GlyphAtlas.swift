import CoreText
import Foundation
import Metal

/// Where a rasterised glyph lives in the atlas, and how to place it.
public struct GlyphPlacement: Equatable, Sendable {
    /// Pixel rect in the atlas texture.
    public var x: UInt32, y: UInt32, width: UInt32, height: UInt32
    /// Pixel offset from the cell's top-left corner to this bitmap's top-left
    /// corner. Negative, because every bitmap is a cell plus a padding margin.
    public var offsetX: Int32, offsetY: Int32
    /// Colour glyphs (emoji) live in their own RGBA atlas and carry their own
    /// colour; grayscale ones store coverage and take the cell's foreground.
    public var isColor: Bool
}

/// Rasterises glyphs once and keeps them in a texture.
///
/// A terminal redraws the same few hundred glyphs thousands of times a second,
/// so rasterising per frame is pure waste. Everything is drawn once into a
/// shared texture and afterwards each cell costs only a quad and a pair of
/// texture coordinates -- which is what makes a full-screen redraw a single
/// draw call rather than a per-cell CoreText round trip.
///
/// Every glyph is rasterised into a bitmap the size of one cell plus a margin,
/// drawn at that cell's own baseline. Placement is then a constant offset --
/// the margin -- rather than a per-glyph bearing computed across CoreText's
/// coordinate space and the device grid, which is where rounding errors creep
/// in and shift text a pixel into its neighbour. Uniform bitmaps also suit a
/// monospaced grid: nothing is wasted when every cell is the same size, and the
/// margin gives descenders and box-drawing characters room to overflow.
///
/// Packing is a shelf allocator: glyphs go left to right on a row whose height
/// is set by the first glyph placed on it, and a new row opens when the current
/// one fills. With uniform bitmaps that is exact. Nothing is ever evicted;
/// when a texture fills, `reset` empties both and the caller rasterises what
/// is on screen again.
public final class GlyphAtlas {
    /// Key for a rasterised glyph: the text, plus the traits that change its
    /// shape. Colour is applied at draw time, so it is not part of the key.
    struct Key: Hashable {
        var text: String
        var bold: Bool
        var italic: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case textureCreation
        case full

        public var description: String {
            switch self {
            case .textureCreation: "cannot create the glyph atlas texture"
            case .full: "the glyph atlas is full"
            }
        }
    }

    /// Coverage for ordinary glyphs.
    public let texture: MTLTexture
    /// Full colour for emoji and other colour fonts.
    public let colorTexture: MTLTexture
    public let size: Int
    public let colorSize: Int

    private let fonts: FontStack
    private let scale: CGFloat
    /// Nil for a cluster already found to have no ink -- a braille blank, a
    /// no-break space -- so it is not rasterised again every frame.
    private var placements: [Key: GlyphPlacement?] = [:]
    /// The same, for a single ASCII character, indexed rather than hashed:
    /// almost every cell on a screen is one, and it is looked up per cell
    /// per rebuild. The outer optional says whether it has been seen.
    private var asciiPlacements = [GlyphPlacement??](repeating: nil, count: 128 * 4)

    private var gray: Shelf
    private var color: Shelf

    /// One atlas's shelf allocator.
    private struct Shelf {
        let size: Int
        var shelfY = 0, shelfHeight = 0, nextX = 0

        init(size: Int) {
            self.size = size
        }

        mutating func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width <= size else { return nil }
            if nextX + width > size {
                shelfY += shelfHeight
                shelfHeight = 0
                nextX = 0
            }
            guard shelfY + max(shelfHeight, height) <= size else { return nil }
            let origin = (x: nextX, y: shelfY)
            nextX += width
            shelfHeight = max(shelfHeight, height)
            return origin
        }
    }

    public init(device: MTLDevice, fonts: FontStack, scale: CGFloat = 2,
                size: Int = 1024, colorSize: Int = 512) throws {
        self.fonts = fonts
        self.scale = scale
        self.size = size
        self.colorSize = colorSize
        self.gray = Shelf(size: size)
        self.color = Shelf(size: colorSize)

        func makeTexture(_ format: MTLPixelFormat, _ side: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: side, height: side, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .managed
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw Failure.textureCreation
            }
            return texture
        }
        // R8 for coverage, BGRA8 for colour fonts. Emoji are rare enough that
        // the colour atlas can be a quarter the size.
        self.texture = try makeTexture(.r8Unorm, size)
        self.colorTexture = try makeTexture(.bgra8Unorm, colorSize)
    }

    /// Returns the placement for a grapheme cluster, rasterising it on first
    /// sight. Blank cells have no glyph and return nil. Throws `.full` when
    /// there is no room left for it.
    public func placement(for text: String, attributes: Cell.Attributes) throws -> GlyphPlacement? {
        guard !text.isEmpty, text != " " else { return nil }

        let bold = attributes.contains(.bold), italic = attributes.contains(.italic)
        var ascii: Int?
        if text.utf8.count == 1, let byte = text.utf8.first, byte < 128 {
            let index = Int(byte) * 4 + (bold ? 2 : 0) + (italic ? 1 : 0)
            if let existing = asciiPlacements[index] { return existing }
            ascii = index
        }
        let key = Key(text: text, bold: bold, italic: italic)
        if ascii == nil, let existing = placements[key] { return existing }

        // Shaping and drawing a glyph go through CoreText; see CoreTextLock.
        CoreTextLock.shared.lock()
        defer { CoreTextLock.shared.unlock() }
        let placement = try rasterize(key)
        if let ascii { asciiPlacements[ascii] = .some(placement) } else { placements[key] = placement }
        return placement
    }

    /// Forgets every glyph and starts both textures again from the top.
    /// Every placement handed out before is void.
    public func reset() {
        placements.removeAll()
        asciiPlacements = [GlyphPlacement??](repeating: nil, count: 128 * 4)
        gray = Shelf(size: size)
        color = Shelf(size: colorSize)
    }

    /// Margin around the cell box, in device pixels, so glyphs that overflow
    /// their cell -- descenders, box drawing, italics -- are not clipped.
    private static let margin = 4

    private func rasterize(_ key: Key) throws -> GlyphPlacement? {
        var attributes: Cell.Attributes = []
        if key.bold { attributes.insert(.bold) }
        if key.italic { attributes.insert(.italic) }
        // Box drawing is produced rather than looked up, so strokes meet
        // across cell boundaries; see BoxDrawing. It needs no line.
        let isBox = BoxDrawing.shape(for: key.text) != nil || BoxDrawing.isBlock(key.text)

        // Laid out as a line rather than mapped glyph by glyph, which gets
        // grapheme clusters and -- for free -- CoreText's own font fallback:
        // neither Maple Mono nor Menlo has CJK, yet 写 renders, because the
        // line cascades to a system font that does.
        //
        // Without kCTForegroundColorFromContextAttributeName, CoreText draws
        // with its own default (black) and ignores the context's fill colour --
        // which on a black staging bitmap produces a perfectly empty glyph.
        let line = isBox ? nil : CTLineCreateWithAttributedString(NSAttributedString(
            string: key.text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: fonts.font(for: attributes),
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ]))

        let fillsCell = Self.fillsWholeCell(key.text)
        let wantsColor = line.map(lineNeedsColor) ?? false
        let margin = Self.margin
        let cell = fonts.metrics.pixelSize(scale: scale)
        // Room for a double-width cell, so a wide character is not clipped.
        let width = Int(cell.width) * 2 + margin * 2
        let height = Int(cell.height) + margin * 2

        let bytesPerPixel = wantsColor ? 4 : 1
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
            space: wantsColor ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
            bitmapInfo: wantsColor
                ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                : CGImageAlphaInfo.none.rawValue)
        else { throw Failure.textureCreation }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSubpixelPositionFonts(true)
        // Said either way: left alone, a bitmap context smooths, and that
        // thickening is what made text heavier here than in Ghostty. Not for
        // a glyph stretched to fill its cell, though -- a powerline separator
        // has to meet the next cell with its edge rows fully inked, and
        // without smoothing those rows come out faint enough to show a seam.
        let smooths = fonts.thickens || fillsCell
        context.setAllowsFontSmoothing(smooths)
        context.setShouldSmoothFonts(smooths)

        if wantsColor {
            // Transparent, so the emoji composites over the cell background.
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            // White on black: the value is coverage, which the shader uses to
            // blend the cell's foreground colour.
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 1, alpha: 1)
        }

        if let line, fillsCell {
            drawStretchedToCell(line, in: context, cell: cell, margin: margin)
        } else if let line {
            // Draw at the cell's own baseline, offset by the margin.
            // CoreGraphics measures y upward from the bottom, so the baseline
            // sits at (height - margin - baseline) from the bottom.
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(
                // Centred when the cell is wider than the font's own advance,
                // so letter spacing adds gaps rather than shifting everything
                // left.
                x: CGFloat(margin) / scale + fonts.metrics.glyphInset,
                y: (CGFloat(height - margin) / scale) - fonts.metrics.baseline)
            CTLineDraw(line, context)
        } else {
            // Drawn in device pixels with the cell's own top-left as origin,
            // which is the margin. CoreGraphics measures y upward, so the
            // context is flipped first to match the cell's sense of "down".
            let cellWidth = cell.width
            let cellHeight = cell.height
            context.saveGState()
            context.translateBy(x: CGFloat(margin), y: CGFloat(height - margin))
            context.scaleBy(x: 1, y: -1)
            BoxDrawing.draw(key.text, into: context,
                            cellWidth: cellWidth, cellHeight: cellHeight)
            context.restoreGState()
        }

        // A blank or unrenderable cluster leaves the bitmap empty; do not waste
        // a draw call on it, nor a slot. Room is only taken once there is
        // something to put in it.
        guard bitmapHasInk(context, width: width, height: height,
                           bytesPerPixel: bytesPerPixel) else { return nil }

        guard let origin = (wantsColor ? color.allocate(width: width, height: height)
                                       : gray.allocate(width: width, height: height))
        else { throw Failure.full }

        upload(context, to: wantsColor ? colorTexture : texture, at: origin, width: width, height: height,
               bytesPerPixel: bytesPerPixel)

        return GlyphPlacement(
            x: UInt32(origin.x), y: UInt32(origin.y),
            width: UInt32(width), height: UInt32(height),
            offsetX: Int32(-margin), offsetY: Int32(-margin),
            isColor: wantsColor)
    }

    /// Glyphs that are meant to reach the edges of their cell.
    ///
    /// Powerline separators are drawn as text but behave like geometry: each
    /// one is half of a shape whose other half is the neighbouring cell's
    /// background. Rendered at their natural size they fall short of a cell
    /// that has been made taller by a line-height setting, and the seam shows
    /// as a gap above and below every prompt segment.
    static func fillsWholeCell(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first
        else { return false }
        return (0xE0B0...0xE0D4).contains(scalar.value)   // Powerline, incl. extras
            || (0xE0A0...0xE0A2).contains(scalar.value)   // branch, line number, padlock
    }

    /// Draws a glyph scaled so its ink exactly fills the cell.
    ///
    /// Only for shapes that are supposed to butt against their neighbours;
    /// doing this to ordinary text would distort it.
    private func drawStretchedToCell(_ line: CTLine, in context: CGContext,
                                     cell: CGSize, margin: Int) {
        let metrics = fonts.metrics
        let emHeight = metrics.ascent + metrics.descent
        guard emHeight > 0, metrics.naturalAdvance > 0 else { return }

        // Mapped from the font's own em box, not from measured ink.
        //
        // `CTLineGetImageBounds` reports a box that includes the antialiased
        // edge, and not symmetrically -- scaling to it left these glyphs half a
        // row high, which on a prompt reads as the separators sitting slightly
        // above the segment beside them. The em box is exact, and it is what
        // these glyphs were drawn against: they are meant to span descender to
        // ascender and one full advance.
        let horizontal = metrics.cellWidth / metrics.naturalAdvance
        let vertical = metrics.cellHeight / emHeight

        context.saveGState()
        // Clipped as well, so antialiasing cannot spill into the rows above
        // and below however the scaling lands.
        context.clip(to: CGRect(x: CGFloat(margin), y: CGFloat(margin),
                                width: cell.width, height: cell.height))
        context.translateBy(x: CGFloat(margin), y: CGFloat(margin))
        context.scaleBy(x: scale * horizontal, y: scale * vertical)
        // The baseline sits one descent above the bottom of the cell, which
        // puts ascent and descent either side of it exactly as designed.
        context.textPosition = CGPoint(x: 0, y: metrics.descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Whether any run in the line uses a colour font, which is how an emoji
    /// announces itself: drawn into a grayscale bitmap it would come out as a
    /// flat silhouette.
    private func lineNeedsColor(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        for run in runs {
            guard let attributes = CTRunGetAttributes(run) as? [CFString: Any],
                  let font = attributes[kCTFontAttributeName] as! CTFont?
            else { continue }
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return true }
        }
        return false
    }

    private func bitmapHasInk(_ context: CGContext, width: Int, height: Int,
                              bytesPerPixel: Int) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // For colour bitmaps only the alpha byte says whether anything is
        // there; for coverage every byte does.
        let stride = bytesPerPixel
        let offset = bytesPerPixel == 4 ? 3 : 0
        for index in Swift.stride(from: offset, to: width * height * stride, by: stride)
        where bytes[index] > 0 { return true }
        return false
    }

    /// Straight from the bitmap into the glyph's own rect. Nothing else of
    /// the texture is ever sampled: a quad covers exactly its glyph's texels,
    /// and the sampler is nearest.
    ///
    /// No vertical flip: a CGBitmapContext's *coordinate system* is bottom-up,
    /// but its memory layout already starts at the top row, which is what the
    /// texture wants. Flipping here renders every glyph upside down while
    /// leaving line order correct -- a distinctive symptom.
    private func upload(_ context: CGContext, to target: MTLTexture, at origin: (x: Int, y: Int),
                        width: Int, height: Int, bytesPerPixel: Int) {
        guard let source = context.data else { return }
        target.replace(region: MTLRegionMake2D(origin.x, origin.y, width, height), mipmapLevel: 0,
                       withBytes: source, bytesPerRow: width * bytesPerPixel)
    }
}
