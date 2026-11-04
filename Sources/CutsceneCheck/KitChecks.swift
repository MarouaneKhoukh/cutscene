import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation

/// Kit-adapter checks (PLAN M1-05): the default kit against each Engine
/// default and `RenderStyle()`, every field of a fully non-default kit
/// reaching its Engine and style field, and the 1080p-to-4K style scaling.
/// Registered by M1-00; reports through the shared checker so the pass count
/// stays one number.
@MainActor
func runKitChecks(_ checker: Checker) {
    checkSpringAdapter(checker)
    checkDefaultKitMapsToEngineDefaults(checker)
    checkCustomKitReachesEveryEngineField(checker)
    checkKitPlan(checker)
    checkDefaultKitStyle(checker)
    checkStyleScaling(checker)
    checkBackgroundAndColors(checker)
}

// MARK: - Fixtures

/// A kit with every mirrored engine field changed from its default, so an
/// adapter that left one field at the default is caught by name. The values
/// stay ones the planners accept, so the kit can also be planned with.
private let loudKit: BrandKit = {
    var kit = BrandKit.default
    kit.cursor.sampleRate = 120
    kit.cursor.spring = SpringStyle(tension: 300, mass: 2, friction: 50)
    kit.cursor.clickSpring = SpringStyle(tension: 600, mass: 1.5, friction: 45)
    kit.cursor.dragSpring = SpringStyle(tension: 900, mass: 1.2, friction: 35)
    kit.cursor.shakeLegThreshold = 0.02
    kit.cursor.shakeWindow = 0.15
    kit.cursor.maximumInputRate = 90
    kit.cursor.minimumTravel = 1.0 / 1080
    kit.cursor.leadTimeConstant = 0.2
    kit.cursor.clickAnticipationWindow = 0.6
    kit.cursor.clickSpringLead = 0.2
    kit.cursor.idleHoldGap = 0.08
    kit.cursor.settleTimeout = 6
    kit.cursor.disabledRanges = [TimeRange(start: 1, end: 2.5), TimeRange(start: 4, end: 3)]
    kit.cursor.idleFadeDelay = 3
    kit.cursor.fadeOutDuration = 0.5
    kit.cursor.fadeInLead = 0.3
    kit.cursor.pressScale = 0.7
    kit.cursor.pressScaleDuration = 0.15
    kit.cursor.scale = 2.5
    kit.zoom.leadIn = 0.4
    kit.zoom.holdAfter = 3
    kit.zoom.mergeGap = 2
    kit.zoom.trailingIgnore = 1.5
    kit.zoom.amount = 3
    kit.zoom.detectsTypingBursts = false
    kit.zoom.typingBurstMinimumKeys = 4
    kit.zoom.typingBurstMaximumGap = 0.6
    kit.zoom.fallbackFocus = NormalizedPoint(x: 0.25, y: 0.75)
    kit.zoom.camera.sampleRate = 90
    kit.zoom.camera.retargetInterval = 0.01
    kit.zoom.camera.spring = SpringStyle(tension: 250, mass: 2, friction: 45)
    kit.zoom.camera.deadZoneWidth = 0.4
    kit.zoom.camera.deadZoneHeight = 0.6
    kit.zoom.camera.preAimThreshold = 1.001
    kit.zoom.camera.fallbackFocus = NormalizedPoint(x: 0.3, y: 0.6)
    kit.background.kind = .solid
    kit.background.solid = KitColor(rgb: 0x10_20_30)
    kit.background.gradient = GradientStyle(
        from: KitColor(rgb: 0xAB_CD_EF), to: KitColor(rgb: 0x12_34_56), angleDegrees: 120)
    kit.frame.padding = 0.1
    kit.frame.cornerRadius = 24
    kit.frame.shadow.offsetX = 4
    kit.frame.shadow.offsetY = 12
    kit.frame.shadow.blurRadius = 30
    kit.frame.shadow.opacity = 0.4
    return kit
}()

