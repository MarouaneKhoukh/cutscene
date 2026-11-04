import AVFoundation
import CoreMedia
import CoreVideo
import CutsceneCore
import CutsceneEngine
import Foundation
import Synchronization

/// Why a composition request could not be rendered.
public enum MetalCompositorError: Error, LocalizedError, Sendable {
    /// The Metal compositor could not be set up when the engine instantiated
    /// this adapter; the detail is the setup error's description.
    case noCompositor(String)
    /// The composition carried an instruction that is not a `RenderInstruction`.
    case unexpectedInstruction(String)
    /// The render context vended no output frame.
    case noOutputBuffer
    /// The transparent stand-in source could not be allocated.
    case blankSource(CVReturn)

    public var errorDescription: String? {
        switch self {
        case .noCompositor(let detail): "The Metal compositor is unavailable: \(detail)"
        case .unexpectedInstruction(let name):
            "The video composition instruction is a \(name), not a RenderInstruction."
        case .noOutputBuffer: "The render context vended no output pixel buffer."
        case .blankSource(let status): "CVPixelBufferCreate failed for the blank source frame (\(status))."
        }
    }
}

/// What a `MetalCompositor` instance has done so far, for spikes and the
/// export self-check.
public struct MetalCompositorStatistics: Sendable, Hashable {
    /// Requests started, finished ones and failed ones alike.
    public var requests = 0
    /// Requests that arrived without a source frame and rendered the last
    /// delivered one instead.
    public var heldFrames = 0
    /// Requests that arrived without a source frame before any had been
    /// delivered, and rendered the empty card.
    public var blankFrames = 0
    /// Requests finished with an error.
    public var failures = 0
    /// Requests that drew a camera bubble.
    public var cameraFrames = 0
    /// Bubbles drawn from the last delivered camera frame because the
    /// request brought none (a 30 fps camera under a 60 fps composition
    /// brings a new one every other request).
    public var heldCameraFrames = 0
    /// Bubbles drawn before any camera frame had been delivered, showing the
    /// background through the picture.
    public var blankCameraFrames = 0
    /// Wall time of the throwaway render after the last render-context change.
    public var warmUpSeconds: Double?
    /// The render context's size, in pixels.
    public var renderWidth = 0
    public var renderHeight = 0
    /// Wall time from the start of a request to its finish, over every request.
    public var totalLatencySeconds: Double = 0
    public var maximumLatencySeconds: Double = 0
    /// The median over the kept latency samples (`MetalCompositor.latencySampleCapacity`
    /// of them): the number ARCHITECTURE §5 trips the v2 decoder on
    /// (`startRequest` over one 4K60 frame interval), so an export can report it.
    public var medianLatencySeconds: Double = 0

    public var meanLatencySeconds: Double {
        requests > 0 ? totalLatencySeconds / Double(requests) : 0
    }

    public init() {}
}

/// A request that arrived without a source frame, and what it rendered instead.
public struct MissingSourceFrame: Sendable, Hashable {
    /// The request's composition time, in seconds.
    public var compositionTime: Double
    /// True when the last delivered frame was rendered; false when none
    /// existed yet and the card was left transparent.
    public var usedHeldFrame: Bool

    public init(compositionTime: Double, usedHeldFrame: Bool) {
        self.compositionTime = compositionTime
        self.usedHeldFrame = usedHeldFrame
    }
}

