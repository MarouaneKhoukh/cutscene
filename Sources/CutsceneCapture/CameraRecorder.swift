import AVFoundation
import CoreMedia
import CoreVideo
import CutsceneCore
import Foundation
import Synchronization

/// A camera as a menu can list it: the `Sendable` part of an
/// `AVCaptureDevice`. Discovery never prompts; only capturing from a device
/// does, and `CameraRecorder.start` refuses to without the grant.
public struct CameraSummary: Sendable, Equatable, Identifiable {
    /// `AVCaptureDevice.uniqueID`, what `CaptureRequest.CameraSelection` names.
    public var id: String
    public var name: String
    /// A built-in camera faces the user, so the kit mirrors it by default
    /// (`CameraTrackInfo.isBuiltIn`).
    public var isBuiltIn: Bool
    /// An iPhone used as a camera (`AVCaptureDevice.isContinuityCamera`),
    /// listed only in a bundle carrying `NSCameraUseContinuityCameraDeviceType`.
    public var isContinuityCamera: Bool
    /// The raw `AVCaptureDevice.DeviceType`, for reports.
    public var deviceType: String

    public init(id: String, name: String, isBuiltIn: Bool, isContinuityCamera: Bool, deviceType: String) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isContinuityCamera = isContinuityCamera
        self.deviceType = deviceType
    }
}

