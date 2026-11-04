import CutsceneCore
import Foundation

/// The part of the frame one rendered frame shows, origin at the top-left, in
/// frame coordinates; what `CameraTimeline.viewport(at:)` returns, as a value
/// a `FrameState` can be compared by. `CutsceneRender.CameraViewport` has the
/// same shape and predates this type.
public struct Viewport: Sendable, Hashable {
    public var origin: NormalizedPoint
    public var size: NormalizedSize

    public init(origin: NormalizedPoint, size: NormalizedSize) {
        self.origin = origin
        self.size = size
    }

    /// From what `CameraTimeline.viewport(at:)` returns.
    public init(_ viewport: (origin: NormalizedPoint, size: NormalizedSize)) {
        self.init(origin: viewport.origin, size: viewport.size)
    }

    /// The whole frame.
    public static let full = Viewport(origin: NormalizedPoint(x: 0, y: 0), size: NormalizedSize(width: 1, height: 1))

    /// Width over height, as fractions of the frame; multiplied by the
    /// frame's own aspect it gives the visible slice's. Zero for no height.
    public var aspectRatio: Double {
        size.height > 0 ? size.width / size.height : 0
    }
}

/// How fast the viewport is moving, in frame widths and heights per second,
/// carried for motion blur: a point at viewport-relative position `p` samples
/// the source at `origin + p × size`, so its on-screen speed is
/// `(originX, originY) + p × (width, height)`.
public struct ViewportVelocity: Sendable, Hashable {
    /// Rate of change of `Viewport.origin`; negative while the viewport moves left or up.
    public var originX: Double
    public var originY: Double
    /// Rate of change of `Viewport.size`; negative while zooming in.
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// A viewport at rest.
    public static let zero = ViewportVelocity(originX: 0, originY: 0, width: 0, height: 0)
}

/// The moment the recorded cursor image switched to `shape`; the renderer
/// draws `shape` from then until the next change.
public struct CursorShapeChange: Sendable, Hashable {
    /// Seconds since the recording started.
    public var time: Double
    public var shape: CursorShape

    public init(time: Double, shape: CursorShape) {
        self.time = time
        self.shape = shape
    }
}

// MARK: - Content crop

/// One frame of the content crop: the part of the captured frame that is the
/// content, in frame coordinates. The viewport then selects a part of it, so
/// a screen pixel is read at `crop.origin + (viewport.origin + p ×
/// viewport.size) × crop.size` (ARCHITECTURE §5); the crop is a `Viewport`
/// because it is the same shape in the same space.
public struct ContentCropSample: Sendable, Hashable {
    /// Seconds since the recording started.
    public var time: Double
    public var crop: Viewport

    public init(time: Double, crop: Viewport) {
        self.time = time
        self.crop = crop
    }
}

/// The content crop over a whole recording, sampled at a fixed rate from time
/// zero like the cursor and camera timelines. `identity` is the whole frame
/// at every time, what display and area recordings use; a window recording's
/// mapper (`ContentMapper`, M2-02) produces one that follows the window.
public struct ContentCropTimeline: Sendable, Hashable {
    public let sampleRate: Double
    /// `samples[n].time == n / sampleRate`; empty for the identity.
    public let samples: [ContentCropSample]