/// A log with one click, enough for a plan to carry a zoom segment.
private let oneClickLog: EventLog = {
    let point = NormalizedPoint(x: 0.3, y: 0.6)
    return EventLog(
        startHostTimeSeconds: 0, captureRectPoints: PointRect(x: 0, y: 0, width: 1920, height: 1080), displayID: 1,
        pointPixelScale: 2, samplingRateHz: 125,
        events: [
            .pointerMoved(time: 0, position: point),
            .buttonDown(time: 1, position: point, button: .left),
            .buttonUp(time: 1.08, position: point, button: .left),
        ])
}()

// MARK: - Springs

/// `SpringParameters(style:)` lands on the engine preset of the same name
/// for every preset, and reads nothing from a kit's `extra`.
@MainActor
private func checkSpringAdapter(_ checker: Checker) {
    let presets: [(String, SpringStyle, SpringParameters)] = [
        ("mellow", .mellow, .mellow), ("slow", .slow, .slow), ("smooth", .smooth, .smooth), ("fast", .fast, .fast),
        ("snappy", .snappy, .snappy), ("drag", .drag, .drag), ("camera", .camera, .camera),
    ]
    for (name, style, parameters) in presets {
        checker.equal(SpringParameters(style: style), parameters, "the kit's \(name) spring is the engine's")
    }
    let custom = SpringStyle(tension: 123, mass: 4.5, friction: 6.7, extra: ["damping": 9])
    checker.equal(
        SpringParameters(style: custom), SpringParameters(tension: 123, mass: 4.5, friction: 6.7),
        "a custom spring maps tension, mass and friction and ignores extra")
}

// MARK: - Default kit against the engine defaults

