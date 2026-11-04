import CutsceneCore
import CutsceneEngine
import Foundation

/// `ContentMapper` checks: display and area sources map to the identity crop,
/// and a window source's per-frame `BoundingRect` from `frames.jsonl`,
/// smoothed with the camera spring, yields a `ContentCropTimeline` that stays
/// C1-continuous and inside the frame across a synthetic 0.2 window jump
/// (PLAN M2-02). Registered empty by M2-00 so `main.swift` is edited once per
/// milestone rather than once per task; the owning task fills the body and
/// reports through the shared checker so the pass count stays one number.
@MainActor
func runContentMapperChecks(_ checker: Checker) {
    checkMapperDefaults(checker)
    checkIdentitySources(checker)
    checkFrameTargets(checker)
    checkWindowJump(checker)
    checkWindowResize(checker)
    checkHiddenAndOffscreenWindow(checker)
    checkMapperDeterminism(checker)
    checkManifestConvenience(checker)
}

// MARK: - Fixtures

/// The synthetic surface: a 1920×1080 display in points, so a rect in points
/// reads as a fraction of the frame by inspection.
private let surface = PointSize(width: 1920, height: 1080)
private let surfaceRect = PointRect(x: 0, y: 0, width: 1920, height: 1080)
/// The window at the start: (0.1, 0.1) with 0.4 × 0.4 of the frame.
private let windowAtStart = PointRect(x: 192, y: 108, width: 768, height: 432)
private let windowSource = CaptureSource.window(
    WindowSource(
        windowID: 42, title: "brief.md", bundleID: "com.apple.Terminal", applicationName: "Terminal",
        frame: windowAtStart, strategy: .displaySurface))
private let indexRate = 60.0

/// A 60 fps index over `duration` seconds whose window rect at each frame is
/// `rect(time)`; nil leaves the frame without a bounding rect, as the sparse
/// writer does for an unchanged value before `frames()` carries it forward.
private func syntheticIndex(duration: Double, rect: (Double) -> PointRect?) -> [FrameIndexEntry] {
    (0...Int(duration * indexRate)).map { n in
        let time = Double(n) / indexRate
        return FrameIndexEntry(
            number: n, time: time, displayTime: time - 0.016, status: .complete, contentRect: surfaceRect,
            contentScale: 1, scaleFactor: 2, screenRect: surfaceRect, boundingRect: rect(time))
    }
}

/// `rect` as a fraction of the surface, cut to it, with the size taken as
/// right minus left so the expectation rounds the way the mapper's edge
/// springs do.
private func crop(_ rect: PointRect) -> Viewport {
    let left = max(rect.x / surface.width, 0)
    let top = max(rect.y / surface.height, 0)
    let right = min((rect.x + rect.width) / surface.width, 1)
    let bottom = min((rect.y + rect.height) / surface.height, 1)
    return Viewport(
        origin: NormalizedPoint(x: left, y: top), size: NormalizedSize(width: right - left, height: bottom - top))
}

private func distance(_ a: Viewport, _ b: Viewport) -> Double {
    max(
        abs(a.origin.x - b.origin.x), abs(a.origin.y - b.origin.y), abs(a.size.width - b.size.width),
        abs(a.size.height - b.size.height))
}

/// The four edges of a crop, the channels the mapper springs.
private func edges(_ viewport: Viewport) -> [Double] {
    [
        viewport.origin.x, viewport.origin.y, viewport.origin.x + viewport.size.width,
        viewport.origin.y + viewport.size.height,
    ]
}

/// Largest overflow of any sample past the frame (0 when every crop is
/// inside), and the smallest side seen.
private func frameBounds(_ timeline: ContentCropTimeline) -> (overflow: Double, smallestSide: Double) {
    var overflow = 0.0
    var smallestSide = Double.infinity
    for sample in timeline.samples {
        let crop = sample.crop
        overflow = max(
            overflow, -crop.origin.x, -crop.origin.y, crop.origin.x + crop.size.width - 1,
            crop.origin.y + crop.size.height - 1)
        smallestSide = min(smallestSide, crop.size.width, crop.size.height)
    }
    return (overflow, smallestSide)
}

