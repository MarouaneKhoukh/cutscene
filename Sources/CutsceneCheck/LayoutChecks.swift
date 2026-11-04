import CutsceneCore
import CutsceneEngine
import Foundation

/// Layout and click-effect checks (PLAN M2-01): `ClickEffects` ripples (the
/// §3 curve pinned at five times, at most four concurrent, the kit adapter),
/// `LayoutSolver` (the M1 card rule on 16:9, the bubble bottom-trailing on
/// 16:9 and above or below the card on 9:16 and 1:1, never overlapping it
/// across a sweep of canvases, corners, sizes and paddings) and the
/// `ZoomTrackMerge` replan that keeps locked, `.manual` and unknown segments
/// and cuts the new plan around them. Registered by M2-00; reports through
/// the shared checker so the pass count stays one number.
@MainActor
func runLayoutChecks(_ checker: Checker) {
    checkRippleCurve(checker)
    checkRippleConcurrency(checker)
    checkRippleAdapter(checker)
    checkCardLayout(checker)
    checkBubbleOverlay(checker)
    checkBubbleStacking(checker)
    checkLayoutAdapter(checker)
    checkZoomTrackConversion(checker)
    checkReplan(checker)
}

// MARK: - Helpers

@MainActor
private func checkRect(
    _ checker: Checker, _ actual: PixelRect, x: Double, y: Double, width: Double, height: Double, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let tolerance = 1e-9
    let error = max(abs(actual.x - x), abs(actual.y - y), abs(actual.width - width), abs(actual.height - height))
    checker.check(
        error <= tolerance, "\(message): got \(actual), expected (\(x), \(y), \(width), \(height)) ± \(tolerance)",
        file: file, line: line)
}

private func canvasRect(_ canvas: CanvasSize) -> PixelRect {
    PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
}

private func rectIsFinite(_ rect: PixelRect) -> Bool {
    rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
}

// MARK: - Ripples

/// The §3 ring: radius 0 → 44 over 0.5 s on `1 − (1 − t)³`, stroke 2.5 → 0,
/// opacity 0.65 → 0, pinned at five times worked out by hand, gone at the end.
@MainActor
private func checkRippleCurve(_ checker: Checker) {
    let defaults = ClickRippleSettings()
    checker.equal(defaults.startRadius, 0, "ripple start radius default")
    checker.equal(defaults.endRadius, 44, "ripple end radius default")
    checker.equal(defaults.duration, 0.5, "ripple duration default")
    checker.equal(defaults.curve, .easeOutCubic, "ripple curve default")
    checker.equal(defaults.startStrokeWidth, 2.5, "ripple start stroke default")
    checker.equal(defaults.endStrokeWidth, 0, "ripple end stroke default")
    checker.equal(defaults.startOpacity, 0.65, "ripple start opacity default")
    checker.equal(defaults.endOpacity, 0, "ripple end opacity default")
    checker.equal(defaults.maximumConcurrent, 4, "ripple concurrency default")
    checker.equal(defaults.referenceHeight, 1080, "ripple reference height default")
    checker.equal(RippleCurve.easeOutCubic.apply(0.5), 0.875, "easeOutCubic(0.5) = 1 − 0.5³")
    checker.equal(RippleCurve.easeOutCubic.apply(-1), 0, "easeOutCubic clamps below")
    checker.equal(RippleCurve.easeOutCubic.apply(2), 1, "easeOutCubic clamps above")
    checker.equal(RippleCurve.linear.apply(0.3), 0.3, "linear is the identity")
    checker.equal(RippleCurve.smoothstep.apply(0.5), Easing.smoothstep(0.5), "smoothstep is the shared easing")
    checker.equal(
        RippleCurve.easeInOutCubic.apply(0.25), Easing.easeInOutCubic(0.25), "easeInOutCubic is the shared easing")
    checker.equal(RippleCurve.smootherstep.apply(0.3), Easing.smootherstep(0.3), "smootherstep is the shared easing")

    let point = NormalizedPoint(x: 0.3, y: 0.4)
    let effects = ClickEffects(clicks: [ClickEvent(time: 1, position: point, button: .left)])
    // (time, eased progress, radius, stroke, opacity) by hand: eased = 1 − (1 − p)³.
    let pinned: [(Double, Double, Double, Double, Double)] = [
        (1.0, 0, 0, 2.5, 0.65),
        (1.1, 0.488, 21.472, 1.28, 0.3328),
        (1.2, 0.784, 34.496, 0.54, 0.1404),
        (1.3, 0.936, 41.184, 0.16, 0.0416),
        (1.4, 0.992, 43.648, 0.02, 0.0052),
    ]
    for (time, eased, radius, stroke, opacity) in pinned {
        let ripples = effects.ripples(at: time)
        checker.equal(ripples.count, 1, "one ripple at \(time) s")
        guard let ripple = ripples.first else { continue }
        checker.close(ripple.progress, (time - 1) / 0.5, "raw progress at \(time) s")
        checker.close(ClickRippleSettings().curve.apply(ripple.progress), eased, "eased progress at \(time) s")
        checker.close(ripple.radius, radius, "radius at \(time) s")
        checker.close(ripple.strokeWidth, stroke, "stroke width at \(time) s")
        checker.close(ripple.opacity, opacity, "opacity at \(time) s")
        checker.equal(ripple.position, point, "the ring is centred on the click")
        checker.equal(ripple.click.button, .left, "the ring remembers its button")
    }
    checker.equal(effects.ripples(at: 0.999), [], "no ripple before the click")
    checker.equal(effects.ripples(at: 1.5), [], "the ripple is gone at exactly its end")
    checker.equal(effects.ripples(at: 3), [], "no ripple long after")
    checker.equal(effects.ripples(at: Double.nan), [], "a NaN time has no ripples")
    checker.equal(ClickEffects(clicks: []).ripples(at: 1), [], "no clicks, no ripples")

    var linear = ClickRippleSettings()
    linear.curve = .linear
    let straight = ClickEffects(clicks: effects.clicks, settings: linear).ripples(at: 1.1)
    checker.close(straight.first?.radius ?? -1, 8.8, "a linear ripple is a fifth of the way at a fifth of the time")
    checker.close(straight.first?.strokeWidth ?? -1, 2.0, "a linear stroke at a fifth of the time")
    checker.close(straight.first?.opacity ?? -1, 0.52, "a linear opacity at a fifth of the time")

    var off = ClickRippleSettings()
    off.enabled = false
    checker.equal(ClickEffects(clicks: effects.clicks, settings: off).ripples(at: 1.1), [], "disabled draws nothing")
    var instant = ClickRippleSettings()
    instant.duration = 0
    checker.equal(
        ClickEffects(clicks: effects.clicks, settings: instant).ripples(at: 1), [], "a zero duration draws nothing")
    var none = ClickRippleSettings()
    none.maximumConcurrent = 0
    checker.equal(
        ClickEffects(clicks: effects.clicks, settings: none).ripples(at: 1.1), [], "zero concurrent draws nothing")

    let doubled = effects.ripples(at: 1.1).map { $0.scaled(by: 2) }
    checker.close(doubled.first?.radius ?? -1, 42.944, "scaling doubles the radius")
    checker.close(doubled.first?.strokeWidth ?? -1, 2.56, "scaling doubles the stroke")
    checker.close(doubled.first?.opacity ?? -1, 0.3328, "scaling leaves the opacity")
}