/// `BrandKit.default` maps to each Engine default, field by field and then
/// as a whole, so one set of defaults exists.
@MainActor
private func checkDefaultKitMapsToEngineDefaults(_ checker: Checker) {
    let cursor = CursorSmootherSettings(kit: .default)
    let cursorDefaults = CursorSmootherSettings()
    checker.equal(cursor.sampleRate, cursorDefaults.sampleRate, "default kit: cursor sampleRate")
    checker.equal(cursor.spring, cursorDefaults.spring, "default kit: cursor spring")
    checker.equal(cursor.clickSpring, cursorDefaults.clickSpring, "default kit: cursor clickSpring")
    checker.equal(cursor.dragSpring, cursorDefaults.dragSpring, "default kit: cursor dragSpring")
    checker.equal(cursor.shakeLegThreshold, cursorDefaults.shakeLegThreshold, "default kit: cursor shakeLegThreshold")
    checker.equal(cursor.shakeWindow, cursorDefaults.shakeWindow, "default kit: cursor shakeWindow")
    checker.equal(cursor.maximumInputRate, cursorDefaults.maximumInputRate, "default kit: cursor maximumInputRate")
    checker.equal(cursor.minimumTravel, cursorDefaults.minimumTravel, "default kit: cursor minimumTravel")
    checker.equal(cursor.leadTimeConstant, cursorDefaults.leadTimeConstant, "default kit: cursor leadTimeConstant")
    checker.equal(
        cursor.clickAnticipationWindow, cursorDefaults.clickAnticipationWindow,
        "default kit: cursor clickAnticipationWindow")
    checker.equal(cursor.clickSpringLead, cursorDefaults.clickSpringLead, "default kit: cursor clickSpringLead")
    checker.equal(cursor.idleHoldGap, cursorDefaults.idleHoldGap, "default kit: cursor idleHoldGap")
    checker.equal(cursor.settleTimeout, cursorDefaults.settleTimeout, "default kit: cursor settleTimeout")
    checker.equal(cursor.disabledRanges, cursorDefaults.disabledRanges, "default kit: cursor disabledRanges")
    checker.equal(cursor.idleFadeDelay, cursorDefaults.idleFadeDelay, "default kit: cursor idleFadeDelay")
    checker.equal(cursor.fadeOutDuration, cursorDefaults.fadeOutDuration, "default kit: cursor fadeOutDuration")
    checker.equal(cursor.fadeInLead, cursorDefaults.fadeInLead, "default kit: cursor fadeInLead")
    checker.equal(cursor.pressScale, cursorDefaults.pressScale, "default kit: cursor pressScale")
    checker.equal(
        cursor.pressScaleDuration, cursorDefaults.pressScaleDuration, "default kit: cursor pressScaleDuration")
    checker.equal(cursor, cursorDefaults, "the default kit is the default CursorSmootherSettings")

    let zoom = ZoomPlannerSettings(kit: .default)
    let zoomDefaults = ZoomPlannerSettings()
    checker.equal(zoom.leadIn, zoomDefaults.leadIn, "default kit: zoom leadIn")
    checker.equal(zoom.holdAfter, zoomDefaults.holdAfter, "default kit: zoom holdAfter")
    checker.equal(zoom.mergeGap, zoomDefaults.mergeGap, "default kit: zoom mergeGap")
    checker.equal(zoom.trailingIgnore, zoomDefaults.trailingIgnore, "default kit: zoom trailingIgnore")
    checker.equal(zoom.amount, zoomDefaults.amount, "default kit: zoom amount")
    checker.equal(zoom.detectsTypingBursts, zoomDefaults.detectsTypingBursts, "default kit: zoom detectsTypingBursts")
    checker.equal(
        zoom.typingBurstMinimumKeys, zoomDefaults.typingBurstMinimumKeys, "default kit: zoom typingBurstMinimumKeys")
    checker.equal(
        zoom.typingBurstMaximumGap, zoomDefaults.typingBurstMaximumGap, "default kit: zoom typingBurstMaximumGap")
    checker.equal(zoom.fallbackFocus, zoomDefaults.fallbackFocus, "default kit: zoom fallbackFocus")
    checker.equal(zoom, zoomDefaults, "the default kit is the default ZoomPlannerSettings")

    let camera = CameraPlannerSettings(kit: .default)
    let cameraDefaults = CameraPlannerSettings()
    checker.equal(camera.sampleRate, cameraDefaults.sampleRate, "default kit: camera sampleRate")
    checker.equal(camera.retargetInterval, cameraDefaults.retargetInterval, "default kit: camera retargetInterval")
    checker.equal(camera.spring, cameraDefaults.spring, "default kit: camera spring")
    checker.equal(camera.deadZoneWidth, cameraDefaults.deadZoneWidth, "default kit: camera deadZoneWidth")
    checker.equal(camera.deadZoneHeight, cameraDefaults.deadZoneHeight, "default kit: camera deadZoneHeight")
    checker.equal(camera.preAimThreshold, cameraDefaults.preAimThreshold, "default kit: camera preAimThreshold")
    checker.equal(camera.fallbackFocus, cameraDefaults.fallbackFocus, "default kit: camera fallbackFocus")
    checker.equal(camera, cameraDefaults, "the default kit is the default CameraPlannerSettings")

    // The group-level adapters are what the kit-level ones read.
    checker.equal(CursorSmootherSettings(style: BrandKit.default.cursor), cursor, "cursor group adapter")
    checker.equal(ZoomPlannerSettings(style: BrandKit.default.zoom), zoom, "zoom group adapter")
    checker.equal(CameraPlannerSettings(style: BrandKit.default.zoom.camera), camera, "camera group adapter")
}

// MARK: - A non-default kit reaches every engine field