    public init(sampleRate: Double, samples: [ContentCropSample]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    /// The whole frame at every time.
    public static let identity = ContentCropTimeline(sampleRate: 1, samples: [])

    /// Whether the crop is the whole frame throughout.
    public var isIdentity: Bool {
        samples.isEmpty
    }

    /// The crop at `time`, clamped to the timeline's range, interpolated
    /// linearly between neighbours; the whole frame for the identity.
    public func crop(at time: Double) -> Viewport {
        guard let first = samples.first else { return .full }
        guard time > 0, samples.count > 1 else { return first.crop }
        let scaled = time * sampleRate
        let lastIndex = samples.count - 1
        guard scaled < Double(lastIndex) else { return samples[lastIndex].crop }
        let index = Int(scaled)
        let fraction = scaled - Double(index)
        let a = samples[index].crop
        let b = samples[index + 1].crop
        return Viewport(
            origin: NormalizedPoint(
                x: Easing.lerp(a.origin.x, b.origin.x, fraction), y: Easing.lerp(a.origin.y, b.origin.y, fraction)),
            size: NormalizedSize(
                width: Easing.lerp(a.size.width, b.size.width, fraction),
                height: Easing.lerp(a.size.height, b.size.height, fraction)))
    }
}

// MARK: - Frame state

/// Everything the renderer needs to compose one output frame, read from a
/// `RenderPlan` at the frame's time for one canvas.
public struct FrameState: Sendable, Hashable {
    /// The card and the bubble on the canvas, in canvas pixels.
    public var layout: FrameLayout
    /// Which part of the captured frame is the content; the whole frame
    /// except in window mode.
    public var contentCrop: Viewport
    /// Which part of the content fills the card.
    public var viewport: Viewport
    /// How fast `viewport` is moving at this moment.
    public var viewportVelocity: ViewportVelocity
    /// The smoothed cursor; nil draws none.
    public var cursor: CursorSample?
    /// The cursor image in effect; nil before the first recorded change (or
    /// when the recorder wrote none), which the renderer draws as the arrow.
    public var cursorShape: CursorShape?
    /// The click rings alive now, oldest first, their pixel values in canvas
    /// pixels and their centres in frame coordinates like the cursor.
    public var ripples: [Ripple]
    /// Where the camera bubble goes; nil when the plan has no camera. The
    /// same value as `layout.bubble`, named for what the renderer asks.
    public var camera: BubblePlacement?

    public init(
        layout: FrameLayout, contentCrop: Viewport, viewport: Viewport, viewportVelocity: ViewportVelocity,
        cursor: CursorSample?, cursorShape: CursorShape?, ripples: [Ripple], camera: BubblePlacement?
    ) {
        self.layout = layout
        self.contentCrop = contentCrop
        self.viewport = viewport
        self.viewportVelocity = viewportVelocity
        self.cursor = cursor
        self.cursorShape = cursorShape
        self.ripples = ripples
        self.camera = camera
    }
}

// MARK: - Plan

/// The effects of a whole recording, planned once and read per frame.
///
/// A plan is an immutable value: the editor rebuilds one off the main actor
/// after every edit and swaps it in, and preview and export read the same plan
/// concurrently without sharing anything mutable. `build` composes the existing
/// planners, so the plan depends only on the log, the duration and the
/// settings: the same inputs give the same plan and the same `FrameState`s.
public struct RenderPlan: Sendable, Hashable {
    /// The smoothed cursor at `CursorSmootherSettings.sampleRate`.
    public let cursor: CursorTimeline
    /// Sorted, non-overlapping; the input of the camera planner, kept for the
    /// editor's zoom track and debug overlay.
    public let zoomSegments: [ZoomSegment]
    /// The camera at `CameraPlannerSettings.sampleRate`.
    public let camera: CameraTimeline
    /// Every recorded cursor-shape change, in time order; equal times keep the
    /// log's order so the later row wins, as it did on screen.
    public let cursorShapeChanges: [CursorShapeChange]
    /// The clicks and the ripple settings they are drawn with.
    public let clickEffects: ClickEffects
    /// The card, bubble and padding rules the frames are laid out with.
    public let layoutSettings: LayoutSettings
    /// Which part of the captured frame is the content, over time.
    public let contentCrop: ContentCropTimeline
    /// Width over height of the captured frame, what the card's aspect
    /// starts from; `build` reads it from the log's capture rect.
    public let sourceAspectRatio: Double
    /// Seconds the plan covers. Never negative, NaN or infinite: a duration
    /// that is none of a finite, positive number plans as zero, the single
    /// sample at time zero that each planner produces for it.
    public let duration: Double

