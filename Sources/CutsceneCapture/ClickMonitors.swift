import AppKit
import CoreGraphics
import CoreMedia
import CutsceneCore
import Foundation
import Synchronization

/// Mouse-button and scroll events observed through `NSEvent` monitors, which
/// need no permission: the header gates only key events behind Accessibility
/// (NSEvent.h), and spike S3 checks that mouse monitors raise no prompt from
/// a reset TCC state (platform-notes "Click monitors").
///
/// Two monitors cover everything: the global one receives copies of events
/// sent to other applications and skips our own, so a local one adds those.
/// Each event carries the window server's stamp (`NSEvent.timestamp`), which
/// `RecordingClock.hostTime(eventTimestamp:)` puts on the host clock, so a
/// click lands where the frame that shows it does instead of up to one poll
/// period late. The handler receives a value, never the `NSEvent`, so it can
/// hand the observation to any thread.
///
/// What the monitors cannot do, from the header: the local monitor is called
/// only for events dispatched through `NSApplication.sendEvent`, not for
/// those consumed by nested tracking loops (a control tracking a click, menu
/// tracking, window dragging), so the mouse-up that ends a click on one of
/// our own buttons never arrives; delivery is asynchronous on the main
/// thread, a few milliseconds behind the event while that thread is idle and
/// longer when it is busy; and both monitors are serviced by the
/// application's event loop, so they are silent in a process without one.
/// `InputTelemetryRecorder` therefore keeps its button poll as the backstop
/// for the edges the monitors miss.
///
/// Create on the main actor, where AppKit installs the monitors and calls
/// the handler; `stop` may be called from any thread.
public final class ClickMonitors: @unchecked Sendable {
    /// Which monitor delivered an observation.
    public enum Source: Sendable, Hashable {
        /// `addGlobalMonitorForEvents`: an event sent to another application.
        case global
        /// `addLocalMonitorForEvents`: an event sent to this application.
        case local
    }

    /// What an observed event was.
    public enum Kind: Sendable, Hashable {
        case buttonDown(InputEvent.Button)
        case buttonUp(InputEvent.Button)
        /// `scrollingDeltaX`/`scrollingDeltaY` as AppKit delivers them, after
        /// the user's natural-scrolling preference: points when `isPrecise`
        /// (trackpads and the Magic Mouse), wheel notches otherwise.
        case scroll(deltaX: Double, deltaY: Double, phase: InputEvent.ScrollPhase, isPrecise: Bool)

        public var isButton: Bool {
            switch self {
            case .buttonDown, .buttonUp: true
            case .scroll: false
            }
        }
    }

    /// One observed event, as a value.
    public struct Observation: Sendable {
        public var kind: Kind
        /// The event's own time: `NSEvent.timestamp` on the host clock.
        public var hostTime: CMTime
        /// The stamp of the `CGEvent` behind the event, on the host clock;
        /// nil for an event without one. Spike S3 compares it with
        /// `hostTime`.
        public var quartzHostTime: CMTime?
        /// Host clock reading when the monitor's handler ran, so
        /// `deliveredAt − hostTime` is the delivery latency.
        public var deliveredAt: CMTime
        /// The pointer in Quartz global coordinates (top-left origin of the
        /// main display), the space of `CGEvent.location`.
        public var location: CGPoint
        public var source: Source
        /// `NSEvent.windowNumber`: the window the event was sent to, which for
        /// a global observation belongs to another application; 0 when none.
        public var windowNumber: Int
        /// `NSEvent.clickCount` for a button event, 0 for a scroll.
        public var clickCount: Int

        public init(
            kind: Kind, hostTime: CMTime, quartzHostTime: CMTime?, deliveredAt: CMTime, location: CGPoint,
            source: Source, windowNumber: Int, clickCount: Int
        ) {
            self.kind = kind
            self.hostTime = hostTime
            self.quartzHostTime = quartzHostTime
            self.deliveredAt = deliveredAt
            self.location = location
            self.source = source
            self.windowNumber = windowNumber
            self.clickCount = clickCount
        }
    }

    /// Called on the main thread for every observation; it must return fast,
    /// since the local monitor runs inside the application's event dispatch.
    public typealias Handler = @Sendable (Observation) -> Void