/// Every mirrored field of `loudKit` lands in its Engine field, so no adapter
/// line is missing or copied from a neighbour.
@MainActor
private func checkCustomKitReachesEveryEngineField(_ checker: Checker) {
    let cursor = CursorSmootherSettings(kit: loudKit)
    checker.equal(cursor.sampleRate, 120, "loud kit: cursor sampleRate")
    checker.equal(cursor.spring, SpringParameters(tension: 300, mass: 2, friction: 50), "loud kit: cursor spring")
    checker.equal(
        cursor.clickSpring, SpringParameters(tension: 600, mass: 1.5, friction: 45), "loud kit: cursor clickSpring")
    checker.equal(
        cursor.dragSpring, SpringParameters(tension: 900, mass: 1.2, friction: 35), "loud kit: cursor dragSpring")
    checker.equal(cursor.shakeLegThreshold, 0.02, "loud kit: cursor shakeLegThreshold")
    checker.equal(cursor.shakeWindow, 0.15, "loud kit: cursor shakeWindow")
    checker.equal(cursor.maximumInputRate, 90, "loud kit: cursor maximumInputRate")
    checker.equal(cursor.minimumTravel, 1.0 / 1080, "loud kit: cursor minimumTravel")
    checker.equal(cursor.leadTimeConstant, 0.2, "loud kit: cursor leadTimeConstant")
    checker.equal(cursor.clickAnticipationWindow, 0.6, "loud kit: cursor clickAnticipationWindow")
    checker.equal(cursor.clickSpringLead, 0.2, "loud kit: cursor clickSpringLead")
    checker.equal(cursor.idleHoldGap, 0.08, "loud kit: cursor idleHoldGap")
    checker.equal(cursor.settleTimeout, 6, "loud kit: cursor settleTimeout")
    // The second kit range runs backwards; it collapses to its start rather
    // than trapping in `ClosedRange`.
    checker.equal(
        cursor.disabledRanges, [1...2.5, 4...4], "loud kit: cursor disabledRanges, a backwards one collapsed")
    checker.equal(cursor.idleFadeDelay, 3, "loud kit: cursor idleFadeDelay")
    checker.equal(cursor.fadeOutDuration, 0.5, "loud kit: cursor fadeOutDuration")
    checker.equal(cursor.fadeInLead, 0.3, "loud kit: cursor fadeInLead")
    checker.equal(cursor.pressScale, 0.7, "loud kit: cursor pressScale")
    checker.equal(cursor.pressScaleDuration, 0.15, "loud kit: cursor pressScaleDuration")
    checker.check(cursor != CursorSmootherSettings(), "the loud kit's cursor settings differ from the defaults")

    let zoom = ZoomPlannerSettings(kit: loudKit)
    checker.equal(zoom.leadIn, 0.4, "loud kit: zoom leadIn")
    checker.equal(zoom.holdAfter, 3, "loud kit: zoom holdAfter")
    checker.equal(zoom.mergeGap, 2, "loud kit: zoom mergeGap")
    checker.equal(zoom.trailingIgnore, 1.5, "loud kit: zoom trailingIgnore")
    checker.equal(zoom.amount, 3, "loud kit: zoom amount")
    checker.equal(zoom.detectsTypingBursts, false, "loud kit: zoom detectsTypingBursts")
    checker.equal(zoom.typingBurstMinimumKeys, 4, "loud kit: zoom typingBurstMinimumKeys")
    checker.equal(zoom.typingBurstMaximumGap, 0.6, "loud kit: zoom typingBurstMaximumGap")
    checker.equal(zoom.fallbackFocus, NormalizedPoint(x: 0.25, y: 0.75), "loud kit: zoom fallbackFocus")
    checker.check(zoom != ZoomPlannerSettings(), "the loud kit's zoom settings differ from the defaults")

    let camera = CameraPlannerSettings(kit: loudKit)
    checker.equal(camera.sampleRate, 90, "loud kit: camera sampleRate")
    checker.equal(camera.retargetInterval, 0.01, "loud kit: camera retargetInterval")
    checker.equal(camera.spring, SpringParameters(tension: 250, mass: 2, friction: 45), "loud kit: camera spring")
    checker.equal(camera.deadZoneWidth, 0.4, "loud kit: camera deadZoneWidth")
    checker.equal(camera.deadZoneHeight, 0.6, "loud kit: camera deadZoneHeight")
    checker.equal(camera.preAimThreshold, 1.001, "loud kit: camera preAimThreshold")
    checker.equal(camera.fallbackFocus, NormalizedPoint(x: 0.3, y: 0.6), "loud kit: camera fallbackFocus")
    checker.check(camera != CameraPlannerSettings(), "the loud kit's camera settings differ from the defaults")
}

