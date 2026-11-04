import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// Codecs the recorder writes. HEVC is the default: hardware encoders have
/// shipped in every Mac since 2017 and it needs about 0.7× the H.264 bit rate
/// for the same legibility on text-heavy UI. H.264 is the compatibility
/// fallback for a machine whose hardware HEVC encoder is missing or busy.
public enum VideoCodec: String, Sendable, CaseIterable {
    case hevc
    case h264

    var codecType: CMVideoCodecType {
        switch self {
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        }
    }

    /// Main profile for HEVC (8-bit; Main10 is for HDR only) and High for
    /// H.264, each at whatever level the frame size and rate demand.
    var profileLevel: CFString {
        switch self {
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264: kVTProfileLevel_H264_High_AutoLevel
        }
    }

    /// Fraction of the H.264 target bit rate that gives this codec the same quality.
    var bitRateScale: Double {
        switch self {
        case .hevc: 0.7
        case .h264: 1
        }
    }
}

/// Bit-rate tiers. `balanced` is the formula Cap ships as its default;
/// `high` doubles it for recordings that will be zoomed into heavily.
public enum VideoQuality: String, Sendable, CaseIterable {
    case balanced
    case high

    var bitRateMultiplier: Double {
        switch self {
        case .balanced: 1
        case .high: 2
        }
    }
}

/// Everything the encoder needs to know before the first frame arrives.
public struct VideoEncoderConfiguration: Sendable, Equatable {
    /// Frame size in pixels, always even. The hardware encoders accept an odd
    /// dimension and silently emit the even size below it, so an odd request
    /// is rounded down here, where the caller can read the size the file will
    /// have. The capture rect stays in points, so normalized telemetry is
    /// unaffected.
    public var width: Int {
        didSet { width = Self.even(width) }
    }
    public var height: Int {
        didSet { height = Self.even(height) }
    }
    /// Nominal capture rate. The stream may deliver fewer frames than this on
    /// static content; the duration-based keyframe limit covers that case.
    public var frameRate: Int
    public var codec: VideoCodec
    public var quality: VideoQuality

    public init(
        width: Int, height: Int, frameRate: Int, codec: VideoCodec = .hevc, quality: VideoQuality = .balanced
    ) {
        self.width = Self.even(width)
        self.height = Self.even(height)
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
    }

    /// Frames between keyframes: one second of video, or half a second from
    /// 4K up, where restarting a GOP costs the editor's scrubber about four
    /// times the decode work of 1080p.
    public var maxKeyFrameInterval: Int {
        let seconds = width * height >= 3840 * 2160 ? 0.5 : 1.0
        return max(1, Int((Double(frameRate) * seconds).rounded()))
    }

    /// Wall-clock bound on the keyframe distance. ScreenCaptureKit delivers
    /// only changed frames, so on a static screen a frame-count limit alone
    /// would stretch a GOP to tens of seconds and make seeking there crawl.
    public var maxKeyFrameIntervalDuration: TimeInterval { 2 }

    /// Long-term average bit rate in bits per second for `codec`:
    /// w × h × min(fps, 60) / 30 × 5 bits for H.264, scaled for other codecs
    /// and the quality tier. 20.7 Mb/s for 1080p60 H.264, 14.5 Mb/s for HEVC.
    public func averageBitRate(for codec: VideoCodec) -> Int {
        let base = Double(width * height) * Double(min(frameRate, 60)) / 30 * 5
        return Int((base * codec.bitRateScale * quality.bitRateMultiplier).rounded())
    }

    private static func even(_ pixels: Int) -> Int {
        max(pixels & ~1, 2)
    }
}

public enum VideoEncoderError: LocalizedError {
    case sessionCreationFailed(codec: VideoCodec, status: OSStatus)
    case propertyRejected(key: String, status: OSStatus)
    case encodeFailed(status: OSStatus)
    case finished

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let codec, let status):
            "VideoToolbox could not open a hardware \(codec.rawValue) compression session (\(status))."
        case .propertyRejected(let key, let status):
            "The video encoder rejected \(key) (\(status))."
        case .encodeFailed(let status):
            "The video encoder failed (\(status))."
        case .finished:
            "The video encoder has already finished."
        }
    }
}

/// Counters for the report at the end of a recording.
public struct VideoEncoderStatistics: Sendable, Equatable {
    /// Frames handed to VideoToolbox.
    public var submittedFrames = 0
    /// Compressed frames delivered to the output callback.
    public var encodedFrames = 0
    /// Frames VideoToolbox discarded to keep up.
    public var droppedFrames = 0
    /// Frames captured during a pause, before the clock's origin or after its
    /// stop. Expected, not a loss.
    public var skippedOutsideRecording = 0
    /// Frames whose recording time did not advance past the previous frame's,
    /// refused so the writer never sees a non-increasing stamp. Anything here
    /// points at a source that re-stamps or reorders frames.
    public var droppedNonIncreasing = 0
    /// Last failure reported by the encoder's output path, if any.
    public var lastErrorStatus: OSStatus?
}

