import Foundation
import Metal
import Testing
@testable import VT

/// Renders into an offscreen texture and reads the pixels back.
///
/// Everything about the renderer that can go wrong -- a wrong clip-space
/// transform, a vertex descriptor that disagrees with the shader, glyphs
/// landing a row off, colours swapped -- shows up as pixels. Doing it headless
/// means it is all covered by `swift test`, with no window and no screenshot to
/// eyeball.
struct Canvas {
    let renderer: CellRenderer
    let texture: MTLTexture
    let width: Int, height: Int

    init(cols: Int, rows: Int, fonts: FontStack = FontStack()) throws {
        renderer = try CellRenderer(fonts: fonts, scale: 2)
        let cell = renderer.cellSizeInPixels
        width = Int(cell.width) * cols
        height = Int(cell.height) * rows

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        texture = renderer.device.makeTexture(descriptor: descriptor)!
    }

    func render(_ frame: Frame) throws -> [UInt8] {
        try renderer.apply(frame)
        renderer.draw(into: texture)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }
        return pixels
    }

    /// BGRA at a pixel.
    func pixel(_ pixels: [UInt8], x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i + 2], pixels[i + 1], pixels[i])
    }

    /// How many pixels inside a cell are not the background -- the cheap,
    /// robust way to ask "did a glyph land here".
    func inkCount(_ pixels: [UInt8], cellX: Int, cellY: Int, background: (UInt8, UInt8, UInt8)) -> Int {
        let cell = renderer.cellSizeInPixels
        var count = 0
        for y in Int(cell.height) * cellY ..< min(height, Int(cell.height) * (cellY + 1)) {
            for x in Int(cell.width) * cellX ..< min(width, Int(cell.width) * (cellX + 1)) {
                let p = pixel(pixels, x: x, y: y)
                if p != background { count += 1 }
            }
        }
        return count
    }
}

private func frame(cols: UInt16, rows: UInt16, cells: [[Cell]],
                   fg: Color = Color(red: 255, green: 255, blue: 255),
                   bg: Color = Color(red: 0, green: 0, blue: 0)) -> Frame {
    Frame(cols: cols, rows: rows, isFullRedraw: true,
          dirtyRows: cells.enumerated().map { Row(y: UInt16($0.offset), cells: $0.element) },
          cursor: nil, defaultForeground: fg, defaultBackground: bg)
}

private func cell(_ text: String,
                  fg: Color? = nil, bg: Color? = nil,
                  attributes: Cell.Attributes = []) -> Cell {
    Cell(text: text, foreground: fg, background: bg,
         attributes: attributes, isSelected: false)
}

@Test("a blank screen is the default background, everywhere")
func blankScreen() throws {
    let canvas = try Canvas(cols: 4, rows: 2)
    let pixels = try canvas.render(frame(cols: 4, rows: 2, cells: [
        [cell(" "), cell(" "), cell(" "), cell(" ")],
        [cell(" "), cell(" "), cell(" "), cell(" ")],
    ], bg: Color(red: 20, green: 20, blue: 30)))

    #expect(canvas.pixel(pixels, x: 0, y: 0) == (20, 20, 30))
    #expect(canvas.pixel(pixels, x: canvas.width - 1, y: canvas.height - 1) == (20, 20, 30))
}

@Test("a glyph lands in its own cell and nowhere else")
func glyphLandsInItsCell() throws {
    let canvas = try Canvas(cols: 4, rows: 2)
    // "M" in the second column of the second row: a dense glyph, so if the
    // grid arithmetic is off by a cell this fails loudly.
    let pixels = try canvas.render(frame(cols: 4, rows: 2, cells: [
        [cell(" "), cell(" "),  cell(" "), cell(" ")],
        [cell(" "), cell("M"),  cell(" "), cell(" ")],
    ]))

    let black: (UInt8, UInt8, UInt8) = (0, 0, 0)
    #expect(canvas.inkCount(pixels, cellX: 1, cellY: 1, background: black) > 20)
    for (x, y) in [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1), (2, 1), (3, 1)] {
        #expect(canvas.inkCount(pixels, cellX: x, cellY: y, background: black) == 0,
                "cell (\(x),\(y)) should be empty")
    }
}

