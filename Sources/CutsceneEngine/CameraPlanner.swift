import CutsceneCore
import Foundation

/// One frame of the auto-zoom camera.
public struct CameraSample: Sendable, Hashable {
    /// Seconds since the recording started.
    public var time: Double
    /// Center of the visible viewport, in frame coordinates.
    public var center: NormalizedPoint
    /// Magnification, never below 1. The viewport is `1 / amount` of the frame on each side.
    public var amount: Double
    /// 0 at rest, rising toward 1 inside a zoom segment and falling back after
    /// it. The third spring channel; renderers can drive secondary effects
    /// (cursor emphasis, blur strength) from it.
    public var activity: Double
    /// The center channel's own state, in travel space (0 = viewport flush
    /// with the left or top edge, 1 = flush with the right or bottom). `center`
    /// is derived from it and `amount`; it is exposed for tests and tooling.
    public var travel: NormalizedPoint
    /// Where the center channel was heading, in travel space. With `travel` it
    /// gives a test the spring's displacement, and so the acceleration the
    /// motion may show at this sample.
    public var travelTarget: NormalizedPoint

    public init(
        time: Double, center: NormalizedPoint, amount: Double, activity: Double, travel: NormalizedPoint,
        travelTarget: NormalizedPoint
    ) {
        self.time = time
        self.center = center
        self.amount = amount
        self.activity = activity
        self.travel = travel
        self.travelTarget = travelTarget
    }
}

/// A size as fractions of the frame.
public struct NormalizedSize: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The camera over a whole recording, sampled at a fixed rate from time zero.
/// Render time asks `viewport(at:)` which part of the frame to show.
public struct CameraTimeline: Sendable, Hashable {
    public let sampleRate: Double
    /// `samples[n].time == n / sampleRate`.
    public let samples: [CameraSample]

    public init(sampleRate: Double, samples: [CameraSample]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    /// Time of the last sample.
    public var duration: Double {
        samples.count > 1 ? Double(samples.count - 1) / sampleRate : 0
    }

    /// The camera at `time`, clamped to the timeline's range, interpolated
    /// linearly between neighbours. `nil` only for an empty timeline.
    public func sample(at time: Double) -> CameraSample? {
        guard let first = samples.first else { return nil }
        guard time > 0, samples.count > 1 else { return first }
        let scaled = time * sampleRate
        let lastIndex = samples.count - 1
        guard scaled < Double(lastIndex) else { return samples[lastIndex] }
        let index = Int(scaled)
        let fraction = scaled - Double(index)
        let a = samples[index]
        let b = samples[index + 1]
        return CameraSample(
            time: time,
            center: NormalizedPoint(
                x: Easing.lerp(a.center.x, b.center.x, fraction), y: Easing.lerp(a.center.y, b.center.y, fraction)),
            amount: Easing.lerp(a.amount, b.amount, fraction),
            activity: Easing.lerp(a.activity, b.activity, fraction),
            travel: NormalizedPoint(
                x: Easing.lerp(a.travel.x, b.travel.x, fraction), y: Easing.lerp(a.travel.y, b.travel.y, fraction)),
            travelTarget: NormalizedPoint(
                x: Easing.lerp(a.travelTarget.x, b.travelTarget.x, fraction),
                y: Easing.lerp(a.travelTarget.y, b.travelTarget.y, fraction)))
    }

    /// The part of the frame to show at `time`, origin at the top-left, in
    /// frame coordinates. Always inside `0...1`; the whole frame for an empty
    /// timeline.
    public func viewport(at time: Double) -> (origin: NormalizedPoint, size: NormalizedSize) {
        guard let sample = sample(at: time) else {
            return (NormalizedPoint(x: 0, y: 0), NormalizedSize(width: 1, height: 1))
        }
        return Self.viewport(center: sample.center, amount: sample.amount)
    }

    /// The viewport of a camera sample. Interpolating `center` and `amount`
    /// linearly keeps the result inside the frame (the feasible region is
    /// convex), so the clamp only absorbs rounding.
    public static func viewport(center: NormalizedPoint, amount: Double) -> (
        origin: NormalizedPoint, size: NormalizedSize
    ) {
        let side = 1 / max(amount, 1)
        let slack = 1 - side
        let origin = NormalizedPoint(
            x: min(max(center.x - side / 2, 0), slack),
            y: min(max(center.y - side / 2, 0), slack))
        return (origin, NormalizedSize(width: side, height: side))
    }
}

/// Every constant of the camera planner (research brief §5.4).
public struct CameraPlannerSettings: Sendable, Hashable {
    /// Output rate of the timeline. Must be positive and finite.
    public var sampleRate: Double = 120
    /// How often the spring targets are recomputed from the segments and the cursor.
    public var retargetInterval: Double = 0.008
    /// Constants shared by the center, amount and activity channels.
    public var spring: SpringParameters = .camera
    /// The dead zone's size as fractions of the *zoomed* viewport: the camera
    /// stays put while the cursor moves inside a box this large.
    public var deadZoneWidth: Double = 0.5
    public var deadZoneHeight: Double = 0.7
    /// While the amount is at most this, the center may jump: the viewport is
    /// the whole frame and nothing visible moves.
    public var preAimThreshold: Double = 1.0005
    /// Where the camera rests before the first segment.
    public var fallbackFocus = NormalizedPoint(x: 0.5, y: 0.5)

