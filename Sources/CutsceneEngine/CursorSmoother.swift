import CutsceneCore
import Foundation

/// One frame of the rendered cursor.
public struct CursorSample: Sendable, Hashable {
    /// Seconds since the recording started.
    public var time: Double
    /// Where the drawn cursor is: the spring's position, or the raw position
    /// inside a disabled range.
    public var smoothedPosition: NormalizedPoint
    /// Where the real pointer was. The cursor *shape* is looked up from this
    /// path (research brief §5.3), and hover-sensitive segments draw it directly.
    public var rawPosition: NormalizedPoint
    /// Whether any mouse button is held.
    public var isPressed: Bool
    /// 1 is fully visible; the cursor fades out after a long idle.
    public var opacity: Double
    /// 1 at rest; shrinks toward `CursorSmootherSettings.pressScale` while pressed.
    public var scale: Double

    public init(
        time: Double, smoothedPosition: NormalizedPoint, rawPosition: NormalizedPoint, isPressed: Bool,
        opacity: Double, scale: Double
    ) {
        self.time = time
        self.smoothedPosition = smoothedPosition
        self.rawPosition = rawPosition
        self.isPressed = isPressed
        self.opacity = opacity
        self.scale = scale
    }
}

/// The smoothed cursor over a whole recording, sampled at a fixed rate from
/// time zero. Render time reads it with `sample(at:)`, which interpolates
/// linearly between neighbours, so playback at any frame rate stays smooth.
public struct CursorTimeline: Sendable, Hashable {
    public let sampleRate: Double
    /// `samples[n].time == n / sampleRate`.
    public let samples: [CursorSample]

    public init(sampleRate: Double, samples: [CursorSample]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    /// Time of the last sample.
    public var duration: Double {
        samples.count > 1 ? Double(samples.count - 1) / sampleRate : 0
    }

    /// The cursor at `time`, clamped to the timeline's range. `nil` only for an
    /// empty timeline. Positions, opacity and scale interpolate linearly;
    /// `isPressed` takes the nearer sample.
    public func sample(at time: Double) -> CursorSample? {
        guard let first = samples.first else { return nil }
        guard time > 0, samples.count > 1 else { return first }
        let scaled = time * sampleRate
        let lastIndex = samples.count - 1
        guard scaled < Double(lastIndex) else { return samples[lastIndex] }
        let index = Int(scaled)
        let fraction = scaled - Double(index)
        let a = samples[index]
        let b = samples[index + 1]
        return CursorSample(
            time: time,
            smoothedPosition: lerp(a.smoothedPosition, b.smoothedPosition, fraction),
            rawPosition: lerp(a.rawPosition, b.rawPosition, fraction),
            isPressed: fraction < 0.5 ? a.isPressed : b.isPressed,
            opacity: Easing.lerp(a.opacity, b.opacity, fraction),
            scale: Easing.lerp(a.scale, b.scale, fraction))
    }

    /// `sample(at:)` reduced to the smoothed position, for callers that read
    /// it hundreds of times a second.
    public func smoothedPosition(at time: Double) -> NormalizedPoint? {
        guard let first = samples.first else { return nil }
        guard time > 0, samples.count > 1 else { return first.smoothedPosition }
        let scaled = time * sampleRate
        let lastIndex = samples.count - 1
        guard scaled < Double(lastIndex) else { return samples[lastIndex].smoothedPosition }
        let index = Int(scaled)
        return lerp(samples[index].smoothedPosition, samples[index + 1].smoothedPosition, scaled - Double(index))
    }
}

/// Every constant of the cursor smoother (research brief §5.3). Times are in
/// seconds, distances in fractions of the frame.
public struct CursorSmootherSettings: Sendable, Hashable {
    /// Output rate of the timeline.
    public var sampleRate: Double = 60
    /// The spring for ordinary pointer motion.
    public var spring: SpringParameters = .mellow
    /// The spring used from `clickSpringLead` before a click until it happens.
    public var clickSpring: SpringParameters = .snappy
    /// The spring used while a button is held.
    public var dragSpring: SpringParameters = .drag

    /// A direction reversal whose two legs are both shorter than this, within
    /// `shakeWindow`, is accessibility-tool shake and is dropped.
    public var shakeLegThreshold: Double = 0.015
    public var shakeWindow: Double = 0.100
    /// Raw pointer samples are thinned to at most this many per second.
    public var maximumInputRate: Double = 60
    /// Samples that travel less than this from the last kept one are thinned too.
    public var minimumTravel: Double = 1.0 / 1920

