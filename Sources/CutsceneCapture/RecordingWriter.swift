import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Audio sources the writer keeps as separate tracks, so voice and system
/// sound stay independently editable; `SCRecordingOutput` mixes them.
public enum RecordingAudioSource: String, Sendable, CaseIterable {
    case system
    case microphone
}

public struct RecordingWriterConfiguration: Sendable, Equatable {
    /// AAC settings for one audio track.
    public struct AudioTrack: Sendable, Equatable {
        /// Channels a track may have, inclusive: mono or stereo. Above two,
        /// `AVAssetWriterInput` demands an `AVChannelLayoutKey` and the AAC
        /// encoder takes only its surround layouts for it (quadraphonic,
        /// 5.1, …; a discrete or unknown layout throws from the input's
        /// initializer, an Objective-C exception no `try` catches, measured
        /// 2026-11-03), which describe no recording source. A source with
        /// more channels is fed to a track of this many and AVFoundation
        /// maps it down (a 4-channel source into a stereo track comes out
        /// as its first two channels, measured the same day).
        public static let maximumChannelCount = 2

        /// Channels in the file, 1 through `maximumChannelCount`. AVFoundation
        /// remaps a source with another count (a mono microphone fed to a
        /// stereo track comes out on both channels), so this is taken from
        /// the capture configuration rather than sniffed from the first
        /// buffer: `SCStreamConfiguration.channelCount` for system audio, the
        /// device's format for the microphone. Every file then has the same
        /// layout whatever arrived first.
        public var channelCount: Int
        public var bitRate: Int

        public init(channelCount: Int = 2, bitRate: Int = 160_000) {
            self.channelCount = channelCount
            self.bitRate = bitRate
        }
    }

    /// Which audio tracks the file carries. Every track listed here must
    /// receive samples: an input that never gets any leaves an empty track.
    public var audioTracks: [RecordingAudioSource: AudioTrack]
    /// How often the movie's sample tables are flushed to disk. A crash or a
    /// full disk loses at most this much; a non-fragmented file loses
    /// everything. Nil picks it from the destination volume: 2 s on internal
    /// storage, 10 s on external or removable media, where Apple advises 10 s
    /// or more (`AVAssetWriter.h`).
    public var movieFragmentInterval: CMTime?
    public var audioSampleRate: Double
    /// Audio buffers per source held back until the first video keyframe
    /// starts the file; ~1.3 s at ScreenCaptureKit's 1024-frame buffers. The
    /// oldest go first when it overflows, so the audio that survives is the
    /// audio that meets the video.
    public var audioPrerollLimit: Int
    /// A buffer that starts later than the previous one ended by more than
    /// this leaves a hole, which is filled with silence; one that starts
    /// earlier by more than this has the overlapping head cut off. Half of a
    /// 1024-frame buffer at 48 kHz.
    public var audioGapTolerance: CMTime

    public init(
        audioTracks: [RecordingAudioSource: AudioTrack] = [:],
        movieFragmentInterval: CMTime? = nil,
        audioSampleRate: Double = 48_000,
        audioPrerollLimit: Int = 64,
        audioGapTolerance: CMTime = CMTime(value: 512, timescale: 48_000)
    ) {
        self.audioTracks = audioTracks
        self.movieFragmentInterval = movieFragmentInterval
        self.audioSampleRate = audioSampleRate
        self.audioPrerollLimit = audioPrerollLimit
        self.audioGapTolerance = audioGapTolerance
    }
}

