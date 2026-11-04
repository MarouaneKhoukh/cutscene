import CutsceneCore
import CutsceneEngine
import Foundation

/// `RenderPlan` checks (PLAN M1-04): the frame-state queries on hand-built
/// plans, `build` as a composition of the three planners, and the 30-minute
/// fixture for determinism, the inside-frame viewport and the build budget.
/// M2-01 adds the per-canvas state (`frameState(at:canvas:)`: layout, crop,
/// ripples, bubble), the builds from a `ZoomTrack` and from a kit, and the
/// 9:16 determinism and no-overlap sweep on the fixture. Registered by
/// M1-00; reports through the shared checker so the pass count stays one
/// number.
@MainActor
func runRenderPlanChecks(_ checker: Checker) {
    checkFrameStateQueries(checker)
    checkBuildComposesPlanners(checker)
    checkCanvasFrameState(checker)
    checkZoomTrackBuilds(checker)
    checkThirtyMinutePlan(checker)
}

// MARK: - Fixtures

/// The 30-minute, 50,000-event trace of the engine budget check in
/// `main.swift`, regenerated here from the same seed and rules so the plan is
/// measured on the trace the planners are: clicks in clusters 6–14 s apart,
/// 2% key-downs, a random walk otherwise.
func thirtyMinuteTrace() -> [InputEvent] {
    var random = TraceRandom(state: 0x5EED)
    var events: [InputEvent] = []
    events.reserveCapacity(50_000)
    var time = 0.0
    var position = NormalizedPoint(x: 0.5, y: 0.5)
    var nextCluster = random.next(in: 6...14)
    var clicksLeft = 0
    var nextClick = 0.0
    while events.count < 50_000 {
        time += random.next(in: 0.02...0.052)
        if clicksLeft == 0, time >= nextCluster {
            clicksLeft = 1 + Int(random.next() * 3)
            nextClick = time
            nextCluster = time + random.next(in: 6...14)
        }
        let roll = random.next()
        if clicksLeft > 0, time >= nextClick, events.count + 2 <= 50_000 {
            events += click(at: time, position, holdFor: 0.06)
            clicksLeft -= 1
            nextClick = time + random.next(in: 0.3...1.5)
        } else if roll < 0.02 {
            events.append(
                .keyDown(time: time, keyCode: UInt16(random.next(in: 0...50)), modifiers: [], isRepeat: false))
        } else {
            position = NormalizedPoint(
                x: min(max(position.x + random.next(in: -0.05...0.05), 0), 1),
                y: min(max(position.y + random.next(in: -0.05...0.05), 0), 1))
            events.append(.pointerMoved(time: time, position: position))
        }
    }
    return events
}

/// Seconds the 30-minute fixture is planned over.
let thirtyMinutes = 1800.0

/// An event log around `events` with the metadata of a 1080p display capture.
func renderPlanLog(_ events: [InputEvent]) -> EventLog {
    EventLog(
        startHostTimeSeconds: 0, captureRectPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080), displayID: 1,
        pointPixelScale: 2, samplingRateHz: 125, events: events)
}

func cursorShape(_ id: String) -> CursorShape {
    CursorShape(id: id, hotspot: NormalizedPoint(x: 0.1, y: 0.1), sizePoints: PointSize(width: 24, height: 24))
}

func viewportIsInsideFrame(_ viewport: Viewport) -> Bool {
    viewport.origin.x >= 0 && viewport.origin.y >= 0 && viewport.size.width > 0 && viewport.size.height > 0
        && viewport.origin.x + viewport.size.width <= 1 + 1e-12 && viewport.origin.y + viewport.size.height <= 1 + 1e-12
}

func milliseconds(_ duration: Duration) -> String {
    String(format: "%.1f", Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15)
}

/// A velocity is a sample difference times a rate, so `(0.35 − 0.25) × 10`
/// lands a rounding error from 1; hand-worked expectations are met within it.
@MainActor
private func checkVelocity(
    _ checker: Checker, _ actual: ViewportVelocity, _ expected: ViewportVelocity, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let tolerance = 1e-9
    let error = max(
        abs(actual.originX - expected.originX), abs(actual.originY - expected.originY),
        abs(actual.width - expected.width), abs(actual.height - expected.height))
    checker.check(
        error <= tolerance, "\(message): got \(actual), expected \(expected) ± \(tolerance)", file: file, line: line)
}

// MARK: - Frame-state queries on hand-built plans