    /// Assembles a plan from parts already computed. `cursorShapeChanges` may
    /// arrive in any order; they are sorted by time (equal times keeping their
    /// order) and a change with a non-finite time is dropped, since it has no
    /// place in time order and would break the lookup for every other one. A
    /// `sourceAspectRatio` that is not a finite positive number falls back to
    /// `layoutSettings.fallbackContentAspectRatio`.
    public init(
        cursor: CursorTimeline, zoomSegments: [ZoomSegment], camera: CameraTimeline,
        cursorShapeChanges: [CursorShapeChange], duration: Double,
        clickEffects: ClickEffects = ClickEffects(clicks: []),
        layoutSettings: LayoutSettings = LayoutSettings(), contentCrop: ContentCropTimeline = .identity,
        sourceAspectRatio: Double = CanvasSize.hd1080.aspectRatio
    ) {
        self.cursor = cursor
        self.zoomSegments = zoomSegments
        self.camera = camera
        self.cursorShapeChanges = Self.sortedByTime(cursorShapeChanges.filter { $0.time.isFinite })
        self.duration = Self.plannable(duration)
        self.clickEffects = clickEffects
        self.layoutSettings = layoutSettings
        self.contentCrop = contentCrop
        self.sourceAspectRatio =
            sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? sourceAspectRatio : layoutSettings.fallbackContentAspectRatio
    }

    /// Plans `log` over `0...duration` seconds with the three planners in
    /// their pipeline order: cursor, zoom segments, camera; the clicks, the
    /// layout rules and the crop ride along for `frameState(at:canvas:)`.
    /// Nonisolated and returning a `sending` value so an editor can run it
    /// off the main actor and hand the result to whichever actor renders.
    public nonisolated static func build(
        log: EventLog, duration: Double, cursor: CursorSmootherSettings = CursorSmootherSettings(),
        zoom: ZoomPlannerSettings = ZoomPlannerSettings(), camera: CameraPlannerSettings = CameraPlannerSettings(),
        ripples: ClickRippleSettings = ClickRippleSettings(), layout: LayoutSettings = LayoutSettings(),
        contentCrop: ContentCropTimeline = .identity
    ) -> sending RenderPlan {
        let duration = plannable(duration)
        let planningLog = contentSpace(log, crop: contentCrop)
        let segments = ZoomPlanner(settings: zoom).plan(planningLog, recordingEnd: duration)
        return build(
            log: log, planningLog: planningLog, duration: duration, segments: segments, cursor: cursor,
            camera: camera, ripples: ripples, layout: layout, contentCrop: contentCrop)
    }

    /// Plans `log` around the segments of an edited zoom track instead of a
    /// fresh automatic plan: what the editor builds after the user has moved,
    /// locked or added segments (`ZoomTrackMerge.segments(of:)` picks them).
    /// The track's focus points are in frame coordinates (the editor aims a
    /// segment at the smoothed cursor); in window mode each is moved into
    /// content space through the crop at the segment's start.
    public nonisolated static func build(
        log: EventLog, duration: Double, zoomTrack: ZoomTrack,
        cursor: CursorSmootherSettings = CursorSmootherSettings(),
        camera: CameraPlannerSettings = CameraPlannerSettings(), ripples: ClickRippleSettings = ClickRippleSettings(),
        layout: LayoutSettings = LayoutSettings(), contentCrop: ContentCropTimeline = .identity
    ) -> sending RenderPlan {
        let segments = ZoomTrackMerge.segments(of: zoomTrack).map { segment in
            var moved = segment
            moved.focus = contentSpace(segment.focus, crop: contentCrop.crop(at: segment.start))
            return moved
        }
        return build(
            log: log, planningLog: contentSpace(log, crop: contentCrop), duration: plannable(duration),
            segments: segments, cursor: cursor, camera: camera, ripples: ripples, layout: layout,
            contentCrop: contentCrop)
    }

    /// `build(log:duration:zoomTrack:…)` with every setting taken from `kit`
    /// and the bubble laid out when the recording has a camera: what the
    /// editor plans a project's `style` and `timeline.zoom` with.
    public nonisolated static func build(
        log: EventLog, duration: Double, zoomTrack: ZoomTrack, kit: BrandKit, hasCamera: Bool,
        contentCrop: ContentCropTimeline = .identity
    ) -> sending RenderPlan {
        build(
            log: log, duration: duration, zoomTrack: zoomTrack, cursor: CursorSmootherSettings(kit: kit),
            camera: CameraPlannerSettings(kit: kit), ripples: ClickRippleSettings(kit: kit),
            layout: LayoutSettings(kit: kit, hasCamera: hasCamera), contentCrop: contentCrop)
    }

