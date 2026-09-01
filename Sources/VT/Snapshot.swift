import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Renders a terminal to an image file, with no window involved.
///
/// Useful twice over: it is how the renderer gets looked at during development
/// on a machine that cannot screenshot, and it is the basis for visual
/// regression tests -- render a known byte stream, compare the pixels.
public enum Snapshot {
    public enum Failure: Error, CustomStringConvertible {
        case texture
        case encode
        public var description: String {
            switch self {
            case .texture: "cannot create the offscreen texture"
            case .encode: "cannot encode the image"
            }
        }
    }

    /// Writes an already-rendered frame, for callers that drove the terminal
    /// themselves.
    public static func write(frame: Frame, renderer: CellRenderer, to url: URL) throws {
        let cell = renderer.cellSizeInPixels
        try write(texture: renderer.render(
            width: Int(cell.width) * Int(frame.cols),
            height: Int(cell.height) * Int(frame.rows)), to: url)
    }

    /// Feeds `input` to a fresh terminal and writes what it looks like.
    public static func write(input: [UInt8],
                             to url: URL,
                             cols: UInt16 = 80, rows: UInt16 = 24,
                             fonts: FontStack = FontStack(),
                             scale: CGFloat = 2) async throws {
        let terminal = try Terminal(cols: cols, rows: rows)
        await terminal.write(input)

        let renderer = try CellRenderer(fonts: fonts, scale: scale)
        guard let frame = await terminal.nextFrame() else { throw Failure.encode }
        try renderer.apply(frame)

        let cell = renderer.cellSizeInPixels
        let width = Int(cell.width) * Int(cols)
        let height = Int(cell.height) * Int(rows)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            throw Failure.texture
        }
        renderer.draw(into: texture)
        try write(texture: texture, to: url)
    }

    private static func write(texture: MTLTexture, to url: URL) throws {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // Metal gives BGRA; CoreGraphics is told so rather than shuffling bytes.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encode }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encode }
    }
}