/// The viewport, its velocity, the cursor and the cursor shape, each pinned
/// with numbers worked out by hand on tiny timelines.
@MainActor
private func checkFrameStateQueries(_ checker: Checker) {
    // An empty plan: the whole frame, at rest, nothing to draw.
    let empty = RenderPlan(
        cursor: CursorTimeline(sampleRate: 60, samples: []), zoomSegments: [],
        camera: CameraTimeline(sampleRate: 120, samples: []), cursorShapeChanges: [], duration: 0)
    let emptyState = empty.frameState(at: 1)
    checker.equal(emptyState.viewport, Viewport.full, "an empty plan shows the whole frame")
    checker.equal(emptyState.viewportVelocity, ViewportVelocity.zero, "an empty plan's viewport is at rest")
    checker.equal(emptyState.cursor, nil, "an empty plan draws no cursor")
    checker.equal(emptyState.cursorShape, nil, "an empty plan names no cursor shape")
    checker.equal(
        Viewport.full, Viewport(origin: NormalizedPoint(x: 0, y: 0), size: NormalizedSize(width: 1, height: 1)),
        "the full viewport is the unit square")

    // Velocity: a 10 Hz camera that zooms from 1× to 2× over the first
    // interval, then pans right by 0.1 over the second. Viewports by hand:
    // (0,0) 1×1 → (0.25,0.25) 0.5×0.5 → (0.35,0.25) 0.5×0.5.
    func cameraSample(_ time: Double, _ x: Double, _ amount: Double) -> CameraSample {
        let center = NormalizedPoint(x: x, y: 0.5)
        return CameraSample(
            time: time, center: center, amount: amount, activity: 0, travel: center, travelTarget: center)
    }
    let camera = CameraTimeline(
        sampleRate: 10, samples: [cameraSample(0, 0.5, 1), cameraSample(0.1, 0.5, 2), cameraSample(0.2, 0.6, 2)])
    var cursorSamples: [CursorSample] = []
    for n in 0...2 {
        let position = NormalizedPoint(x: 0.1 * Double(n), y: 0.5)
        cursorSamples.append(
            CursorSample(
                time: Double(n) / 10, smoothedPosition: position, rawPosition: position, isPressed: n == 1, opacity: 1,
                scale: 1))
    }
    let cursor = CursorTimeline(sampleRate: 10, samples: cursorSamples)
    let plan = RenderPlan(
        cursor: cursor, zoomSegments: [], camera: camera, cursorShapeChanges: [], duration: 0.2)
    let zoomingIn = plan.frameState(at: 0.05)
    checkVelocity(
        checker, zoomingIn.viewportVelocity, ViewportVelocity(originX: 2.5, originY: 2.5, width: -5, height: -5),
        "zooming 1× → 2× in 0.1 s moves the origin at 2.5/s and shrinks the viewport at 5/s")
    checkVelocity(
        checker, plan.frameState(at: 0.15).viewportVelocity,
        ViewportVelocity(originX: 1, originY: 0, width: 0, height: 0),
        "panning 0.1 in 0.1 s at a constant amount is an origin velocity of 1/s")
    checkVelocity(
        checker, plan.frameState(at: 0.1).viewportVelocity,
        ViewportVelocity(originX: 1, originY: 0, width: 0, height: 0),
        "exactly on a sample the velocity is the interval that starts there")
    checker.equal(
        plan.frameState(at: 0.2).viewportVelocity, ViewportVelocity.zero, "the velocity is zero from the last sample on"
    )
    checker.equal(plan.frameState(at: 5).viewportVelocity, ViewportVelocity.zero, "the velocity is zero past the end")
    checker.equal(
        plan.frameState(at: -1).viewportVelocity, ViewportVelocity.zero, "the velocity is zero before time zero")
    checker.equal(
        plan.frameState(at: Double.nan).viewportVelocity, ViewportVelocity.zero,
        "a NaN time asks for a viewport at rest")
    checker.equal(
        zoomingIn.viewport, Viewport(camera.viewport(at: 0.05)), "the viewport is the camera timeline's at that time")
    checker.close(
        zoomingIn.viewport.origin.x, 0.5 - 1 / 3, "halfway from 1× to 2× the amount is 1.5× and the origin is 0.5 − 1/3"
    )
    checker.close(zoomingIn.viewport.size.width, 2 / 3, "halfway from 1× to 2× the viewport is 2/3 of the frame")
    checker.equal(zoomingIn.cursor, cursor.sample(at: 0.05), "the cursor is the cursor timeline's sample at that time")
    checker.close(
        zoomingIn.cursor?.smoothedPosition.x ?? Double.nan, 0.05, "the cursor interpolates between its samples")
    checker.equal(plan.frameState(at: 7).cursor, cursor.samples[2], "past the end the cursor holds its last sample")

    // Shapes: changes handed over out of order, two at the same time and one
    // with a NaN time; the plan sorts them, keeps the tie order and drops the NaN.
    let shapes = RenderPlan(
        cursor: cursor, zoomSegments: [], camera: camera,
        cursorShapeChanges: [
            CursorShapeChange(time: 2, shape: cursorShape("iBeam")),
            CursorShapeChange(time: 1, shape: cursorShape("arrow")),
            CursorShapeChange(time: 2, shape: cursorShape("crosshair")),
            CursorShapeChange(time: Double.nan, shape: cursorShape("lost")),
        ], duration: 3)
    checker.equal(
        shapes.cursorShapeChanges.map { $0.time }, [1, 2, 2], "shape changes are sorted by time, NaN dropped")
    checker.equal(
        shapes.cursorShapeChanges.map { $0.shape.id }, ["arrow", "iBeam", "crosshair"],
        "shape changes at the same time keep their order")
    checker.equal(shapes.frameState(at: 0.5).cursorShape, nil, "no shape before the first change")
    checker.equal(shapes.frameState(at: 1).cursorShape?.id, "arrow", "a change applies exactly at its time")
    checker.equal(shapes.frameState(at: 1.5).cursorShape?.id, "arrow", "between changes the earlier one holds")
    checker.equal(
        shapes.frameState(at: 2).cursorShape?.id, "crosshair", "of two changes at the same time the later row wins")
    checker.equal(shapes.frameState(at: 100).cursorShape?.id, "crosshair", "the last change holds to the end")
    checker.equal(shapes.cursorShape(at: -1), nil, "no shape before time zero")
    checker.equal(shapes.cursorShape(at: Double.nan), nil, "a NaN time has no shape")
    checker.equal(shapes.duration, 3, "a finite, positive duration is kept as given")
    checker.equal(
        RenderPlan(cursor: cursor, zoomSegments: [], camera: camera, cursorShapeChanges: [], duration: -2).duration, 0,
        "a negative duration plans as zero")
    checker.equal(
        RenderPlan(cursor: cursor, zoomSegments: [], camera: camera, cursorShapeChanges: [], duration: Double.nan)
            .duration, 0, "a NaN duration plans as zero")
}

