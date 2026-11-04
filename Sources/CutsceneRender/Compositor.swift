import CoreGraphics
import CoreVideo
import CutsceneCore
import CutsceneEngine
import Foundation
import Metal
import Synchronization

/// The part of the source frame the camera shows, in normalized source
/// coordinates with a top-left origin: what `CameraTimeline.viewport(at:)` returns.
public struct CameraViewport: Sendable, Hashable {
    public var origin: NormalizedPoint
    public var size: NormalizedSize

    public init(origin: NormalizedPoint, size: NormalizedSize) {
        self.origin = origin
        self.size = size
    }

    public init(_ viewport: (origin: NormalizedPoint, size: NormalizedSize)) {
        self.init(origin: viewport.origin, size: viewport.size)
    }

    /// The whole frame.
    public static let full = CameraViewport(
        origin: NormalizedPoint(x: 0, y: 0), size: NormalizedSize(width: 1, height: 1))
}

/// The camera picture for one frame and where the layout put the bubble.
public struct CameraBubbleFrame {
    /// A frame of the camera track, in the same formats and with the same
    /// colour rule as `SourceFrame.pixelBuffer`; aspect-filled into the bubble.
    public var pixelBuffer: CVPixelBuffer
    /// The bubble's bounds, outline, radius and border, in output pixels.
    public var placement: BubblePlacement
    /// Flipped left to right, so a built-in camera reads like a mirror.
    public var isMirrored: Bool

    public init(pixelBuffer: CVPixelBuffer, placement: BubblePlacement, isMirrored: Bool = false) {
        self.pixelBuffer = pixelBuffer
        self.placement = placement
        self.isMirrored = isMirrored
    }
}

/// Everything that changes from one frame to the next.
public struct SourceFrame {
    /// BGRA with premultiplied alpha (what CoreGraphics and ScreenCaptureKit
    /// produce), 420v or 420f. Must be IOSurface-backed, as capture and
    /// decode buffers are, so Metal can read it in place. Transparent BGRA
    /// texels (a window capture's rounded corners and shadow margin, the
    /// clear background of a window-bound display filter) show the
    /// background through the card rather than turning black.
    ///
    /// Colour: the samples are taken as sRGB / BT.709 and the output is
    /// tagged BT.709, so a buffer tagged for another space (Display P3 from
    /// an unpinned `SCStreamConfiguration.colorSpaceName`, BT.601, HDR) makes
    /// `render` throw `RenderError.unsupportedColorSpace` instead of coming
    /// out desaturated; an untagged buffer is taken as sRGB.
    public var pixelBuffer: CVPixelBuffer
    /// Which part of the content fills the card.
    public var viewport: CameraViewport
    /// Which part of the captured frame is the content, in frame coordinates:
    /// the window's bounding rect in window mode, the whole frame otherwise.
    /// A screen pixel is read at `crop.origin + (viewport.origin + p ×
    /// viewport.size) × crop.size` (ARCHITECTURE §5), and the cursor and the
    /// ripples, whose positions are frame coordinates too, go through the
    /// same mapping.
    public var contentCrop: CameraViewport
    /// The smoothed cursor for this frame; nil draws none.
    public var cursor: CursorSample?
    public var cursorSprite: CursorSprite
    /// Source pixels per captured point, `sourceWidth / captureRectPoints.width`,
    /// so the cursor is drawn at the size the user saw it. That equals the
    /// display's `pointPixelScale` only when the stream runs at native
    /// pixels; a stream scaled below that (`captureResolution = .nominal`, an
    /// explicit `width`) has fewer pixels per point, and the display's scale
    /// would draw the cursor up to twice too large.
    public var sourcePixelsPerPoint: Double
    /// The click rings alive now, oldest first, radii and strokes in output
    /// pixels and centres in frame coordinates (`FrameState.ripples`). Past
    /// `CompositorUniforms.maximumRipples` the oldest are dropped.
    public var ripples: [Ripple]
    /// The camera bubble; nil draws none.
    public var camera: CameraBubbleFrame?
    /// The card's bounds in output pixels as the engine's layout solved them
    /// (`FrameLayout.card`), which on a narrow canvas leave room for a
    /// stacked bubble. The visible content is aspect-fitted and centred
    /// inside it, so a bound whose aspect disagrees with the pixels never
    /// stretches the picture. nil fits the card inside the style's padding
    /// alone, the M1 rule.
    public var cardRect: PixelRect?

    public init(
        pixelBuffer: CVPixelBuffer, viewport: CameraViewport = .full, contentCrop: CameraViewport = .full,
        cursor: CursorSample? = nil, cursorSprite: CursorSprite = .arrow, sourcePixelsPerPoint: Double = 1,
        ripples: [Ripple] = [], camera: CameraBubbleFrame? = nil, cardRect: PixelRect? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.viewport = viewport
        self.contentCrop = contentCrop
        self.cursor = cursor
        self.cursorSprite = cursorSprite
        self.sourcePixelsPerPoint = sourcePixelsPerPoint
        self.ripples = ripples
        self.camera = camera
        self.cardRect = cardRect
    }
}

/// How long one frame took.
public struct RenderTiming: Sendable, Hashable {
    /// Wall time of the whole call: encoding, submission and the wait for the GPU.
    public var cpuSeconds: Double
    /// Time the GPU spent on the command buffer, from Metal's own timestamps.
    public var gpuSeconds: Double