    /// A spring chasing a moving target trails it by `friction / tension`
    /// seconds, so the target is read that far ahead. The lead follows the
    /// active spring through a one-pole filter with this time constant, so a
    /// profile switch does not jerk the target.
    public var leadTimeConstant: Double = 0.130
    /// When the next click is at most this far away, the target becomes the click point.
    public var clickAnticipationWindow: Double = 0.500
    /// `clickSpring` takes over this long before the click.
    public var clickSpringLead: Double = 0.175
    /// Gaps between raw samples longer than this are idle: the raw position
    /// holds instead of drifting linearly to the next sample.
    public var idleHoldGap: Double = 0.067
    /// After this long without input the spring is forced onto its target.
    public var settleTimeout: Double = 5
    /// Time ranges where smoothing is off and the raw motion passes through,
    /// for menus and hover states that desynchronize from a smoothed pointer.
    public var disabledRanges: [ClosedRange<Double>] = []

    /// Idle time before the cursor starts to fade.
    public var idleFadeDelay: Double = 2
    public var fadeOutDuration: Double = 0.400
    /// The cursor fades back in this long before input resumes.
    public var fadeInLead: Double = 0.250
    /// Scale reached while a button is held.
    public var pressScale: Double = 0.8
    /// Time to reach `pressScale` after a press and to return after release.
    public var pressScaleDuration: Double = 0.130

    public init() {}
}

/// Turns the recorded pointer and button events into a `CursorTimeline`.
///
/// The whole recording is simulated offline, which is what makes click
/// anticipation and the fade-in before motion possible: the smoother can see
/// the future. The output depends only on the events and the settings.
public struct CursorSmoother: Sendable {
    public var settings: CursorSmootherSettings

    public init(settings: CursorSmootherSettings = CursorSmootherSettings()) {
        self.settings = settings
    }

    /// Smooths the pointer events of `log` over `0...duration` seconds.
    public func timeline(for log: EventLog, duration: Double) -> CursorTimeline {
        timeline(events: log.events, duration: duration)
    }

