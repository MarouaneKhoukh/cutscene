import CoreMedia
import CoreVideo
import CutsceneCapture
import Foundation

/// Proves the recording path without any permission: synthetic frames and two
/// LPCM tone sources go through `RecordingClock`, `VideoEncoder` and
/// `RecordingWriter`, and ffprobe then checks the finalized MP4 for the
/// properties the editor depends on.
///
/// The run is shaped like a real take rather than a clean stream, so the
/// writer's hard cases are on the test every time: a pause (frames and audio
/// captured during it must vanish, the first frame after it must be a
/// keyframe, the audio join must be sample-exact), a static stretch with no
/// frames (the video track must still run to the stop, not end a frame after
/// the last change), system audio that starts late and loses a buffer (both
/// holes must be filled with silence so the tracks stay in step), and
/// microphone audio that starts before the first frame (the pre-roll path).
enum WriterSpike {
    static let width = 1920
    static let height = 1080
    static let frameRate = 60
    /// Wall-clock seconds from the start of the run.
    static let pauseAt = 0.75
    static let pauseLength = 0.5
    /// The screen goes static: no frames are submitted.
    static let holeStart = 2.25
    static let holeEnd = 3.25
    static let videoEnd = 4.25
    static let stopAt = 5.25
    static let systemAudioStart = 0.25
    static let microphoneAudioStart = -0.2
    /// One system-audio buffer is withheld here, as a dropped buffer would be.
    static let withheldSystemBufferAt = 2.75
    static let frameCountTolerance = 0.05
    /// Keyframes come at least every `frameRate` frames by count and every 2 s
    /// by duration; the duration rule can only act on the next frame, so a
    /// hole adds up to one frame interval.
    static let maximumKeyframeFrames = frameRate
    static let maximumKeyframeSeconds = 2.0 + 1.0 / Double(frameRate) + 0.05
    static let durationTolerance = 0.1