/// C1 continuity of a crop timeline, each edge held to the spring's own
/// acceleration from its target at that sample, as `continuity(of:)` holds
/// the camera's travel channel: |x″| ≤ (k·|target − x| + c·|x′|) / m, so
/// consecutive finite-difference velocities may differ by at most that × dt,
/// plus 5% and a floor of 0.01/s for the frame limits, which zero a
/// sub-pixel overshoot. Returns the worst ratio to that limit (1 is exactly
/// the limit) and the largest velocity jump seen.
private func edgeContinuity(
    _ timeline: ContentCropTimeline, target: (Double) -> Viewport, spring: SpringParameters
) -> (ratio: Double, jump: Double, speed: Double) {
    let samples = timeline.samples
    guard samples.count >= 3 else { return (0, 0, 0) }
    let rate = timeline.sampleRate
    let dt = 1 / rate
    let kOverM = spring.tension / spring.mass
    let cOverM = spring.friction / spring.mass
    var ratio = 0.0
    var jump = 0.0
    var speed = 0.0
    for index in 1..<(samples.count - 1) {
        let a = edges(samples[index - 1].crop)
        let b = edges(samples[index].crop)
        let c = edges(samples[index + 1].crop)
        let targets = [
            edges(target(samples[index - 1].time)), edges(target(samples[index].time)),
            edges(target(samples[index + 1].time)),
        ]
        for axis in 0..<4 {
            let v1 = (b[axis] - a[axis]) * rate
            let v2 = (c[axis] - b[axis]) * rate
            let displacement = max(
                abs(targets[0][axis] - a[axis]), abs(targets[1][axis] - b[axis]), abs(targets[2][axis] - c[axis]))
            let limit = (kOverM * displacement + cOverM * max(abs(v1), abs(v2))) * dt * 1.05 + 0.01
            speed = max(speed, abs(v1), abs(v2))
            jump = max(jump, abs(v2 - v1))
            ratio = max(ratio, abs(v2 - v1) / limit)
        }
    }
    return (ratio, jump, speed)
}

// MARK: - Checks

@MainActor
private func checkMapperDefaults(_ checker: Checker) {
    let defaults = ContentMapperSettings()
    checker.equal(defaults.sampleRate, 120, "the crop is sampled at the camera's rate")
    checker.equal(defaults.spring, .camera, "the crop edges follow the camera spring")
    checker.equal(defaults.minimumSide, 0.02, "a crop side never falls under 2% of the frame")
}

/// Display and area recordings fill their frame whatever the index says;
/// so does a window recording whose index never carried a bounding rect.
@MainActor
private func checkIdentitySources(_ checker: Checker) {
    let frames = syntheticIndex(duration: 2) { _ in windowAtStart }
    let mapper = ContentMapper()
    checker.equal(
        mapper.cropTimeline(source: .display, frames: frames, surfaceSize: surface, duration: 2), .identity,
        "a display recording maps to the identity crop")
    checker.equal(
        mapper.cropTimeline(source: .area, frames: frames, surfaceSize: surface, duration: 2), .identity,
        "an area recording maps to the identity crop")
    checker.equal(
        mapper.cropTimeline(source: windowSource, frames: [], surfaceSize: surface, duration: 2), .identity,
        "a window recording with no frames maps to the identity crop")
    let bare = syntheticIndex(duration: 2) { _ in nil }
    checker.equal(
        mapper.cropTimeline(source: windowSource, frames: bare, surfaceSize: surface, duration: 2), .identity,
        "a window recording whose frames carry no bounding rect maps to the identity crop")
    let windowed = mapper.cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 2)
    checker.check(windowed != .identity, "a window recording with bounding rects is cropped")
}

