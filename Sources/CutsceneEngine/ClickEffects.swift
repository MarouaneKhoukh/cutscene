import CutsceneCore
import Foundation

/// The curve a ripple grows along. Mirrors the kit's `RippleEasing` case for
/// case (Core cannot import the engine); `ClickRippleSettings(style:)` maps
/// one onto the other.
public enum RippleCurve: Sendable, Hashable, CaseIterable {
    case linear
    /// `1 − (1 − t)³`: fast out of the click, settling as it fades, the §3 default.
    case easeOutCubic
    case easeInOutCubic
    case smoothstep
    case smootherstep

    /// The eased progress for a raw progress `t`, clamped to `0...1` like the
    /// shared `Easing` functions.
    public func apply(_ t: Double) -> Double {
        switch self {
        case .linear:
            return Easing.clamp01(t)
        case .easeOutCubic:
            let u = 1 - Easing.clamp01(t)
            return 1 - u * u * u
        case .easeInOutCubic:
            return Easing.easeInOutCubic(t)
        case .smoothstep:
            return Easing.smoothstep(t)
        case .smootherstep:
            return Easing.smootherstep(t)
        }
    }
}

/// Every constant of the click ripples (ARCHITECTURE §3 `cursor.click`): the
/// ring that spreads from a mouse-down. Radii and stroke widths are output
/// pixels at `referenceHeight`, the way the kit quotes them, so the same
/// settings look alike at 1080p and 4K; `RenderPlan.frameState(at:canvas:)`
/// scales them to the canvas.
public struct ClickRippleSettings: Sendable, Hashable {
    public var enabled: Bool = true
    public var startRadius: Double = 0
    public var endRadius: Double = 44
    /// Seconds from the click to the ripple's end.
    public var duration: Double = 0.5
    public var curve: RippleCurve = .easeOutCubic
    public var startStrokeWidth: Double = 2.5
    public var endStrokeWidth: Double = 0
    public var startOpacity: Double = 0.65
    public var endOpacity: Double = 0
    /// Ripples alive at once; when more clicks fall inside one `duration`
    /// the oldest end early, so a burst of clicks never stacks rings.
    public var maximumConcurrent: Int = 4
    /// The canvas height the pixel values are quoted at (`FrameStyle.referenceHeight`).
    public var referenceHeight: Double = 1080

    public init() {}
}

/// A mouse-down as the ripples see it: when, where (frame coordinates) and
/// which button, read from the log's `buttonDown` events.
public struct ClickEvent: Sendable, Hashable {
    /// Seconds since the recording started.
    public var time: Double
    public var position: NormalizedPoint
    public var button: InputEvent.Button

    public init(time: Double, position: NormalizedPoint, button: InputEvent.Button) {
        self.time = time
        self.position = position
        self.button = button
    }
}

/// One ring to draw. `radius` and `strokeWidth` are in the units of the
/// settings that made it (reference-height pixels from `ClickEffects`, canvas
/// pixels after `scaled(by:)`); `position` is in frame coordinates, the same
/// space as the cursor, so the renderer maps it through the crop and the
/// viewport exactly as it maps the cursor.
public struct Ripple: Sendable, Hashable {
    /// The click that started it.
    public var click: ClickEvent
    /// `0` at the click, rising to `1` at `ClickRippleSettings.duration`; the
    /// raw ratio, before the curve.
    public var progress: Double
    public var radius: Double
    public var strokeWidth: Double
    /// `0...1`, straight alpha.
    public var opacity: Double

    public init(click: ClickEvent, progress: Double, radius: Double, strokeWidth: Double, opacity: Double) {
        self.click = click
        self.progress = progress
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.opacity = opacity
    }

    /// Where the ring is centred, in frame coordinates.
    public var position: NormalizedPoint { click.position }

    /// The same ring with its pixel values multiplied by `factor`: a 4K
    /// canvas draws the 1080p ring `scaled(by: 2)`.
    public func scaled(by factor: Double) -> Ripple {
        var copy = self
        copy.radius *= factor
        copy.strokeWidth *= factor
        return copy
    }
}