    /// Smooths `events` (sorted by time if they are not already) over
    /// `0...duration` seconds. Events past `duration` still shape the end of
    /// the timeline through anticipation and the phase lead. A duration that
    /// is not a finite, positive number gives the single sample at time zero.
    public func timeline(events: [InputEvent], duration: Double) -> CursorTimeline {
        let events = sortedByTime(events)
        var path: [PathSample] = []
        var buttons: [ButtonEvent] = []
        path.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .pointerMoved(let time, let position, _):
                path.append(PathSample(time: time, position: position))
            case .buttonDown(let time, let position, _, _):
                path.append(PathSample(time: time, position: position))
                buttons.append(ButtonEvent(time: time, position: position, isDown: true))
            case .buttonUp(let time, let position, _, _):
                path.append(PathSample(time: time, position: position))
                buttons.append(ButtonEvent(time: time, position: position, isDown: false))
            case .keyDown, .keyUp, .cursorShapeChanged, .takeMarker, .scroll, .focus, .geometry, .unknown:
                break
            }
        }
        if path.isEmpty {
            // No pointer data: park the cursor at the center; the idle rules hide it.
            path = [PathSample(time: 0, position: NormalizedPoint(x: 0.5, y: 0.5))]
        }
        path = decimate(removingShake(from: path))
        return simulate(
            path: Path(samples: path, idleHoldGap: settings.idleHoldGap), buttons: buttons, duration: duration)
    }

    // MARK: Pre-filters

    /// Drops the middle point of a quick back-and-forth whose legs are both
    /// tiny: the jitter of accessibility tools and shaky hands, not motion.
    private func removingShake(from path: [PathSample]) -> [PathSample] {
        guard path.count > 2 else { return path }
        let threshold = settings.shakeLegThreshold
        var kept: [PathSample] = []
        kept.reserveCapacity(path.count)
        for sample in path {
            if kept.count >= 2 {
                let a = kept[kept.count - 2]
                let b = kept[kept.count - 1]
                let abx = b.position.x - a.position.x
                let aby = b.position.y - a.position.y
                let bcx = sample.position.x - b.position.x
                let bcy = sample.position.y - b.position.y
                let reverses = abx * bcx + aby * bcy < 0
                if reverses, sample.time - a.time <= settings.shakeWindow,
                    (abx * abx + aby * aby).squareRoot() < threshold,
                    (bcx * bcx + bcy * bcy).squareRoot() < threshold
                {
                    kept.removeLast()
                }
            }
            kept.append(sample)
        }
        return kept
    }

    /// Thins the path to `maximumInputRate` and `minimumTravel`. The last
    /// sample before an idle gap is always kept, whatever its spacing, so
    /// every rest position is exact.
    private func decimate(_ path: [PathSample]) -> [PathSample] {
        guard path.count > 1 else { return path }
        let minimumInterval = settings.maximumInputRate > 0 ? 1 / settings.maximumInputRate : 0
        var kept = [path[0]]
        kept.reserveCapacity(path.count)
        for index in 1..<path.count {
            let sample = path[index]
            let last = kept[kept.count - 1]
            let isRestPoint = index == path.count - 1 || path[index + 1].time - sample.time > settings.idleHoldGap
            if isRestPoint {
                kept.append(sample)
                continue
            }
            // A hair of slack keeps samples recorded at exactly the maximum rate.
            guard sample.time - last.time >= minimumInterval - 1e-9 else { continue }
            // Kept for its travel, or because dropping it would leave the next
            // sample more than an idle gap after the last kept one: under slow
            // drift the travel filter alone turns a continuously sampled path
            // into a staircase that `Path` then holds across instead of
            // interpolating.
            if distance(sample.position, last.position) >= settings.minimumTravel
                || path[index + 1].time - last.time > settings.idleHoldGap
            {
                kept.append(sample)
            }
        }
        return kept
    }

    // MARK: Simulation

    private func simulate(path: Path, buttons: [ButtonEvent], duration: Double) -> CursorTimeline {
        precondition(
            settings.sampleRate > 0 && settings.sampleRate.isFinite,
            "The cursor sample rate must be positive and finite."
        )
        let sampleRate = settings.sampleRate
        let dt = 1 / sampleRate
        let count = sampleCount(duration: duration, sampleRate: sampleRate)
        let downs = buttons.filter(\.isDown)
        let disabledRanges = settings.disabledRanges.sorted { $0.lowerBound < $1.lowerBound }
        let activity = activityTimes(path: path, buttons: buttons)

        var spring = Spring2D(parameters: settings.spring, position: path.samples[0].position)
        var step = SpringStep(parameters: settings.spring, dt: dt)
        var lead = OnePoleLowPass(timeConstant: settings.leadTimeConstant, initialValue: settings.spring.phaseLag)
        var pressBlend = 0.0
        var rawHint = 0
        var targetHint = 0
        var buttonIndex = 0
        var heldButtons = 0
        var nextDownIndex = 0
        var activityIndex = 0
        var disabledIndex = 0

        var samples: [CursorSample] = []
        samples.reserveCapacity(count)

        for n in 0..<count {
            let time = Double(n) / sampleRate

            while buttonIndex < buttons.count, buttons[buttonIndex].time <= time {
                heldButtons = max(heldButtons + (buttons[buttonIndex].isDown ? 1 : -1), 0)
                buttonIndex += 1
            }
            let pressed = heldButtons > 0

            while nextDownIndex < downs.count, downs[nextDownIndex].time < time {
                nextDownIndex += 1
            }
            let nextDown = nextDownIndex < downs.count ? downs[nextDownIndex] : nil
            let timeToClick = nextDown.map { $0.time - time } ?? .infinity

            while disabledIndex < disabledRanges.count, disabledRanges[disabledIndex].upperBound < time {
                disabledIndex += 1
            }
            let disabled = disabledIndex < disabledRanges.count && disabledRanges[disabledIndex].lowerBound <= time

            while activityIndex + 1 < activity.count, activity[activityIndex + 1] <= time {
                activityIndex += 1
            }
            // A held button is activity even with the pointer still: a drag
            // paused over a drop target must not fade the cursor out.
            let idleFor = pressed ? 0 : time - activity[activityIndex]
            let nextActivity = activityIndex + 1 < activity.count ? activity[activityIndex + 1] : nil

            let raw = path.position(at: time, hint: &rawHint)
            if disabled {
                // Pass raw motion through; the spring re-enters from the raw position.
                spring.position = raw
                spring.target = raw
                spring.x.velocity = 0
                spring.y.velocity = 0
            } else if idleFor >= settings.settleTimeout,
                nextActivity.map({ $0 - time > max(settings.clickAnticipationWindow, lead.value) + dt }) ?? true
            {
                // Forced onto its target only while the target cannot be about
                // to move. Inside the anticipation or lead window the target
                // already points at the coming motion, and snapping there would
                // teleport the cursor and zero the velocity it needs.
                spring.snapToTarget()
            }

            var opacity = 1.0
            if idleFor >= settings.idleFadeDelay {
                let fadeOut =
                    settings.fadeOutDuration > 0
                    ? 1 - Easing.smoothstep((idleFor - settings.idleFadeDelay) / settings.fadeOutDuration) : 0
                var fadeIn = 0.0
                if let nextActivity, settings.fadeInLead > 0, nextActivity - time <= settings.fadeInLead {
                    fadeIn = Easing.smoothstep(1 - (nextActivity - time) / settings.fadeInLead)
                }
                opacity = max(fadeOut, fadeIn)
            }

            if settings.pressScaleDuration > 0 {
                pressBlend = Easing.clamp01(pressBlend + (pressed ? dt : -dt) / settings.pressScaleDuration)
            } else {
                pressBlend = pressed ? 1 : 0
            }
            let scale = Easing.lerp(1, settings.pressScale, Easing.smoothstep(pressBlend))

            samples.append(
                CursorSample(
                    time: time, smoothedPosition: spring.position, rawPosition: raw, isPressed: pressed,
                    opacity: opacity, scale: scale))

            // Advance to the next sample. The target is read at the middle of
            // the step (plus the lead): the closed form holds it constant for
            // the step, and the midpoint is the best stand-in for a target that
            // moves during it; reading it at the start would lag by dt/2.
            let parameters: SpringParameters
            if pressed {
                parameters = settings.dragSpring
            } else if timeToClick <= settings.clickSpringLead {
                parameters = settings.clickSpring
            } else {
                parameters = settings.spring
            }
            if parameters != spring.parameters {
                spring.parameters = parameters
                step = SpringStep(parameters: parameters, dt: dt)
            }
            lead.update(toward: parameters.phaseLag, dt: dt)
            if let nextDown, !pressed, timeToClick <= settings.clickAnticipationWindow {
                // A held button wins over anticipation: during a drag the
                // cursor stays on the drag path instead of running ahead to a
                // click that follows the release.
                spring.target = nextDown.position
            } else {
                spring.target = path.position(at: time + dt / 2 + lead.value, hint: &targetHint)
            }
            spring.step(step)
        }
        return CursorTimeline(sampleRate: sampleRate, samples: samples)
    }

    /// Moments the user did something: the recording start, every pointer
    /// sample that travelled at least `minimumTravel` from the last one that
    /// counted (anything less is jitter, not activity) and every button event.
    /// Sorted, starting at 0.
    private func activityTimes(path: Path, buttons: [ButtonEvent]) -> [Double] {
        var times: [Double] = [0]
        times.reserveCapacity(path.samples.count + buttons.count + 1)
        var previous: NormalizedPoint?
        for sample in path.samples {
            if previous.map({ distance(sample.position, $0) >= settings.minimumTravel }) ?? true {
                times.append(sample.time)
                previous = sample.position
            }
        }
        for button in buttons {
            times.append(button.time)
        }
        times.sort()
        return times
    }
}

