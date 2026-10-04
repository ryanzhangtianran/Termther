import Foundation
import GhosttyVt
import Metal
import QuartzCore
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
/// boundary, rasterising glyphs, and building each row's instances, which
/// are kept per row and rebuilt only for a row that changed.
public final class CellRenderer {
    /// Must match `SolidVertexIn` in Shaders.swift.
    struct SolidInstance {
        var originX: Float, originY: Float
        var width: Float, height: Float
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    /// Must match `TextVertexIn` in Shaders.swift.
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
        case shaderCompilation(String)
        case pipeline(String)

        public var description: String {
            switch self {
            case .noDevice: "no Metal device"
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
    /// One frame on the GPU at a time: the next rewrites the instance buffer
    /// and the atlas textures, which must not happen while it reads them.
    private let inFlight = DispatchSemaphore(value: 1)

    /// Eased cursor position. Configurable because a terminal that is being
    /// scripted or screenshotted wants it off.
    public var cursorMotion = CursorMotion()

    /// True while the cursor is still sliding, so the host keeps drawing even
    /// though the terminal produced no new frame.
    public var isAnimating: Bool { cursorMotion.isAnimating }

    private(set) var underlays: [SolidInstance] = []
    private(set) var glyphs: [TextInstance] = []
    private(set) var overlays: [SolidInstance] = []

    /// One grid row's instances, kept until the row or what is drawn over
    /// it changes.
    private struct RowInstances {
        var underlays: [SolidInstance] = []
        var glyphs: [TextInstance] = []
        var overlays: [SolidInstance] = []
        /// What shaped them besides the row's cells; nil until built.
        var context: RowContext?
    }

    /// The rest of what a row's instances depend on: a block cursor on it
    /// inverts a cell, and a composition hides the cells it covers. The cell
    /// size and the defaults are the same for every row, and a change to
    /// either rebuilds them all.
    private struct RowContext: Equatable {
        var blockCursor: Int?
        var composing: Range<Int>?
    }

    private var rows: [RowInstances] = []
    /// The last rebuild could not fit everything in the atlas: some rows lack
    /// glyphs, so the next one starts from scratch, as it would have to.
    private var overflowed = false

    /// The last full grid, so a partial frame can be composited onto it.
    private var grid: [[Cell]] = []
    private var cols = 0
    private var cursor: Cursor?
    private var cursorColor: Color?
    private var defaultForeground = Color(red: 255, green: 255, blue: 255)
    private var defaultBackground = Color(red: 0, green: 0, blue: 0)

    /// What an input method is composing, drawn over the grid at the cursor
    /// until it is committed. Nil, or empty, when nothing is.
    public var preedit: String? {
        didSet { if preedit != oldValue { rebuildInstances() } }
    }

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

        (solidPipeline, textPipeline) = try Self.pipelines(for: device)

        atlas = try GlyphAtlas(device: device, fonts: fonts, scale: scale)
    }

    // MARK: - frames in

    /// Folds a frame into the renderer's grid.
    ///
    /// Frames carry only dirty rows, so they are composited rather than
    /// replacing what came before; a full redraw resets the grid first.
    public func apply(_ frame: Frame) {
        cols = Int(frame.cols)
        if frame.isFullRedraw || grid.count != Int(frame.rows) {
            grid = Array(repeating: [], count: Int(frame.rows))
            rows = Array(repeating: RowInstances(), count: Int(frame.rows))
        }
        for row in frame.dirtyRows where Int(row.y) < grid.count {
            grid[Int(row.y)] = row.cells
            rows[Int(row.y)].context = nil
        }
        if frame.defaultForeground != defaultForeground || frame.defaultBackground != defaultBackground {
            invalidateRows()
        }
        cursor = frame.cursor
        cursorColor = frame.cursorColor
        defaultForeground = frame.defaultForeground
        defaultBackground = frame.defaultBackground

        rebuildInstances()
    }

    /// Every row is built again at the next rebuild.
    private func invalidateRows() {
        for index in rows.indices { rows[index].context = nil }
    }

    /// Builds every row afresh, for a test to compare with what was kept.
    func rebuildEveryRow() {
        invalidateRows()
        rebuildInstances()
    }

    /// Rebuilds the instances of every row that changed.
    ///
    /// Never gives up part-way: a cell whose glyph cannot be had is left
    /// without one, and the rest of the screen is still drawn. When the atlas
    /// fills it is emptied and the screen built again, which re-rasterises
    /// only what is on it now; a screen that alone needs more than the atlas
    /// holds draws what fits.
    private func rebuildInstances() {
        // The atlas is written as glyphs are rasterised.
        waitForGPU()
        if overflowed { invalidateRows() }
        overflowed = false
        if !buildInstances() {
            atlas.reset()
            invalidateRows()
            overflowed = !buildInstances()
        }
        if let cursor, cursor.isVisible {
            cursorMotion.move(to: SIMD2(Double(cursor.x), Double(cursor.y)))
        }
    }

    /// False when a glyph did not fit in the atlas.
    private func buildInstances() -> Bool {
        var fits = true

        let cell = cellSizeInPixels
        let cellWidth = Float(cell.width), cellHeight = Float(cell.height)
        let thickness = lineThickness
        // Measured down from the top of the cell, from the font's own metric.
        let underlineY = Float((fonts.metrics.baseline - fonts.metrics.underlinePosition) * scale)
            .rounded()

        // The composition covers the cells from the cursor on, one or two to
        // a cluster as the terminal would lay them out once committed.
        var composing: [(x: Int, width: Int, text: String)] = []
        let composingRow = cursor.map { Int($0.y) } ?? -1
        if let preedit, !preedit.isEmpty, let cursor {
            var x = Int(cursor.x)
            for cluster in Self.clusters(preedit) where x < cols {
                composing.append((x, cluster.width, cluster.text))
                x += max(cluster.width, 1)
            }
        }
        let composingEnd = composing.last.map { $0.x + max($0.width, 1) } ?? 0
        let composingSpan = composing.first.map { $0.x..<composingEnd }

        func glyph(_ text: String, _ attributes: Cell.Attributes) -> GlyphPlacement? {
            do { return try atlas.placement(for: text, attributes: attributes) }
            catch GlyphAtlas.Failure.full { fits = false; return nil }
            catch { return nil }
        }

        func text(_ placement: GlyphPlacement, x: Int, y: UInt16, _ color: Color, alpha: UInt8) -> TextInstance {
            TextInstance(
                glyphX: placement.x, glyphY: placement.y,
                glyphWidth: placement.width, glyphHeight: placement.height,
                offsetX: placement.offsetX, offsetY: placement.offsetY,
                gridX: UInt16(x), gridY: y,
                r: color.red, g: color.green, b: color.blue, a: alpha,
                cellWidth: UInt16(clamping: cellWidth), cellHeight: UInt16(clamping: cellHeight),
                atlas: placement.isColor ? 1 : 0, padding: 0)
        }

        for (y, cells) in grid.enumerated() {
            let blockCursor = cursor.flatMap { $0.isVisible && $0.shape == .block && Int($0.y) == y ? Int($0.x) : nil }
            let context = RowContext(blockCursor: blockCursor, composing: y == composingRow ? composingSpan : nil)
            guard rows[y].context != context else { continue }

            // Taken out of the array, so its buffers are refilled in place.
            var row = RowInstances()
            swap(&row, &rows[y])
            row.underlays.removeAll(keepingCapacity: true)
            row.glyphs.removeAll(keepingCapacity: true)
            row.overlays.removeAll(keepingCapacity: true)
            row.context = context

            for (x, cell) in cells.enumerated() {
                if let span = context.composing, span.contains(x) { continue }
                let originX = Float(x) * cellWidth
                let originY = Float(y) * cellHeight

                // Inverse swaps the two, which is how selections and `\e[7m`
                // are drawn without a second code path. A block cursor inverts
                // again, so a cursor sitting on selected text stays legible.
                var inverse = cell.attributes.contains(.inverse) != cell.isSelected
                if context.blockCursor == x { inverse.toggle() }

                var foreground = cell.foreground ?? defaultForeground
                var background = cell.background ?? defaultBackground
                if inverse { swap(&foreground, &background) }
                // The other matches of a search: a tint of the text colour,
                // short of the inverse the selected one gets.
                if cell.isMatch, !inverse { background = background.mixed(with: foreground, 0.3) }

                // Only cells that differ from the default need a background
                // quad; on a typical screen that is a small minority.
                if background != defaultBackground {
                    row.underlays.append(SolidInstance(
                        originX: originX, originY: originY,
                        width: cellWidth, height: cellHeight,
                        r: background.red, g: background.green, b: background.blue, a: 255))
                }

                if cell.attributes.contains(.underline) {
                    row.underlays.append(SolidInstance(
                        originX: originX, originY: originY + underlineY,
                        width: cellWidth, height: thickness,
                        r: foreground.red, g: foreground.green, b: foreground.blue, a: 255))
                }
                if cell.attributes.contains(.strikethrough) {
                    // Over the text, or it would be hidden by the glyph.
                    row.overlays.append(SolidInstance(
                        originX: originX,
                        originY: originY + (cellHeight * 0.55).rounded(),
                        width: cellWidth, height: thickness,
                        r: foreground.red, g: foreground.green, b: foreground.blue, a: 255))
                }

                guard !cell.attributes.contains(.invisible),
                      let placement = glyph(cell.text, cell.attributes)
                else { continue }

                // Faint is a rendering hint, not a colour the terminal reports,
                // so it is applied here rather than in the emulator.
                let alpha: UInt8 = cell.attributes.contains(.faint) ? 150 : 255
                row.glyphs.append(text(placement, x: x, y: UInt16(y), foreground, alpha: alpha))
            }
            rows[y] = row
        }

        // The rows in order, which is the order a whole-screen build makes.
        underlays.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        overlays.removeAll(keepingCapacity: true)
        for row in rows {
            underlays.append(contentsOf: row.underlays)
            glyphs.append(contentsOf: row.glyphs)
            overlays.append(contentsOf: row.overlays)
        }

        // Underlined on the default colours, as a text field shows it, and
        // over whatever the grid has there.
        let composingY = Float(composingRow) * cellHeight
        for (x, width, cluster) in composing {
            let originX = Float(x) * cellWidth
            let span = cellWidth * Float(max(width, 1))
            let color = defaultForeground
            underlays.append(SolidInstance(
                originX: originX, originY: composingY, width: span, height: cellHeight,
                r: defaultBackground.red, g: defaultBackground.green, b: defaultBackground.blue,
                a: 255))
            underlays.append(SolidInstance(
                originX: originX, originY: composingY + underlineY, width: span, height: thickness,
                r: color.red, g: color.green, b: color.blue, a: 255))
            guard let placement = glyph(cluster, []) else { continue }
            glyphs.append(text(placement, x: x, y: UInt16(clamping: composingRow), color, alpha: 255))
        }
        return fits
    }

    /// Underlines, strikethrough and the thin cursor shapes.
    private var lineThickness: Float {
        Float(max(1, (fonts.metrics.underlineThickness * scale).rounded()))
    }

    /// A string's grapheme clusters and the cells each takes, by the
    /// terminal's own rules, so a composition lines up with what it becomes.
    static func clusters(_ text: String) -> [(text: String, width: Int)] {
        let scalars = Array(text.unicodeScalars)
        let codepoints = scalars.map(\.value)
        var clusters: [(text: String, width: Int)] = []
        var index = 0
        while index < codepoints.count {
            var width: UInt8 = 0
            let count = codepoints[index...].withUnsafeBufferPointer {
                ghostty_unicode_grapheme_width($0.baseAddress, $0.count, &width)
            }
            let end = min(codepoints.count, index + max(count, 1))
            var cluster = String.UnicodeScalarView()
            cluster.append(contentsOf: scalars[index..<end])
            clusters.append((String(cluster), Int(width)))
            index = end
        }
        return clusters
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
    ///
    /// Not drawn while an input method is composing: the composition sits
    /// where the cursor is and says where the text will go.
    private func cursorRects() -> (under: [SolidInstance], over: [SolidInstance]) {
        var under: [SolidInstance] = [], over: [SolidInstance] = []
        guard let cursor, cursor.isVisible, preedit?.isEmpty ?? true else { return (under, over) }

        let cell = cellSizeInPixels
        let cellWidth = Float(cell.width), cellHeight = Float(cell.height)
        let thickness = lineThickness

        cursorMotion.tick()
        let x = Float(cursorMotion.visual.x) * cellWidth
        let y = Float(cursorMotion.visual.y) * cellHeight
        let color = cursorColor ?? defaultForeground
        func rect(_ ox: Float, _ oy: Float, _ w: Float, _ h: Float) -> SolidInstance {
            SolidInstance(originX: x + ox, originY: y + oy, width: w, height: h,
                          r: color.red, g: color.green, b: color.blue, a: 255)
        }

        switch cursor.shape {
        case .block:
            under.append(rect(0, 0, cellWidth, cellHeight))
        case .bar:
            // Keep the caret inside the cell's vertical rhythm. A full-height
            // bar is visually oversized next to the terminal's glyphs.
            let height = (cellHeight * 0.72).rounded()
            over.append(rect(0, (cellHeight - height) * 0.5,
                             max(2, Float((2 * scale).rounded())), height))
        case .underline:
            over.append(rect(0, cellHeight - thickness, cellWidth, thickness))
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

    /// Draws into `target` and waits until it is drawn.
    public func draw(into target: MTLTexture) {
        encode(into: target)?.waitUntilCompleted()
    }

    /// Draws into a drawable, which the GPU puts on screen once it is drawn;
    /// nothing waits for it.
    public func draw(to drawable: CAMetalDrawable) {
        encode(into: drawable.texture, presenting: drawable)
    }

    /// Waits until no frame is being drawn.
    private func waitForGPU() {
        inFlight.wait()
        inFlight.signal()
    }

    /// Encodes and commits a frame; nil when nothing was committed.
    @discardableResult
    private func encode(into target: MTLTexture, presenting drawable: MTLDrawable? = nil) -> MTLCommandBuffer? {
        guard let buffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defaultBackground.red) / 255,
            green: Double(defaultBackground.green) / 255,
            blue: Double(defaultBackground.blue) / 255,
            alpha: 1)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

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
        //
        // The cursor's rects follow the grid's in each region, copied there
        // rather than joined into a new array every frame.
        let cursor = cursorRects()
        let firstCount = underlays.count + cursor.under.count
        let lastCount = overlays.count + cursor.over.count

        let stride = MemoryLayout<SolidInstance>.stride
        let textStride = MemoryLayout<TextInstance>.stride
        func aligned(_ value: Int) -> Int { (value + 255) & ~255 }

        let firstAt = 0
        let glyphsAt = aligned(firstAt + stride * firstCount)
        let lastAt = aligned(glyphsAt + textStride * glyphs.count)
        let total = aligned(lastAt + stride * lastCount)

        // Grown, never shrunk: a terminal settles on a size within a frame or
        // two, and reallocating every frame costs more than the memory does.
        if total > 0, instances == nil || instances!.length < total {
            instances = device.makeBuffer(length: max(total, 256 * 1024),
                                          options: .storageModeShared)
        }
        guard total == 0 || instances != nil else { encoder.endEncoding(); return nil }

        // The previous frame may still be reading the buffer.
        inFlight.wait()
        buffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        func copy<T>(_ values: [T], to offset: Int) {
            guard !values.isEmpty, let buffer = instances else { return }
            values.withUnsafeBytes { source in
                buffer.contents().advanced(by: offset)
                    .copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        copy(underlays, to: firstAt)
        copy(cursor.under, to: firstAt + stride * underlays.count)
        copy(glyphs, to: glyphsAt)
        copy(overlays, to: lastAt)
        copy(cursor.over, to: lastAt + stride * overlays.count)

        func drawSolids(_ count: Int, at offset: Int) {
            guard count > 0, let buffer = instances else { return }
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setVertexBuffer(buffer, offset: offset, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
        }

        drawSolids(firstCount, at: firstAt)

        if !glyphs.isEmpty, let buffer = instances {
            encoder.setRenderPipelineState(textPipeline)
            encoder.setVertexBuffer(buffer, offset: glyphsAt, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentTexture(atlas.colorTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: glyphs.count)
        }

        drawSolids(lastCount, at: lastAt)

        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        return buffer
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

    /// Built once per device and shared: every tab, and every renderer a
    /// font or screen change replaces one with, draws with the same two.
    private nonisolated(unsafe) static var pipelinesByDevice:
        [UInt64: (solid: MTLRenderPipelineState, text: MTLRenderPipelineState)] = [:]
    private static let pipelinesLock = NSLock()

    private static func pipelines(for device: MTLDevice) throws
        -> (solid: MTLRenderPipelineState, text: MTLRenderPipelineState) {
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let built = pipelinesByDevice[device.registryID] { return built }

        // Compiled at startup rather than shipped as a metallib, which would
        // need Xcode's `metal` tool; it costs a few tens of milliseconds once.
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) }
        catch { throw Failure.shaderCompilation(String(describing: error)) }

        let built = (
            solid: try makePipeline(
                device: device, library: library,
                vertex: "solid_vertex", fragment: "solid_fragment",
                descriptor: solidVertexDescriptor()),
            text: try makePipeline(
                device: device, library: library,
                vertex: "cell_text_vertex", fragment: "cell_text_fragment",
                descriptor: textVertexDescriptor()))
        pipelinesByDevice[device.registryID] = built
        return built
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                     vertex: String, fragment: String,
                                     descriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: vertex)
        pipeline.fragmentFunction = library.makeFunction(name: fragment)
        pipeline.vertexDescriptor = descriptor

        let attachment = pipeline.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Sources are premultiplied, so glyphs and overlays composite over
        // whatever the previous pass drew.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do { return try device.makeRenderPipelineState(descriptor: pipeline) }
        catch { throw Failure.pipeline(String(describing: error)) }
    }

    private static func solidVertexDescriptor() -> MTLVertexDescriptor {
        vertexDescriptor(stride: MemoryLayout<SolidInstance>.stride, [
            (.float2, MemoryLayout.offset(of: \SolidInstance.originX)!),
            (.float2, MemoryLayout.offset(of: \SolidInstance.width)!),
            (.uchar4, MemoryLayout.offset(of: \SolidInstance.r)!),
        ])
    }

    private static func textVertexDescriptor() -> MTLVertexDescriptor {
        vertexDescriptor(stride: MemoryLayout<TextInstance>.stride, [
            (.uint2, MemoryLayout.offset(of: \TextInstance.glyphX)!),
            (.uint2, MemoryLayout.offset(of: \TextInstance.glyphWidth)!),
            (.int2, MemoryLayout.offset(of: \TextInstance.offsetX)!),
            (.ushort2, MemoryLayout.offset(of: \TextInstance.gridX)!),
            (.uchar4, MemoryLayout.offset(of: \TextInstance.r)!),
            (.ushort4, MemoryLayout.offset(of: \TextInstance.cellWidth)!),
        ])
    }

    /// One instance per draw call's worth of attributes, all in buffer 0.
    private static func vertexDescriptor(stride: Int, _ attributes: [(MTLVertexFormat, Int)]) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        for (index, (format, offset)) in attributes.enumerated() {
            descriptor.attributes[index].format = format
            descriptor.attributes[index].offset = offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = stride
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

private extension Color {
    /// This colour moved `fraction` of the way towards `other`.
    func mixed(with other: Color, _ fraction: Float) -> Color {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Float(a) + (Float(b) - Float(a)) * fraction).rounded())
        }
        return Color(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }
}
