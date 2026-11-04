import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import CutsceneCapture
import CutsceneCore
import Foundation
import Synchronization

/// Spike S3, permission-free clicks through `NSEvent` monitors (PLAN M1-07,
/// ARCHITECTURE §9.3).
///
/// Opens a window of its own for a few seconds and records the main
/// display's telemetry through `InputTelemetryRecorder` while an independent
/// `ClickMonitors` counts what the monitors deliver, then reports the clicks
/// the monitors saw against the poll's button edges (and against the tap
/// when Input Monitoring is already granted), the median monitor − poll-edge
/// offset, delivery latency, and the permission states, read by preflight
/// only. Before the human phase, a synthetic mouse-down, mouse-up and scroll
/// posted to our own event queue prove the local-monitor path with nobody at
/// the mouse. Nothing here prompts: the monitors need no grant, and the tap
/// is installed only when the grant already exists.
enum ClickSpike {
    static let defaultSeconds = 10.0
    /// ARCHITECTURE §9.3: the median monitor − poll-edge offset stays within
    /// one poll period, and so does the NSEvent − CGEvent stamp difference.
    static let maxOffsetMedianSeconds = 0.008
    static let maxStampSkewSeconds = 0.008
    /// How long the synthetic phase pumps our own event queue; the events
    /// are already queued, so this is slack, not a wait.
    static let syntheticPumpSeconds = 0.3
    /// How far apart a monitor stamp and a tap stamp of one click may lie
    /// and still be paired for the offset.
    static let pairingToleranceSeconds = 0.05
    static let windowSize = NSSize(width: 480, height: 280)
    /// Where the synthetic click lands, in the window's own coordinates.
    static let syntheticPoint = NSPoint(x: 40, y: 40)
    /// Spacing of the synthetic stamps, so they are distinct and in order.
    static let syntheticSpacingSeconds = 0.05
    static let syntheticScrollDeltaY: Int32 = -12
    /// Flushes come this often, so even a short run exercises the sidecar.
    static let persistenceInterval = 2.0
    static let countdownTickSeconds = 0.25

    static func run(arguments: [String]) async -> Bool {
        var seconds = defaultSeconds
        if let first = arguments.first {
            guard let value = Double(first), value > 0 else {
                print("unknown argument \(first); expected a duration in seconds")
                return false
            }
            seconds = value
        }
        if arguments.count > 1 {
            print("too many arguments; expected [seconds]")
            return false
        }
        let inputMonitoring = InputTelemetryRecorder.isInputMonitoringGranted
        let accessibility = AXIsProcessTrusted()
        print(
            "clicks spike: \(seconds) s with our own window; preflights only: Input Monitoring "
                + (inputMonitoring ? "granted (tap on)" : "not granted (tap off)") + ", Accessibility "
                + (accessibility ? "trusted" : "not trusted")
                + "; NSEvent mouse monitors need neither, and nothing here prompts")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutscene-spike", isDirectory: true)
            .appendingPathComponent("clicks-\(stamp).json")
        let report = await stage(seconds: seconds, persistenceURL: url)
        return evaluate(report)
    }

    // MARK: Staging

    /// Everything AppKit, on the main thread: the window, the synthetic
    /// phase, then the recorder under `NSApplication.run` for `seconds`.
    @MainActor
    private static func stage(seconds: Double, persistenceURL: URL) -> Report {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let panel = SpikeWindow(size: windowSize)
        panel.show()
        app.finishLaunching()
        app.activate()

        // Synthetic phase: our own queue, the local monitor, nobody at the mouse.
        let syntheticSeen = Collector()
        let syntheticMonitors = ClickMonitors { syntheticSeen.add($0) }
        let posted = panel.postSyntheticEvents()
        pump(app, for: syntheticPumpSeconds)
        let selfTest = SelfTest(
            posted: posted, seen: syntheticSeen.snapshot(), globalInstalled: syntheticMonitors.isGlobalActive,
            localInstalled: syntheticMonitors.isLocalActive)
        syntheticMonitors.stop()
        let activeAtStart = app.isActive

        // Human phase: the recorder's own monitors plus an independent pair
        // that counts everything AppKit delivers.
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let clock = RecordingClock()
        let recorder = InputTelemetryRecorder(
            displayBounds: bounds,
            captureRectPoints: PointRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
            displayID: displayID, pointPixelScale: pointPixelScale(of: displayID), persistenceURL: persistenceURL,
            persistenceInterval: persistenceInterval)
        let seen = Collector()
        let monitors = ClickMonitors { seen.add($0) }
        recorder.start(clock: clock)
        print(
            "GO: for \(seconds) s, click on the \"\(panel.window.title)\" window, its button and elsewhere; scroll too")
        fflush(stdout)
        panel.run(app, seconds: seconds)
        let log = recorder.stop()
        clock.stop()
        let globalInstalled = monitors.isGlobalActive
        let localInstalled = monitors.isLocalActive
        monitors.stop()
        let activeAtEnd = app.isActive
        panel.close()
        return Report(
            seconds: seconds, windowNumber: panel.windowNumber, activeAtStart: activeAtStart, activeAtEnd: activeAtEnd,
            selfTest: selfTest, observations: seen.snapshot(), globalInstalled: globalInstalled,
            localInstalled: localInstalled, log: log, statistics: recorder.statistics,
            recordedSeconds: clock.elapsed.seconds, persistenceURL: persistenceURL)
    }

