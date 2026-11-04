import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCapture
import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation
import ImageIO
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

/// Spike S4, window-mode geometry (PLAN M2-06; ARCHITECTURE §9.4): one
/// window captured for a few seconds under each of the three §2 window
/// strategies, through the capture pipeline the session uses
/// (`StreamConfigurationBuilder`, `VideoEncoder`, `RecordingWriter`,
/// `ScreenFrameIndexer`, `InputTelemetryRecorder`, `WindowGeometryPoller`,
/// `FocusMonitor`) into a `.cutscene` package per strategy; prints the
/// output size, the frame counts, the geometry attachments and how often they
/// changed, the poller's and the focus monitor's events, and the file size;
/// then pulls each package through the reader path (`ContentMapper`,
/// `RenderPlan`, `CompositionBuilder`, `MetalCompositor`) and writes PNGs,
/// each with the lit area of the captured surface and the recorded bounding
/// rect at that moment, so menus, popovers, moves and resizes can be seen
/// and measured.
///
/// `window own [seconds]` opens a window of its own and drives it unattended:
/// a popup menu, a popover, a move and a resize at scripted moments, with the
/// content animating throughout so frames keep coming. `window <title>
/// [seconds]` captures another application's window while the lead opens a
/// menu and a popover and drags it (the menu, popover and cursor-on-pointer
/// checks are the lead's eyes on the PNGs). `--strategy <name>` runs one
/// strategy instead of all three; `--out <dir>` and `--no-reader` as named.
///
/// Preflights `CGPreflightScreenCaptureAccess()` and exits 3 without the
/// grant; never prompts (PLAN "Permission rule for spikes"). No audio is
/// captured, so the microphone grant is not needed.
enum WindowSpike {
    static let defaultSeconds = 10.0
    /// Under this the scripted phases overlap.
    static let minimumSeconds = 4.0
    static let pngCount = 8
    static let canvas = CanvasSpec.hd1080p60
    static let windowSize = NSSize(width: 640, height: 400)
    /// The scripted phases, as fractions of the take: when the popup menu
    /// opens and for how long, the popover likewise, then the move and the
    /// resize. Spread so each of the eight PNGs lands in a known phase.
    static let menuAt = 0.3
    static let menuFor = 0.15
    static let popoverAt = 0.5
    static let popoverFor = 0.2
    static let moveAt = 0.72
    static let moveBy = NSPoint(x: 160, y: -120)
    static let resizeAt = 0.85
    static let resizeBy = NSSize(width: 120, height: 80)
    /// The own window repaints a moving block at this rate so a stream of
    /// content frames arrives with nobody at the mouse.
    static let animationInterval = 1.0 / 30
    static let countdownTick = 0.25
    static let popoverSize = NSSize(width: 260, height: 160)
    /// Lit-area probes over the captured surface as the card shows it: a
    /// sample brighter than `litThreshold` on its brightest channel is lit.
    /// A black surface samples at 0; the gradient outside the card never
    /// reaches the probed rect except at the rounded corners.
    static let probeColumns = 96
    static let probeRows = 54
    static let litThreshold = 24
    /// How far apart, in surface points, the lit bounding box and the
    /// recorded bounding rect may lie before the PNG is flagged: the lit box
    /// is on a probe grid of `probeColumns` × `probeRows`, so one cell plus
    /// the window's shadow-free border.
    static let boundingMatchSlackCells = 1.5
    /// Slack on the recorded duration against the requested seconds.
    static let durationTolerance = 0.5
    /// How often, and how long apart, the window listing is retried while
    /// the window to capture is missing from it: a freshly ordered-front
    /// window of ours reaches ScreenCaptureKit's listing within a few
    /// hundred milliseconds.
    static let windowListRetries = 30
    static let windowListRetryInterval = 0.1
    /// How much the lit area must grow, as a fraction of the idle window's,
    /// for a menu or popover phase to count as showing the child window:
    /// the four-item menu adds under five hundredths of the window's area
    /// (measured 4.6 %), the popover a sixth, and the block's motion moves
    /// the lit area by a thousandth.
    static let litGrowthMinimum = 0.02
    /// The zoom-under-crop check: a 2× segment from `zoomCheckStart` for
    /// `zoomCheckSeconds`, long enough for the camera spring to settle, and
    /// how far from the content's centre the settled viewport may rest.
    static let zoomCheckStart = 1.0
    static let zoomCheckSeconds = 4.0
    static let zoomCheckTolerance = 0.01

    // MARK: - Arguments

    private struct Options {
        var target = Target.own
        var seconds = defaultSeconds
        var strategies = CaptureRequest.WindowStrategy.allCases
        var runsReader = true
        /// Record through `CaptureSession` (the app's path) rather than the
        /// hand-wired pipeline, so the session's window path (the manifest's
        /// `WindowSource`, its own poller and focus monitor) is exercised.
        var throughSession = false
        var outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutscene-spike", isDirectory: true)
            .appendingPathComponent("window", isDirectory: true)
    }

    private enum Target: Equatable {
        case own
        case title(String)
    }

    private static let usage = """
        usage: window own [seconds] [--strategy displaySurface|pinnedFrame|independentWindow] [--session] [--out <dir>]
                   [--no-reader]
               window <title> [seconds] [--strategy …] [--session] [--out <dir>] [--no-reader]
        """