/// The `AVVideoCompositing` adapter: one `Compositor` per instance, driven by
/// the `RenderInstruction`s of a composition built by `CompositionBuilder`,
/// shared by the `AVPlayer` preview and the `AVAssetReader` export
/// (ARCHITECTURE §5). The composition engine instantiates it through
/// `customVideoCompositorClass`, so it has no inputs but the instructions.
///
/// Each request is rendered synchronously: the screen frame for the request's
/// track, the plan's state at the recording time behind the composition
/// time, and the style and sprites the instruction carries go through
/// `Compositor.render(_:style:into:)` onto a frame from the render context,
/// and `finish(withComposedVideoFrame:)` is called before `startRequest`
/// returns. A request without a source frame (an empty edit, a decoder that
/// has nothing new) renders the last delivered frame, so a static stretch
/// never shows an empty card; before the first frame the card is transparent
/// and the background shows through.
///
/// Thread-safety: the engine may call in from any queue; the held frame and
/// the counters sit behind a `Mutex`, the `Compositor` guards itself.
public final class MetalCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Latency samples kept for a median; at 60 fps about 73 minutes of
    /// export. Later requests still update the count, sum and maximum.
    public static let latencySampleCapacity = 1 << 18
    /// Side of the transparent source used to warm the pipeline: any size
    /// works, since the warm-up's output is discarded.
    static let warmUpSourceSide = 2
    /// Side of the transparent picture a bubble shows before the camera
    /// track has delivered a frame; aspect-filled, so any size works.
    static let blankCameraSide = 2
    /// The warm-up draws a cursor so the sprite path (upload, mip chain)
    /// is exercised too.
    static let warmUpCursor = CursorSample(
        time: 0, smoothedPosition: NormalizedPoint(x: 0.5, y: 0.5), rawPosition: NormalizedPoint(x: 0.5, y: 0.5),
        isPressed: false, opacity: 1, scale: 1)
    /// The warm-up draws a bubble too, so the camera texture slots and the
    /// bubble branch of the shader are exercised before the first request.
    static let warmUpBubble = BubblePlacement(
        rect: PixelRect(x: 0, y: 0, width: 2, height: 2), outline: .circle, cornerRadius: 1, borderWidth: 0,
        arrangement: .overlay)

    /// BGRA, Metal-compatible and IOSurface-backed, for sources and outputs
    /// alike: what the compositor wraps as textures without a copy. The
    /// engine converts decoded 4:2:0 frames to this on its side (native
    /// 4:2:0 sampling is an M3-08 lever).
    static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    private let compositor: Compositor?
    private let setupError: (any Error)?
    private let state = Mutex(State())

    /// Pixel buffers are not `Sendable` in the SDK; the ones boxed here are
    /// read by the GPU only inside a render the caller waits on.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    private struct SizeKey: Hashable {
        let width: Int
        let height: Int
    }

    private struct State: Sendable {
        /// The last delivered screen frame, retained so the decoder pool
        /// cannot recycle it while a request without a frame may need it.
        var heldFrame: Unchecked<CVPixelBuffer>?
        /// The last delivered camera frame, kept for the same reason.
        var heldCameraFrame: Unchecked<CVPixelBuffer>?
        /// Transparent sources by size, allocated on first need.
        var blankSources: [SizeKey: Unchecked<CVPixelBuffer>] = [:]
        var statistics = MetalCompositorStatistics()
        var latencies: [Double] = []
        var missingSourceFrames: [MissingSourceFrame] = []
    }

    /// The engine's entry point. A compositor that cannot be built (no Metal
    /// device, a shader that does not compile) makes every request fail
    /// with the reason rather than crashing the engine's queue.
    public override init() {
        do {
            compositor = try Compositor()
            setupError = nil
        } catch {
            compositor = nil
            setupError = error
        }
        super.init()
    }

    // MARK: AVVideoCompositing

    public var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelBufferAttributes }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelBufferAttributes }

    /// The compositor renders sRGB / BT.709 only; the engine converts
    /// wide-gamut sources to BT.709 before handing them over.
    public var supportsWideColorSourceFrames: Bool { false }

    public var supportsHDRSourceFrames: Bool { false }

    /// Renders one throwaway frame into the new context so the first real
    /// request does not pay for the output wrap, the sprite upload and the
    /// mip chain (8–26 ms measured by the render spike).
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        let size = newRenderContext.size
        state.withLock { state in
            state.statistics.renderWidth = Int(size.width)
            state.statistics.renderHeight = Int(size.height)
            state.statistics.warmUpSeconds = nil
        }
        guard let compositor, let output = newRenderContext.newPixelBuffer() else { return }
        let started = ContinuousClock.now
        do {
            let blank = try blankSource(width: Self.warmUpSourceSide, height: Self.warmUpSourceSide)
            try compositor.render(
                SourceFrame(
                    pixelBuffer: blank, cursor: Self.warmUpCursor,
                    camera: CameraBubbleFrame(pixelBuffer: blank, placement: Self.warmUpBubble)),
                style: RenderStyle(), into: output)
            let seconds = Self.seconds(since: started)
            state.withLock { $0.statistics.warmUpSeconds = seconds }
        } catch {
            // Nothing is lost: the first request renders the same way and reports the error itself.
        }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = ContinuousClock.now
        var outcome = RequestOutcome()
        do {
            guard let compositor else {
                throw MetalCompositorError.noCompositor(setupError?.localizedDescription ?? "no setup error recorded")
            }
            guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
                throw MetalCompositorError.unexpectedInstruction(
                    String(describing: type(of: request.videoCompositionInstruction)))
            }
            let source: CVPixelBuffer
            if let delivered = request.sourceFrame(byTrackID: instruction.screenTrackID) {
                source = delivered
                let boxed = Unchecked(value: delivered)
                state.withLock { $0.heldFrame = boxed }
            } else if let last = state.withLock({ $0.heldFrame }) {
                source = last.value
                outcome.held = true
            } else {
                source = try blankSource(width: instruction.sourceWidth, height: instruction.sourceHeight)
                outcome.blank = true
            }
            guard let output = request.renderContext.newPixelBuffer() else { throw MetalCompositorError.noOutputBuffer }
            // The plan lays the frame out for the canvas it is asked about:
            // the output's size, which is the render context's.
            let canvas = CanvasSize(
                width: Double(CVPixelBufferGetWidth(output)), height: Double(CVPixelBufferGetHeight(output)))
            let frameState = instruction.plan.frameState(
                at: instruction.sourceTime(forCompositionTime: request.compositionTime), canvas: canvas)

            // The bubble needs both a placement (the plan was built with a
            // camera in its layout) and a camera track to draw from; its
            // frame is held across requests like the screen's.
            var camera: CameraBubbleFrame?
            if let placement = frameState.camera, instruction.hasCamera {
                let picture: CVPixelBuffer
                if let delivered = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
                    picture = delivered
                    let boxed = Unchecked(value: delivered)
                    state.withLock { $0.heldCameraFrame = boxed }
                } else if let last = state.withLock({ $0.heldCameraFrame }) {
                    picture = last.value
                    outcome.cameraHeld = true
                } else {
                    picture = try blankSource(width: Self.blankCameraSide, height: Self.blankCameraSide)
                    outcome.cameraBlank = true
                }
                camera = CameraBubbleFrame(
                    pixelBuffer: picture, placement: placement,
                    isMirrored: instruction.style.camera.mirrorsBuiltInCameras && instruction.cameraIsBuiltIn)
                outcome.cameraDrawn = true
            }

            let frame = SourceFrame(
                pixelBuffer: source,
                viewport: CameraViewport(origin: frameState.viewport.origin, size: frameState.viewport.size),
                contentCrop: CameraViewport(origin: frameState.contentCrop.origin, size: frameState.contentCrop.size),
                cursor: frameState.cursor, cursorSprite: instruction.cursorAtlas.sprite(for: frameState.cursorShape),
                sourcePixelsPerPoint: instruction.sourcePixelsPerPoint(forFrameWidth: CVPixelBufferGetWidth(source)),
                ripples: frameState.ripples, camera: camera, cardRect: frameState.layout.card)
            try compositor.render(frame, style: instruction.style, into: output)
            request.finish(withComposedVideoFrame: output)
            record(request, latency: Self.seconds(since: started), outcome: outcome)
        } catch {
            request.finish(with: error)
            outcome.failed = true
            record(request, latency: Self.seconds(since: started), outcome: outcome)
        }
    }

    /// Every request finishes inside `startRequest`, so nothing is pending;
    /// the engine calls this when a batch ends, which is the moment to let
    /// the texture cache recycle.
    public func cancelAllPendingVideoCompositionRequests() {
        flush()
    }

    // MARK: Owner's interface

    /// Lets the compositor's texture cache recycle its IOSurfaces; see
    /// `Compositor.flush()`. For the end of an export or a paused preview.
    public func flush() {
        compositor?.flush()
    }

    /// The counters, with the median computed from the kept samples at the
    /// time of the call (a sort of at most `latencySampleCapacity` values, so
    /// read it once per batch rather than per frame).
    public var statistics: MetalCompositorStatistics {
        state.withLock { state in
            var statistics = state.statistics
            let sorted = state.latencies.sorted()
            if !sorted.isEmpty {
                let middle = sorted.count / 2
                statistics.medianLatencySeconds =
                    sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            }
            return statistics
        }
    }

    /// Per-request latencies in seconds, in request order, up to
    /// `latencySampleCapacity` of them.
    public var requestLatencies: [Double] {
        state.withLock { $0.latencies }
    }

    /// The requests that had no source frame, in request order, up to
    /// `latencySampleCapacity` of them. The engine renders ahead of its
    /// consumer, so this, not the order frames come out, says which times
    /// were rendered from the held frame.
    public var missingSourceFrames: [MissingSourceFrame] {
        state.withLock { $0.missingSourceFrames }
    }

    // MARK: Private

    /// What one request did, for the counters.
    private struct RequestOutcome {
        var held = false
        var blank = false
        var cameraDrawn = false
        var cameraHeld = false
        var cameraBlank = false
        var failed = false
    }

    private func record(_ request: AVAsynchronousVideoCompositionRequest, latency: Double, outcome: RequestOutcome) {
        let time = request.compositionTime.seconds
        state.withLock { state in
            state.statistics.requests += 1
            if outcome.held { state.statistics.heldFrames += 1 }
            if outcome.blank { state.statistics.blankFrames += 1 }
            if outcome.cameraDrawn { state.statistics.cameraFrames += 1 }
            if outcome.cameraHeld { state.statistics.heldCameraFrames += 1 }
            if outcome.cameraBlank { state.statistics.blankCameraFrames += 1 }
            if outcome.failed { state.statistics.failures += 1 }
            state.statistics.totalLatencySeconds += latency
            state.statistics.maximumLatencySeconds = max(state.statistics.maximumLatencySeconds, latency)
            if state.latencies.count < Self.latencySampleCapacity {
                state.latencies.append(latency)
            }
            if outcome.held || outcome.blank, state.missingSourceFrames.count < Self.latencySampleCapacity {
                state.missingSourceFrames.append(
                    MissingSourceFrame(compositionTime: time, usedHeldFrame: outcome.held))
            }
        }
    }

    /// A transparent BGRA source of the given size, IOSurface-backed so the
    /// compositor can wrap it; made once per size. Rendered through the
    /// card it shows the background, never black.
    private func blankSource(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = SizeKey(width: max(width, 1), height: max(height, 1))
        return try state.withLock { state -> Unchecked<CVPixelBuffer> in
            if let cached = state.blankSources[key] { return cached }
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, key.width, key.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                &created)
            guard status == kCVReturnSuccess, let buffer = created else {
                throw MetalCompositorError.blankSource(status)
            }
            // A fresh IOSurface is not promised to be zeroed.
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let boxed = Unchecked(value: buffer)
            state.blankSources[key] = boxed
            return boxed
        }.value
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