/// Hardware video encoder for the recording path: a `VTCompressionSession`
/// configured for an editable source file rather than for streaming.
///
/// Every property that `SCRecordingOutput` leaves to the encoder's defaults is
/// pinned here: real-time mode, no frame reordering (so the MP4 keeps a plain
/// `stss` keyframe index and no `ctts`), a keyframe at least every second and
/// every two seconds of wall time, a bit rate derived from the frame size, and
/// BT.709 colour tags. Compressed frames come back in presentation order
/// through the output callback, on VideoToolbox's thread, stamped on the
/// recording timeline (see `RecordingClock`), which is what `RecordingWriter`
/// expects.
///
/// Hardware encoding is required, not merely enabled: VideoToolbox otherwise
/// falls back to Apple's software encoder without a word, and a 4K60 session
/// on it drops frames wholesale. When the hardware HEVC encoder is unavailable
/// or saturated, the session falls back to hardware H.264.
///
/// `encode` is safe to call from the ScreenCaptureKit sample queue; `finish`
/// from anywhere. Both serialize on one lock, which the output callback never
/// takes, so draining the session cannot deadlock against its own callbacks.
public final class VideoEncoder: @unchecked Sendable {
    public let configuration: VideoEncoderConfiguration
    /// The timeline frames are stamped on; shared with the writer and the telemetry.
    public let clock: RecordingClock
    /// The codec in use. Differs from the configured one only after the
    /// fallback from HEVC to H.264.
    public let codec: VideoCodec
    /// What VideoToolbox reports about the session it opened. Always true
    /// while hardware encoding is required; kept in the report so a change in
    /// that policy, or in VideoToolbox, is visible.
    public let isHardwareAccelerated: Bool

    private struct Control {
        var isFinished = false
        var submittedFrames = 0
        var skippedOutsideRecording = 0
        var droppedNonIncreasing = 0
        var lastPresentationTime: CMTime?
        /// The clock's completed pauses when the last frame was submitted; a
        /// change means a resume happened and the next frame opens a GOP.
        var completedPauses = 0
    }

    private let session: VTCompressionSession
    private let sink: Sink
    private let frameDuration: CMTime
    private let control = Mutex(Control())