    public init() {}
}

/// Turns zoom segments and the smoothed cursor into camera motion.
///
/// Three spring channels (center, amount, activity) share one set of
/// constants and are retargeted every `retargetInterval` with their velocity
/// kept, so a target that changes mid-flight bends the motion instead of
/// restarting it. The center lives in *travel space*: 0 is the viewport flush
/// with the left or top edge, 1 flush with the right or bottom, so any value
/// in 0...1 is a viewport inside the frame, whatever the amount. That is what
/// keeps the viewport in frame by construction rather than by clamping the
/// rendered rectangle.
public struct CameraPlanner: Sendable {
    public var settings: CameraPlannerSettings

    public init(settings: CameraPlannerSettings = CameraPlannerSettings()) {
        self.settings = settings
    }

    /// Half the viewport's side at `amount`, as a fraction of the frame. A
    /// focus closer than this to an edge cannot be centred, so
    /// `travel(forFocus:amount:)` puts the viewport flush with that edge. The
    /// brief's `edge_snap_ratio 0.25` is this value at 2×; a fixed ratio
    /// centres the focus at that one amount only, and above 4× leaves it
    /// outside the viewport.
    public static func edgeSnapRatio(forAmount amount: Double) -> Double {
        0.5 / max(amount, 1)
    }

    /// Where the viewport must sit, in travel space, to centre `focus` at
    /// `amount`: with `r = edgeSnapRatio(forAmount:)`, `[r, 1 − r]` maps
    /// linearly to `[0, 1]` and the outer bands snap to the edges. At amount 1
    /// the viewport is the whole frame and the answer is the centre.
    public static func travel(forFocus focus: NormalizedPoint, amount: Double) -> NormalizedPoint {
        let ratio = edgeSnapRatio(forAmount: amount)
        let span = 1 - 2 * ratio
        guard span > 1e-9 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(x: Easing.clamp01((focus.x - ratio) / span), y: Easing.clamp01((focus.y - ratio) / span))
    }

    /// The viewport center in frame coordinates for a travel-space position and an amount.
    public static func center(travel: NormalizedPoint, amount: Double) -> NormalizedPoint {
        let side = 1 / max(amount, 1)
        return NormalizedPoint(x: travel.x * (1 - side) + side / 2, y: travel.y * (1 - side) + side / 2)
    }

    /// Simulates the camera over `0...duration` (by default, to the later of
    /// the cursor timeline's end and the latest segment end). Segments are
    /// sorted by start if they are not already; where they overlap, the one
    /// that started first wins. A duration that is not a finite, positive
    /// number gives the single sample at time zero.
    public func timeline(segments: [ZoomSegment], cursor: CursorTimeline, duration: Double? = nil) -> CameraTimeline {
        precondition(
            settings.sampleRate > 0 && settings.sampleRate.isFinite,
            "The camera sample rate must be positive and finite."
        )
        let segments = segments.sorted { $0.start < $1.start }
        let duration = duration ?? max(cursor.duration, segments.map(\.end).max() ?? 0)
        let sampleRate = settings.sampleRate
        let count = sampleCount(duration: duration, sampleRate: sampleRate)
        let interval =
            settings.retargetInterval > 0 && settings.retargetInterval.isFinite
            ? settings.retargetInterval : 1 / sampleRate
        let fullStep = SpringStep(parameters: settings.spring, dt: interval)

        var state = State(
            settings: settings, segments: segments, cursor: cursor,
            travel: Self.travel(forFocus: settings.fallbackFocus, amount: segments.first?.amount ?? 1))
        var retargets = 0
        state.retarget(at: 0)

        var samples: [CameraSample] = []
        samples.reserveCapacity(count)
        for n in 0..<count {
            let time = Double(n) / sampleRate
            // Retarget boundaries are multiples of the interval, counted rather
            // than accumulated so they do not drift over a long recording.
            while Double(retargets + 1) * interval <= time {
                state.step(fullStep)
                retargets += 1
                state.retarget(at: Double(retargets) * interval)
            }
            // The output time falls inside a retarget interval; the closed form
            // gives the exact state there without disturbing the simulation.
            var travel = state.travel
            var amount = state.amount
            var activity = state.activity
            let partial = time - Double(retargets) * interval
            if partial > 1e-12 {
                let partialStep = SpringStep(parameters: settings.spring, dt: partial)
                travel.step(partialStep)
                amount.step(partialStep)
                activity.step(partialStep)
                State.limit(travel: &travel, amount: &amount, activity: &activity)
            }
            samples.append(
                CameraSample(
                    time: time,
                    center: Self.center(travel: travel.position, amount: amount.position),
                    amount: amount.position, activity: activity.position, travel: travel.position,
                    travelTarget: travel.target))
        }
        return CameraTimeline(sampleRate: sampleRate, samples: samples)
    }
}

// MARK: - Simulation state

/// The three channels plus the bookkeeping the retarget step needs.
private struct State {
    let settings: CameraPlannerSettings
    let segments: [ZoomSegment]
    let cursor: CursorTimeline
    var travel: Spring2D
    var amount: Spring
    var activity: Spring
    var segmentIndex = 0
    var deadZone: DeadZone?