/// At most four rings at once, the newest winning; clicks read from a log in
/// any order; the end of the window is exact.
@MainActor
private func checkRippleConcurrency(_ checker: Checker) {
    // Click times that are exact in binary (multiples of 1/16), so the window
    // edges below test the comparison and not floating-point rounding.
    let point = NormalizedPoint(x: 0.5, y: 0.5)
    let clicks = (0...4).map { ClickEvent(time: Double($0) * 0.0625, position: point, button: .left) }
    let effects = ClickEffects(clicks: clicks.reversed())
    checker.equal(effects.clicks.map(\.time), [0, 0.0625, 0.125, 0.1875, 0.25], "clicks are sorted by time")
    let crowded = effects.ripples(at: 0.375)
    checker.equal(crowded.count, 4, "five clicks inside one duration draw four rings")
    checker.equal(
        crowded.map(\.click.time), [0.0625, 0.125, 0.1875, 0.25], "the oldest ring ends early, oldest first")
    checker.check(
        zip(crowded, crowded.dropFirst()).allSatisfy { $0.radius > $1.radius },
        "older rings are larger (\(crowded.map(\.radius)))")
    checker.equal(
        effects.ripples(at: 0.5625).map(\.click.time), [0.125, 0.1875, 0.25], "the window is (t − duration, t]")
    checker.equal(
        effects.ripples(at: 0.5).map(\.click.time), [0.0625, 0.125, 0.1875, 0.25], "a click at t − duration is out")
    checker.equal(effects.ripples(at: 0).map(\.click.time), [0], "a click at t is in")
    var two = ClickRippleSettings()
    two.maximumConcurrent = 2
    checker.equal(
        ClickEffects(clicks: clicks, settings: two).ripples(at: 0.375).map(\.click.time), [0.1875, 0.25],
        "the newest two win at a cap of two")

    let ties = ClickEffects(clicks: [
        ClickEvent(time: 2, position: point, button: .right),
        ClickEvent(time: Double.nan, position: point, button: .left),
        ClickEvent(time: 2, position: point, button: .left),
        ClickEvent(time: 1, position: point, button: .other(3)),
    ])
    checker.equal(ties.clicks.map(\.time), [1, 2, 2], "a NaN click is dropped, the rest sorted")
    checker.equal(ties.clicks.map(\.button), [.other(3), .right, .left], "equal times keep their order")

    var log = renderPlanLog([])
    log.append(contentsOf: click(at: 1, NormalizedPoint(x: 0.2, y: 0.8)))
    log.append(.buttonDown(time: 2, position: NormalizedPoint(x: 0.6, y: 0.1), button: .right))
    log.append(.buttonUp(time: 2.1, position: NormalizedPoint(x: 0.6, y: 0.1), button: .right))
    log.append(.pointerMoved(time: 2.5, position: point))
    let fromLog = ClickEffects(log: log)
    checker.equal(fromLog.clicks.count, 2, "only button-downs are clicks")
    checker.equal(fromLog.clicks.map(\.time), [1, 2], "clicks come in log order")
    checker.equal(fromLog.clicks[1].button, .right, "the button is read from the log")
    checker.equal(fromLog.clicks[0].position, NormalizedPoint(x: 0.2, y: 0.8), "the position is read from the log")
}

