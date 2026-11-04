import CutsceneCore
import Foundation

// The brand kit's `cursor` and `zoom` groups mirror the engine's settings
// structs field for field (ARCHITECTURE §3): Core cannot import Engine, so
// the kit carries its own copies and these adapters bring them across. They
// map only; a kit's `extra` members are for newer builds, and a value's
// validity (a positive sample rate, say) is the engine's own contract.

// MARK: - Springs

extension SpringParameters {
    /// The constants of a kit's spring, which quotes them in the same
    /// (tension, mass, friction) form.
    public init(style: SpringStyle) {
        self.init(tension: style.tension, mass: style.mass, friction: style.friction)
    }
}

// MARK: - Cursor

extension CursorSmootherSettings {
    /// The smoother's constants from `kit.cursor`.
    public init(kit: BrandKit) {
        self.init(style: kit.cursor)
    }

    /// The smoother's constants from a kit's cursor group. The render-only
    /// members (`scale`, `click`) are `RenderStyle`'s and stay behind.
    public init(style: CursorStyle) {
        self.init()
        sampleRate = style.sampleRate
        spring = SpringParameters(style: style.spring)
        clickSpring = SpringParameters(style: style.clickSpring)
        dragSpring = SpringParameters(style: style.dragSpring)
        shakeLegThreshold = style.shakeLegThreshold
        shakeWindow = style.shakeWindow
        maximumInputRate = style.maximumInputRate
        minimumTravel = style.minimumTravel
        leadTimeConstant = style.leadTimeConstant
        clickAnticipationWindow = style.clickAnticipationWindow
        clickSpringLead = style.clickSpringLead
        idleHoldGap = style.idleHoldGap
        settleTimeout = style.settleTimeout
        // A kit range whose end precedes its start collapses to its start
        // (`TimeRange.closedRange`), since a `ClosedRange` cannot run backwards
        // and a hand-edited kit must not trap the planner.
        disabledRanges = style.disabledRanges.map(\.closedRange)
        idleFadeDelay = style.idleFadeDelay
        fadeOutDuration = style.fadeOutDuration
        fadeInLead = style.fadeInLead
        pressScale = style.pressScale
        pressScaleDuration = style.pressScaleDuration
    }
}

// MARK: - Zoom

extension ZoomPlannerSettings {
    /// The zoom planner's constants from `kit.zoom`.
    public init(kit: BrandKit) {
        self.init(style: kit.zoom)
    }

    /// The zoom planner's constants from a kit's zoom group; its `camera`
    /// member is `CameraPlannerSettings`' and stays behind.
    public init(style: ZoomStyle) {
        self.init()
        leadIn = style.leadIn
        holdAfter = style.holdAfter
        mergeGap = style.mergeGap
        trailingIgnore = style.trailingIgnore
        amount = style.amount
        detectsTypingBursts = style.detectsTypingBursts
        typingBurstMinimumKeys = style.typingBurstMinimumKeys
        typingBurstMaximumGap = style.typingBurstMaximumGap
        fallbackFocus = style.fallbackFocus
    }
}

// MARK: - Camera

extension CameraPlannerSettings {
    /// The camera planner's constants from `kit.zoom.camera`.
    public init(kit: BrandKit) {
        self.init(style: kit.zoom.camera)
    }

    /// The camera planner's constants from a kit's camera-motion group.
    public init(style: CameraMotionStyle) {
        self.init()
        sampleRate = style.sampleRate
        retargetInterval = style.retargetInterval
        spring = SpringParameters(style: style.spring)
        deadZoneWidth = style.deadZoneWidth
        deadZoneHeight = style.deadZoneHeight
        preAimThreshold = style.preAimThreshold
        fallbackFocus = style.fallbackFocus
    }
}

// MARK: - Plan

extension RenderPlan {
    /// `build(log:duration:cursor:zoom:camera:)` with every setting taken
    /// from `kit`: what the auto-render and the editor plan a project's
    /// `style` with.
    public nonisolated static func build(log: EventLog, duration: Double, kit: BrandKit) -> sending RenderPlan {
        build(
            log: log, duration: duration, cursor: CursorSmootherSettings(kit: kit), zoom: ZoomPlannerSettings(kit: kit),
            camera: CameraPlannerSettings(kit: kit))
    }
}
