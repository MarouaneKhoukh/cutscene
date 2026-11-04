import CutsceneCore
import Foundation

/// Every constant of the content mapper.
public struct ContentMapperSettings: Sendable, Hashable {
    /// Output rate of the crop timeline. Must be positive and finite. The
    /// camera's rate, so the two motions the renderer composes per frame are
    /// sampled alike.
    public var sampleRate: Double = 120
    /// The spring each edge of the crop follows. The camera spring, so a
    /// window that moves reads as a camera pan rather than a second kind of
    /// motion with its own feel.
    public var spring: SpringParameters = .camera
    /// Smallest width or height of the crop, as a fraction of the frame. A
    /// window reduced to a sliver (resized to its minimum, dragged almost off
    /// the display) would otherwise leave a crop with no pixels for the card
    /// and a zero to divide by in the layout.
    public var minimumSide: Double = 0.02

    public init() {}
}

/// Maps the captured surface onto the content the card shows.
///
/// A display or area recording fills its frame, so the crop is the identity.
/// A window recording on the `.displaySurface` strategy is a display-sized
/// surface with the window somewhere on it (ARCHITECTURE §2), and
/// ScreenCaptureKit attaches the window's `boundingRect` to every frame; the
/// mapper turns that per-frame rectangle, as `frames.jsonl` keeps it, into a
/// `ContentCropTimeline` so the card shows the window and nothing else. Each
/// edge of the crop is a `Spring` chasing that frame's edge, so a window that
/// moves or resizes stays framed and the card glides after it instead of
/// snapping, and a jump in the recorded rect (a window dragged quickly, a
/// resize in one step) is C1-continuous on screen. The springs run at a fixed
/// step; the hard limits (inside the frame, at least `minimumSide` a side)
/// zero an edge's velocity when they catch it, as the camera planner's do.
public struct ContentMapper: Sendable {
    public var settings: ContentMapperSettings

    public init(settings: ContentMapperSettings = ContentMapperSettings()) {
        self.settings = settings
    }

    /// The crop timeline of `manifest`'s recording: identity unless the
    /// source is a window. The surface's size in points comes from
    /// `content.captureRectPoints`, the frame a window recording measures,
    /// and the duration from the manifest unless given.
    public func cropTimeline(manifest: RecordingManifest, index: FrameIndex, duration: Double? = nil)
        -> ContentCropTimeline
    {
        let rect = manifest.content.captureRectPoints
        let frames = index.frames()
        return cropTimeline(
            source: manifest.source, frames: frames, surfaceSize: PointSize(width: rect.width, height: rect.height),
            duration: duration ?? manifest.duration ?? frames.last?.time ?? 0)
    }

    /// The crop timeline over `0...duration` for `frames`, which may arrive
    /// unsorted. Display and area sources, and a window recording whose
    /// frames carry no usable `boundingRect`, give the identity. A frame
    /// without a `contentRect` measures the surface as `surfaceSize` points.
    public func cropTimeline(
        source: CaptureSource, frames: [FrameIndexEntry], surfaceSize: PointSize, duration: Double
    ) -> ContentCropTimeline {
        guard case .window = source else { return .identity }
        precondition(
            settings.sampleRate > 0 && settings.sampleRate.isFinite,
            "The content mapper sample rate must be positive and finite."
        )
        let frames = Self.sortedByTime(frames)
        let targets = frames.map {
            Edges(target: Self.target(for: $0, surfaceSize: surfaceSize), minimumSide: settings.minimumSide)
        }
        // The window's place when the take starts is where the crop starts: a
        // spring flying in from the whole surface would open every window
        // recording with a zoom nobody asked for.
        guard let first = targets.lazy.compactMap({ $0 }).first else { return .identity }
        let sampleRate = settings.sampleRate
        let count = sampleCount(duration: duration, sampleRate: sampleRate)
        let step = SpringStep(parameters: settings.spring, dt: 1 / sampleRate)
        var state = State(parameters: settings.spring, edges: first, minimumSide: settings.minimumSide)
        var next = 0
        var samples: [ContentCropSample] = []
        samples.reserveCapacity(count)
        for n in 0..<count {
            let time = Double(n) / sampleRate
            // The step covers the interval up to this sample, under the
            // target in force during it; only then does the newest frame at
            // or before the sample set the target, so a frame moves the crop
            // from its own time on, not a sample early. A frame whose rect is
            // unusable (the window hidden) keeps the last one, so the framing
            // holds until the window is back.
            if n > 0 {
                state.step(step)
            }
            while next < frames.count, frames[next].time <= time {
                if let target = targets[next] {
                    state.retarget(target)
                }
                next += 1
            }
            samples.append(ContentCropSample(time: time, crop: state.crop))
        }
        return ContentCropTimeline(sampleRate: sampleRate, samples: samples)
    }

