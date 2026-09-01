// Draws Termther's app icon and writes Resources/AppIcon.icns.
//
// In the repo rather than as a committed binary someone has to remember how to
// remake: the icon is a hundred lines of geometry, and geometry belongs in a
// file you can edit.
//
//     swift Scripts/make-icon.swift
import AppKit

// MARK: - the shape

/// Apple's icon outline is a superellipse, not a rounded rectangle.
///
/// The difference is small and unmistakable: a circular corner meets the
/// straight edge at a visible seam, and next to every other icon in the Dock
/// that seam is what makes a custom icon look homemade.
func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720

    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        // |x/a|^n + |y/b|^n = 1, parameterised so the corners stay full.
        let x = a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        let point = CGPoint(x: centre.x + x, y: centre.y + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - the drawing

/// The case: brushed metal, lit from above.
///
/// Four stops rather than two. A straight two-colour ramp reads as a flat
/// tint; metal needs a bright top, a quick fall through the middle and a lift
/// at the very bottom, which is the light the surface catches from below.
/// Bright silver. It can afford to be, now that the screen behind it is dark:
/// the silhouette is held by the edge between the two, not by the case being
/// darker than whatever it sits on.
let caseMetal: [CGColor] = [
    CGColor(red: 0.973, green: 0.976, blue: 0.984, alpha: 1),
    CGColor(red: 0.839, green: 0.855, blue: 0.882, alpha: 1),
    CGColor(red: 0.588, green: 0.616, blue: 0.663, alpha: 1),
    CGColor(red: 0.769, green: 0.788, blue: 0.824, alpha: 1),
]
let caseStops: [CGFloat] = [0, 0.42, 0.88, 1]
/// The screen behind everything.
let screen: [CGColor] = [
    CGColor(red: 0.102, green: 0.337, blue: 0.369, alpha: 1),
    CGColor(red: 0.067, green: 0.243, blue: 0.278, alpha: 1),
    CGColor(red: 0.039, green: 0.165, blue: 0.196, alpha: 1),
]
let screenStops: [CGFloat] = [0, 0.55, 1]

/// Pac-Man is only Pac-Man in yellow. Any other colour and it is a circle
/// with a bite out of it -- so it deepens towards amber rather than away from
/// yellow, which is as far as it can go and still be the right shape.
let pac = CGColor(red: 0.961, green: 0.651, blue: 0.137, alpha: 1)
/// Light, and not white: three levels of brightness on the screen -- ground,
/// amber, glyph -- is what keeps all three legible at 32 points.
let accent = CGColor(red: 0.839, green: 0.961, blue: 0.941, alpha: 1)

/// A disc with a wedge missing, mouth open to the right.
func pacman(centre: CGPoint, radius: CGFloat, mouth: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: centre)
    // The long way round. Sweeping clockwise from +mouth/2 to -mouth/2 takes
    // the short arc and fills the wedge -- which draws the mouth instead of
    // the thing the mouth is a hole in.
    path.addArc(center: centre, radius: radius,
                startAngle: mouth / 2, endAngle: -mouth / 2, clockwise: false)
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage? {
    let scale = CGFloat(size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // A margin, but a small one. Apple's grid leaves room for a shadow rather
    // than for empty space, and at 0.085 the case sat inside a ring of nothing
    // that read, in a row of icons that fill their tiles, as a smaller app.
    let inset = scale * 0.018
    let body = CGRect(x: inset, y: inset, width: scale - inset * 2, height: scale - inset * 2)
    let unit = body.width

    context.saveGState()
    context.addPath(squircle(in: body))
    context.clip()
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: caseMetal as CFArray, locations: caseStops)!,
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    context.restoreGState()

    // The screen: a window inside the case, which is what makes this read as a
    // terminal rather than as a symbol on a tile.
    // The screen is the same shape as the case, inset.
    //
    // A rounded rectangle inside a superellipse leaves a bezel that is thin
    // along the edges and fat at the corners -- the two outlines simply are
    // not parallel. Insetting the same curve keeps the frame one width the
    // whole way round, which is the only way it reads as a frame.
    let pad = unit * 0.056
    let window = body.insetBy(dx: pad, dy: pad)
    context.saveGState()
    context.addPath(squircle(in: window))
    context.clip()
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: screen as CFArray, locations: screenStops)!,
        start: CGPoint(x: 0, y: window.maxY), end: CGPoint(x: 0, y: window.minY), options: [])
    context.restoreGState()

    // A dot grid on the screen, the way a terminal's own background can carry
    // one.
    //
    // Drawn as a lift rather than as a colour: the screen is a gradient, so a
    // fixed tone would sit close to the ground at one end and stand off it at
    // the other. A low-alpha white keeps the same distance from whatever is
    // underneath it.
    //
    // Only above 64 points. Below that the spacing falls under a pixel and the
    // grid stops being a texture and becomes a haze over the whole screen --
    // which reads as a rendering fault, not as a watermark.
    if size >= 64 {
        context.saveGState()
        context.addPath(squircle(in: window))
        context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 0.10))

        let spacing = unit * 0.042
        let dot = spacing * 0.145
        var y = window.minY + spacing / 2
        while y < window.maxY {
            var x = window.minX + spacing / 2
            while x < window.maxX {
                context.addEllipse(in: CGRect(x: x - dot, y: y - dot,
                                              width: dot * 2, height: dot * 2))
                x += spacing
            }
            y += spacing
        }
        context.fillPath()
        context.restoreGState()
    }

    // Big enough to own the corner it sits in: at 32 points a disc is one
    // shape, and the notch that says which shape has to be part of the
    // outline rather than a detail inside it.
    // Clear of the frame by more than its own width: a shape touching the
    // bezel reads as a sticker put on top rather than something on the screen.
    let softness = unit * 0.030
    let radius = unit * 0.175 - softness / 2
    let mouth = CGPoint(x: window.minX + unit * 0.275, y: window.maxY - unit * 0.275)

    // Filled and stroked with the same colour, round joins.
    //
    // A wedge cut from a disc has three sharp points -- the apex at the centre
    // and the two corners where the cut meets the rim -- and sharp points are
    // what make it read as a slice missing rather than as a mouth. Stroking
    // the outline rounds all three at once, which is why the radius is dialled
    // back by half the stroke: the shape grows by that much.
    context.setFillColor(pac)
    context.setStrokeColor(pac)
    context.setLineWidth(softness)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.addPath(pacman(centre: mouth, radius: radius, mouth: .pi / 2.1))
    context.drawPath(using: .fillStroke)

    // The thing it is eating. Set in type rather than drawn: a dollar sign is
    // an S through a bar, and an S built out of arcs by hand never looks like
    // one anybody types.
    // Smaller than the disc eating it. They are not two marks side by side:
    // one is the mouth and one is the mouthful.
    let glyphSize = unit * 0.30
    let font = CTFontCreateWithName(("Menlo-Bold" as CFString), glyphSize, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "$",
        attributes: [.font: font, .foregroundColor: NSColor(cgColor: accent)!]) as CFAttributedString)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    context.saveGState()
    context.textPosition = CGPoint(
        x: mouth.x + radius * 1.35 - bounds.minX,
        y: mouth.y - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, context)
    context.restoreGState()

    return context.makeImage()
}

// MARK: - writing it out

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let image = drawIcon(size: pixels) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: base, height: base)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
        try data.write(to: iconset.appending(path: name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appending(path: "Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