// MARK: - build composes the planners

/// `build` is the three planners run in pipeline order with the settings it
/// is given, plus the shape changes read from the log.
@MainActor
private func checkBuildComposesPlanners(_ checker: Checker) {
    // Two clicks 6 s apart: their padded windows ([0.7, 3.5] and [6.7, 9.5])
    // are further apart than `mergeGap`, so they stay two segments.
    let first = NormalizedPoint(x: 0.3, y: 0.3)
    let second = NormalizedPoint(x: 0.8, y: 0.7)
    var events = linearMoves(from: NormalizedPoint(x: 0.1, y: 0.2), to: first, start: 0, end: 0.8)
    events += click(at: 1, first)
    events += linearMoves(from: first, to: second, start: 2, end: 4)
    events += click(at: 7, second)
    events.append(.cursorShapeChanged(time: 0, shape: cursorShape("arrow")))
    events.append(.cursorShapeChanged(time: 0.9, shape: cursorShape("pointingHand")))
    events.append(.cursorShapeChanged(time: 6.9, shape: cursorShape("iBeam")))
    events.append(.cursorShapeChanged(time: 12, shape: cursorShape("arrow")))
    let log = renderPlanLog(events)
    let duration = 10.0

    let plan = RenderPlan.build(log: log, duration: duration)
    checker.equal(plan.duration, duration, "the plan covers the duration it was built for")
    checker.equal(
        plan.cursor, CursorSmoother().timeline(for: log, duration: duration), "build runs the cursor smoother")
    checker.equal(plan.zoomSegments, ZoomPlanner().plan(log, recordingEnd: duration), "build runs the zoom planner")
    checker.equal(
        plan.camera, CameraPlanner().timeline(segments: plan.zoomSegments, cursor: plan.cursor, duration: duration),
        "build runs the camera planner on its own segments and cursor")
    checker.equal(plan.zoomSegments.count, 2, "two clicks 6 s apart are two zoom segments")
    checker.equal(plan.cursor.samples.count, 601, "the cursor timeline covers the duration at 60 Hz")
    checker.equal(plan.camera.samples.count, 1201, "the camera timeline covers the duration at 120 Hz")
    checker.equal(
        plan.cursorShapeChanges.map { $0.time }, [0, 0.9, 6.9, 12], "every shape change is read, past the end included")
    checker.equal(plan.frameState(at: 5).cursorShape?.id, "pointingHand", "the shape at 5 s is the change at 0.9 s")
    checker.equal(plan.frameState(at: 11).cursorShape?.id, "iBeam", "a change past the end does not apply before it")
    checker.equal(plan.frameState(at: 12).cursorShape?.id, "arrow", "a change past the end applies at its time")
    let frame = plan.frameState(at: 3.5)
    checker.equal(frame.viewport, Viewport(plan.camera.viewport(at: 3.5)), "the frame's viewport is the camera's")
    checker.equal(frame.cursor, plan.cursor.sample(at: 3.5), "the frame's cursor is the timeline's")
    let zoomingIn = plan.frameState(at: plan.zoomSegments[0].start + 0.1)
    checker.check(
        zoomingIn.viewport.size.width < 1 && zoomingIn.viewportVelocity.width < 0,
        "0.1 s into the first segment the camera is zooming in (viewport width \(zoomingIn.viewport.size.width), "
            + "velocity \(zoomingIn.viewportVelocity.width)/s)")
    let settled = plan.frameState(at: 0)
    checker.equal(settled.viewport, Viewport.full, "before the first segment the viewport is the whole frame")
    checker.equal(settled.viewportVelocity, ViewportVelocity.zero, "before the first segment the viewport is at rest")

    // The settings reach each planner.
    var cursorSettings = CursorSmootherSettings()
    cursorSettings.sampleRate = 30
    var zoomSettings = ZoomPlannerSettings()
    zoomSettings.amount = 3
    var cameraSettings = CameraPlannerSettings()
    cameraSettings.sampleRate = 60
    let tuned = RenderPlan.build(
        log: log, duration: duration, cursor: cursorSettings, zoom: zoomSettings, camera: cameraSettings)
    checker.equal(tuned.cursor.sampleRate, 30, "the cursor settings reach the smoother")
    checker.equal(tuned.cursor.samples.count, 301, "a 30 Hz cursor timeline has 301 samples over 10 s")
    checker.equal(tuned.zoomSegments.map { $0.amount }, [3, 3], "the zoom settings reach the planner")
    checker.equal(tuned.camera.sampleRate, 60, "the camera settings reach the planner")
    checker.equal(tuned.camera.samples.count, 601, "a 60 Hz camera timeline has 601 samples over 10 s")
    checker.equal(
        tuned.cursor, CursorSmoother(settings: cursorSettings).timeline(for: log, duration: duration),
        "the tuned cursor timeline is the smoother's with those settings")
    checker.equal(
        tuned.camera,
        CameraPlanner(settings: cameraSettings)
            .timeline(segments: tuned.zoomSegments, cursor: tuned.cursor, duration: duration),
        "the tuned camera timeline is the planner's with those settings")
    checker.check(tuned != plan, "different settings give a different plan")
    checker.check(tuned.frameState(at: 4) != plan.frameState(at: 4), "different settings give different frame states")

    // Durations the planners cannot use plan as zero: one sample each, no segments.
    for (name, bad) in [("zero", 0.0), ("negative", -5.0), ("NaN", Double.nan), ("infinite", Double.infinity)] {
        let degenerate = RenderPlan.build(log: log, duration: bad)
        checker.equal(degenerate.duration, 0, "a \(name) duration plans as zero")
        checker.equal(degenerate.cursor.samples.count, 1, "a \(name) duration gives the one cursor sample")
        checker.equal(degenerate.camera.samples.count, 1, "a \(name) duration gives the one camera sample")
        checker.equal(degenerate.zoomSegments, [], "a \(name) duration plans no zoom")
        let state = degenerate.frameState(at: 3)
        checker.equal(state.viewport, Viewport.full, "a \(name)-duration plan shows the whole frame")
        checker.equal(state.viewportVelocity, ViewportVelocity.zero, "a \(name)-duration plan is at rest")
        checker.equal(
            state.cursor, degenerate.cursor.samples[0], "a \(name)-duration plan holds the first cursor sample")
        checker.equal(state.cursorShape?.id, "pointingHand", "a \(name)-duration plan still answers for shapes")
    }

    // An empty log: the parked cursor, the whole frame, no shapes.
    let bare = RenderPlan.build(log: renderPlanLog([]), duration: 2)
    checker.equal(bare.cursor.samples.count, 121, "an empty log still gives a cursor timeline")
    checker.equal(bare.zoomSegments, [], "an empty log plans no zoom")
    checker.equal(bare.cursorShapeChanges, [], "an empty log has no shape changes")
    checker.equal(bare.frameState(at: 1).viewport, Viewport.full, "an empty log shows the whole frame")
    checker.equal(bare.frameState(at: 1).cursorShape, nil, "an empty log names no shape")
}