    /// The crop one frame asks for, as a fraction of the frame: its
    /// `boundingRect` within the surface, which is the frame's `contentRect`
    /// when it carries one and otherwise `surfaceSize` points at the origin,
    /// cut to the surface. Nil when the frame has no bounding rect, or the
    /// rect is not finite or has no area within the surface (the window
    /// minimised or dragged off the display), so the caller keeps the last
    /// usable crop.
    public static func target(for frame: FrameIndexEntry, surfaceSize: PointSize) -> Viewport? {
        guard let bounding = frame.boundingRect else { return nil }
        let surface = frame.contentRect ?? PointRect(x: 0, y: 0, width: surfaceSize.width, height: surfaceSize.height)
        guard surface.width > 0, surface.height > 0, surface.width.isFinite, surface.height.isFinite else { return nil }
        let left = max((bounding.x - surface.x) / surface.width, 0)
        let top = max((bounding.y - surface.y) / surface.height, 0)
        let right = min((bounding.x + bounding.width - surface.x) / surface.width, 1)
        let bottom = min((bounding.y + bounding.height - surface.y) / surface.height, 1)
        guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite, right > left, bottom > top else {
            return nil
        }
        return Viewport(
            origin: NormalizedPoint(x: left, y: top), size: NormalizedSize(width: right - left, height: bottom - top))
    }

    /// Reorders by time, keeping equal times in file order; the index is the
    /// tie-breaker because `sort` makes no stability promise. The writer
    /// appends in time order, so this is one pass for a real index.
    private static func sortedByTime(_ frames: [FrameIndexEntry]) -> [FrameIndexEntry] {
        var isSorted = true
        for index in frames.indices.dropFirst() where frames[index - 1].time > frames[index].time {
            isSorted = false
            break
        }
        if isSorted { return frames }
        return frames.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }
}

// MARK: - Simulation

/// The four edges of a crop, as fractions of the frame.
private struct Edges {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    /// A target with the mapper's size floor applied: a side under
    /// `minimumSide` grows around its centre and is pushed back inside the
    /// frame, so every target the springs chase is itself a legal crop and
    /// the hard limits only ever absorb a spring's overshoot.
    init?(target: Viewport?, minimumSide: Double) {
        guard let target else { return nil }
        let minimum = min(max(minimumSide, 0), 1)
        var left = target.origin.x
        var right = target.origin.x + target.size.width
        var top = target.origin.y
        var bottom = target.origin.y + target.size.height
        Self.widen(&left, &right, to: minimum)
        Self.widen(&top, &bottom, to: minimum)
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    private static func widen(_ low: inout Double, _ high: inout Double, to minimum: Double) {
        guard high - low < minimum else { return }
        let center = (low + high) / 2
        low = center - minimum / 2
        high = center + minimum / 2
        if low < 0 {
            high -= low
            low = 0
        } else if high > 1 {
            low -= high - 1
            high = 1
        }
    }
}

/// Four edge springs plus the hard limits.
private struct State {
    var left: Spring
    var top: Spring
    var right: Spring
    var bottom: Spring
    let minimumSide: Double

    init(parameters: SpringParameters, edges: Edges, minimumSide: Double) {
        left = Spring(parameters: parameters, position: edges.left)
        top = Spring(parameters: parameters, position: edges.top)
        right = Spring(parameters: parameters, position: edges.right)
        bottom = Spring(parameters: parameters, position: edges.bottom)
        self.minimumSide = min(max(minimumSide, 0), 1)
    }

    var crop: Viewport {
        Viewport(
            origin: NormalizedPoint(x: left.position, y: top.position),
            size: NormalizedSize(width: right.position - left.position, height: bottom.position - top.position))
    }

    /// Aims every edge at `edges`, keeping its velocity, so a target that
    /// changes mid-flight bends the motion instead of restarting it.
    mutating func retarget(_ edges: Edges) {
        left.target = edges.left
        top.target = edges.top
        right.target = edges.right
        bottom.target = edges.bottom
    }

    /// Advances every edge and applies the hard limits: inside the frame,
    /// and at least `minimumSide` apart. A caught edge has its velocity
    /// zeroed, as a wall does; with every target a legal crop, this only
    /// absorbs the under-damped spring's overshoot of a few 1e-4.
    mutating func step(_ step: SpringStep) {
        left.step(step)
        top.step(step)
        right.step(step)
        bottom.step(step)
        Self.limit(&left, &right, minimumSide: minimumSide)
        Self.limit(&top, &bottom, minimumSide: minimumSide)
    }

    private static func limit(_ low: inout Spring, _ high: inout Spring, minimumSide: Double) {
        clamp(&low, to: 0...1)
        clamp(&high, to: 0...1)
        guard high.position - low.position < minimumSide else { return }
        if low.position + minimumSide <= 1 {
            high.position = low.position + minimumSide
            high.velocity = 0
        } else {
            high.position = 1
            high.velocity = 0
            low.position = 1 - minimumSide
            low.velocity = 0
        }
    }

    private static func clamp(_ spring: inout Spring, to range: ClosedRange<Double>) {
        if spring.position < range.lowerBound {
            spring.position = range.lowerBound
            spring.velocity = 0
        } else if spring.position > range.upperBound {
            spring.position = range.upperBound
            spring.velocity = 0
        }
    }
}
