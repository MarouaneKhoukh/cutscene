import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCore
import Foundation
import ScreenCaptureKit

/// Where the idle heartbeat gets the pixels of the last complete frame
/// (ARCHITECTURE §2 "Idle heartbeat"). Whether ScreenCaptureKit leaves a
/// retained surface untouched is unverified until spike S1 runs; the session
/// checks it with a checksum and can fall back to copying.
public enum HeartbeatHoldSource: String, Sendable, Codable, CaseIterable {
    /// The retained surface, with its checksum compared against the one
    /// taken on arrival at the first hold of a static stretch; when it
    /// matches, the frame is copied then and the stretch's later holds
    /// encode the copy (one copy per stretch, never per frame), and at a
    /// mismatch the rest of the take copies every content frame on arrival
    /// instead.
    case automatic
    /// Always the retained surface; mismatches are counted, never acted on.
    case retainedSurface
    /// Always a copy made when the frame arrives.
    case copy
}

/// The numbers one session is tuned with (ARCHITECTURE §2 `disk.*`; the
/// heartbeat interval itself is the request's `heartbeat`).
public struct CaptureSessionSettings: Sendable, Equatable {
    /// Free space the destination volume must have before a take starts
    /// (`disk.preflightMinimum`): a few minutes of 4K60 plus the finalize,
    /// which briefly holds the fragmented movie and the MP4 side by side.
    public var minimumFreeBytes: Int64 = 2_000_000_000
    /// Seconds between the status snapshots the `start` stream yields.
    public var statusInterval: TimeInterval = 1
    /// Snapshots kept for a slow consumer; newer ones replace older, so the
    /// final status always gets through.
    public var statusBufferDepth: Int = 8
    /// How late the heartbeat timer may fire. Milliseconds against a 1 s
    /// cadence cost nothing and let libdispatch coalesce the wake-up.
    public var heartbeatLeeway: TimeInterval = 0.01
    /// How far in the past a hold is stamped: ScreenCaptureKit delivers a
    /// frame one to two frame intervals after capturing it (ARCHITECTURE
    /// §2), so a hold stamped at the tick itself could land after a content
    /// frame still on its way, which the encoder would then drop as
    /// non-increasing. Two 60 fps intervals.
    public var heartbeatDeliveryGuard: TimeInterval = 2.0 / 60
    /// Where a content frame that still arrives stamped at or before the
    /// last hold is moved to, past that hold: a millisecond keeps the frame
    /// in the movie at a stamp no viewer can tell from its own.
    public var heartbeatNudge: TimeInterval = 0.001
    public var holdSource: HeartbeatHoldSource = .automatic
    /// Channels the microphone track is written with at most: a
    /// multi-channel interface is mapped down to this many by AVFoundation
    /// (`RecordingWriterConfiguration.AudioTrack.maximumChannelCount`), since
    /// the AAC encoder's own layouts above stereo are surround layouts and
    /// a voice track needs no more.
    public var microphoneMaximumChannels: Int = RecordingWriterConfiguration.AudioTrack.maximumChannelCount
    /// Bytes of a retained frame that go into its checksum, spread over every
    /// plane in `checksumChunkBytes` runs. A surface recycled for another
    /// frame changes everywhere, so a sparse sample catches it at a cost of
    /// microseconds per frame, where hashing the whole 12 MB of a 4K frame
    /// at 60 fps would not fit beside the encoder.
    public var checksumSampleBytes: Int = 16_384
    public var checksumChunkBytes: Int = 64
    /// Warnings kept in the statistics; the first ones are the useful ones.
    public var maximumWarnings: Int = 32
    /// The reason string of the `ProcessInfo` activity held for the take.
    public var activityReason: String = "Recording"
    /// Label of the session's serial queue, the actor's executor.
    public var queueLabel: String = "app.cutscene.capture.session"
    /// Name of the S1 facts file written into `recording/` after the first
    /// content frame.
    public var debugFileName: String = "capture-debug.json"
    public var frameIndex = FrameIndexWriterSettings()
    /// The camera recorder's own numbers; the size cap, rate and tier are
    /// the request's `CameraSelection`.
    public var camera = CameraRecorderSettings()
    public var telemetryPersistenceInterval: TimeInterval = InputTelemetryRecorder.defaultPersistenceInterval
    /// The disk guard's numbers: poll, warning line, auto-stop floor.
    public var disk = DiskSpaceMonitorSettings()
    /// Seconds without a microphone buffer, while the stream keeps
    /// delivering, before the microphone is reported stalled. The stream
    /// hands over a buffer every 21 ms (1024 frames at 48 kHz), so two
    /// seconds is a hundred missed buffers, far past any scheduling hiccup.
    public var microphoneStallTimeout: TimeInterval = 2
    /// The kit `project.json` is written with.
    public var kit: BrandKit = .default
    /// The window geometry poll's numbers (4 Hz on a display or area take,
    /// 10 Hz on a window take).
    public var geometry = WindowGeometryPollerSettings()
    /// How many times, and how far apart, the shareable content is listed
    /// again when ScreenCaptureKit does not yet list a window of ours for a
    /// display or area take: a window of ours (the pill) reaches the
    /// listing a few run-loop turns after it is ordered front
    /// (platform-notes "Window capture"), and without our application in
    /// the listing the filter would exclude nothing and the pill would be
    /// captured. The spike's 100 ms loop, for up to a second.
    public var ownApplicationListingRetries: Int = 10
    public var ownApplicationListingInterval: TimeInterval = 0.1

    public init() {}
}

/// Everything the take lost, gathered from the pipeline's own counters into
/// the numbers the pill shows (ARCHITECTURE §2 "Dropped frames and
/// pacing"). The parts stay in `CaptureStatistics` for the report.
public struct CaptureDropCounters: Sendable, Equatable {
    /// Content frames VideoToolbox discarded to keep up.
    public var encoderDropped = 0
    /// Compressed frames the writer could not take because its input was
    /// not ready (the disk fell behind); each one has a `gap` line.
    public var writerNotReady = 0
    /// Frames the writer refused for a non-increasing stamp.
    public var writerNonIncreasing = 0
    /// `gap` lines in `frames.jsonl`.
    public var gapLines = 0
    /// Audio buffers lost on the way to the file, both sources.
    public var audioBuffers = 0
    /// Camera frames the output discarded or the camera writer could not
    /// take; zero without a camera.
    public var cameraFrames = 0

    /// Screen frames that never reached the movie.
    public var screenFrames: Int {
        encoderDropped + writerNotReady + writerNonIncreasing
    }

    public init() {}
}

/// What the session knows about the microphone track as the take runs.
public enum MicrophoneCondition: Sendable, Equatable {
    /// The take has no microphone track.
    case notRecorded
    /// No buffer has arrived yet; the writer pads the track from zero when
    /// the first one does.
    case waiting
    case delivering
    /// No buffer for longer than `CaptureSessionSettings.microphoneStallTimeout`
    /// while the stream delivers; the span is silence in the track, filled
    /// by the writer when the next buffer comes or at the stop.
    case stalled(sinceRecordingSeconds: Double)
    /// The device went away (`AVCaptureDevice.wasDisconnectedNotification`);
    /// the rest of the track is silence and the take goes on.
    case disconnected(atRecordingSeconds: Double)
}

/// Counters for the pill and the end-of-take report, gathered from every part
/// of the pipeline into one `Sendable` value.
public struct CaptureStatistics: Sendable, Equatable {
    public var frames = ScreenFrameIndexerStatistics()
    public var encoder = VideoEncoderStatistics()
    public var writer = RecordingWriterStatistics()
    public var telemetry = InputTelemetryStatistics()
    /// The window geometry poll's counters: its `geometry` rows go into
    /// the telemetry log.
    public var geometry = WindowGeometryPollerStatistics()
    /// Focus changes observed and written into the log, the one at start
    /// included.
    public var focusEvents = 0
    /// The camera's counters; nil when the take records no camera.
    public var camera: CameraRecorderStatistics?
    /// Heartbeat frames encoded.
    public var holdsEncoded = 0
    /// Heartbeats that encoded nothing: the retained surface failed its
    /// checksum, or the encoder refused the frame.
    public var holdsSkipped = 0
    /// Content frames that arrived stamped at or before the last hold in
    /// spite of the delivery guard and were nudged past it
    /// (`CaptureSessionSettings.heartbeatNudge`).
    public var holdCollisions = 0
    /// Holds for which the retained surface's checksum was compared with the
    /// one taken on arrival.
    public var retainedSurfaceChecks = 0
    /// Of those, the ones whose surface had changed: the S1 fact.
    public var retainedSurfaceMismatches = 0
    /// Content frames copied for the heartbeat.
    public var copiedFrames = 0
    public var copyFailures = 0
    /// What the heartbeat encodes from right now; `automatic` resolves to
    /// one of the other two.
    public var holdSourceInUse: HeartbeatHoldSource = .retainedSurface
    /// Whether `SCStream.synchronizationClock` is the host clock; nil until
    /// the stream reports one.
    public var synchronizationClockIsHostClock: Bool?
    /// Samples whose stamps were converted from the stream clock to the host
    /// clock, which happens only when the two differ.
    public var sampleTimesConverted = 0
    /// Cursor sprites written into `cursors/` at stop.
    public var cursorSpritesWritten = 0
    /// What the take lost, for the pill; the parts are in the fields above.
    public var dropped = CaptureDropCounters()
    /// The disk guard's latest reading; nil before its first poll.
    public var disk: DiskSpaceReading?
    /// Free bytes on the destination volume: the disk guard's reading, or
    /// a direct look when it has none yet.
    public var freeDiskBytes: Int64?
    public var microphone: MicrophoneCondition = .notRecorded
    /// Microphone buffers the stream delivered, whatever the writer did
    /// with them.
    public var microphoneBuffers = 0
    /// Pauses completed so far.
    public var pauses = 0
    /// Seconds the take has spent paused, the open pause included.
    public var pausedSeconds: Double = 0
    public var warnings: [String] = []

