import Foundation
import Metal
import simd

/// Draws terminal frames with Metal.
///
/// Three instanced passes per frame, in an order that matters: solid rects
/// (cell backgrounds, underlines, the cursor's fill), then glyphs, then the
/// overlays that must sit on top of text (strikethrough, a hollow or bar
/// cursor). Nothing is drawn per glyph on the CPU -- the atlas already holds
/// the shapes -- so a full screen is three draw calls regardless of content.
///
/// The renderer keeps the whole grid, not just the dirty rows, because a GPU
/// redraw of two thousand cells is cheaper than tracking partial damage. What
/// the dirty rows save is the expensive part: pulling cells across the C
/// boundary and rasterising glyphs.
public final class CellRenderer {
    /// Must match `SolidVertexIn` in shaders.metal.
    struct SolidInstance {
        var originX: Float, originY: Float
        var width: Float, height: Float
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    /// Must match `TextVertexIn` in shaders.metal.
    struct TextInstance {
        var glyphX: UInt32, glyphY: UInt32
        var glyphWidth: UInt32, glyphHeight: UInt32
        var offsetX: Int32, offsetY: Int32
        var gridX: UInt16, gridY: UInt16
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var cellWidth: UInt16, cellHeight: UInt16, atlas: UInt16, padding: UInt16
    }

    struct Uniforms {
        var screenSize: SIMD2<Float>
        var atlasSize: SIMD2<Float>
        var colorAtlasSize: SIMD2<Float>
    }

    public enum Failure: Error, CustomStringConvertible {
        case noDevice
        case shaderSource
        case shaderCompilation(String)
        case pipeline(String)