    /// The common tail of the builds: the cursor and camera planners around
    /// segments already decided, plus the shape changes and clicks read from
    /// the log. `duration` is already plannable.
    ///
    /// Two spaces meet here. The renderer applies the camera viewport inside
    /// the content crop (ARCHITECTURE §5: a pixel is read at `crop.origin +
    /// (viewport.origin + p × viewport.size) × crop.size`), so the camera is
    /// planned in content space: from `planningLog`, the log with every
    /// position moved through the crop of its moment, and from `segments`
    /// whose focus is in that space too. The cursor and the ripples are drawn
    /// through the same crop, so the cursor timeline the renderer reads stays
    /// in frame space, from `log` itself. Both logs are the same value when
    /// the crop is the identity, and then one smoothing serves both.
    private nonisolated static func build(
        log: EventLog, planningLog: EventLog, duration: Double, segments: [ZoomSegment],
        cursor: CursorSmootherSettings, camera: CameraPlannerSettings, ripples: ClickRippleSettings,
        layout: LayoutSettings, contentCrop: ContentCropTimeline
    ) -> sending RenderPlan {
        let smoother = CursorSmoother(settings: cursor)
        let cursorTimeline = smoother.timeline(for: log, duration: duration)
        let planningCursor =
            planningLog == log ? cursorTimeline : smoother.timeline(for: planningLog, duration: duration)
        let cameraTimeline = CameraPlanner(settings: camera)
            .timeline(segments: segments, cursor: planningCursor, duration: duration)
        // Changes past `duration` are kept: they cost nothing, and a plan
        // trimmed shorter than its log still answers for every time it is asked.
        var changes: [CursorShapeChange] = []
        for case .cursorShapeChanged(let time, let shape) in log.events {
            changes.append(CursorShapeChange(time: time, shape: shape))
        }
        let capture = log.captureRectPoints
        return RenderPlan(
            cursor: cursorTimeline, zoomSegments: segments, camera: cameraTimeline, cursorShapeChanges: changes,
            duration: duration, clickEffects: ClickEffects(log: log, settings: ripples), layoutSettings: layout,
            contentCrop: contentCrop, sourceAspectRatio: capture.height > 0 ? capture.width / capture.height : 0)
    }

    /// What to draw at `time` on the reference 1920×1080 canvas:
    /// `frameState(at:canvas:)` for `CanvasSize.hd1080`, kept for callers
    /// that lay the card out themselves.
    public func frameState(at time: Double) -> FrameState {
        frameState(at: time, canvas: .hd1080)
    }

    /// What to draw at `time` on `canvas`. Outside `0...duration` the
    /// timelines hold their end samples, so a frame asked for slightly past
    /// the end (export rounding) renders the last state rather than nothing.
    /// The layout is solved here because the visible content's aspect (the
    /// source's times the crop's times the viewport's) changes with time in
    /// window mode; the ripples are scaled from their reference height to the
    /// canvas's shorter side, the rule `RenderStyle(kit:canvas:)` and
    /// `LayoutSolver` apply to the kit's other pixel values, so a 9:16 or
    /// 1:1 export, whose card is as wide as the 16:9 one is tall, draws them
    /// at the 16:9 size.
    public func frameState(at time: Double, canvas: CanvasSize) -> FrameState {
        let viewport = Viewport(camera.viewport(at: time))
        let crop = contentCrop.crop(at: time)
        let layout = LayoutSolver.solve(
            canvas: canvas, contentAspectRatio: sourceAspectRatio * crop.aspectRatio * viewport.aspectRatio,
            settings: layoutSettings)
        let reference = clickEffects.settings.referenceHeight
        let shorterSide = min(canvas.width, canvas.height)
        let rippleScale = reference.isFinite && reference > 0 && shorterSide.isFinite ? shorterSide / reference : 1
        return FrameState(
            layout: layout, contentCrop: crop, viewport: viewport, viewportVelocity: viewportVelocity(at: time),
            cursor: cursor.sample(at: time), cursorShape: cursorShape(at: time),
            ripples: clickEffects.ripples(at: time).map { $0.scaled(by: rippleScale) }, camera: layout.bubble)
    }