    public init(cpuSeconds: Double, gpuSeconds: Double) {
        self.cpuSeconds = cpuSeconds
        self.gpuSeconds = gpuSeconds
    }
}

/// A finished frame from the compositor's pool.
public struct RenderedFrame {
    /// BGRA at the style's output size, tagged BT.709 (primaries, transfer and
    /// matrix). The samples are the source's sRGB-encoded values, untouched;
    /// the 709 tags are what SDR video pipelines expect and what the export
    /// writer forces anyway (architecture panel §5), so nothing converts here.
    public var pixelBuffer: CVPixelBuffer
    public var timing: RenderTiming
}

public enum RenderError: Error, LocalizedError, Sendable {
    case noMetalDevice
    case shaderCompilation(String)
    case pipelineState(String)
    case textureCache(CVReturn)
    case unsupportedSourceFormat(OSType)
    case unsupportedColorSpace(String)
    case sourceTexture(CVReturn)
    case unsupportedOutput(String)
    case invalidOutputSize(width: Int, height: Int)
    case pixelBufferPool(CVReturn)
    case pixelBuffer(CVReturn)
    case outputTexture(CVReturn)
    case spriteUpload
    case commandBuffer
    case gpu(String)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device is available."
        case .shaderCompilation(let detail): "The compositor shaders did not compile: \(detail)"
        case .pipelineState(let detail): "The compositor pipeline could not be built: \(detail)"
        case .textureCache(let status): "CVMetalTextureCacheCreate failed (\(status))."
        case .unsupportedSourceFormat(let format):
            "Source pixel format '\(fourCharCode(format))' is not supported; use BGRA, 420v or 420f."
        case .unsupportedColorSpace(let detail):
            "The source frame is tagged \(detail); the compositor renders sRGB / BT.709 sources only."
        case .sourceTexture(let status):
            "Could not wrap the source frame as a Metal texture (\(status)); is it IOSurface-backed?"
        case .unsupportedOutput(let detail): "The render target is not usable: \(detail)."
        case .invalidOutputSize(let width, let height): "Output size \(width)×\(height) is not positive."
        case .pixelBufferPool(let status): "CVPixelBufferPoolCreate failed (\(status))."
        case .pixelBuffer(let status):
            status == kCVReturnWouldExceedAllocationThreshold
                ? "The output pool is exhausted; frames are being held faster than they are released."
                : "CVPixelBufferPoolCreatePixelBuffer failed (\(status))."
        case .outputTexture(let status): "Could not wrap the output frame as a Metal texture (\(status))."
        case .spriteUpload: "The cursor sprite could not be uploaded to the GPU."
        case .commandBuffer: "Metal returned no command buffer or encoder."
        case .gpu(let detail): "The GPU failed to render the frame: \(detail)"
        }
    }
}

/// Composes one output frame from a captured frame, the content crop, the
/// camera viewport, the smoothed cursor, the click ripples, the camera
/// bubble and a `RenderStyle`. Every render path (preview, export) calls
/// this; nothing here knows about time, timelines or AVFoundation.
///
/// Thread-safety: one instance may be used from any thread, including an
/// `AVVideoCompositing` request queue, and from several at once. The Metal
/// device, queue, library, samplers and functions are immutable; the
/// pipeline, sprite, pool and texture-cache state sit behind a `Mutex`, and
/// the GPU wait happens outside it so concurrent frames overlap.
public final class Compositor: @unchecked Sendable {
    public let device: MTLDevice
    /// How many output frames may be alive at once before `render(_:style:)`
    /// throws instead of allocating; keeps a stalled consumer from eating
    /// memory one 4K frame at a time.
    public let maximumPooledFrames: Int
    /// Sprites kept on the GPU before the cache is emptied. A recording uses
    /// a handful of shapes; the cap is for a caller that builds a new
    /// `CursorSprite` per frame, which would otherwise keep every one alive.
    public static let maximumCachedSprites = 32
    /// Minification (source pixels per output pixel) up to which one bilinear
    /// tap is enough. Beyond it the shader averages a grid of taps spread over
    /// the output pixel's footprint, so a Retina capture on a 1080p canvas or
    /// in a small preview is box-filtered rather than point-sampled.
    static let supersampleThreshold = 1.05
    /// Taps per axis at most; 4×4 covers a 6K source on a 1080p canvas, and
    /// a 720p camera in a bubble a fifth of the canvas tall.
    static let maximumSupersampleGrid = 4
    /// The source and camera textures the shader declares, in slot order:
    /// BGRA, luma, chroma for each.
    static let sourceTextureSlots = 0..<3
    static let cameraTextureSlots = 4..<7
    static let spriteTextureSlot = 3

    private let queue: MTLCommandQueue
    private let vertexFunction: MTLFunction
    private let fragmentFunction: MTLFunction
    private let sourceSampler: MTLSamplerState
    private let spriteSampler: MTLSamplerState
    /// `kCVPixelBufferPoolAllocationThresholdKey`, bridged once rather than per frame.
    private let auxiliaryAttributes: CFDictionary
    private let state: Mutex<State>

