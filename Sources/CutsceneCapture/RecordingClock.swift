import CoreMedia
import Foundation
import Synchronization

/// The one timeline of a recording: host-clock timestamps in, recording time
/// out, with pauses removed.
///
/// Every stamp a recording keeps (video and audio sample times in the movie,
/// event times in the `EventLog`) goes through one clock, so the media and the
/// telemetry cannot disagree about where time zero is or how long a pause
/// lasted. Recording time is `hostTime − origin − (pauses completed before
/// hostTime)`; a timestamp inside a pause, before the origin or at or after
/// `stop` maps to nothing, and the sample carrying it is left out.
///
/// Membership is decided by the timestamp, never by when a sample arrives:
/// ScreenCaptureKit hands over a frame some milliseconds after capturing it, so
/// a frame captured just before `pause()` may arrive after it and still belongs
/// to the recording. Pauses are therefore kept as intervals, not as a running
/// offset.
///
/// A clock made with `init(origin:)` counts from the moment it is made; one
/// made with `unstarted()` counts from `start()`, so a pipeline can be built
/// around it (encoder, writer, stream) and time zero taken only when the
/// stream is about to start. Until then every stamp maps to nothing.
///
/// Thread-safe; every method may be called from any thread.
public final class RecordingClock: @unchecked Sendable {
    private struct Pause {
        var start: CMTime
        var end: CMTime?
    }

    private struct State {
        var origin: CMTime?
        var pauses: [Pause] = []
        var stop: CMTime?
    }

    private let state: Mutex<State>

    /// Starts the timeline at `origin`, by default the host clock's reading now.
    public init(origin: CMTime = RecordingClock.hostTime()) {
        state = Mutex(State(origin: origin))
    }

    private init(unstarted: Void) {
        state = Mutex(State(origin: nil))
    }

    /// A clock whose origin is taken by `start()` rather than now.
    public static func unstarted() -> RecordingClock {
        RecordingClock(unstarted: ())
    }

    /// Host-clock reading at recording time zero; `.invalid` until the clock
    /// has started (see `unstarted()`).
    public var origin: CMTime {
        state.withLock { $0.origin ?? .invalid }
    }

    public var isStarted: Bool {
        state.withLock { $0.origin != nil }
    }

    /// Takes the origin now. Nothing happens once the clock has started or
    /// stopped.
    public func start() {
        let now = Self.hostTime()
        state.withLock { state in
            guard state.origin == nil, state.stop == nil else { return }
            state.origin = now
        }
    }

    /// The host clock (`CMClockGetHostTimeClock`), which ScreenCaptureKit and
    /// `CGEvent` timestamps share.
    public static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// Opens a pause at the host time of the call. Nothing happens before
    /// `start`, while paused or after `stop`.
    public func pause() {
        let now = Self.hostTime()
        state.withLock { state in
            guard state.origin != nil, state.stop == nil, state.pauses.last?.end != nil || state.pauses.isEmpty
            else { return }
            state.pauses.append(Pause(start: now, end: nil))
        }
    }

    /// Closes the open pause at the host time of the call.
    public func resume() {
        let now = Self.hostTime()
        state.withLock { state in
            guard state.stop == nil, let index = state.pauses.indices.last, state.pauses[index].end == nil else {
                return
            }
            state.pauses[index].end = now
        }
    }

    /// Ends the timeline at the host time of the call, or where the open pause
    /// began when called while paused. Timestamps from then on map to nothing
    /// and `elapsed` stops moving. Calling it again changes nothing.
    public func stop() {
        let now = Self.hostTime()
        state.withLock { state in
            guard state.stop == nil else { return }
            if let last = state.pauses.last, last.end == nil {
                state.pauses.removeLast()
                state.stop = last.start
            } else {
                state.stop = now
            }
        }
    }

    public var isPaused: Bool {
        state.withLock { $0.stop == nil && $0.pauses.last.map { $0.end == nil } ?? false }
    }

    public var isStopped: Bool {
        state.withLock { $0.stop != nil }
    }

    /// Pauses completed so far. The video encoder forces a keyframe when it
    /// changes between two frames, so every resume starts a fresh GOP.
    public var completedPauses: Int {
        state.withLock { $0.pauses.filter { $0.end != nil }.count }
    }

    /// Recording time now: the recorded duration so far. Zero before `start`,
    /// frozen while paused and after `stop`.
    public var elapsed: CMTime {
        let hostNow = Self.hostTime()
        return state.withLock { state in
            guard let origin = state.origin else { return .zero }
            let now: CMTime
            if let stop = state.stop {
                now = stop
            } else if let last = state.pauses.last, last.end == nil {
                now = last.start
            } else {
                now = hostNow
            }
            let removed = state.pauses.reduce(CMTime.zero) { total, pause in
                pause.end.map { total + ($0 - pause.start) } ?? total
            }
            return CMTimeMaximum(now - origin - removed, .zero)
        }
    }

    /// Where a host-clock timestamp falls on the recording timeline, or nil
    /// when it is not part of the recording: before the origin (or before
    /// `start`), inside a pause, or at or after `stop`.
    public func recordingTime(forHostTime hostTime: CMTime) -> CMTime? {
        state.withLock { state in
            guard let origin = state.origin, hostTime >= origin else { return nil }
            if let stop = state.stop, hostTime >= stop { return nil }
            var removed = CMTime.zero
            for pause in state.pauses {
                // Pauses are chronological: this one and the rest lie after the stamp.
                if hostTime < pause.start { break }
                guard let end = pause.end, hostTime >= end else { return nil }
                removed = removed + (end - pause.start)
            }
            return hostTime - origin - removed
        }
    }

    /// `recordingTime(forHostTime:)` for a stamp in seconds, as `CGEvent`
    /// timestamps and AppKit readings arrive in the telemetry recorder.
    public func recordingTime(forHostTimeSeconds seconds: Double) -> Double? {
        recordingTime(forHostTime: CMTime(seconds: seconds, preferredTimescale: Self.timescale))?.seconds
    }

    /// Host time of a `CGEventTimestamp`, which counts nanoseconds of the same
    /// uptime clock (`CGEventTypes.h`).
    public static func hostTime(eventTimestamp: UInt64) -> CMTime {
        CMTime(value: CMTimeValue(clamping: eventTimestamp), timescale: Self.timescale)
    }

    /// Host time of an `NSEvent.timestamp`: the same uptime clock as
    /// `CGEventTimestamp`, in seconds. NSEvent.h names no base; spike S3
    /// compares the stamp with that of the `CGEvent` behind the same event
    /// (`NSEvent.cgEvent`), and AppKit converts between the two with no
    /// offset (platform-notes "Click monitors").
    public static func hostTime(eventTimestamp seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timescale)
    }

    /// Nanoseconds, the host clock's own resolution.
    static let timescale: CMTimeScale = 1_000_000_000
}