    /// Event types the monitors ask for: the three button pairs and the
    /// scroll wheel. Pointer motion stays with the poll, whose cadence needs
    /// no event delivery.
    public static let eventMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
    ]

    /// The opaque tokens AppKit returns for installed monitors. They carry no
    /// Sendable annotation; `removeMonitor` is their only use and it runs on
    /// the main thread, so the box exists to keep them under the lock.
    private struct Handles: @unchecked Sendable {
        var global: Any?
        var local: Any?
    }

    private struct Key: Equatable {
        var type: UInt
        var timestamp: TimeInterval
    }

    private struct State {
        var handles = Handles()
        var handler: Handler?
        /// The last event forwarded, so one event reaching both monitors
        /// (the header says it does not) would be forwarded once.
        var lastKey: Key?
        var observations = 0
    }

    private let state: Mutex<State>
    /// The activation observer, when `focusHandler` was given.
    private let focus: FocusMonitor?

    /// Installs both monitors. AppKit may refuse either; `isGlobalActive` and
    /// `isLocalActive` say which took. With a `focusHandler`, a `FocusMonitor`
    /// is installed beside them and stopped with them, so one object covers
    /// the three permission-free sources of the format-2 log (clicks,
    /// scrolls, focus).
    @MainActor
    public init(handler: @escaping Handler, focusHandler: FocusMonitor.Handler? = nil) {
        state = Mutex(State(handler: handler))
        focus = focusHandler.map { FocusMonitor(handler: $0) }
        let global = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { @Sendable [weak self] event in
            self?.observe(event, from: .global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { @Sendable [weak self] event in
            self?.observe(event, from: .local)
            // Returning the event lets AppKit dispatch it; nil would swallow it.
            return event
        }
        state.withLock { $0.handles = Handles(global: global, local: local) }
    }

    deinit {
        stop()
    }

    public var isGlobalActive: Bool {
        state.withLock { $0.handles.global != nil }
    }

    public var isLocalActive: Bool {
        state.withLock { $0.handles.local != nil }
    }

    /// Whether at least one monitor is installed.
    public var isActive: Bool {
        state.withLock { $0.handles.global != nil || $0.handles.local != nil }
    }

    /// Observations forwarded so far.
    public var observationCount: Int {
        state.withLock { $0.observations }
    }

    /// Stops forwarding at once and removes the monitors on the main thread:
    /// directly when called there, otherwise through the main run loop, so a
    /// caller on another thread never waits behind a busy main thread. Safe
    /// to call more than once.
    public func stop() {
        focus?.stop()
        let handles = state.withLock { state -> Handles in
            state.handler = nil
            defer { state.handles = Handles() }
            return state.handles
        }
        guard handles.global != nil || handles.local != nil else { return }
        let remove: @Sendable () -> Void = {
            if let global = handles.global { NSEvent.removeMonitor(global) }
            if let local = handles.local { NSEvent.removeMonitor(local) }
        }
        if Thread.isMainThread {
            remove()
        } else {
            // Common modes, so the removal also runs while a menu or a drag
            // holds the main loop in a tracking mode; `perform` schedules
            // without waking the loop.
            RunLoop.main.perform(inModes: [.common], block: remove)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func observe(_ event: NSEvent, from source: Source) {
        let deliveredAt = RecordingClock.hostTime()
        guard let kind = Self.kind(of: event) else { return }
        let timestamp = event.timestamp
        let quartz = event.cgEvent
        let clickCount: Int
        switch kind {
        case .buttonDown, .buttonUp:
            clickCount = event.clickCount
        case .scroll:
            // Asking a scroll event for its click count raises an exception.
            clickCount = 0
        }
        let observation = Observation(
            kind: kind,
            hostTime: RecordingClock.hostTime(eventTimestamp: timestamp),
            quartzHostTime: quartz.map { RecordingClock.hostTime(eventTimestamp: $0.timestamp) },
            deliveredAt: deliveredAt,
            // Without a CGEvent, the pointer's position now: within the
            // delivery latency of where the event happened.
            location: quartz?.location ?? Self.quartzGlobal(appKitGlobal: NSEvent.mouseLocation),
            source: source,
            windowNumber: event.windowNumber,
            clickCount: clickCount)
        let handler = state.withLock { state -> Handler? in
            let key = Key(type: event.type.rawValue, timestamp: timestamp)
            guard state.lastKey != key else { return nil }
            state.lastKey = key
            state.observations += 1
            return state.handler
        }
        handler?(observation)
    }

    private static func kind(of event: NSEvent) -> Kind? {
        switch event.type {
        case .leftMouseDown: .buttonDown(.left)
        case .leftMouseUp: .buttonUp(.left)
        case .rightMouseDown: .buttonDown(.right)
        case .rightMouseUp: .buttonUp(.right)
        // `buttonNumber` is Quartz numbering, which `InputEvent.Button.other`
        // and the poll's `pressedMouseButtons` bits share.
        case .otherMouseDown: .buttonDown(.other(event.buttonNumber))
        case .otherMouseUp: .buttonUp(.other(event.buttonNumber))
        case .scrollWheel:
            .scroll(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                phase: scrollPhase(phase: event.phase, momentum: event.momentumPhase),
                isPrecise: event.hasPreciseScrollingDeltas)
        default: nil
        }
    }

    /// AppKit's two phase fields folded into the log's one; momentum first,
    /// since an event in its momentum phase carries no gesture phase.
    static func scrollPhase(phase: NSEvent.Phase, momentum: NSEvent.Phase) -> InputEvent.ScrollPhase {
        if !momentum.isEmpty {
            if momentum.contains(.began) { return .momentumBegan }
            if momentum.contains(.ended) || momentum.contains(.cancelled) { return .momentumEnded }
            return .momentumChanged
        }
        if phase.isEmpty { return .discrete }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.began) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        // `changed`, and `stationary`, which a scroll never reports but
        // which would mean the same: fingers down, nothing ended.
        return .changed
    }

    /// AppKit's global space has its origin at the bottom-left of the main
    /// display, Quartz's at its top-left.
    private static func quartzGlobal(appKitGlobal point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }
}

// MARK: - Focus

/// The frontmost application, observed through
/// `NSWorkspace.didActivateApplicationNotification` (ARCHITECTURE §2 "Scroll,
/// focus, geometry"): the source of the format-2 `focus` event, which needs
/// no permission. The notification carries no timestamp, so an observation
/// is stamped when it is delivered, on the main thread, a few milliseconds
/// after the switch; and it names the application only, so the window is
/// looked up in the window list at that moment (`windowID`), the frontmost
/// ordinary window of that process, which is nil for an application that
/// has none on screen.
///
/// Create on the main actor; `stop` may be called from any thread.
public final class FocusMonitor: @unchecked Sendable {
    /// One activation, as a value.
    public struct Observation: Sendable, Equatable {
        /// Host clock reading when the notification was delivered.
        public var hostTime: CMTime
        public var bundleID: String
        public var processID: pid_t
        public var applicationName: String?
        /// The frontmost ordinary window of the application at delivery,
        /// from the window list; nil when it has none on screen.
        public var windowID: CGWindowID?

        public init(
            hostTime: CMTime, bundleID: String, processID: pid_t, applicationName: String? = nil,
            windowID: CGWindowID? = nil
        ) {
            self.hostTime = hostTime
            self.bundleID = bundleID
            self.processID = processID
            self.applicationName = applicationName
            self.windowID = windowID
        }

        /// The observation as the log records it, on `clock`'s timeline;
        /// nil when the clock places it outside the recording.
        public func inputEvent(clock: RecordingClock) -> InputEvent? {
            guard let time = clock.recordingTime(forHostTime: hostTime)?.seconds else { return nil }
            return .focus(time: time, bundleID: bundleID, windowID: windowID)
        }
    }

    /// Called on the main thread for every activation.
    public typealias Handler = @Sendable (Observation) -> Void

    /// The observer token carries no Sendable annotation; it is only ever
    /// handed back to `removeObserver`.
    private struct Token: @unchecked Sendable {
        var value: (any NSObjectProtocol)?
    }

    private struct State {
        var token = Token()
        var handler: Handler?
        var observations = 0
    }

    private let state: Mutex<State>

    /// Starts observing. The observer runs on the main queue, where AppKit
    /// posts the notification.
    @MainActor
    public init(handler: @escaping Handler) {
        state = Mutex(State(handler: handler))
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.observe(application)
        }
        state.withLock { $0.token = Token(value: token) }
    }

    deinit {
        stop()
    }

    public var isActive: Bool {
        state.withLock { $0.token.value != nil }
    }

    /// Observations forwarded so far.
    public var observationCount: Int {
        state.withLock { $0.observations }
    }

    /// The frontmost application right now, as an observation stamped now:
    /// what a recorder writes at start so the log opens with a known focus.
    public static func current() -> Observation? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return observation(of: application, at: RecordingClock.hostTime())
    }

    /// Stops forwarding and removes the observer. Safe to call more than once.
    public func stop() {
        let token = state.withLock { state -> Token in
            state.handler = nil
            defer { state.token = Token() }
            return state.token
        }
        guard let value = token.value else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(value)
    }

    private func observe(_ application: NSRunningApplication?) {
        let now = RecordingClock.hostTime()
        guard let application, let observation = Self.observation(of: application, at: now) else { return }
        let handler = state.withLock { state -> Handler? in
            guard state.handler != nil else { return nil }
            state.observations += 1
            return state.handler
        }
        handler?(observation)
    }

    private static func observation(of application: NSRunningApplication, at hostTime: CMTime) -> Observation? {
        // A process without a bundle identifier (a bare executable) is
        // named by its process id, so the row is still a usable key.
        let bundleID = application.bundleIdentifier ?? "pid:\(application.processIdentifier)"
        return Observation(
            hostTime: hostTime, bundleID: bundleID, processID: application.processIdentifier,
            applicationName: application.localizedName,
            windowID: WindowGeometryPoller.frontmostWindowID(ofProcess: application.processIdentifier))
    }
}