@Test("a cell background fills its whole cell")
func backgroundFillsCell() throws {
    let canvas = try Canvas(cols: 3, rows: 1)
    let red = Color(red: 255, green: 0, blue: 0)
    let pixels = try canvas.render(frame(cols: 3, rows: 1, cells: [
        [cell(" "), cell(" ", bg: red), cell(" ")],
    ]))

    let cellSize = canvas.renderer.cellSizeInPixels
    let midY = Int(cellSize.height) / 2
    #expect(canvas.pixel(pixels, x: Int(cellSize.width) / 2, y: midY) == (0, 0, 0))
    #expect(canvas.pixel(pixels, x: Int(cellSize.width) + 2, y: 1) == (255, 0, 0))
    #expect(canvas.pixel(pixels, x: Int(cellSize.width * 2) - 2, y: Int(cellSize.height) - 2) == (255, 0, 0))
    #expect(canvas.pixel(pixels, x: Int(cellSize.width * 2) + 2, y: midY) == (0, 0, 0))
}

@Test("foreground colour reaches the glyph")
func foregroundColour() throws {
    let canvas = try Canvas(cols: 2, rows: 1)
    let green = Color(red: 0, green: 255, blue: 0)
    let pixels = try canvas.render(frame(cols: 2, rows: 1, cells: [
        [cell("M", fg: green), cell(" ")],
    ]))

    // Every lit pixel must be on the green ramp: no red or blue leaking in.
    let cellSize = canvas.renderer.cellSizeInPixels
    var litPixels = 0
    for y in 0..<Int(cellSize.height) {
        for x in 0..<Int(cellSize.width) {
            let p = canvas.pixel(pixels, x: x, y: y)
            guard p != (0, 0, 0) else { continue }
            litPixels += 1
            #expect(p.r == 0 && p.b == 0, "expected green ramp, got \(p)")
        }
    }
    #expect(litPixels > 20)
}

@Test("inverse swaps foreground and background")
func inverseSwaps() throws {
    let canvas = try Canvas(cols: 2, rows: 1)
    let pixels = try canvas.render(frame(cols: 2, rows: 1, cells: [
        [cell("M", attributes: .inverse), cell(" ")],
    ]))

    // The cell is now mostly white with dark glyph strokes: the corner, which
    // "M" does not reach, must be the swapped-in background.
    #expect(canvas.pixel(pixels, x: 0, y: 0) == (255, 255, 255))
}

@Test("only dirty rows change; the rest of the grid persists")
func partialFramesComposite() throws {
    let canvas = try Canvas(cols: 3, rows: 2)
    _ = try canvas.render(frame(cols: 3, rows: 2, cells: [
        [cell("M"), cell(" "), cell(" ")],
        [cell(" "), cell(" "), cell(" ")],
    ]))

    // A later frame touching only row 1 must not erase row 0.
    let partial = Frame(cols: 3, rows: 2, isFullRedraw: false,
                        dirtyRows: [Row(y: 1, cells: [cell(" "), cell("M"), cell(" ")])],
                        cursor: nil,
                        defaultForeground: Color(red: 255, green: 255, blue: 255),
                        defaultBackground: Color(red: 0, green: 0, blue: 0))
    let pixels = try canvas.render(partial)

    let black: (UInt8, UInt8, UInt8) = (0, 0, 0)
    #expect(canvas.inkCount(pixels, cellX: 0, cellY: 0, background: black) > 20)
    #expect(canvas.inkCount(pixels, cellX: 1, cellY: 1, background: black) > 20)
}

@Test("the atlas rasterises each glyph once and reuses it")
func atlasCaches() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let atlas = try GlyphAtlas(device: device, fonts: FontStack())

    let first = try #require(try atlas.placement(for: "A", attributes: []))
    let again = try #require(try atlas.placement(for: "A", attributes: []))
    #expect(first == again)

    // Bold is a different shape, so it gets its own entry.
    let bold = try #require(try atlas.placement(for: "A", attributes: .bold))
    #expect(bold != first)

    // A blank cell has nothing to draw.
    #expect(try atlas.placement(for: " ", attributes: []) == nil)
    #expect(try atlas.placement(for: "", attributes: []) == nil)
}

@Test("line height and letter spacing change the cell, not the glyph")
func gridMultipliers() throws {
    let natural = FontStack(size: 13)
    let loose = FontStack(size: 13, lineHeight: 1.5, letterSpacing: 1.25)

    #expect(loose.metrics.cellHeight > natural.metrics.cellHeight)
    #expect(loose.metrics.cellWidth > natural.metrics.cellWidth)

    // The extra room is split above and below, so text stays on its baseline
    // rather than sliding to the top of a taller row.
    let addedHeight = loose.metrics.cellHeight - natural.metrics.cellHeight
    let movedBaseline = loose.metrics.baseline - natural.metrics.baseline
    #expect(abs(movedBaseline - addedHeight / 2) <= 1)

    // And the glyph is centred in a wider cell rather than being stretched.
    #expect(loose.metrics.glyphInset > 0)
    #expect(natural.metrics.glyphInset == 0)
}