/// The kit's click group reaches every field; the default kit is the default settings.
@MainActor
private func checkRippleAdapter(_ checker: Checker) {
    checker.equal(ClickRippleSettings(kit: .default), ClickRippleSettings(), "the default kit maps to the defaults")
    var kit = BrandKit.default
    kit.cursor.click.enabled = false
    kit.cursor.click.startRadius = 4
    kit.cursor.click.endRadius = 60
    kit.cursor.click.duration = 0.8
    kit.cursor.click.easing = .smootherstep
    kit.cursor.click.startStrokeWidth = 3
    kit.cursor.click.endStrokeWidth = 1
    kit.cursor.click.startOpacity = 0.9
    kit.cursor.click.endOpacity = 0.1
    kit.cursor.click.maximumConcurrent = 2
    kit.frame.referenceHeight = 2160
    let settings = ClickRippleSettings(kit: kit)
    checker.equal(settings.enabled, false, "enabled reaches the settings")
    checker.equal(settings.startRadius, 4, "startRadius reaches the settings")
    checker.equal(settings.endRadius, 60, "endRadius reaches the settings")
    checker.equal(settings.duration, 0.8, "duration reaches the settings")
    checker.equal(settings.curve, .smootherstep, "easing reaches the settings")
    checker.equal(settings.startStrokeWidth, 3, "startStrokeWidth reaches the settings")
    checker.equal(settings.endStrokeWidth, 1, "endStrokeWidth reaches the settings")
    checker.equal(settings.startOpacity, 0.9, "startOpacity reaches the settings")
    checker.equal(settings.endOpacity, 0.1, "endOpacity reaches the settings")
    checker.equal(settings.maximumConcurrent, 2, "maximumConcurrent reaches the settings")
    checker.equal(settings.referenceHeight, 2160, "the frame's reference height reaches the settings")
    for easing in RippleEasing.allCases {
        checker.equal(
            RippleCurve(style: easing), RippleCurve.allCases.first { "\($0)" == easing.rawValue },
            "the curve \(easing.rawValue) maps by name")
    }
}

// MARK: - Layout