    private struct State {
        var textureCache: CVMetalTextureCache
        /// 1×1 transparent texture bound to source slots the current frame
        /// does not use, so every slot the shader declares is always bound.
        var placeholder: MTLTexture
        var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        var sprites: [ObjectIdentifier: (sprite: CursorSprite, texture: MTLTexture)] = [:]
        var pool: CVPixelBufferPool?
        var poolWidth = 0
        var poolHeight = 0
    }

    /// Metal textures and CoreVideo buffers are not `Sendable` in the SDK, but
    /// everything handed across the lock here is either immutable once made
    /// or written only by a GPU pass the caller waits on. The box states that.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Compiles the shaders (100–300 ms once) and builds the caches.
    public init(device: MTLDevice? = nil, maximumPooledFrames: Int = 16) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        self.device = device
        self.maximumPooledFrames = maximumPooledFrames
        precondition(
            MemoryLayout<CompositorUniforms>.stride == ShaderSource.uniformsStride,
            "CompositorUniforms no longer matches the shader's Uniforms layout.")
        guard let queue = device.makeCommandQueue() else { throw RenderError.commandBuffer }
        queue.label = "app.cutscene.compositor"
        self.queue = queue

        let options = MTLCompileOptions()
        // Relaxed keeps infinities and NaNs well-defined while letting the
        // compiler fuse and reorder; nothing here needs IEEE-exact results.
        options.mathMode = .relaxed
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.composite, options: options)
        } catch {
            throw RenderError.shaderCompilation(error.localizedDescription)
        }
        guard let vertexFunction = library.makeFunction(name: ShaderSource.vertexFunction),
            let fragmentFunction = library.makeFunction(name: ShaderSource.fragmentFunction)
        else {
            throw RenderError.shaderCompilation("missing entry points")
        }
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.normalizedCoordinates = true
        guard let sourceSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RenderError.pipelineState("sampler")
        }
        self.sourceSampler = sourceSampler
        // The sprite has a mip chain (see `spriteTexture`), and the camera
        // scale varies continuously, so blend between levels.
        samplerDescriptor.mipFilter = .linear
        guard let spriteSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RenderError.pipelineState("sprite sampler")
        }
        self.spriteSampler = spriteSampler
        auxiliaryAttributes = [kCVPixelBufferPoolAllocationThresholdKey: maximumPooledFrames] as CFDictionary

        // One cache serves sources and outputs: the usage covers reading a
        // source and rendering into an output.
        let usage: MTLTextureUsage = [.shaderRead, .renderTarget]
        let cacheAttributes: [CFString: Any] = [kCVMetalTextureUsage: usage.rawValue]
        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, cacheAttributes as CFDictionary, &textureCache)
        guard cacheStatus == kCVReturnSuccess, let textureCache else { throw RenderError.textureCache(cacheStatus) }

        let placeholder = try Self.makeTexture(device: device, width: 1, height: 1, mipmapped: false)
        var clear: UInt32 = 0
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)

        state = Mutex(State(textureCache: textureCache, placeholder: placeholder))
        // Build the common pipeline now so the first frame pays nothing extra.
        _ = try pipeline(for: .bgra8Unorm)
    }

    // MARK: Rendering

    /// Renders into a BGRA frame from the compositor's pool at
    /// `style.outputWidth × outputHeight`. Synchronous: the frame is complete
    /// when this returns.
    public func render(_ frame: SourceFrame, style: RenderStyle) throws -> RenderedFrame {
        let started = ContinuousClock.now
        let width = style.outputWidth
        let height = style.outputHeight
        guard width > 0, height > 0 else { throw RenderError.invalidOutputSize(width: width, height: height) }

        let pool = try state.withLock { state -> Unchecked<CVPixelBufferPool> in
            if state.pool == nil || state.poolWidth != width || state.poolHeight != height {
                state.pool = try Self.makePool(width: width, height: height)
                state.poolWidth = width
                state.poolHeight = height
            }
            return Unchecked(value: state.pool!)
        }
        // Outside the lock: a cold pool allocates a 4K IOSurface here, and
        // pools are safe to draw from concurrently.
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool.value, auxiliaryAttributes, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw RenderError.pixelBuffer(status) }
        let gpuSeconds = try encodeAndWait(frame, style: style, output: .pixelBuffer(buffer))
        // Pool buffers come back recycled, so the tags are set every time; the
        // cost is a dictionary write.
        Self.tagBT709(buffer)
        return RenderedFrame(
            pixelBuffer: buffer, timing: RenderTiming(cpuSeconds: Self.seconds(since: started), gpuSeconds: gpuSeconds))
    }

    /// Renders into a caller-supplied BGRA, IOSurface-backed buffer, such as
    /// the one `AVVideoCompositionRenderContext.newPixelBuffer()` vends, and
    /// tags it BT.709. The output size is the buffer's; the style's
    /// `outputWidth` and `outputHeight` are ignored.
    @discardableResult
    public func render(_ frame: SourceFrame, style: RenderStyle, into output: CVPixelBuffer) throws -> RenderTiming {
        let started = ContinuousClock.now
        let format = CVPixelBufferGetPixelFormatType(output)
        guard format == kCVPixelFormatType_32BGRA else {
            throw RenderError.unsupportedOutput("pixel format '\(fourCharCode(format))'; the output must be BGRA")
        }
        let gpuSeconds = try encodeAndWait(frame, style: style, output: .pixelBuffer(output))
        Self.tagBT709(output)
        return RenderTiming(cpuSeconds: Self.seconds(since: started), gpuSeconds: gpuSeconds)
    }

    /// Renders onto a caller-supplied texture, such as a `CAMetalLayer`
    /// drawable for the preview. The output size is the texture's; the style's
    /// `outputWidth` and `outputHeight` are ignored. The texture must have
    /// been created for `renderTarget` use in a non-sRGB format
    /// (`bgra8Unorm`): the samples are already sRGB-encoded, and an sRGB
    /// attachment would encode them a second time and wash the frame out.
    @discardableResult
    public func render(_ frame: SourceFrame, style: RenderStyle, to target: MTLTexture) throws -> RenderTiming {
        let started = ContinuousClock.now
        guard target.usage.contains(.renderTarget) else {
            throw RenderError.unsupportedOutput("the texture was not created with renderTarget usage")
        }
        guard !Self.sRGBFormats.contains(target.pixelFormat) else {
            throw RenderError.unsupportedOutput("an sRGB texture would re-encode the sRGB samples; use bgra8Unorm")
        }
        let gpuSeconds = try encodeAndWait(frame, style: style, output: .texture(target))
        return RenderTiming(cpuSeconds: Self.seconds(since: started), gpuSeconds: gpuSeconds)
    }

    /// Lets the texture cache recycle the source and output textures it still
    /// holds. The cache does this on its own while frames keep coming; call
    /// this when a batch ends or playback pauses, so the last IOSurfaces (and
    /// the pool buffers behind them) are released before the one-second
    /// age-out.
    public func flush() {
        state.withLock { state in
            CVMetalTextureCacheFlush(state.textureCache, 0)
        }
    }

    private enum Output {
        case texture(MTLTexture)
        case pixelBuffer(CVPixelBuffer)
    }

    /// Encodes the single pass and waits for it. Returns the GPU time.
    private func encodeAndWait(_ frame: SourceFrame, style: RenderStyle, output: Output) throws -> Double {
        let source = frame.pixelBuffer
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = try Self.sourceFormat(of: source)
        // The camera goes through the same format and colour check as the
        // screen: a wrongly tagged camera movie must fail as loudly.
        let camera = frame.camera?.pixelBuffer
        let cameraFormat = try camera.map(Self.sourceFormat(of:)) ?? CompositorUniforms.bgraSource
        let cameraSize = camera.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) } ?? (1, 1)

        // The cache only reads the buffers (it binds textures to their
        // IOSurfaces) and the caller keeps them alive, so they may cross the lock.
        let boxedSource = Unchecked(value: source)
        let boxedCamera = camera.map { Unchecked(value: $0) }
        let boxedOutput = Unchecked(value: output)
        let sprite = frame.cursorSprite
        let wantsCursor = frame.cursor != nil
        // Everything that touches the caches happens here, then the lock is
        // released before the GPU work so other threads can prepare their frames.
        let bound = try state.withLock { state -> Unchecked<BoundTextures> in
            var bound = BoundTextures(placeholder: state.placeholder)
            bound.retained.reserveCapacity(5)
            switch boxedOutput.value {
            case .texture(let texture):
                bound.target = texture
            case .pixelBuffer(let buffer):
                let texture = try Self.wrap(
                    buffer, in: state.textureCache, format: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer), plane: 0, failure: RenderError.outputTexture)
                bound.retained.append(texture)
                bound.target = CVMetalTextureGetTexture(texture)
            }
            bound.source = try Self.wrapSource(
                boxedSource.value, format: sourceFormat, in: &bound, cache: state.textureCache)
            if let boxedCamera {
                bound.camera = try Self.wrapSource(
                    boxedCamera.value, format: cameraFormat, in: &bound, cache: state.textureCache)
            }
            if wantsCursor {
                bound.sprite = try Self.spriteTexture(for: sprite, device: device, queue: queue, in: &state)
            }
            return Unchecked(value: bound)
        }
        let textures = bound.value
        guard let target = textures.target else { throw RenderError.outputTexture(kCVReturnError) }
        guard target.width > 0, target.height > 0 else {
            throw RenderError.invalidOutputSize(width: target.width, height: target.height)
        }
        let pipeline = try pipeline(for: target.pixelFormat)

        var uniforms = Self.uniforms(
            for: frame, style: style, sourceFormat: sourceFormat, sourceSize: (sourceWidth, sourceHeight),
            outputSize: (target.width, target.height), cameraFormat: cameraFormat, cameraSize: cameraSize)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // Every pixel is written, so the previous contents need not be loaded.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Cutscene composite"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositorUniforms>.stride, index: 0)
        textures.source.bind(to: encoder, slots: Self.sourceTextureSlots, placeholder: textures.placeholder)
        (textures.camera ?? SourceTextures()).bind(
            to: encoder, slots: Self.cameraTextureSlots, placeholder: textures.placeholder)
        encoder.setFragmentTexture(textures.sprite ?? textures.placeholder, index: Self.spriteTextureSlot)
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.setFragmentSamplerState(spriteSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        // The CVMetalTextures must outlive the GPU's use of the IOSurfaces.
        withExtendedLifetime(textures.retained) {
            commandBuffer.waitUntilCompleted()
        }
        if let error = commandBuffer.error { throw RenderError.gpu(error.localizedDescription) }
        return max(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, 0)
    }

    /// The textures of one source (the screen or the camera): BGRA, or a
    /// luma and a chroma plane.
    private struct SourceTextures {
        var bgra: MTLTexture?
        var luma: MTLTexture?
        var chroma: MTLTexture?

        /// Binds the three slots, the placeholder on the ones this source
        /// does not use, so every slot the shader declares is always bound.
        func bind(to encoder: MTLRenderCommandEncoder, slots: Range<Int>, placeholder: MTLTexture) {
            encoder.setFragmentTexture(bgra ?? placeholder, index: slots.lowerBound)
            encoder.setFragmentTexture(luma ?? placeholder, index: slots.lowerBound + 1)
            encoder.setFragmentTexture(chroma ?? placeholder, index: slots.lowerBound + 2)
        }
    }

    private struct BoundTextures {
        var placeholder: MTLTexture
        var target: MTLTexture?
        var source = SourceTextures()
        var camera: SourceTextures?
        var sprite: MTLTexture?
        var retained: [CVMetalTexture] = []
    }

    /// Wraps a source buffer's planes as textures through the cache, keeping
    /// the `CVMetalTexture`s alive in `bound.retained`.
    private static func wrapSource(
        _ buffer: CVPixelBuffer, format: UInt32, in bound: inout BoundTextures, cache: CVMetalTextureCache
    ) throws -> SourceTextures {
        var textures = SourceTextures()
        switch format {
        case CompositorUniforms.bgraSource:
            let texture = try wrap(
                buffer, in: cache, format: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer), plane: 0, failure: RenderError.sourceTexture)
            bound.retained.append(texture)
            textures.bgra = CVMetalTextureGetTexture(texture)
        default:
            let luma = try wrap(
                buffer, in: cache, format: .r8Unorm, width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0), plane: 0, failure: RenderError.sourceTexture)
            let chroma = try wrap(
                buffer, in: cache, format: .rg8Unorm, width: CVPixelBufferGetWidthOfPlane(buffer, 1),
                height: CVPixelBufferGetHeightOfPlane(buffer, 1), plane: 1, failure: RenderError.sourceTexture)
            bound.retained += [luma, chroma]
            textures.luma = CVMetalTextureGetTexture(luma)
            textures.chroma = CVMetalTextureGetTexture(chroma)
        }
        guard textures.bgra != nil || (textures.luma != nil && textures.chroma != nil) else {
            throw RenderError.sourceTexture(kCVReturnError)
        }
        return textures
    }

    // MARK: Layout

    /// Taps per axis for a source minified `minification` times onto the
    /// output, and their spacing in source pixels: one tap up to
    /// `supersampleThreshold`, then a grid of at most `maximumSupersampleGrid`.
    private static func taps(forMinification minification: Double) -> (count: Int, spacing: Double) {
        let count =
            minification <= supersampleThreshold ? 1 : min(Int(minification.rounded(.up)), maximumSupersampleGrid)
        return (count, minification / Double(count))
    }

    /// The per-frame constants. Pure, so the layout can be checked without a GPU.
    static func uniforms(
        for frame: SourceFrame, style: RenderStyle, sourceFormat: UInt32, sourceSize: (width: Int, height: Int),
        outputSize: (width: Int, height: Int), cameraFormat: UInt32 = CompositorUniforms.bgraSource,
        cameraSize: (width: Int, height: Int) = (1, 1)
    ) -> CompositorUniforms {
        let outputWidth = Double(outputSize.width)
        let outputHeight = Double(outputSize.height)

        // The visible content: the crop's slice of the source, then the
        // viewport's slice of that, shown at its own aspect ratio.
        let viewport = frame.viewport
        let viewportWidth = max(viewport.size.width, 1e-6)
        let viewportHeight = max(viewport.size.height, 1e-6)
        let crop = frame.contentCrop
        let cropWidth = max(crop.size.width, 1e-6)
        let cropHeight = max(crop.size.height, 1e-6)
        let sourceWidth = Double(max(sourceSize.width, 1))
        let sourceHeight = Double(max(sourceSize.height, 1))
        let visibleWidth = viewportWidth * cropWidth * sourceWidth
        let visibleHeight = viewportHeight * cropHeight * sourceHeight

        // The card: the visible content aspect-fitted and centred inside its
        // bound, which is the engine's card rect when the frame carries one
        // and the padded canvas otherwise.
        let bound: PixelRect
        if let rect = frame.cardRect, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 {
            bound = rect
        } else {
            let padding = min(max(style.padding, 0), 0.49) * min(outputWidth, outputHeight)
            bound = PixelRect(
                x: padding, y: padding, width: max(outputWidth - 2 * padding, 1),
                height: max(outputHeight - 2 * padding, 1))
        }
        let pixelsPerSourcePixel = min(bound.width / visibleWidth, bound.height / visibleHeight)
        let cardWidth = visibleWidth * pixelsPerSourcePixel
        let cardHeight = visibleHeight * pixelsPerSourcePixel
        let cardX = bound.x + (bound.width - cardWidth) / 2
        let cardY = bound.y + (bound.height - cardHeight) / 2

        // Source pixels under one output pixel. One bilinear tap reads only a
        // 2×2 texel patch, so past the threshold the shader spreads a grid of
        // taps over the whole footprint; the spacing is in source uv units.
        let sourceTaps = taps(forMinification: 1 / pixelsPerSourcePixel)
        let sourceTapStep = SIMD2(Float(sourceTaps.spacing / sourceWidth), Float(sourceTaps.spacing / sourceHeight))

        // Frame coordinates to output pixels, through the crop and then the
        // viewport: the cursor and the ripples share the screen's mapping.
        func canvasPoint(_ position: NormalizedPoint) -> (x: Double, y: Double) {
            let contentX = (position.x - crop.origin.x) / cropWidth
            let contentY = (position.y - crop.origin.y) / cropHeight
            return (
                cardX + (contentX - viewport.origin.x) / viewportWidth * cardWidth,
                cardY + (contentY - viewport.origin.y) / viewportHeight * cardHeight
            )
        }

        // The cursor's natural size in source pixels, through the same
        // magnification as the screen, times the style and press scales.
        var cursorOrigin = SIMD2<Float>(0, 0)
        var cursorSize = SIMD2<Float>(1, 1)
        var cursorOpacity: Float = 0
        if let cursor = frame.cursor, cursor.opacity > 0 {
            let sprite = frame.cursorSprite
            let scale = frame.sourcePixelsPerPoint * style.cursorScale * cursor.scale * pixelsPerSourcePixel
            let spriteWidth = max(sprite.sizePoints.width * scale, 1e-3)
            let spriteHeight = max(sprite.sizePoints.height * scale, 1e-3)
            let point = canvasPoint(cursor.smoothedPosition)
            cursorOrigin = SIMD2(
                Float(point.x - sprite.hotspot.x * spriteWidth), Float(point.y - sprite.hotspot.y * spriteHeight))
            cursorSize = SIMD2(Float(spriteWidth), Float(spriteHeight))
            cursorOpacity = Float(min(cursor.opacity, 1))
        }

        // The ripples, already in output pixels; the newest win when there
        // are more than the shader draws.
        var rippleCenterX = SIMD4<Float>(repeating: 0)
        var rippleCenterY = SIMD4<Float>(repeating: 0)
        var rippleRadius = SIMD4<Float>(repeating: 0)
        var rippleHalfStroke = SIMD4<Float>(repeating: 0)
        var rippleOpacity = SIMD4<Float>(repeating: 0)
        let rings = frame.ripples.suffix(CompositorUniforms.maximumRipples)
        for (lane, ring) in rings.enumerated() {
            let center = canvasPoint(ring.position)
            rippleCenterX[lane] = Float(center.x)
            rippleCenterY[lane] = Float(center.y)
            rippleRadius[lane] = Float(max(ring.radius, 0))
            rippleHalfStroke[lane] = Float(max(ring.strokeWidth, 0) / 2)
            rippleOpacity[lane] = Float(min(max(ring.opacity, 0), 1))
        }

        // The bubble: the camera aspect-filled into the placement's rect,
        // mirrored by flipping the uv run, box-filtered like the screen.
        var bubbleMode = CompositorUniforms.noBubble
        var bubbleOrigin = SIMD2<Float>(0, 0)
        var bubbleSize = SIMD2<Float>(1, 1)
        var bubbleCornerRadius: Float = 0
        var bubbleBorderWidth: Float = 0
        var bubbleShadowOpacity: Float = 0
        var cameraUVOrigin = SIMD2<Float>(0, 0)
        var cameraUVScale = SIMD2<Float>(1, 1)
        var cameraTapStep = SIMD2<Float>(0, 0)
        var cameraTapCount = 1
        if let camera = frame.camera, camera.placement.rect.width > 0, camera.placement.rect.height > 0 {
            let placement = camera.placement
            let rect = placement.rect
            bubbleMode = CompositorUniforms.cameraBubble
            bubbleOrigin = SIMD2(Float(rect.x), Float(rect.y))
            bubbleSize = SIMD2(Float(rect.width), Float(rect.height))
            switch placement.outline {
            case .circle: bubbleCornerRadius = Float(min(rect.width, rect.height) / 2)
            case .roundedRectangle: bubbleCornerRadius = Float(max(placement.cornerRadius, 0))
            }
            bubbleBorderWidth = Float(max(placement.borderWidth, 0))
            bubbleShadowOpacity = style.camera.usesFrameShadow ? Float(min(max(style.shadow.opacity, 0), 1)) : 0
            let cameraWidth = Double(max(cameraSize.width, 1))
            let cameraHeight = Double(max(cameraSize.height, 1))
            let fill = max(rect.width / cameraWidth, rect.height / cameraHeight)
            let visibleFractionX = rect.width / (cameraWidth * fill)
            let visibleFractionY = rect.height / (cameraHeight * fill)
            var originX = (1 - visibleFractionX) / 2
            var scaleX = visibleFractionX
            if camera.isMirrored {
                originX += visibleFractionX
                scaleX = -visibleFractionX
            }
            cameraUVOrigin = SIMD2(Float(originX), Float((1 - visibleFractionY) / 2))
            cameraUVScale = SIMD2(Float(scaleX), Float(visibleFractionY))
            let cameraTaps = taps(forMinification: 1 / fill)
            cameraTapCount = cameraTaps.count
            cameraTapStep = SIMD2(Float(cameraTaps.spacing / cameraWidth), Float(cameraTaps.spacing / cameraHeight))
        }

        var backgroundMode = CompositorUniforms.solidBackground
        var backgroundFrom = SIMD4<Float>(0, 0, 0, 1)
        var backgroundTo = SIMD4<Float>(0, 0, 0, 1)
        var gradientDirection = SIMD2<Float>(0, -1)
        var gradientHalfLength: Float = 1
        switch style.background {
        case .solid(let color):
            backgroundFrom = Self.vector(color)
        case .linearGradient(let from, let to, let angleDegrees):
            backgroundMode = CompositorUniforms.gradientBackground
            backgroundFrom = Self.vector(from)
            backgroundTo = Self.vector(to)
            // CSS angles: 0 points up, 90 right; y grows downward in pixels.
            let radians = angleDegrees * .pi / 180
            let direction = (x: sin(radians), y: -cos(radians))
            gradientDirection = SIMD2(Float(direction.x), Float(direction.y))
            // Half the gradient line: the projection of the half-frame onto
            // the direction, so the corners land exactly on the two stops.
            let halfLength = abs(outputWidth / 2 * direction.x) + abs(outputHeight / 2 * direction.y)
            gradientHalfLength = Float(max(halfLength, 1e-3))
        }

        return CompositorUniforms(
            outputSize: SIMD2(Float(outputWidth), Float(outputHeight)),
            cardOrigin: SIMD2(Float(cardX), Float(cardY)),
            cardSize: SIMD2(Float(cardWidth), Float(cardHeight)),
            viewportOrigin: SIMD2(Float(viewport.origin.x), Float(viewport.origin.y)),
            viewportSize: SIMD2(Float(viewportWidth), Float(viewportHeight)),
            cropOrigin: SIMD2(Float(crop.origin.x), Float(crop.origin.y)),
            cropSize: SIMD2(Float(cropWidth), Float(cropHeight)),
            shadowOffset: SIMD2(Float(style.shadow.offsetX), Float(style.shadow.offsetY)),
            cursorOrigin: cursorOrigin,
            cursorSize: cursorSize,
            gradientDirection: gradientDirection,
            sourceTapStep: sourceTapStep,
            bubbleOrigin: bubbleOrigin,
            bubbleSize: bubbleSize,
            cameraUVOrigin: cameraUVOrigin,
            cameraUVScale: cameraUVScale,
            cameraTapStep: cameraTapStep,
            backgroundFrom: backgroundFrom,
            backgroundTo: backgroundTo,
            rippleColor: Self.vector(style.rippleColor),
            bubbleBorderColor: Self.vector(style.camera.borderColor),
            rippleCenterX: rippleCenterX,
            rippleCenterY: rippleCenterY,
            rippleRadius: rippleRadius,
            rippleHalfStroke: rippleHalfStroke,
            rippleOpacity: rippleOpacity,
            cornerRadius: Float(max(style.cornerRadius, 0)),
            // Half a pixel at least: smoothstep with equal edges is undefined.
            shadowBlur: Float(max(style.shadow.blurRadius, 0.5)),
            shadowOpacity: Float(min(max(style.shadow.opacity, 0), 1)),
            cursorOpacity: cursorOpacity,
            gradientHalfLength: gradientHalfLength,
            bubbleCornerRadius: bubbleCornerRadius,
            bubbleBorderWidth: bubbleBorderWidth,
            bubbleShadowOpacity: bubbleShadowOpacity,
            backgroundMode: backgroundMode,
            sourceFormat: sourceFormat,
            sourceTapCount: UInt32(sourceTaps.count),
            rippleCount: UInt32(rings.count),
            bubbleMode: bubbleMode,
            cameraFormat: cameraFormat,
            cameraTapCount: UInt32(cameraTapCount))
    }

    private static func vector(_ color: RenderColor) -> SIMD4<Float> {
        SIMD4(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha))
    }

    // MARK: Resources

    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try state.withLock { state in
            if let existing = state.pipelines[format] { return existing }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Cutscene composite \(format.rawValue)"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = format
            let pipeline: MTLRenderPipelineState
            do {
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RenderError.pipelineState(error.localizedDescription)
            }
            state.pipelines[format] = pipeline
            return pipeline
        }
    }

    /// Formats the fragment shader must not write: its values are already
    /// sRGB-encoded, and these attachments would encode them again.
    private static let sRGBFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm_srgb, .rgba8Unorm_srgb, .r8Unorm_srgb, .rg8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb,
    ]

    /// The sprite's texture, uploaded on first use with a full mip chain. The
    /// entry retains the sprite so its identifier stays unique for as long as
    /// it is cached.
    private static func spriteTexture(
        for sprite: CursorSprite, device: MTLDevice, queue: MTLCommandQueue, in state: inout State
    ) throws -> MTLTexture {
        let key = ObjectIdentifier(sprite)
        if let cached = state.sprites[key] { return cached.texture }
        let image = sprite.image
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RenderError.spriteUpload
        }
        // Redrawing through CoreGraphics normalizes any CGImage layout to the
        // premultiplied BGRA the shader composites with.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RenderError.spriteUpload }
        let texture = try makeTexture(device: device, width: width, height: height, mipmapped: true)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        // The sprite is drawn far smaller than its bitmap (8× oversampled,
        // then minified by the card scale), and sampling level 0 alone
        // point-samples the edges, so the cursor shimmers as it moves. The
        // chain is built once per sprite; premultiplied texels average correctly.
        guard let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { throw RenderError.spriteUpload }
        if state.sprites.count >= maximumCachedSprites { state.sprites.removeAll() }
        state.sprites[key] = (sprite, texture)
        return texture
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, mipmapped: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        // Managed is the storage mode every macOS GPU accepts for a texture
        // the CPU fills once (MTLResource.h); on unified memory it is one
        // allocation anyway. Shared textures are an Apple-GPU feature, and
        // `hasUnifiedMemory` is also true on Intel integrated GPUs.
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.spriteUpload }
        return texture
    }

    private static func wrap(
        _ buffer: CVPixelBuffer, in cache: CVMetalTextureCache, format: MTLPixelFormat, width: Int, height: Int,
        plane: Int, failure: (CVReturn) -> RenderError
    ) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, width, height, plane, &texture)
        guard status == kCVReturnSuccess, let texture else { throw failure(status) }
        return texture
    }

    /// The shader's code for the buffer's pixel format, after checking that
    /// the buffer is tagged for the sRGB / BT.709 pipeline the shader and the
    /// output tags assume (or not tagged at all).
    private static func sourceFormat(of buffer: CVPixelBuffer) throws -> UInt32 {
        let format: UInt32
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA: format = CompositorUniforms.bgraSource
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: format = CompositorUniforms.videoRange420Source
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: format = CompositorUniforms.fullRange420Source
        case let other: throw RenderError.unsupportedSourceFormat(other)
        }
        try checkColorTags(of: buffer, isYCbCr: format != CompositorUniforms.bgraSource)
        return format
    }

    private static let acceptedPrimaries: Set<String> = [kCVImageBufferColorPrimaries_ITU_R_709_2 as String]
    private static let acceptedTransferFunctions: Set<String> = [
        kCVImageBufferTransferFunction_ITU_R_709_2 as String, kCVImageBufferTransferFunction_sRGB as String,
    ]
    private static let acceptedMatrices: Set<String> = [kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String]
    /// `kCGColorSpaceCoreMedia709` (15.0) is the space the composition engine
    /// attaches to the BGRA frames it converts from a 709-tagged decoder.
    private static let acceptedColorSpaceNames: Set<String> = [
        CGColorSpace.sRGB as String, CGColorSpace.extendedSRGB as String, CGColorSpace.itur_709 as String,
        CGColorSpace.coreMedia709 as String,
    ]

    /// Rejects a frame whose tags say it is not sRGB / BT.709. ScreenCaptureKit
    /// uses the display's colour space unless `colorSpaceName` is pinned
    /// (SCStream.h), so on a Display P3 Mac an unpinned stream would reach
    /// here P3-encoded and leave the frame tagged 709, visibly desaturated.
    /// Four dictionary lookups per frame buy a typed error instead.
    ///
    /// The string tags are the rule (DECISIONS "sRGB / BT.709 sources
    /// only"); a `CGColorSpace` attachment is held to its name only when the
    /// frame carries no primaries and transfer tags, since the composition
    /// engine names its spaces as it likes from one macOS to the next. When
    /// the tags are there and accepted, the space has only to agree with
    /// them on the gamut: a wide-gamut space beside 709 tags is still refused.
    private static func checkColorTags(of buffer: CVPixelBuffer, isYCbCr: Bool) throws {
        let primaries = stringAttachment(of: buffer, key: kCVImageBufferColorPrimariesKey)
        if let primaries, !acceptedPrimaries.contains(primaries) {
            throw RenderError.unsupportedColorSpace("colour primaries \(primaries)")
        }
        let transfer = stringAttachment(of: buffer, key: kCVImageBufferTransferFunctionKey)
        if let transfer, !acceptedTransferFunctions.contains(transfer) {
            throw RenderError.unsupportedColorSpace("transfer function \(transfer)")
        }
        if isYCbCr, let matrix = stringAttachment(of: buffer, key: kCVImageBufferYCbCrMatrixKey),
            !acceptedMatrices.contains(matrix)
        {
            throw RenderError.unsupportedColorSpace("YCbCr matrix \(matrix)")
        }
        if let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
            CFGetTypeID(attachment) == CGColorSpace.typeID
        {
            let space = attachment as! CGColorSpace
            let name = space.name.map { $0 as String }
            if let name, acceptedColorSpaceNames.contains(name) { return }
            let taggedByStrings = primaries != nil && transfer != nil
            if taggedByStrings, !space.isWideGamutRGB { return }
            throw RenderError.unsupportedColorSpace("colour space \(name ?? "an unnamed colour space")")
        }
    }

    private static func stringAttachment(of buffer: CVPixelBuffer, key: CFString) -> String? {
        guard let attachment = CVBufferCopyAttachment(buffer, key, nil), CFGetTypeID(attachment) == CFStringGetTypeID()
        else { return nil }
        return attachment as! CFString as String
    }

    private static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // IOSurface backing is what lets Metal render into the frame and
            // the encoder read it without a copy.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw RenderError.pixelBufferPool(status) }
        return pool
    }

    private static func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// A pixel format code as the four characters it spells, for error messages.
func fourCharCode(_ code: OSType) -> String {
    let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
}