    static func run(arguments: [String]) async -> Bool {
        var codec = VideoCodec.hevc
        for argument in arguments {
            if let named = VideoCodec(rawValue: argument) {
                codec = named
            } else {
                print("unknown argument \(argument); expected hevc or h264")
                return false
            }
        }
        do {
            return try await record(codec: codec)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    private static func record(codec: VideoCodec) async throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cutscene-spike", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let movieURL = directory.appendingPathComponent("writer-\(codec.rawValue)-\(stamp).mov")

        // Stereo interleaved system audio and mono non-interleaved microphone
        // audio: ScreenCaptureKit delivers planar buffers, so the writer's
        // trim and silence paths see both layouts.
        let tones = [
            try ToneSource(source: .system, channels: 2, interleaved: true, frequency: 440),
            try ToneSource(source: .microphone, channels: 1, interleaved: false, frequency: 660),
        ]
        let tracks = Dictionary(
            uniqueKeysWithValues: tones.map {
                ($0.source, RecordingWriterConfiguration.AudioTrack(channelCount: $0.channels))
            })
        let clock = RecordingClock()
        let writer = try RecordingWriter(
            movieURL: movieURL, clock: clock, configuration: RecordingWriterConfiguration(audioTracks: tracks))
        let configuration = VideoEncoderConfiguration(width: width, height: height, frameRate: frameRate, codec: codec)
        let encoder = try VideoEncoder(configuration: configuration, clock: clock) { sample in
            writer.appendVideo(sample)
        }
        print(
            "writer spike: \(width)×\(height) @ \(frameRate) fps, requested \(codec.rawValue), "
                + "encoder \(encoder.codec.rawValue) (\(encoder.isHardwareAccelerated ? "hardware" : "software")), "
                + "target \(configuration.averageBitRate(for: encoder.codec) / 1000) kb/s; "
                + "fragments every \(writer.movieFragmentInterval.seconds) s "
                + "(destination \(writer.destinationIsInternal.map { $0 ? "internal" : "external" } ?? "unknown"))")
        print(
            "timeline (wall s): pause \(pauseAt)–\(pauseAt + pauseLength), static screen \(holeStart)–\(holeEnd), "
                + "video to \(videoEnd), stop at \(stopAt); system audio from \(systemAudioStart) "
                + "(one buffer withheld at \(withheldSystemBufferAt)), microphone from \(microphoneAudioStart)")

        // Paced in real time so the encoder's real-time mode sees the cadence
        // it will see from ScreenCaptureKit, and stamped the way capture is:
        // with the host clock at the moment the frame exists.
        let frames = try FrameSource(width: width, height: height)
        let origin = clock.origin
        func wallTime(_ seconds: Double) -> CMTime {
            origin + CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        }
        var audioTimes = tones.map { tone in
            wallTime(tone.source == .system ? systemAudioStart : microphoneAudioStart)
        }
        var withheld = false
        func feedAudio(until now: CMTime) throws {
            for (index, tone) in tones.enumerated() {
                while audioTimes[index] <= now {
                    let time = audioTimes[index]
                    audioTimes[index] = time + ToneSource.bufferDuration
                    let buffer = try tone.buffer(at: time)
                    if tone.source == .system, !withheld, time >= wallTime(withheldSystemBufferAt) {
                        withheld = true
                        continue
                    }
                    writer.appendAudio(buffer, from: tone.source)
                }
            }
        }

        let start = ContinuousClock.now
        var submittedInRecording = 0
        var submittedInPause = 0
        var resumeTime: CMTime?
        var paused = false
        let slots = Int(videoEnd * Double(frameRate))
        for index in 0..<slots {
            let wall = Double(index) / Double(frameRate)
            try await Task.sleep(until: start + .seconds(wall), tolerance: .milliseconds(1), clock: .continuous)
            if !paused, wall >= pauseAt, wall < pauseAt + pauseLength {
                clock.pause()
                paused = true
            } else if paused, wall >= pauseAt + pauseLength {
                clock.resume()
                paused = false
            }
            let now = RecordingClock.hostTime()
            try feedAudio(until: now)
            if wall >= holeStart, wall < holeEnd { continue }
            try encoder.encode(try frames.frame(index), hostTime: now)
            if paused {
                submittedInPause += 1
            } else {
                submittedInRecording += 1
                if resumeTime == nil, wall >= pauseAt + pauseLength {
                    resumeTime = clock.recordingTime(forHostTime: now)
                }
            }
        }
        // Audio alone to the stop, as when the screen stays still.
        var wall = videoEnd
        while wall < stopAt {
            wall = min(wall + 0.1, stopAt)
            try await Task.sleep(until: start + .seconds(wall), tolerance: .milliseconds(1), clock: .continuous)
            try feedAudio(until: RecordingClock.hostTime())
        }
        clock.stop()
        let recordedSeconds = clock.elapsed.seconds
        try encoder.finish()
        let finalizedURL = try await writer.finish()

        let encoderStatistics = encoder.statistics
        let writerStatistics = writer.statistics
        print(
            "recorded \(String(format: "%.3f", recordedSeconds)) s of \(stopAt) s wall; "
                + "\(submittedInRecording) frames submitted in the recording, \(submittedInPause) during the pause")
        print(
            "encoder: \(encoderStatistics.submittedFrames) submitted, \(encoderStatistics.encodedFrames) encoded, "
                + "\(encoderStatistics.droppedFrames) dropped, \(encoderStatistics.skippedOutsideRecording) skipped "
                + "outside the recording, \(encoderStatistics.droppedNonIncreasing) non-increasing, "
                + "last error \(encoderStatistics.lastErrorStatus ?? 0)")
        print(
            "writer: \(writerStatistics.videoFrames) frames written, "
                + "\(writerStatistics.videoDroppedBeforeKeyframe) dropped before keyframe, "
                + "\(writerStatistics.videoDroppedNotReady) dropped not ready, "
                + "\(writerStatistics.videoDroppedNonIncreasing) non-increasing; "
                + "\(writerStatistics.audioBuffers) audio buffers written, \(writerStatistics.audioDropped) dropped, "
                + "\(writerStatistics.audioOutsideRecording) outside the recording, "
                + "\(writerStatistics.audioGapsFilled) gaps filled with "
                + "\(String(format: "%.3f", writerStatistics.audioSilenceSeconds)) s of silence, "
                + "\(writerStatistics.audioOverlapsTrimmed) overlaps trimmed")
        let size = (try? FileManager.default.attributesOfItem(atPath: finalizedURL.path)[.size] as? Int64) ?? 0
        print("finalized: \(finalizedURL.path) (\(size / 1024) KiB)")

        var failures: [String] = []
        let leftovers = [movieURL, writer.markerURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !leftovers.isEmpty {
            failures.append("leftover files after finalize: \(leftovers.map(\.lastPathComponent))")
        }
        if !encoder.isHardwareAccelerated { failures.append("the encoder is not hardware accelerated") }
        if encoderStatistics.droppedFrames > 0 { failures.append("encoder dropped \(encoderStatistics.droppedFrames)") }
        if encoderStatistics.droppedNonIncreasing > 0 {
            failures.append("encoder refused \(encoderStatistics.droppedNonIncreasing) non-increasing frames")
        }
        if encoderStatistics.skippedOutsideRecording != submittedInPause {
            failures.append(
                "encoder skipped \(encoderStatistics.skippedOutsideRecording) frames, "
                    + "expected the \(submittedInPause) submitted during the pause")
        }
        if writerStatistics.videoDroppedNotReady + writerStatistics.videoDroppedBeforeKeyframe
            + writerStatistics.videoDroppedNonIncreasing > 0
        {
            failures.append("writer dropped video")
        }
        if writerStatistics.audioDropped > 0 {
            failures.append("writer dropped \(writerStatistics.audioDropped) audio")
        }
        if writerStatistics.audioOutsideRecording < 10 {
            failures.append("only \(writerStatistics.audioOutsideRecording) audio buffers fell in the pause")
        }
        // The late system start and the withheld buffer are two holes at least.
        if writerStatistics.audioGapsFilled < 2 {
            failures.append("\(writerStatistics.audioGapsFilled) audio gaps filled, expected at least 2")
        }
        if abs(writerStatistics.audioSilenceSeconds - systemAudioStart) > 0.1 {
            failures.append(
                "\(writerStatistics.audioSilenceSeconds) s of silence, expected about \(systemAudioStart) s "
                    + "(the late system start plus one buffer)")
        }

        guard let ffprobe = findFFprobe() else {
            print("note: ffprobe not found at /opt/homebrew/bin or on PATH; skipping the probe")
            return report(failures)
        }
        let probe = try Probe.run(ffprobe, on: finalizedURL)
        print(
            "ffprobe: codec=\(probe.codec) \(probe.width)×\(probe.height) nb_frames=\(probe.frameCount) "
                + "has_b_frames=\(probe.bFrames) bit_rate=\(probe.bitRate.map { "\($0 / 1000) kb/s" } ?? "n/a") "
                + "start=\(String(format: "%.3f", probe.videoStartTime)) s "
                + "duration=\(String(format: "%.3f", probe.videoDuration)) s")
        let times = probe.keyframeTimes.map { String(format: "%.3f", $0) }.joined(separator: " ")
        let gaps = zip(probe.keyframeTimes.dropFirst(), probe.keyframeTimes).map(-)
        let maximumGap = gaps.max() ?? 0
        let longestGOP = probe.framesPerGOP.max() ?? 0
        print(
            "keyframes (s): \(times)  max gap \(String(format: "%.3f", maximumGap)) s, longest GOP \(longestGOP) frames"
        )
        for track in probe.audioTracks {
            print(
                "audio: codec=\(track.codec) sample_rate=\(track.sampleRate) channels=\(track.channels) "
                    + "start=\(String(format: "%.3f", track.startTime)) s "
                    + "duration=\(String(format: "%.3f", track.duration)) s")
        }

        if probe.codec != encoder.codec.rawValue {
            failures.append("codec \(probe.codec) is not \(encoder.codec.rawValue)")
        }
        if probe.width != width || probe.height != height {
            failures.append("frame size \(probe.width)×\(probe.height) is not \(width)×\(height)")
        }
        if probe.bFrames != 0 { failures.append("has_b_frames=\(probe.bFrames)") }
        if probe.keyframeTimes.isEmpty { failures.append("no keyframes") }
        if longestGOP > maximumKeyframeFrames {
            failures.append("a GOP of \(longestGOP) frames exceeds \(maximumKeyframeFrames)")
        }
        if maximumGap > maximumKeyframeSeconds {
            failures.append("keyframe gap \(maximumGap) s > \(maximumKeyframeSeconds) s")
        }
        if let resumeTime, !probe.keyframeTimes.contains(where: { abs($0 - resumeTime.seconds) < 0.02 }) {
            failures.append("no keyframe at the resume (\(String(format: "%.3f", resumeTime.seconds)) s)")
        }
        let tolerance = Int((Double(submittedInRecording) * frameCountTolerance).rounded())
        if abs(probe.frameCount - submittedInRecording) > tolerance {
            failures.append("nb_frames=\(probe.frameCount) outside \(submittedInRecording) ± \(tolerance)")
        }
        // The last frame lands a second before the stop; the stop marker must
        // stretch it so the video track ends with the audio. The track starts
        // where the first frame was captured (an empty edit covers the gap
        // from time zero), and ffprobe's duration excludes that edit, so the
        // end is start plus duration.
        let videoEnd = probe.videoStartTime + probe.videoDuration
        if abs(videoEnd - recordedSeconds) > durationTolerance {
            failures.append("video ends at \(videoEnd) s, expected ≈ \(String(format: "%.3f", recordedSeconds)) s")
        }
        if probe.audioTracks.count != tones.count {
            failures.append("\(probe.audioTracks.count) audio tracks, expected \(tones.count)")
        }
        for (track, tone) in zip(probe.audioTracks, tones) {
            if track.codec != "aac" || track.sampleRate != 48_000 || track.channels != tone.channels {
                failures.append(
                    "\(tone.source.rawValue) track is \(track.codec) \(track.sampleRate) Hz × \(track.channels), "
                        + "expected aac 48000 Hz × \(tone.channels)")
            }
            let end = track.startTime + track.duration
            if abs(end - recordedSeconds) > durationTolerance {
                failures.append(
                    "\(tone.source.rawValue) track ends at \(end) s, "
                        + "expected ≈ \(String(format: "%.3f", recordedSeconds)) s")
            }
        }
        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    private static func findFFprobe() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffprobe" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    enum SpikeError: LocalizedError {
        case pixelBufferPool(CVReturn)
        case pixelBuffer(CVReturn)
        case audioBuffer(OSStatus)
        case probeExited(Int32)
        case probeOutput(String)

        var errorDescription: String? {
            switch self {
            case .pixelBufferPool(let status): "CVPixelBufferPoolCreate failed (\(status))."
            case .pixelBuffer(let status): "CVPixelBufferPoolCreatePixelBuffer failed (\(status))."
            case .audioBuffer(let status): "Building an LPCM sample buffer failed (\(status))."
            case .probeExited(let status): "ffprobe exited with status \(status)."
            case .probeOutput(let detail): "Could not read ffprobe output: \(detail)."
            }
        }
    }

    /// Synthetic 32BGRA frames: a diagonal gradient that scrolls six pixels
    /// per frame plus a white block crossing the screen, so no two frames
    /// match and the encoder has real motion to code rather than a still.
    private final class FrameSource {
        private let width: Int
        private let height: Int
        private let pool: CVPixelBufferPool
        /// Palette doubled in length so a row of `width` pixels can be copied
        /// from any phase without wrapping.
        private let palette: [UInt32]
        private static let paletteSize = 2048
        private static let blockSize = 160

        init(width: Int, height: Int) throws {
            self.width = width
            self.height = height
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                // IOSurface backing lets the hardware encoder read the frame
                // without a copy, as ScreenCaptureKit's buffers do.
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let pool = created else { throw SpikeError.pixelBufferPool(status) }
            self.pool = pool

            var palette = [UInt32](repeating: 0, count: Self.paletteSize * 2)
            for index in 0..<Self.paletteSize {
                let phase = Double(index) / Double(Self.paletteSize) * 2 * .pi
                let red = UInt32((sin(phase) * 0.5 + 0.5) * 255)
                let green = UInt32((sin(phase + 2 * .pi / 3) * 0.5 + 0.5) * 255)
                let blue = UInt32((sin(phase + 4 * .pi / 3) * 0.5 + 0.5) * 255)
                // Little-endian BGRA in memory is ARGB as a UInt32.
                palette[index] = 0xFF00_0000 | red << 16 | green << 8 | blue
                palette[index + Self.paletteSize] = palette[index]
            }
            self.palette = palette
        }

        func frame(_ index: Int) throws -> CVPixelBuffer {
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer(kCVReturnError) }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let shift = index * 6
            palette.withUnsafeBufferPointer { palette in
                for row in 0..<height {
                    let phase = (row + shift) % Self.paletteSize
                    base.advanced(by: row * bytesPerRow)
                        .copyMemory(from: palette.baseAddress! + phase, byteCount: width * 4)
                }
            }
            let blockX = (index * 9) % (width - Self.blockSize)
            let blockY = (index * 5) % (height - Self.blockSize)
            for row in blockY..<(blockY + Self.blockSize) {
                base.advanced(by: row * bytesPerRow + blockX * 4)
                    .assumingMemoryBound(to: UInt32.self)
                    .update(repeating: 0xFFFF_FFFF, count: Self.blockSize)
            }
            return buffer
        }
    }

    /// LPCM sine tone in the shape ScreenCaptureKit delivers audio: Float32
    /// at 48 kHz, 1024 frames per buffer, interleaved or planar.
    private final class ToneSource {
        static let sampleRate = 48_000
        static let framesPerBuffer = 1024
        static let bufferDuration = CMTime(value: CMTimeValue(framesPerBuffer), timescale: CMTimeScale(sampleRate))

        let source: RecordingAudioSource
        let channels: Int
        let interleaved: Bool
        private let frequency: Double
        private let format: CMAudioFormatDescription
        private var phase = 0.0

        init(source: RecordingAudioSource, channels: Int, interleaved: Bool, frequency: Double) throws {
            self.source = source
            self.channels = channels
            self.interleaved = interleaved
            self.frequency = frequency
            let bytesPerFrame = UInt32(4 * (interleaved ? channels : 1))
            var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            var created: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &created)
            guard status == noErr, let format = created else { throw SpikeError.audioBuffer(status) }
            self.format = format
        }

        /// One buffer whose first frame plays at `time`.
        func buffer(at time: CMTime) throws -> CMSampleBuffer {
            var samples = [Float](repeating: 0, count: Self.framesPerBuffer * channels)
            let step = 2 * .pi * frequency / Double(Self.sampleRate)
            for frame in 0..<Self.framesPerBuffer {
                let value = Float(sin(phase)) * 0.25
                phase = (phase + step).truncatingRemainder(dividingBy: 2 * .pi)
                for channel in 0..<channels {
                    // Planar data is one channel after another; interleaved alternates.
                    let index = interleaved ? frame * channels + channel : channel * Self.framesPerBuffer + frame
                    samples[index] = value
                }
            }

            let byteCount = samples.count * MemoryLayout<Float>.size
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
            guard status == kCMBlockBufferNoErr, let block else { throw SpikeError.audioBuffer(status) }
            status = samples.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
            }
            guard status == kCMBlockBufferNoErr else { throw SpikeError.audioBuffer(status) }

            var sample: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: Self.framesPerBuffer, presentationTimeStamp: time, packetDescriptions: nil,
                sampleBufferOut: &sample)
            guard status == noErr, let sample else { throw SpikeError.audioBuffer(status) }
            return sample
        }
    }

    /// What ffprobe reports about the streams.
    private struct Probe {
        struct AudioTrack {
            var codec: String
            var sampleRate: Int
            var channels: Int
            var startTime: Double
            var duration: Double
        }

        var codec: String
        var width: Int
        var height: Int
        var frameCount: Int
        var bFrames: Int
        var bitRate: Int?
        var videoStartTime: Double
        var videoDuration: Double
        var keyframeTimes: [Double]
        /// Frames from each keyframe up to the next one, in order.
        var framesPerGOP: [Int]
        var audioTracks: [AudioTrack]

        /// ffprobe's JSON; counts and rates it derives arrive as strings.
        private struct StreamReport: Decodable {
            struct Stream: Decodable {
                var codecName: String
                var width: Int?
                var height: Int?
                var frameCount: String?
                var bFrames: Int?
                var bitRate: String?
                var sampleRate: String?
                var channels: Int?
                var startTime: String?
                var duration: String?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case width
                    case height
                    case frameCount = "nb_frames"
                    case bFrames = "has_b_frames"
                    case bitRate = "bit_rate"
                    case sampleRate = "sample_rate"
                    case channels
                    case startTime = "start_time"
                    case duration
                }
            }

            var streams: [Stream]
        }

        static func run(_ ffprobe: URL, on file: URL) throws -> Probe {
            let entries =
                "stream=codec_name,width,height,nb_frames,has_b_frames,bit_rate,sample_rate,channels,start_time,duration"
            let video = try streams(ffprobe, file, selecting: "v:0", entries: entries)
            guard let stream = video.first else { throw SpikeError.probeOutput("no video stream") }
            let audio = try streams(ffprobe, file, selecting: "a", entries: entries)

            // Packet flags need no decoding; "K" marks a keyframe.
            let packets = try output(
                of: ffprobe,
                [
                    "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of",
                    "csv=p=0", file.path,
                ])
            var keyframeTimes: [Double] = []
            var framesPerGOP: [Int] = []
            for line in packets.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 2, let time = Double(fields[0]) else { continue }
                if fields[1].contains("K") {
                    keyframeTimes.append(time)
                    framesPerGOP.append(0)
                }
                if !framesPerGOP.isEmpty { framesPerGOP[framesPerGOP.count - 1] += 1 }
            }

            return Probe(
                codec: stream.codecName, width: stream.width ?? 0, height: stream.height ?? 0,
                frameCount: stream.frameCount.flatMap(Int.init) ?? 0, bFrames: stream.bFrames ?? 0,
                bitRate: stream.bitRate.flatMap(Int.init),
                videoStartTime: stream.startTime.flatMap(Double.init) ?? 0,
                videoDuration: stream.duration.flatMap(Double.init) ?? 0,
                keyframeTimes: keyframeTimes.sorted(), framesPerGOP: framesPerGOP,
                audioTracks: audio.map {
                    AudioTrack(
                        codec: $0.codecName, sampleRate: $0.sampleRate.flatMap(Int.init) ?? 0,
                        channels: $0.channels ?? 0, startTime: $0.startTime.flatMap(Double.init) ?? 0,
                        duration: $0.duration.flatMap(Double.init) ?? 0)
                })
        }

        private static func streams(
            _ ffprobe: URL, _ file: URL, selecting selector: String, entries: String
        ) throws -> [StreamReport.Stream] {
            let json = try output(
                of: ffprobe,
                ["-v", "error", "-select_streams", selector, "-show_entries", entries, "-of", "json", file.path])
            return try JSONDecoder().decode(StreamReport.self, from: Data(json.utf8)).streams
        }

        private static func output(of executable: URL, _ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.standardError
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SpikeError.probeExited(process.terminationStatus) }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
