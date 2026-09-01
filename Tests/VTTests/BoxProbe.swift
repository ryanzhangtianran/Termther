import Metal
import Testing
@testable import VT

@Test("a full block fills its whole cell, edge to edge")
func fullBlockFillsCell() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let fonts = FontStack()
    let atlas = try GlyphAtlas(device: device, fonts: fonts, scale: 2)
    let placement = try #require(try atlas.placement(for: "█", attributes: []))
    atlas.flush()

    var pixels = [UInt8](repeating: 0, count: atlas.size * atlas.size)
    pixels.withUnsafeMutableBytes { raw in
        atlas.texture.getBytes(raw.baseAddress!, bytesPerRow: atlas.size,
                               from: MTLRegionMake2D(0, 0, atlas.size, atlas.size), mipmapLevel: 0)
    }

    // The bitmap is a cell plus a margin on each side; the block must cover the
    // cell exactly -- no gap at the edges, or adjacent blocks show seams.
    let cellWidth = Int((fonts.metrics.cellWidth * 2).rounded())
    let cellHeight = Int((fonts.metrics.cellHeight * 2).rounded())
    let left = Int(placement.x) - Int(placement.offsetX)
    let top = Int(placement.y) - Int(placement.offsetY)

    func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * atlas.size + x] > 128 }

    for corner in [(left, top), (left + cellWidth - 1, top),
                   (left, top + cellHeight - 1), (left + cellWidth - 1, top + cellHeight - 1)] {
        #expect(lit(corner.0, corner.1), "block does not reach corner \(corner)")
    }
    // And it must not spill into the margin, or neighbouring cells overlap.
    #expect(!lit(left - 1, top + cellHeight / 2), "block spills left of its cell")
    #expect(!lit(left + cellWidth, top + cellHeight / 2), "block spills right of its cell")
}

@Test("a powerline separator reaches every edge of its cell")
func powerlineFillsCell() throws {
    // These are half of a shape whose other half is the next cell's
    // background. Drawn at their natural size in a cell made taller by a
    // line-height setting they fall short, and the seam shows as a gap above
    // and below every prompt segment.
    let device = MTLCreateSystemDefaultDevice()!
    let fonts = FontStack(size: 13, lineHeight: 1.4)
    guard fonts.resolvedName.contains("Maple") else { return }   // needs a Nerd Font

    let atlas = try GlyphAtlas(device: device, fonts: fonts, scale: 2)
    // U+E0B0, the solid right-pointing triangle every prompt uses.
    let placement = try #require(try atlas.placement(for: "\u{E0B0}", attributes: []))
    atlas.flush()

    var pixels = [UInt8](repeating: 0, count: atlas.size * atlas.size)
    pixels.withUnsafeMutableBytes { raw in
        atlas.texture.getBytes(raw.baseAddress!, bytesPerRow: atlas.size,
                               from: MTLRegionMake2D(0, 0, atlas.size, atlas.size), mipmapLevel: 0)
    }

    let cellHeight = Int((fonts.metrics.cellHeight * 2).rounded())
    let left = Int(placement.x) - Int(placement.offsetX)
    let top = Int(placement.y) - Int(placement.offsetY)
    func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * atlas.size + x] > 100 }

    // The flat edge runs the full height of the cell, top row to bottom row.
    #expect(lit(left, top + 1), "nothing at the top of the cell")
    #expect(lit(left, top + cellHeight - 2), "nothing at the bottom of the cell")
    #expect(lit(left, top + cellHeight / 2), "nothing in the middle")
}

@Test("a stretched glyph is exactly as tall as the renderer's cell")
func stretchedGlyphMatchesCell() throws {
    // The cell size used to be worked out separately in the renderer, the
    // atlas and the stretching path, with three different roundings. The
    // fractions of a pixel between them were enough for a powerline separator
    // -- which is meant to butt against the cell background beside it -- to
    // sit visibly proud of it.
    let device = MTLCreateSystemDefaultDevice()!
    // A line height that does not land on a whole pixel, which is where the
    // disagreement showed.
    let fonts = FontStack(size: 13, lineHeight: 1.17)
    guard fonts.resolvedName.contains("Maple") else { return }

    let cell = fonts.metrics.pixelSize(scale: 2)
    let renderer = try CellRenderer(fonts: fonts, scale: 2)
    #expect(renderer.cellSizeInPixels == cell, "the renderer disagrees about the cell")

    let atlas = try GlyphAtlas(device: device, fonts: fonts, scale: 2)
    let placement = try #require(try atlas.placement(for: "\u{E0B0}", attributes: []))
    atlas.flush()

    var pixels = [UInt8](repeating: 0, count: atlas.size * atlas.size)
    pixels.withUnsafeMutableBytes { raw in
        atlas.texture.getBytes(raw.baseAddress!, bytesPerRow: atlas.size,
                               from: MTLRegionMake2D(0, 0, atlas.size, atlas.size), mipmapLevel: 0)
    }

    let left = Int(placement.x) - Int(placement.offsetX)
    let top = Int(placement.y) - Int(placement.offsetY)
    func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * atlas.size + x] > 100 }

    // Ink on the first and last row of the cell, and none in the margin
    // outside it: exactly the cell, not a fraction more.
    #expect(lit(left, top), "the glyph does not reach the top of the cell")
    #expect(lit(left, top + Int(cell.height) - 1), "it does not reach the bottom")
    #expect(!lit(left, top - 2), "it spills above the cell")
    #expect(!lit(left, top + Int(cell.height) + 1), "it spills below the cell")
}
