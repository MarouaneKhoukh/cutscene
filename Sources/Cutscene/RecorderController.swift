import CoreMedia
import CutsceneCapture
import CutsceneCore
import Foundation
import Observation

/// What happens to a complete package once the take has stopped. M1-13's
/// `AutoRender` builds the plan and exports it; until a renderer is set, the
/// controller is done when the package is.
protocol TakeRenderer: Sendable {
    /// Renders `package` to a movie and returns where it was written.
    /// `progress` is 0…1 and may be called from any thread.
    func render(
        package: RecordingPackage, manifest: RecordingManifest, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    /// Ends the render in flight, if any; `render` then throws and leaves
    /// nothing on disk.
    func cancel() async
}

/// A marker pressed on the pill while the take ran, by the host time of the
/// press; it becomes a `takeMarker` event once the package is complete.
struct TakeMarker: Sendable, Equatable {
    /// Seconds on the take's timeline, mapped through the clock so paused
    /// intervals are excluded.
    let recordingSeconds: Double
    let label: String?
}

/// One take at a time, from the menu's Record to a complete package and its
/// render (ARCHITECTURE §1): `idle → countdown → selecting → recording →
/// finishing → rendering → done(url) / failed(error, partialURL) /
/// renderFailed(error, package)`.
///
/// One `CaptureSession` per take. The session's status stream drives the
/// elapsed time and the counters, and the end of the take, whether Stop was
/// pressed or the stream stopped itself (display gone, system stop), goes
/// through one finish path. Nothing here prompts except the microphone
/// request on a Record with a microphone chosen and never asked for, which is
/// the "first toggle" of §7 when the menu's own request did not happen.
///
/// Markers (the pill's button) are stamped here with the host clock and
/// written into `events.json` after the session has completed the package:
/// the log's `startHostTimeSeconds` is the same origin the session stamped
/// every other event with, so a marker lands at the time of the press to the
/// precision of the clock, and the session's own files stay the session's.
@MainActor @Observable final class RecorderController {
    enum State {
        /// Nothing running; the menu offers the sources.
        case idle
        /// The source was chosen and the overlay counts `remaining` seconds
        /// before the session starts; Stop cancels it.
        case countdown(remaining: Int)
        /// The session is resolving the source and starting the stream.
        case selecting
        case recording
        /// Stop was pressed or the stream ended; the files are being completed.
        case finishing
        /// The package is complete and the renderer is exporting it; the
        /// progress is nil until the renderer reports one.
        case rendering(progress: Double?)
        /// The export, or the package when there is no renderer, at `url`.
        case done(URL)
        /// `partialURL` is the package when one was created; its manifest
        /// says what survived.
        case failed(any Error, partialURL: URL?)
        /// The package at `package` is complete but its render failed or was
        /// cancelled; `renderLast(package:)` runs it again.
        case renderFailed(any Error, package: URL)
    }

    /// What one take owns while it runs.
    private struct Take {
        let session: CaptureSession
        let package: RecordingPackage
        let request: CaptureRequest
    }

    let permissions: Permissions
    let sessionSettings: CaptureSessionSettings
    /// Set by M1-13; nil leaves the take at the package.
    var renderer: (any TakeRenderer)?
    /// Called when a package is complete, before any render.
    var onTakeComplete: (@MainActor (RecordingPackage, RecordingManifest) -> Void)?
    /// Called when the renderer wrote its file.
    var onExportComplete: (@MainActor (URL) -> Void)?
    /// Called on every change of `state`, for the overlays and the pill,
    /// which are AppKit windows rather than SwiftUI views.
    var onStateChange: (@MainActor (State) -> Void)?

    private(set) var state = State.idle {
        didSet { onStateChange?(state) }
    }
    /// Recorded seconds so far, at the session's status cadence.
    private(set) var elapsedSeconds = 0.0
    /// Mirrors the session's clock; true between Pause and Resume.
    private(set) var isPaused = false
    private(set) var statistics = CaptureStatistics()
    /// The markers pressed during the running or last take.
    private(set) var markers: [TakeMarker] = []
    /// Why the last take's markers did not reach `events.json`, if they did not.
    private(set) var markerWarning: String?
    private var take: Take?
    private var statusTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    /// The countdown in flight; cancelled by `stop`.
    private var countdownTask: Task<Bool, Never>?
    /// Set by a `stop` during the countdown, for the case where the
    /// countdown task had already finished its last sleep and the cancel
    /// reached nothing; `record` reads it before it starts the session.
    private var cancelRequested = false
    /// Callers of `stop` that arrived while the take was still starting.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(permissions: Permissions, sessionSettings: CaptureSessionSettings = CaptureSessionSettings()) {
        self.permissions = permissions
        self.sessionSettings = sessionSettings
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var markerCount: Int { markers.count }