        public var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case .shaderSource: "shaders.metal is missing from the bundle"
            case .shaderCompilation(let m): "shader compilation failed: \(m)"
            case .pipeline(let m): "pipeline creation failed: \(m)"
            }
        }
    }

    public let device: MTLDevice
    public let fonts: FontStack
    /// Points-to-pixels; 2 on a Retina display.
    public let scale: CGFloat

    private let queue: MTLCommandQueue

    /// Instance data goes through a buffer, never `setVertexBytes`.
    ///
    /// That call has a hard 4 KB limit and aborts inside the Metal driver when
    /// it is passed more -- not an error, an `abort()`. A screenful of text is
    /// thousands of instances and tens of kilobytes, so the only reason this
    /// ever worked is that most screens are mostly empty. It crashed the first
    /// time somebody filled one.
    private var instances: MTLBuffer?
    private let solidPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas

    /// Eased cursor position. Configurable because a terminal that is being
    /// scripted or screenshotted wants it off.
    public var cursorMotion = CursorMotion()

    /// True while the cursor is still sliding, so the host keeps drawing even
    /// though the terminal produced no new frame.
    public var isAnimating: Bool { cursorMotion.isAnimating }

    private var underlays: [SolidInstance] = []
    private var glyphs: [TextInstance] = []
    private var overlays: [SolidInstance] = []

    /// The last full grid, so a partial frame can be composited onto it.
    private var grid: [[Cell]] = []
    private var cursor: Cursor?
    private var defaultForeground = Color(red: 255, green: 255, blue: 255)
    private var defaultBackground = Color(red: 0, green: 0, blue: 0)

    public var cellSizeInPixels: CGSize { fonts.metrics.pixelSize(scale: scale) }

    public init(device: MTLDevice? = nil,
                fonts: FontStack = FontStack(),
                scale: CGFloat = 2) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        self.device = device
        self.fonts = fonts
        self.scale = scale

        guard let queue = device.makeCommandQueue() else { throw Failure.noDevice }
        self.queue = queue

        // Compiled at startup rather than shipped as a metallib: SwiftPM copies
        // .metal files without compiling them, and runtime compilation costs a
        // few tens of milliseconds once. An Xcode app target can precompile.
        guard let source = ShaderSource.metal() else { throw Failure.shaderSource }

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: nil) }
        catch { throw Failure.shaderCompilation(String(describing: error)) }

        solidPipeline = try Self.makePipeline(
            device: device, library: library,
            vertex: "solid_vertex", fragment: "solid_fragment",
            descriptor: Self.solidVertexDescriptor(), blending: true)
        textPipeline = try Self.makePipeline(
            device: device, library: library,
            vertex: "cell_text_vertex", fragment: "cell_text_fragment",
            descriptor: Self.textVertexDescriptor(), blending: true)

        atlas = try GlyphAtlas(device: device, fonts: fonts, scale: scale)
    }

    // MARK: - frames in

    /// Folds a frame into the renderer's grid.
    ///
    /// Frames carry only dirty rows, so they are composited rather than
    /// replacing what came before; a full redraw resets the grid first.
    public func apply(_ frame: Frame) throws {
        if frame.isFullRedraw || grid.count != Int(frame.rows) {
            grid = Array(repeating: [], count: Int(frame.rows))
        }
        for row in frame.dirtyRows where Int(row.y) < grid.count {
            grid[Int(row.y)] = row.cells
        }
        cursor = frame.cursor
        defaultForeground = frame.defaultForeground
        defaultBackground = frame.defaultBackground

        try rebuildInstances()
    }

    private func rebuildInstances() throws {
        underlays.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        overlays.removeAll(keepingCapacity: true)

        let cell = cellSizeInPixels
        let cellWidth = Float(cell.width), cellHeight = Float(cell.height)
        let thickness = Float(max(1, (fonts.metrics.underlineThickness * scale).rounded()))
        // Measured down from the top of the cell, from the font's own metric.
        let underlineY = Float((fonts.metrics.baseline - fonts.metrics.underlinePosition) * scale)
            .rounded()

        for (y, cells) in grid.enumerated() {
            for (x, cell) in cells.enumerated() {
                let originX = Float(x) * cellWidth
                let originY = Float(y) * cellHeight
                let onCursor = cursor.map { Int($0.x) == x && Int($0.y) == y && $0.isVisible } ?? false

                // Inverse swaps the two, which is how selections and `\e[7m`
                // are drawn without a second code path. A block cursor inverts
                // again, so a cursor sitting on selected text stays legible.
                var inverse = cell.attributes.contains(.inverse) != cell.isSelected
                if onCursor, cursor?.shape == .block { inverse.toggle() }

                var foreground = cell.foreground ?? defaultForeground
                var background = cell.background ?? defaultBackground
                if inverse { swap(&foreground, &background) }

                // Only cells that differ from the default need a background
                // quad; on a typical screen that is a small minority.
                if background != defaultBackground {
                    underlays.append(SolidInstance(
                        originX: originX, originY: originY,
                        width: cellWidth, height: cellHeight,
                        r: background.red, g: background.green, b: background.blue, a: 255))
                }

                if cell.attributes.contains(.underline) {
                    underlays.append(SolidInstance(
                        originX: originX, originY: originY + underlineY,
                        width: cellWidth, height: thickness,
                        r: foreground.red, g: foreground.green, b: foreground.blue, a: 255))
                }
                if cell.attributes.contains(.strikethrough) {
                    // Over the text, or it would be hidden by the glyph.
                    overlays.append(SolidInstance(
                        originX: originX,
                        originY: originY + (cellHeight * 0.55).rounded(),
                        width: cellWidth, height: thickness,
                        r: foreground.red, g: foreground.green, b: foreground.blue, a: 255))
                }

                guard !cell.attributes.contains(.invisible),
                      let placement = try atlas.placement(for: cell.text,
                                                          attributes: cell.attributes)
                else { continue }

                // Faint is a rendering hint, not a colour the terminal reports,
                // so it is applied here rather than in the emulator.
                let alpha: UInt8 = cell.attributes.contains(.faint) ? 150 : 255
                glyphs.append(TextInstance(
                    glyphX: placement.x, glyphY: placement.y,
                    glyphWidth: placement.width, glyphHeight: placement.height,
                    offsetX: placement.offsetX, offsetY: placement.offsetY,
                    gridX: UInt16(x), gridY: UInt16(y),
                    r: foreground.red, g: foreground.green, b: foreground.blue, a: alpha,
                    cellWidth: UInt16(clamping: cellWidth), cellHeight: UInt16(clamping: cellHeight),
                    atlas: placement.isColor ? 1 : 0, padding: 0))
            }
        }

        if let cursor, cursor.isVisible {
            cursorMotion.move(to: SIMD2(Double(cursor.x), Double(cursor.y)))
        }
        atlas.flush()
    }

    /// The cursor, drawn in whichever shape the terminal asked for.
    ///
    /// Built at draw time rather than when a frame arrives, because it moves
    /// between frames: the ease has to be sampled per redraw, not per update.
    ///
    /// A block is filled under the text and the cell's glyph is inverted over
    /// it (handled when instances are built), so the character under the cursor
    /// stays readable. The thin shapes go over the text instead, where they
    /// read as an insertion point rather than a highlight.
    private func cursorRects() -> (under: [SolidInstance], over: [SolidInstance]) {
        var under: [SolidInstance] = [], over: [SolidInstance] = []
        guard let cursor, cursor.isVisible else { return (under, over) }

        let cell = cellSizeInPixels
        let cellWidth = Float(cell.width), cellHeight = Float(cell.height)
        let thickness = Float(max(1, (fonts.metrics.underlineThickness * scale).rounded()))

        cursorMotion.tick()
        let x = Float(cursorMotion.visual.x) * cellWidth
        let y = Float(cursorMotion.visual.y) * cellHeight
        let colour = defaultForeground
        func rect(_ ox: Float, _ oy: Float, _ w: Float, _ h: Float) -> SolidInstance {
            SolidInstance(originX: x + ox, originY: y + oy, width: w, height: h,
                          r: colour.red, g: colour.green, b: colour.blue, a: 255)
        }

        switch cursor.shape {
        case .block:
            under.append(rect(0, 0, cellWidth, cellHeight))
        case .bar:
            // Thin and full height, the way a text caret looks everywhere
            // else. Anything thicker starts reading as a highlight.
            over.append(rect(0, 0, max(2, Float((2 * scale).rounded())), cellHeight))
        case .underline:
            over.append(rect(0, cellHeight - thickness * 2, cellWidth, thickness * 2))
        case .hollowBlock:
            // Four edges: an unfocused terminal, which should be visible but
            // must not obscure the character.
            over.append(rect(0, 0, cellWidth, thickness))
            over.append(rect(0, cellHeight - thickness, cellWidth, thickness))
            over.append(rect(0, 0, thickness, cellHeight))
            over.append(rect(cellWidth - thickness, 0, thickness, cellHeight))
        }
        return (under, over)
    }

    // MARK: - pixels out

    public func draw(into target: MTLTexture) {
        guard let buffer = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defaultBackground.red) / 255,
            green: Double(defaultBackground.green) / 255,
            blue: Double(defaultBackground.blue) / 255,
            alpha: 1)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = Uniforms(
            screenSize: SIMD2(Float(target.width), Float(target.height)),
            atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
            colorAtlasSize: SIMD2(Float(atlas.colorSize), Float(atlas.colorSize)))

        // Three passes, one buffer, three regions.
        //
        // Not one region reused: the encoder only records that a draw reads
        // this buffer, and the GPU reads it once the whole command buffer
        // runs. Overwriting it between passes leaves every pass drawing the
        // last one's data -- which showed up as nothing being drawn at all.
        let cursor = cursorRects()
        let first = underlays + cursor.under
        let last = overlays + cursor.over

        let stride = MemoryLayout<SolidInstance>.stride
        let textStride = MemoryLayout<TextInstance>.stride
        func aligned(_ value: Int) -> Int { (value + 255) & ~255 }

        let firstAt = 0
        let glyphsAt = aligned(firstAt + stride * first.count)
        let lastAt = aligned(glyphsAt + textStride * glyphs.count)
        let total = aligned(lastAt + stride * last.count)

        // Grown, never shrunk: a terminal settles on a size within a frame or
        // two, and reallocating every frame costs more than the memory does.
        if total > 0, instances == nil || instances!.length < total {
            instances = device.makeBuffer(length: max(total, 256 * 1024),
                                          options: .storageModeShared)
        }
        guard total == 0 || instances != nil else { encoder.endEncoding(); return }

        func copy<T>(_ values: [T], to offset: Int) {
            guard !values.isEmpty, let buffer = instances else { return }
            values.withUnsafeBytes { source in
                buffer.contents().advanced(by: offset)
                    .copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        copy(first, to: firstAt)
        copy(glyphs, to: glyphsAt)
        copy(last, to: lastAt)

        func drawSolids(_ solids: [SolidInstance], at offset: Int) {
            guard !solids.isEmpty, let buffer = instances else { return }
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setVertexBuffer(buffer, offset: offset, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: solids.count)
        }

        drawSolids(first, at: firstAt)

        if !glyphs.isEmpty, let buffer = instances {
            encoder.setRenderPipelineState(textPipeline)
            encoder.setVertexBuffer(buffer, offset: glyphsAt, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentTexture(atlas.colorTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: glyphs.count)
        }

        drawSolids(last, at: lastAt)

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Draws into a fresh offscreen texture, for snapshots and tests.
    public func render(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.noDevice
        }
        draw(into: texture)
        return texture
    }

    // MARK: - pipeline setup

    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                     vertex: String, fragment: String,
                                     descriptor: MTLVertexDescriptor,
                                     blending: Bool) throws -> MTLRenderPipelineState {
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: vertex)
        pipeline.fragmentFunction = library.makeFunction(name: fragment)
        pipeline.vertexDescriptor = descriptor

        let attachment = pipeline.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        if blending {
            // Sources are premultiplied, so glyphs and overlays composite over
            // whatever the previous pass drew.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        do { return try device.makeRenderPipelineState(descriptor: pipeline) }
        catch { throw Failure.pipeline(String(describing: error)) }
    }

    private static func solidVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let attributes: [(MTLVertexFormat, Int)] = [
            (.float2, MemoryLayout.offset(of: \SolidInstance.originX)!),
            (.float2, MemoryLayout.offset(of: \SolidInstance.width)!),
            (.uchar4, MemoryLayout.offset(of: \SolidInstance.r)!),
        ]
        for (index, (format, offset)) in attributes.enumerated() {
            descriptor.attributes[index].format = format
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = MemoryLayout<SolidInstance>.stride
        descriptor.layouts[0].stepFunction = .perInstance
        return descriptor
    }

    private static func textVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let attributes: [(MTLVertexFormat, Int)] = [
            (.uint2, MemoryLayout.offset(of: \TextInstance.glyphX)!),
            (.uint2, MemoryLayout.offset(of: \TextInstance.glyphWidth)!),
            (.int2, MemoryLayout.offset(of: \TextInstance.offsetX)!),
            (.ushort2, MemoryLayout.offset(of: \TextInstance.gridX)!),
            (.uchar4, MemoryLayout.offset(of: \TextInstance.r)!),
            (.ushort4, MemoryLayout.offset(of: \TextInstance.cellWidth)!),
        ]
        for (index, (format, offset)) in attributes.enumerated() {
            descriptor.attributes[index].format = format
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = MemoryLayout<TextInstance>.stride
        descriptor.layouts[0].stepFunction = .perInstance
        return descriptor
    }
}

private extension UInt16 {
    /// Clamped, because a very large window must not trap on overflow.
    init(clamping value: Float) {
        self = UInt16(Swift.max(0, Swift.min(Float(UInt16.max), value)))
    }
}