/// The card alone: the M1 compositor's rule (padding on the shorter side,
/// aspect-fit, centred), pinned by hand on 16:9, 4K and the narrow canvases,
/// plus the guards.
@MainActor
private func checkCardLayout(_ checker: Checker) {
    let defaults = LayoutSettings()
    checker.equal(defaults.padding, 0.06, "layout padding default")
    checker.equal(defaults.cornerRadius, 18, "layout corner radius default")
    checker.equal(defaults.referenceHeight, 1080, "layout reference height default")
    checker.equal(defaults.bubble, nil, "no bubble by default")
    checker.close(defaults.minimumOverlayAspect, 4.0 / 3.0, "4:3 is the narrowest canvas that overlays")
    checker.equal(defaults.stackGap, 0.03, "stack gap default")
    checker.equal(defaults.maximumPadding, 0.49, "padding cap default")
    checker.close(defaults.fallbackContentAspectRatio, 16.0 / 9.0, "fallback content aspect default")
    checker.equal(CanvasSize.hd1080, CanvasSize(width: 1920, height: 1080), "the reference canvas is 1080p")
    checker.equal(CanvasSize.vertical1080, CanvasSize(width: 1080, height: 1920), "the vertical preset is 9:16")
    checker.equal(CanvasSize.square1080, CanvasSize(width: 1080, height: 1080), "the square preset is 1:1")
    checker.close(CanvasSize.hd1080.aspectRatio, 16.0 / 9.0, "a canvas knows its aspect")

    // 1080p, 16:9 content: padding 64.8, available 1790.4 × 950.4, height-bound.
    let wide = 16.0 / 9.0
    let hd = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide)
    checkRect(checker, hd.card, x: 115.2, y: 64.8, width: 1689.6, height: 950.4, "the 1080p card is the M1 card")
    checker.equal(hd.cornerRadius, 18, "the 1080p radius is the kit's")
    checker.equal(hd.pixelScale, 1, "1080p is the reference scale")
    checker.equal(hd.bubble, nil, "no bubble without a camera")
    checker.equal(hd.canvas, CanvasSize.hd1080, "the layout carries its canvas")
    let uhd = LayoutSolver.solve(canvas: .uhd2160, contentAspectRatio: wide)
    checkRect(checker, uhd.card, x: 230.4, y: 129.6, width: 3379.2, height: 1900.8, "the 4K card is the 1080p card × 2")
    checker.equal(uhd.cornerRadius, 36, "the 4K radius is doubled")
    checker.equal(uhd.pixelScale, 2, "4K is twice the reference")
    // Tall content on 16:9 is width-free, height-bound: a 3:4 window.
    let tall = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: 0.75)
    checkRect(checker, tall.card, x: 603.6, y: 64.8, width: 712.8, height: 950.4, "tall content is height-bound")
    // 16:9 content on 9:16 is width-bound: 950.4 wide, 534.6 tall, centred.
    let vertical = LayoutSolver.solve(canvas: .vertical1080, contentAspectRatio: wide)
    checkRect(checker, vertical.card, x: 64.8, y: 692.7, width: 950.4, height: 534.6, "the 9:16 card is width-bound")
    checker.equal(vertical.pixelScale, 1, "9:16 at 1080 wide scales by its shorter side, like the padding")
    checker.equal(vertical.cornerRadius, 18, "the 9:16 radius is the 1080p radius")
    let square = LayoutSolver.solve(canvas: .square1080, contentAspectRatio: wide)
    checkRect(checker, square.card, x: 64.8, y: 272.7, width: 950.4, height: 534.6, "the 1:1 card is width-bound")

    var tight = LayoutSettings()
    tight.padding = 0
    checkRect(
        checker, LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: tight).card, x: 0, y: 0,
        width: 1920, height: 1080, "zero padding fills the frame")
    tight.padding = 0.8
    let capped = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: tight).card
    checker.check(capped.width > 0 && capped.height > 0, "padding is capped so the card keeps a size (\(capped))")
    checkRect(checker, capped, x: 940.8, y: 529.2, width: 38.4, height: 21.6, "padding caps at 0.49 of the short side")
    tight.padding = -1
    checkRect(
        checker, LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: tight).card, x: 0, y: 0,
        width: 1920, height: 1080, "negative padding is zero")

    var reference = LayoutSettings()
    reference.referenceHeight = 2160
    checker.equal(
        LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: reference).cornerRadius, 9,
        "a 4K-quoted kit halves its radius at 1080p")
    reference.referenceHeight = 0
    checker.equal(
        LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: reference).pixelScale, 1,
        "a zero reference height scales by one")
    reference.cornerRadius = -5
    checker.equal(
        LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: reference).cornerRadius, 0,
        "a negative radius is zero")

    for (name, canvas) in [
        ("zero", CanvasSize(width: 0, height: 0)), ("NaN", CanvasSize(width: .nan, height: .nan)),
        ("infinite", CanvasSize(width: .infinity, height: 1080)),
    ] {
        let layout = LayoutSolver.solve(canvas: canvas, contentAspectRatio: wide)
        checker.check(rectIsFinite(layout.card), "a \(name) canvas still lays out a finite card (\(layout.card))")
    }
    for (name, aspect) in [("zero", 0.0), ("negative", -2.0), ("NaN", Double.nan), ("infinite", Double.infinity)] {
        let layout = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: aspect)
        checker.check(rectIsFinite(layout.card), "a \(name) content aspect still lays out a finite card")
        checkRect(
            checker, layout.card, x: 484.8, y: 64.8, width: 950.4, height: 950.4, "a \(name) aspect lays out square")
    }

    let a = PixelRect(x: 0, y: 0, width: 10, height: 10)
    checker.check(a.intersects(PixelRect(x: 5, y: 5, width: 10, height: 10)), "overlapping rects intersect")
    checker.check(!a.intersects(PixelRect(x: 10, y: 0, width: 10, height: 10)), "touching rects do not intersect")
    checker.check(a.contains(PixelRect(x: 0, y: 0, width: 10, height: 10)), "a rect contains itself")
    checker.check(!a.contains(PixelRect(x: 1, y: 1, width: 10, height: 10)), "a rect does not contain an overhang")
    checker.equal(a.maxX, 10, "maxX")
    checker.equal(a.maxY, 10, "maxY")
}