    /// Whether a take is in flight: anything between Record and done or
    /// failed, the render included, since a second take would compete with
    /// the export for the encoder.
    var isBusy: Bool {
        switch state {
        case .idle, .done, .failed, .renderFailed: false
        case .countdown, .selecting, .recording, .finishing, .rendering: true
        }
    }

    // MARK: Record

    /// Starts a take of `request` in a new package under `directory`, named
    /// `RecordingPackage.url(createdAt:source:in:)` after `source` when one
    /// is given (a window's application name), else after the request's
    /// kind. A `countdown` with a positive count runs first, with the state
    /// at `.countdown` and Stop cancelling it. Returns once the stream runs
    /// (`.recording`), the start failed (`.failed`) or the countdown was
    /// cancelled (`.idle`). Does nothing while a take is in flight.
    func record(
        _ request: CaptureRequest, in directory: URL, countdown: CountdownSettings? = nil,
        named source: CaptureSource? = nil
    ) async {
        guard !isBusy else { return }
        elapsedSeconds = 0
        statistics = CaptureStatistics()
        markers = []
        markerWarning = nil
        defer { resumeStartWaiters() }

        if let countdown, countdown.seconds > 0 {
            // Busy from this line, before the first suspension: the
            // countdown task runs in a later main-actor job, and a second
            // `record` landing in between would otherwise pass `isBusy`
            // and start a take beside this one.
            state = .countdown(remaining: countdown.seconds)
            let task = Task { await self.runCountdown(countdown) }
            countdownTask = task
            let completed = await task.value
            countdownTask = nil
            guard completed, !cancelRequested else {
                cancelRequested = false
                state = .idle
                return
            }
        }
        state = .selecting

        if request.microphoneID != nil {
            var microphone = permissions.preflight(.microphone)
            if microphone == .notDetermined {
                microphone = await permissions.request(.microphone)
            }
            guard microphone == .granted else {
                state = .failed(CaptureSessionError.microphoneNotGranted(microphone), partialURL: nil)
                return
            }
        }

        let package: RecordingPackage
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let proposed = RecordingPackage.url(
                createdAt: Date(), source: source ?? Self.captureSource(for: request), in: directory)
            package = RecordingPackage(url: RecordingPackage.availableURL(for: proposed))
        } catch {
            state = .failed(error, partialURL: nil)
            return
        }

        let session = CaptureSession(settings: sessionSettings, permissions: permissions)
        do {
            let statuses = try await session.start(request: request, package: package)
            take = Take(session: session, package: package, request: request)
            state = .recording
            statusTask = Task { [weak self] in
                for await status in statuses {
                    self?.apply(status)
                }
            }
        } catch {
            // A start whose stream refused to run left a `failed` manifest in
            // the package; one that failed before the manifest removed the
            // package again, so nothing points at an empty folder.
            state = .failed(error, partialURL: package.exists ? package.url : nil)
        }
    }