/// Turns the recorded clicks into the rings alive at any moment. Pure and
/// deterministic: the rings at a time depend only on the clicks and the
/// settings, and the lookup is a binary search so the renderer can ask once
/// per frame on a recording with thousands of clicks.
public struct ClickEffects: Sendable, Hashable {
    public let settings: ClickRippleSettings
    /// Sorted by time; a click with a non-finite time is dropped, since it has
    /// no place in time order.
    public let clicks: [ClickEvent]

    public init(clicks: [ClickEvent], settings: ClickRippleSettings = ClickRippleSettings()) {
        self.settings = settings
        self.clicks = Self.sortedByTime(clicks.filter { $0.time.isFinite })
    }

    /// Every `buttonDown` of `log` as a click.
    public init(log: EventLog, settings: ClickRippleSettings = ClickRippleSettings()) {
        var clicks: [ClickEvent] = []
        for case .buttonDown(let time, let position, let button, _) in log.events {
            clicks.append(ClickEvent(time: time, position: position, button: button))
        }
        self.init(clicks: clicks, settings: settings)
    }

    /// The rings alive at `time`, oldest first so a renderer drawing them in
    /// order puts the newest on top. A ring lives from its click for
    /// `duration` seconds, the end excluded, so at the exact end it is gone
    /// rather than drawn at zero opacity; when more than `maximumConcurrent`
    /// are alive, the newest win. Empty when the effect is off, the duration
    /// is not a finite positive number, or `time` is NaN.
    public func ripples(at time: Double) -> [Ripple] {
        let duration = settings.duration
        guard settings.enabled, duration.isFinite, duration > 0, !time.isNaN, settings.maximumConcurrent > 0
        else { return [] }
        // Clicks in `(time − duration, time]`: the first index whose click is
        // strictly later than `time − duration`, up to the first index past `time`.
        let start = firstIndex(after: time - duration)
        let end = firstIndex(after: time)
        guard start < end else { return [] }
        let alive = clicks[max(start, end - settings.maximumConcurrent)..<end]
        return alive.map { click in
            let progress = (time - click.time) / duration
            let eased = settings.curve.apply(progress)
            return Ripple(
                click: click, progress: progress,
                radius: Easing.lerp(settings.startRadius, settings.endRadius, eased),
                strokeWidth: Easing.lerp(settings.startStrokeWidth, settings.endStrokeWidth, eased),
                opacity: Easing.lerp(settings.startOpacity, settings.endOpacity, eased))
        }
    }

    /// The first index whose click is strictly after `time`; `clicks.count`
    /// when none is.
    private func firstIndex(after time: Double) -> Int {
        var low = clicks.startIndex
        var high = clicks.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if clicks[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Reorders by time while keeping equal times in their original order,
    /// since `sort` makes no stability promise.
    private static func sortedByTime(_ clicks: [ClickEvent]) -> [ClickEvent] {
        var isSorted = true
        for index in clicks.indices.dropFirst() where clicks[index - 1].time > clicks[index].time {
            isSorted = false
            break
        }
        if isSorted { return clicks }
        return clicks.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }
}

// MARK: - Kit adapter

extension RippleCurve {
    /// The engine's curve for a kit's easing name.
    public init(style: RippleEasing) {
        switch style {
        case .linear: self = .linear
        case .easeOutCubic: self = .easeOutCubic
        case .easeInOutCubic: self = .easeInOutCubic
        case .smoothstep: self = .smoothstep
        case .smootherstep: self = .smootherstep
        }
    }
}

extension ClickRippleSettings {
    /// The ripple constants from `kit.cursor.click`, quoted at
    /// `kit.frame.referenceHeight`. The color stays with the renderer.
    public init(kit: BrandKit) {
        self.init(style: kit.cursor.click, referenceHeight: kit.frame.referenceHeight)
    }

    /// The ripple constants from a kit's click group.
    public init(style: ClickRippleStyle, referenceHeight: Double) {
        self.init()
        enabled = style.enabled
        startRadius = style.startRadius
        endRadius = style.endRadius
        duration = style.duration
        curve = RippleCurve(style: style.easing)
        startStrokeWidth = style.startStrokeWidth
        endStrokeWidth = style.endStrokeWidth
        startOpacity = style.startOpacity
        endOpacity = style.endOpacity
        maximumConcurrent = style.maximumConcurrent
        self.referenceHeight = referenceHeight
    }
}