/// On 16:9 the bubble takes a canvas corner over the card, inset from the
/// edges, at its size as a fraction of the canvas height.
@MainActor
private func checkBubbleOverlay(_ checker: Checker) {
    let wide = 16.0 / 9.0
    var settings = LayoutSettings()
    settings.bubble = BubbleSettings()
    checker.equal(BubbleSettings().size, 0.20, "bubble size default")
    checker.equal(BubbleSettings().inset, 0.03, "bubble inset default")
    checker.equal(BubbleSettings().corner, .bottomTrailing, "bubble corner default")
    checker.equal(BubbleSettings().outline, .roundedRectangle, "bubble outline default")
    checker.equal(BubbleSettings().borderWidth, 0, "bubble border default")

    let hd = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: settings)
    checkRect(checker, hd.card, x: 115.2, y: 64.8, width: 1689.6, height: 950.4, "the card ignores an overlaid bubble")
    guard let bubble = hd.bubble else {
        checker.check(false, "a 16:9 layout with a camera has a bubble")
        return
    }
    checkRect(checker, bubble.rect, x: 1671.6, y: 831.6, width: 216, height: 216, "bottom-trailing, inset 32.4")
    checker.equal(bubble.arrangement, .overlay, "on 16:9 the bubble overlays the card")
    checker.check(bubble.rect.intersects(hd.card), "on 16:9 the bubble sits over the card by design")
    checker.equal(bubble.outline, .roundedRectangle, "the outline is the settings'")
    checker.equal(bubble.cornerRadius, 18, "a rounded bubble shares the card's radius")
    checker.equal(bubble.borderWidth, 0, "no border by default")
    checker.check(canvasRect(.hd1080).contains(bubble.rect), "the bubble is inside the canvas")

    let corners: [(BubbleCorner, Double, Double)] = [
        (.bottomLeading, 32.4, 831.6), (.bottomTrailing, 1671.6, 831.6), (.topLeading, 32.4, 32.4),
        (.topTrailing, 1671.6, 32.4),
    ]
    for (corner, x, y) in corners {
        settings.bubble?.corner = corner
        let layout = LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: settings)
        checkRect(
            checker, layout.bubble?.rect ?? PixelRect(x: -1, y: -1, width: 0, height: 0), x: x, y: y, width: 216,
            height: 216, "the \(corner) bubble on 16:9")
        checker.equal(layout.bubble?.arrangement, .overlay, "every corner overlays on 16:9")
    }
    settings.bubble?.corner = .bottomTrailing
    settings.bubble?.borderWidth = 3
    settings.bubble?.outline = .roundedRectangle
    let uhd = LayoutSolver.solve(canvas: .uhd2160, contentAspectRatio: wide, settings: settings)
    checkRect(
        checker, uhd.bubble?.rect ?? PixelRect(x: -1, y: -1, width: 0, height: 0), x: 3343.2, y: 1663.2, width: 432,
        height: 432, "the 4K bubble is the 1080p one × 2")
    checker.equal(uhd.bubble?.borderWidth, 6, "the border scales with the canvas")
    checker.equal(uhd.bubble?.outline, .roundedRectangle, "the outline reaches the placement")
    checker.equal(uhd.bubble?.cornerRadius, 36, "the rounded bubble's radius is the 4K card's")

    // 4:3 still overlays; anything narrower stacks.
    let fourThree = LayoutSolver.solve(
        canvas: CanvasSize(width: 1440, height: 1080), contentAspectRatio: wide,
        settings: settings)
    checker.equal(fourThree.bubble?.arrangement, .overlay, "4:3 overlays")
    let fiveFour = LayoutSolver.solve(
        canvas: CanvasSize(width: 1350, height: 1080), contentAspectRatio: wide,
        settings: settings)
    checker.equal(fiveFour.bubble?.arrangement, .belowCard, "5:4 stacks")
    settings.minimumOverlayAspect = 2
    checker.equal(
        LayoutSolver.solve(canvas: .hd1080, contentAspectRatio: wide, settings: settings).bubble?.arrangement,
        .belowCard, "the overlay threshold is a tunable")
}