/// The per-frame target: the bounding rect as a fraction of the surface,
/// measured by `contentRect` when the frame has one and `surfaceSize`
/// otherwise, cut to the surface, nil when there is nothing to crop to.
@MainActor
private func checkFrameTargets(_ checker: Checker) {
    let frame = FrameIndexEntry(number: 0, time: 0, contentRect: surfaceRect, boundingRect: windowAtStart)
    checker.equal(
        ContentMapper.target(for: frame, surfaceSize: PointSize(width: 1, height: 1)), crop(windowAtStart),
        "the target is the bounding rect over the content rect")
    let bare = FrameIndexEntry(number: 0, time: 0, boundingRect: windowAtStart)
    checker.equal(
        ContentMapper.target(for: bare, surfaceSize: surface), crop(windowAtStart),
        "without a content rect the surface size measures the frame")
    let offset = FrameIndexEntry(
        number: 0, time: 0, contentRect: PointRect(x: 100, y: 50, width: 1920, height: 1080),
        boundingRect: PointRect(x: 292, y: 158, width: 768, height: 432))
    checker.equal(
        ContentMapper.target(for: offset, surfaceSize: surface), crop(windowAtStart),
        "a content rect away from the origin shifts the target with it")
    let hanging = FrameIndexEntry(
        number: 0, time: 0, contentRect: surfaceRect, boundingRect: PointRect(x: -192, y: 756, width: 768, height: 648))
    checker.equal(
        ContentMapper.target(for: hanging, surfaceSize: surface),
        crop(PointRect(x: -192, y: 756, width: 768, height: 648)),
        "a window hanging off the display is cut to the surface")
    checker.check(
        distance(
            ContentMapper.target(for: hanging, surfaceSize: surface) ?? .full,
            Viewport(origin: NormalizedPoint(x: 0, y: 0.7), size: NormalizedSize(width: 0.3, height: 0.3))) < 1e-12,
        "the cut window is the 0.3 × 0.3 corner that is on the display")
    checker.equal(
        ContentMapper.target(for: FrameIndexEntry(number: 0, time: 0, contentRect: surfaceRect), surfaceSize: surface),
        nil, "a frame without a bounding rect has no target")
    let empty = FrameIndexEntry(
        number: 0, time: 0, contentRect: surfaceRect, boundingRect: PointRect(x: 500, y: 500, width: 0, height: 0))
    checker.equal(ContentMapper.target(for: empty, surfaceSize: surface), nil, "an empty bounding rect has no target")
    let gone = FrameIndexEntry(
        number: 0, time: 0, contentRect: surfaceRect, boundingRect: PointRect(x: 2500, y: 100, width: 300, height: 300))
    checker.equal(
        ContentMapper.target(for: gone, surfaceSize: surface), nil, "a bounding rect off the surface has no target")
    let unmeasured = FrameIndexEntry(number: 0, time: 0, boundingRect: windowAtStart)
    checker.equal(
        ContentMapper.target(for: unmeasured, surfaceSize: PointSize(width: 0, height: 0)), nil,
        "a surface without size measures nothing")
}

