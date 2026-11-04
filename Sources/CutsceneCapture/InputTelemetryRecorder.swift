import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreMedia
import CutsceneCore
import Foundation
import Synchronization

/// Counters for the report at the end of a recording.
public struct InputTelemetryStatistics: Sendable, Equatable {
    /// Pointer-poll ticks that landed on the recording timeline; ticks during
    /// a pause do not count.
    public var samplerTicks = 0
    /// Recording time the sampler ran for, in seconds: pauses excluded.
    public var activeSeconds: Double = 0
    /// Whether clicks and keys come from the event tap. False means Input
    /// Monitoring was not granted, or the tap could not be installed, so
    /// button events are derived from the pointer poll and keys are absent.
    public var eventTapActive = false
    /// Times macOS disabled the tap and the recorder switched it back on.
    public var eventTapReenables = 0
    /// Completed incremental flushes to the sidecar beside `persistenceURL`.
    public var persistedWrites = 0
    public var persistenceFailures = 0
    public var lastPersistenceError: String?
    /// Whether clicks and scrolls come from the `NSEvent` monitors, the tier
    /// between the tap and the poll. False with the tap live (it sees every
    /// click, so the monitors would only duplicate it), without an
    /// application event loop to service them, or when AppKit refused them.
    public var clickMonitorsActive = false
    /// Button events the monitors delivered and the log took.
    public var monitorButtonEvents = 0
    public var monitorScrollEvents = 0
    /// Monitor button events dropped because the poll had already written
    /// the same edge after waiting out `monitorGracePeriod`.
    public var monitorDuplicatesDropped = 0
    /// Button changes the poll noticed, with the tap off.
    public var pollEdgesDetected = 0
    /// Of those, the ones the monitors also delivered: their exact stamp
    /// stands and the poll's sighting is dropped.
    public var pollEdgesSuperseded = 0
    /// Of those, the ones written with the poll's own stamp: every edge with
    /// the monitors off, and with them on the edges they missed, such as the
    /// mouse-up inside one of our own controls' tracking loops.
    public var pollEdgesWritten = 0
    /// For every edge both sources reported, the monitor's stamp minus the
    /// host time of the poll tick that noticed it, in seconds: at most one
    /// poll period negative when both are right. Spike S3 reads the median.
    public var monitorPollOffsetsSeconds: [Double] = []

    /// Ticks per active second: the rate `pointerMoved` could be emitted at.
    public var measuredSamplingRateHz: Double {
        activeSeconds > 0 ? Double(samplerTicks) / activeSeconds : 0
    }
}

