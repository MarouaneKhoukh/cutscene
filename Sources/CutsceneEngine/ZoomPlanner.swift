import CutsceneCore
import Foundation

/// A stretch of the recording the camera zooms into.
public struct ZoomSegment: Sendable, Hashable {
    /// Seconds since the recording started.
    public var start: Double
    public var end: Double
    /// Where the zoom aims first, in frame coordinates. The camera planner
    /// then follows the cursor from here.
    public var focus: NormalizedPoint
    /// Magnification, at least 1; 2 shows half the frame's width and height.
    /// The camera treats anything below 1 as 1: a viewport larger than the
    /// frame (the brief's "zoom level below 100%", letterboxed) is not
    /// supported yet.
    public var amount: Double

    public init(start: Double, end: Double, focus: NormalizedPoint, amount: Double) {
        self.start = start
        self.end = end
        self.focus = focus
        self.amount = amount
    }

    public var duration: Double {
        end - start
    }

    public func contains(_ time: Double) -> Bool {
        start <= time && time <= end
    }
}

/// Every constant of the zoom planner (research brief §5.4). Times are in seconds.
public struct ZoomPlannerSettings: Sendable, Hashable {
    /// How long before a click its zoom begins.
    public var leadIn: Double = 0.3
    /// How long after a click (or the last key of a burst) its zoom holds.
    public var holdAfter: Double = 2.5
    /// Zooms separated by at most this much merge into one.
    public var mergeGap: Double = 2.5
    /// Events in the last stretch of the recording are ignored: that is the
    /// click on the stop button.
    public var trailingIgnore: Double = 1.0
    /// Magnification of every generated segment, at least 1 (see `ZoomSegment.amount`).
    public var amount: Double = 2.0
    /// Typing bursts become zoom anchors at the pointer's last position.
    public var detectsTypingBursts: Bool = true
    /// A burst is at least this many non-modifier key-downs …
    public var typingBurstMinimumKeys: Int = 3
    /// … each less than this long after the previous one.
    public var typingBurstMaximumGap: Double = 0.5
    /// Where a typing burst aims when the pointer has not been seen yet.
    public var fallbackFocus = NormalizedPoint(x: 0.5, y: 0.5)

    /// Virtual key codes (Carbon `kVK_*`) of the modifier keys: Command,
    /// Shift, Caps Lock, Option, Control, their right-hand twins and Fn.
    /// Pressing them alone is not typing.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public init() {}
}

/// Derives zoom segments from input events: a padded window around every
/// click and every typing burst, merged where they come close.
///
/// A merged segment aims at the weighted center of its anchors, each click
/// and each burst counting once. Following the cursor inside the segment is
/// the camera planner's job.
public struct ZoomPlanner: Sendable {
    public var settings: ZoomPlannerSettings

    public init(settings: ZoomPlannerSettings = ZoomPlannerSettings()) {
        self.settings = settings
    }

    /// Plans the zooms of `log` for a recording that ends at `recordingEnd` seconds.
    public func plan(_ log: EventLog, recordingEnd: Double) -> [ZoomSegment] {
        plan(events: log.events, recordingEnd: recordingEnd)
    }

    /// Plans the zooms of `events` (sorted by time if they are not already)
    /// for a recording that ends at `recordingEnd` seconds. Segments are
    /// sorted, non-overlapping and clamped to `0...recordingEnd`. Events
    /// before time zero (a log offset by another tool) and auto-repeat
    /// key-downs are not anchors.
    public func plan(events: [InputEvent], recordingEnd: Double) -> [ZoomSegment] {
        guard recordingEnd > 0, recordingEnd.isFinite else { return [] }
        let cutoff = recordingEnd - settings.trailingIgnore
        var anchors: [Anchor] = []
        var lastPointer: NormalizedPoint?
        var burst: Burst?

        func flushBurst() {
            if let burst, burst.keyCount >= settings.typingBurstMinimumKeys {
                anchors.append(Anchor(start: burst.start, end: burst.end, position: burst.position))
            }
            burst = nil
        }

        for event in sortedByTime(events) {
            switch event {
            case .pointerMoved(_, let position, _), .buttonUp(_, let position, _, _):
                lastPointer = position
            case .buttonDown(let time, let position, _, _):
                lastPointer = position
                if time >= 0, time < cutoff {
                    anchors.append(Anchor(start: time, end: time, position: position))
                }
            case .keyDown(let time, let keyCode, _, let isRepeat):
                guard settings.detectsTypingBursts, time >= 0, time < cutoff,
                    !ZoomPlannerSettings.modifierKeyCodes.contains(keyCode)
                else { break }
                if isRepeat {
                    // Auto-repeat is one key held, not typing: a held arrow or
                    // backspace keeps an open burst alive but never starts or
                    // lengthens one on its own.
                    if var current = burst, time - current.end < settings.typingBurstMaximumGap {
                        current.end = time
                        burst = current
                    }
                } else if var current = burst, time - current.end < settings.typingBurstMaximumGap {
                    current.end = time
                    current.keyCount += 1
                    burst = current
                } else {
                    flushBurst()
                    burst = Burst(start: time, end: time, keyCount: 1, position: lastPointer ?? settings.fallbackFocus)
                }
            case .keyUp, .cursorShapeChanged, .takeMarker, .scroll, .focus, .geometry, .unknown:
                break
            }
        }
        flushBurst()
        guard !anchors.isEmpty else { return [] }

        // Clicks and bursts interleave, so order the padded windows before merging.
        let windows = anchors.map { anchor in
            Window(
                start: max(anchor.start - settings.leadIn, 0),
                end: min(max(anchor.end + settings.holdAfter, anchor.start), recordingEnd),
                sumX: anchor.position.x, sumY: anchor.position.y, weight: 1)
        }.sorted { $0.start < $1.start }

        var merged: [Window] = []
        for window in windows {
            if var last = merged.last, window.start - last.end <= settings.mergeGap {
                last.end = max(last.end, window.end)
                last.sumX += window.sumX
                last.sumY += window.sumY
                last.weight += window.weight
                merged[merged.count - 1] = last
            } else {
                merged.append(window)
            }
        }
        return merged.map { window in
            ZoomSegment(
                start: window.start, end: window.end,
                focus: NormalizedPoint(x: window.sumX / window.weight, y: window.sumY / window.weight),
                amount: max(settings.amount, 1))
        }
    }
}

// MARK: - Private types

/// A click or a typing burst: an activity span and the point it aims at.
private struct Anchor {
    var start: Double
    var end: Double
    var position: NormalizedPoint
}

private struct Burst {
    var start: Double
    var end: Double
    var keyCount: Int
    var position: NormalizedPoint
}

/// A padded, possibly merged window with the running sum of its anchors.
private struct Window {
    var start: Double
    var end: Double
    var sumX: Double
    var sumY: Double
    var weight: Double
}