/// The acceptance: a 0.2 jump of the window at 2 s yields a crop that starts
/// on the window, is C1-continuous through the jump, never leaves the frame,
/// keeps the window's size through a pure translation and settles exactly
/// on the moved window.
@MainActor
private func checkWindowJump(_ checker: Checker) {
    let jumpTime = 2.0
    let jump = 0.2 * surface.width
    func rect(at time: Double) -> PointRect {
        var rect = windowAtStart
        if time >= jumpTime { rect.x += jump }
        return rect
    }
    let frames = syntheticIndex(duration: 5, rect: rect(at:))
    let settings = ContentMapperSettings()
    let timeline = ContentMapper(settings: settings)
        .cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 5)
    checker.equal(timeline.sampleRate, settings.sampleRate, "the timeline runs at the settings' rate")
    checker.equal(timeline.samples.count, 601, "120 Hz over 5 s is 601 samples")
    checker.equal(timeline.samples.first?.time, 0, "the first sample is at time zero")
    checker.close(timeline.samples.last?.time ?? -1, 5, "the last sample is at the duration")
    checker.equal(
        timeline.samples.first?.crop, crop(windowAtStart),
        "the crop starts on the window, with no fly-in from the frame")
    let beforeJump = timeline.samples.filter { $0.time <= jumpTime }
    checker.check(
        beforeJump.allSatisfy { $0.crop == crop(windowAtStart) },
        "the crop rests on a still window until the frame that moves it")
    let bounds = frameBounds(timeline)
    checker.equal(bounds.overflow, 0, "the crop stays inside the frame at every sample")
    checker.check(
        bounds.smallestSide >= settings.minimumSide, "no crop side falls under the floor (\(bounds.smallestSide))")
    let continuity = edgeContinuity(timeline, target: { crop(rect(at: $0)) }, spring: settings.spring)
    checker.check(
        continuity.ratio <= 1,
        "edge velocity jumps through the 0.2 jump stay within the spring's acceleration "
            + "(\(continuity.ratio) of the limit)")
    checker.check(continuity.speed > 0.1, "the crop does move after the jump (peak speed \(continuity.speed)/s)")
    let midFlight = timeline.crop(at: jumpTime + 0.2)
    checker.check(
        midFlight.origin.x > 0.1 && midFlight.origin.x < 0.3,
        "200 ms after the jump the crop is under way, not there (x = \(midFlight.origin.x))")
    var widthDrift = 0.0
    for sample in timeline.samples {
        widthDrift = max(
            widthDrift, abs(sample.crop.size.width - 0.4), abs(sample.crop.size.height - 0.4),
            abs(sample.crop.origin.y - 0.1))
    }
    checker.check(
        widthDrift < 1e-9, "a pure translation keeps the window's size and the other axis (drift \(widthDrift))")
    checker.equal(timeline.samples.last?.crop, crop(rect(at: 5)), "the crop lands exactly on the moved window")
    let settled = timeline.samples.first { $0.time > jumpTime && $0.crop == crop(rect(at: 5)) }?.time ?? .nan
    checker.check(settled < 4, "the crop settles within 2 s of the jump (at \(settled) s)")
    print(
        "window jump: max edge velocity jump \(String(format: "%.4f", continuity.jump))/s "
            + "(\(String(format: "%.2f", continuity.ratio)) of the spring limit), peak speed "
            + "\(String(format: "%.3f", continuity.speed))/s, settled at \(String(format: "%.3f", settled)) s")
    // Interpolation between samples: the renderer asks at 60 fps against a
    // 120 Hz timeline, and a query past the end holds the last crop.
    let between = timeline.crop(at: jumpTime + 0.2 + 1 / 240)
    let next = timeline.crop(at: jumpTime + 0.2 + 1 / 120)
    checker.check(
        between.origin.x > midFlight.origin.x && between.origin.x < next.origin.x,
        "a query between samples interpolates")
    checker.equal(timeline.crop(at: 9), timeline.samples.last?.crop, "a query past the end holds the last crop")
    checker.equal(timeline.crop(at: -1), timeline.samples.first?.crop, "a query before zero holds the first crop")
    // The continuity check has teeth: one sample shoved by 0.01 is a jump
    // well past the spring bound.
    var broken = timeline.samples
    var shoved = broken[300].crop
    shoved.origin.x += 0.01
    broken[300] = ContentCropSample(time: broken[300].time, crop: shoved)
    let brokenContinuity = edgeContinuity(
        ContentCropTimeline(sampleRate: timeline.sampleRate, samples: broken), target: { crop(rect(at: $0)) },
        spring: settings.spring)
    checker.check(
        brokenContinuity.ratio > 1, "a 0.01 discontinuity exceeds the spring bound (\(brokenContinuity.ratio))")
}