@Test("a taller row still puts its glyph in the right cell")
func tallRowsStayAligned() throws {
    // Loosening the grid is the change most likely to knock glyph placement
    // out, because every offset is derived from the cell box.
    let canvas = try Canvas(cols: 3, rows: 3, fonts: FontStack(size: 13, lineHeight: 1.6))
    let pixels = try canvas.render(frame(cols: 3, rows: 3, cells: [
        [cell(" "), cell(" "), cell(" ")],
        [cell(" "), cell("M"), cell(" ")],
        [cell(" "), cell(" "), cell(" ")],
    ]))

    let black: (UInt8, UInt8, UInt8) = (0, 0, 0)
    #expect(canvas.inkCount(pixels, cellX: 1, cellY: 1, background: black) > 20)
    for (x, y) in [(0, 1), (2, 1), (1, 0), (1, 2)] {
        #expect(canvas.inkCount(pixels, cellX: x, cellY: y, background: black) == 0,
                "ink leaked into (\(x),\(y))")
    }
}

@Test("a powerline separator meets the background beside it exactly")
func powerlineSeam() throws {
    // The real invariant: at the seam, the glyph's column and the neighbouring
    // background's column must be lit over exactly the same rows. Anything
    // else is the hairline that shows up along every prompt segment.
    let fonts = FontStack(size: 13, lineHeight: 1.5)
    guard fonts.resolvedName.contains("Maple") else { return }

    let canvas = try Canvas(cols: 4, rows: 1, fonts: fonts)
    let pink = Color(red: 255, green: 128, blue: 128)
    // A background cell, then the separator drawn in the same colour: the two
    // are halves of one shape.
    let pixels = try canvas.render(frame(cols: 4, rows: 1, cells: [[
        cell(" ", bg: pink),
        cell("\u{E0B0}", fg: pink),
        cell(" "), cell(" "),
    ]]))

    let cell = canvas.renderer.cellSizeInPixels
    func litRows(atX x: Int) -> [Int] {
        (0..<Int(cell.height)).filter { canvas.pixel(pixels, x: x, y: $0) != (0, 0, 0) }
    }

    // The last column of the background, and the first column of the glyph.
    let background = litRows(atX: Int(cell.width) - 1)
    let separator = litRows(atX: Int(cell.width))

    #expect(background.count == Int(cell.height), "the background should fill its cell")
    let message = "seam mismatch: background covers \(background.count) rows, separator covers \(separator.count)"
    #expect(separator == background, "\(message)")
}

/// A screen with something in every cell.
///
/// This is the test that was missing. Every other one draws a handful of
/// glyphs, and a handful fits inside the 4 KB that `setVertexBytes` allows --
/// so the renderer passed everything while carrying a call that aborts the
/// process the moment a screen is actually full. It shipped, and it crashed on
/// the first `ls` of a large directory.
@Test("a full screen of text draws, whatever the instance count")
func fullScreenOfText() throws {
    let cols = 100, rows = 30
    let canvas = try Canvas(cols: cols, rows: rows)

    // Every cell filled, foreground and background both set, so the frame
    // carries three instances per cell across the three passes.
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    let cells = (0..<rows).map { row in
        (0..<cols).map { column in
            cell(String(letters[(row + column) % letters.count]),
                 fg: Color(red: 220, green: 220, blue: 220),
                 bg: Color(red: 20, green: 30, blue: 40))
        }
    }

    let pixels = try canvas.render(frame(cols: UInt16(cols), rows: UInt16(rows), cells: cells))

    // Reaching here at all is most of the point -- the old path aborted inside
    // the Metal driver rather than returning. The corners confirm it drew the
    // whole grid and not just the part that fitted.
    let background = (UInt8(20), UInt8(30), UInt8(40))
    #expect(canvas.inkCount(pixels, cellX: 0, cellY: 0, background: background) > 0)
    #expect(canvas.inkCount(pixels, cellX: cols - 1, cellY: rows - 1,
                            background: background) > 0)
    #expect(canvas.inkCount(pixels, cellX: cols / 2, cellY: rows / 2,
                            background: background) > 0)
}