/// The numbers the camera path is tuned with that are not a user's choice
/// (the size cap, rate and tier are the request's `CameraSelection`).
public struct CameraRecorderSettings: Sendable, Equatable {
    /// `'420v'`, the layout the hardware encoder takes without a conversion
    /// pass and the one the compositor reads natively (ARCHITECTURE §2); the
    /// output converts from the device's own format when it must. When the
    /// output cannot deliver it, `fallbackPixelFormat` is tried, then the
    /// output's default.
    public var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    public var fallbackPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames`: a frame the
    /// encoder cannot take in time is dropped by the output rather than
    /// queued, so the camera track never falls behind the clock and the
    /// device's buffer pool never starves on frames we hold.
    public var alwaysDiscardsLateVideoFrames = true
    /// Label of the recorder's serial queue, the actor's executor, where the
    /// blocking `startRunning` and `stopRunning` run.
    public var queueLabel = "app.cutscene.capture.camera"
    /// Label of the queue the output delivers frames on: separate from the
    /// executor so a frame is encoded or dropped where it arrives while the
    /// actor may be inside a blocking session call.
    public var deliveryQueueLabel = "app.cutscene.capture.camera.frames"
    /// Warnings kept in the statistics; the first ones are the useful ones.
    public var maximumWarnings = 32

    public init() {}
}

/// Counters for the pill and the end-of-take report.
public struct CameraRecorderStatistics: Sendable, Equatable {
    /// Frames handed to the encoder: captured at or after the origin, outside
    /// a pause and before the stop.
    public var framesEncoded = 0
    /// Frames captured before the clock's origin: the camera runs before
    /// the take starts so its first frame lands within one interval of the
    /// origin, and these are the price. Dropped on the delivery queue,
    /// never retained.
    public var framesBeforeOrigin = 0
    /// Frames captured during a pause or after the stop.
    public var framesOutsideRecording = 0
    /// Frames the output discarded because the delivery queue was busy
    /// (`alwaysDiscardsLateVideoFrames`), or for another reason it reports.
    public var framesDroppedByOutput = 0
    /// Frames delivered without pixels, which no camera should produce.
    public var framesWithoutPixels = 0
    /// Frames the encoder refused with an error.
    public var encodeFailures = 0
    /// Whether `AVCaptureSession.synchronizationClock` is the host clock; nil
    /// until the session reports one.
    public var synchronizationClockIsHostClock: Bool?
    /// Stamps converted from the session clock to the host clock, which
    /// happens only when the two differ.
    public var sampleTimesConverted = 0
    /// Recording time of the first and last frame encoded, in seconds; what
    /// the spike checks against one frame interval.
    public var firstFrameRecordingSeconds: Double?
    public var lastFrameRecordingSeconds: Double?
    /// Host time of the first encoded frame, for the report.
    public var firstFrameHostSeconds: Double?
    public var encoder = VideoEncoderStatistics()
    public var writer = RecordingWriterStatistics()
    /// Set when the session reported a runtime error or the device went
    /// away; the recording keeps what it had.
    public var sessionFailure: String?
    public var warnings: [String] = []

    public init() {}
}

public enum CameraRecorderError: LocalizedError {
    /// The camera grant is not usable, and the recorder never prompts.
    case notGranted(PermissionState)
    case deviceNotFound(String)
    /// No format of the device supports the requested frame rate.
    case noUsableFormat(deviceName: String, frameRate: Int)
    case inputRejected(deviceName: String)
    case outputRejected
    /// `lockForConfiguration` failed, so the format and rate could not be set.
    case configurationFailed(deviceName: String, underlying: any Error)
    /// A recorder records one take; make another for the next.
    case alreadyStarted
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .notGranted(let state):
            "Camera access is \(state.rawValue), so the camera cannot be recorded."
        case .deviceNotFound(let id):
            "No camera with the identifier \(id) is connected."
        case .noUsableFormat(let name, let rate):
            "The camera \(name) has no format that delivers \(rate) frames per second."
        case .inputRejected(let name):
            "The capture session refused the camera \(name) as an input."
        case .outputRejected:
            "The capture session refused the video data output."
        case .configurationFailed(let name, let error):
            "The camera \(name) could not be configured: \(error.localizedDescription)"
        case .alreadyStarted:
            "This camera recorder has already recorded a take."
        case .notStarted:
            "The camera recorder is not running."
        }
    }
}

/// One format a camera offers, reduced to what the choice depends on, so the
/// rule is a pure function a spike can exercise without a device.
public struct CameraFormatCandidate: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixelFormat: OSType
    /// Frame-rate ranges the format supports (`videoSupportedFrameRateRanges`).
    public var frameRateRanges: [ClosedRange<Double>]

    public init(width: Int, height: Int, pixelFormat: OSType, frameRateRanges: [ClosedRange<Double>]) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.frameRateRanges = frameRateRanges
    }

    /// Whether a constant `frameRate` can be set on this format: some range
    /// must contain it, since setting a duration outside every range throws
    /// an Objective-C exception no `try` catches.
    public func supports(frameRate: Int) -> Bool {
        frameRateRanges.contains { $0.contains(Double(frameRate)) }
    }
}

/// Records one camera beside the screen (ARCHITECTURE §2 "Camera"): an
/// `AVCaptureSession` on a device found through `DiscoverySession` (built-in,
/// external and Continuity cameras), set to the largest format within
/// `CameraSelection.maximumWidth × maximumHeight` at `CameraSelection.frameRate`,
/// an `AVCaptureVideoDataOutput` delivering `'420v'` with late frames
/// discarded, and a second `VideoEncoder` + `RecordingWriter` pair on the
/// take's own `RecordingClock`, so `camera.mp4` shares the screen movie's
/// time zero: media time 0 is the clock's origin and an event at 3.2 s in the
/// log is at 3.2 s in both movies.
///
/// The actor runs on a `DispatchSerialQueue` of its own, where the blocking
/// `startRunning` and `stopRunning` belong; frames arrive on a second serial
/// queue and are consumed there by a lock-guarded sink: the stamp is moved
/// from `AVCaptureSession.synchronizationClock` to the host clock with
/// `CMSyncConvertTime` when the two differ, a frame captured before the
/// clock's origin (or inside a pause, or after the stop) is counted and
/// dropped on that queue without ever being retained, since buffers held
/// back starve the device's pool and the output starts dropping, and every
/// other frame goes to the encoder with its capture stamp.
///
/// `start` runs the session before the caller takes the clock's origin, so
/// the camera has warmed up and its first recorded frame lands within one
/// frame interval of time zero; the frames before it are the
/// `framesBeforeOrigin` of the statistics. `stop` is called after the
/// clock's stop: the session stops, the encoder drains and the writer
/// finishes the fragmented `camera.mov` into `camera.mp4`, with the same
/// `.needsFinalize` marker the screen movie has, so a crash leaves it to
/// `RecoveryScanner`. A recorder records one take.
public actor CameraRecorder {
    /// The executor.
    public nonisolated let queue: DispatchSerialQueue
    public nonisolated let settings: CameraRecorderSettings
    public nonisolated let permissions: Permissions

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The device types a camera menu lists: the Mac's own camera, USB and
    /// other external cameras, and an iPhone as a Continuity Camera (14.0,
    /// shown only to a bundle with `NSCameraUseContinuityCameraDeviceType`).
    public static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .external, .continuityCamera,
    ]

    /// `AVCaptureSessionPresetInputPriority`, which the macOS SDK leaves
    /// undeclared; see `start`.
    static let inputPriorityPresetName = "AVCaptureSessionPresetInputPriority"

    private enum Phase {
        case idle
        case running(Take)
        case stopping
        case stopped
        case failed
    }

    /// Everything one take owns; never leaves the actor.
    private final class Take {
        let session: AVCaptureSession
        let device: AVCaptureDevice
        let output: AVCaptureVideoDataOutput
        let sink: FrameSink
        let deliveryQueue: DispatchQueue
        let track: CameraTrackInfo
        var observers: [any NSObjectProtocol] = []

        init(
            session: AVCaptureSession, device: AVCaptureDevice, output: AVCaptureVideoDataOutput, sink: FrameSink,
            deliveryQueue: DispatchQueue, track: CameraTrackInfo
        ) {
            self.session = session
            self.device = device
            self.output = output
            self.sink = sink
            self.deliveryQueue = deliveryQueue
            self.track = track
        }
    }

    /// What `deinit` needs to stop a session the recorder was dropped with:
    /// an actor's `deinit` is nonisolated and may read only `Sendable`
    /// state. `AVCaptureSession` is not, so it is boxed; nothing but
    /// `deinit` reads the box, and the session stays the take's.
    private final class AbandonedSessionHandle: @unchecked Sendable {
        let session: AVCaptureSession

        init(session: AVCaptureSession) {
            self.session = session
        }
    }

    private var phase = Phase.idle
    /// The take's sink, readable without isolation so the session's status
    /// tick can gather the camera's counters alongside the screen's.
    private nonisolated let sinkBox = Mutex<FrameSink?>(nil)
    private nonisolated let abandoned = Mutex<AbandonedSessionHandle?>(nil)

    /// Makes a recorder on its own serial queue. `qos` is the queue's, and
    /// the delivery queue's.
    public init(
        settings: CameraRecorderSettings = CameraRecorderSettings(), permissions: Permissions = .shared,
        qos: DispatchQoS = .userInitiated
    ) {
        self.settings = settings
        self.permissions = permissions
        queue = DispatchSerialQueue(label: settings.queueLabel, qos: qos)
    }

    deinit {
        // A recorder dropped without `stop` must not keep the camera light
        // on; the files stay for recovery, as after a crash.
        abandoned.withLock { $0?.session.stopRunning() }
    }

    /// The counters as they stand; empty before `start`.
    public nonisolated var statistics: CameraRecorderStatistics {
        sinkBox.withLock { $0?.statistics } ?? CameraRecorderStatistics()
    }

    /// The track as the manifest describes it, with the size and codec of
    /// the encoder in use (the sink replaces its encoder when the device
    /// delivers another size than the chosen format's); nil before `start`
    /// and after the take ends. Read it again at stop for the final manifest.
    public var track: CameraTrackInfo? {
        guard case .running(let take) = phase else { return nil }
        var track = take.track
        let configuration = take.sink.encoder.configuration
        track.width = configuration.width
        track.height = configuration.height
        track.codec = take.sink.encoder.codec.rawValue
        return track
    }

    // MARK: Discovery

    /// The cameras a menu can offer, built-in first. Listing devices never
    /// prompts; capturing does, and only `start` captures. A process without
    /// `NSCameraUseContinuityCameraDeviceType` in its Info.plist (the spike
    /// binary) does not see Continuity Cameras.
    public nonisolated static func availableCameras() -> [CameraSummary] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices.map(summary(of:))
    }

    /// The camera `uniqueID` names, or nil when none is connected.
    public nonisolated static func camera(id: String) -> CameraSummary? {
        AVCaptureDevice(uniqueID: id).map(summary(of:))
    }

    private nonisolated static func summary(of device: AVCaptureDevice) -> CameraSummary {
        CameraSummary(
            id: device.uniqueID, name: device.localizedName, isBuiltIn: isBuiltIn(device),
            isContinuityCamera: device.isContinuityCamera, deviceType: device.deviceType.rawValue)
    }

    /// Whether the device is the Mac's own camera. Only the wide-angle type
    /// counts: an external or Continuity camera can face anywhere.
    private nonisolated static func isBuiltIn(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInWideAngleCamera
    }

    // MARK: Format choice

    /// Which of `candidates` to record, or nil when none supports
    /// `selection.frameRate`: the largest format within the selection's size
    /// cap, preferring `preferredPixelFormat` at equal size (no conversion
    /// pass in the output), then the earlier one; when every format is
    /// larger than the cap, the smallest, which the encoder takes as it is
    /// (the bit rate scales with it) and the caller reports.
    public static func chooseFormat(
        from candidates: [CameraFormatCandidate], selection: CaptureRequest.CameraSelection,
        preferredPixelFormat: OSType
    ) -> Int? {
        let usable = candidates.indices.filter { candidates[$0].supports(frameRate: selection.frameRate) }
        guard !usable.isEmpty else { return nil }
        let area = { (index: Int) in candidates[index].width * candidates[index].height }
        // The tie-breakers rank a preferred format and an earlier index
        // higher, so one `max` serves the fitting case; the oversized case
        // takes the smallest area with the same two tie-breakers.
        let rank = { (index: Int, largestFirst: Bool) in
            (
                largestFirst ? area(index) : -area(index),
                candidates[index].pixelFormat == preferredPixelFormat ? 1 : 0, -index
            )
        }
        let fitting = usable.filter {
            candidates[$0].width <= selection.maximumWidth && candidates[$0].height <= selection.maximumHeight
        }
        if !fitting.isEmpty {
            return fitting.max { rank($0, true) < rank($1, true) }
        }
        return usable.max { rank($0, false) < rank($1, false) }
    }

    // MARK: Lifecycle

    /// Opens the camera `selection` names, builds the encoder and the writer
    /// on `clock` for the fragmented movie at `movieURL` (the MP4 and the
    /// marker take their names from it, as for the screen) and starts the
    /// session, blocking until it runs. Returns what the manifest records
    /// about the track. Throws `notGranted` before any AVFoundation call
    /// that could prompt when the camera grant is not usable; nothing here
    /// prompts. Call it before the clock's `start()`: frames until then are
    /// dropped, and the first one after it is recorded.
    public func start(selection: CaptureRequest.CameraSelection, movieURL: URL, clock: RecordingClock) throws
        -> CameraTrackInfo
    {
        guard case .idle = phase else { throw CameraRecorderError.alreadyStarted }
        let state = permissions.preflight(.camera)
        guard state == .granted else { throw CameraRecorderError.notGranted(state) }
        guard let device = AVCaptureDevice(uniqueID: selection.deviceID) else {
            throw CameraRecorderError.deviceNotFound(selection.deviceID)
        }
        var warnings: [String] = []

        let formats = device.formats
        let candidates = formats.map(Self.candidate(of:))
        guard
            let chosen = Self.chooseFormat(
                from: candidates, selection: selection, preferredPixelFormat: settings.pixelFormat)
        else {
            throw CameraRecorderError.noUsableFormat(deviceName: device.localizedName, frameRate: selection.frameRate)
        }
        let format = formats[chosen]
        let candidate = candidates[chosen]
        if candidate.width > selection.maximumWidth || candidate.height > selection.maximumHeight {
            warnings.append(
                "every format of \(device.localizedName) exceeds \(selection.maximumWidth)×\(selection.maximumHeight); "
                    + "recording \(candidate.width)×\(candidate.height)")
        }

        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        let deliveryQueue = DispatchQueue(label: settings.deliveryQueueLabel, qos: queue.qos)
        session.beginConfiguration()
        // Input priority leaves the device's active format to us rather
        // than fitting it to a preset. The macOS SDK does not declare the
        // preset (it is iOS API), so it is tried by name and skipped when
        // the session refuses it; the format set below inside the same
        // configuration is then what the header's recipe promises, and the
        // sink rebuilds the encoder should the delivered size still differ.
        let inputPriority = AVCaptureSession.Preset(rawValue: Self.inputPriorityPresetName)
        if session.canSetSessionPreset(inputPriority) {
            session.sessionPreset = inputPriority
        } else {
            warnings.append("the session refuses the input-priority preset; the format is set directly")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraRecorderError.configurationFailed(deviceName: device.localizedName, underlying: error)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraRecorderError.inputRejected(deviceName: device.localizedName)
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = settings.alwaysDiscardsLateVideoFrames
        let available = output.availableVideoPixelFormatTypes
        if let pixelFormat = [settings.pixelFormat, settings.fallbackPixelFormat].first(where: available.contains) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            if pixelFormat != settings.pixelFormat {
                warnings.append(
                    "the output cannot deliver \(Self.fourCharacterCode(settings.pixelFormat)); using "
                        + Self.fourCharacterCode(pixelFormat))
            }
        } else {
            warnings.append(
                "the output can deliver none of the configured pixel formats; using its default "
                    + (available.first.map(Self.fourCharacterCode) ?? "(unknown)"))
        }
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraRecorderError.outputRejected
        }
        session.addOutput(output)
        // The format and a constant rate, set while the session is
        // configured so no preset undoes them. `chooseFormat` only returns
        // a format whose ranges contain the rate, so the durations are
        // values the device accepts.
        do {
            try device.lockForConfiguration()
        } catch {
            session.commitConfiguration()
            throw CameraRecorderError.configurationFailed(deviceName: device.localizedName, underlying: error)
        }
        device.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(selection.frameRate, 1)))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
        session.commitConfiguration()

        // No audio track: the microphone rides the screen stream's clock and
        // lives in `screen.mp4`.
        let writer = try RecordingWriter(movieURL: movieURL, clock: clock)
        let frameRate = selection.frameRate
        let tier = selection.tier
        let makeEncoder: @Sendable (Int, Int) throws -> VideoEncoder = { width, height in
            try VideoEncoder(
                configuration: VideoEncoderConfiguration(
                    width: width, height: height, frameRate: frameRate, quality: tier),
                clock: clock
            ) { sample in
                // On VideoToolbox's thread, without a hop; the writer counts
                // a frame it could not take.
                writer.appendVideo(sample)
            }
        }
        let encoder = try makeEncoder(candidate.width, candidate.height)
        let sink = FrameSink(
            clock: clock, encoder: encoder, makeEncoder: makeEncoder, writer: writer,
            maximumWarnings: settings.maximumWarnings)
        for warning in warnings { sink.note(warning: warning) }
        output.setSampleBufferDelegate(sink, queue: deliveryQueue)
        let track = CameraTrackInfo(
            width: encoder.configuration.width, height: encoder.configuration.height, frameRate: frameRate,
            codec: encoder.codec.rawValue, deviceID: device.uniqueID, deviceName: device.localizedName,
            isBuiltIn: Self.isBuiltIn(device))
        let take = Take(
            session: session, device: device, output: output, sink: sink, deliveryQueue: deliveryQueue, track: track)
        take.observers = observe(take)
        sinkBox.withLock { $0 = sink }
        abandoned.withLock { $0 = AbandonedSessionHandle(session: session) }

        // Blocks until the session runs or fails; a failure arrives as a
        // runtime-error notification, which the sink records.
        session.startRunning()
        sink.adoptSynchronizationClock(session.synchronizationClock)
        if !session.isRunning {
            abandoned.withLock { $0 = nil }
            sinkBox.withLock { $0 = nil }
            phase = .failed
            for observer in take.observers { NotificationCenter.default.removeObserver(observer) }
            output.setSampleBufferDelegate(nil, queue: nil)
            let failure = sink.statistics.sessionFailure ?? "the capture session did not start"
            throw CameraRecorderError.configurationFailed(
                deviceName: device.localizedName, underlying: CameraSessionFailure(message: failure))
        }
        phase = .running(take)
        return track
    }

    /// Ends the take and returns the finalized `camera.mp4`. Call the
    /// clock's `stop()` first: the movie ends where the clock stopped, not
    /// where this ran. Frames still arriving are refused from the moment
    /// this starts; the session stops, the encoder drains, and the writer
    /// finishes. Throws `RecordingWriterError.noVideo` when no frame was
    /// ever written (the marker is removed), or the writer's failure, with
    /// the fragmented movie left for recovery.
    public func stop() async throws -> URL {
        guard case .running(let take) = phase else { throw CameraRecorderError.notStarted }
        phase = .stopping
        take.sink.close()
        take.session.stopRunning()
        abandoned.withLock { $0 = nil }
        for observer in take.observers { NotificationCenter.default.removeObserver(observer) }
        take.output.setSampleBufferDelegate(nil, queue: nil)
        do {
            try take.sink.encoder.finish()
        } catch {
            take.sink.note(warning: "draining the camera encoder failed: \(error.localizedDescription)")
        }
        do {
            let url = try await take.sink.writer.finish()
            phase = .stopped
            return url
        } catch {
            phase = .failed
            throw error
        }
    }

    /// Stops the session and discards the take without finishing a movie:
    /// for a screen stream that refused to start. The fragmented movie and
    /// its marker are removed; nothing of the camera stays in the package.
    public func cancel() async {
        guard case .running(let take) = phase else { return }
        phase = .stopping
        take.sink.close()
        take.session.stopRunning()
        abandoned.withLock { $0 = nil }
        for observer in take.observers { NotificationCenter.default.removeObserver(observer) }
        take.output.setSampleBufferDelegate(nil, queue: nil)
        try? take.sink.encoder.finish()
        // Finishing with frames written would produce the MP4; the files go
        // either way, so the outcome is ignored.
        _ = try? await take.sink.writer.finish()
        let writer = take.sink.writer
        for url in [writer.finalizedURL, writer.movieURL, writer.markerURL] {
            try? FileManager.default.removeItem(at: url)
        }
        phase = .stopped
    }

    /// Runtime errors and the device going away are recorded in the
    /// statistics: the take keeps what it had, and the session reports the
    /// loss through its status.
    private func observe(_ take: Take) -> [any NSObjectProtocol] {
        let sink = take.sink
        let center = NotificationCenter.default
        let runtimeError = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: take.session, queue: nil
        ) { notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            sink.recordSessionFailure(
                "the capture session failed: " + (error?.localizedDescription ?? "unknown error"))
        }
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: take.device, queue: nil
        ) { _ in
            sink.recordSessionFailure("the camera was disconnected")
        }
        return [runtimeError, disconnected]
    }

    // MARK: Helpers

    private nonisolated static func candidate(of format: AVCaptureDevice.Format) -> CameraFormatCandidate {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return CameraFormatCandidate(
            width: Int(dimensions.width), height: Int(dimensions.height),
            pixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription),
            frameRateRanges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
    }

    static func fourCharacterCode(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A session failure as an error, for `configurationFailed`.
    private struct CameraSessionFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: Frame sink

    /// Receives frames on the delivery queue and compressed samples on
    /// VideoToolbox's thread. A class apart from the actor so neither path
    /// hops: the clock, the encoder and the writer are lock-guarded and
    /// thread-safe, and the counters sit under one lock the callbacks
    /// never hold while calling out.
    final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        /// `CMClock` carries no Sendable annotation; a clock is immutable,
        /// so holding it under the lock is safe.
        private struct Converter: @unchecked Sendable {
            let clock: CMClock
            let isHostClock: Bool
        }

        private struct State {
            var encoder: VideoEncoder
            var converter: Converter?
            /// Set by `close`: from then on every frame is refused, whatever
            /// its stamp, so nothing reaches an encoder being drained.
            var isClosed = false
            var statistics = CameraRecorderStatistics()
        }

        let clock: RecordingClock
        let writer: RecordingWriter
        /// Opens an encoder for a frame size: the one for the chosen format
        /// at `init`, and a replacement when the device delivers another
        /// size (a preset the session kept, or a format the device swapped),
        /// so the movie carries what arrives rather than failing on every
        /// frame.
        private let makeEncoder: @Sendable (Int, Int) throws -> VideoEncoder
        private let maximumWarnings: Int
        private let state: Mutex<State>

        init(
            clock: RecordingClock, encoder: VideoEncoder,
            makeEncoder: @escaping @Sendable (Int, Int) throws -> VideoEncoder,
            writer: RecordingWriter, maximumWarnings: Int
        ) {
            self.clock = clock
            self.writer = writer
            self.makeEncoder = makeEncoder
            self.maximumWarnings = maximumWarnings
            state = Mutex(State(encoder: encoder))
        }

        /// The encoder in use.
        var encoder: VideoEncoder {
            state.withLock { $0.encoder }
        }

        var statistics: CameraRecorderStatistics {
            let (statistics, encoder) = state.withLock { ($0.statistics, $0.encoder) }
            var result = statistics
            result.encoder = encoder.statistics
            result.writer = writer.statistics
            return result
        }

        /// The session's clock once it runs. Nil leaves stamps as they are,
        /// which only ever happens before the clock's origin.
        func adoptSynchronizationClock(_ sessionClock: CMClock?) {
            guard let sessionClock else {
                note(warning: "the capture session reports no synchronization clock; stamps are taken as host time")
                return
            }
            let isHostClock = CFEqual(sessionClock, CMClockGetHostTimeClock())
            state.withLock { state in
                state.converter = Converter(clock: sessionClock, isHostClock: isHostClock)
                state.statistics.synchronizationClockIsHostClock = isHostClock
            }
            if !isHostClock {
                note(warning: "the capture session clock is not the host clock; sample times are converted")
            }
        }

        func close() {
            state.withLock { $0.isClosed = true }
        }

        func note(warning: String) {
            state.withLock { state in
                guard state.statistics.warnings.count < maximumWarnings else { return }
                state.statistics.warnings.append(warning)
            }
        }

        func recordSessionFailure(_ message: String) {
            state.withLock { state in
                if state.statistics.sessionFailure == nil { state.statistics.sessionFailure = message }
            }
            note(warning: message)
        }

        /// One captured frame, on the delivery queue. The buffer is consumed
        /// or dropped before this returns and never stored: a retained
        /// buffer starves the device's pool.
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            let (converter, closed) = state.withLock { ($0.converter, $0.isClosed) }
            guard !closed else {
                state.withLock { $0.statistics.framesOutsideRecording += 1 }
                return
            }
            var hostTime = sampleBuffer.presentationTimeStamp
            if let converter, !converter.isHostClock {
                hostTime = CMSyncConvertTime(hostTime, from: converter.clock, to: CMClockGetHostTimeClock())
                state.withLock { $0.statistics.sampleTimesConverted += 1 }
            }
            guard clock.isStarted, let recordingTime = clock.recordingTime(forHostTime: hostTime) else {
                // Before the origin (the warm-up, or a stamp from before the
                // clock started), inside a pause, or after the stop.
                let beforeOrigin = !clock.isStarted || hostTime < clock.origin
                state.withLock { state in
                    if beforeOrigin {
                        state.statistics.framesBeforeOrigin += 1
                    } else {
                        state.statistics.framesOutsideRecording += 1
                    }
                }
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                state.withLock { $0.statistics.framesWithoutPixels += 1 }
                return
            }
            guard let encoder = encoder(for: pixelBuffer) else { return }
            do {
                try encoder.encode(pixelBuffer, hostTime: hostTime)
                let seconds = recordingTime.seconds
                state.withLock { state in
                    state.statistics.framesEncoded += 1
                    if state.statistics.firstFrameRecordingSeconds == nil {
                        state.statistics.firstFrameRecordingSeconds = seconds
                        state.statistics.firstFrameHostSeconds = hostTime.seconds
                    }
                    state.statistics.lastFrameRecordingSeconds = seconds
                }
            } catch {
                state.withLock { $0.statistics.encodeFailures += 1 }
                note(warning: "encoding a camera frame failed: \(error.localizedDescription)")
            }
        }

        /// The encoder for a frame of this size: the current one when the
        /// size matches its configuration, else a replacement opened for the
        /// delivered size (the old one is drained first, so nothing it still
        /// holds lands after the new one's frames). Nil when no encoder can
        /// be opened for the size, counted as an encode failure.
        private func encoder(for pixelBuffer: CVPixelBuffer) -> VideoEncoder? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let current = state.withLock { $0.encoder }
            let configured = current.configuration
            // The encoder rounds an odd size down; a delivered size that
            // rounds to the configured one is the configured one.
            let expected = VideoEncoderConfiguration(width: width, height: height, frameRate: configured.frameRate)
            guard expected.width != configured.width || expected.height != configured.height else { return current }
            do {
                let replacement = try makeEncoder(width, height)
                try? current.finish()
                state.withLock { $0.encoder = replacement }
                note(
                    warning:
                        "the camera delivers \(width)×\(height), not the chosen \(configured.width)×\(configured.height); "
                        + "the encoder was reopened for it")
                return replacement
            } catch {
                state.withLock { $0.statistics.encodeFailures += 1 }
                note(warning: "no encoder could be opened for \(width)×\(height): \(error.localizedDescription)")
                return nil
            }
        }

        /// A frame the output discarded (`alwaysDiscardsLateVideoFrames`);
        /// the buffer carries no pixels.
        func captureOutput(
            _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
        ) {
            state.withLock { $0.statistics.framesDroppedByOutput += 1 }
        }
    }
}
