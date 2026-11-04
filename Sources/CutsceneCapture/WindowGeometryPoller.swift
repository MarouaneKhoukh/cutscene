import CoreGraphics
import CoreMedia
import CutsceneCore
import Foundation
import Synchronization

/// The numbers the geometry poll runs with (ARCHITECTURE §2 "Scroll, focus,
/// geometry").
public struct WindowGeometryPollerSettings: Sendable, Equatable {
    /// Polls per second on a display or area take, where every ordinary
    /// window is tracked: a window moved by hand changes frame a few times a
    /// second, and the engine only needs to know where windows settle.
    public var displayRateHz: Double = 4
    /// Polls per second on a window take, where the one window is tracked:
    /// its moves are what the crop follows, and ScreenCaptureKit's own
    /// per-frame bounding rect carries the fine motion, so the poll only
    /// has to notice a move within a frame or two of the camera spring.
    public var windowRateHz: Double = 10
    /// How late a tick may fire, as a fraction of its period; the poll is
    /// not a clock, so libdispatch may coalesce it.
    public var leewayFraction: Double = 0.1
    /// Smallest change on any edge, in points, that counts as a move. The
    /// window list reports whole points; a half point absorbs rounding
    /// without losing a one-point nudge.
    public var movementThreshold: Double = 0.5
    /// Below this alpha a listed window is invisible (a fading or hidden
    /// panel) and is left out of the display-wide tracking.
    public var minimumAlpha: Double = 0.01

    public init() {}
}

/// Counters for the end-of-take report.
public struct WindowGeometryPollerStatistics: Sendable, Equatable {
    public var ticks = 0
    /// Geometry events forwarded: first sightings and changes.
    public var events = 0
    /// Windows seen at least once.
    public var windowsSeen = 0
    /// Ticks on which the watched window (window scope) was not listed on
    /// screen: minimised, closed or on another Space.
    public var watchedWindowMissing = 0
    /// Seconds each `CGWindowListCopyWindowInfo` call took, so a spike can
    /// report the poll's cost against its period.
    public var pollCostsSeconds: [Double] = []
    public var lastFrames: [CGWindowID: PointRect] = [:]
}

/// Window geometry as the window server lists it, polled with
/// `CGWindowListCopyWindowInfo` (no permission) at `displayRateHz`, or at
/// `windowRateHz` for the one window of a window take, into format-2
/// `geometry` events (ARCHITECTURE §2 "Scroll, focus, geometry").
///
/// The window list is the only permission-free source of other windows'
/// frames, and a poll is enough: ScreenCaptureKit attaches the captured
/// window's bounding rect to every frame of a `.displaySurface` take, so the
/// poll is the coarse record (which window is where, for the editor and for
/// the strategies without a per-frame rect), not the motion. Frames are in
/// the points of the captured display with a top-left origin (the window
/// list's global bounds less the display's origin), the space of
/// `EventLog.captureRectPoints`, so a consumer can re-normalize telemetry
/// against them. An event is forwarded when a window is first seen and
/// whenever its frame moves by at least `movementThreshold` on any edge;
/// `windowID` keys the events, so a consumer follows one window across them.
///
/// Lock-guarded and timer-driven on its own queue, like the telemetry
/// recorder; the handler receives a value and may hand it anywhere. Nothing
/// here prompts: the window list hands out bounds to any process, and the
/// titles that need Screen Recording are not read.
public final class WindowGeometryPoller: @unchecked Sendable {
    /// Which windows are tracked.
    public enum Scope: Sendable, Equatable {
        /// The one window of a window take, at `windowRateHz`.
        case window(CGWindowID)
        /// Every ordinary on-screen window (layer 0, visible, not ours) of a
        /// display or area take, at `displayRateHz`.
        case display
    }