/// On 9:16 and 1:1 the card gives up a band and the bubble goes above or
/// below it: pinned by hand for the presets, then swept over canvases,
/// corners, outlines, sizes, paddings and content aspects for the invariant
/// that the bubble never overlaps the card and both stay inside the canvas.
@MainActor
private func checkBubbleStacking(_ checker: Checker) {
    let wide = 16.0 / 9.0
    var settings = LayoutSettings()
    settings.bubble = BubbleSettings()

    // 9:16, bottom-trailing: padding 64.8, available 950.4 × 1790.4, bubble
    // 384, gap 57.6; the card is width-bound at 534.6 tall, the stack 976.2
    // tall starts at 471.9.
    let vertical = LayoutSolver.solve(canvas: .vertical1080, contentAspectRatio: wide, settings: settings)
    checkRect(checker, vertical.card, x: 64.8, y: 471.9, width: 950.4, height: 534.6, "the 9:16 card above the bubble")
    checkRect(
        checker, vertical.bubble?.rect ?? PixelRect(x: -1, y: -1, width: 0, height: 0), x: 348, y: 1064.1, width: 384,
        height: 384, "the 9:16 bubble below the card, centred on it")
    checker.equal(vertical.bubble?.arrangement, .belowCard, "a bottom corner stacks the bubble below")
    checker.check(!(vertical.bubble?.rect.intersects(vertical.card) ?? true), "the 9:16 bubble clears the card")
    checker.close(
        (vertical.bubble?.rect.y ?? 0) - vertical.card.maxY, 57.6, "the stack gap separates the bubble from the card")
    checker.close(
        vertical.card.y - 64.8, 1920 - 64.8 - (vertical.bubble?.rect.maxY ?? 0),
        "the stack is centred in the available height")

    // 1:1, top-leading: available 950.4 square, bubble 216, gap 32.4; the
    // stack is 783 tall and starts at 148.5.
    settings.bubble?.corner = .topLeading
    let square = LayoutSolver.solve(canvas: .square1080, contentAspectRatio: wide, settings: settings)
    checkRect(
        checker, square.bubble?.rect ?? PixelRect(x: -1, y: -1, width: 0, height: 0), x: 432, y: 148.5, width: 216,
        height: 216, "the 1:1 bubble above the card, centred on it")
    checkRect(checker, square.card, x: 64.8, y: 396.9, width: 950.4, height: 534.6, "the 1:1 card below the bubble")
    checker.equal(square.bubble?.arrangement, .aboveCard, "a top corner stacks the bubble above")
    checker.check(!(square.bubble?.rect.intersects(square.card) ?? true), "the 1:1 bubble clears the card")
    settings.bubble?.corner = .bottomTrailing
    var wider = settings
    wider.stackGap = 0.1
    let spaced = LayoutSolver.solve(canvas: .square1080, contentAspectRatio: wide, settings: wider)
    checker.close(
        (spaced.bubble?.rect.y ?? 0) - spaced.card.maxY, 108, "the stack gap is a tunable fraction of the height")

    // The sweep.
    let canvases: [(String, CanvasSize)] = [
        ("9:16", .vertical1080), ("1:1", .square1080), ("4:5", CanvasSize(width: 1080, height: 1350)),
        ("9:16 at 720", CanvasSize(width: 720, height: 1280)), ("5:4", CanvasSize(width: 1350, height: 1080)),
    ]
    var solved = 0
    var overlapping: [String] = []
    var escaping: [String] = []
    var misarranged: [String] = []
    for (name, canvas) in canvases {
        for corner in BubbleCorner.allCases {
            for outline in BubbleOutline.allCases {
                for size in [0.1, 0.2, 0.3, 0.45] {
                    for padding in [0.0, 0.06, 0.12] {
                        for aspect in [wide, 4.0 / 3.0, 1.0, 0.6, 2.4] {
                            var sweep = LayoutSettings()
                            sweep.padding = padding
                            var bubble = BubbleSettings()
                            bubble.corner = corner
                            bubble.outline = outline
                            bubble.size = size
                            sweep.bubble = bubble
                            let layout = LayoutSolver.solve(canvas: canvas, contentAspectRatio: aspect, settings: sweep)
                            solved += 1
                            let label = "\(name) \(corner) \(outline) size \(size) padding \(padding) aspect \(aspect)"
                            guard let placed = layout.bubble else {
                                misarranged.append(label + ": no bubble")
                                continue
                            }
                            if placed.rect.intersects(layout.card) { overlapping.append(label) }
                            if !canvasRect(canvas).contains(placed.rect) || !canvasRect(canvas).contains(layout.card) {
                                escaping.append(label)
                            }
                            let expected: BubbleArrangement = corner.isTop ? .aboveCard : .belowCard
                            if placed.arrangement != expected { misarranged.append(label) }
                            if abs(layout.card.width / layout.card.height - aspect) > 1e-9 {
                                misarranged.append(label + ": card aspect \(layout.card.width / layout.card.height)")
                            }
                        }
                    }
                }
            }
        }
    }
    checker.equal(solved, 2400, "the sweep solves 2,400 narrow layouts")
    checker.equal(
        overlapping.count, 0, "the bubble never overlaps the card on a narrow canvas: \(overlapping.prefix(3))")
    checker.equal(escaping.count, 0, "the card and the bubble stay inside a narrow canvas: \(escaping.prefix(3))")
    checker.equal(misarranged.count, 0, "every narrow layout stacks as its corner says: \(misarranged.prefix(3))")
}