/// A resize that moves one edge leaves the others exactly where they are,
/// and a frame that arrives mid-flight bends the motion rather than
/// restarting it.
@MainActor
private func checkWindowResize(_ checker: Checker) {
    func rect(at time: Double) -> PointRect {
        var rect = windowAtStart
        if time >= 1 { rect.width += 384 }
        if time >= 1.1 { rect.width += 384 }
        return rect
    }
    let frames = syntheticIndex(duration: 4, rect: rect(at:))
    let settings = ContentMapperSettings()
    let timeline = ContentMapper(settings: settings)
        .cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 4)
    var otherEdges = 0.0
    for sample in timeline.samples {
        otherEdges = max(
            otherEdges, abs(sample.crop.origin.x - 0.1), abs(sample.crop.origin.y - 0.1),
            abs(sample.crop.size.height - 0.4))
    }
    checker.check(otherEdges < 1e-12, "a resize of the right edge leaves the other three edges (drift \(otherEdges))")
    checker.equal(timeline.samples.last?.crop, crop(rect(at: 4)), "the crop settles on the resized window")
    let continuity = edgeContinuity(timeline, target: { crop(rect(at: $0)) }, spring: settings.spring)
    checker.check(
        continuity.ratio <= 1,
        "a second resize 100 ms into the first bends the motion within the spring bound (\(continuity.ratio))")
    checker.equal(frameBounds(timeline).overflow, 0, "a growing window stays inside the frame")
}

/// A window that vanishes (an empty rect) keeps the last framing; one
/// dragged off the display is followed to the edge and no further; a tiny
/// window is framed at the size floor.
@MainActor
private func checkHiddenAndOffscreenWindow(_ checker: Checker) {
    let settings = ContentMapperSettings()
    let mapper = ContentMapper(settings: settings)
    let hidden = syntheticIndex(duration: 3) { time in
        time >= 1 && time < 2 ? PointRect(x: 0, y: 0, width: 0, height: 0) : windowAtStart
    }
    let held = mapper.cropTimeline(source: windowSource, frames: hidden, surfaceSize: surface, duration: 3)
    checker.check(
        held.samples.allSatisfy { $0.crop == crop(windowAtStart) }, "a hidden window keeps the last framing")
    let sparse = syntheticIndex(duration: 3) { time in time == 0 ? windowAtStart : nil }
    let carried = mapper.cropTimeline(source: windowSource, frames: sparse, surfaceSize: surface, duration: 3)
    checker.equal(carried, held, "frames without a rect after the first keep the framing, as the sparse index reads")

    let jumpTime = 1.0
    func offscreen(at time: Double) -> PointRect {
        time >= jumpTime ? PointRect(x: 1700, y: 900, width: 768, height: 432) : windowAtStart
    }
    let dragged = syntheticIndex(duration: 4, rect: offscreen(at:))
    let edge = mapper.cropTimeline(source: windowSource, frames: dragged, surfaceSize: surface, duration: 4)
    let bounds = frameBounds(edge)
    checker.equal(bounds.overflow, 0, "a window dragged off the display keeps the crop inside the frame")
    checker.equal(
        edge.samples.last?.crop, crop(offscreen(at: 4)), "the crop settles on the visible part of the window")
    checker.check(
        distance(
            edge.samples.last?.crop ?? .full,
            Viewport(
                origin: NormalizedPoint(x: 1700 / surface.width, y: 900 / surface.height),
                size: NormalizedSize(width: 220 / surface.width, height: 180 / surface.height))) < 1e-12,
        "the visible part is the 220 × 180 points still on the display")
    let continuity = edgeContinuity(
        edge,
        target: {
            ContentMapper.target(
                for: FrameIndexEntry(
                    number: 0, time: 0, contentRect: surfaceRect, boundingRect: offscreen(at: $0)), surfaceSize: surface
            )!
        },
        spring: settings.spring)
    checker.check(
        continuity.ratio <= 1, "the edge clamp stays within the continuity bound (\(continuity.ratio))")

    let tiny = syntheticIndex(duration: 1) { _ in PointRect(x: 1910, y: 1070, width: 10, height: 10) }
    let floored = mapper.cropTimeline(source: windowSource, frames: tiny, surfaceSize: surface, duration: 1)
    let tinyBounds = frameBounds(floored)
    checker.close(tinyBounds.smallestSide, settings.minimumSide, "a tiny window is framed at the size floor")
    checker.equal(tinyBounds.overflow, 0, "the size floor is applied inside the frame")
    checker.close(
        floored.samples.first?.crop.origin.x ?? -1, 1 - settings.minimumSide,
        "a tiny window in the corner is framed by a floor-sized crop pushed inside the frame")
}