    private static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 0
        var sawTarget = false
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--strategy":
                guard index + 1 < arguments.count,
                    let strategy = CaptureRequest.WindowStrategy(rawValue: arguments[index + 1])
                else {
                    print("--strategy needs one of \(CaptureRequest.WindowStrategy.allCases.map(\.rawValue))")
                    return nil
                }
                options.strategies = [strategy]
                index += 2
            case "--out":
                guard index + 1 < arguments.count else {
                    print("--out needs a directory")
                    return nil
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                index += 2
            case "--no-reader":
                options.runsReader = false
                index += 1
            case "--session":
                options.throughSession = true
                index += 1
            default:
                if !sawTarget {
                    options.target = argument.lowercased() == "own" ? .own : .title(argument)
                    sawTarget = true
                } else if let value = Double(argument), value >= minimumSeconds {
                    options.seconds = value
                } else {
                    print("expected a duration of at least \(Int(minimumSeconds)) s, not \(argument)\n\(usage)")
                    return nil
                }
                index += 1
            }
        }
        guard sawTarget else {
            print(usage)
            return nil
        }
        return options
    }

    // MARK: - Entry

    static func run(arguments: [String]) async -> Bool {
        guard let options = parse(arguments) else { return false }
        let permissions = Permissions()
        let screen = permissions.preflight(.screenRecording)
        guard screen == .granted else {
            print(
                "skipped: Screen Recording not granted to this terminal (\(screen.rawValue)). Grant it to the "
                    + "terminal application under System Settings > Privacy & Security > Screen & System Audio "
                    + "Recording (\(Capability.screenRecording.settingsURL)), relaunch the terminal and run again.")
            exit(3)
        }
        let target: String
        switch options.target {
        case .own: target = "the spike's own window"
        case .title(let title): target = "a window titled like \"\(title)\""
        }
        print(
            "window spike: Screen Recording granted; \(options.strategies.map(\.rawValue).joined(separator: ", ")), "
                + "\(format(options.seconds)) s each, target \(target)"
                + (options.throughSession ? ", through CaptureSession" : "")
                + "; output \(options.outputDirectory.path)"
        )
        do {
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
        await stage(options: options, permissions: permissions)
    }

    /// Everything AppKit on the main thread: the application, the own
    /// window when asked for, then the takes, the reader passes and the
    /// verdict as a main-actor task under `NSApplication.run` (platform-notes
    /// "Preview playback": the loop drains the main queue there, and nowhere
    /// else from an async entry point). The task ends the process itself:
    /// `NSApplication.stop` also stops the run loop the async entry point
    /// waits in, after which the runtime exits 0 at once, before anything
    /// printed after the stop reaches stdout and whatever the verdict was
    /// (measured 2026-11-04: the summary never appeared and a failing run
    /// exited 0).
    @MainActor
    private static func stage(options: Options, permissions: Permissions) async -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(options.target == .own ? .regular : .accessory)
        app.finishLaunching()
        app.activate()
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                Task { @MainActor in
                    // Made once the loop runs: a window ordered front
                    // before `finishLaunching` stayed off the active
                    // Space (a full-screen one) and so off screen.
                    let ownWindow: SpikeWindow? = options.target == .own ? SpikeWindow(size: windowSize) : nil
                    ownWindow?.show()
                    var passed = false
                    do {
                        var reports: [TakeReport] = []
                        for strategy in options.strategies {
                            var report = try await take(
                                strategy: strategy, options: options, window: ownWindow, permissions: permissions)
                            if options.runsReader {
                                report.reader = try await read(report, options: options)
                            }
                            reports.append(report)
                            print("")
                        }
                        passed = evaluate(reports, options: options)
                    } catch {
                        print("FAIL: \(error.localizedDescription)")
                    }
                    ownWindow?.close()
                    fflush(stdout)
                    exit(passed ? 0 : 1)
                }
                NSApp.run()
            }
        }
        // The task above exits the process, so this never resumes; unsafe
        // rather than checked, since a continuation meant never to resume
        // is not a leak to report.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        exit(2)
    }

    // MARK: - One take

    struct TakeReport: Sendable {
        var strategy: CaptureRequest.WindowStrategy
        var package: RecordingPackage
        var window: WindowGeometry
        var geometry: CaptureGeometry
        var summary: StreamSummary
        var displayPixelSize: (Int, Int)
        var recordedSeconds: Double
        var frames: ScreenFrameIndexerStatistics
        var encoder: VideoEncoderStatistics
        var writer: RecordingWriterStatistics
        var telemetry: InputTelemetryStatistics
        var poller: WindowGeometryPollerStatistics
        var geometryEvents: [WindowGeometryPoller.Event]
        var focusEvents: [FocusMonitor.Observation]
        var firstFrame: FirstFrame?
        var stopError: String?
        var movieBytes: Int64
        var eventCounts: [String: Int]
        var boundingRange: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
        /// Recording times of the scripted phases (own mode).
        var phases: Phases?
        var reader: ReaderReport?
    }

    struct FirstFrame: Sendable {
        var status: FrameStatus
        var bufferWidth: Int
        var bufferHeight: Int
        var contentRect: PointRect?
        var screenRect: PointRect?
        var boundingRect: PointRect?
        var contentScale: Double?
        var scaleFactor: Double?
        var recordingTime: Double?
    }

    struct Phases: Sendable {
        var menuOpen: ClosedRange<Double>
        var popoverOpen: ClosedRange<Double>
        var movedAt: Double
        var resizedAt: Double

        func label(at time: Double) -> String {
            if menuOpen.contains(time) { return "menu open" }
            if popoverOpen.contains(time) { return "popover open" }
            if time >= resizedAt { return "after resize" }
            if time >= movedAt { return "after move" }
            return "idle"
        }
    }

    @MainActor
    private static func take(
        strategy: CaptureRequest.WindowStrategy, options: Options, window ownWindow: SpikeWindow?,
        permissions: Permissions
    ) async throws -> TakeReport {
        // Back where it started, so every strategy sees the same window
        // and the same scripted move and resize.
        ownWindow?.reset()
        // Our own window reaches the window server a few run-loop turns
        // after `orderFront`, and ScreenCaptureKit's listing a moment after
        // that, so the listing is retried while it is missing.
        var content = try await ShareableContent.current(permissions: permissions)
        var target: SCWindow?
        for attempt in 0..<windowListRetries {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(windowListRetryInterval))
                // Ordered front again from inside the running loop: a window
                // ordered before `finishLaunching` can stay off the active
                // Space (observed with a full-screen Space in front).
                ownWindow?.orderFront()
                content = try await ShareableContent.current(permissions: permissions)
            }
            target = try resolveWindow(
                options.target, ownWindow: ownWindow, content: content, isLastAttempt: attempt == windowListRetries - 1)
            if target != nil { break }
        }
        guard let target else { throw SpikeError.windowNotFound }
        let request = CaptureRequest(source: .window(target.windowID), windowStrategy: strategy, systemAudio: false)
        let built = try StreamConfigurationBuilder.build(request: request, content: content)
        guard let windowGeometry = try StreamConfigurationBuilder.windowGeometry(for: request, content: content) else {
            throw SpikeError.windowNotFound
        }
        let geometry = built.geometry
        let summary = StreamConfigurationBuilder.summary(of: built.configuration)
        let displayBounds = CGDisplayBounds(geometry.displayID)
        let displayPixels = (
            StreamConfigurationBuilder.evenPixels(displayBounds.width * geometry.pointPixelScale),
            StreamConfigurationBuilder.evenPixels(displayBounds.height * geometry.pointPixelScale)
        )
        print(
            "\(strategy.rawValue): window \(target.windowID) \"\(target.title ?? "")\" of "
                + "\(target.owningApplication?.applicationName ?? "?") at \(describe(windowGeometry.frame)) pt on display "
                + "\(geometry.displayID) (\(format(displayBounds.width))×\(format(displayBounds.height)) pt, "
                + "\(geometry.pointPixelScale)×); output \(geometry.outputWidth)×\(geometry.outputHeight) px, capture rect "
                + "\(describe(geometry.captureRectPoints)) pt, sourceRect "
                + "\(geometry.sourceRectPoints.map(describe) ?? "none"); includeChildWindows \(summary.includeChildWindows), "
                + "ignoreShadows display \(summary.ignoreShadowsDisplay) / single \(summary.ignoreShadowsSingleWindow), "
                + "scalesToFit \(summary.scalesToFit), preservesAspectRatio \(summary.preservesAspectRatio), "
                + "filter contentRect \(describe(PointRect(built.filter.contentRect))) at \(built.filter.pointPixelScale)×"
        )

        if options.throughSession {
            return try await sessionTake(
                strategy: strategy, request: request, target: target, windowGeometry: windowGeometry,
                geometry: geometry, summary: summary, displayPixels: displayPixels, options: options,
                window: ownWindow, permissions: permissions)
        }

        // The package and the pipeline, as the session wires them.
        let createdAt = Date()
        let label = "\(target.owningApplication?.applicationName ?? "Window") \(strategy.rawValue)"
        let package = try RecordingPackage.create(
            at: RecordingPackage.availableURL(
                for: options.outputDirectory.appendingPathComponent(
                    RecordingPackage.name(createdAt: createdAt, label: label))))
        let recordingID = UUID()
        let clock = RecordingClock.unstarted()
        let writer = try RecordingWriter(
            movieURL: package.screenFragmentedMovieURL, clock: clock, configuration: RecordingWriterConfiguration())
        let indexer = try ScreenFrameIndexer(url: package.frameIndexURL, recordingID: recordingID, clock: clock)
        let encoder = try VideoEncoder(
            configuration: VideoEncoderConfiguration(
                width: geometry.outputWidth, height: geometry.outputHeight, frameRate: request.frameRate,
                quality: request.tier),
            clock: clock
        ) { sample in
            let dropped = writer.statistics.videoDroppedNotReady
            writer.appendVideo(sample)
            if writer.statistics.videoDroppedNotReady > dropped {
                indexer.recordGap(at: sample.presentationTimeStamp.seconds)
            }
        }
        let telemetry = InputTelemetryRecorder(
            displayBounds: displayBounds, captureRectPoints: geometry.captureRectPoints, displayID: geometry.displayID,
            pointPixelScale: geometry.pointPixelScale, recordingID: recordingID, persistenceURL: package.eventsURL)
        let geometryEvents = Collector<WindowGeometryPoller.Event>()
        let poller = WindowGeometryPoller(scope: .window(target.windowID), displayBounds: displayBounds) {
            geometryEvents.add($0)
        }
        let focusEvents = Collector<FocusMonitor.Observation>()
        let focus = FocusMonitor { focusEvents.add($0) }
        let shim = SpikeStreamOutput(clock: clock, encoder: encoder, indexer: indexer)
        let queue = DispatchQueue(label: "app.cutscene.spike.window", qos: .userInitiated)
        let stream = SCStream(filter: built.filter, configuration: built.configuration, delegate: shim)
        try stream.addStreamOutput(shim, type: .screen, sampleHandlerQueue: queue)
        var manifest = RecordingManifest(
            recordingID: recordingID, createdAt: createdAt, source: built.source,
            content: ContentGeometry(
                displayID: geometry.displayID, displayBoundsPoints: PointRect(displayBounds),
                captureRectPoints: geometry.captureRectPoints, pointPixelScale: geometry.pointPixelScale),
            screen: ScreenTrackInfo(
                width: geometry.outputWidth, height: geometry.outputHeight, frameRate: request.frameRate,
                codec: encoder.codec.rawValue),
            state: .inProgress)
        try package.writeManifest(manifest)
        let store = ProjectStore(package: package)
        try store.save(Project(recording: manifest))

        clock.start()
        telemetry.start(clock: clock)
        poller.start()
        if let current = FocusMonitor.current() { focusEvents.add(current) }
        let started = ContinuousClock.now
        try await stream.startCapture()
        print(
            "  recording \(package.url.lastPathComponent) (\(encoder.codec.rawValue)); stream started "
                + "\(milliseconds(elapsed(since: started))) after the origin")
        var phases: Phases?
        if let ownWindow {
            ownWindow.setStatus("\(strategy.rawValue): recording")
            phases = try await script(ownWindow, seconds: options.seconds, clock: clock)
        } else {
            print(
                "  GO: \(format(options.seconds)) s; open a menu and a popover in the window, drag it, resize it, "
                    + "move the pointer over it")
            fflush(stdout)
            try await Task.sleep(for: .seconds(options.seconds))
        }

        clock.stop()
        let recorded = clock.elapsed.seconds
        do {
            try await stream.stopCapture()
        } catch {
            print("  note: stopCapture threw: \(error.localizedDescription)")
        }
        poller.stop()
        focus.stop()
        var log = telemetry.stop()
        try encoder.finish()
        let movieURL = try await writer.finish()
        indexer.close()
        ownWindow?.setStatus("\(strategy.rawValue): finishing")

        // The format-2 rows the recorder does not write itself: the focus
        // changes and the window geometry, merged into the log in time order.
        let geometryRows = geometryEvents.snapshot().compactMap { $0.inputEvent(clock: clock) }
        let focusRows = focusEvents.snapshot().compactMap { $0.inputEvent(clock: clock) }
        log.append(contentsOf: geometryRows + focusRows)
        try log.write(to: package.eventsURL)
        for (id, png) in telemetry.sprites() {
            try png.write(to: package.cursorSpriteURL(shapeID: id), options: .atomic)
        }
        manifest.state = .complete
        manifest.stopReason = .userStopped
        manifest.duration = recorded
        try package.writeManifest(manifest)
        try store.save(Project(recording: manifest))

        let index = try package.frameIndex()
        var eventCounts: [String: Int] = [:]
        for event in log.events { eventCounts[kind(of: event), default: 0] += 1 }
        let movieBytes = (try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? Int64) ?? 0
        let report = TakeReport(
            strategy: strategy, package: package, window: windowGeometry, geometry: geometry, summary: summary,
            displayPixelSize: displayPixels, recordedSeconds: recorded, frames: indexer.statistics,
            encoder: encoder.statistics, writer: writer.statistics, telemetry: telemetry.statistics,
            poller: poller.statistics, geometryEvents: geometryEvents.snapshot(), focusEvents: focusEvents.snapshot(),
            firstFrame: shim.firstFrame, stopError: shim.stopError, movieBytes: movieBytes, eventCounts: eventCounts,
            boundingRange: boundingRange(of: index), phases: phases)
        printTake(report)
        return report
    }

    /// The same take through `CaptureSession`, the app's path: the session
    /// builds the pipeline, resolves the manifest's `WindowSource`, runs its
    /// own geometry poller and focus monitor and writes their rows into
    /// `events.json`, which the verdict then counts like the hand-wired
    /// take's. The scripted phases are timed on a clock of the spike's own
    /// started when `start` returns, within the stream's start latency of
    /// the session's origin.
    @MainActor
    private static func sessionTake(
        strategy: CaptureRequest.WindowStrategy, request: CaptureRequest, target: SCWindow,
        windowGeometry: WindowGeometry, geometry: CaptureGeometry, summary: StreamSummary,
        displayPixels: (Int, Int), options: Options, window ownWindow: SpikeWindow?, permissions: Permissions
    ) async throws -> TakeReport {
        let label = "\(target.owningApplication?.applicationName ?? "Window") \(strategy.rawValue) session"
        let package = RecordingPackage(
            url: RecordingPackage.availableURL(
                for: options.outputDirectory.appendingPathComponent(
                    RecordingPackage.name(createdAt: Date(), label: label))))
        let session = CaptureSession(permissions: permissions)
        let statuses = try await session.start(request: request, package: package)
        let clock = RecordingClock.unstarted()
        clock.start()
        let printer = Task {
            for await status in statuses {
                if case .failed(let reason, let message) = status.phase {
                    print("  session failed: \(reason.rawValue), \(message)")
                }
            }
        }
        print("  recording \(package.url.lastPathComponent) through CaptureSession")
        var phases: Phases?
        if let ownWindow {
            ownWindow.setStatus("\(strategy.rawValue): recording (session)")
            phases = try await script(ownWindow, seconds: options.seconds, clock: clock)
        } else {
            print(
                "  GO: \(format(options.seconds)) s; open a menu and a popover in the window, drag it, resize it, "
                    + "move the pointer over it")
            fflush(stdout)
            try await Task.sleep(for: .seconds(options.seconds))
        }
        let manifest = try await session.stop()
        await printer.value
        let statistics = await session.statistics
        ownWindow?.setStatus("\(strategy.rawValue): finishing")
        for warning in statistics.warnings { print("  warning: \(warning)") }
        print(
            "  session: \(manifest.state.rawValue) (\(manifest.stopReason?.rawValue ?? "no reason")), "
                + "\(format(manifest.duration ?? 0)) s; manifest source "
                + {
                    if case .window(let source) = manifest.source {
                        return "window \(source.windowID) \"\(source.title ?? "")\" \(source.bundleID) at "
                            + "\(describe(source.frame)) pt, \(source.strategy.rawValue)"
                    }
                    return "\(manifest.source)"
                }())

        let log = try package.eventLog()
        let index = try package.frameIndex()
        var eventCounts: [String: Int] = [:]
        var geometryEvents: [WindowGeometryPoller.Event] = []
        var focusEvents: [FocusMonitor.Observation] = []
        for event in log.events {
            eventCounts[kind(of: event), default: 0] += 1
            let hostTime = CMTime(
                seconds: event.time + log.startHostTimeSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            switch event {
            case .geometry(_, let windowID, let frame):
                geometryEvents.append(
                    Event(
                        hostTime: hostTime, windowID: windowID, frame: frame, ownerPID: 0,
                        isFirstSighting: geometryEvents.isEmpty))
            case .focus(_, let bundleID, let windowID):
                focusEvents.append(
                    FocusMonitor.Observation(hostTime: hostTime, bundleID: bundleID, processID: 0, windowID: windowID))
            default:
                break
            }
        }
        let movieBytes =
            (try? FileManager.default.attributesOfItem(atPath: package.screenMovieURL.path)[.size] as? Int64) ?? 0
        var stopError: String?
        switch manifest.source {
        case .window(let source) where source.windowID != target.windowID:
            stopError = "the manifest names window \(source.windowID), not \(target.windowID)"
        case .window:
            break
        case .display, .area:
            stopError = "the manifest's source is \(manifest.source), not the window"
        }
        if manifest.state != .complete {
            stopError = "the session ended \(manifest.state.rawValue) (\(manifest.stopReason?.rawValue ?? "no reason"))"
        }
        let report = TakeReport(
            strategy: strategy, package: package, window: windowGeometry, geometry: geometry, summary: summary,
            displayPixelSize: displayPixels, recordedSeconds: manifest.duration ?? 0, frames: statistics.frames,
            encoder: statistics.encoder, writer: statistics.writer, telemetry: statistics.telemetry,
            poller: statistics.geometry, geometryEvents: geometryEvents, focusEvents: focusEvents, firstFrame: nil,
            stopError: stopError, movieBytes: movieBytes, eventCounts: eventCounts,
            boundingRange: boundingRange(of: index), phases: phases)
        printTake(report)
        return report
    }

    private typealias Event = WindowGeometryPoller.Event

    /// The window to capture: our own, or the frontmost on-screen window
    /// whose title contains `title`.
    @MainActor
    private static func resolveWindow(
        _ target: Target, ownWindow: SpikeWindow?, content: ShareableContent, isLastAttempt: Bool
    ) throws -> SCWindow? {
        switch target {
        case .own:
            guard let ownWindow else { throw SpikeError.windowNotFound }
            let id = CGWindowID(ownWindow.windowNumber)
            guard let window = content.window(id: id) else {
                guard isLastAttempt else { return nil }
                let ours = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier }
                print(
                    "ScreenCaptureKit does not list our window \(id); it lists \(content.windows.count) windows; the "
                        + "window server has it \(WindowGeometryPoller.bounds(ofWindow: id).map { "at \($0)" } ?? "not on screen")"
                        + "; NSWindow visible \(ownWindow.window.isVisible), on active space \(ownWindow.window.isOnActiveSpace), "
                        + "occlusion \(ownWindow.window.occlusionState.rawValue); window list rows of ours: \(ours); "
                        + "session \(CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]); on screen: "
                        + content.windows.map {
                            "\($0.owningApplication?.applicationName ?? "?") \"\($0.title ?? "")\""
                        }
                        .joined(separator: ", "))
                throw SpikeError.windowNotFound
            }
            return window
        case .title(let title):
            let matches = content.windows.filter {
                $0.isOnScreen && $0.windowLayer == 0 && ($0.title ?? "").localizedCaseInsensitiveContains(title)
            }
            guard let first = matches.first else {
                guard isLastAttempt else { return nil }
                print("no on-screen window has a title containing \"\(title)\"; candidates:")
                for window in content.windows where window.windowLayer == 0 && window.isOnScreen {
                    print(
                        "  \(window.windowID)  \(window.owningApplication?.applicationName ?? "?")  "
                            + "\"\(window.title ?? "")\"  \(describe(PointRect(window.frame)))")
                }
                throw SpikeError.windowNotFound
            }
            if matches.count > 1 {
                print(
                    "  \(matches.count) windows match; taking the frontmost, \(first.windowID) "
                        + "\"\(first.title ?? "")\"")
            }
            return first
        }
    }

    /// Drives the own window through the scripted phases and returns their
    /// recording times. The popup menu blocks the main thread while it
    /// tracks, so the timer that closes it runs in the common modes.
    @MainActor
    private static func script(_ window: SpikeWindow, seconds: Double, clock: RecordingClock) async throws -> Phases {
        func now() -> Double { clock.elapsed.seconds }
        func sleep(until fraction: Double) async throws {
            let remaining = fraction * seconds - now()
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
        try await sleep(until: menuAt)
        let menuOpened = now()
        window.setStatus("menu open")
        window.openMenu(for: menuFor * seconds)
        let menuClosed = now()
        try await sleep(until: popoverAt)
        let popoverOpened = now()
        window.setStatus("popover open")
        window.showPopover()
        try await sleep(until: popoverAt + popoverFor)
        window.closePopover()
        let popoverClosed = now()
        try await sleep(until: moveAt)
        window.move(by: moveBy)
        let movedAt = now()
        window.setStatus("moved")
        try await sleep(until: resizeAt)
        window.resize(by: resizeBy)
        let resizedAt = now()
        window.setStatus("resized")
        try await sleep(until: 1)
        print(
            "  scripted: menu \(format(menuOpened))–\(format(menuClosed)) s, popover \(format(popoverOpened))–"
                + "\(format(popoverClosed)) s, moved at \(format(movedAt)) s, resized at \(format(resizedAt)) s")
        return Phases(
            menuOpen: menuOpened...menuClosed, popoverOpen: popoverOpened...popoverClosed, movedAt: movedAt,
            resizedAt: resizedAt)
    }

    private static func boundingRange(of index: FrameIndex) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)?
    {
        var range: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
        for frame in index.frames() {
            guard let rect = frame.boundingRect else { continue }
            if var current = range {
                current.minX = min(current.minX, rect.x)
                current.minY = min(current.minY, rect.y)
                current.maxX = max(current.maxX, rect.x + rect.width)
                current.maxY = max(current.maxY, rect.y + rect.height)
                range = current
            } else {
                range = (rect.x, rect.y, rect.x + rect.width, rect.y + rect.height)
            }
        }
        return range
    }

    private static func printTake(_ r: TakeReport) {
        let f = r.frames
        print(
            "  recorded \(format(r.recordedSeconds)) s: \(f.samples) samples, \(f.contentFrames) content "
                + "(\(f.startedFrames) started), \(f.idleFrames) idle, \(f.blankFrames) blank, \(f.suspendedFrames) suspended, "
                + "\(f.stoppedFrames) stopped, \(f.otherFrames) other, \(f.outsideRecording) outside; first content at "
                + "\(f.firstContentTime.map(format) ?? "never") s; encoder \(r.encoder.encodedFrames) encoded / "
                + "\(r.encoder.droppedFrames) dropped; writer \(r.writer.videoFrames) frames, \(f.gaps) gaps"
                + (r.stopError.map { "; stream stopped itself: \($0)" } ?? ""))
        print(
            "  movie \(r.movieBytes / 1024) KiB = \(String(format: "%.0f", Double(r.movieBytes) * 8 / 1000 / max(r.recordedSeconds, 0.001))) kbit/s "
                + "at \(r.geometry.outputWidth)×\(r.geometry.outputHeight) px")
        if let first = r.firstFrame {
            print(
                "  first frame: \(first.status.rawValue) at \(first.recordingTime.map(format) ?? "?") s, buffer "
                    + "\(first.bufferWidth)×\(first.bufferHeight) px, contentRect \(first.contentRect.map(describe) ?? "none"), "
                    + "screenRect \(first.screenRect.map(describe) ?? "none"), boundingRect "
                    + "\(first.boundingRect.map(describe) ?? "none"), contentScale \(first.contentScale.map(format) ?? "none"), "
                    + "scaleFactor \(first.scaleFactor.map(format) ?? "none")")
        }
        print(
            "  geometry attachments: contentRect on \(f.samplesWithContentRect) samples, \(f.contentRectChanges) changes "
                + "(last \(f.lastContentRect.map(describe) ?? "none")); screenRect on \(f.samplesWithScreenRect), "
                + "\(f.screenRectChanges) changes (last \(f.lastScreenRect.map(describe) ?? "none")); boundingRect on "
                + "\(f.samplesWithBoundingRect), \(f.boundingRectChanges) changes (last "
                + "\(f.lastBoundingRect.map(describe) ?? "none"))"
                + (r.boundingRange.map {
                    "; bounding rect spanned x \(format($0.minX))–\(format($0.maxX)), y \(format($0.minY))–\(format($0.maxY)) pt"
                } ?? ""))
        let p = r.poller
        let costs = p.pollCostsSeconds.sorted()
        print(
            "  geometry poll: \(p.ticks) ticks at \(format(1 / max(Double(p.ticks) / max(r.recordedSeconds, 0.001), 0.001))) s, "
                + "\(p.events) events for \(p.windowsSeen) window(s), watched window missing on \(p.watchedWindowMissing) ticks; "
                + "list cost median \(milliseconds(median(costs))), max \(milliseconds(costs.last ?? 0)); frames: "
                + r.geometryEvents.map {
                    "\(format($0.hostTime.seconds - r.geometryEvents.first!.hostTime.seconds)) s \(describe($0.frame))"
                }
                .joined(separator: " → "))
        print(
            "  focus: \(r.focusEvents.count) observations "
                + r.focusEvents.map { "\($0.bundleID)\($0.windowID.map { " #\($0)" } ?? "")" }.joined(separator: ", "))
        let t = r.telemetry
        print(
            "  telemetry: \(t.samplerTicks) ticks at \(String(format: "%.1f", t.measuredSamplingRateHz)) Hz, monitors "
                + "\(t.clickMonitorsActive ? "on" : "off"), tap \(t.eventTapActive ? "on" : "off"); events.json: "
                + r.eventCounts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
    }

    // MARK: - Reader pass

    struct ReaderReport: Sendable {
        var pngs: [PNGReport]
        var frames: Int
        var expectedFrames: Int
        var requests: Int
        var medianLatencyMilliseconds: Double
        var cropSamples: Int
        /// Whether a 2× zoom aimed at the window's centre, planned over the
        /// take's own crop timeline, put the viewport at the centre of the
        /// content (the plan is made in content space, PLAN review 2026-11-04).
        var zoomCentred: Bool
        var zoomViewport: Viewport
    }

    struct PNGReport: Sendable {
        var name: String
        var time: Double
        var phase: String
        /// Lit share of the content the card shows (the mapper's crop).
        var litFraction: Double
        /// The lit area in surface points squared: the share times the
        /// crop's area, comparable across PNGs whatever the crop did.
        var litPoints: Double
        /// Lit bounding box in surface points, from the probe grid.
        var litBox: PointRect?
        var recordedBounding: PointRect?
        var crop: Viewport
        var zoom: Double
    }

    /// Pulls the package through the composition path at 1080p60 and writes
    /// `pngCount` PNGs, each probed for the lit area of the content the card
    /// shows. The plan carries the mapper's crop and no zoom segments, so
    /// what the card shows at a time is the crop and nothing else, and the
    /// probe grid maps back to surface points through it.
    private static func read(_ take: TakeReport, options: Options) async throws -> ReaderReport {
        let package = take.package
        let directory = options.outputDirectory.appendingPathComponent(
            package.url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = try package.manifest()
        let log = try package.eventLog()
        let index = try package.frameIndex()
        let duration = manifest.duration ?? take.recordedSeconds
        let crop = ContentMapper().cropTimeline(manifest: manifest, index: index, duration: duration)
        // An empty zoom track: a click during the take (the lead's, or a
        // scripted one) would otherwise zoom the card and the probes would
        // measure the zoom, not the window.
        let plan = RenderPlan.build(log: log, duration: duration, zoomTrack: ZoomTrack(), contentCrop: crop)
        let atlas = CursorAtlas.load(for: plan, in: package)
        var style = RenderStyle()
        style.outputWidth = canvas.width
        style.outputHeight = canvas.height
        let composition = try await CompositionBuilder.build(
            package: package, keptRanges: [0...duration], plan: plan, style: style, cursor: atlas, canvas: canvas)
        let expected = composition.expectedFrameCount
        let frames = index.frames()

        // The card: the crop of the moment is aspect-fitted inside it.
        let padding = style.padding * Double(min(canvas.width, canvas.height))
        let card = CGRect(
            x: padding, y: padding, width: Double(canvas.width) - 2 * padding,
            height: Double(canvas.height) - 2 * padding)
        let surfacePoints = take.geometry.captureRectPoints

        let reader = try AVAssetReader(asset: composition.composition)
        let videoTracks = try await composition.composition.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpikeError.reader("the reader refused the output") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpikeError.reader("startReading failed") }
        let compositor = output.customVideoCompositor as? MetalCompositor
        var count = 0
        var pngs: [PNGReport] = []
        let step = max(expected / pngCount, 1)
        let offset = step / 2
        while let sample = output.copyNextSampleBuffer() {
            defer { count += 1 }
            guard (count - offset) % step == 0, (count - offset) >= 0, pngs.count < pngCount,
                let buffer = CMSampleBufferGetImageBuffer(sample)
            else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let name = String(format: "frame-%02d.png", pngs.count)
            try writePNG(buffer, to: directory.appendingPathComponent(name))
            let recorded = frames.last { $0.time <= time }?.boundingRect
            let state = plan.frameState(at: time)
            let shown = state.contentCrop
            let contentPoints = PointRect(
                x: shown.origin.x * surfacePoints.width, y: shown.origin.y * surfacePoints.height,
                width: shown.size.width * surfacePoints.width, height: shown.size.height * surfacePoints.height)
            let lit = try litArea(
                of: buffer, in: fitted(CGSize(width: contentPoints.width, height: contentPoints.height), in: card),
                contentPoints: contentPoints)
            pngs.append(
                PNGReport(
                    name: name, time: time, phase: take.phases?.label(at: time) ?? "human", litFraction: lit.fraction,
                    litPoints: lit.fraction * contentPoints.width * contentPoints.height, litBox: lit.box,
                    recordedBounding: recorded, crop: shown, zoom: 1 / max(state.viewport.size.width, 1e-9)))
        }
        guard reader.status == .completed else {
            throw reader.error ?? SpikeError.reader("status \(reader.status.rawValue)")
        }
        compositor?.flush()
        let latencies = compositor?.requestLatencies.sorted() ?? []
        print(
            "  reader: \(count) frames (\(expected) expected) at \(canvas.width)×\(canvas.height), "
                + "\(compositor?.statistics.requests ?? 0) requests, latency median \(milliseconds(median(latencies))); "
                + "crop timeline \(crop.samples.count) samples; PNGs in \(directory.path)")

        // The zoom under the crop: a manual 2× segment aimed at the window's
        // centre (frame coordinates, as the editor aims one) over the take's
        // own crop timeline, on a log whose pointer rests at that centre, so
        // the viewport must come to rest on the centre of the content. The
        // probes above keep their empty zoom track.
        let zoomEnd = min(duration, zoomCheckStart + zoomCheckSeconds)
        let zoomCrop = crop.crop(at: zoomCheckStart)
        let centre = NormalizedPoint(
            x: zoomCrop.origin.x + zoomCrop.size.width / 2, y: zoomCrop.origin.y + zoomCrop.size.height / 2)
        var resting = log
        resting.removeAllEvents()
        resting.append(
            contentsOf: log.events.filter { $0.position == nil } + [.pointerMoved(time: 0, position: centre)])
        var track = ZoomTrack()
        track.segments = [
            ZoomTrackSegment(start: zoomCheckStart, end: zoomEnd, focus: centre, amount: 2, source: .manual)
        ]
        let zoomPlan = RenderPlan.build(log: resting, duration: duration, zoomTrack: track, contentCrop: crop)
        let viewport = zoomPlan.frameState(at: zoomEnd).viewport
        let zoomCentred =
            abs(viewport.origin.x + viewport.size.width / 2 - 0.5) <= zoomCheckTolerance
            && abs(viewport.origin.y + viewport.size.height / 2 - 0.5) <= zoomCheckTolerance
            && abs(viewport.size.width - 0.5) <= zoomCheckTolerance
        print(
            "  zoom under the crop: 2× at the window centre (frame \(String(format: "%.3f", centre.x)), "
                + "\(String(format: "%.3f", centre.y))) from \(format(zoomCheckStart)) s: viewport at "
                + "\(format(zoomEnd)) s origin (\(String(format: "%.3f", viewport.origin.x)), "
                + "\(String(format: "%.3f", viewport.origin.y))) size \(String(format: "%.3f", viewport.size.width))×"
                + "\(String(format: "%.3f", viewport.size.height)) → \(zoomCentred ? "centred on the content" : "OFF CENTRE")"
        )
        for png in pngs {
            print(
                "  \(png.name)  t \(format(png.time)) s  \(png.phase.padding(toLength: 13, withPad: " ", startingAt: 0))"
                    + "lit \(String(format: "%5.1f", png.litFraction * 100)) % = \(String(format: "%7.0f", png.litPoints)) pt², "
                    + "lit box \(png.litBox.map(describe) ?? "none") pt"
                    + "  recorded boundingRect \(png.recordedBounding.map(describe) ?? "none")  crop "
                    + "(\(String(format: "%.3f", png.crop.origin.x)), \(String(format: "%.3f", png.crop.origin.y)) "
                    + "\(String(format: "%.3f", png.crop.size.width))×\(String(format: "%.3f", png.crop.size.height)))"
                    + (png.zoom > 1.001 ? "  zoom \(String(format: "%.2f", png.zoom))×" : ""))
        }
        return ReaderReport(
            pngs: pngs, frames: count, expectedFrames: expected, requests: compositor?.statistics.requests ?? 0,
            medianLatencyMilliseconds: median(latencies) * 1000, cropSamples: crop.samples.count,
            zoomCentred: zoomCentred, zoomViewport: viewport)
    }

    /// `size` aspect-fitted and centred in `rect`.
    private static func fitted(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// Probes a grid over `shown` (the cropped content as drawn on the
    /// canvas, which covers `contentPoints` of the surface) and returns the
    /// lit fraction and the lit bounding box in surface points.
    private static func litArea(of buffer: CVPixelBuffer, in shown: CGRect, contentPoints: PointRect) throws
        -> (fraction: Double, box: PointRect?)
    {
        let surface = shown
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var lit = 0
        var minColumn = Int.max
        var maxColumn = -1
        var minRow = Int.max
        var maxRow = -1
        for row in 0..<probeRows {
            for column in 0..<probeColumns {
                let x = Int(surface.minX + surface.width * (Double(column) + 0.5) / Double(probeColumns))
                let y = Int(surface.minY + surface.height * (Double(row) + 0.5) / Double(probeRows))
                let pixel = base.advanced(by: min(max(y, 0), height - 1) * bytesPerRow + min(max(x, 0), width - 1) * 4)
                    .assumingMemoryBound(to: UInt8.self)
                guard max(pixel[0], pixel[1], pixel[2]) >= UInt8(litThreshold) else { continue }
                lit += 1
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        let fraction = Double(lit) / Double(probeRows * probeColumns)
        guard lit > 0 else { return (fraction, nil) }
        let cellWidth = contentPoints.width / Double(probeColumns)
        let cellHeight = contentPoints.height / Double(probeRows)
        return (
            fraction,
            PointRect(
                x: contentPoints.x + Double(minColumn) * cellWidth, y: contentPoints.y + Double(minRow) * cellHeight,
                width: Double(maxColumn - minColumn + 1) * cellWidth, height: Double(maxRow - minRow + 1) * cellHeight)
        )
    }

    private static func writePNG(_ buffer: CVPixelBuffer, to url: URL) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            for row in 0..<height {
                raw.baseAddress!.advanced(by: row * width * 4)
                    .copyMemory(from: base.advanced(by: row * bytesPerRow), byteCount: width * 4)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SpikeError.png(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpikeError.png(url.lastPathComponent) }
    }

    // MARK: - Verdict

    private static func evaluate(_ reports: [TakeReport], options: Options) -> Bool {
        var failures: [String] = []
        var notes: [String] = []
        let scale = reports.first?.geometry.pointPixelScale ?? 1
        print("summary:")
        for r in reports {
            let name = r.strategy.rawValue
            print(
                "  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(r.geometry.outputWidth)×\(r.geometry.outputHeight) px  "
                    + "\(String(format: "%6d", r.movieBytes / 1024)) KiB  \(String(format: "%3d", r.frames.contentFrames)) content frames  "
                    + "boundingRect \(r.frames.samplesWithBoundingRect > 0 ? "yes" : "no") (\(r.frames.boundingRectChanges) changes)  "
                    + "poll events \(r.poller.events)  focus \(r.focusEvents.count)")
            if r.frames.contentFrames == 0 { failures.append("\(name): no content frame") }
            if r.frames.writeFailures > 0 { failures.append("\(name): frame index write failures") }
            if r.writer.videoDroppedBeforeKeyframe + r.writer.videoDroppedNonIncreasing > 0 {
                failures.append("\(name): the writer refused video")
            }
            if abs(r.recordedSeconds - options.seconds) > durationTolerance {
                failures.append("\(name): recorded \(format(r.recordedSeconds)) s of \(format(options.seconds))")
            }
            if let error = r.stopError { failures.append("\(name): the stream stopped itself: \(error)") }
            if let first = r.firstFrame,
                first.bufferWidth != r.geometry.outputWidth || first.bufferHeight != r.geometry.outputHeight
            {
                failures.append(
                    "\(name): buffers are \(first.bufferWidth)×\(first.bufferHeight), configured "
                        + "\(r.geometry.outputWidth)×\(r.geometry.outputHeight)")
            }
            let frame = r.window.frame
            switch r.strategy {
            case .displaySurface:
                if (r.geometry.outputWidth, r.geometry.outputHeight) != r.displayPixelSize {
                    failures.append("\(name): output is not the display's \(r.displayPixelSize)")
                }
                if r.frames.samplesWithBoundingRect == 0 {
                    failures.append("\(name): no sample carried a boundingRect, so the crop has nothing to follow")
                }
            case .pinnedFrame, .independentWindow:
                let expected = (
                    StreamConfigurationBuilder.evenPixels(frame.width * scale),
                    StreamConfigurationBuilder.evenPixels(frame.height * scale)
                )
                if (r.geometry.outputWidth, r.geometry.outputHeight) != expected {
                    failures.append(
                        "\(name): output \(r.geometry.outputWidth)×\(r.geometry.outputHeight) is not \(expected)")
                }
            }
            if r.focusEvents.isEmpty { failures.append("\(name): no focus observation (not even the initial one)") }
            if r.eventCounts["geometry"] ?? 0 == 0 { failures.append("\(name): no geometry event reached events.json") }
            if r.eventCounts["focus"] ?? 0 == 0 { failures.append("\(name): no focus event reached events.json") }
            if options.runsReader {
                guard let reader = r.reader else {
                    failures.append("\(name): no reader pass")
                    continue
                }
                if reader.pngs.count < pngCount { failures.append("\(name): \(reader.pngs.count) PNGs") }
                if abs(reader.frames - reader.expectedFrames) > 1 {
                    failures.append("\(name): read \(reader.frames) frames, expected \(reader.expectedFrames)")
                }
                if !reader.zoomCentred {
                    failures.append(
                        "\(name): a 2× zoom at the window's centre left the viewport at \(reader.zoomViewport)")
                }
            }
            if r.phases != nil {
                // Unattended findings from the scripted phases.
                if r.poller.events < 3 {
                    failures.append("\(name): the poll saw \(r.poller.events) geometry events for a move and a resize")
                }
                if r.strategy == .displaySurface, r.frames.boundingRectChanges < 3 {
                    failures.append(
                        "\(name): boundingRect changed \(r.frames.boundingRectChanges) times through a move and a resize"
                    )
                }
                if let reader = r.reader {
                    let idle = reader.pngs.filter { $0.phase == "idle" }.map(\.litPoints).max() ?? 0
                    for phase in ["menu open", "popover open"] {
                        let during = reader.pngs.filter { $0.phase == phase }.map(\.litPoints).max()
                        guard let during else {
                            notes.append("\(name): no PNG fell in the \(phase) phase")
                            continue
                        }
                        let grew = during >= idle * (1 + litGrowthMinimum)
                        notes.append(
                            "\(name): lit area \(String(format: "%.0f", idle)) pt² idle → "
                                + "\(String(format: "%.0f", during)) pt² with the \(phase): child window "
                                + (grew ? "visible" : "NOT visible"))
                    }
                    for png in reader.pngs where png.phase == "after move" || png.phase == "after resize" {
                        notes.append(
                            "\(name): \(png.name) \(png.phase): lit box \(png.litBox.map(describe) ?? "none"), recorded "
                                + "boundingRect \(png.recordedBounding.map(describe) ?? "none")")
                    }
                }
            }
        }
        for note in notes { print("note: \(note)") }
        if !failures.isEmpty {
            print("FAIL: " + failures.joined(separator: "; "))
            return false
        }
        if options.target != .own {
            print("INCONCLUSIVE: the pipeline ran; the menu, popover and cursor checks are the lead's, on the PNGs")
        } else {
            print("PASS")
        }
        return true
    }

    // MARK: - Stream output

    /// The stream's screen output: every sample is indexed and, when it
    /// carries content, encoded, on the sample queue, as the session's shim
    /// does; the first content frame's facts are kept for the report.
    private final class SpikeStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
        private struct State {
            var firstFrame: FirstFrame?
            var stopError: String?
        }

        private let clock: RecordingClock
        private let encoder: VideoEncoder
        private let indexer: ScreenFrameIndexer
        private let state = Mutex(State())

        init(clock: RecordingClock, encoder: VideoEncoder, indexer: ScreenFrameIndexer) {
            self.clock = clock
            self.encoder = encoder
            self.indexer = indexer
            super.init()
        }

        var firstFrame: FirstFrame? { state.withLock { $0.firstFrame } }
        var stopError: String? { state.withLock { $0.stopError } }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
        {
            guard type == .screen else { return }
            let info = ScreenFrameInfo(sampleBuffer: sampleBuffer)
            let hostTime = sampleBuffer.presentationTimeStamp
            let time = indexer.record(info, presentationHostTime: hostTime)
            guard info.carriesContent, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            state.withLock { state in
                guard state.firstFrame == nil else { return }
                state.firstFrame = FirstFrame(
                    status: info.status, bufferWidth: CVPixelBufferGetWidth(pixelBuffer),
                    bufferHeight: CVPixelBufferGetHeight(pixelBuffer), contentRect: info.contentRect,
                    screenRect: info.screenRect, boundingRect: info.boundingRect, contentScale: info.contentScale,
                    scaleFactor: info.scaleFactor, recordingTime: time)
            }
            try? encoder.encode(pixelBuffer, hostTime: hostTime)
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            state.withLock { $0.stopError = error.localizedDescription }
        }
    }

    // MARK: - Helpers

    enum SpikeError: LocalizedError {
        case windowNotFound
        case reader(String)
        case pixelBuffer
        case png(String)

        var errorDescription: String? {
            switch self {
            case .windowNotFound: "The window to capture was not found."
            case .reader(let detail): "The asset reader failed: \(detail)."
            case .pixelBuffer: "A frame's pixel buffer could not be read."
            case .png(let name): "Could not write \(name)."
            }
        }
    }

    private static func kind(of event: InputEvent) -> String {
        switch event {
        case .pointerMoved: "pointerMoved"
        case .buttonDown: "buttonDown"
        case .buttonUp: "buttonUp"
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .cursorShapeChanged: "cursorShapeChanged"
        case .takeMarker: "takeMarker"
        case .scroll: "scroll"
        case .focus: "focus"
        case .geometry: "geometry"
        case .unknown(let kind, _): "unknown(\(kind))"
        }
    }

    private static func describe(_ rect: PointRect) -> String {
        "(\(format(rect.x)), \(format(rect.y)) \(format(rect.width))×\(format(rect.height)))"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.2f ms", seconds * 1000)
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Values collected from a handler on any thread, read once the take ends.
private final class Collector<Element: Sendable>: Sendable {
    private let values = Mutex<[Element]>([])

    func add(_ value: Element) {
        values.withLock { $0.append(value) }
    }

    func snapshot() -> [Element] {
        values.withLock { $0 }
    }
}

// MARK: - The own window

/// The window the spike captures when told `own`: animated content so
/// frames keep coming, a popup menu and a popover it can open by script or
/// the lead by button, and a status line.
@MainActor
private final class SpikeWindow: NSObject {
    let window: NSWindow
    private let content: AnimatedView
    private let menuButton: NSButton
    private let popoverButton: NSButton
    private let menu = NSMenu(title: "Spike")
    private var popover: NSPopover?
    private var animation: Timer?

    init(size: NSSize) {
        // A non-activating panel: the one window kind that joins the active
        // Space from a process that cannot activate itself. A plain
        // `NSWindow` of a `swift run` process, even with `canJoinAllSpaces`
        // and `fullScreenAuxiliary`, stays on the desktop Space while a
        // full-screen Space is in front, off screen for the window server
        // and absent from ScreenCaptureKit's listing (measured 2026-11-04).
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered,
            defer: false)
        // Panels hide when their application deactivates, which ours never
        // is; the capture needs the window to stay.
        panel.hidesOnDeactivate = false
        window = panel
        window.title = "Cutscene window spike"
        window.isReleasedWhenClosed = false
        // On top of everything, so the capture shows the window whole and
        // the lead sees it, without the process being active.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content = AnimatedView(frame: NSRect(origin: .zero, size: size))
        menuButton = NSButton(title: "Menu", target: nil, action: nil)
        popoverButton = NSButton(title: "Popover", target: nil, action: nil)
        super.init()
        for (index, title) in ["First item", "Second item", "Third item", "A longer fourth item"].enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        menuButton.target = self
        menuButton.action = #selector(menuButtonPressed(_:))
        popoverButton.target = self
        popoverButton.action = #selector(popoverButtonPressed(_:))
        let buttons = NSStackView(views: [menuButton, popoverButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.frame = NSRect(x: 16, y: 16, width: 220, height: 32)
        buttons.autoresizingMask = [.maxXMargin, .maxYMargin]
        // A stack view made in code opts out of frame-based layout, and a
        // constraint-less stack lays its buttons out at zero size.
        buttons.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        if let view = window.contentView {
            content.frame = view.bounds
            view.addSubview(content)
            view.addSubview(buttons)
        }
    }

    var windowNumber: Int { window.windowNumber }

    func show() {
        window.center()
        orderFront()
        let timer = Timer(timeInterval: WindowSpike.animationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.content.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// Orders the window front without activating the process, which a
    /// `swift run` process cannot do (platform-notes "Click monitors").
    func orderFront() {
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        animation?.invalidate()
        animation = nil
        popover?.close()
        window.orderOut(nil)
    }

    /// The starting size, centred, with no popover: the state every take
    /// begins from.
    func reset() {
        closePopover()
        window.setContentSize(WindowSpike.windowSize)
        window.center()
        orderFront()
    }

    func setStatus(_ text: String) {
        content.status = text
    }

    /// Pops the menu up in the window and closes it after `seconds`. The
    /// call blocks in the menu's tracking loop until then; the closing timer
    /// runs in the common modes, which the tracking loop services.
    func openMenu(for seconds: Double) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let anchor = NSPoint(x: menuButton.frame.midX, y: menuButton.frame.maxY)
        _ = menu.popUp(positioning: nil, at: anchor, in: window.contentView)
        timer.invalidate()
    }

    func showPopover() {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentSize = WindowSpike.popoverSize
        popover.contentViewController = PopoverController()
        popover.show(relativeTo: popoverButton.bounds, of: popoverButton, preferredEdge: .maxY)
        self.popover = popover
    }

    func closePopover() {
        popover?.close()
        popover = nil
    }

    func move(by delta: NSPoint) {
        var origin = window.frame.origin
        origin.x += delta.x
        origin.y += delta.y
        window.setFrameOrigin(origin)
    }

    func resize(by delta: NSSize) {
        var frame = window.frame
        frame.size.width += delta.width
        frame.size.height += delta.height
        frame.origin.y -= delta.height
        window.setFrame(frame, display: true)
    }

    @objc private func menuButtonPressed(_ sender: Any?) {
        _ = menu.popUp(
            positioning: nil, at: NSPoint(x: menuButton.frame.midX, y: menuButton.frame.maxY), in: window.contentView)
    }

    @objc private func popoverButtonPressed(_ sender: Any?) {
        if popover == nil { showPopover() } else { closePopover() }
    }
}

/// A white surface with a block circling it and the status text, redrawn
/// on every tick so the stream sees a changed frame.
@MainActor
private final class AnimatedView: NSView {
    var status = "" {
        didSet { needsDisplay = true }
    }
    private var phase = 0.0
    private let blockSize = 48.0

    func advance() {
        phase += 0.06
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let inset = bounds.insetBy(dx: blockSize, dy: blockSize + 24)
        let center = NSPoint(
            x: inset.midX + cos(phase) * inset.width / 2, y: inset.midY + sin(phase * 1.3) * inset.height / 2)
        NSColor.systemBlue.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: center.x - blockSize / 2, y: center.y - blockSize / 2, width: blockSize, height: blockSize),
            xRadius: 8, yRadius: 8
        ).fill()
        let text = "Cutscene window spike\n\(status)" as NSString
        text.draw(
            at: NSPoint(x: 16, y: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.black])
    }
}

/// The popover's content: a coloured panel with a label, large enough to
/// show in the capture.
@MainActor
private final class PopoverController: NSViewController {
    override func loadView() {
        let view = NSView(frame: NSRect(origin: .zero, size: WindowSpike.popoverSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemOrange.cgColor
        let label = NSTextField(labelWithString: "Popover (child window)")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.sizeToFit()
        label.frame.origin = NSPoint(
            x: (view.bounds.width - label.frame.width) / 2, y: (view.bounds.height - label.frame.height) / 2)
        view.addSubview(label)
        self.view = view
    }
}