// MARK: - Private types

private struct PathSample: Hashable {
    var time: Double
    var position: NormalizedPoint
}

private struct ButtonEvent: Hashable {
    var time: Double
    var position: NormalizedPoint
    var isDown: Bool
}

/// The thinned raw pointer path as a function of time: linear between close
/// samples, held across idle gaps, held flat before the first and after the
/// last sample.
private struct Path {
    var samples: [PathSample]
    var idleHoldGap: Double

    /// `hint` is the index of the last sample at or before the previous query;
    /// queries arrive nearly in order, so moving it is cheaper than a search.
    func position(at time: Double, hint: inout Int) -> NormalizedPoint {
        while hint + 1 < samples.count, samples[hint + 1].time <= time {
            hint += 1
        }
        while hint > 0, samples[hint].time > time {
            hint -= 1
        }
        let sample = samples[hint]
        guard time >= sample.time, hint + 1 < samples.count else { return sample.position }
        let next = samples[hint + 1]
        let gap = next.time - sample.time
        guard gap > 0, gap <= idleHoldGap else { return sample.position }
        return lerp(sample.position, next.position, (time - sample.time) / gap)
    }
}

private func lerp(_ a: NormalizedPoint, _ b: NormalizedPoint, _ t: Double) -> NormalizedPoint {
    NormalizedPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

private func distance(_ a: NormalizedPoint, _ b: NormalizedPoint) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    return (dx * dx + dy * dy).squareRoot()
}

/// Samples of a timeline at `sampleRate` over `0...duration`: one for time
/// zero plus one per interval. A duration that is not a finite, positive
/// number (as `CMTime.seconds` of an invalid time is NaN) gives one sample
/// rather than a trap in the conversion to `Int`.
func sampleCount(duration: Double, sampleRate: Double) -> Int {
    guard duration.isFinite, duration > 0 else { return 1 }
    let intervals = (duration * sampleRate).rounded(.down)
    guard intervals < Double(Int.max / 2) else { return Int.max / 2 }
    return Int(intervals) + 1
}

/// Reorders by time, keeping equal times in arrival order. `EventLog` already
/// guarantees this, so for its events the check is a single pass.
func sortedByTime(_ events: [InputEvent]) -> [InputEvent] {
    var isSorted = true
    for index in events.indices.dropFirst() where events[index - 1].time > events[index].time {
        isSorted = false
        break
    }
    if isSorted { return events }
    return events.enumerated()
        .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        .map(\.element)
}