    public init() {}
}

/// One snapshot from a running session, yielded by the `start` stream.
public struct CaptureStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case recording
        case finishing
        case finished(StopReason)
        /// The take ended but its files are not all complete; `message`
        /// says what failed and the manifest says what survived.
        case failed(StopReason, message: String)
    }

    public var phase: Phase
    /// Recorded seconds so far, pauses removed.
    public var elapsedSeconds: Double
    public var statistics: CaptureStatistics
    /// Whether the clock is paused: the phase stays `recording`, since the
    /// stream runs and the take is still open.
    public var isPaused: Bool

    public init(phase: Phase, elapsedSeconds: Double, statistics: CaptureStatistics, isPaused: Bool = false) {
        self.phase = phase
        self.elapsedSeconds = elapsedSeconds
        self.statistics = statistics
        self.isPaused = isPaused
    }
}

public enum CaptureSessionError: LocalizedError {
    /// A session records one take; make another for the next.
    case alreadyStarted
    case notRecording
    case insufficientDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    /// The request names a microphone but the grant is not usable, and the
    /// session never prompts.
    case microphoneNotGranted(PermissionState)
    case microphoneNotFound(String)
    /// The take ended but finishing it failed; `manifest` is what was
    /// written, with `state` saying whether the movie is complete.
    case finishFailed(underlying: any Error, manifest: RecordingManifest)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "This capture session has already recorded a take."
        case .notRecording:
            "No take is being recorded."
        case .insufficientDiskSpace(let available, let required):
            "Only \(available / 1_000_000) MB are free; recording needs at least \(required / 1_000_000) MB."
        case .microphoneNotGranted(let state):
            "Microphone access is \(state.rawValue), so the microphone cannot be recorded."
        case .microphoneNotFound(let id):
            "No microphone with the identifier \(id) is connected."
        case .finishFailed(let error, _):
            "The recording could not be finished: \(error.localizedDescription)"
        }
    }
}

