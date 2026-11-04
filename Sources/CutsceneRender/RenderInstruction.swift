import AVFoundation
import CoreMedia
import CutsceneCore
import CutsceneEngine
import Foundation

/// One kept range of a recording as a video composition instruction: the
/// plan, style and sprites `MetalCompositor` renders with, and the mapping
/// from composition time back to recording time, which is what the plan is
/// indexed by.
///
/// Immutable once built, so the composition engine may hand it to any queue;
/// `@unchecked` only because `NSObject` is not `Sendable`.
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    /// The instruction's span on the composition timeline.
    public let timeRange: CMTimeRange
    /// The recording time at `timeRange.start`; the kept range's start.
    public let sourceStart: CMTime
    /// The composition track that carries the screen movie.
    public let screenTrackID: CMPersistentTrackID
    public let plan: RenderPlan
    public let style: RenderStyle
    public let cursorAtlas: CursorAtlas
    /// The screen movie's frame size, in pixels, for a frame rendered before
    /// any source frame exists.
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// The captured area in display points; with a frame's pixel width it
    /// gives the source pixels per point the cursor is sized by.
    public let capturePointSize: PointSize
    /// The composition track that carries the camera movie;
    /// `kCMPersistentTrackID_Invalid` when the recording has no camera.
    public let cameraTrackID: CMPersistentTrackID
    /// Whether the camera is a built-in one (`CameraTrackInfo.isBuiltIn`),
    /// which the style's `camera.mirrorsBuiltInCameras` decides mirroring by.
    public let cameraIsBuiltIn: Bool

    public init(
        timeRange: CMTimeRange, sourceStart: CMTime, screenTrackID: CMPersistentTrackID, plan: RenderPlan,
        style: RenderStyle, cursorAtlas: CursorAtlas, sourceWidth: Int, sourceHeight: Int, capturePointSize: PointSize,
        cameraTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid, cameraIsBuiltIn: Bool = false
    ) {
        self.timeRange = timeRange
        self.sourceStart = sourceStart
        self.screenTrackID = screenTrackID
        self.plan = plan
        self.style = style
        self.cursorAtlas = cursorAtlas
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.capturePointSize = capturePointSize
        self.cameraTrackID = cameraTrackID
        self.cameraIsBuiltIn = cameraIsBuiltIn
        super.init()
    }

    /// Whether a camera track feeds this instruction's bubble.
    public var hasCamera: Bool { cameraTrackID != kCMPersistentTrackID_Invalid }

    // MARK: AVVideoCompositionInstructionProtocol

    /// The frames are composed from scratch; nothing is post-processed.
    public var enablePostProcessing: Bool { false }

    /// The camera and cursor move between any two composition times, so the
    /// engine must not reuse a frame rendered for another time.
    public var containsTweening: Bool { true }

    /// The screen and, when there is one, the camera: the engine decodes and
    /// delivers only the tracks listed here.
    public var requiredSourceTrackIDs: [NSValue]? {
        hasCamera ? [NSNumber(value: screenTrackID), NSNumber(value: cameraTrackID)] : [NSNumber(value: screenTrackID)]
    }

    public var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    // MARK: Time mapping

    /// Seconds on the recording timeline for a composition time inside
    /// `timeRange`: the kept range runs at its natural rate, so the offset
    /// from the instruction's start is the offset from the range's start.
    public func sourceTime(forCompositionTime time: CMTime) -> Double {
        CMTimeAdd(sourceStart, CMTimeSubtract(time, timeRange.start)).seconds
    }

    /// What to draw at a composition time.
    public func frameState(atCompositionTime time: CMTime) -> FrameState {
        plan.frameState(at: sourceTime(forCompositionTime: time))
    }

    /// Source pixels per captured point for a frame `pixelWidth` wide:
    /// `SourceFrame.sourcePixelsPerPoint`, taken from the frame rather than
    /// the display's scale because a stream scaled below native pixels has
    /// fewer pixels per point than the display.
    public func sourcePixelsPerPoint(forFrameWidth pixelWidth: Int) -> Double {
        guard pixelWidth > 0, capturePointSize.width > 0 else { return 1 }
        return Double(pixelWidth) / capturePointSize.width
    }
}