    init(settings: CameraPlannerSettings, segments: [ZoomSegment], cursor: CursorTimeline, travel: NormalizedPoint) {
        self.settings = settings
        self.segments = segments
        self.cursor = cursor
        self.travel = Spring2D(parameters: settings.spring, position: travel)
        self.amount = Spring(parameters: settings.spring, position: 1)
        self.activity = Spring(parameters: settings.spring, position: 0)
    }

    /// Recomputes the three targets for `time`.
    mutating func retarget(at time: Double) {
        while segmentIndex < segments.count, segments[segmentIndex].end < time {
            segmentIndex += 1
        }
        guard segmentIndex < segments.count, segments[segmentIndex].start <= time else {
            // Between segments: zoom out around the last framing.
            deadZone = nil
            amount.target = 1
            activity.target = 0
            return
        }
        let segment = segments[segmentIndex]
        let zoom = max(segment.amount, 1)
        if deadZone?.segmentIndex != segmentIndex {
            deadZone = DeadZone(segmentIndex: segmentIndex, around: segment.focus)
        }
        if let cursorPosition = cursor.smoothedPosition(at: time) {
            deadZone?.include(
                cursorPosition, maximumWidth: settings.deadZoneWidth / zoom,
                maximumHeight: settings.deadZoneHeight / zoom)
        }
        travel.target = CameraPlanner.travel(forFocus: deadZone?.center ?? segment.focus, amount: zoom)
        amount.target = zoom
        activity.target = 1
        if amount.position <= settings.preAimThreshold {
            travel.snapToTarget()
        }
    }

    /// Advances all channels and applies the hard limits.
    mutating func step(_ step: SpringStep) {
        travel.step(step)
        amount.step(step)
        activity.step(step)
        Self.limit(travel: &travel, amount: &amount, activity: &activity)
    }

    /// The hard limits: travel inside 0...1, amount at least 1, activity
    /// inside 0...1, each with its velocity zeroed when it hits a limit.
    static func limit(travel: inout Spring2D, amount: inout Spring, activity: inout Spring) {
        clamp(&travel.x, to: 0...1)
        clamp(&travel.y, to: 0...1)
        clamp(&amount, to: 1...Double.infinity)
        clamp(&activity, to: 0...1)
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

/// The greedy cursor cluster of the current segment: a bounding box that
/// grows while the cursor stays within the allowed size and restarts at the
/// cursor when it leaves. Its center is the camera's aim.
private struct DeadZone {
    let segmentIndex: Int
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double

    init(segmentIndex: Int, around point: NormalizedPoint) {
        self.segmentIndex = segmentIndex
        minX = point.x
        maxX = point.x
        minY = point.y
        maxY = point.y
    }

    var center: NormalizedPoint {
        NormalizedPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    mutating func include(_ point: NormalizedPoint, maximumWidth: Double, maximumHeight: Double) {
        let grownMinX = min(minX, point.x)
        let grownMaxX = max(maxX, point.x)
        let grownMinY = min(minY, point.y)
        let grownMaxY = max(maxY, point.y)
        if grownMaxX - grownMinX <= maximumWidth, grownMaxY - grownMinY <= maximumHeight {
            minX = grownMinX
            maxX = grownMaxX
            minY = grownMinY
            maxY = grownMaxY
        } else {
            minX = point.x
            maxX = point.x
            minY = point.y
            maxY = point.y
        }
    }
}