    /// The cursor image in effect at `time`: the last change at or before it,
    /// nil before the first. A binary search, since the renderer asks once per
    /// frame and a long recording holds thousands of changes.
    public func cursorShape(at time: Double) -> CursorShape? {
        var low = cursorShapeChanges.startIndex
        var high = cursorShapeChanges.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if cursorShapeChanges[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > cursorShapeChanges.startIndex ? cursorShapeChanges[low - 1].shape : nil
    }

    /// The viewport's velocity at `time`: the mean velocity of the viewport
    /// `CameraTimeline.viewport(at:)` interpolates across the camera sample
    /// interval containing `time`, so the motion a renderer sees between two
    /// camera samples and the velocity it is told agree. Zero before time zero
    /// and from the last sample on, where the camera holds still.
    public func viewportVelocity(at time: Double) -> ViewportVelocity {
        let samples = camera.samples
        guard time > 0, samples.count > 1 else { return .zero }
        let scaled = time * camera.sampleRate
        let lastIndex = samples.count - 1
        guard scaled < Double(lastIndex) else { return .zero }
        let index = Int(scaled)
        let from = CameraTimeline.viewport(center: samples[index].center, amount: samples[index].amount)
        let to = CameraTimeline.viewport(center: samples[index + 1].center, amount: samples[index + 1].amount)
        let rate = camera.sampleRate
        return ViewportVelocity(
            originX: (to.origin.x - from.origin.x) * rate, originY: (to.origin.y - from.origin.y) * rate,
            width: (to.size.width - from.size.width) * rate, height: (to.size.height - from.size.height) * rate)
    }

    /// The duration the planners can work with; see `duration`.
    private static func plannable(_ duration: Double) -> Double {
        duration.isFinite && duration > 0 ? duration : 0
    }

    // MARK: Content space

    /// `log` with every position moved from frame coordinates into content
    /// space through the crop at the event's time; `log` itself when the
    /// crop is the identity, so the identity costs nothing.
    public static func contentSpace(_ log: EventLog, crop: ContentCropTimeline) -> EventLog {
        guard !crop.isIdentity else { return log }
        var moved = log
        moved.removeAllEvents()
        moved.append(
            contentsOf: log.events.map { event in
                switch event {
                case .pointerMoved(let time, let position, let global):
                    .pointerMoved(
                        time: time, position: contentSpace(position, crop: crop.crop(at: time)), global: global)
                case .buttonDown(let time, let position, let button, let global):
                    .buttonDown(
                        time: time, position: contentSpace(position, crop: crop.crop(at: time)), button: button,
                        global: global)
                case .buttonUp(let time, let position, let button, let global):
                    .buttonUp(
                        time: time, position: contentSpace(position, crop: crop.crop(at: time)), button: button,
                        global: global)
                case .scroll(let time, let position, let deltaX, let deltaY, let phase, let global):
                    .scroll(
                        time: time, position: contentSpace(position, crop: crop.crop(at: time)), deltaX: deltaX,
                        deltaY: deltaY, phase: phase, global: global)
                case .keyDown, .keyUp, .cursorShapeChanged, .takeMarker, .focus, .geometry, .unknown:
                    event
                }
            })
        return moved
    }

    /// `position` (frame coordinates) as a fraction of `crop`, clamped to the
    /// content: a pointer outside the window aims the camera at the nearest
    /// edge rather than past it, so the inside-frame invariant holds.
    public static func contentSpace(_ position: NormalizedPoint, crop: Viewport) -> NormalizedPoint {
        func axis(_ value: Double, origin: Double, size: Double) -> Double {
            guard size.isFinite, size > 0 else { return value }
            return min(max((value - origin) / size, 0), 1)
        }
        return NormalizedPoint(
            x: axis(position.x, origin: crop.origin.x, size: crop.size.width),
            y: axis(position.y, origin: crop.origin.y, size: crop.size.height))
    }

    /// Reorders by time while keeping equal times in their original order; the
    /// index is the tie-breaker because `sort` makes no stability promise.
    private static func sortedByTime(_ changes: [CursorShapeChange]) -> [CursorShapeChange] {
        var isSorted = true
        for index in changes.indices.dropFirst() where changes[index - 1].time > changes[index].time {
            isSorted = false
            break
        }
        if isSorted { return changes }
        return changes.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }
}