    /// One window frame as the window server listed it.
    public struct Event: Sendable, Equatable {
        /// Host clock reading when the list was taken; the list itself
        /// carries no stamp.
        public var hostTime: CMTime
        public var windowID: CGWindowID
        /// The frame in display-local points, top-left origin.
        public var frame: PointRect
        public var ownerPID: pid_t
        /// Whether this is the first frame seen for the window rather than
        /// a change.
        public var isFirstSighting: Bool

        public init(hostTime: CMTime, windowID: CGWindowID, frame: PointRect, ownerPID: pid_t, isFirstSighting: Bool) {
            self.hostTime = hostTime
            self.windowID = windowID
            self.frame = frame
            self.ownerPID = ownerPID
            self.isFirstSighting = isFirstSighting
        }

        /// The event as the log records it, on `clock`'s timeline; nil when
        /// the clock places it outside the recording.
        public func inputEvent(clock: RecordingClock) -> InputEvent? {
            guard let time = clock.recordingTime(forHostTime: hostTime)?.seconds else { return nil }
            return .geometry(time: time, windowID: windowID, frame: frame)
        }
    }

    /// Called on the poller's queue for every event; it must return fast.
    public typealias Handler = @Sendable (Event) -> Void

    private struct State {
        var timer: (any DispatchSourceTimer)?
        var handler: Handler?
        var statistics = WindowGeometryPollerStatistics()
        var isRunning = false
    }