// MARK: - Per-canvas state

/// `frameState(at:canvas:)`: the layout for the canvas, the crop (identity
/// by default, a timeline when given), the ripples scaled to the canvas and
/// the bubble; `frameState(at:)` is the 1080p case.
@MainActor
private func checkCanvasFrameState(_ checker: Checker) {
    let first = NormalizedPoint(x: 0.3, y: 0.3)
    var events = linearMoves(from: NormalizedPoint(x: 0.1, y: 0.2), to: first, start: 0, end: 0.8)
    events += click(at: 1, first)
    let log = renderPlanLog(events)
    let plan = RenderPlan.build(log: log, duration: 5)
    checker.close(plan.sourceAspectRatio, 16.0 / 9.0, "the source aspect is the log's capture rect")
    checker.equal(plan.contentCrop, ContentCropTimeline.identity, "the crop is the identity by default")
    checker.check(plan.contentCrop.isIdentity, "the identity crop says so")
    checker.equal(plan.layoutSettings, LayoutSettings(), "the layout settings default")
    checker.equal(plan.clickEffects.settings, ClickRippleSettings(), "the ripple settings default")
    checker.equal(plan.clickEffects.clicks.map(\.time), [1], "the plan reads the log's clicks")

    let hd = plan.frameState(at: 0.5, canvas: .hd1080)
    checker.equal(plan.frameState(at: 0.5), hd, "frameState(at:) is the 1080p state")
    checker.equal(hd.contentCrop, Viewport.full, "the identity crop is the whole frame")
    checker.equal(hd.layout, LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: 16.0 / 9.0), "the 1080p layout")
    checker.equal(hd.ripples, [], "no ripple before the click")
    checker.equal(hd.camera, nil, "no bubble without a camera")
    checker.equal(hd.viewport, Viewport(plan.camera.viewport(at: 0.5)), "the viewport is still the camera's")
    checker.equal(hd.cursor, plan.cursor.sample(at: 0.5), "the cursor is still the timeline's")

    let rippling = plan.frameState(at: 1.1, canvas: .hd1080)
    checker.equal(rippling.ripples.count, 1, "one ripple 0.1 s after the click")
    checker.close(rippling.ripples.first?.radius ?? -1, 21.472, "the 1080p ripple is at the reference size")
    checker.equal(rippling.ripples.first?.position, first, "the ripple is centred on the click")
    let uhd = plan.frameState(at: 1.1, canvas: .uhd2160)
    checker.close(uhd.ripples.first?.radius ?? -1, 42.944, "the 4K ripple is doubled")
    checker.close(uhd.ripples.first?.strokeWidth ?? -1, 2.56, "the 4K stroke is doubled")
    checker.close(uhd.ripples.first?.opacity ?? -1, 0.3328, "the 4K opacity is unchanged")
    checker.equal(uhd.layout.pixelScale, 2, "the 4K layout is at twice the reference")
    let vertical = plan.frameState(at: 1.1, canvas: .vertical1080)
    checker.close(vertical.ripples.first?.radius ?? -1, 21.472, "9:16 scales ripples by its shorter side: 1080p size")
    checker.equal(vertical.layout.pixelScale, 1, "the 9:16 layout is at the reference scale")
    checker.equal(
        vertical.layout, LayoutSolver.solve(canvas: .vertical1080, contentAspectRatio: 16.0 / 9.0), "the 9:16 layout")
    checker.equal(plan.frameState(at: 1.5, canvas: .hd1080).ripples, [], "the ripple is gone at its end")

    // Settings reach the state: a camera adds the bubble, ripples can be off.
    var withCamera = LayoutSettings()
    withCamera.bubble = BubbleSettings()
    var quiet = ClickRippleSettings()
    quiet.enabled = false
    let styled = RenderPlan.build(log: log, duration: 5, ripples: quiet, layout: withCamera)
    let bubbled = styled.frameState(at: 1.1, canvas: .vertical1080)
    checker.equal(bubbled.ripples, [], "ripples off reaches the state")
    checker.check(bubbled.camera != nil, "a camera in the layout settings places a bubble")
    checker.equal(bubbled.camera, bubbled.layout.bubble, "the state's camera is the layout's bubble")
    checker.equal(bubbled.camera?.arrangement, .belowCard, "the bubble stacks on 9:16")
    checker.check(!(bubbled.camera?.rect.intersects(bubbled.layout.card) ?? true), "the bubble clears the card")
    checker.equal(
        styled.frameState(at: 1.1, canvas: .hd1080).camera?.arrangement, .overlay, "the bubble overlays on 16:9")

    // A crop timeline: the whole frame at 0 s, the right half at 1 s, held
    // after; the card follows the visible slice's aspect.
    let half = Viewport(origin: NormalizedPoint(x: 0.5, y: 0), size: NormalizedSize(width: 0.5, height: 1))
    let crop = ContentCropTimeline(
        sampleRate: 1, samples: [ContentCropSample(time: 0, crop: .full), ContentCropSample(time: 1, crop: half)])
    checker.equal(crop.crop(at: 0), Viewport.full, "the crop at time zero")
    checker.equal(crop.crop(at: 1), half, "the crop at the second sample")
    checker.equal(crop.crop(at: 7), half, "the crop holds past its end")
    checker.equal(crop.crop(at: -1), Viewport.full, "the crop holds before time zero")
    checker.close(crop.crop(at: 0.5).origin.x, 0.25, "the crop interpolates its origin")
    checker.close(crop.crop(at: 0.5).size.width, 0.75, "the crop interpolates its size")
    checker.check(!crop.isIdentity, "a sampled crop is not the identity")
    checker.equal(ContentCropTimeline.identity.crop(at: 3), Viewport.full, "the identity is the whole frame")
    let cropped = RenderPlan.build(log: log, duration: 5, contentCrop: crop)
    checker.equal(cropped.contentCrop, crop, "the crop timeline reaches the plan")
    let narrow = cropped.frameState(at: 3, canvas: .hd1080)
    checker.equal(narrow.contentCrop, half, "the state carries the crop at its time")
    checker.close(
        narrow.layout.card.width / narrow.layout.card.height, 8.0 / 9.0, "the card is the cropped slice's aspect")
    checker.close(narrow.layout.card.height, 950.4, "the narrow card is still height-bound")
    checker.equal(cropped.cursor, plan.cursor, "the crop does not move the cursor: it is drawn through the crop")
    checker.check(cropped.camera != plan.camera, "the crop moves the camera: it is planned in content space")

    // Planned in content space: a click at the crop's centre (frame x 0.75)
    // zooms 2× onto the centre of the window, so the viewport sits in the
    // middle of the content and the cursor lands at the card's centre; in
    // frame space the viewport would have been pushed to the right edge of
    // the content and the cursor to the card's left edge.
    let centre = NormalizedPoint(x: 0.75, y: 0.5)
    var centred = linearMoves(from: NormalizedPoint(x: 0.7, y: 0.5), to: centre, start: 0, end: 1.5)
    centred += click(at: 2, centre)
    let centredLog = renderPlanLog(centred)
    let centredPlan = RenderPlan.build(log: centredLog, duration: 6, contentCrop: crop)
    let zoomed = centredPlan.frameState(at: 4, canvas: .hd1080)
    checker.equal(zoomed.contentCrop, half, "the zoomed state is in the cropped stretch")
    checker.close(zoomed.viewport.size.width, 0.5, tolerance: 1e-3, "the 2× zoom halves the viewport")
    checker.close(
        zoomed.viewport.origin.x + zoomed.viewport.size.width / 2, 0.5, tolerance: 1e-3,
        "the viewport is centred on the content, not pushed to its edge")
    checker.close(
        zoomed.viewport.origin.y + zoomed.viewport.size.height / 2, 0.5, tolerance: 1e-3,
        "the viewport is centred vertically on the content")
    let drawn = zoomed.cursor?.smoothedPosition ?? NormalizedPoint(x: -1, y: -1)
    checker.close(drawn.x, 0.75, tolerance: 1e-3, "the drawn cursor stays in frame space at the window's centre")
    let cardX = ((drawn.x - half.origin.x) / half.size.width - zoomed.viewport.origin.x) / zoomed.viewport.size.width
    checker.close(
        cardX, 0.5, tolerance: 1e-3, "a cursor at the crop's centre under a 2× zoom lands at the card's centre")
    checker.equal(
        RenderPlan.contentSpace(centredLog, crop: .identity), centredLog, "the identity crop leaves the log as it is")
    checker.equal(
        RenderPlan.contentSpace(centredLog, crop: crop).events.compactMap(\.position).last,
        NormalizedPoint(x: 0.5, y: 0.5), "the click at frame x 0.75 is x 0.5 of the right half")
    checker.equal(
        RenderPlan.contentSpace(NormalizedPoint(x: 0.2, y: 2), crop: half), NormalizedPoint(x: 0, y: 1),
        "a point outside the content clamps to its edge")
    checker.equal(
        RenderPlan.build(log: centredLog, duration: 6, contentCrop: crop),
        RenderPlan.build(log: centredLog, duration: 6, contentCrop: crop), "content-space planning is deterministic")
    // A manual segment aimed at the window's centre in frame space zooms
    // onto the content's centre too.
    var manual = ZoomTrack()
    manual.segments = [ZoomTrackSegment(start: 2, end: 5, focus: centre, amount: 2, source: .manual)]
    let manualPlan = RenderPlan.build(log: centredLog, duration: 6, zoomTrack: manual, contentCrop: crop)
    let manualState = manualPlan.frameState(at: 4.5, canvas: .hd1080)
    checker.close(
        manualState.viewport.origin.x + manualState.viewport.size.width / 2, 0.5, tolerance: 1e-3,
        "a manual segment's frame-space focus is moved into content space")
    checker.equal(
        manualPlan.zoomSegments.first?.focus, NormalizedPoint(x: 0.5, y: 0.5),
        "the plan's segment carries the moved focus")
    checker.equal(
        Viewport(origin: NormalizedPoint(x: 0, y: 0), size: NormalizedSize(width: 1, height: 0)).aspectRatio, 0,
        "a viewport without height has no aspect")

    // A log with an empty capture rect falls back to the layout's default aspect.
    let bare = EventLog(
        startHostTimeSeconds: 0, captureRectPoints: PointRect(x: 0, y: 0, width: 0, height: 0), displayID: 1,
        pointPixelScale: 1, samplingRateHz: 125, events: [])
    checker.close(
        RenderPlan.build(log: bare, duration: 1).sourceAspectRatio, 16.0 / 9.0, "an empty capture rect falls back")
    let handBuilt = RenderPlan(
        cursor: plan.cursor, zoomSegments: [], camera: plan.camera, cursorShapeChanges: [], duration: 5,
        sourceAspectRatio: Double.nan)
    checker.close(handBuilt.sourceAspectRatio, 16.0 / 9.0, "a NaN source aspect falls back")
    checker.equal(handBuilt.clickEffects.clicks, [], "a hand-built plan has no clicks unless given")
}