/// Counters for the report at the end of a recording.
public struct RecordingWriterStatistics: Sendable, Equatable {
    public var videoFrames = 0
    /// Compressed frames that arrived before the first keyframe. The encoder
    /// starts with one, so anything here points at a mis-ordered pipeline.
    public var videoDroppedBeforeKeyframe = 0
    /// Frames the writer could not take: its input was not ready (the disk
    /// fell behind), it had already failed, or `finish` had run.
    public var videoDroppedNotReady = 0
    /// Frames whose stamp did not advance past the previous frame's. The
    /// encoder refuses those already, so anything here points at a second
    /// video source feeding one writer.
    public var videoDroppedNonIncreasing = 0
    public var audioBuffers = 0
    /// Buffers captured during a pause, before the clock's origin or after its
    /// stop. Expected, not a loss.
    public var audioOutsideRecording = 0
    /// Buffers lost: writer not ready, pre-roll overflow, a source without a
    /// configured track, or arrival after `finish`. The span of a lost buffer
    /// is filled with silence when the source's next buffer arrives, so the
    /// rest of the track keeps its place.
    public var audioDropped = 0
    /// Silent buffers inserted where a source's timestamps left a hole: a
    /// source that started late, a dropped buffer, a gap in the stream.
    public var audioGapsFilled = 0
    /// Total silence inserted, in seconds.
    public var audioSilenceSeconds: Double = 0
    /// Buffers whose head overlapped audio already written and was cut off,
    /// as happens to the first buffer after a resume.
    public var audioOverlapsTrimmed = 0
    /// Silent buffers appended at `finish` so each track ends on the stop
    /// with the video (the capture delivers an audio buffer only once it is
    /// complete, so the one covering the stop is still in flight when the
    /// take ends), and the seconds they add up to.
    public var audioEndPadded = 0
    public var audioEndPaddingSeconds: Double = 0
    /// Why the writer stopped taking samples, when it has; what
    /// `RecordingWriter.failure` says, for the report.
    public var failureDescription: String?
}

public enum RecordingWriterError: LocalizedError {
    case noVideo
    case unsupportedFormat
    /// A configured audio track asks for more channels than
    /// `RecordingWriterConfiguration.AudioTrack.maximumChannelCount` or
    /// fewer than one; refused before the file exists, since the input's
    /// initializer would throw an uncatchable exception on the encoder's
    /// thread.
    case unsupportedChannelCount(RecordingAudioSource, Int)
    case writerFailed((any Error)?)
    case exportUnavailable
    case alreadyFinished
    case notFinished
    case sourceMissing(URL)
    case endMarkerFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noVideo: "The recording ended before any video frame was written."
        case .unsupportedFormat: "AVAssetWriter cannot write this media format to a QuickTime movie."
        case .unsupportedChannelCount(let source, let count):
            "The \(source.rawValue) audio track cannot have \(count) channels; 1 to "
                + "\(RecordingWriterConfiguration.AudioTrack.maximumChannelCount) are supported."
        case .writerFailed(let error):
            "Writing the recording failed: \(error?.localizedDescription ?? "unknown error")."
        case .exportUnavailable: "No passthrough export session is available for the recording."
        case .alreadyFinished: "The recording writer has already finished."
        case .notFinished: "The recording writer has not finished yet."
        case .sourceMissing(let url): "The fragmented movie \(url.lastPathComponent) no longer exists."
        case .endMarkerFailed(let status): "The stop marker for the video track could not be built (\(status))."
        }
    }
}

/// Sidecar written next to the fragmented movie from the moment it exists
/// until `finish` succeeds. If the app dies, the file's presence tells the next
/// launch which movie still needs `RecordingWriter.finalize(fragmentedMovie:into:)`.
public struct NeedsFinalizeMarker: Codable, Sendable, Equatable {
    public var fragmentedMovie: String
    public var finalizedMovie: String
    public var startedAt: Date
    /// The process writing the movie, so a scan can tell a take another
    /// process is still recording (a second instance, the CLI) from one a
    /// dead process left; nil in markers from builds before it was written.
    public var processID: Int32?
}

