import CoreGraphics
import Foundation

/// Draws box-drawing characters instead of asking the font for them.
///
/// A font's box glyphs are designed against its own em box, not against our
/// cell, and most monospaced faces do not contain them at all -- CoreText then
/// falls back to whatever font does, whose line weights and positions differ
/// again. Either way the strokes land in the wrong place and adjacent cells
/// stop meeting, which is exactly the thing box drawing exists to do. Anything
/// built out of these characters -- vim splits, tmux panes, htop, table output
/// -- comes out visibly broken.
///
/// Drawing them ourselves makes them exact by construction: a horizontal line
/// spans the full cell width at a fixed fraction of its height, so the same
/// stroke in the next cell continues it seamlessly.
enum BoxDrawing {
    /// Which edges of the cell a stroke reaches, and how heavy it is.
    struct Edges: OptionSet {
        let rawValue: UInt8
        static let left   = Edges(rawValue: 1 << 0)
        static let right  = Edges(rawValue: 1 << 1)
        static let up     = Edges(rawValue: 1 << 2)
        static let down   = Edges(rawValue: 1 << 3)
    }

    struct Shape {
        var light: Edges = []
        var heavy: Edges = []
        var isDouble = false
    }

    /// The characters worth drawing ourselves: the light and heavy line set,
    /// the double-line set, and the block elements TUIs use for bars and
    /// shading. Anything else falls through to the font.
    static func shape(for text: String) -> Shape? {
        guard text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first
        else { return nil }
        return table[scalar.value]
    }

    static func isBlock(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1
        else { return false }
        return (0x2580...0x259F).contains(scalar.value)
    }

    /// Draws the character into a context whose origin is the cell's top-left,
    /// in device pixels. Returns false when it is not one we handle.
    @discardableResult
    static func draw(_ text: String, into context: CGContext,
                     cellWidth: CGFloat, cellHeight: CGFloat) -> Bool {
        if let scalar = text.unicodeScalars.first, (0x2580...0x259F).contains(scalar.value) {
            drawBlock(scalar.value, into: context, cellWidth: cellWidth, cellHeight: cellHeight)
            return true
        }
        guard let shape = shape(for: text) else { return false }

        // Odd thicknesses centre exactly on a pixel, which keeps strokes crisp
        // rather than straddling two rows at half intensity.
        let light = max(1, (cellHeight / 12).rounded())
        let heavy = max(2, light * 2)
        let midX = (cellWidth / 2).rounded()
        let midY = (cellHeight / 2).rounded()

        func stroke(_ edges: Edges, _ thickness: CGFloat) {
            let half = (thickness / 2).rounded()
            if edges.contains(.left) {
                context.fill(CGRect(x: 0, y: midY - half, width: midX + half, height: thickness))
            }
            if edges.contains(.right) {
                context.fill(CGRect(x: midX - half, y: midY - half,
                                    width: cellWidth - midX + half, height: thickness))
            }
            if edges.contains(.up) {
                context.fill(CGRect(x: midX - half, y: 0, width: thickness, height: midY + half))
            }
            if edges.contains(.down) {
                context.fill(CGRect(x: midX - half, y: midY - half,
                                    width: thickness, height: cellHeight - midY + half))
            }
        }

        if shape.isDouble {
            // Two thin strokes a gap apart, so parallel runs stay distinct.
            let gap = max(2, light * 2)
            for offset in [-gap, gap] {
                if shape.light.contains(.left) {
                    context.fill(CGRect(x: 0, y: midY + offset, width: midX + gap, height: light))
                }
                if shape.light.contains(.right) {
                    context.fill(CGRect(x: midX - gap, y: midY + offset,
                                        width: cellWidth - midX + gap, height: light))
                }
                if shape.light.contains(.up) {
                    context.fill(CGRect(x: midX + offset, y: 0, width: light, height: midY + gap))
                }
                if shape.light.contains(.down) {
                    context.fill(CGRect(x: midX + offset, y: midY - gap,
                                        width: light, height: cellHeight - midY + gap))
                }
            }
            return true
        }

        stroke(shape.light, light)
        stroke(shape.heavy, heavy)
        return true
    }