/// One take of the screen, from Record to a complete `.cutscene` package
/// (ARCHITECTURE §1, §2).
///
/// The actor runs on a `DispatchSerialQueue` that is also the queue
/// `SCStream` delivers samples on. `StreamOutputShim` enters the actor from
/// that queue with `assumeIsolated`, so a sample buffer is consumed where it
/// arrives: the encoder, the writer, the frame indexer and the telemetry
/// recorder are lock-guarded classes, never actors, and nothing that is not
/// `Sendable` crosses an isolation boundary. The heartbeat and status timers
/// are dispatch sources on the same queue and enter the same way.
///
/// Everything is stamped through one `RecordingClock`, built unstarted while
/// the pipeline is wired and started immediately before the stream is: the
/// first frame lands some hundred milliseconds in and the movie opens with
/// an empty edit of that length, which is what keeps it aligned with the
/// telemetry and the audio, which begin at zero. ScreenCaptureKit stamps are
/// assumed to be host-clock; the stream's `synchronizationClock` is compared
/// with the host clock as soon as the stream reports one (at the first
/// sample, or after the start), and if the two differ every stamp is
/// converted with `CMSyncConvertTime` first. The comparison, with the first
/// frame's buffer attachments, goes into `recording/capture-debug.json` for
/// spike S1.
///
/// A request naming a camera gets a `CameraRecorder` on the same clock:
/// started before the origin is taken, so the camera has warmed up and its
/// first recorded frame lands within one interval of time zero, and stopped
/// on the finish path after the clock, so `camera.mp4` ends with the screen.
/// The camera is a companion, not the take: a camera that fails leaves a
/// warning and a manifest without `camera`, never a failed take.
///
/// A static screen yields no frames, so every `heartbeat` seconds without a
/// content frame the last one is encoded again, stamped a delivery guard
/// before the tick, and the index gets a `hold` line; that is what lets the
/// encoder's 2 s keyframe cap fire. Whether the retained surface still holds
/// the frame is checked with a checksum taken on arrival
/// (`HeartbeatHoldSource`).
///
/// `pause()` and `resume()` pause the clock (DECISIONS "pause stays in the
/// data path": the live pause case passed in spike S1): the stream keeps
/// running, and every stage decides membership by the stamp, so frames,
/// audio buffers and events captured inside the pause fall out on their
/// own, the first frame after the resume opens a GOP (the encoder forces
/// the keyframe) and the audio joins sample-exact (the writer trims the
/// buffer straddling the resume). The status says `isPaused`; the phase
/// stays `recording`.
///
/// The take ends through one finish path, whether the user stopped it, the
/// stream stopped itself (`stream(_:didStopWithError:)`: the display went
/// away, `systemStoppedStream`), the window being recorded closed
/// (`streamDidBecomeInactive`, 15.2), the display went offline under a
/// stream that did not notice (checked at every status tick), the disk
/// guard hit its floor (`DiskSpaceMonitor`, `.diskFull`) or the writer
/// failed (noticed at the next status tick): the clock stops, the stream is
/// stopped while samples stamped before the stop are still taken, the
/// telemetry log and the movie are finalized (the writer's end marker gives
/// the last frame its duration up to the stop, and each audio track is
/// padded with silence to it), the cursor sprites are written, and the
/// manifest goes from `inProgress` to `complete` (or `recovered` when the
/// writer failed and what it had flushed was finalized, or `failed`) with
/// the stop reason, which is the package's commit point. A microphone that
/// goes away mid-take (`wasDisconnectedNotification`, or buffers that stop
/// coming) does not end the take: the status says so, and the writer fills
/// the hole with silence when the next buffer arrives or at the stop.
/// `project.json` is written at start and rewritten at stop with the
/// default kit, so the package opens in the editor either way. A session
/// records one take; the app makes one per take, and a session dropped
/// mid-take stops its stream in `deinit`.
public actor CaptureSession {
    /// The executor, and the sample-handler queue of the stream.
    public nonisolated let queue: DispatchSerialQueue
    public nonisolated let settings: CaptureSessionSettings
    public nonisolated let permissions: Permissions

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private enum Phase {
        case idle
        case starting
        case recording
        case finishing
        case finished(RecordingManifest)
        case failed(any Error)
    }

    /// Everything one take owns, created by `start` and released by the
    /// finish path. A class so the actor's methods can share one reference
    /// without copying; it never leaves the actor.
    private final class Take {
        let request: CaptureRequest
        let package: RecordingPackage
        let geometry: CaptureGeometry
        let clock: RecordingClock
        let encoder: VideoEncoder
        let writer: RecordingWriter
        let indexer: ScreenFrameIndexer
        let telemetry: InputTelemetryRecorder
        /// The window geometry poll, whose `geometry` rows go into the
        /// telemetry log (ARCHITECTURE §2 "Scroll, focus, geometry").
        let poller: WindowGeometryPoller
        let store: ProjectStore
        let stream: SCStream
        let shim: StreamOutputShim
        /// The stream's delegate, held here because the stream does not.
        let events: StreamEventDelegate
        let streamSummary: StreamSummary
        /// Running on the same clock since before the origin; nil when the
        /// request names no camera.
        let camera: CameraRecorder?
        let disk: DiskSpaceMonitor
        /// The microphone being recorded, watched for its disconnection.
        let microphoneDevice: AVCaptureDevice?
        /// The activation observer behind the log's `focus` rows; made on
        /// the main actor once the pipeline exists, so set by `start`.
        var focus: FocusMonitor?
        /// Focus rows written so far, the initial one included.
        var focusEvents = 0
        var manifest: RecordingManifest
        /// Known once the stream has started.
        var synchronizationClock: CMClock?
        /// True only when `synchronizationClock` exists and is not the host
        /// clock, in which case every stamp is converted before use.
        var convertsSampleTimes = false
        var debugFactsWritten = false
        /// Whether the camera's failure has been noted; it is noted once.
        var cameraFailureNoted = false
        /// Arrival time of the last sample of any type, and of the last
        /// microphone buffer: a microphone that stops while the stream goes
        /// on is a stall, one that stops with the stream is not.
        var lastSampleArrival: CMTime?
        var lastMicrophoneArrival: CMTime?
        var microphoneObserver: (any NSObjectProtocol)?
        /// Whether the disk warning has been noted; it is noted once.
        var diskWarningNoted = false
        /// Host time the open pause began, and the completed pauses' total.
        var pauseStartedAt: CMTime?
        var pausedSeconds: Double = 0

        init(
            request: CaptureRequest, package: RecordingPackage, geometry: CaptureGeometry, clock: RecordingClock,
            encoder: VideoEncoder, writer: RecordingWriter, indexer: ScreenFrameIndexer,
            telemetry: InputTelemetryRecorder, poller: WindowGeometryPoller, store: ProjectStore, stream: SCStream,
            shim: StreamOutputShim, events: StreamEventDelegate, streamSummary: StreamSummary,
            camera: CameraRecorder?, disk: DiskSpaceMonitor, microphoneDevice: AVCaptureDevice?,
            manifest: RecordingManifest
        ) {
            self.request = request
            self.package = package
            self.geometry = geometry
            self.clock = clock
            self.encoder = encoder
            self.writer = writer
            self.indexer = indexer
            self.telemetry = telemetry
            self.poller = poller
            self.store = store
            self.stream = stream
            self.shim = shim
            self.events = events
            self.streamSummary = streamSummary
            self.camera = camera
            self.disk = disk
            self.microphoneDevice = microphoneDevice
            self.manifest = manifest
        }
    }

    /// The stream's delegate (`SCStreamDelegate`): the lifecycle events,
    /// which arrive on a queue of ScreenCaptureKit's choosing and hop into
    /// the session through a task, as the samples' shim does for the stop.
    /// A separate object from `StreamOutputShim` so the 15.2 delegate
    /// methods can be gated here without touching the sample path. The
    /// session is held weakly for the same reason the shim holds it so.
    final class StreamEventDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
        private weak var session: CaptureSession?

        init(session: CaptureSession) {
            self.session = session
            super.init()
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            guard let session else { return }
            Task { await session.streamDidStop(with: error) }
        }

        @available(macOS 15.2, *)
        func streamDidBecomeInactive(_ stream: SCStream) {
            guard let session else { return }
            Task { await session.streamDidBecomeInactive() }
        }

        @available(macOS 15.2, *)
        func streamDidBecomeActive(_ stream: SCStream) {
            guard let session else { return }
            Task { await session.streamDidBecomeActive() }
        }
    }

    /// What `deinit` needs to end a take the session was dropped in the
    /// middle of. An actor's `deinit` is nonisolated and may read only
    /// `Sendable` state, so the stream, the telemetry and the activity
    /// assertion are boxed here from the start of the take to its finish;
    /// nothing but `deinit` reads the box, and the objects stay the take's.
    private final class AbandonedTakeHandle: @unchecked Sendable {
        let stream: SCStream
        let telemetry: InputTelemetryRecorder
        let poller: WindowGeometryPoller
        let activity: (any NSObjectProtocol)?
        /// Set once the take records, on the actor; read only by `deinit`,
        /// which runs when nothing else references the session.
        var microphoneObserver: (any NSObjectProtocol)?
        var focus: FocusMonitor?

        init(
            stream: SCStream, telemetry: InputTelemetryRecorder, poller: WindowGeometryPoller,
            activity: (any NSObjectProtocol)?
        ) {
            self.stream = stream
            self.telemetry = telemetry
            self.poller = poller
            self.activity = activity
        }
    }

    /// The last content frame and what the heartbeat knows about it.
    private struct Heartbeat {
        /// The frame to re-encode: the stream's own surface, or our copy.
        var retained: CVPixelBuffer?
        /// Checksum of `retained` when it arrived; nil for a copy, which
        /// nobody else can touch.
        var retainedFingerprint: UInt64?
        /// Capture time of the last content frame or the stamp of the last
        /// hold, whichever came last: the next hold is due `heartbeat`
        /// seconds after it.
        var lastEncodedHostTime: CMTime?
        /// Whether `lastEncodedHostTime` is a hold's stamp, the one a late
        /// content frame can collide with.
        var lastEncodeWasHold = false
        var copyPool: CVPixelBufferPool?
        var copyPoolFormat: (OSType, Int, Int)?
        var source: HeartbeatHoldSource = .retainedSurface
    }

    private var phase = Phase.idle
    private var take: Take?
    private var activity: (any NSObjectProtocol)?
    private var abandonedTakeHandle: AbandonedTakeHandle?
    private var continuation: AsyncStream<CaptureStatus>.Continuation?
    private var finishTask: Task<RecordingManifest, any Error>?
    private var heartbeatTimer: (any DispatchSourceTimer)?
    private var statusTimer: (any DispatchSourceTimer)?
    private var heartbeat = Heartbeat()
    private var counters = CaptureStatistics()
    /// Set by the finish path once the stream has stopped: from then on no
    /// sample is taken, whatever its stamp. Until then samples stamped
    /// before the clock's stop are still welcome, the stream delivering
    /// them after the stop was asked for.
    private var samplesClosed = false
    /// A `stop` that arrived while the stream was still starting; honoured
    /// the moment the take is recording.
    private var pendingStop = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Makes a session on its own serial queue. `qos` is the queue's: samples
    /// are handled at it, so the default is the tier ScreenCaptureKit itself
    /// delivers at.
    public init(
        settings: CaptureSessionSettings = CaptureSessionSettings(), permissions: Permissions = .shared,
        qos: DispatchQoS = .userInitiated
    ) {
        self.settings = settings
        self.permissions = permissions
        queue = DispatchSerialQueue(label: settings.queueLabel, qos: qos)
    }

    deinit {
        // A session dropped without `stop` must not keep capturing: the
        // timers, the stream, the telemetry and the activity assertion all
        // go; the files stay for recovery, as after a crash.
        heartbeatTimer?.cancel()
        statusTimer?.cancel()
        guard let handle = abandonedTakeHandle else { return }
        handle.stream.stopCapture { _ in }
        handle.poller.stop()
        handle.focus?.stop()
        _ = handle.telemetry.stop()
        if let observer = handle.microphoneObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let activity = handle.activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// The counters as they stand, gathered from every part of the pipeline.
    public var statistics: CaptureStatistics {
        if let take { refreshCounters(from: take) }
        return counters
    }

    /// The package of the running take; nil before `start` and after the
    /// finish path.
    public var package: RecordingPackage? {
        take?.package
    }

    // MARK: Lifecycle

    /// Starts recording `request` into `package` (created if missing) and
    /// returns a stream of status snapshots that ends when the take does.
    /// Throws before anything is written when Screen Recording is not
    /// usable by this process (`ShareableContentError`), when the request
    /// names a microphone or a camera whose grant is not usable, when the
    /// source cannot be resolved, or when the volume has less than
    /// `settings.minimumFreeBytes` free; a package this call created is
    /// removed again when the preparation fails after it (a camera that
    /// cannot be opened, `CameraRecorderError`, fails the start too).
    /// Nothing here raises a permission prompt. The clock's origin, the
    /// recording's time zero, is taken once the pipeline is built and the
    /// camera runs, just before the stream starts.
    public func start(request: CaptureRequest, package: RecordingPackage) async throws -> AsyncStream<CaptureStatus> {
        guard case .idle = phase else { throw CaptureSessionError.alreadyStarted }
        phase = .starting
        let (status, continuation) = AsyncStream.makeStream(
            of: CaptureStatus.self, bufferingPolicy: .bufferingNewest(settings.statusBufferDepth))
        self.continuation = continuation
        // Reset before `prepare`, whose warnings (a clamped microphone, an
        // unreadable volume) belong to this take.
        counters = CaptureStatistics()
        defer { resumeStartWaiters() }
        do {
            let take = try await prepare(request: request, package: package)
            self.take = take
            heartbeat = Heartbeat(source: settings.holdSource == .copy ? .copy : .retainedSurface)
            counters.holdSourceInUse = heartbeat.source
            samplesClosed = false
            // Held for the take: no App Nap, no display sleep, and the I/O
            // priority the header reserves for audio and video recording.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: settings.activityReason)
            let handle = AbandonedTakeHandle(
                stream: take.stream, telemetry: take.telemetry, poller: take.poller, activity: activity)
            abandonedTakeHandle = handle
            // Made before the origin, on the main actor where AppKit posts
            // the activation notification; its rows go into the telemetry
            // log like the poller's, so one `events.json` carries all three
            // permission-free format-2 sources.
            let telemetry = take.telemetry
            let clock = take.clock
            let focus = await MainActor.run {
                FocusMonitor { observation in
                    if let event = observation.inputEvent(clock: clock) {
                        telemetry.append(event)
                    }
                }
            }
            take.focus = focus
            handle.focus = focus
            take.clock.start()
            take.telemetry.start(clock: take.clock)
            take.poller.start()
            // The log opens with a known focus: the frontmost application
            // at time zero, which no activation notification reports.
            if let current = await MainActor.run(body: { FocusMonitor.current() }),
                let event = current.inputEvent(clock: take.clock)
            {
                take.telemetry.append(event)
                take.focusEvents += 1
            }
            do {
                try await take.stream.startCapture()
            } catch {
                await abortStart(take, error: error)
                throw error
            }
            if take.synchronizationClock == nil {
                adoptSynchronizationClock(of: take)
            }
            phase = .recording
            startTimers(for: take)
            observeMicrophone(of: take)
            publish(.recording, take: take)
            if pendingStop {
                _ = beginFinish(reason: .userStopped)
            }
            return status
        } catch {
            phase = .failed(error)
            continuation.finish()
            self.continuation = nil
            throw error
        }
    }

    /// Ends the take and returns the final manifest once every file in the
    /// package is complete. The stop is the moment of the call, not the
    /// moment the files are done; a call while the stream is still starting
    /// waits for the start and stops the take the moment it records. When
    /// the stream has already stopped itself the finish path is already
    /// running and this waits for it; after it, the manifest comes back
    /// again. Throws `finishFailed` when the movie or the manifest could not
    /// be completed, with what was written.
    public func stop() async throws -> RecordingManifest {
        switch phase {
        case .idle:
            throw CaptureSessionError.notRecording
        case .starting:
            pendingStop = true
            await withCheckedContinuation { startWaiters.append($0) }
            return try await stop()
        case .recording:
            return try await beginFinish(reason: .userStopped).value
        case .finishing:
            guard let finishTask else { throw CaptureSessionError.notRecording }
            return try await finishTask.value
        case .finished(let manifest):
            return manifest
        case .failed(let error):
            throw error
        }
    }

    /// Pauses the clock at the moment of the call: the stream keeps running,
    /// and what it captures until `resume()` is left out of the take by its
    /// stamp (frames by the encoder, audio by the writer, events by the
    /// telemetry, camera frames by the camera recorder). Nothing happens
    /// when already paused. Throws `notRecording` unless a take is
    /// recording.
    public func pause() throws {
        guard case .recording = phase, let take else { throw CaptureSessionError.notRecording }
        guard !take.clock.isPaused else { return }
        take.clock.pause()
        take.pauseStartedAt = RecordingClock.hostTime()
        publish(.recording, take: take)
    }

    /// Closes the pause at the moment of the call. The next content frame
    /// opens a GOP, and the heartbeat, which encodes nothing inside a
    /// pause, re-arms at its next tick. Nothing happens when not paused.
    public func resume() throws {
        guard case .recording = phase, let take else { throw CaptureSessionError.notRecording }
        guard take.clock.isPaused else { return }
        take.clock.resume()
        if let openedAt = take.pauseStartedAt {
            take.pausedSeconds += (RecordingClock.hostTime() - openedAt).seconds
            take.pauseStartedAt = nil
        }
        publish(.recording, take: take)
    }

    /// Whether a recording take is paused.
    public var isPaused: Bool {
        take?.clock.isPaused ?? false
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Stream callbacks

    /// Takes one sample from the stream, on the actor's queue, from the shim.
    func handleSample(_ sample: StreamOutputShim.DeliveredSample) {
        guard let take, acceptsSamples else { return }
        // The stream names its clock once it runs, which can be before
        // `startCapture` returns: the first sample adopts it, so no stamp is
        // taken on one clock and the rest on another.
        if take.synchronizationClock == nil {
            adoptSynchronizationClock(of: take)
        }
        take.lastSampleArrival = RecordingClock.hostTime()
        switch sample.type {
        case .screen:
            handleScreen(sample.buffer, take: take)
        case .audio:
            handleAudio(sample.buffer, from: .system, take: take)
        case .microphone:
            noteMicrophoneBuffer(take: take)
            handleAudio(sample.buffer, from: .microphone, take: take)
        @unknown default:
            break
        }
    }

    /// The stream ended on its own: the display went away, the user stopped
    /// it from the system's recording indicator, or it failed. The take
    /// finishes through the same path as a Stop, with the reason recorded.
    func streamDidStop(with error: any Error) {
        guard case .recording = phase else { return }
        note(warning: "the stream stopped: \(error.localizedDescription)")
        _ = beginFinish(reason: Self.stopReason(for: error))
    }

    /// Every window the stream was sharing has closed (15.2). For a window
    /// take that is the source ending, and the take finishes as it would
    /// for a display that went away; a display or area stream has no
    /// windows to lose, so there the event is only noted.
    func streamDidBecomeInactive() {
        guard case .recording = phase, let take else { return }
        if case .window = take.request.source {
            note(warning: "the window being recorded closed")
            _ = beginFinish(reason: .sourceEnded)
        } else {
            note(warning: "the stream reported itself inactive")
        }
    }

    /// A shared window re-opened after all had closed (15.2); a window take
    /// has finished by then, so this is only noted.
    func streamDidBecomeActive() {
        guard case .recording = phase else { return }
        note(warning: "the stream reported itself active again")
    }

    /// The microphone went away mid-take. The take goes on: the writer
    /// pads the track with silence to the stop, and the status says what
    /// happened and when.
    private func microphoneDisconnected() {
        guard case .recording = phase, let take else { return }
        if case .disconnected = counters.microphone { return }
        let at = take.clock.elapsed.seconds
        counters.microphone = .disconnected(atRecordingSeconds: at)
        note(warning: "the microphone was disconnected at \(at) s; the rest of its track is silence")
        publish(.recording, take: take)
    }

    private func noteMicrophoneBuffer(take: Take) {
        take.lastMicrophoneArrival = RecordingClock.hostTime()
        counters.microphoneBuffers += 1
        switch counters.microphone {
        case .waiting:
            counters.microphone = .delivering
        case .stalled(let since):
            // Buffers again: the hole is the writer's to fill, from where
            // the last buffer ended to where this one starts.
            counters.microphone = .delivering
            note(warning: "the microphone resumed after stalling at \(since) s")
        case .disconnected:
            // A device re-plugged under the same identifier; the stream
            // picked it up, so the track continues.
            counters.microphone = .delivering
            note(warning: "the microphone is delivering again")
        case .notRecorded, .delivering:
            break
        }
    }

    /// Watches the microphone device for its disconnection; the notification
    /// arrives on a thread of AVFoundation's choosing and hops to the queue.
    private func observeMicrophone(of take: Take) {
        guard let device = take.microphoneDevice else { return }
        counters.microphone = .waiting
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.assumeIsolated { $0.microphoneDisconnected() }
            }
        }
        take.microphoneObserver = observer
        abandonedTakeHandle?.microphoneObserver = observer
    }

    /// At every status tick: a microphone whose buffers stopped while the
    /// stream kept delivering is reported stalled, once.
    private func checkMicrophone(of take: Take, now: CMTime) {
        guard take.request.capturesMicrophone, let lastSample = take.lastSampleArrival else { return }
        let timeout = settings.microphoneStallTimeout
        guard (now - lastSample).seconds < timeout else { return }
        let lastMicrophone = take.lastMicrophoneArrival ?? take.clock.origin
        guard lastMicrophone.isValid, (now - lastMicrophone).seconds >= timeout else { return }
        switch counters.microphone {
        case .waiting, .delivering:
            let since = take.clock.recordingTime(forHostTime: lastMicrophone)?.seconds ?? 0
            counters.microphone = .stalled(sinceRecordingSeconds: since)
            note(warning: "no microphone buffer since \(since) s; the span is silence in its track")
        case .notRecorded, .stalled, .disconnected:
            break
        }
    }

    /// Samples are taken while the take starts and records, and through the
    /// finish until the stream has stopped: the clock, stopped first, maps a
    /// stamp after the stop to nothing, so membership stays the stamp's
    /// (`RecordingClock`), and the buffer covering the stop, delivered only
    /// once complete, still reaches the file.
    private var acceptsSamples: Bool {
        switch phase {
        case .starting, .recording: true
        case .finishing: !samplesClosed
        case .idle, .finished, .failed: false
        }
    }

    private func handleScreen(_ sampleBuffer: CMSampleBuffer, take: Take) {
        let info = ScreenFrameInfo(sampleBuffer: sampleBuffer)
        var hostTime = hostClockTime(of: sampleBuffer.presentationTimeStamp, take: take)
        if info.carriesContent, heartbeat.lastEncodeWasHold, let last = heartbeat.lastEncodedHostTime, hostTime <= last
        {
            // Captured before the last hold's stamp and delivered after it,
            // past the delivery guard: nudged over the hold so the encoder
            // takes it, rather than indexed as complete and silently dropped.
            hostTime = last + CMTime(seconds: settings.heartbeatNudge, preferredTimescale: RecordingClock.timescale)
            counters.holdCollisions += 1
        }
        let time = take.indexer.record(info, presentationHostTime: hostTime)
        guard info.carriesContent, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !take.debugFactsWritten {
            take.debugFactsWritten = true
            writeDebugFacts(
                sampleBuffer, pixelBuffer: pixelBuffer, info: info, hostTime: hostTime, recordingTime: time, take: take)
        }
        // The encoder decides membership itself (a frame inside a pause is
        // skipped there), so it sees every content frame.
        do {
            try take.encoder.encode(pixelBuffer, hostTime: hostTime)
        } catch {
            note(warning: "encoding a frame failed: \(error.localizedDescription)")
        }
        retainForHeartbeat(pixelBuffer, capturedAt: hostTime)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, from source: RecordingAudioSource, take: Take) {
        var sample = sampleBuffer
        if take.convertsSampleTimes, let clock = take.synchronizationClock {
            do {
                sample = try Self.retimed(sampleBuffer, from: clock)
                counters.sampleTimesConverted += 1
            } catch {
                note(warning: "an audio buffer could not be retimed: \(error.localizedDescription)")
                return
            }
        }
        take.writer.appendAudio(sample, from: source)
    }

    /// A screen stamp on the host clock: the stream's own stamp unless the
    /// stream clock turned out to be another one.
    private func hostClockTime(of time: CMTime, take: Take) -> CMTime {
        guard take.convertsSampleTimes, let clock = take.synchronizationClock else { return time }
        counters.sampleTimesConverted += 1
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
    }

    private func adoptSynchronizationClock(of take: Take) {
        guard let clock = take.stream.synchronizationClock else { return }
        let isHostClock = CFEqual(clock, CMClockGetHostTimeClock())
        take.synchronizationClock = clock
        take.convertsSampleTimes = !isHostClock
        counters.synchronizationClockIsHostClock = isHostClock
        if !isHostClock {
            note(warning: "the stream clock is not the host clock; sample times are converted")
        }
    }

    // MARK: Heartbeat

    private func retainForHeartbeat(_ pixelBuffer: CVPixelBuffer, capturedAt hostTime: CMTime) {
        heartbeat.lastEncodedHostTime = hostTime
        heartbeat.lastEncodeWasHold = false
        switch heartbeat.source {
        case .copy:
            if let copy = copy(pixelBuffer) {
                heartbeat.retained = copy
                counters.copiedFrames += 1
            } else {
                // Better a hold from a surface that may change than none.
                heartbeat.retained = pixelBuffer
                counters.copyFailures += 1
            }
            heartbeat.retainedFingerprint = nil
        case .retainedSurface, .automatic:
            heartbeat.retained = pixelBuffer
            heartbeat.retainedFingerprint = Self.fingerprint(
                of: pixelBuffer, sampleBytes: settings.checksumSampleBytes, chunkBytes: settings.checksumChunkBytes)
        }
    }

    private func heartbeatTick() {
        guard let take, case .recording = phase, let timer = heartbeatTimer else { return }
        let interval = take.request.heartbeat
        // The hold is stamped a delivery guard before the tick: any content
        // frame captured before that stamp has been delivered by now, and
        // one captured after it is newer than the hold, so the encoder's
        // order holds either way.
        let stamp =
            RecordingClock.hostTime()
            - CMTime(seconds: settings.heartbeatDeliveryGuard, preferredTimescale: RecordingClock.timescale)
        if let last = heartbeat.lastEncodedHostTime {
            // Re-armed from the last encode rather than from the tick, so
            // the gap between frames on a static screen is the interval
            // itself and the keyframe cap fires where the plan says.
            let due = last.seconds + interval
            if stamp.seconds < due {
                timer.schedule(deadline: .now() + (due - stamp.seconds), leeway: heartbeatLeeway)
                return
            }
            encodeHold(at: stamp, take: take)
        }
        timer.schedule(deadline: .now() + interval, leeway: heartbeatLeeway)
    }

    private func encodeHold(at stamp: CMTime, take: Take) {
        heartbeat.lastEncodedHostTime = stamp
        heartbeat.lastEncodeWasHold = true
        // Nothing to hold yet, or the clock is paused: not a skip, just no frame.
        guard var retained = heartbeat.retained, let time = take.clock.recordingTime(forHostTime: stamp)?.seconds
        else { return }
        if heartbeat.source != .copy, let expected = heartbeat.retainedFingerprint {
            counters.retainedSurfaceChecks += 1
            let current = Self.fingerprint(
                of: retained, sampleBytes: settings.checksumSampleBytes, chunkBytes: settings.checksumChunkBytes)
            if current != expected {
                counters.retainedSurfaceMismatches += 1
                if settings.holdSource == .automatic {
                    // The pixels are no longer the frame that was captured;
                    // encoding them would put something else in the movie.
                    heartbeat.source = .copy
                    heartbeat.retained = nil
                    heartbeat.retainedFingerprint = nil
                    counters.holdSourceInUse = .copy
                    counters.holdsSkipped += 1
                    note(warning: "a retained surface changed under the heartbeat; frames are copied from now on")
                    return
                }
            } else if settings.holdSource == .automatic {
                // The surface is verified intact right now: copied once for
                // the stretch, so the next holds need neither the surface
                // nor a check, and a stretch is never left without a hold.
                if let copy = copy(retained) {
                    retained = copy
                    heartbeat.retained = copy
                    heartbeat.retainedFingerprint = nil
                    counters.copiedFrames += 1
                } else {
                    counters.copyFailures += 1
                }
            }
        }
        do {
            try take.encoder.encode(retained, hostTime: stamp)
            take.indexer.recordHold(at: time)
            counters.holdsEncoded += 1
        } catch {
            counters.holdsSkipped += 1
            note(warning: "a heartbeat frame could not be encoded: \(error.localizedDescription)")
        }
    }

    private var heartbeatLeeway: DispatchTimeInterval {
        .milliseconds(Int(settings.heartbeatLeeway * 1000))
    }

    /// The frame's pixels in a buffer of our own, from a pool matching the
    /// stream's format, with the colour attachments carried over.
    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = (
            CVPixelBufferGetPixelFormatType(source), CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source)
        )
        if heartbeat.copyPool == nil || heartbeat.copyPoolFormat.map({ $0 != format }) ?? true {
            heartbeat.copyPool = Self.makePool(for: format)
            heartbeat.copyPoolFormat = format
        }
        guard let pool = heartbeat.copyPool else { return nil }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
            let destination = created, Self.copyPixels(from: source, to: destination)
        else { return nil }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    // MARK: Timers

    private func startTimers(for take: Take) {
        let status = DispatchSource.makeTimerSource(queue: queue)
        status.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { $0.statusTick() }
        }
        status.schedule(
            deadline: .now() + settings.statusInterval, repeating: settings.statusInterval,
            leeway: .milliseconds(Int(settings.statusInterval * 100)))
        status.activate()
        statusTimer = status

        // The guard polls on the session's queue, so its reading enters the
        // actor the way the timers do.
        take.disk.start(queue: queue) { [weak self] reading in
            guard let self else { return }
            self.assumeIsolated { $0.diskTick(reading) }
        }

        guard take.request.heartbeat > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { $0.heartbeatTick() }
        }
        timer.schedule(deadline: .now() + take.request.heartbeat, leeway: heartbeatLeeway)
        timer.activate()
        heartbeatTimer = timer
    }

    private func statusTick() {
        guard let take, case .recording = phase else { return }
        if let failure = take.writer.failure {
            // Every frame from here on would be counted as dropped; what
            // the writer flushed is finalized by the finish path.
            note(warning: "the movie writer failed: \(failure.localizedDescription)")
            _ = beginFinish(reason: .writerFailed)
            return
        }
        if CGDisplayIsOnline(take.geometry.displayID) == 0 {
            // The display was disconnected under a stream that has not
            // stopped itself: the source is gone, so the take ends as if it
            // had.
            note(warning: "the display \(take.geometry.displayID) went offline")
            _ = beginFinish(reason: .sourceEnded)
            return
        }
        if let camera = take.camera, !take.cameraFailureNoted {
            // The camera is a companion: its failure is reported, and the
            // take goes on with the screen.
            let statistics = camera.statistics
            if let failure = statistics.sessionFailure ?? statistics.writer.failureDescription {
                take.cameraFailureNoted = true
                note(warning: "the camera stopped recording: \(failure)")
            }
        }
        checkMicrophone(of: take, now: RecordingClock.hostTime())
        publish(.recording, take: take)
    }

    /// One reading from the disk guard: the warning is noted once, the
    /// floor ends the take with `diskFull`.
    private func diskTick(_ reading: DiskSpaceReading) {
        guard let take, case .recording = phase else { return }
        counters.disk = reading
        counters.freeDiskBytes = reading.freeBytes
        switch reading.level {
        case .ok:
            break
        case .low:
            if !take.diskWarningNoted {
                take.diskWarningNoted = true
                let minutes = reading.remainingSeconds.map { Int($0 / 60) } ?? 0
                note(warning: "about \(minutes) min of disk space left at the current write rate")
                publish(.recording, take: take)
            }
        case .full:
            note(
                warning:
                    "free space fell to \(reading.freeBytes.map { $0 / 1_000_000 } ?? 0) MB against a floor of "
                    + "\(reading.floorBytes / 1_000_000) MB; the take stops")
            _ = beginFinish(reason: .diskFull)
        }
    }

    private func cancelTimers() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        statusTimer?.cancel()
        statusTimer = nil
        take?.disk.stop()
    }

    // MARK: Start

    private func prepare(request: CaptureRequest, package: RecordingPackage) async throws -> Take {
        // `ShareableContent.current` refuses to call ScreenCaptureKit unless
        // the grant is usable by this process, so nothing here can prompt.
        var content = try await ShareableContent.current(permissions: permissions)
        if case .window = request.source {
            // A window filter includes the one window; ours is not in it.
        } else if content.currentApplication == nil {
            // The display and area filters exclude our application, which
            // ScreenCaptureKit lists only once one of our windows (the
            // pill, shown just before this) has reached it.
            for _ in 0..<max(settings.ownApplicationListingRetries, 0) where content.currentApplication == nil {
                try await Task.sleep(for: .seconds(settings.ownApplicationListingInterval))
                content = try await ShareableContent.current(permissions: permissions)
            }
            if content.currentApplication == nil {
                note(warning: "ScreenCaptureKit lists no window of ours; our own windows may be in the capture")
            }
        }
        var microphone: (device: AVCaptureDevice, channelCount: Int)?
        if let microphoneID = request.microphoneID {
            let state = permissions.preflight(.microphone)
            guard state == .granted else { throw CaptureSessionError.microphoneNotGranted(state) }
            guard let device = AVCaptureDevice(uniqueID: microphoneID) else {
                throw CaptureSessionError.microphoneNotFound(microphoneID)
            }
            let native = Self.channelCount(of: device)
            let written = min(native, settings.microphoneMaximumChannels)
            if written < native {
                note(warning: "the microphone \(device.localizedName) has \(native) channels; its track has \(written)")
            }
            microphone = (device, written)
        }
        if request.camera != nil {
            // The recorder checks again before opening the device; this is
            // the refusal before the package exists.
            let state = permissions.preflight(.camera)
            guard state == .granted else { throw CameraRecorderError.notGranted(state) }
        }
        let built = try StreamConfigurationBuilder.build(request: request, content: content)
        let geometry = built.geometry

        // Checked before the package exists, so a refused take leaves no
        // empty package behind; the volume is the nearest existing ancestor's.
        if let available = Self.availableCapacity(at: package.url) {
            if available < settings.minimumFreeBytes {
                throw CaptureSessionError.insufficientDiskSpace(
                    availableBytes: available, requiredBytes: settings.minimumFreeBytes)
            }
        } else {
            note(warning: "the free space of the destination volume could not be read; the take starts unchecked")
        }
        let createdPackage = !package.exists
        if createdPackage {
            _ = try RecordingPackage.create(at: package.url)
        }
        // The clock is made here, unstarted, because the camera runs on it
        // from before the origin: its frames until `start()` are dropped.
        let clock = RecordingClock.unstarted()
        var camera: (recorder: CameraRecorder, track: CameraTrackInfo)?
        do {
            if let selection = request.camera {
                let recorder = CameraRecorder(settings: settings.camera, permissions: permissions)
                let track = try await recorder.start(
                    selection: selection, movieURL: package.cameraFragmentedMovieURL, clock: clock)
                camera = (recorder, track)
            }
            return try prepareTake(
                request: request, package: package, geometry: geometry, built: built, microphone: microphone,
                clock: clock, camera: camera)
        } catch {
            // Nothing was recorded, and a package without a manifest is one
            // the recovery scan can only skip.
            await camera?.recorder.cancel()
            if createdPackage {
                try? FileManager.default.removeItem(at: package.url)
            }
            throw error
        }
    }

    /// The pipeline over an existing package: on `clock`, unstarted until
    /// the stream is about to start, the writer, the index, the encoder and
    /// the telemetry; the stream; then the manifest and the project.
    private func prepareTake(
        request: CaptureRequest, package: RecordingPackage, geometry: CaptureGeometry, built: CaptureStream,
        microphone: (device: AVCaptureDevice, channelCount: Int)?, clock: RecordingClock,
        camera: (recorder: CameraRecorder, track: CameraTrackInfo)?
    ) throws -> Take {
        let recordingID = UUID()
        let createdAt = Date()
        var tracks: [RecordingAudioSource: RecordingWriterConfiguration.AudioTrack] = [:]
        if request.systemAudio {
            tracks[.system] = RecordingWriterConfiguration.AudioTrack(channelCount: request.stream.audioChannelCount)
        }
        if let microphone {
            tracks[.microphone] = RecordingWriterConfiguration.AudioTrack(channelCount: microphone.channelCount)
        }
        let writer = try RecordingWriter(
            movieURL: package.screenFragmentedMovieURL, clock: clock,
            configuration: RecordingWriterConfiguration(
                audioTracks: tracks, audioSampleRate: Double(request.stream.audioSampleRate)))
        let indexer = try ScreenFrameIndexer(
            url: package.frameIndexURL, recordingID: recordingID, clock: clock, settings: settings.frameIndex)
        let encoderConfiguration = VideoEncoderConfiguration(
            width: geometry.outputWidth, height: geometry.outputHeight, frameRate: request.frameRate,
            quality: request.tier)
        let encoder = try VideoEncoder(configuration: encoderConfiguration, clock: clock) { sample in
            // The writer counts a frame it could not take; the index gets a
            // gap at that frame's time, on VideoToolbox's thread, without a hop.
            let dropped = writer.statistics.videoDroppedNotReady
            writer.appendVideo(sample)
            if writer.statistics.videoDroppedNotReady > dropped {
                indexer.recordGap(at: sample.presentationTimeStamp.seconds)
            }
        }
        let displayBounds = CGDisplayBounds(geometry.displayID)
        let telemetry = InputTelemetryRecorder(
            displayBounds: displayBounds, captureRectPoints: geometry.captureRectPoints, displayID: geometry.displayID,
            pointPixelScale: geometry.pointPixelScale, recordingID: recordingID, persistenceURL: package.eventsURL,
            persistenceInterval: settings.telemetryPersistenceInterval)
        // The one window of a window take, every ordinary window otherwise;
        // its rows enter the telemetry log on the poller's own queue.
        let scope: WindowGeometryPoller.Scope
        if case .window(let id) = request.source {
            scope = .window(id)
        } else {
            scope = .display
        }
        let poller = WindowGeometryPoller(scope: scope, displayBounds: displayBounds, settings: settings.geometry) {
            event in
            if let row = event.inputEvent(clock: clock) {
                telemetry.append(row)
            }
        }

        let shim = StreamOutputShim(session: self)
        let events = StreamEventDelegate(session: self)
        let stream = SCStream(filter: built.filter, configuration: built.configuration, delegate: events)
        try stream.addStreamOutput(shim, type: .screen, sampleHandlerQueue: queue)
        if request.systemAudio {
            try stream.addStreamOutput(shim, type: .audio, sampleHandlerQueue: queue)
        }
        if microphone != nil {
            try stream.addStreamOutput(shim, type: .microphone, sampleHandlerQueue: queue)
        }

        // File order: the writer lays the tracks out system first.
        var audioTracks: [AudioTrackInfo] = []
        if request.systemAudio {
            audioTracks.append(AudioTrackInfo(source: .system, channelCount: request.stream.audioChannelCount))
        }
        if let microphone {
            audioTracks.append(
                AudioTrackInfo(
                    source: .microphone, channelCount: microphone.channelCount, deviceID: microphone.device.uniqueID,
                    deviceName: microphone.device.localizedName))
        }
        let manifest = RecordingManifest(
            recordingID: recordingID, createdAt: createdAt, source: built.source,
            content: ContentGeometry(
                displayID: geometry.displayID, displayBoundsPoints: PointRect(displayBounds),
                captureRectPoints: geometry.captureRectPoints, pointPixelScale: geometry.pointPixelScale),
            screen: ScreenTrackInfo(
                width: geometry.outputWidth, height: geometry.outputHeight, frameRate: request.frameRate,
                codec: encoder.codec.rawValue, audioTracks: audioTracks),
            camera: camera?.track,
            state: .inProgress)
        let store = ProjectStore(package: package)
        // Written before the stream starts: from here on a crash leaves an
        // `inProgress` manifest for recovery to find.
        try package.writeManifest(manifest)
        try store.save(Project(recording: manifest, kit: settings.kit))

        // The guard's estimate before it has measured anything: what the
        // encoders are configured to write, plus the AAC tracks.
        var nominalBitsPerSecond = Double(encoderConfiguration.averageBitRate(for: encoder.codec))
        if let selection = request.camera {
            nominalBitsPerSecond += Double(
                VideoEncoderConfiguration(
                    width: selection.maximumWidth, height: selection.maximumHeight, frameRate: selection.frameRate,
                    quality: selection.tier
                ).averageBitRate(for: encoder.codec))
        }
        nominalBitsPerSecond += tracks.values.reduce(0) { $0 + Double($1.bitRate) }
        let disk = DiskSpaceMonitor(
            url: package.url, settings: settings.disk, nominalBytesPerSecond: nominalBitsPerSecond / 8)

        return Take(
            request: request, package: package, geometry: geometry, clock: clock, encoder: encoder, writer: writer,
            indexer: indexer, telemetry: telemetry, poller: poller, store: store, stream: stream, shim: shim,
            events: events, streamSummary: StreamConfigurationBuilder.summary(of: built.configuration),
            camera: camera?.recorder, disk: disk, microphoneDevice: microphone?.device, manifest: manifest)
    }

    /// The stream refused to start: release what `prepare` made and leave a
    /// manifest that says so, since the package already exists.
    private func abortStart(_ take: Take, error: any Error) async {
        take.poller.stop()
        take.focus?.stop()
        _ = take.telemetry.stop()
        try? take.encoder.finish()
        // No frame was written, so this throws `noVideo` and removes the marker.
        _ = try? await take.writer.finish()
        // The camera may have recorded a few frames since the origin; they
        // are no take, so its files go too.
        await take.camera?.cancel()
        take.indexer.close()
        endActivity()
        abandonedTakeHandle = nil
        var manifest = take.manifest
        manifest.state = .failed
        manifest.stopReason = .streamFailed
        manifest.duration = 0
        manifest.camera = nil
        try? take.package.writeManifest(manifest)
        try? take.store.save(Project(recording: manifest, kit: settings.kit))
        self.take = nil
    }

    // MARK: Finish

    private func beginFinish(reason: StopReason) -> Task<RecordingManifest, any Error> {
        if let finishTask { return finishTask }
        phase = .finishing
        let task = Task { try await self.finish(reason: reason) }
        finishTask = task
        return task
    }

    private func finish(reason: StopReason) async throws -> RecordingManifest {
        guard let take else { throw CaptureSessionError.notRecording }
        cancelTimers()
        heartbeat.retained = nil
        heartbeat.copyPool = nil
        // The stop is now: samples stamped after it map to nothing, whatever
        // the stream still delivers while it winds down, and samples stamped
        // before it are still taken until the stream has stopped. A stop
        // inside a pause lands where the pause began, so the open pause is
        // no part of the take.
        take.clock.stop()
        take.pauseStartedAt = nil
        let elapsed = take.clock.elapsed.seconds
        publish(.finishing, take: take)

        do {
            try await take.stream.stopCapture()
        } catch {
            // After a system stop the stream is already stopped and says so.
            if reason == .userStopped {
                note(warning: "stopping the stream failed: \(error.localizedDescription)")
            }
        }
        samplesClosed = true
        if let observer = take.microphoneObserver {
            NotificationCenter.default.removeObserver(observer)
            take.microphoneObserver = nil
        }
        // Both stop before the telemetry so their last rows land in the
        // log that the telemetry's stop writes out.
        take.poller.stop()
        take.focus?.stop()
        _ = take.telemetry.stop()
        // The camera finishes beside the screen writer rather than after
        // it: both finalize a movie, and the camera light should go out
        // with the stop, not with the screen's export.
        let cameraFinish = take.camera.map { camera in Task.detached { await Self.finishCamera(camera) } }
        do {
            try take.encoder.finish()
        } catch {
            note(warning: "draining the encoder failed: \(error.localizedDescription)")
        }
        var failure: (any Error)?
        var salvagedSeconds: Double?
        do {
            _ = try await take.writer.finish()
        } catch {
            failure = error
            salvagedSeconds = await salvageMovie(of: take, after: error)
        }
        var cameraTrack: CameraTrackInfo?
        if let cameraFinish {
            let (track, warning) = await cameraFinish.value
            cameraTrack = track
            if let warning { note(warning: warning) }
        }
        take.indexer.close()
        writeCursorSprites(take)
        endActivity()
        abandonedTakeHandle = nil

        var manifest = take.manifest
        manifest.camera = cameraTrack
        if let salvagedSeconds {
            // The writer failed mid-take but what it had flushed plays: the
            // take ends as a recovered one, bounded by its shortest track.
            manifest.duration = salvagedSeconds
            manifest.stopReason = .writerFailed
            manifest.state = .recovered
            failure = nil
        } else {
            manifest.duration = elapsed
            manifest.stopReason = failure == nil ? reason : .writerFailed
            manifest.state = failure == nil ? .complete : .failed
        }
        do {
            try take.package.writeManifest(manifest)
            try take.store.save(Project(recording: manifest, kit: settings.kit))
        } catch {
            failure = failure ?? error
        }
        take.manifest = manifest
        refreshCounters(from: take)
        self.take = nil
        finishTask = nil

        if let failure {
            let error = CaptureSessionError.finishFailed(underlying: failure, manifest: manifest)
            phase = .failed(error)
            publish(
                .failed(manifest.stopReason ?? reason, message: failure.localizedDescription), elapsed: elapsed)
            throw error
        }
        phase = .finished(manifest)
        publish(.finished(manifest.stopReason ?? reason), elapsed: manifest.duration ?? elapsed)
        return manifest
    }

    /// The writer could not finish: what it had flushed to the fragmented
    /// movie is finalized now, as recovery would do at the next launch, and
    /// the playable length (the shortest track's end) comes back; nil when
    /// there was no movie or the rewrite failed too, in which case the files
    /// stay for recovery and the manifest says `failed`.
    private func salvageMovie(of take: Take, after error: any Error) async -> Double? {
        note(warning: "the movie writer failed: \(error.localizedDescription)")
        guard FileManager.default.fileExists(atPath: take.writer.movieURL.path) else { return nil }
        do {
            let movieURL = try await take.writer.salvage()
            guard let playable = try await RecoveryScanner.playableSeconds(of: movieURL), playable > 0 else {
                note(warning: "the salvaged movie holds no playable video")
                return nil
            }
            note(warning: "the movie was finalized from what reached the disk: \(playable) s play")
            return playable
        } catch {
            note(warning: "the movie could not be finalized after the failure: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stops the camera after the clock and returns what the manifest
    /// records of its track: the device, with the size and codec of the
    /// encoder that ran, once `camera.mp4` is complete; nil with a warning
    /// when the camera could not be finished, which is not a failure of
    /// the take (its fragmented movie, if any, stays for recovery).
    private nonisolated static func finishCamera(_ camera: CameraRecorder) async -> (CameraTrackInfo?, String?) {
        let track = await camera.track
        do {
            _ = try await camera.stop()
            return (track, nil)
        } catch {
            return (nil, "the camera movie could not be finished: \(error.localizedDescription)")
        }
    }

    /// Writes every cursor shape the telemetry saw as
    /// `cursors/<CursorShape.id>.png`, the files `CursorAtlas` reads. The
    /// folder is made here too: `RecordingPackage.create` makes it, but a
    /// take into an existing package may find it missing.
    private func writeCursorSprites(_ take: Take) {
        do {
            try FileManager.default.createDirectory(
                at: take.package.cursorsDirectory, withIntermediateDirectories: true)
        } catch {
            note(warning: "the cursors folder could not be created: \(error.localizedDescription)")
        }
        for (id, png) in take.telemetry.sprites() {
            do {
                try png.write(to: take.package.cursorSpriteURL(shapeID: id), options: .atomic)
                counters.cursorSpritesWritten += 1
            } catch {
                note(warning: "the cursor sprite \(id) could not be written: \(error.localizedDescription)")
            }
        }
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    // MARK: Status

    private func publish(_ phase: CaptureStatus.Phase, take: Take) {
        refreshCounters(from: take)
        publish(phase, elapsed: take.clock.elapsed.seconds, isPaused: take.clock.isPaused)
    }

    private func publish(_ phase: CaptureStatus.Phase, elapsed: Double, isPaused: Bool = false) {
        guard let continuation else { return }
        continuation.yield(
            CaptureStatus(phase: phase, elapsedSeconds: elapsed, statistics: counters, isPaused: isPaused))
        switch phase {
        case .finished, .failed:
            continuation.finish()
            self.continuation = nil
        case .recording, .finishing:
            break
        }
    }

    private func refreshCounters(from take: Take) {
        counters.frames = take.indexer.statistics
        counters.encoder = take.encoder.statistics
        counters.writer = take.writer.statistics
        counters.telemetry = take.telemetry.statistics
        counters.geometry = take.poller.statistics
        counters.focusEvents = take.focusEvents + (take.focus?.observationCount ?? 0)
        counters.camera = take.camera?.statistics
        counters.disk = take.disk.reading
        counters.freeDiskBytes = counters.disk?.freeBytes ?? Self.availableCapacity(at: take.package.url)
        counters.pauses = take.clock.completedPauses
        counters.pausedSeconds = take.pausedSeconds
        if let openedAt = take.pauseStartedAt {
            counters.pausedSeconds += (RecordingClock.hostTime() - openedAt).seconds
        }
        var dropped = CaptureDropCounters()
        dropped.encoderDropped = counters.encoder.droppedFrames
        dropped.writerNotReady = counters.writer.videoDroppedNotReady
        dropped.writerNonIncreasing = counters.writer.videoDroppedNonIncreasing
        dropped.gapLines = counters.frames.gaps
        dropped.audioBuffers = counters.writer.audioDropped
        if let camera = counters.camera {
            dropped.cameraFrames =
                camera.framesDroppedByOutput + camera.encoder.droppedFrames + camera.writer.videoDroppedNotReady
        }
        counters.dropped = dropped
    }

    private func note(warning: String) {
        guard counters.warnings.count < settings.maximumWarnings else { return }
        counters.warnings.append(warning)
    }

    // MARK: S1 facts

    /// `recording/capture-debug.json`: what spike S1 needs to settle the
    /// colour tags (`CaptureRequest.colorTags`) and the clock question, taken
    /// from the first content frame.
    private func writeDebugFacts(
        _ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer, info: ScreenFrameInfo, hostTime: CMTime,
        recordingTime: Double?, take: Take
    ) {
        let now = RecordingClock.hostTime()
        let host = CMClockGetHostTimeClock()
        var stream: [String: JSONValue] = [
            "sampleTimesConvertedToHostClock": .bool(take.convertsSampleTimes),
            "configuration": Self.json(take.streamSummary),
        ]
        if let clock = take.synchronizationClock ?? take.stream.synchronizationClock {
            let clockNow = CMClockGetTime(clock)
            stream["synchronizationClockPresent"] = true
            stream["synchronizationClockIsHostClock"] = .bool(CFEqual(clock, host))
            stream["synchronizationClockMightDrift"] = .bool(CMSyncMightDrift(clock, host))
            stream["synchronizationClockOffsetSeconds"] = .number(
                CMSyncConvertTime(clockNow, from: clock, to: host).seconds - clockNow.seconds)
            stream["synchronizationClockNowSeconds"] = .number(clockNow.seconds)
            stream["hostClockNowSeconds"] = .number(now.seconds)
        } else {
            stream["synchronizationClockPresent"] = false
        }

        var frame: [String: JSONValue] = [
            "status": .string(info.status.rawValue),
            "rawStatus": info.rawStatus.map { .integer(Int64($0)) } ?? .null,
            "presentationHostSeconds": .number(hostTime.seconds),
            "presentationStreamSeconds": .number(sampleBuffer.presentationTimeStamp.seconds),
            "recordingTimeSeconds": recordingTime.map { .number($0) } ?? .null,
            "originHostSeconds": .number(take.clock.origin.seconds),
            "deliveryLatencySeconds": .number(now.seconds - hostTime.seconds),
            "dirtyRectCount": info.dirtyRectCount.map { .integer(Int64($0)) } ?? .null,
            "contentScale": info.contentScale.map { .number($0) } ?? .null,
            "scaleFactor": info.scaleFactor.map { .number($0) } ?? .null,
            "contentRect": Self.json(info.contentRect),
            "screenRect": Self.json(info.screenRect),
            "boundingRect": Self.json(info.boundingRect),
        ]
        if let display = info.displayHostTime {
            frame["displayHostSeconds"] = .number(display.seconds)
            frame["presentationMinusDisplaySeconds"] = .number(hostTime.seconds - display.seconds)
        }

        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let planes = planar ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1
        var buffer: [String: JSONValue] = [
            "pixelFormat": .string(Self.fourCharacterCode(CVPixelBufferGetPixelFormatType(pixelBuffer))),
            "width": .integer(Int64(CVPixelBufferGetWidth(pixelBuffer))),
            "height": .integer(Int64(CVPixelBufferGetHeight(pixelBuffer))),
            "isPlanar": .bool(planar),
            "planeCount": .integer(Int64(planes)),
            "bytesPerRow": .array(
                (0..<planes).map {
                    .integer(
                        Int64(
                            planar
                                ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, $0)
                                : CVPixelBufferGetBytesPerRow(pixelBuffer)))
                }),
            "isIOSurfaceBacked": .bool(CVPixelBufferGetIOSurface(pixelBuffer) != nil),
            "attachmentsShouldPropagate": Self.json(CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)),
            "attachmentsShouldNotPropagate": Self.json(CVBufferCopyAttachments(pixelBuffer, .shouldNotPropagate)),
        ]
        if let format = sampleBuffer.formatDescription {
            buffer["formatDescriptionMediaSubType"] = .string(
                Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType(format)))
            buffer["formatDescriptionExtensions"] = Self.json(CMFormatDescriptionGetExtensions(format))
        }

        let document: JSONValue = .object([
            "formatVersion": 1,
            "writtenAt": .string(PackageJSON.string(from: Date())),
            "recordingID": .string(take.manifest.recordingID.uuidString),
            "stream": .object(stream),
            "firstScreenFrame": .object(frame),
            "pixelBuffer": .object(buffer),
        ])
        let url = take.package.recordingDirectory.appendingPathComponent(settings.debugFileName)
        do {
            try PackageJSON.encode(document, prettyPrinted: true).write(to: url, options: .atomic)
        } catch {
            note(warning: "the capture facts could not be written: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private static func stopReason(for error: any Error) -> StopReason {
        guard let streamError = error as? SCStreamError else { return .streamFailed }
        switch streamError.code {
        case .userStopped: return .userStopped
        case .systemStoppedStream: return .sourceEnded
        default: return .streamFailed
        }
    }

    /// Free space on the volume holding `url`, as the disk guard reads it
    /// (`DiskSpaceMonitor.freeBytes(at:)`: the capacity for important usage,
    /// or the plain one where a volume reports that as zero, as disk images
    /// do), so the preflight and the guard agree; when `url` does not exist
    /// yet, the volume of its nearest existing ancestor (a first take's
    /// `~/Movies/Cutscene` is made by the take itself). Nil when the volume
    /// does not say.
    public static func availableCapacity(at url: URL) -> Int64? {
        DiskSpaceMonitor.freeBytes(at: url)
    }

    /// Channels of the microphone's active format, the count its track in
    /// the file gets; one when the device does not say.
    private static func channelCount(of device: AVCaptureDevice) -> Int {
        let description = device.activeFormat.formatDescription.audioStreamBasicDescription
        return max(1, Int(description?.mChannelsPerFrame ?? 1))
    }

    /// `sample` with its stamp moved from `clock` to the host clock; the data
    /// is shared.
    private static func retimed(_ sample: CMSampleBuffer, from clock: CMClock) throws -> CMSampleBuffer {
        let timing = try sample.sampleTimingInfo(at: 0)
        let converted = CMSyncConvertTime(timing.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        return try CMSampleBuffer(
            copying: sample,
            withNewTiming: [
                CMSampleTimingInfo(
                    duration: timing.duration, presentationTimeStamp: converted, decodeTimeStamp: .invalid)
            ])
    }

    /// FNV-1a over `sampleBytes` bytes of the frame, spread evenly over every
    /// plane in `chunkBytes` runs. Only pixel columns are sampled, never the
    /// row padding: every pixel format writes at least one byte per column,
    /// so the first `width` bytes of a row are always real content. Nil when
    /// the buffer cannot be locked.
    static func fingerprint(of buffer: CVPixelBuffer, sampleBytes: Int, chunkBytes: Int) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let planes = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        guard planes > 0 else { return nil }
        let chunk = max(MemoryLayout<UInt64>.size, chunkBytes)
        let chunksPerPlane = max(1, sampleBytes / chunk / planes)
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for plane in 0..<planes {
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            let rowBytes =
                planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let columns = min(
                rowBytes, planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer))
            guard let base, rows > 0, columns > 0 else { continue }
            hash = (hash ^ UInt64(rows)) &* prime
            hash = (hash ^ UInt64(columns)) &* prime
            let length = min(chunk, columns)
            let span = rows * columns
            for index in 0..<chunksPerPlane {
                let position = span / chunksPerPlane * index
                let row = min(position / columns, rows - 1)
                let column = min(position % columns, columns - length)
                let start = base.advanced(by: row * rowBytes + column)
                // Whole words where the run allows: eight bytes per step
                // keeps the hash cheap in a debug build too.
                var offset = 0
                while offset + MemoryLayout<UInt64>.size <= length {
                    hash = (hash ^ start.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) &* prime
                    offset += MemoryLayout<UInt64>.size
                }
                while offset < length {
                    hash = (hash ^ UInt64(start.load(fromByteOffset: offset, as: UInt8.self))) &* prime
                    offset += 1
                }
            }
        }
        return hash
    }

    static func makePool(for format: (OSType, Int, Int)) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.0,
            kCVPixelBufferWidthKey: format.1,
            kCVPixelBufferHeightKey: format.2,
            // IOSurface backing, as the stream's own buffers have, so the
            // hardware encoder reads the copy without another one.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }

    /// Copies every plane row by row; the two buffers may differ in pitch.
    static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planar = CVPixelBufferIsPlanar(source)
        let planes = planar ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planes {
            guard
                let from = planar
                    ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                let to = planar
                    ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
            else { return false }
            let rows = min(
                planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source),
                planar ? CVPixelBufferGetHeightOfPlane(destination, plane) : CVPixelBufferGetHeight(destination))
            let fromPitch =
                planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toPitch =
                planar
                ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let bytes = min(fromPitch, toPitch)
            if fromPitch == toPitch {
                to.copyMemory(from: from, byteCount: rows * bytes)
            } else {
                for row in 0..<rows {
                    to.advanced(by: row * toPitch).copyMemory(
                        from: from.advanced(by: row * fromPitch), byteCount: bytes)
                }
            }
        }
        return true
    }

    private static func fourCharacterCode(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func json(_ rect: PointRect?) -> JSONValue {
        guard let rect else { return .null }
        return .array([.number(rect.x), .number(rect.y), .number(rect.width), .number(rect.height)])
    }

    private static func json(_ summary: StreamSummary) -> JSONValue {
        .object([
            "width": .integer(Int64(summary.width)),
            "height": .integer(Int64(summary.height)),
            "pixelFormat": .string(summary.pixelFormatName),
            "colorSpaceName": .string(summary.colorSpaceName),
            "colorMatrix": .string(summary.colorMatrix),
            "minimumFrameIntervalSeconds": .number(summary.minimumFrameInterval.seconds),
            "queueDepth": .integer(Int64(summary.queueDepth)),
            "capturesAudio": .bool(summary.capturesAudio),
            "sampleRate": .integer(Int64(summary.sampleRate)),
            "channelCount": .integer(Int64(summary.channelCount)),
            "captureMicrophone": .bool(summary.captureMicrophone),
            "microphoneCaptureDeviceID": summary.microphoneCaptureDeviceID.map { .string($0) } ?? .null,
        ])
    }

    /// A Core Foundation attachment tree as JSON, so the facts file shows
    /// the tags as they are: strings, numbers and booleans as themselves,
    /// a colour space by its name, data as base64, anything else described.
    private static func json(_ value: Any?) -> JSONValue {
        guard let value else { return .null }
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            switch UInt8(number.objCType.pointee) {
            case UInt8(ascii: "f"), UInt8(ascii: "d"):
                return .number(number.doubleValue)
            default:
                return .integer(number.int64Value)
            }
        case let data as Data:
            return .object([
                "byteCount": .integer(Int64(data.count)), "base64": .string(data.base64EncodedString()),
            ])
        case let dictionary as NSDictionary:
            var object: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                object[String(describing: key)] = json(element)
            }
            return .object(object)
        case let array as NSArray:
            return .array(array.map { json($0) })
        default:
            let object = value as AnyObject
            if CFGetTypeID(object) == CGColorSpace.typeID {
                let space = unsafeDowncast(object, to: CGColorSpace.self)
                return .string((space.name as String?) ?? "CGColorSpace")
            }
            return .string(String(describing: value))
        }
    }
}
