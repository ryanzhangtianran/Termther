import Testing
@testable import VT

/// Powerline separators are half of a shape whose other half is a neighbouring
/// cell's background. Any disagreement about where the cell is shows up as a
/// hairline along every prompt segment, so this checks every combination that
/// a prompt actually produces rather than one representative case.
private struct Seam {
    let renderer: CellRenderer
    let pixels: [UInt8]
    let width: Int, height: Int
    let cell: CGSize

    /// The row the glyph is on, so overflow above and below can be seen.
    let glyphRow = 1

    /// Three rows of three cells, with the glyph in the middle.
    ///
    /// The empty rows are the point: a canvas exactly one cell tall clips
    /// anything that overflows, so a glyph drawn too large still measures as
    /// filling its cell -- which is how a separator with spikes poking into
    /// the lines above and below passed as correct.
    init(_ text: String, lineHeight: CGFloat, letterSpacing: CGFloat = 1.0) throws {
        let fonts = FontStack(size: 13, lineHeight: lineHeight, letterSpacing: letterSpacing)
        renderer = try CellRenderer(fonts: fonts, scale: 2)
        cell = renderer.cellSizeInPixels
        width = Int(cell.width) * 3
        height = Int(cell.height) * 3

        let ink = Color(red: 255, green: 128, blue: 128)
        func blank() -> [Cell] {
            (0..<3).map { _ in
                Cell(text: " ", foreground: nil, background: nil,
                     attributes: [], isSelected: false)
            }
        }
        let frame = Frame(
            cols: 3, rows: 3, isFullRedraw: true,
            dirtyRows: [
                Row(y: 0, cells: blank()),
                Row(y: 1, cells: [
                    Cell(text: " ", foreground: nil, background: ink, attributes: [], isSelected: false),
                    Cell(text: text, foreground: ink, background: nil, attributes: [], isSelected: false),
                    Cell(text: " ", foreground: nil, background: ink, attributes: [], isSelected: false),
                ]),
                Row(y: 2, cells: blank()),
            ],
            cursor: nil,
            defaultForeground: Color(red: 255, green: 255, blue: 255),
            defaultBackground: Color(red: 0, green: 0, blue: 0))

        try renderer.apply(frame)
        let texture = try renderer.render(width: width, height: height)
        let byteCount = width * height * 4
        // Read into a local first: the closure must not capture a self whose
        // stored properties are still being initialised.
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rowBytes = width * 4
        let region = MTLRegionMake2D(0, 0, width, height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                             from: region, mipmapLevel: 0)
        }
        pixels = bytes
    }

    /// Lit rows of a column, within the glyph's own row.
    func coverage(atX x: Int) -> Int {
        rows(atX: x, from: glyphRow * Int(cell.height), count: Int(cell.height))
    }

    /// Lit rows of a column in the blank rows above and below. Anything here is
    /// a glyph that has overflowed its cell.
    func spill(atX x: Int) -> Int {
        rows(atX: x, from: 0, count: Int(cell.height))
            + rows(atX: x, from: 2 * Int(cell.height), count: Int(cell.height))
    }

    private func rows(atX x: Int, from start: Int, count: Int) -> Int {
        (start..<(start + count)).filter { y in
            let i = (y * width + x) * 4
            return !(pixels[i] == 0 && pixels[i + 1] == 0 && pixels[i + 2] == 0)
        }.count
    }
}

import Metal

/// The glyphs a prompt is built from, and which side each one has to meet a
/// background on.
private let separators: [(name: String, text: String, meetsLeft: Bool, meetsRight: Bool)] = [
    ("right triangle \u{E0B0}", "\u{E0B0}", true, false),
    ("left triangle \u{E0B2}", "\u{E0B2}", false, true),
    ("right half circle \u{E0B4}", "\u{E0B4}", true, false),
    ("left half circle \u{E0B6}", "\u{E0B6}", false, true),
]

@Test("every separator meets its neighbour at every line height",
      arguments: [1.0, 1.15, 1.17, 1.3, 1.5])
func seamsHold(lineHeight: CGFloat) throws {
    guard FontStack().resolvedName.contains("Maple") else { return }   // needs a Nerd Font

    for separator in separators {
        let seam = try Seam(separator.text, lineHeight: lineHeight)
        let full = Int(seam.cell.height)

        // The backgrounds either side must fill their cells completely; if
        // they do not, the comparison below is meaningless.
        #expect(seam.coverage(atX: Int(seam.cell.width) - 1) == full)
        #expect(seam.coverage(atX: Int(seam.cell.width) * 2) == full)

        // And nothing may reach the rows above or below: a separator that
        // overflows shows as spikes poking out of the prompt.
        for column in stride(from: Int(seam.cell.width), to: Int(seam.cell.width) * 2, by: 2) {
            let spill = seam.spill(atX: column)
            #expect(spill == 0,
                    "\(separator.name) at \(lineHeight)x: spills \(spill) rows outside its cell")
        }

        if separator.meetsLeft {
            let column = seam.coverage(atX: Int(seam.cell.width))
            #expect(column == full,
                    "\(separator.name) at \(lineHeight)x: left edge covers \(column) of \(full) rows")
        }
        if separator.meetsRight {
            let column = seam.coverage(atX: Int(seam.cell.width) * 2 - 1)
            #expect(column == full,
                    "\(separator.name) at \(lineHeight)x: right edge covers \(column) of \(full) rows")
        }
    }
}

@Test("separators still meet when the columns are widened")
func seamsHoldWithLetterSpacing() throws {
    guard FontStack().resolvedName.contains("Maple") else { return }

    for separator in separators {
        let seam = try Seam(separator.text, lineHeight: 1.2, letterSpacing: 1.2)
        let full = Int(seam.cell.height)
        if separator.meetsLeft {
            let column = seam.coverage(atX: Int(seam.cell.width))
            #expect(column == full, "\(separator.name): left edge covers \(column) of \(full)")
        }
        if separator.meetsRight {
            let column = seam.coverage(atX: Int(seam.cell.width) * 2 - 1)
            #expect(column == full, "\(separator.name): right edge covers \(column) of \(full)")
        }
    }
}