    private static func drawBlock(_ scalar: UInt32, into context: CGContext,
                                  cellWidth w: CGFloat, cellHeight h: CGFloat) {
        switch scalar {
        case 0x2588: context.fill(CGRect(x: 0, y: 0, width: w, height: h))          // full
        case 0x2580: context.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))      // upper half
        case 0x2584: context.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))  // lower half
        case 0x258C: context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))      // left half
        case 0x2590: context.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))  // right half
        // Eighths, used for fine-grained progress bars and sparklines.
        case 0x2581...0x2587:
            let eighths = CGFloat(scalar - 0x2580)
            let height = h * eighths / 8
            context.fill(CGRect(x: 0, y: h - height, width: w, height: height))
        case 0x2589...0x258F:
            let eighths = CGFloat(0x2590 - scalar)
            context.fill(CGRect(x: 0, y: 0, width: w * eighths / 8, height: h))
        // Shades: approximated by alpha rather than a dither pattern, which at
        // terminal sizes reads the same and stays crisp.
        case 0x2591, 0x2592, 0x2593:
            let alpha: CGFloat = scalar == 0x2591 ? 0.25 : (scalar == 0x2592 ? 0.5 : 0.75)
            context.saveGState()
            context.setAlpha(alpha)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.restoreGState()
        default: break
        }
    }

    /// U+2500 onwards. Only the combinations that actually appear in terminal
    /// output are listed; the rest fall back to the font.
    private static let table: [UInt32: Shape] = {
        func s(_ light: Edges = [], heavy: Edges = [], double: Bool = false) -> Shape {
            Shape(light: light, heavy: heavy, isDouble: double)
        }
        return [
            0x2500: s([.left, .right]),                     // ─
            0x2501: s(heavy: [.left, .right]),              // ━
            0x2502: s([.up, .down]),                        // │
            0x2503: s(heavy: [.up, .down]),                 // ┃
            0x250C: s([.right, .down]),                     // ┌
            0x250F: s(heavy: [.right, .down]),              // ┏
            0x2510: s([.left, .down]),                      // ┐
            0x2513: s(heavy: [.left, .down]),               // ┓
            0x2514: s([.right, .up]),                       // └
            0x2517: s(heavy: [.right, .up]),                // ┗
            0x2518: s([.left, .up]),                        // ┘
            0x251B: s(heavy: [.left, .up]),                 // ┛
            0x251C: s([.up, .down, .right]),                // ├
            0x2523: s(heavy: [.up, .down, .right]),         // ┣
            0x2524: s([.up, .down, .left]),                 // ┤
            0x252B: s(heavy: [.up, .down, .left]),          // ┫
            0x252C: s([.left, .right, .down]),              // ┬
            0x2533: s(heavy: [.left, .right, .down]),       // ┳
            0x2534: s([.left, .right, .up]),                // ┴
            0x253B: s(heavy: [.left, .right, .up]),         // ┻
            0x253C: s([.left, .right, .up, .down]),         // ┼
            0x254B: s(heavy: [.left, .right, .up, .down]),  // ╋
            0x2550: s([.left, .right], double: true),       // ═
            0x2551: s([.up, .down], double: true),          // ║
            0x2554: s([.right, .down], double: true),       // ╔
            0x2557: s([.left, .down], double: true),        // ╗
            0x255A: s([.right, .up], double: true),         // ╚
            0x255D: s([.left, .up], double: true),          // ╝
            0x2560: s([.up, .down, .right], double: true),  // ╠
            0x2563: s([.up, .down, .left], double: true),   // ╣
            0x2566: s([.left, .right, .down], double: true),// ╦
            0x2569: s([.left, .right, .up], double: true),  // ╩
            0x256C: s([.left, .right, .up, .down], double: true), // ╬
        ]
    }()
}