/// Writes one recording to disk: compressed video from `VideoEncoder` passed
/// through untouched, plus up to two LPCM audio sources encoded to AAC, into a
/// fragmented QuickTime movie that survives a crash. `finish` then rewrites it
/// as a progressive, faststart MP4 without re-encoding.
///
/// Time zero of the movie is the `RecordingClock`'s origin, the same instant
/// the telemetry counts from, so an event at 3.2 s in the log is at 3.2 s in
/// the movie. Video arrives from the encoder already on that timeline; audio
/// arrives straight from the capture stream with host-clock stamps and is
/// placed on it here, which drops buffers captured during a pause and trims
/// the one that straddles a resume. Because AVFoundation times an AAC track by
/// the audio it is given rather than by stamps, every hole in a source (a late
/// start, a dropped buffer, a gap in the stream) is filled with silence, so
/// the audio after it keeps its place against the video.
///
/// The file is created on the first video keyframe, because the passthrough
/// input needs that frame's format description and every input must exist
/// before `AVAssetWriter.startWriting()`. Audio that arrives earlier waits in
/// a bounded pre-roll and is kept: the session starts at zero, not at the
/// first frame.
///
/// Append paths are synchronous and lock-guarded so ScreenCaptureKit's sample
/// queue and the encoder's callback thread can call them directly. They never
/// wait for the writer: when an input is not ready the sample is dropped and
/// counted (and, for audio, filled in later), which is the right trade for a
/// real-time source.
///
/// HEVC passthrough was the open question in the research brief (§5.2, §8
/// Q15). Confirmed 2026-11-02 on macOS 26.7 with `cutscene-spike writer`:
/// `hvc1` Main samples pass through the fragmented `.mov` and the passthrough
/// export into `.mp4` with BT.709 tags intact, `ftyp`/`moov`/`mdat` order and
/// pts equal to dts on every packet.
public final class RecordingWriter: @unchecked Sendable {
    /// The fragmented movie written during the recording.
    public let movieURL: URL
    /// The progressive MP4 `finish` produces next to it.
    public let finalizedURL: URL
    /// The `needsFinalize` sidecar, present from the first keyframe until `finish` succeeds.
    public let markerURL: URL
    public let configuration: RecordingWriterConfiguration
    /// The timeline the movie is written on; shared with the encoder and the telemetry.
    public let clock: RecordingClock
    /// The fragment interval in use: the configured one, or the one chosen
    /// for the destination volume.
    public let movieFragmentInterval: CMTime
    /// Whether the destination is internal storage. Nil when the volume does
    /// not say, which is treated as external.
    public let destinationIsInternal: Bool?

    /// Fragment interval for internal storage.
    public static let internalVolumeFragmentInterval = CMTime(value: 2, timescale: 1)
    /// Fragment interval for external, removable or unknown storage.
    public static let externalVolumeFragmentInterval = CMTime(value: 10, timescale: 1)

    /// `CMSampleBuffer` carries no Sendable annotation because its attachments
    /// are mutable, so the lock's region checking refuses to keep one in
    /// `State`. The writer never mutates a buffer and hands each one to
    /// `AVAssetWriter` exactly once, so holding it under the lock is safe.
    private struct PendingSample: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    private struct State {
        var session: Session?
        var isFinished = false
        var failure: (any Error)?
        var pendingAudio: [RecordingAudioSource: [PendingSample]] = [:]
        /// Where each source's next buffer should start, on the recording
        /// timeline. Starts at zero, so a source that begins late gets silence
        /// from the start and every track spans the whole recording.
        var audioCursor: [RecordingAudioSource: CMTime] = [:]
        /// The LPCM format of each source's last buffer: what the silence
        /// that pads the track to the stop is synthesized in.
        var audioFormat: [RecordingAudioSource: CMFormatDescription] = [:]
        var lastVideoTime: CMTime?
        var videoFormat: CMFormatDescription?
        var statistics = RecordingWriterStatistics()
    }

    private let state = Mutex(State())