// MARK: - Planning with a kit

/// `RenderPlan.build(log:duration:kit:)` is the three adapters applied to
/// the three-settings build: the default kit plans as the defaults do, and a
/// kit's zoom amount reaches the segments.
@MainActor
private func checkKitPlan(_ checker: Checker) {
    let fromDefaults = RenderPlan.build(log: oneClickLog, duration: 5)
    let fromKit = RenderPlan.build(log: oneClickLog, duration: 5, kit: .default)
    checker.equal(fromKit, fromDefaults, "the default kit plans exactly as the default settings do")
    checker.equal(fromKit.zoomSegments.map(\.amount), [2], "the default plan zooms 2× around the click")
    let loud = RenderPlan.build(log: oneClickLog, duration: 5, kit: loudKit)
    checker.equal(loud.zoomSegments.map(\.amount), [3], "the loud kit's 3× reaches the planned segment")
    checker.equal(loud.cursor.sampleRate, 120, "the loud kit's cursor rate reaches the cursor timeline")
    checker.equal(loud.camera.sampleRate, 90, "the loud kit's camera rate reaches the camera timeline")
    checker.close(loud.zoomSegments.first?.start ?? -1, 0.6, "the loud kit's 0.4 s lead-in reaches the segment")
}

// MARK: - Default kit against RenderStyle()

/// `RenderStyle(kit: .default, canvas: 1920×1080) == RenderStyle()`, field
/// by field and as a whole; the canvas's frame rate plays no part.
@MainActor
private func checkDefaultKitStyle(_ checker: Checker) {
    let style = RenderStyle(kit: .default, canvas: .hd1080p60)
    let defaults = RenderStyle()
    checker.equal(style.outputWidth, 1920, "default kit at 1080p: outputWidth")
    checker.equal(style.outputHeight, 1080, "default kit at 1080p: outputHeight")
    checker.equal(style.background, defaults.background, "default kit at 1080p: background")
    checker.equal(
        style.background,
        .linearGradient(from: RenderColor(rgb: 0x1C_2B_4B), to: RenderColor(rgb: 0x4A_1F_5E), angleDegrees: 45),
        "default kit at 1080p: the gradient is #1C2B4B → #4A1F5E at 45°")
    checker.equal(style.padding, defaults.padding, "default kit at 1080p: padding")
    checker.equal(style.cornerRadius, defaults.cornerRadius, "default kit at 1080p: cornerRadius")
    checker.equal(style.cornerRadius, 18, "default kit at 1080p: the corner radius is 18 px")
    checker.equal(style.shadow, defaults.shadow, "default kit at 1080p: shadow")
    checker.equal(
        style.shadow, RenderShadow(offsetX: 0, offsetY: 18, blurRadius: 48, opacity: 0.55),
        "default kit at 1080p: the shadow is 0.55 / 48 / (0, 18)")
    checker.equal(style.cursorScale, defaults.cursorScale, "default kit at 1080p: cursorScale")
    checker.equal(style.cursorScale, 1, "default kit at 1080p: the cursor is drawn at its natural size")
    checker.equal(style, defaults, "RenderStyle(kit: .default, canvas: 1920×1080) == RenderStyle()")
    checker.equal(RenderStyle(kit: .default, canvas: .hd1080p30), style, "the frame rate does not change the style")
    checker.equal(BrandKit.default.frame.referenceHeight, 1080, "the kit quotes its pixel values at 1080p")
}

// MARK: - Scaling