/// The kit's frame and camera groups reach the layout settings.
@MainActor
private func checkLayoutAdapter(_ checker: Checker) {
    checker.equal(
        LayoutSettings(kit: .default, hasCamera: false), LayoutSettings(), "the default kit maps to the defaults")
    var expected = LayoutSettings()
    expected.bubble = BubbleSettings()
    checker.equal(
        LayoutSettings(kit: .default, hasCamera: true), expected, "a camera adds the default bubble to the defaults")
    var kit = BrandKit.default
    kit.frame.padding = 0.1
    kit.frame.cornerRadius = 24
    kit.frame.referenceHeight = 720
    kit.camera.shape = .roundedRectangle
    kit.camera.size = 0.25
    kit.camera.inset = 0.05
    kit.camera.position = .topLeading
    kit.camera.borderWidth = 4
    let settings = LayoutSettings(kit: kit, hasCamera: true)
    checker.equal(settings.padding, 0.1, "padding reaches the layout")
    checker.equal(settings.cornerRadius, 24, "the corner radius reaches the layout")
    checker.equal(settings.referenceHeight, 720, "the reference height reaches the layout")
    checker.equal(settings.bubble?.outline, .roundedRectangle, "the bubble shape reaches the layout")
    checker.equal(settings.bubble?.size, 0.25, "the bubble size reaches the layout")
    checker.equal(settings.bubble?.inset, 0.05, "the bubble inset reaches the layout")
    checker.equal(settings.bubble?.corner, .topLeading, "the bubble position reaches the layout")
    checker.equal(settings.bubble?.borderWidth, 4, "the bubble border reaches the layout")
    checker.equal(LayoutSettings(kit: kit, hasCamera: false).bubble, nil, "no camera, no bubble, whatever the kit")
    for position in BubblePosition.allCases {
        checker.equal(
            "\(BubbleCorner(style: position))", position.rawValue, "the corner \(position.rawValue) maps by name")
    }
    for shape in BubbleShape.allCases {
        checker.equal("\(BubbleOutline(style: shape))", shape.rawValue, "the outline \(shape.rawValue) maps by name")
    }
}

// MARK: - Zoom track

/// `ZoomSegment` ↔ `ZoomTrackSegment` field for field; the track's segments
/// for the camera planner sorted and cleaned.
@MainActor
private func checkZoomTrackConversion(_ checker: Checker) {
    let focus = NormalizedPoint(x: 0.3, y: 0.7)
    let segment = ZoomSegment(start: 1, end: 3, focus: focus, amount: 2.5)
    let id = UUID()
    let tracked = ZoomTrackSegment(segment, source: .manual, locked: true, id: id, extra: ["note": "x"])
    checker.equal(tracked.id, id, "the given id is kept")
    checker.equal(tracked.start, 1, "start crosses")
    checker.equal(tracked.end, 3, "end crosses")
    checker.equal(tracked.focus, focus, "focus crosses")
    checker.equal(tracked.amount, 2.5, "amount crosses")
    checker.equal(tracked.source, .manual, "the source is as given")
    checker.equal(tracked.locked, true, "locked is as given")
    checker.equal(tracked.extra, ["note": "x"], "extra is as given")
    checker.equal(ZoomSegment(tracked), segment, "the round trip is the identity")
    let planned = ZoomTrackSegment(segment, source: .auto(generation: 3))
    checker.equal(planned.locked, false, "a planned segment is unlocked")
    checker.check(planned.isReplaceableByReplan, "an unlocked auto segment is replaceable")
    checker.check(ZoomTrackSegment(segment, source: .auto(generation: 3)).id != planned.id, "each gets a fresh id")

    let track = ZoomTrack(segments: [
        ZoomTrackSegment(ZoomSegment(start: 5, end: 6, focus: focus, amount: 2), source: .manual),
        ZoomTrackSegment(ZoomSegment(start: 2, end: 2, focus: focus, amount: 2), source: .manual),
        ZoomTrackSegment(ZoomSegment(start: 1, end: 4, focus: focus, amount: 2), source: .auto(generation: 1)),
        ZoomTrackSegment(ZoomSegment(start: .nan, end: 9, focus: focus, amount: 2), source: .manual),
        ZoomTrackSegment(ZoomSegment(start: 8, end: 7, focus: focus, amount: 2), source: .manual),
        ZoomTrackSegment(ZoomSegment(start: 1, end: 2, focus: focus, amount: 3), source: .manual),
    ])
    let segments = ZoomTrackMerge.segments(of: track)
    checker.equal(segments.map(\.start), [1, 1, 5], "the camera gets the spanning segments sorted by start")
    checker.equal(segments.map(\.amount), [2, 3, 2], "equal starts keep the track's order")
    checker.equal(ZoomTrackMerge.segments(of: ZoomTrack()), [], "an empty track has no segments")
}