    /// Prepares to write `movieURL` (a `.mov`) on `clock`'s timeline; the MP4
    /// and the marker take their names from it. Creates the directory now;
    /// the movie and the marker appear with the first video keyframe. Throws
    /// `unsupportedChannelCount` for an audio track the file could not lay
    /// out, so a bad configuration fails here rather than on the encoder's
    /// callback thread.
    public init(
        movieURL: URL, clock: RecordingClock,
        configuration: RecordingWriterConfiguration = RecordingWriterConfiguration()
    ) throws {
        for source in RecordingAudioSource.allCases {
            guard let track = configuration.audioTracks[source] else { continue }
            guard (1...RecordingWriterConfiguration.AudioTrack.maximumChannelCount).contains(track.channelCount) else {
                throw RecordingWriterError.unsupportedChannelCount(source, track.channelCount)
            }
        }
        self.movieURL = movieURL
        self.clock = clock
        self.configuration = configuration
        finalizedURL = movieURL.deletingPathExtension().appendingPathExtension("mp4")
        markerURL = Self.markerURL(for: movieURL)

        let directory = movieURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destinationIsInternal = Self.volumeIsInternal(directory)
        movieFragmentInterval =
            configuration.movieFragmentInterval
            ?? (destinationIsInternal == true
                ? Self.internalVolumeFragmentInterval : Self.externalVolumeFragmentInterval)
    }

    /// Where the marker for a given fragmented movie lives.
    public static func markerURL(for movieURL: URL) -> URL {
        movieURL.appendingPathExtension("needsFinalize")
    }