// MARK: - Builds from a zoom track

/// `build(log:duration:zoomTrack:…)` plans around the track's segments, and
/// the first replan of the planner's own output gives the planner's plan;
/// the kit build is the adapters applied.
@MainActor
private func checkZoomTrackBuilds(_ checker: Checker) {
    let first = NormalizedPoint(x: 0.3, y: 0.3)
    let second = NormalizedPoint(x: 0.8, y: 0.7)
    var events = linearMoves(from: NormalizedPoint(x: 0.1, y: 0.2), to: first, start: 0, end: 0.8)
    events += click(at: 1, first)
    events += linearMoves(from: first, to: second, start: 2, end: 4)
    events += click(at: 7, second)
    let log = renderPlanLog(events)
    let duration = 10.0
    let plan = RenderPlan.build(log: log, duration: duration)
    checker.equal(plan.zoomSegments.count, 2, "the planner finds two segments")

    let track = ZoomTrackMerge.replan(ZoomTrack(), with: plan.zoomSegments)
    checker.equal(track.planGeneration, 1, "the first replan is generation 1")
    let fromTrack = RenderPlan.build(log: log, duration: duration, zoomTrack: track)
    checker.equal(fromTrack, plan, "a plan from the planner's own track is the planner's plan")
    checker.equal(
        RenderPlan.build(log: log, duration: duration, zoomTrack: track, kit: .default, hasCamera: false), plan,
        "the default kit build from the track is the default build")
    let withCamera = RenderPlan.build(log: log, duration: duration, zoomTrack: track, kit: .default, hasCamera: true)
    checker.check(
        withCamera.frameState(at: 3, canvas: .square1080).camera != nil, "the kit build with a camera places a bubble")
    checker.equal(
        withCamera.layoutSettings, LayoutSettings(kit: .default, hasCamera: true), "the layout settings are the kit's")

    // The user locks the first segment and makes the second a 3× manual one
    // moved earlier; the plan follows the track, not the planner.
    var edited = track
    edited.segments[0].locked = true
    edited.segments[1].source = .manual
    edited.segments[1].start = 5
    edited.segments[1].amount = 3
    let editedPlan = RenderPlan.build(log: log, duration: duration, zoomTrack: edited)
    checker.equal(editedPlan.zoomSegments, ZoomTrackMerge.segments(of: edited), "the plan's segments are the track's")
    checker.equal(editedPlan.zoomSegments.map(\.amount), [2, 3], "the manual amount reaches the plan")
    checker.equal(editedPlan.zoomSegments[1].start, 5, "the moved start reaches the plan")
    checker.check(editedPlan.camera != plan.camera, "the edited track moves the camera")
    checker.equal(editedPlan.cursor, plan.cursor, "the track does not move the cursor")
    checker.equal(editedPlan.clickEffects, plan.clickEffects, "the track does not change the clicks")
    let replanned = ZoomTrackMerge.replan(edited, with: plan.zoomSegments)
    checker.equal(
        replanned.segments.filter { !$0.isReplaceableByReplan }.map(\.id), edited.segments.map(\.id),
        "both edited segments survive the replan")
    checker.equal(
        RenderPlan.build(log: log, duration: duration, zoomTrack: replanned), editedPlan,
        "a replan around the edited segments changes nothing the user sees")

    // A kit with a different zoom amount reaches the plan through the kit
    // build, and the clicks reach the ripples with the kit's reference height.
    var kit = BrandKit.default
    kit.zoom.camera.sampleRate = 60
    kit.cursor.click.endRadius = 88
    kit.frame.referenceHeight = 2160
    let tuned = RenderPlan.build(log: log, duration: duration, zoomTrack: track, kit: kit, hasCamera: false)
    checker.equal(tuned.camera.sampleRate, 60, "the kit's camera rate reaches the plan")
    checker.equal(tuned.clickEffects.settings.endRadius, 88, "the kit's ripple radius reaches the plan")
    checker.close(
        tuned.frameState(at: 1.1, canvas: .hd1080).ripples.first?.radius ?? -1, 88 * 0.488 / 2,
        "a 4K-quoted ripple is halved at 1080p")
    checker.equal(tuned.layoutSettings.referenceHeight, 2160, "the kit's reference height reaches the layout")

    // A track with nothing usable plans like an empty one: no zoom.
    let still = RenderPlan.build(
        log: log, duration: duration,
        zoomTrack: ZoomTrack(segments: [
            ZoomTrackSegment(ZoomSegment(start: 3, end: 3, focus: first, amount: 2), source: .manual)
        ]))
    checker.equal(still.zoomSegments, [], "an empty segment is not planned")
    checker.equal(still.frameState(at: 3).viewport, Viewport.full, "no zoom, the whole frame")
    checker.equal(
        RenderPlan.build(log: log, duration: -1, zoomTrack: track).duration, 0, "a bad duration plans as zero")
}