/// Records pointer, button, key and cursor-shape telemetry for one take into
/// a `CutsceneCore.EventLog` (research brief §5.1).
///
/// Pointer positions come from a 125 Hz poll of `NSEvent.mouseLocation`
/// rather than from mouse-moved events: a poll needs no permission, gives the
/// smoothing spring a steady cadence, and still catches every click through
/// `pressedMouseButtons` edges. Clicks and scrolls come from the most exact
/// source available, in order: a listen-only `CGEventTap` when Input
/// Monitoring has already been granted (exact stamps, keys as well, nothing
/// missed); else `ClickMonitors`, the permission-free `NSEvent` monitors
/// (exact stamps, but no mouse-up from a nested tracking loop in our own
/// windows, and nothing at all without an application event loop); else the
/// poll's button edges, up to one period late. While the monitors run, the
/// poll stays on as their backstop: an edge it notices waits
/// `monitorGracePeriod` for the monitors' exact copy and is written with the
/// poll's own stamp only when none arrives, and an edge the monitors
/// delivered first is recognized by button and time when the poll notices
/// the same change, so no click is written twice. The recorder never asks
/// for the Input Monitoring grant, because the prompt belongs to a user
/// action in the app: see `requestInputMonitoringAccess()`.
///
/// Every event is stamped through the `RecordingClock` the media is written
/// on, so events and frames share one origin and lose the same pauses; an
/// event that falls inside a pause is dropped by the clock. Tap events carry
/// the time the window server generated them, not the time the callback ran.
/// Positions are normalized within the capture rect; a pointer outside it
/// yields values outside 0...1, which is how a consumer tells that the pointer
/// left the recorded area, and why nothing is clamped.
///
/// One recorder records one take: `start` once, `stop` once; pausing is the
/// clock's job. Every method may be called from any thread. The sampling path
/// waits on nothing but the state lock, which no holder keeps for longer than
/// a few appends, and never touches the main actor.
///
/// With a `persistenceURL`, new events are appended every `persistenceInterval`
/// to a JSON Lines sidecar next to it (a header with the log's metadata is
/// written first), so a flush costs only the events since the last one rather
/// than a rewrite of the whole log, which at the one-hour mark would be 20 MB
/// every five seconds. `stop` writes the complete log to `persistenceURL` and
/// removes the sidecar; after a crash, `recoverLog(persistenceURL:)` rebuilds
/// the log from the two files.
public final class InputTelemetryRecorder: @unchecked Sendable {
    /// Pointer poll period. The brief calls 8 ms "120 Hz"; it is 125 Hz, and
    /// the log records the true figure. Consumers interpolate on timestamps.
    public static let samplingInterval: TimeInterval = 0.008
    /// Cursor-shape poll period: every other pointer tick.
    public static let cursorShapeInterval: TimeInterval = 0.016
    /// How often new events are flushed to the sidecar unless the initializer
    /// says otherwise. A crash loses at most this much telemetry.
    public static let defaultPersistenceInterval: TimeInterval = 5
    /// Smallest change on either axis that produces a `pointerMoved`: 1/4096
    /// of the capture rect is under a pixel on any display and far below what
    /// a rendered frame can show, so a resting pointer costs no events while
    /// real motion loses nothing.
    public static let movementThreshold = 1.0 / 4096
    /// How long a button edge the poll noticed waits for the monitors' exact
    /// copy before it is written with the poll's own stamp. Monitor delivery
    /// is asynchronous on the main thread, a few milliseconds when it is idle
    /// and more when it is busy; waiting costs nothing, since the log orders
    /// by time and nothing reads it live, so the wait is generous.
    public static let monitorGracePeriod: TimeInterval = 0.1
    /// How far apart the monitors' stamp and the poll's sighting of one edge
    /// may lie and still be the same edge: one poll period, since the poll
    /// notices a change on its next tick, plus scheduling slack. A real
    /// second edge of the same button and direction is at least a click
    /// apart, far outside this.
    public static let edgeMatchTolerance: TimeInterval = 0.05
    /// How long a written or delivered edge stays known for matching, which
    /// bounds how late the other source's copy may arrive without being
    /// written again. Delivery stalls this long would mean a hung main
    /// thread; the lists hold a handful of entries either way.
    public static let edgeRetention: TimeInterval = 5

    private enum Phase {
        case idle
        /// `start` is setting up; claimed first so two callers cannot both start.
        case starting
        case recording
        case stopped
    }

    private struct State {
        var phase = Phase.idle
        var log: EventLog?
        var clock: RecordingClock?
        /// The clock's recording time when sampling began; `activeSeconds` is
        /// measured from here.
        var elapsedAtStart: Double = 0
        /// Height in points of the display AppKit's global coordinates hang
        /// from, read when recording starts.
        var mainDisplayHeight: Double = 0
        var lastPosition: NormalizedPoint?
        var lastButtons = 0
        /// Modifier state at the previous `flagsChanged`, to tell a press from
        /// a release for keys without a known flag.
        var tapFlags = CGEventFlags()
        /// Events appended since the last flush, in arrival order. Kept apart
        /// from the log because a late tap event lands in the middle of it.
        var unpersisted: [InputEvent] = []
        var statistics = InputTelemetryStatistics()
        var samplerTimer: (any DispatchSourceTimer)?
        var persistenceTimer: (any DispatchSourceTimer)?
        var tap: EventTapMonitor?
        var monitors: ClickMonitors?
        /// Button edges the poll noticed: waiting out `monitorGracePeriod`
        /// for the monitors' copy, or written and kept `edgeRetention` so a
        /// late copy is recognized rather than written again.
        var pollEdges: [PollEdge] = []
        /// Edges the monitors delivered before the poll noticed them, kept
        /// `edgeRetention` so the poll's own sighting is not written again.
        var monitorEdges: [MonitorEdge] = []
    }

    /// One button change: Quartz button number and direction.
    private struct ButtonEdge: Hashable {
        var button: Int
        var isDown: Bool
    }

    private struct PollEdge {
        var edge: ButtonEdge
        /// Host time of the tick that noticed the change.
        var hostSeconds: Double
        var time: Double
        var position: NormalizedPoint
        var written = false
    }

    private struct MonitorEdge {
        var edge: ButtonEdge
        var hostSeconds: Double
    }