    public let scope: Scope
    public let settings: WindowGeometryPollerSettings
    /// Bounds of the captured display in Quartz global coordinates, the
    /// origin the frames are made local to.
    public let displayBounds: CGRect

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "app.cutscene.capture.geometry", qos: .utility)
    /// Marks `queue` so `stop` can tell when it is called from a tick (the
    /// handler stopping the poller, or the last reference dropped inside
    /// one): a `sync` onto the queue the caller already runs on would
    /// deadlock, and libdispatch aborts on it.
    private let queueKey = DispatchSpecificKey<Bool>()
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    public init(
        scope: Scope, displayBounds: CGRect, settings: WindowGeometryPollerSettings = WindowGeometryPollerSettings(),
        handler: @escaping Handler
    ) {
        self.scope = scope
        self.displayBounds = displayBounds
        self.settings = settings
        state = Mutex(State(handler: handler))
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // No tick can be in flight once the last reference is gone (`tick`
        // runs on a strong reference), so the timer is only cancelled; a
        // wait here would deadlock when the release happens inside a tick.
        let timer = state.withLock { state -> (any DispatchSourceTimer)? in
            state.handler = nil
            state.isRunning = false
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    /// Polls per second for `scope`.
    public var rateHz: Double {
        switch scope {
        case .window: settings.windowRateHz
        case .display: settings.displayRateHz
        }
    }

    public var statistics: WindowGeometryPollerStatistics {
        state.withLock { $0.statistics }
    }

    /// Starts polling; the first tick runs at once. Does nothing when
    /// already running or stopped.
    public func start() {
        let period = 1 / max(rateHz, 0.001)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(
            deadline: .now(), repeating: period, leeway: .milliseconds(Int(period * settings.leewayFraction * 1000)))
        let started: Bool = state.withLock { state in
            guard state.timer == nil, state.handler != nil else { return false }
            state.timer = timer
            state.isRunning = true
            return true
        }
        if started {
            timer.activate()
        } else {
            // libdispatch refuses to release a source that was never
            // activated, so the unused one is activated to be cancelled.
            timer.activate()
            timer.cancel()
        }
    }

    /// Stops polling and forwarding; a tick in flight finishes first, except
    /// when `stop` is called from the handler itself (on the poller's
    /// queue), which returns without waiting since the tick is the caller.
    /// Safe to call more than once and from any thread.
    public func stop() {
        let timer = state.withLock { state -> (any DispatchSourceTimer)? in
            state.handler = nil
            state.isRunning = false
            defer { state.timer = nil }
            return state.timer
        }
        guard let timer else { return }
        timer.cancel()
        guard DispatchQueue.getSpecific(key: queueKey) != true else { return }
        queue.sync {}
    }

    private func tick() {
        let started = ContinuousClock.now
        let now = RecordingClock.hostTime()
        let listed = Self.listWindows(scope: scope, excludingProcess: ownProcessID, minimumAlpha: settings.minimumAlpha)
        let cost = ContinuousClock.now - started
        let costSeconds = Double(cost.components.seconds) + Double(cost.components.attoseconds) / 1e18
        let origin = displayBounds.origin
        var events: [Event] = []
        let handler = state.withLock { state -> Handler? in
            guard state.isRunning else { return nil }
            state.statistics.ticks += 1
            state.statistics.pollCostsSeconds.append(costSeconds)
            if case .window(let id) = scope, !listed.contains(where: { $0.id == id }) {
                state.statistics.watchedWindowMissing += 1
            }
            for window in listed {
                let frame = PointRect(window.bounds.offsetBy(dx: -origin.x, dy: -origin.y))
                let last = state.statistics.lastFrames[window.id]
                let first = last == nil
                guard first || Self.moved(frame, from: last, threshold: settings.movementThreshold) else { continue }
                state.statistics.lastFrames[window.id] = frame
                if first { state.statistics.windowsSeen += 1 }
                state.statistics.events += 1
                events.append(
                    Event(
                        hostTime: now, windowID: window.id, frame: frame, ownerPID: window.ownerPID,
                        isFirstSighting: first)
                )
            }
            return state.handler
        }
        guard let handler else { return }
        for event in events {
            handler(event)
        }
    }

    private static func moved(_ frame: PointRect, from last: PointRect?, threshold: Double) -> Bool {
        guard let last else { return true }
        return abs(frame.x - last.x) >= threshold || abs(frame.y - last.y) >= threshold
            || abs(frame.width - last.width) >= threshold || abs(frame.height - last.height) >= threshold
    }

    // MARK: Window list

    /// One row of the window list, as the poller reads it.
    public struct ListedWindow: Sendable, Equatable {
        public var id: CGWindowID
        /// Quartz global bounds (top-left origin at the main display).
        public var bounds: CGRect
        public var ownerPID: pid_t
        public var layer: Int
        public var alpha: Double
    }

    /// The on-screen windows the window server lists, front to back, for
    /// `scope`: the one window, or every layer-0 window above `minimumAlpha`
    /// that is not ours. Needs no permission.
    public static func listWindows(scope: Scope, excludingProcess: pid_t? = nil, minimumAlpha: Double = 0.01)
        -> [ListedWindow]
    {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var windows: [ListedWindow] = []
        for row in rows {
            guard let window = ListedWindow(row: row) else { continue }
            switch scope {
            case .window(let id):
                guard window.id == id else { continue }
            case .display:
                guard window.layer == 0, window.alpha >= minimumAlpha, window.ownerPID != excludingProcess else {
                    continue
                }
            }
            windows.append(window)
        }
        return windows
    }

    /// The bounds of one window as the window server lists it right now,
    /// in Quartz global coordinates; nil when it is not on screen.
    public static func bounds(ofWindow id: CGWindowID) -> CGRect? {
        listWindows(scope: .window(id)).first?.bounds
    }

    /// The frontmost ordinary (layer 0) on-screen window of a process, which
    /// is what a `focus` event names; nil when the process has none.
    public static func frontmostWindowID(ofProcess pid: pid_t) -> CGWindowID? {
        listWindows(scope: .display).first { $0.ownerPID == pid }?.id
    }
}

extension WindowGeometryPoller.ListedWindow {
    /// Reads the keys the poller needs; a row without them (the window
    /// server lists a few bookkeeping windows that way) is skipped.
    fileprivate init?(row: [String: Any]) {
        guard let number = row[kCGWindowNumber as String] as? CGWindowID,
            let boundsValue = row[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsValue),
            let pid = row[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        id = number
        self.bounds = bounds
        ownerPID = pid
        layer = row[kCGWindowLayer as String] as? Int ?? 0
        alpha = row[kCGWindowAlpha as String] as? Double ?? 1
    }
}