/// The default kit at 3840×2160 is the 1080p style `scaled(by: 2)` with the
/// size doubled; the factor is the canvas height over the kit's reference
/// height, fractions stay, and a reference height that cannot scale is
/// taken as 1.
@MainActor
private func checkStyleScaling(_ checker: Checker) {
    var expected = RenderStyle().scaled(by: 2)
    expected.outputWidth = 3840
    expected.outputHeight = 2160
    let uhd = RenderStyle(kit: .default, canvas: .uhd2160p60)
    checker.equal(uhd.outputWidth, 3840, "default kit at 4K: outputWidth")
    checker.equal(uhd.outputHeight, 2160, "default kit at 4K: outputHeight")
    checker.equal(uhd.cornerRadius, 36, "default kit at 4K: the corner radius doubles to 36 px")
    checker.equal(uhd.shadow.offsetX, 0, "default kit at 4K: a zero shadow offset stays zero")
    checker.equal(uhd.shadow.offsetY, 36, "default kit at 4K: the shadow offset doubles to 36 px")
    checker.equal(uhd.shadow.blurRadius, 96, "default kit at 4K: the shadow blur doubles to 96 px")
    checker.equal(uhd.shadow.opacity, 0.55, "default kit at 4K: the shadow opacity is a fraction and stays")
    checker.equal(uhd.padding, 0.06, "default kit at 4K: the padding is a fraction and stays")
    checker.equal(uhd.cursorScale, 1, "default kit at 4K: the cursor scale is a multiplier and stays")
    checker.equal(uhd.background, RenderStyle().background, "default kit at 4K: the background has no pixel values")
    checker.equal(uhd, expected, "the default kit at 3840×2160 is the 1080p style scaled by 2 with the size doubled")

    // The loud kit's pixel values at 1080p are the kit's own, and at 4K twice them.
    let loudHD = RenderStyle(kit: loudKit, canvas: .hd1080p60)
    checker.equal(loudHD.cornerRadius, 24, "loud kit at 1080p: cornerRadius")
    checker.equal(
        loudHD.shadow, RenderShadow(offsetX: 4, offsetY: 12, blurRadius: 30, opacity: 0.4), "loud kit at 1080p: shadow")
    checker.equal(loudHD.padding, 0.1, "loud kit at 1080p: padding")
    checker.equal(loudHD.cursorScale, 2.5, "loud kit at 1080p: cursorScale")
    var loudExpected = loudHD.scaled(by: 2)
    loudExpected.outputWidth = 3840
    loudExpected.outputHeight = 2160
    checker.equal(RenderStyle(kit: loudKit, canvas: .uhd2160p60), loudExpected, "the loud kit scales like the default")

    // The factor follows the kit's reference height: a kit quoted at 4K is
    // unscaled there and halved at 1080p.
    var quotedAt4K = BrandKit.default
    quotedAt4K.frame.referenceHeight = 2160
    checker.equal(
        RenderStyle(kit: quotedAt4K, canvas: .uhd2160p60).cornerRadius, 18, "a kit quoted at 4K is unscaled at 4K")
    checker.equal(
        RenderStyle(kit: quotedAt4K, canvas: .hd1080p60).cornerRadius, 9, "a kit quoted at 4K is halved at 1080p")
    checker.equal(
        RenderStyle(kit: quotedAt4K, canvas: .hd1080p60).shadow.blurRadius, 24, "the shadow follows the same factor")

    // The shorter side, not the height: the 1080×1920 and 1080×1080 presets
    // draw the kit's pixel values at the 1080p size, on a card as wide as
    // the 1080p one is tall.
    let vertical = RenderStyle(kit: .default, canvas: CanvasSpec(width: 1080, height: 1920, frameRate: 60))
    checker.equal(vertical.cornerRadius, 18, "a 9:16 canvas scales by its shorter side: radius 18")
    checker.equal(vertical.shadow, RenderStyle().shadow, "a 9:16 canvas keeps the 1080p shadow")
    checker.equal(vertical.outputWidth, 1080, "a 9:16 canvas keeps its width")
    checker.equal(vertical.outputHeight, 1920, "a 9:16 canvas keeps its height")
    checker.equal(
        RenderStyle(kit: .default, canvas: CanvasSpec(width: 1080, height: 1080, frameRate: 60)).cornerRadius, 18,
        "a 1:1 canvas scales by its shorter side")

    checker.equal(
        RenderStyle.pixelScale(forCanvasWidth: 3840, height: 2160, referenceHeight: 1080), 2,
        "pixel scale 2160 / 1080")
    checker.equal(
        RenderStyle.pixelScale(forCanvasWidth: 1280, height: 720, referenceHeight: 1080), 720.0 / 1080,
        "pixel scale 720 / 1080")
    checker.equal(
        RenderStyle.pixelScale(forCanvasWidth: 1080, height: 1920, referenceHeight: 1080), 1,
        "pixel scale 1080 / 1080 on a 9:16 canvas")
    for bad in [0.0, -1080, .infinity, -.infinity, .nan] {
        checker.equal(
            RenderStyle.pixelScale(forCanvasWidth: 3840, height: 2160, referenceHeight: bad), 1,
            "a reference height of \(bad) cannot scale and is taken as 1")
    }
    var unscalable = BrandKit.default
    unscalable.frame.referenceHeight = 0
    checker.equal(
        RenderStyle(kit: unscalable, canvas: .uhd2160p60).cornerRadius, 18,
        "a kit with reference height 0 keeps its pixel values rather than dividing by zero")
}