    /// Bounds of the captured display in Quartz global coordinates (top-left
    /// origin at the main display), as `CGDisplayBounds` reports them.
    public let displayBounds: CGRect
    /// The captured area in display-local points, top-left origin.
    public let captureRectPoints: PointRect
    public let displayID: CGDirectDisplayID
    public let pointPixelScale: Double
    public let recordingID: UUID
    /// Where the complete log is written on `stop`, with incremental flushes
    /// to `sidecarURL(for:)` beside it meanwhile. Nil keeps the log in memory only.
    public let persistenceURL: URL?
    /// Seconds between flushes to the sidecar.
    public let persistenceInterval: TimeInterval
    /// Whether `start` installs `ClickMonitors` when the tap is not live.
    /// Even then the monitors need the application's event loop, so a
    /// process without `NSApp` keeps the poll as its click source.
    public let usesClickMonitors: Bool

    private let state = Mutex(State())
    private let cursorSampler: CursorShapeSampler
    private let samplingQueue = DispatchQueue(label: "app.cutscene.telemetry.sampler", qos: .utility)
    private let persistenceQueue = DispatchQueue(label: "app.cutscene.telemetry.persistence", qos: .utility)
    /// Touched only on `persistenceQueue`.
    private let sidecar = Sidecar()

    /// `captureRectPoints` must have a positive size; positions are divided
    /// by it. `usesClickMonitors` is off only for a caller that wants the
    /// poll's edges alone, such as a measurement of the poll itself.
    public init(
        displayBounds: CGRect,
        captureRectPoints: PointRect,
        displayID: CGDirectDisplayID,
        pointPixelScale: Double,
        recordingID: UUID = UUID(),
        persistenceURL: URL? = nil,
        persistenceInterval: TimeInterval = InputTelemetryRecorder.defaultPersistenceInterval,
        usesClickMonitors: Bool = true,
        cursorSource: any SystemCursorSource = AppKitCursorSource()
    ) {
        precondition(
            captureRectPoints.width > 0 && captureRectPoints.height > 0, "The capture rect must have a positive size.")
        precondition(persistenceInterval > 0, "The persistence interval must be positive.")
        self.displayBounds = displayBounds
        self.captureRectPoints = captureRectPoints
        self.displayID = displayID
        self.pointPixelScale = pointPixelScale
        self.recordingID = recordingID
        self.persistenceURL = persistenceURL
        self.persistenceInterval = persistenceInterval
        self.usesClickMonitors = usesClickMonitors
        cursorSampler = CursorShapeSampler(source: cursorSource)
    }

    deinit {
        // Dropped mid-take without `stop`: the timers must not keep firing,
        // and the tap and the monitors must leave the session.
        let (tap, monitors) = state.withLock { state -> (EventTapMonitor?, ClickMonitors?) in
            state.samplerTimer?.cancel()
            state.persistenceTimer?.cancel()
            defer {
                state.tap = nil
                state.monitors = nil
            }
            return (state.tap, state.monitors)
        }
        tap?.stop()
        monitors?.stop()
    }

    // MARK: Permissions

    /// Whether this process may install a listening event tap, checked without
    /// any prompt.
    public static var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the Input Monitoring prompt, or opens the path to System
    /// Settings when the user has already declined once. Call it from a user
    /// action in the app, never from the recording path: the prompt interrupts
    /// whatever the user is doing, and a grant typically reaches only the next
    /// launch, as with Screen Recording. Returns the state at the time of the
    /// call; a recorder started afterwards re-checks it.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: Lifecycle