    /// Dispatches whatever is queued, then waits out `seconds` for more: the
    /// documented alternative to `run` for a loop of our own.
    @MainActor
    private static func pump(_ app: NSApplication, for seconds: Double) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }

    /// Pixels per point of the display's current mode; 1 when unknown.
    private static func pointPixelScale(of displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    // MARK: Report

    private struct SelfTest: Sendable {
        var posted: Int
        var seen: [ClickMonitors.Observation]
        var globalInstalled: Bool
        var localInstalled: Bool
    }

    private struct Report: Sendable {
        var seconds: Double
        var windowNumber: Int
        var activeAtStart: Bool
        var activeAtEnd: Bool
        var selfTest: SelfTest
        var observations: [ClickMonitors.Observation]
        var globalInstalled: Bool
        var localInstalled: Bool
        var log: EventLog
        var statistics: InputTelemetryStatistics
        var recordedSeconds: Double
        var persistenceURL: URL
    }

    private static func evaluate(_ report: Report) -> Bool {
        var failures: [String] = []
        var notes: [String] = []

        let selfTest = report.selfTest
        let selfLocal = selfTest.seen.filter { $0.source == .local }
        let selfGlobal = selfTest.seen.filter { $0.source == .global }
        print(
            "self-test: \(selfTest.posted) synthetic events posted to our own queue; local monitor saw "
                + "\(selfLocal.count) (\(selfLocal.map { describe($0.kind) }.joined(separator: ", "))), global monitor "
                + "\(selfGlobal.count); monitors installed: global \(yesNo(selfTest.globalInstalled)), local "
                + "\(yesNo(selfTest.localInstalled)); CGEvent behind \(selfTest.seen.filter { $0.quartzHostTime != nil }.count) "
                + "of \(selfTest.seen.count); stamp skew max \(milliseconds(maxStampSkew(selfTest.seen)))")
        if !selfTest.globalInstalled { failures.append("the global monitor was not installed") }
        if !selfTest.localInstalled { failures.append("the local monitor was not installed") }
        if selfLocal.count != selfTest.posted {
            failures.append("the local monitor saw \(selfLocal.count) of \(selfTest.posted) synthetic events")
        }

        let observations = report.observations
        let buttons = observations.filter { $0.kind.isButton }
        let global = observations.filter { $0.source == .global }
        let local = observations.filter { $0.source == .local }
        let own = observations.filter { $0.kind.isButton && $0.windowNumber == report.windowNumber }
        let latencies = observations.map { ($0.deliveredAt - $0.hostTime).seconds }
        print(
            "monitors: \(observations.count) observations in \(format(report.seconds)) s (installed: global "
                + "\(yesNo(report.globalInstalled)), local \(yesNo(report.localInstalled)); app active at start "
                + "\(yesNo(report.activeAtStart)), at end \(yesNo(report.activeAtEnd))): global \(counts(global)), local "
                + "\(counts(local)), on our window \(counts(own)); delivery latency median "
                + "\(milliseconds(median(latencies))), max \(milliseconds(latencies.max())); stamp skew max "
                + "\(milliseconds(maxStampSkew(observations)))")

        let statistics = report.statistics
        var logDowns = 0
        var logUps = 0
        var logScrolls = 0
        for event in report.log.events {
            switch event {
            case .buttonDown: logDowns += 1
            case .buttonUp: logUps += 1
            case .scroll: logScrolls += 1
            default: break
            }
        }
        print(
            "recorder: \(format(statistics.activeSeconds)) s active at "
                + "\(String(format: "%.1f", statistics.measuredSamplingRateHz)) Hz; click monitors "
                + "\(statistics.clickMonitorsActive ? "active" : "off"), tap \(statistics.eventTapActive ? "on" : "off"); "
                + "log buttonDown \(logDowns), buttonUp \(logUps), scroll \(logScrolls); monitor button events "
                + "\(statistics.monitorButtonEvents), scroll \(statistics.monitorScrollEvents), duplicates dropped "
                + "\(statistics.monitorDuplicatesDropped); poll edges detected \(statistics.pollEdgesDetected), "
                + "superseded \(statistics.pollEdgesSuperseded), written \(statistics.pollEdgesWritten)")
        let offsets = statistics.monitorPollOffsetsSeconds
        print(
            "offset monitor − poll edge: \(offsets.count) pairs, median \(milliseconds(median(offsets))) (limit ±"
                + "\(milliseconds(maxOffsetMedianSeconds))), min \(milliseconds(offsets.min())), max "
                + "\(milliseconds(offsets.max()))")
        var tapOffsets: [Double] = []
        if statistics.eventTapActive {
            tapOffsets = pairWithTap(observations: buttons, log: report.log)
            print(
                "tap: \(tapOffsets.count) of \(buttons.count) monitor clicks paired with tap clicks; monitor − tap median "
                    + "\(milliseconds(median(tapOffsets))), max |\(milliseconds(tapOffsets.map(abs).max()))|")
        }
        print("persisted: \(report.persistenceURL.path)")

        if buttons.isEmpty {
            notes.append(
                "no clicks were made during the run, so the monitor − poll comparison and the own-window check are "
                    + "pending a human run")
        } else {
            let monitorDowns = buttons.filter { if case .buttonDown = $0.kind { true } else { false } }.count
            if logDowns < monitorDowns {
                failures.append("the log holds \(logDowns) buttonDown events for \(monitorDowns) the monitors saw")
            }
            if logDowns != logUps {
                notes.append("the log is unbalanced (\(logDowns) downs, \(logUps) ups)")
            }
            if own.isEmpty {
                notes.append(
                    "no click landed on our own window, so the local-monitor path is proven by the self-test only")
            }
            if let skew = maxStampSkew(observations), skew > maxStampSkewSeconds {
                failures.append("NSEvent and CGEvent stamps differ by up to \(milliseconds(skew))")
            }
            if statistics.eventTapActive {
                if let tapMedian = median(tapOffsets) {
                    if abs(tapMedian) > maxOffsetMedianSeconds {
                        failures.append("monitor − tap offset median \(milliseconds(tapMedian)) is over the limit")
                    }
                } else {
                    failures.append("no monitor click could be paired with a tap click")
                }
            } else if let offsetMedian = median(offsets) {
                if abs(offsetMedian) > maxOffsetMedianSeconds {
                    failures.append("monitor − poll-edge offset median \(milliseconds(offsetMedian)) is over the limit")
                }
            } else {
                failures.append("no monitor click was paired with a poll edge")
            }
        }

        for note in notes {
            print("note: \(note)")
        }
        if !failures.isEmpty {
            print("FAIL: " + failures.joined(separator: "; "))
            return false
        }
        if buttons.isEmpty {
            print(
                "INCONCLUSIVE: the self-test and the permission-free installation passed; the human-click measurement is pending"
            )
            return true
        }
        print("PASS")
        return true
    }

    /// Pairs each monitor click with the nearest tap click of the same kind
    /// in the log and returns monitor − tap stamps, in seconds.
    private static func pairWithTap(observations: [ClickMonitors.Observation], log: EventLog) -> [Double] {
        var candidates = log.events.compactMap { event -> (kind: ClickMonitors.Kind, hostSeconds: Double)? in
            switch event {
            case .buttonDown(let time, _, let button, _):
                (.buttonDown(button), log.startHostTimeSeconds + time)
            case .buttonUp(let time, _, let button, _):
                (.buttonUp(button), log.startHostTimeSeconds + time)
            default:
                nil
            }
        }
        var offsets: [Double] = []
        for observation in observations {
            let host = observation.hostTime.seconds
            let nearest = candidates.indices
                .filter { candidates[$0].kind == observation.kind }
                .min { abs(candidates[$0].hostSeconds - host) < abs(candidates[$1].hostSeconds - host) }
            guard let index = nearest, abs(candidates[index].hostSeconds - host) <= pairingToleranceSeconds else {
                continue
            }
            offsets.append(host - candidates[index].hostSeconds)
            candidates.remove(at: index)
        }
        return offsets
    }

    // MARK: Formatting

    private static func counts(_ observations: [ClickMonitors.Observation]) -> String {
        var downs = 0
        var ups = 0
        var scrolls = 0
        for observation in observations {
            switch observation.kind {
            case .buttonDown: downs += 1
            case .buttonUp: ups += 1
            case .scroll: scrolls += 1
            }
        }
        return "\(downs) down / \(ups) up / \(scrolls) scroll"
    }

    private static func describe(_ kind: ClickMonitors.Kind) -> String {
        switch kind {
        case .buttonDown(let button): "down \(describe(button))"
        case .buttonUp(let button): "up \(describe(button))"
        case .scroll(let deltaX, let deltaY, let phase, let isPrecise):
            "scroll (\(format(deltaX)), \(format(deltaY))) \(phase.rawValue)\(isPrecise ? " precise" : "")"
        }
    }

    private static func describe(_ button: InputEvent.Button) -> String {
        switch button {
        case .left: "left"
        case .right: "right"
        case .other(let number): "button \(number)"
        }
    }

    /// Largest |NSEvent stamp − CGEvent stamp| over the observations that
    /// carry both; nil when none does.
    private static func maxStampSkew(_ observations: [ClickMonitors.Observation]) -> Double? {
        observations.compactMap { observation in
            observation.quartzHostTime.map { abs((observation.hostTime - $0).seconds) }
        }.max()
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func milliseconds(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.2f ms", $0 * 1000) } ?? "n/a"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

/// Observations from a `ClickMonitors`, collected on the main thread and
/// read once the loop has ended.
private final class Collector: Sendable {
    private let observations = Mutex<[ClickMonitors.Observation]>([])

    func add(_ observation: ClickMonitors.Observation) {
        observations.withLock { $0.append(observation) }
    }

    func snapshot() -> [ClickMonitors.Observation] {
        observations.withLock { $0 }
    }
}

/// The window the lead clicks on, with a control whose tracking loop keeps
/// the mouse-up from the local monitor, and the timer that ends
/// `NSApplication.run`.
@MainActor
private final class SpikeWindow: NSObject {
    let window: NSWindow
    private let label: NSTextField
    private var deadline = Date()

    init(size: NSSize) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered,
            defer: false)
        window.title = "Cutscene click spike"
        window.isReleasedWhenClosed = false
        window.level = .floating
        label = NSTextField(wrappingLabelWithString: "Preparing…")
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        super.init()
        let button = NSButton(title: "Button (its tracking loop hides the mouse-up)", target: nil, action: nil)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        if let content = window.contentView {
            stack.frame = content.bounds
            stack.autoresizingMask = [.width, .height]
            content.addSubview(stack)
        }
    }

    var windowNumber: Int {
        window.windowNumber
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    /// Posts a left down, a left up and a scroll to our own event queue,
    /// stamped on the host clock. They never reach the window server, so
    /// they need no permission and the global monitor and the poll never see
    /// them. Returns how many were posted.
    func postSyntheticEvents() -> Int {
        let base = RecordingClock.hostTime().seconds
        var posted = 0
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: ClickSpike.syntheticPoint, modifierFlags: [], timestamp: base,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        {
            NSApp.postEvent(down, atStart: false)
            posted += 1
        }
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: ClickSpike.syntheticPoint, modifierFlags: [],
            timestamp: base + ClickSpike.syntheticSpacingSeconds, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0)
        {
            NSApp.postEvent(up, atStart: false)
            posted += 1
        }
        if let scroll = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: ClickSpike.syntheticScrollDeltaY,
            wheel2: 0, wheel3: 0)
        {
            scroll.timestamp = CGEventTimestamp((base + 2 * ClickSpike.syntheticSpacingSeconds) * 1e9)
            let frame = window.frame
            scroll.location = CGPoint(x: frame.midX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.midY)
            if let event = NSEvent(cgEvent: scroll) {
                NSApp.postEvent(event, atStart: false)
                posted += 1
            }
        }
        return posted
    }

    /// Runs the application's event loop for `seconds`, counting down in the
    /// window. The timer joins the common modes so it also fires while a
    /// click on the button holds the loop in its tracking mode.
    func run(_ app: NSApplication, seconds: Double) {
        deadline = Date(timeIntervalSinceNow: seconds)
        let timer = Timer(
            timeInterval: ClickSpike.countdownTickSeconds, target: self, selector: #selector(tick(_:)), userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tick(timer)
        app.run()
        timer.invalidate()
    }

    @objc private func tick(_ timer: Timer) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            label.stringValue = "Done"
            NSApp.stop(nil)
            // `stop` takes effect once the loop processes another event.
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0)
            {
                NSApp.postEvent(wake, atStart: true)
            }
            return
        }
        label.stringValue =
            "Click here, on the button and elsewhere; scroll too.\n\(Int(remaining.rounded(.up))) s left"
    }
}