    /// Whether `url` lives on internal, non-removable storage. Nil when the
    /// volume does not report it.
    public static func volumeIsInternal(_ url: URL) -> Bool? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            ]),
            let isInternal = values.volumeIsInternal
        else { return nil }
        return isInternal && values.volumeIsRemovable != true && values.volumeIsEjectable != true
    }

    public var statistics: RecordingWriterStatistics {
        state.withLock { state in
            var statistics = state.statistics
            statistics.failureDescription = state.failure?.localizedDescription
            return statistics
        }
    }

    /// Why the writer stopped taking samples, once it has: `AVAssetWriter`
    /// failed, or the file could not be opened at the first keyframe. From
    /// then on every append is counted as dropped, so a session should end
    /// the take as soon as this is set rather than record into nothing.
    public var failure: (any Error)? {
        state.withLock { $0.failure }
    }

    /// Appends one compressed frame from the encoder, stamped on the recording
    /// timeline. Frames before the first keyframe cannot start a decodable
    /// file and are dropped.
    public func appendVideo(_ sample: CMSampleBuffer) {
        state.withLock { state in
            guard !state.isFinished, state.failure == nil else {
                state.statistics.videoDroppedNotReady += 1
                return
            }
            let time = sample.presentationTimeStamp
            if let last = state.lastVideoTime, time <= last {
                state.statistics.videoDroppedNonIncreasing += 1
                return
            }
            if state.session == nil {
                guard sample.isKeyframe, let format = sample.formatDescription else {
                    state.statistics.videoDroppedBeforeKeyframe += 1
                    return
                }
                do {
                    let session = try startSession(videoFormat: format)
                    state.session = session
                    state.videoFormat = format
                    for source in RecordingAudioSource.allCases {
                        for pending in state.pendingAudio[source] ?? [] {
                            place(pending.buffer, from: source, in: session, state: &state)
                        }
                    }
                    state.pendingAudio = [:]
                } catch {
                    state.failure = error
                    return
                }
            }
            guard let session = state.session else { return }
            switch session.appendVideo(sample) {
            case .appended:
                state.statistics.videoFrames += 1
                state.lastVideoTime = time
            case .notReady:
                state.statistics.videoDroppedNotReady += 1
            case .failed(let error):
                state.failure = RecordingWriterError.writerFailed(error)
            }
        }
    }

    /// Appends one LPCM buffer from `source`, which must have a configured
    /// track. The buffer carries the capture stream's host-clock stamp; the
    /// clock places it on the recording timeline.
    public func appendAudio(_ sample: CMSampleBuffer, from source: RecordingAudioSource) {
        state.withLock { state in
            guard !state.isFinished, state.failure == nil, configuration.audioTracks[source] != nil else {
                state.statistics.audioDropped += 1
                return
            }
            guard let time = clock.recordingTime(forHostTime: sample.presentationTimeStamp) else {
                state.statistics.audioOutsideRecording += 1
                return
            }
            let placed: CMSampleBuffer
            do {
                placed = try Self.retimed(sample, to: time)
            } catch {
                state.statistics.audioDropped += 1
                return
            }
            guard let session = state.session else {
                var pending = state.pendingAudio[source, default: []]
                if pending.count >= configuration.audioPrerollLimit {
                    pending.removeFirst()
                    state.statistics.audioDropped += 1
                }
                pending.append(PendingSample(buffer: placed))
                state.pendingAudio[source] = pending
                return
            }
            place(placed, from: source, in: session, state: &state)
        }
    }

    /// Closes the movie at the clock's current recording time, rewrites it as
    /// a faststart MP4 and returns that URL. Call `clock.stop()` first, so the
    /// end is the moment the user stopped rather than the moment this ran, and
    /// call `VideoEncoder.finish()` first too: the last frame's duration comes
    /// from a stop marker appended after it, so every frame must already be in
    /// the file. Each audio track is padded with silence up to the stop, so
    /// the tracks end together. The fragmented original and the marker go
    /// away only once the MP4 is complete; after a failure both stay, for
    /// `salvage()` now or recovery at the next launch.
    public func finish() async throws -> URL {
        let stopTime = clock.elapsed
        let (session, failure) = try state.withLock { state -> (Session?, (any Error)?) in
            guard !state.isFinished else { throw RecordingWriterError.alreadyFinished }
            state.isFinished = true
            state.pendingAudio = [:]
            if let session = state.session, state.failure == nil, let last = state.lastVideoTime,
                let format = state.videoFormat, stopTime > last
            {
                // ScreenCaptureKit delivers only changed frames, so without
                // this the track would end a frame after the last screen
                // change while the audio runs to the stop.
                do {
                    if case .failed(let error) = session.appendVideo(try Self.endMarker(format: format, at: stopTime)) {
                        state.failure = RecordingWriterError.writerFailed(error)
                    }
                } catch {
                    state.failure = error
                }
            }
            if let session = state.session, state.failure == nil {
                padAudioToStop(stopTime, in: session, state: &state)
            }
            state.session?.markAsFinished()
            return (state.session, state.failure)
        }
        guard let session else {
            // No movie was ever created, so there is nothing to recover and
            // the marker must not outlive the attempt.
            try? FileManager.default.removeItem(at: markerURL)
            throw failure ?? RecordingWriterError.noVideo
        }
        if let failure { throw failure }

        await session.writer.finishWriting()
        guard session.writer.status == .completed else {
            throw RecordingWriterError.writerFailed(session.writer.error)
        }
        try await Self.finalize(fragmentedMovie: movieURL, into: finalizedURL)
        // The marker goes first: an orphan movie only wastes disk, an orphan
        // marker would send the next launch to recover a finished recording.
        try? FileManager.default.removeItem(at: markerURL)
        try? FileManager.default.removeItem(at: movieURL)
        return finalizedURL
    }

    /// After `finish` threw with the movie on disk: rewrites what the writer
    /// had flushed as the MP4 and clears the marker and the fragmented
    /// original, which is what recovery would do at the next launch, so the
    /// take can be used now (ARCHITECTURE §2 "Writer failure → the finish
    /// path; the last fragment survives"). The tracks end at their own last
    /// fragment, so the playable length is the shortest track's. Throws when
    /// `finish` has not run, when there is no fragmented movie, or when the
    /// rewrite fails, in which case the files stay for recovery.
    public func salvage() async throws -> URL {
        guard state.withLock({ $0.isFinished }) else { throw RecordingWriterError.notFinished }
        try await Self.finalize(fragmentedMovie: movieURL, into: finalizedURL)
        try? FileManager.default.removeItem(at: markerURL)
        try? FileManager.default.removeItem(at: movieURL)
        return finalizedURL
    }

    /// Rewrites a fragmented movie as a progressive MP4 with the `moov` atom
    /// up front, without touching the encoded samples. Also the recovery path
    /// for a movie whose marker survived a crash: a marker whose movie is gone
    /// fails with `sourceMissing` and leaves any finished MP4 alone.
    public static func finalize(fragmentedMovie: URL, into outputURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fragmentedMovie.path) else {
            throw RecordingWriterError.sourceMissing(fragmentedMovie)
        }
        let asset = AVURLAsset(url: fragmentedMovie)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingWriterError.exportUnavailable
        }
        export.shouldOptimizeForNetworkUse = true
        // The export writes next to the destination and is renamed over it
        // only when complete, so a crash mid-export cannot destroy an MP4 that
        // an earlier attempt finished. The export refuses to overwrite, so a
        // leftover from an interrupted attempt is cleared first.
        let temporaryURL = outputURL.deletingPathExtension().appendingPathExtension("finalizing.mp4")
        try? FileManager.default.removeItem(at: temporaryURL)
        try await export.export(to: temporaryURL, as: .mp4)
        guard rename(temporaryURL.path, outputURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: Writer session

    /// The `AVAssetWriter` and its inputs. Only ever touched under the state
    /// lock, except `finishWriting`, which runs after every input is finished.
    fileprivate final class Session: @unchecked Sendable {
        enum Outcome: Sendable {
            case appended
            case notReady
            case failed((any Error)?)
        }

        let writer: AVAssetWriter
        private let video: AVAssetWriterInput
        private let audio: [RecordingAudioSource: AVAssetWriterInput]

        init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: [RecordingAudioSource: AVAssetWriterInput]) {
            self.writer = writer
            self.video = video
            self.audio = audio
        }

        func appendVideo(_ sample: CMSampleBuffer) -> Outcome {
            append(sample, to: video)
        }

        func appendAudio(_ sample: CMSampleBuffer, from source: RecordingAudioSource) -> Outcome {
            guard let input = audio[source] else { return .notReady }
            return append(sample, to: input)
        }

        func markAsFinished() {
            video.markAsFinished()
            for input in audio.values { input.markAsFinished() }
        }

        private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Outcome {
            guard input.isReadyForMoreMediaData else { return .notReady }
            return input.append(sample) ? .appended : .failed(writer.error)
        }
    }

    private func startSession(videoFormat: CMFormatDescription) throws -> Session {
        // The marker goes down first: from here on a movie exists that a
        // crash would leave unfinished.
        let marker = NeedsFinalizeMarker(
            fragmentedMovie: movieURL.lastPathComponent, finalizedMovie: finalizedURL.lastPathComponent,
            startedAt: Date(), processID: ProcessInfo.processInfo.processIdentifier)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL, options: .atomic)

        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        writer.movieFragmentInterval = movieFragmentInterval

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingWriterError.unsupportedFormat }
        writer.add(video)

        var audio: [RecordingAudioSource: AVAssetWriterInput] = [:]
        // Fixed order so the track layout is the same in every file.
        for source in RecordingAudioSource.allCases {
            guard let track = configuration.audioTracks[source] else { continue }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: configuration.audioSampleRate,
                    AVNumberOfChannelsKey: track.channelCount,
                    AVEncoderBitRateKey: track.bitRate,
                ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingWriterError.unsupportedFormat }
            writer.add(input)
            audio[source] = input
        }

        guard writer.startWriting() else { throw RecordingWriterError.writerFailed(writer.error) }
        // Zero is the clock's origin, not the first frame's stamp. ScreenCaptureKit
        // takes 50–500 ms to deliver its first frame, so the video track opens
        // with an empty edit of that length; that is what keeps it aligned
        // with the telemetry and the audio, which start at zero.
        writer.startSession(atSourceTime: .zero)
        return Session(writer: writer, video: video, audio: audio)
    }

    // MARK: Audio placement

    /// Appends `sample` (already on the recording timeline) after reconciling
    /// its start with where the source's previous buffer ended: silence fills a
    /// hole, an overlapping head is cut off.
    private func place(
        _ sample: CMSampleBuffer, from source: RecordingAudioSource, in session: Session, state: inout State
    ) {
        var sample = sample
        let expected = state.audioCursor[source] ?? .zero
        let start = sample.presentationTimeStamp
        if start < expected - configuration.audioGapTolerance {
            do {
                guard let trimmed = try Self.trimmed(sample, toStartAt: expected) else {
                    // Nothing left after the overlap: the audio is already in the file.
                    state.statistics.audioOverlapsTrimmed += 1
                    return
                }
                sample = trimmed
                state.statistics.audioOverlapsTrimmed += 1
            } catch {
                state.statistics.audioDropped += 1
                return
            }
        } else if start > expected + configuration.audioGapTolerance, let format = sample.formatDescription {
            guard fillSilence(from: expected, to: start, like: format, source: source, in: session, state: &state)
            else { return }
        }
        switch session.appendAudio(sample, from: source) {
        case .appended:
            state.statistics.audioBuffers += 1
            state.audioCursor[source] = sample.presentationTimeStamp + sample.duration
            state.audioFormat[source] = sample.formatDescription
        case .notReady:
            state.statistics.audioDropped += 1
        case .failed(let error):
            state.failure = RecordingWriterError.writerFailed(error)
        }
    }

    /// Appends silence in `format` from `start` up to `end`, in buffers of at
    /// most one second, counting each as a filled gap. Returns false when the
    /// input stopped taking data, in which case the cursor stays where the
    /// silence reached and the next buffer picks the hole up again.
    private func fillSilence(
        from start: CMTime, to end: CMTime, like format: CMFormatDescription, source: RecordingAudioSource,
        in session: Session, state: inout State
    ) -> Bool {
        appendSilence(from: start, to: end, like: format, source: source, in: session, state: &state) {
            statistics, seconds in
            statistics.audioGapsFilled += 1
            statistics.audioSilenceSeconds += seconds
        }
    }

    /// At `finish`: silence from each source's cursor up to the stop, so the
    /// track ends with the video. A source whose last buffer already runs
    /// past the stop (the one straddling it is written whole) gets nothing.
    private func padAudioToStop(_ stopTime: CMTime, in session: Session, state: inout State) {
        for source in RecordingAudioSource.allCases {
            guard let format = state.audioFormat[source], let cursor = state.audioCursor[source], cursor < stopTime
            else { continue }
            _ = appendSilence(from: cursor, to: stopTime, like: format, source: source, in: session, state: &state) {
                statistics, seconds in
                statistics.audioEndPadded += 1
                statistics.audioEndPaddingSeconds += seconds
            }
        }
    }

    private func appendSilence(
        from start: CMTime, to end: CMTime, like format: CMFormatDescription, source: RecordingAudioSource,
        in session: Session, state: inout State, count: (inout RecordingWriterStatistics, Double) -> Void
    ) -> Bool {
        guard let layout = PCMLayout(format) else {
            // Not LPCM, so no silence can be synthesized; the hole stays.
            return true
        }
        var cursor = start
        while cursor < end {
            let frames = min(Int(((end - cursor).seconds * layout.sampleRate).rounded()), Int(layout.sampleRate))
            guard frames > 0 else { break }
            let silence: CMSampleBuffer
            do {
                silence = try Self.silence(frames: frames, at: cursor, format: format, layout: layout)
            } catch {
                return true
            }
            switch session.appendAudio(silence, from: source) {
            case .appended:
                count(&state.statistics, silence.duration.seconds)
                cursor = cursor + silence.duration
                state.audioCursor[source] = cursor
            case .notReady:
                state.statistics.audioDropped += 1
                return false
            case .failed(let error):
                state.failure = RecordingWriterError.writerFailed(error)
                return false
            }
        }
        return true
    }

    /// What the silence and trim paths need from an LPCM stream description.
    private struct PCMLayout {
        let sampleRate: Double
        /// Bytes per frame per plane: all channels for interleaved audio, one
        /// channel for non-interleaved, which is how ScreenCaptureKit delivers.
        let bytesPerFrame: Int
        let planes: Int

        init?(_ format: CMFormatDescription) {
            guard let description = format.audioStreamBasicDescription, description.mFormatID == kAudioFormatLinearPCM,
                description.mBytesPerFrame > 0, description.mSampleRate > 0
            else { return nil }
            sampleRate = description.mSampleRate
            bytesPerFrame = Int(description.mBytesPerFrame)
            planes =
                description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                ? Int(description.mChannelsPerFrame) : 1
        }
    }

    /// `sample` with its presentation time moved to `time`; the data is shared.
    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) throws -> CMSampleBuffer {
        let timing = try sample.sampleTimingInfo(at: 0)
        return try CMSampleBuffer(
            copying: sample,
            withNewTiming: [
                CMSampleTimingInfo(duration: timing.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            ])
    }

    /// `sample` without the frames before `start`, or nil when none would be
    /// left. Copies plane by plane, since CoreMedia's own range copy refuses
    /// non-interleaved audio.
    private static func trimmed(_ sample: CMSampleBuffer, toStartAt start: CMTime) throws -> CMSampleBuffer? {
        guard let format = sample.formatDescription, let layout = PCMLayout(format) else {
            throw RecordingWriterError.unsupportedFormat
        }
        let total = sample.numSamples
        let skip = Int(((start - sample.presentationTimeStamp).seconds * layout.sampleRate).rounded())
        guard skip < total else { return nil }
        guard skip > 0 else { return sample }
        let kept = total - skip
        let planeBytes = kept * layout.bytesPerFrame
        let block = try CMBlockBuffer(length: planeBytes * layout.planes, flags: .assureMemoryNow)
        try sample.withAudioBufferList { list, _ in
            var offset = 0
            for buffer in list {
                guard let data = buffer.mData, offset + planeBytes <= planeBytes * layout.planes else { break }
                let source = UnsafeRawBufferPointer(start: data + skip * layout.bytesPerFrame, count: planeBytes)
                try block.withUnsafeMutableBytes(atOffset: offset) { $0.copyMemory(from: source) }
                offset += planeBytes
            }
        }
        let skipped = CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(layout.sampleRate))
        return try CMSampleBuffer(
            dataBuffer: block, formatDescription: format, numSamples: kept,
            presentationTimeStamp: sample.presentationTimeStamp + skipped, packetDescriptions: [])
    }

    private static func silence(frames: Int, at time: CMTime, format: CMFormatDescription, layout: PCMLayout) throws
        -> CMSampleBuffer
    {
        let block = try CMBlockBuffer(length: frames * layout.bytesPerFrame * layout.planes, flags: .assureMemoryNow)
        try block.fillDataBytes(with: 0)
        return try CMSampleBuffer(
            dataBuffer: block, formatDescription: format, numSamples: frames, presentationTimeStamp: time,
            packetDescriptions: [])
    }

    /// A sample-less buffer whose decode time ends the previous video frame
    /// (`kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration`). AVAssetWriter
    /// times every frame but the last by the next frame's decode stamp; this
    /// gives the last one its stamp.
    private static func endMarker(format: CMFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: time)
        var created: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &created)
        guard status == noErr, let marker = created else { throw RecordingWriterError.endMarkerFailed(status) }
        CMSetAttachment(
            marker, key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration, value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return marker
    }
}

extension CMSampleBuffer {
    /// True unless the first sample is marked as depending on others. Absence
    /// of the attachment means sync, per CoreMedia.
    fileprivate var isKeyframe: Bool {
        guard let attachments = sampleAttachments.first else { return true }
        return attachments[.notSync] as? Bool != true
    }
}