    /// Begins sampling on `clock`, the timeline the media is written on: its
    /// origin becomes the log's time zero and its pauses drop the events they
    /// cover. Returns once sampling is live, after about 25 ms of setup (the
    /// Input Monitoring preflight is an IPC round trip, the first AppKit read
    /// opens the window-server connection), so the first sample lands that
    /// far after an origin taken just before the call. The `NSEvent`
    /// monitors, when they apply, are installed on the main thread: at once
    /// when `start` runs there, otherwise through the main run loop a moment
    /// later, with the poll covering the gap. Returns quietly if the recorder
    /// has already started.
    public func start(clock: RecordingClock) {
        let claimed = state.withLock { state -> Bool in
            guard state.phase == .idle else { return false }
            state.phase = .starting
            return true
        }
        guard claimed else { return }

        // Setup runs before sampling opens, so `activeSeconds` measures
        // sampling alone. The tap is attempted only when the grant already
        // exists: creating one without it is what raises the Input Monitoring
        // prompt, and a recorder must never do that behind the user's back.
        var tap: EventTapMonitor?
        if Self.isInputMonitoringGranted {
            tap = EventTapMonitor.start { [weak self] type, event in self?.handleTap(type: type, event: event) }
        }
        if let persistenceURL {
            try? FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // The first AppKit read opens the window-server connection, about
        // 16 ms that would otherwise delay the first tick.
        _ = NSEvent.mouseLocation
        _ = cursorSampler.source.readCursor()

        // Strict timers skip libdispatch's power-saving coalescing, which
        // would otherwise widen the 8 ms period by its QoS-based leeway.
        let samplerTimer = DispatchSource.makeTimerSource(flags: .strict, queue: samplingQueue)
        samplerTimer.setEventHandler { [weak self] in self?.samplerTick() }
        samplerTimer.schedule(
            deadline: .now(), repeating: .milliseconds(Int(Self.samplingInterval * 1000)), leeway: .microseconds(500))
        var persistenceTimer: (any DispatchSourceTimer)?
        if persistenceURL != nil {
            let timer = DispatchSource.makeTimerSource(queue: persistenceQueue)
            timer.setEventHandler { [weak self] in self?.persist() }
            timer.schedule(
                deadline: .now() + persistenceInterval, repeating: persistenceInterval,
                leeway: .milliseconds(Int(min(persistenceInterval * 100, 500))))
            persistenceTimer = timer
        }

        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let log = makeLog(startHostTimeSeconds: clock.origin.seconds)
        let elapsedAtStart = clock.elapsed.seconds
        let started: Bool = state.withLock { state in
            guard state.phase == .starting else {
                // `stop` ran during setup. libdispatch refuses to release a
                // source that was never activated, so each one is activated
                // only to be cancelled.
                samplerTimer.activate()
                samplerTimer.cancel()
                persistenceTimer?.activate()
                persistenceTimer?.cancel()
                return false
            }
            state.phase = .recording
            state.clock = clock
            state.elapsedAtStart = elapsedAtStart
            state.mainDisplayHeight = mainDisplayHeight
            state.log = log
            state.tap = tap
            state.statistics.eventTapActive = tap != nil
            state.samplerTimer = samplerTimer
            state.persistenceTimer = persistenceTimer
            // Activated under the lock: the first tick is due at once and runs
            // the moment the lock is released, against the clock just set.
            samplerTimer.activate()
            persistenceTimer?.activate()
            return true
        }
        guard started else {
            // Outside the lock, for the same reason as in `stop`.
            tap?.stop()
            return
        }
        // The tap sees every click with an exact stamp; the monitors would
        // only duplicate it.
        if tap == nil, usesClickMonitors {
            installClickMonitors()
        }
    }

    /// Ends the take and returns the complete log. Waits for samples in
    /// flight, so nothing changes after it returns, and when a
    /// `persistenceURL` was given the final log is on disk as well, with the
    /// sidecar removed. Calling it again, or without `start`, returns the log
    /// as it stands.
    public func stop() -> EventLog {
        let (tap, monitors, log) = state.withLock { state -> (EventTapMonitor?, ClickMonitors?, EventLog) in
            if state.phase == .recording, let clock = state.clock {
                state.statistics.activeSeconds = clock.elapsed.seconds - state.elapsedAtStart
                // Edges still waiting for a monitor copy are the poll's to
                // write now; nothing more will arrive.
                flushPollEdges(now: RecordingClock.hostTime().seconds, force: true, state: &state)
            }
            state.phase = .stopped
            state.samplerTimer?.cancel()
            state.persistenceTimer?.cancel()
            state.samplerTimer = nil
            state.persistenceTimer = nil
            defer {
                state.tap = nil
                state.monitors = nil
            }
            return (state.tap, state.monitors, state.log ?? makeLog(startHostTimeSeconds: 0))
        }
        // Outside the lock: the tap thread may be waiting for it in a callback,
        // and `stop` waits for that callback to finish; the monitors' handler
        // may be waiting the same way on the main thread.
        tap?.stop()
        monitors?.stop()
        if let tap {
            state.withLock { $0.statistics.eventTapReenables = tap.reenableCount }
        }
        samplingQueue.sync {}
        persistenceQueue.sync { self.persistComplete(log) }
        return log
    }

    /// Adds an event another source observed (a `WindowGeometryPoller`'s
    /// `geometry` row, a `FocusMonitor`'s `focus` row) to the log at its
    /// place in time order, from any thread, so the take's `events.json`
    /// carries every format-2 source and the sidecar flushes it like the
    /// recorder's own. The event's time is already on the recording's
    /// clock; one that arrives before `start` or after `stop` is dropped,
    /// since the log it belongs to does not exist yet or is written.
    public func append(_ event: InputEvent) {
        state.withLock { state in
            guard state.phase == .recording else { return }
            append(event, to: &state)
        }
    }

    public var statistics: InputTelemetryStatistics {
        let (statistics, tap) = state.withLock { state -> (InputTelemetryStatistics, EventTapMonitor?) in
            var statistics = state.statistics
            if state.phase == .recording, let clock = state.clock {
                statistics.activeSeconds = clock.elapsed.seconds - state.elapsedAtStart
            }
            return (statistics, state.tap)
        }
        guard let tap else { return statistics }
        var live = statistics
        live.eventTapReenables = tap.reenableCount
        return live
    }

    /// PNG data for every cursor shape seen so far, keyed by the ids in the
    /// log's `cursorShapeChanged` events. Complete once `stop` has returned.
    public func sprites() -> [String: Data] {
        cursorSampler.sprites()
    }

    // MARK: Sampling

    private func samplerTick() {
        // Both class properties report the window server's current device
        // state, "independent of which events have been delivered via the
        // event stream" (NSEvent.h), and the SDK does not isolate them to the
        // main actor, so this poll never hops to the main thread, which the
        // app's own UI work would otherwise stall.
        let location = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let now = RecordingClock.hostTime()

        let cursorSampleTime: Double? = state.withLock { state in
            guard state.phase == .recording, let time = state.clock?.recordingTime(forHostTime: now)?.seconds else {
                return nil
            }
            state.statistics.samplerTicks += 1

            let position = normalized(appKitGlobal: location, mainDisplayHeight: state.mainDisplayHeight)
            let moved = state.lastPosition.map {
                abs(position.x - $0.x) >= Self.movementThreshold || abs(position.y - $0.y) >= Self.movementThreshold
            }
            if moved ?? true {
                append(.pointerMoved(time: time, position: position), to: &state)
                state.lastPosition = position
            }

            // With the tap live, button edges are its job. Otherwise the poll
            // notices them and `notePollEdge` decides whether the monitors
            // already delivered them. Changes on bit n are button n in Quartz
            // numbering, which `pressedMouseButtons` shares.
            if !state.statistics.eventTapActive {
                if buttons != state.lastButtons {
                    let changed = buttons ^ state.lastButtons
                    for bit in 0..<Int.bitWidth where changed & (1 << bit) != 0 {
                        let edge = ButtonEdge(button: bit, isDown: buttons & (1 << bit) != 0)
                        notePollEdge(edge, hostSeconds: now.seconds, time: time, position: position, state: &state)
                    }
                    state.lastButtons = buttons
                }
                flushPollEdges(now: now.seconds, state: &state)
            }
            return state.statistics.samplerTicks % 2 == 1 ? time : nil
        }

        // The cursor read and hash run outside the lock so the tap thread is
        // never held up by them.
        guard let cursorSampleTime, let event = cursorSampler.sample(at: cursorSampleTime) else { return }
        state.withLock { state in
            guard state.phase == .recording else { return }
            append(event, to: &state)
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        // The event's own stamp, not the callback's: the tap thread can run
        // late behind a busy system, and a click must land where the frame
        // that shows it does.
        let hostTime = RecordingClock.hostTime(eventTimestamp: event.timestamp)
        let location = event.location
        let flags = event.flags
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        state.withLock { state in
            guard state.phase == .recording, let time = state.clock?.recordingTime(forHostTime: hostTime)?.seconds
            else { return }
            let position = normalized(quartzGlobal: location)
            let modifiers = InputEvent.Modifiers(flags)
            switch type {
            case .leftMouseDown:
                append(.buttonDown(time: time, position: position, button: .left), to: &state)
            case .leftMouseUp:
                append(.buttonUp(time: time, position: position, button: .left), to: &state)
            case .rightMouseDown:
                append(.buttonDown(time: time, position: position, button: .right), to: &state)
            case .rightMouseUp:
                append(.buttonUp(time: time, position: position, button: .right), to: &state)
            case .otherMouseDown:
                append(.buttonDown(time: time, position: position, button: .other(buttonNumber)), to: &state)
            case .otherMouseUp:
                append(.buttonUp(time: time, position: position, button: .other(buttonNumber)), to: &state)
            case .keyDown:
                append(.keyDown(time: time, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat), to: &state)
            case .keyUp:
                append(.keyUp(time: time, keyCode: keyCode, modifiers: modifiers), to: &state)
            case .flagsChanged:
                // A modifier press arrives as a flags change, not a key event.
                // The key's own flag says whether it went down; for a key with
                // no known flag, any newly set bit means a press.
                let previous = state.tapFlags
                state.tapFlags = flags
                let isDown: Bool
                if let flag = Self.modifierFlag(forKeyCode: keyCode) {
                    isDown = flags.contains(flag)
                } else {
                    isDown = flags.rawValue & ~previous.rawValue != 0
                }
                if isDown {
                    append(.keyDown(time: time, keyCode: keyCode, modifiers: modifiers, isRepeat: false), to: &state)
                } else {
                    append(.keyUp(time: time, keyCode: keyCode, modifiers: modifiers), to: &state)
                }
            default:
                break
            }
        }
    }

    // MARK: Click monitors

    /// Installs the `NSEvent` monitors on the main thread, where AppKit
    /// installs and services them: at once when called there, otherwise
    /// through the main run loop rather than the main dispatch queue, which a
    /// nested `NSApplication.run` does not drain.
    private func installClickMonitors() {
        let install: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                // The monitors are serviced by the application's event loop.
                // In a process without one (a command-line tool) nothing would
                // ever call them, and the poll stays the click source.
                guard NSApp != nil else { return }
                let monitors = ClickMonitors { [weak self] observation in self?.handleMonitor(observation) }
                let unused: ClickMonitors? = state.withLock { state in
                    // `stop` ran first.
                    guard state.phase == .recording else { return monitors }
                    state.monitors = monitors
                    state.statistics.clickMonitorsActive = monitors.isActive
                    return nil
                }
                unused?.stop()
            }
        }
        if Thread.isMainThread {
            install()
        } else {
            RunLoop.main.perform(inModes: [.common], block: install)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Takes a monitor observation, on the main thread.
    private func handleMonitor(_ observation: ClickMonitors.Observation) {
        state.withLock { state in
            guard state.phase == .recording, state.statistics.clickMonitorsActive,
                let time = state.clock?.recordingTime(forHostTime: observation.hostTime)?.seconds
            else { return }
            let position = normalized(quartzGlobal: observation.location)
            let edge: ButtonEdge
            let event: InputEvent
            switch observation.kind {
            case .scroll(let deltaX, let deltaY, let phase, _):
                append(
                    .scroll(time: time, position: position, deltaX: deltaX, deltaY: deltaY, phase: phase), to: &state)
                state.statistics.monitorScrollEvents += 1
                return
            case .buttonDown(let button):
                edge = ButtonEdge(button: Self.number(of: button), isDown: true)
                event = .buttonDown(time: time, position: position, button: button)
            case .buttonUp(let button):
                edge = ButtonEdge(button: Self.number(of: button), isDown: false)
                event = .buttonUp(time: time, position: position, button: button)
            }
            let hostSeconds = observation.hostTime.seconds
            if let index = state.pollEdges.firstIndex(where: {
                $0.edge == edge && abs($0.hostSeconds - hostSeconds) <= Self.edgeMatchTolerance
            }) {
                let seen = state.pollEdges.remove(at: index)
                state.statistics.monitorPollOffsetsSeconds.append(hostSeconds - seen.hostSeconds)
                if seen.written {
                    // The grace period ran out and the poll wrote this edge;
                    // a second copy would press the button twice.
                    state.statistics.monitorDuplicatesDropped += 1
                    return
                }
                state.statistics.pollEdgesSuperseded += 1
            } else {
                state.monitorEdges.append(MonitorEdge(edge: edge, hostSeconds: hostSeconds))
            }
            append(event, to: &state)
            state.statistics.monitorButtonEvents += 1
        }
    }

    /// A button change the poll noticed, at the tick's host time: dropped
    /// when the monitors already delivered it, otherwise queued for
    /// `flushPollEdges`.
    private func notePollEdge(
        _ edge: ButtonEdge, hostSeconds: Double, time: Double, position: NormalizedPoint, state: inout State
    ) {
        state.statistics.pollEdgesDetected += 1
        if let index = state.monitorEdges.firstIndex(where: {
            $0.edge == edge && abs($0.hostSeconds - hostSeconds) <= Self.edgeMatchTolerance
        }) {
            let seen = state.monitorEdges.remove(at: index)
            state.statistics.pollEdgesSuperseded += 1
            state.statistics.monitorPollOffsetsSeconds.append(seen.hostSeconds - hostSeconds)
            return
        }
        state.pollEdges.append(PollEdge(edge: edge, hostSeconds: hostSeconds, time: time, position: position))
    }

    /// Writes the poll's edges whose grace period has passed (every one with
    /// `force`, at stop) and forgets edges older than `edgeRetention`. With
    /// the monitors off there is no copy to wait for, so an edge is written
    /// on the tick that noticed it.
    private func flushPollEdges(now: Double, force: Bool = false, state: inout State) {
        let monitorsActive = state.statistics.clickMonitorsActive
        let grace = monitorsActive ? Self.monitorGracePeriod : 0
        for index in state.pollEdges.indices where !state.pollEdges[index].written {
            let pending = state.pollEdges[index]
            guard force || now - pending.hostSeconds >= grace else { continue }
            let button = Self.button(number: pending.edge.button)
            if pending.edge.isDown {
                append(.buttonDown(time: pending.time, position: pending.position, button: button), to: &state)
            } else {
                append(.buttonUp(time: pending.time, position: pending.position, button: button), to: &state)
            }
            state.pollEdges[index].written = true
            state.statistics.pollEdgesWritten += 1
        }
        state.pollEdges.removeAll { $0.written && (!monitorsActive || now - $0.hostSeconds > Self.edgeRetention) }
        state.monitorEdges.removeAll { now - $0.hostSeconds > Self.edgeRetention }
    }

    private func append(_ event: InputEvent, to state: inout State) {
        guard state.log?.append(event) == true else { return }
        if persistenceURL != nil {
            state.unpersisted.append(event)
        }
    }

    // MARK: Persistence

    /// The JSON Lines file that receives new events between flushes.
    public static func sidecarURL(for persistenceURL: URL) -> URL {
        persistenceURL.deletingPathExtension().appendingPathExtension("events.jsonl")
    }

    /// Rebuilds the log of a take that never reached `stop`: the header the
    /// recorder wrote at its first flush plus every complete line of the
    /// sidecar. A line torn by the crash ends the read; everything before it
    /// is kept. Without a sidecar, the file at `persistenceURL` is returned as
    /// it is, which after a normal `stop` is the complete log.
    public static func recoverLog(persistenceURL: URL) throws -> EventLog {
        var log = try EventLog.read(from: persistenceURL)
        let sidecarURL = sidecarURL(for: persistenceURL)
        guard let data = try? Data(contentsOf: sidecarURL) else { return log }
        let decoder = JSONDecoder()
        var recovered: [InputEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let event = try? decoder.decode(InputEvent.self, from: line) else { break }
            recovered.append(event)
        }
        log.append(contentsOf: recovered)
        return log
    }

    /// Appends the events since the last flush to the sidecar, writing the
    /// header first when this is the first flush.
    private func persist() {
        guard let persistenceURL else { return }
        let (header, events) = state.withLock { state -> (EventLog?, [InputEvent]) in
            guard let log = state.log else { return (nil, []) }
            defer { state.unpersisted.removeAll(keepingCapacity: true) }
            var header: EventLog?
            if !sidecar.headerWritten {
                header = log
                header?.removeAllEvents()
            }
            return (header, state.unpersisted)
        }
        do {
            if let header {
                try header.write(to: persistenceURL)
                sidecar.headerWritten = true
            }
            try sidecar.append(events, to: Self.sidecarURL(for: persistenceURL))
            state.withLock { $0.statistics.persistedWrites += 1 }
        } catch {
            state.withLock { state in
                state.statistics.persistenceFailures += 1
                state.statistics.lastPersistenceError = error.localizedDescription
            }
        }
    }

    /// Writes the complete log atomically and removes the sidecar, whose
    /// contents it now contains.
    private func persistComplete(_ log: EventLog) {
        guard let persistenceURL else { return }
        do {
            try log.write(to: persistenceURL)
            sidecar.close()
            try? FileManager.default.removeItem(at: Self.sidecarURL(for: persistenceURL))
            state.withLock { $0.statistics.persistedWrites += 1 }
        } catch {
            state.withLock { state in
                state.statistics.persistenceFailures += 1
                state.statistics.lastPersistenceError = error.localizedDescription
            }
        }
    }

    /// The open sidecar file. Confined to `persistenceQueue`, hence no lock;
    /// a class so the recorder's methods can mutate it without `inout`.
    private final class Sidecar: @unchecked Sendable {
        var headerWritten = false
        private var handle: FileHandle?
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()

        func append(_ events: [InputEvent], to url: URL) throws {
            guard !events.isEmpty else { return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: url)
                try opened.seekToEnd()
                handle = opened
            }
            var data = Data()
            for event in events {
                data.append(try encoder.encode(event))
                data.append(UInt8(ascii: "\n"))
            }
            try handle?.write(contentsOf: data)
        }

        func close() {
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: Conversions

    private func makeLog(startHostTimeSeconds: Double) -> EventLog {
        EventLog(
            recordingID: recordingID, startHostTimeSeconds: startHostTimeSeconds, captureRectPoints: captureRectPoints,
            displayID: displayID, pointPixelScale: pointPixelScale, samplingRateHz: 1 / Self.samplingInterval)
    }

    /// AppKit's global space has its origin at the bottom-left of the main
    /// display; Quartz's at its top-left. Flipping against the main display's
    /// height, not the captured display's, is what makes a secondary display
    /// come out right.
    private func normalized(appKitGlobal point: NSPoint, mainDisplayHeight: Double) -> NormalizedPoint {
        normalized(quartzGlobal: CGPoint(x: point.x, y: mainDisplayHeight - point.y))
    }

    private func normalized(quartzGlobal point: CGPoint) -> NormalizedPoint {
        let localX = point.x - displayBounds.minX
        let localY = point.y - displayBounds.minY
        return NormalizedPoint(
            x: (localX - captureRectPoints.x) / captureRectPoints.width,
            y: (localY - captureRectPoints.y) / captureRectPoints.height)
    }

    private static func button(number: Int) -> InputEvent.Button {
        switch number {
        case 0: .left
        case 1: .right
        default: .other(number)
        }
    }

    /// The Quartz button number behind a `Button`, the inverse of `button(number:)`.
    private static func number(of button: InputEvent.Button) -> Int {
        switch button {
        case .left: 0
        case .right: 1
        case .other(let number): number
        }
    }

    /// The flag each modifier key drives, by its virtual key code.
    private static func modifierFlag(forKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Shift, kVK_RightShift: .maskShift
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Function: .maskSecondaryFn
        case kVK_CapsLock: .maskAlphaShift
        default: nil
        }
    }
}

extension InputEvent.Modifiers {
    fileprivate init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskCommand) { insert(.command) }
        if flags.contains(.maskSecondaryFn) { insert(.function) }
        if flags.contains(.maskAlphaShift) { insert(.capsLock) }
    }
}