// MARK: - Background and colors

/// Each background slot maps to its `RenderBackground` case, the reserved
/// image slot falls back to the solid color, and 8-bit kit colors convert
/// to the compositor's unit floats exactly where it matters.
@MainActor
private func checkBackgroundAndColors(_ checker: Checker) {
    checker.equal(RenderColor(KitColor(rgb: 0x1C_2B_4B)), RenderColor(rgb: 0x1C_2B_4B), "#1C2B4B converts exactly")
    checker.equal(RenderColor(KitColor.white), RenderColor.white, "white converts to 1, 1, 1, 1")
    checker.equal(RenderColor(KitColor.black), RenderColor.black, "black converts to 0, 0, 0, 1")
    let translucent = RenderColor(KitColor(red: 255, green: 0, blue: 0, alpha: 51))
    checker.equal(translucent.red, 1, "a full channel converts to exactly 1")
    checker.equal(translucent.green, 0, "an empty channel converts to exactly 0")
    checker.close(translucent.alpha, 0.2, "alpha 51 of 255 converts to 0.2")
    checker.equal(RenderColor(KitColor(hex: "#4A1F5E")!), RenderColor(rgb: 0x4A_1F_5E), "a hex kit color converts")

    let solid = RenderStyle(kit: loudKit, canvas: .hd1080p60).background
    checker.equal(solid, .solid(RenderColor(rgb: 0x10_20_30)), "a solid kit background draws the solid slot")

    var gradientKit = loudKit
    gradientKit.background.kind = .linearGradient
    checker.equal(
        RenderStyle(kit: gradientKit, canvas: .hd1080p60).background,
        .linearGradient(from: RenderColor(rgb: 0xAB_CD_EF), to: RenderColor(rgb: 0x12_34_56), angleDegrees: 120),
        "a gradient kit background draws the gradient slot with its angle")

    var imageKit = loudKit
    imageKit.background.kind = .image
    imageKit.background.image = ["path": "logo.png"]
    checker.equal(
        RenderStyle(kit: imageKit, canvas: .hd1080p60).background, .solid(RenderColor(rgb: 0x10_20_30)),
        "the reserved image background draws the solid slot until a renderer exists")

    checker.equal(
        RenderBackground(style: BrandKit.default.background), RenderStyle().background,
        "the default background group is RenderStyle's gradient")
    checker.equal(
        RenderShadow(style: BrandKit.default.frame.shadow, scale: 1), RenderShadow(),
        "the default shadow group is RenderShadow()")
}