    /// Counts `countdown.seconds` down through `.countdown` states; false
    /// when cancelled before it reached zero.
    private func runCountdown(_ countdown: CountdownSettings) async -> Bool {
        for remaining in stride(from: countdown.seconds, to: 0, by: -1) {
            state = .countdown(remaining: remaining)
            do {
                try await Task.sleep(for: .seconds(countdown.tickInterval))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    /// Ends the take and returns once the package is complete: a countdown
    /// is cancelled, a take still starting is stopped the moment it
    /// records, one already finishing is waited for. The render, when there
    /// is one, carries on by itself; `state` follows it. Nothing happens in
    /// any other state.
    func stop() async {
        switch state {
        case .countdown:
            cancelRequested = true
            countdownTask?.cancel()
            await withCheckedContinuation { startWaiters.append($0) }
            // A countdown that had already completed when the cancel came
            // went on to start the take; this ends it. A no-op in `idle`.
            await stop()
        case .selecting:
            await withCheckedContinuation { startWaiters.append($0) }
            await stop()
        case .recording:
            beginFinish()
            await finishTask?.value
        case .finishing:
            await finishTask?.value
        case .idle, .rendering, .done, .failed, .renderFailed:
            return
        }
    }

    /// Stamps a marker at the moment of the call (the pill's Marker button;
    /// M3-02 adds the labelled "retake" form). Ignored unless recording.
    func mark(label: String? = nil) {
        guard isRecording, !isPaused, let take else { return }
        let host = RecordingClock.hostTime().seconds
        Task { @MainActor in
            // Through the clock, never raw host-time subtraction: a pause
            // before the marker would otherwise shift it late in the log.
            guard let seconds = await take.session.recordingTime(forHostSeconds: host) else { return }
            markers.append(TakeMarker(recordingSeconds: seconds, label: label))
        }
    }

    /// Pauses the take's clock: screen, camera, audio, elapsed time, telemetry
    /// and markers all stop together (ARCHITECTURE §2).
    func pause() {
        guard isRecording, !isPaused, let take else { return }
        Task { try? await take.session.pause() }
    }

    func resume() {
        guard isRecording, isPaused, let take else { return }
        Task { try? await take.session.resume() }
    }

    /// Ends a render in flight and waits for it to wind down; the package
    /// stays complete and `renderLast(package:)` can run it again.
    func cancelRender() async {
        guard case .rendering = state, let renderer else { return }
        await renderer.cancel()
        await renderTask?.value
    }

    /// Renders `package`, a complete take, as the auto-render would have:
    /// for a render that failed or was cancelled. Nothing happens while a
    /// take is in flight or without a renderer.
    func renderLast(package: RecordingPackage) {
        guard !isBusy, let renderer else { return }
        let manifest: RecordingManifest
        do {
            manifest = try package.manifest()
        } catch {
            state = .renderFailed(error, package: package.url)
            return
        }
        state = .rendering(progress: nil)
        renderTask = Task { await self.render(package, manifest: manifest, with: renderer) }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Status

    private func apply(_ status: CaptureStatus) {
        elapsedSeconds = status.elapsedSeconds
        isPaused = status.isPaused
        statistics = status.statistics
        switch status.phase {
        case .recording:
            break
        case .finishing, .finished, .failed:
            // The stream stopped itself, or this is the echo of our Stop;
            // either way the finish path runs once.
            beginFinish()
        }
    }

    // MARK: Finish

    private func beginFinish() {
        guard finishTask == nil, let take else { return }
        state = .finishing
        finishTask = Task { await self.finish(take) }
    }

    private func finish(_ take: Take) async {
        let manifest: RecordingManifest
        do {
            manifest = try await take.session.stop()
        } catch {
            clearTake()
            state = .failed(error, partialURL: take.package.url)
            return
        }
        clearTake()
        writeMarkers(into: take.package)
        onTakeComplete?(take.package, manifest)
        guard let renderer else {
            state = .done(take.package.url)
            return
        }
        state = .rendering(progress: nil)
        renderTask = Task { await self.render(take.package, manifest: manifest, with: renderer) }
    }

    /// Appends the take's markers to the package's `events.json` as
    /// `takeMarker` events at their time on the recording's clock. A take
    /// without markers leaves the file untouched; a failure is reported in
    /// `markerWarning`, never as a failed take.
    private func writeMarkers(into package: RecordingPackage) {
        guard !markers.isEmpty else { return }
        do {
            var log = try EventLog.read(from: package.eventsURL)
            log.append(
                contentsOf: markers.map {
                    InputEvent.takeMarker(time: $0.recordingSeconds, label: $0.label)
                })
            try log.write(to: package.eventsURL)
        } catch {
            markerWarning = "The \(markers.count) marker(s) could not be saved: \(error.localizedDescription)"
        }
    }

    private func render(_ package: RecordingPackage, manifest: RecordingManifest, with renderer: any TakeRenderer)
        async
    {
        do {
            let url = try await renderer.render(package: package, manifest: manifest) { [weak self] progress in
                Task { @MainActor in self?.reportRenderProgress(progress) }
            }
            state = .done(url)
            onExportComplete?(url)
        } catch {
            state = .renderFailed(error, package: package.url)
        }
        renderTask = nil
    }

    private func reportRenderProgress(_ progress: Double) {
        guard case .rendering = state else { return }
        state = .rendering(progress: progress)
    }

    /// Dropping the take releases the session; the status stream ended with
    /// it, so its loop is over too.
    private func clearTake() {
        take = nil
        finishTask = nil
        statusTask = nil
    }

    /// The manifest's name for the request's source, for the package name
    /// when the caller gives none; a window's facts are the session's to
    /// resolve, so here it is the kind alone.
    private static func captureSource(for request: CaptureRequest) -> CaptureSource {
        switch request.source {
        case .display: .display
        case .area: .area
        case .window(let id):
            .window(
                WindowSource(
                    windowID: id, bundleID: "", frame: PointRect(x: 0, y: 0, width: 0, height: 0),
                    strategy: WindowStrategy(request.windowStrategy)))
        }
    }
}

extension RecorderController.State {
    /// True once the take has rendered; the launcher reopens itself on it.
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}