    /// Opens the session. Asking for HEVC on a machine whose hardware cannot
    /// provide it right now opens a hardware H.264 session instead; check
    /// `codec` to tell. Throws when neither hardware encoder is available.
    public init(
        configuration: VideoEncoderConfiguration, clock: RecordingClock,
        output: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        self.configuration = configuration
        self.clock = clock
        let sink = Sink(output: output)
        self.sink = sink
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(configuration.frameRate, 1)))
        do {
            (session, isHardwareAccelerated) = try Self.openSession(
                for: configuration.codec, configuration: configuration, sink: sink)
            codec = configuration.codec
        } catch {
            guard configuration.codec == .hevc else { throw error }
            (session, isHardwareAccelerated) = try Self.openSession(
                for: .h264, configuration: configuration, sink: sink)
            codec = .h264
        }
    }

    deinit {
        // Orderly teardown guarantees no callback reaches `sink` after it is
        // released; relying on the last CFRelease would make that timing a guess.
        VTCompressionSessionInvalidate(session)
    }

    public var statistics: VideoEncoderStatistics {
        var statistics = sink.statistics
        control.withLock { control in
            statistics.submittedFrames = control.submittedFrames
            statistics.skippedOutsideRecording = control.skippedOutsideRecording
            statistics.droppedNonIncreasing = control.droppedNonIncreasing
        }
        return statistics
    }

    /// Submits one captured frame. `hostTime` is the stream's capture stamp
    /// (the sample buffer's presentation time), never the time of this call:
    /// frames queue between capture and encode, and stamping them late is what
    /// desynchronizes video from the cursor log and audio. The clock places
    /// the frame on the recording timeline: a frame captured during a pause,
    /// before the origin or after the stop is skipped, the first frame after a
    /// resume is a forced keyframe so every resume starts a fresh GOP, and a
    /// frame that would not advance the timeline is dropped.
    public func encode(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime, forceKeyFrame: Bool = false) throws {
        try control.withLock { control in
            guard !control.isFinished else { throw VideoEncoderError.finished }
            guard let presentationTime = clock.recordingTime(forHostTime: hostTime) else {
                control.skippedOutsideRecording += 1
                return
            }
            if let last = control.lastPresentationTime, presentationTime <= last {
                control.droppedNonIncreasing += 1
                return
            }
            let completedPauses = clock.completedPauses
            let keyframe = forceKeyFrame || completedPauses != control.completedPauses
            control.completedPauses = completedPauses
            control.lastPresentationTime = presentationTime
            control.submittedFrames += 1
            let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: frameDuration,
                frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: &flags)
            guard status == noErr else { throw VideoEncoderError.encodeFailed(status: status) }
            // A synchronous drop never reaches the output callback.
            if flags.contains(.frameDropped) { sink.recordDrop() }
        }
    }

    /// Emits every pending frame through the output callback, then tears the
    /// session down. Blocks until the last frame is out, so once it returns
    /// the writer holds every frame and may append its stop marker; later
    /// calls are no-ops.
    public func finish() throws {
        try control.withLock { control in
            guard !control.isFinished else { return }
            control.isFinished = true
            let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            guard status == noErr else { throw VideoEncoderError.encodeFailed(status: status) }
        }
    }

    private static func openSession(
        for codec: VideoCodec, configuration: VideoEncoderConfiguration, sink: Sink
    ) throws -> (VTCompressionSession, Bool) {
        var created: VTCompressionSession?
        // Require, not Enable: Enable is the default and still lets VideoToolbox
        // hand back the software encoder, so the H.264 fallback would never fire.
        let specification =
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(configuration.width), height: Int32(configuration.height),
            codecType: codec.codecType, encoderSpecification: specification, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: compressionOutput,
            refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            throw VideoEncoderError.sessionCreationFailed(codec: codec, status: status)
        }

        do {
            let properties: [(CFString, CFTypeRef)] = [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: configuration.maxKeyFrameInterval)),
                (
                    kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                    NSNumber(value: configuration.maxKeyFrameIntervalDuration)
                ),
                (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: configuration.averageBitRate(for: codec))),
                (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuration.frameRate)),
                (kVTCompressionPropertyKey_ProfileLevel, codec.profileLevel),
                (kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
                (kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
                (kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2),
            ]
            for (key, value) in properties {
                let status = VTSessionSetProperty(session, key: key, value: value)
                guard status == noErr else {
                    throw VideoEncoderError.propertyRejected(key: key as String, status: status)
                }
            }
            // Allocates the encoder's resources now rather than on the first
            // frame, so the first captured frame is not the one that pays for it.
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw VideoEncoderError.encodeFailed(status: prepared) }
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }

        var usingHardware: Unmanaged<CFTypeRef>?
        let copied = withUnsafeMutablePointer(to: &usingHardware) { pointer in
            VTSessionCopyProperty(
                session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil,
                valueOut: UnsafeMutableRawPointer(pointer))
        }
        let isHardware = copied == noErr ? (usingHardware?.takeRetainedValue() as? Bool) ?? false : false
        return (session, isHardware)
    }

    /// Receives VideoToolbox's output on its own thread. A separate object so
    /// it can be the session's refcon before `self` is fully initialized, and
    /// so its lock is never the one `finish` holds while the session drains.
    fileprivate final class Sink: @unchecked Sendable {
        private struct Counters {
            var encodedFrames = 0
            var droppedFrames = 0
            var lastErrorStatus: OSStatus?
        }

        private let output: @Sendable (CMSampleBuffer) -> Void
        private let counters = Mutex(Counters())

        init(output: @escaping @Sendable (CMSampleBuffer) -> Void) {
            self.output = output
        }

        var statistics: VideoEncoderStatistics {
            counters.withLock {
                VideoEncoderStatistics(
                    encodedFrames: $0.encodedFrames, droppedFrames: $0.droppedFrames,
                    lastErrorStatus: $0.lastErrorStatus)
            }
        }

        func recordDrop() {
            counters.withLock { $0.droppedFrames += 1 }
        }

        func handle(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
            guard status == noErr else {
                counters.withLock { $0.lastErrorStatus = status }
                return
            }
            guard let sampleBuffer, !flags.contains(.frameDropped) else {
                recordDrop()
                return
            }
            counters.withLock { $0.encodedFrames += 1 }
            output(sampleBuffer)
        }
    }
}

/// The C callback VideoToolbox invokes per compressed frame; `refcon` is the
/// encoder's `Sink`, kept alive by the encoder until the session is invalidated.
private let compressionOutput: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
    guard let refcon else { return }
    Unmanaged<VideoEncoder.Sink>.fromOpaque(refcon).takeUnretainedValue()
        .handle(status: status, flags: flags, sampleBuffer: sampleBuffer)
}