/// A replan keeps the locked, the manual and the unknown, drops the unlocked
/// `.auto`, and cuts the new plan around what it keeps.
@MainActor
private func checkReplan(_ checker: Checker) {
    let focus = NormalizedPoint(x: 0.5, y: 0.5)
    func auto(_ start: Double, _ end: Double, generation: Int = 1, locked: Bool = false) -> ZoomTrackSegment {
        ZoomTrackSegment(
            ZoomSegment(start: start, end: end, focus: focus, amount: 2), source: .auto(generation: generation),
            locked: locked)
    }
    let locked = auto(5, 7, locked: true)
    let manual = ZoomTrackSegment(ZoomSegment(start: 10, end: 12, focus: focus, amount: 3), source: .manual)
    let unknown = ZoomTrackSegment(
        ZoomSegment(start: 14, end: 15, focus: focus, amount: 2), source: .unknown(kind: "scripted", raw: [:]))
    let track = ZoomTrack(
        segments: [auto(1, 3), locked, manual, unknown, auto(20, 21)], planGeneration: 1, extra: ["tool": "check"])
    let planned = [
        ZoomSegment(start: 0.5, end: 2, focus: NormalizedPoint(x: 0.1, y: 0.1), amount: 2),
        ZoomSegment(start: 4, end: 8, focus: NormalizedPoint(x: 0.2, y: 0.2), amount: 2),
        ZoomSegment(start: 9.8, end: 12.2, focus: focus, amount: 2),
        ZoomSegment(start: 13, end: 16, focus: NormalizedPoint(x: 0.3, y: 0.3), amount: 2),
        ZoomSegment(start: 5.5, end: 6.5, focus: focus, amount: 2),
        ZoomSegment(start: 20, end: 22, focus: focus, amount: 2),
        ZoomSegment(start: 30, end: 30, focus: focus, amount: 2),
        ZoomSegment(start: 31, end: .infinity, focus: focus, amount: 2),
    ]
    let replanned = ZoomTrackMerge.replan(track, with: planned)
    checker.equal(replanned.planGeneration, 2, "a replan bumps the generation")
    checker.equal(replanned.extra, ["tool": "check"], "a replan keeps the track's extra")
    checker.equal(
        replanned.segments.map(\.start), [0.5, 4, 5, 7, 10, 13, 14, 15, 20], "the replanned track, sorted by start")
    checker.equal(
        replanned.segments.map(\.end), [2, 5, 7, 8, 12, 14, 15, 16, 22], "the new plan is cut around the kept")
    checker.check(replanned.segments.contains(locked), "the locked segment survives, id and all")
    checker.check(replanned.segments.contains(manual), "the manual segment survives, id and all")
    checker.check(replanned.segments.contains(unknown), "a segment of an unknown kind survives")
    checker.check(
        !replanned.segments.contains { $0.source == .auto(generation: 1) && !$0.locked },
        "every unlocked generation-1 auto segment is gone")
    checker.equal(
        replanned.segments.filter { $0.source == .auto(generation: 2) }.count, 6, "six new automatic segments")
    checker.check(
        replanned.segments.filter { $0.source == .auto(generation: 2) }.allSatisfy { !$0.locked },
        "new automatic segments are unlocked")
    checker.equal(
        replanned.segments.map(\.focus.x), [0.1, 0.2, 0.5, 0.2, 0.5, 0.3, 0.5, 0.3, 0.5],
        "a cut piece keeps its segment's focus")
    checker.check(
        zip(replanned.segments, replanned.segments.dropFirst()).allSatisfy { $0.end <= $1.start },
        "the replanned track does not overlap")
    checker.equal(Set(replanned.segments.map(\.id)).count, replanned.segments.count, "every segment has its own id")

    let first = ZoomTrackMerge.replan(ZoomTrack(), with: planned.prefix(2).map { $0 })
    checker.equal(first.planGeneration, 1, "the first plan is generation 1")
    checker.equal(
        first.segments.map { ZoomSegment($0) }, Array(planned.prefix(2)), "an empty track takes the plan whole")
    checker.equal(
        first.segments.map(\.source), [.auto(generation: 1), .auto(generation: 1)],
        "the first plan is generation 1 auto")
    let cleared = ZoomTrackMerge.replan(track, with: [])
    checker.equal(cleared.segments.map(\.start), [5, 10, 14], "an empty plan leaves only the kept segments")
    checker.equal(ZoomTrackMerge.replan(ZoomTrack(), with: []).planGeneration, 1, "an empty replan still counts")

    var generous = ZoomTrackMergeSettings()
    checker.equal(generous.minimumAutomaticDuration, 0.5, "minimum automatic duration default")
    generous.minimumAutomaticDuration = 0
    let slivers = ZoomTrackMerge.replan(track, with: planned, settings: generous)
    checker.equal(slivers.segments.count, 11, "with no minimum the slivers around the manual segment stay")
    checker.equal(slivers.segments.map(\.start).prefix(6).map { $0 }, [0.5, 4, 5, 7, 9.8, 10], "the slivers in place")
    generous.minimumAutomaticDuration = 1.5
    let strict = ZoomTrackMerge.replan(track, with: planned, settings: generous)
    checker.equal(
        strict.segments.filter { $0.source == .auto(generation: 2) }.map(\.start), [0.5, 20],
        "a higher minimum drops every short piece")

    // Replanning again replaces only the previous plan: the kept three plus
    // the new plan, however many times.
    let again = ZoomTrackMerge.replan(replanned, with: planned.prefix(1).map { $0 })
    checker.equal(again.planGeneration, 3, "the generation counts replans")
    checker.equal(again.segments.map(\.start), [0.5, 5, 10, 14], "the second replan replaces the first plan only")
}