// MARK: - The 30-minute fixture

/// Determinism, the inside-frame invariant at 1,000 times, the build budget
/// and the shape lookup against a linear scan.
@MainActor
private func checkThirtyMinutePlan(_ checker: Checker) {
    let events = thirtyMinuteTrace()
    checker.equal(events.count, 50_000, "the 30-minute trace has 50,000 events")
    let log = renderPlanLog(events)

    // Best of three, so a busy machine does not fail a budget the code meets;
    // the first and last plans serve the determinism check.
    let clock = ContinuousClock()
    var plans: [RenderPlan] = []
    var best = Duration.seconds(1_000)
    for run in 1...3 {
        var plan: RenderPlan?
        let elapsed = clock.measure { plan = RenderPlan.build(log: log, duration: thirtyMinutes) }
        plans.append(plan!)
        best = min(best, elapsed)
        print("30-minute RenderPlan.build, run \(run): \(milliseconds(elapsed)) ms")
    }
    #if DEBUG
        let budget = Duration.milliseconds(1500)
        let budgetNote = "debug build, 3× the 500 ms release budget"
    #else
        let budget = Duration.milliseconds(500)
        let budgetNote = "release build"
    #endif
    checker.check(
        best < budget,
        "RenderPlan.build of the 30-minute fixture completes in under \(milliseconds(budget)) ms (\(budgetNote); "
            + "best \(milliseconds(best)) ms)")
    let plan = plans[0]
    checker.equal(plan.duration, thirtyMinutes, "the plan covers 30 minutes")
    checker.equal(
        plan.cursor.samples.count, Int(thirtyMinutes) * 60 + 1, "the cursor timeline covers 30 minutes at 60 Hz")
    checker.equal(
        plan.camera.samples.count, Int(thirtyMinutes) * 120 + 1, "the camera timeline covers 30 minutes at 120 Hz")
    checker.check(
        plan.zoomSegments.count >= 100, "the fixture plans hundreds of zoom segments (\(plan.zoomSegments.count))")
    checker.equal(plan.cursorShapeChanges, [], "the fixture records no cursor shapes")
    checker.check(plans[2] == plan, "two builds from identical inputs give identical plans")

    // 1,000 times across the recording, plus the edges and beyond them.
    var random = TraceRandom(state: 0x9A11)
    var times = (0..<1000).map { _ in random.next(in: 0...thirtyMinutes) }
    times += [0, thirtyMinutes, thirtyMinutes + 0.5, -0.5]
    var outside = 0
    var differing = 0
    var missingCursor = 0
    var moving = 0
    var fastest = 0.0
    for time in times {
        let state = plan.frameState(at: time)
        if !viewportIsInsideFrame(state.viewport) { outside += 1 }
        if state != plans[2].frameState(at: time) { differing += 1 }
        if state.cursor == nil { missingCursor += 1 }
        let velocity = state.viewportVelocity
        let speed = max(abs(velocity.originX), abs(velocity.originY), abs(velocity.width), abs(velocity.height))
        if speed > 0 { moving += 1 }
        fastest = max(fastest, speed)
    }
    checker.equal(outside, 0, "the viewport is inside the frame at all \(times.count) times")
    checker.equal(differing, 0, "identical inputs give identical frame states at all \(times.count) times")
    checker.equal(missingCursor, 0, "a built plan always has a cursor to draw")
    checker.check(
        moving > 0 && moving < times.count, "the viewport moves at some times and rests at others (\(moving))")
    print("30-minute plan: viewport moving at \(moving) of \(times.count) times, fastest \(fastest)/s")
    checker.equal(plan.frameState(at: 0).viewportVelocity, ViewportVelocity.zero, "the camera is at rest at time zero")
    checker.equal(
        plan.frameState(at: thirtyMinutes).viewportVelocity, ViewportVelocity.zero, "the camera is at rest at the end")
    checker.equal(
        plan.frameState(at: thirtyMinutes + 0.5).viewport, plan.frameState(at: thirtyMinutes).viewport,
        "past the end the viewport holds its last value")
    if let first = plan.zoomSegments.first {
        let zoomingIn = plan.frameState(at: first.start + 0.1)
        checker.check(
            zoomingIn.viewportVelocity.width < 0 && zoomingIn.viewportVelocity.height < 0,
            "0.1 s into the first segment the viewport is shrinking (\(zoomingIn.viewportVelocity.width)/s)")
    }
    // The velocity is the slope of the interpolated viewport over the camera
    // interval around `time`: from that interval's first sample, one interval
    // at that velocity lands on its second sample's viewport.
    var predictionError = 0.0
    for time in times.prefix(200) where time > 0 && time < thirtyMinutes {
        let index = Int(time * plan.camera.sampleRate)
        let a = plan.camera.samples[index]
        let b = plan.camera.samples[index + 1]
        let from = Viewport(CameraTimeline.viewport(center: a.center, amount: a.amount))
        let to = Viewport(CameraTimeline.viewport(center: b.center, amount: b.amount))
        let velocity = plan.frameState(at: time).viewportVelocity
        let interval = 1 / plan.camera.sampleRate
        predictionError = max(
            predictionError,
            abs(from.origin.x + velocity.originX * interval - to.origin.x),
            abs(from.origin.y + velocity.originY * interval - to.origin.y),
            abs(from.size.width + velocity.width * interval - to.size.width),
            abs(from.size.height + velocity.height * interval - to.size.height))
    }
    checker.check(
        predictionError < 1e-9,
        "the velocity over a camera interval predicts the interval's next viewport (error \(predictionError))")

    // 9:16 with a camera on the same fixture: the per-canvas state is
    // deterministic too, the ripples never exceed four and agree with a
    // linear scan of the clicks, and the bubble never touches the card.
    var withCamera = LayoutSettings()
    withCamera.bubble = BubbleSettings()
    let vertical = RenderPlan.build(log: log, duration: thirtyMinutes, layout: withCamera)
    let verticalAgain = RenderPlan.build(log: log, duration: thirtyMinutes, layout: withCamera)
    checker.check(
        vertical.clickEffects.clicks.count > 100,
        "the fixture holds hundreds of clicks (\(vertical.clickEffects.clicks.count))")
    let canvas = PixelRect(x: 0, y: 0, width: CanvasSize.vertical1080.width, height: CanvasSize.vertical1080.height)
    var verticalDiffering = 0
    var mostRipples = 0
    var rippleFrames = 0
    var rippleMismatches = 0
    var overlapping = 0
    var escaping = 0
    let rippleWindow = vertical.clickEffects.settings.duration
    for time in times {
        let state = vertical.frameState(at: time, canvas: .vertical1080)
        if state != verticalAgain.frameState(at: time, canvas: .vertical1080) { verticalDiffering += 1 }
        mostRipples = max(mostRipples, state.ripples.count)
        if !state.ripples.isEmpty { rippleFrames += 1 }
        let expected = vertical.clickEffects.clicks.filter { $0.time > time - rippleWindow && $0.time <= time }.suffix(
            4)
        if state.ripples.map(\.click) != Array(expected) { rippleMismatches += 1 }
        if let bubble = state.camera {
            if bubble.rect.intersects(state.layout.card) { overlapping += 1 }
            if !canvas.contains(bubble.rect) { escaping += 1 }
        } else {
            overlapping += 1
        }
        if !canvas.contains(state.layout.card) { escaping += 1 }
    }
    checker.equal(verticalDiffering, 0, "identical inputs give identical 9:16 frame states at all \(times.count) times")
    checker.check(mostRipples <= 4, "never more than four ripples (most \(mostRipples))")
    checker.check(rippleFrames > 0, "some frames show ripples (\(rippleFrames) of \(times.count))")
    checker.equal(rippleMismatches, 0, "the ripples at every time are the clicks of the last half second, newest four")
    checker.equal(overlapping, 0, "the bubble never overlaps the card on 9:16 at any of \(times.count) times")
    checker.equal(escaping, 0, "the card and the bubble stay inside the 9:16 canvas at every time")
    print("30-minute plan on 9:16: ripples on \(rippleFrames) of \(times.count) frames, at most \(mostRipples) at once")

    // Shape changes sprinkled into the fixture, with ties: the plan's list is
    // the log's, and the binary search agrees with a linear scan everywhere.
    let shapeIDs = ["arrow", "iBeam", "pointingHand", "crosshair"]
    var shaped = events
    var shapeTimes: [Double] = []
    for n in 0..<300 {
        let time = random.next(in: 0...thirtyMinutes)
        shapeTimes.append(time)
        shaped.append(.cursorShapeChanged(time: time, shape: cursorShape(shapeIDs[n % shapeIDs.count])))
        if n % 10 == 0 {
            shaped.append(.cursorShapeChanged(time: time, shape: cursorShape("tie-\(n)")))
        }
    }
    let shapedLog = renderPlanLog(shaped)
    let shapedPlan = RenderPlan.build(log: shapedLog, duration: thirtyMinutes)
    var reference: [CursorShapeChange] = []
    for case .cursorShapeChanged(let time, let shape) in shapedLog.events {
        reference.append(CursorShapeChange(time: time, shape: shape))
    }
    checker.equal(reference.count, 330, "the shaped log carries 330 shape changes")
    checker.equal(shapedPlan.cursorShapeChanges, reference, "the plan's shape changes are the log's, in log order")
    checker.equal(shapedPlan.camera, plan.camera, "shape changes do not move the camera")
    checker.equal(shapedPlan.cursor, plan.cursor, "shape changes do not move the cursor")
    var queries = times
    for time in shapeTimes {
        queries += [time, time - 1e-9, time + 1e-9]
    }
    var mismatches = 0
    for time in queries {
        let expected = reference.last(where: { $0.time <= time })?.shape
        if shapedPlan.frameState(at: time).cursorShape != expected { mismatches += 1 }
    }
    checker.equal(mismatches, 0, "the shape at each of \(queries.count) times is the last change at or before it")
}