// MARK: - Event tap

/// A listen-only session event tap serviced by a run loop on its own thread,
/// so a busy main thread cannot starve the tap into the timeout that makes
/// macOS disable it.
///
/// The tap is placed last in the chain so it sees events as the apps receive
/// them, after any remapping tool ahead of it. Callbacks forward to `handler`
/// on the tap thread and must return fast; the recorder's handler takes one
/// short lock.
private final class EventTapMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Void

    /// Core Foundation handles carry no Sendable annotation. Both are safe to
    /// hand across threads by contract (`CFMachPortInvalidate` and
    /// `CFRunLoopStop` are the documented teardown from another thread), so
    /// the box only exists to keep them under the lock.
    private struct Ports: @unchecked Sendable {
        var port: CFMachPort?
        var runLoop: CFRunLoop?
    }

    private struct State {
        var ports = Ports()
        var reenables = 0
    }

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .keyDown, .keyUp, .flagsChanged,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private let handler: Handler
    private let state = Mutex(State())
    private let finished = DispatchSemaphore(value: 0)

    private init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Installs the tap and returns once it is live, or nil when macOS refused
    /// it: no Input Monitoring grant, or a binary whose signature changed since
    /// the grant. The caller then falls back to polling.
    static func start(handler: @escaping Handler) -> EventTapMonitor? {
        let monitor = EventTapMonitor(handler: handler)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { monitor.run(ready: ready) }
        thread.name = "app.cutscene.telemetry.tap"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        return monitor.isLive ? monitor : nil
    }

    var isLive: Bool {
        state.withLock { $0.ports.port != nil }
    }

    var reenableCount: Int {
        state.withLock { $0.reenables }
    }

    /// Tears the tap down and waits for its thread to exit, so no callback
    /// runs after this returns. Safe to call more than once.
    func stop() {
        let ports = state.withLock { state -> Ports in
            defer { state.ports = Ports() }
            return state.ports
        }
        guard let port = ports.port else { return }
        CFMachPortInvalidate(port)
        if let runLoop = ports.runLoop {
            CFRunLoopStop(runLoop)
        }
        // Bounded in case the run loop never comes back; the port is already
        // invalid by then, so no further callbacks can fire.
        _ = finished.wait(timeout: .now() + .seconds(2))
    }

    private func run(ready: DispatchSemaphore) {
        defer { finished.signal() }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: Self.mask, callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        state.withLock { $0.ports = Ports(port: port, runLoop: runLoop) }
        ready.signal()
        CFRunLoopRun()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches off a tap it considers unresponsive (and, for the
            // second case, on some secure-input transitions). Both are
            // recoverable; staying off would silently lose every later click.
            state.withLock { state in
                guard let port = state.ports.port else { return }
                CGEvent.tapEnable(tap: port, enable: true)
                state.reenables += 1
            }
        default:
            handler(type, event)
        }
    }
}

/// The C callback Quartz invokes per event on the tap thread; `userInfo` is
/// the monitor, kept alive by its thread until the run loop exits.
private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