@MainActor
private func checkMapperDeterminism(_ checker: Checker) {
    func rect(at time: Double) -> PointRect {
        var rect = windowAtStart
        if time >= 2 { rect.x += 384 }
        return rect
    }
    let frames = syntheticIndex(duration: 4, rect: rect(at:))
    let mapper = ContentMapper()
    let first = mapper.cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 4)
    let again = mapper.cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 4)
    checker.equal(first, again, "the mapper is deterministic across two runs")
    let shuffled = mapper.cropTimeline(
        source: windowSource, frames: frames.reversed(), surfaceSize: surface, duration: 4)
    checker.equal(shuffled, first, "frames out of time order give the same timeline")
    let zero = mapper.cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: 0)
    checker.equal(zero.samples.count, 1, "a zero duration is the single sample at time zero")
    checker.equal(zero.samples.first?.crop, crop(windowAtStart), "the single sample is the window at the start")
    let nan = mapper.cropTimeline(source: windowSource, frames: frames, surfaceSize: surface, duration: .nan)
    checker.equal(nan.samples.count, 1, "a NaN duration plans as zero rather than trapping")
}

/// The manifest form reads the surface from `captureRectPoints`, the
/// duration from the manifest and the frames through `FrameIndex.frames()`,
/// so an index written sparse (geometry only when it changes) is read whole.
@MainActor
private func checkManifestConvenience(_ checker: Checker) {
    let manifest = RecordingManifest(
        source: windowSource,
        content: ContentGeometry(
            displayID: 1, displayBoundsPoints: surfaceRect, captureRectPoints: surfaceRect, pointPixelScale: 2),
        screen: ScreenTrackInfo(width: 3840, height: 2160, frameRate: 60, codec: "hevc"),
        state: .complete, stopReason: .userStopped, duration: 3)
    var lines: [FrameIndexLine] = []
    for n in 0...Int(3 * indexRate) {
        let time = Double(n) / indexRate
        // Sparse, as the writer stores it: geometry on the first frame and on
        // the frame that moves the window, nothing on the others.
        var rect: PointRect?
        if n == 0 { rect = windowAtStart }
        if time == 1.5 { rect = PointRect(x: 576, y: 108, width: 768, height: 432) }
        lines.append(
            .frame(FrameIndexEntry(number: n, time: time, contentRect: n == 0 ? surfaceRect : nil, boundingRect: rect)))
        if n % 60 == 59 { lines.append(.hold(time: time + 0.008)) }
    }
    let index = FrameIndex(header: FrameIndexHeader(recordingID: manifest.recordingID), lines: lines)
    let timeline = ContentMapper().cropTimeline(manifest: manifest, index: index)
    checker.equal(timeline.samples.count, 361, "the manifest's duration sets the timeline's length")
    checker.equal(timeline.samples.first?.crop, crop(windowAtStart), "the sparse index starts the crop on the window")
    checker.equal(
        timeline.samples.last?.crop, crop(PointRect(x: 576, y: 108, width: 768, height: 432)),
        "the sparse index moves the crop with the one frame that carries a new rect")
    let explicit = ContentMapper().cropTimeline(
        source: windowSource, frames: index.frames(), surfaceSize: surface, duration: 3)
    checker.equal(timeline, explicit, "the manifest form equals the explicit form")
    let longer = ContentMapper().cropTimeline(manifest: manifest, index: index, duration: 4)
    checker.equal(longer.samples.count, 481, "an explicit duration overrides the manifest's")
    var open = manifest
    open.duration = nil
    let fromIndex = ContentMapper().cropTimeline(manifest: open, index: index)
    checker.equal(fromIndex.samples.count, 361, "without a manifest duration the last frame's time is the length")
}
