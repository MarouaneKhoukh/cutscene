import AVFoundation
import CoreMedia
import CoreVideo
import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation
import Synchronization

// MARK: - Errors

/// Why an export did not produce a file. Every case carries text rather
/// than the framework's error object, so it can cross isolation boundaries.
public enum ExportError: Error, LocalizedError, Sendable, Equatable {
    /// `export` was called while the exporter was busy with another job.
    case busy
    /// An `ExportPresetID` that `ExportPreset.standard` has no entry for: a
    /// project written by a newer build that added a preset.
    case unsupportedPreset(ExportPresetID)
    /// A frame rate outside `ExportPreset.frameRates`.
    case unsupportedFrameRate(Int)
    /// `cancel()` or the task's cancellation ended the export; nothing was left on disk.
    case cancelled
    /// The destination volume has less free space than the estimate plus the headroom.
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case readerSetup(String)
    case writerSetup(String)
    /// The asset reader stopped with an error, or would not start.
    case readFailed(String)
    /// The asset writer refused a sample, failed, or would not start.
    case writeFailed(String)
    /// The composition delivered a sample without an image buffer.
    case frameWithoutImage(index: Int)
    /// The composition delivered a frame at or before the previous one;
    /// the self-check's first rule, enforced before the frame is written.
    case nonIncreasingTimestamp(previous: Double, next: Double)
    /// The written file does not match what was written (ARCHITECTURE §6); the
    /// file was deleted. Each string names one failed rule.
    case selfCheckFailed([String])
    /// A folder could not be created or the finished file could not be moved into place.
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "Another export is still running."
        case .unsupportedPreset(let id): "This build cannot export the \(id.rawValue) preset yet."
        case .unsupportedFrameRate(let rate):
            "\(rate) fps is not an export rate; choose one of \(ExportPreset.frameRates)."
        case .cancelled: "The export was cancelled."
        case .insufficientDiskSpace(let required, let available):
            "The export needs about \(required >> 20) MB free; \(available >> 20) MB are available."
        case .readerSetup(let detail): "The asset reader could not be set up: \(detail)"
        case .writerSetup(let detail): "The asset writer could not be set up: \(detail)"
        case .readFailed(let detail): "Reading the composition failed: \(detail)"
        case .writeFailed(let detail): "Writing the export failed: \(detail)"
        case .frameWithoutImage(let index): "Frame \(index) arrived without an image buffer."
        case .nonIncreasingTimestamp(let previous, let next):
            "Frame times went backwards: \(next) s after \(previous) s."
        case .selfCheckFailed(let problems):
            "The exported file failed its self-check: " + problems.joined(separator: "; ")
        case .fileSystem(let detail): detail
        }
    }
}

// MARK: - Job

/// Everything one export needs, as values: the package and the ranges of it
/// to keep, the plan and kit to render with, the preset, the mix levels and
/// where the file goes.
public struct ExportJob: Sendable {
    public var package: RecordingPackage
    /// Recording seconds to keep, in timeline order; the whole recording as
    /// one range for the auto-render, `Timeline.keptRanges()` from the editor.
    public var keptRanges: [ClosedRange<Double>]
    public var plan: RenderPlan
    /// The look to render with; a project's `style`.
    public var kit: BrandKit
    public var preset: ExportPreset
    /// Mix levels in decibels; a project's `export.audio`.
    public var audio: ExportAudioSettings
    /// Where the finished file goes; `~/Movies/Cutscene/Exports` by default.
    public var destinationDirectory: URL
    /// The file's name with its extension; nil names it after the package
    /// plus the preset's suffix. A taken name gets ` 2`, ` 3`, … appended.
    public var fileName: String?

    public init(
        package: RecordingPackage, keptRanges: [ClosedRange<Double>], plan: RenderPlan, kit: BrandKit,
        preset: ExportPreset, audio: ExportAudioSettings = ExportAudioSettings(),
        destinationDirectory: URL = RecordingPackage.defaultExportsDirectory, fileName: String? = nil
    ) {
        self.package = package
        self.keptRanges = keptRanges
        self.plan = plan
        self.kit = kit
        self.preset = preset
        self.audio = audio
        self.destinationDirectory = destinationDirectory
        self.fileName = fileName
    }

    /// A project's export: its timeline's kept ranges, its `style`, its mix
    /// levels, and its export settings' preset unless `preset` says otherwise.
    public init(
        package: RecordingPackage, project: Project, plan: RenderPlan, preset: ExportPreset? = nil,
        destinationDirectory: URL = RecordingPackage.defaultExportsDirectory, fileName: String? = nil
    ) throws {
        self.init(
            package: package, keptRanges: project.timeline.keptRanges().map(\.closedRange), plan: plan,
            kit: project.style, preset: try preset ?? ExportPreset.resolve(project.export), audio: project.export.audio,
            destinationDirectory: destinationDirectory, fileName: fileName)
    }

    /// Seconds the kept ranges add up to, before the composition clips them
    /// to the movie.
    public var keptSeconds: Double {
        keptRanges.reduce(0) { $0 + max($1.upperBound - $1.lowerBound, 0) }
    }

    /// The size and time to expect, from the preset's rates and `keptSeconds`.
    public func estimate(settings: ExportWriterSettings = ExportWriterSettings()) -> ExportEstimate {
        ExportEstimate(
            preset: preset, audioBitRate: settings.audio.bitRate, durationSeconds: keptSeconds,
            headroomFactor: settings.disk.headroomFactor)
    }

    /// The file name in effect; see `fileName`.
    public func resolvedFileName(settings: ExportWriterSettings) -> String {
        if let fileName { return fileName }
        let stem = package.url.deletingPathExtension().lastPathComponent
        return "\(stem)\(preset.fileNameSuffix).\(settings.fileExtension)"
    }

    /// The mix levels as the composition builder takes them: linear gains.
    var compositionSettings: CompositionSettings {
        var settings = CompositionSettings()
        settings.systemAudioGain = Self.linearGain(decibels: audio.systemAudioGainDB)
        settings.microphoneGain = Self.linearGain(decibels: audio.microphoneGainDB)
        return settings
    }

    /// `10^(dB / 20)`, the amplitude ratio a level in decibels names.
    static func linearGain(decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }
}

/// What an export is expected to cost before it starts (ARCHITECTURE §6).
public struct ExportEstimate: Sendable, Hashable {
    /// The file's size from the average bit rates, times the disk headroom.
    public var bytes: Int64
    /// Wall seconds at the preset's estimated speed.
    public var seconds: Double

    public init(preset: ExportPreset, audioBitRate: Int, durationSeconds: Double, headroomFactor: Double) {
        let bitsPerSecond = Double(preset.rateControl.averageBitRate + audioBitRate)
        bytes = Int64((bitsPerSecond / 8 * max(durationSeconds, 0) * headroomFactor).rounded(.up))
        seconds = max(durationSeconds, 0) / max(preset.estimatedSpeed, Double.leastNonzeroMagnitude)
    }
}

// MARK: - Result

/// What a finished export produced and how it went.
public struct ExportResult: Sendable, Hashable {
    public var outputURL: URL
    public var preset: ExportPreset
    /// The composition's duration: what the file was checked against.
    public var durationSeconds: Double
    /// Frames in the written file, counted back from it.
    public var frameCount: Int
    public var expectedFrameCount: Int
    public var audioBuffersWritten: Int
    public var fileSizeBytes: Int64
    /// Wall seconds from the first frame to the last track finishing.
    public var encodingSeconds: Double
    /// Wall seconds `finishWriting` took: closing the file, `moov` to the front.
    public var finishingSeconds: Double
    /// Wall seconds of the whole export, preparation and self-check included.
    public var elapsedSeconds: Double
    /// Whether `moov` precedes `mdat` in the file.
    public var isFaststart: Bool
    public var compositor: MetalCompositorStatistics?

    /// Multiples of real time the whole export ran at.
    public var speed: Double {
        elapsedSeconds > 0 ? durationSeconds / elapsedSeconds : 0
    }

    /// Multiples of real time the encoding alone ran at.
    public var encodingSpeed: Double {
        encodingSeconds > 0 ? durationSeconds / encodingSeconds : 0
    }

    /// The file's overall bit rate in bits per second, audio and container included.
    public var averageBitRate: Double {
        durationSeconds > 0 ? Double(fileSizeBytes) * 8 / durationSeconds : 0
    }
}

// MARK: - Exporter

/// Renders a composition to an MP4 (ARCHITECTURE §6): the composition
/// `CompositionBuilder` makes for the preset's canvas is read through an
/// `AVAssetReaderVideoCompositionOutput` (so `MetalCompositor` draws every
/// frame, as it does for the preview) and an `AVAssetReaderAudioMixOutput`,
/// and written by an `AVAssetWriter` to a hidden file beside the
/// destination; the file is checked against what was written and renamed
/// into place, so a reader of the destination folder never sees a partial
/// export.
///
/// One job at a time per instance. `cancel()` ends the running job at the
/// next frame and leaves nothing on disk; so does cancelling the task that
/// awaits `export`.
public actor Exporter {
    public let settings: ExportWriterSettings
    private var pump: ExportPump?
    private var isExporting = false
    private var cancelRequested = false

    public init(settings: ExportWriterSettings = ExportWriterSettings()) {
        self.settings = settings
    }

    /// Whether a job is running.
    public var isBusy: Bool { isExporting }

    /// Runs `job` to completion and returns the finished file. `onProgress`
    /// is called from the export's own queues, at most every
    /// `settings.progressInterval` seconds while frames flow and at every
    /// phase change; hop to the main actor before touching UI.
    public func export(
        _ job: ExportJob, onProgress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportResult {
        guard !isExporting else { throw ExportError.busy }
        isExporting = true
        cancelRequested = false
        defer {
            isExporting = false
            pump = nil
        }
        let started = ContinuousClock.now
        let reporter = ProgressReporter(callback: onProgress, interval: settings.progressInterval, started: started)
        reporter.report(phase: .preparing, force: true)

        let style = RenderStyle(kit: job.kit, canvas: job.preset.canvas)
        let atlas = CursorAtlas.load(for: job.plan, in: job.package)
        let directory = job.destinationDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.fileSystem("Could not create \(directory.path): \(error.localizedDescription)")
        }
        let temporaryURL = directory.appendingPathComponent(settings.temporaryFilePrefix + UUID().uuidString)
            .appendingPathExtension(settings.fileExtension)
        let pump = try await ExportPump.make(
            job: job, style: style, atlas: atlas, outputURL: temporaryURL, settings: settings, reporter: reporter)
        self.pump = pump
        try checkCancellation()
        try Self.guardDiskSpace(
            directory: directory, preset: job.preset, settings: settings, durationSeconds: pump.durationSeconds)

        let summary = try await withTaskCancellationHandler {
            try await pump.run()
        } onCancel: {
            pump.cancel()
        }

        // From here the file exists and is complete; any failure removes it.
        do {
            try checkCancellation()
            reporter.report(phase: .verifying, force: true)
            let verified = try await Self.verify(
                outputURL: temporaryURL, durationSeconds: pump.durationSeconds, canvas: job.preset.canvas,
                expectedFrames: pump.expectedFrames, framesWritten: summary.framesWritten,
                audioDurationSeconds: pump.hasAudio ? pump.audioDurationSeconds : nil, settings: settings.selfCheck)
            // The last moment a cancel can be honoured: once the file is
            // moved into place it is the user's.
            try checkCancellation()
            let finalURL = RecordingPackage.availableURL(
                for: directory.appendingPathComponent(job.resolvedFileName(settings: settings)))
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            } catch {
                throw ExportError.fileSystem(
                    "Could not move the export to \(finalURL.path): \(error.localizedDescription)")
            }
            reporter.report(phase: .done, force: true)
            return ExportResult(
                outputURL: finalURL, preset: job.preset, durationSeconds: pump.durationSeconds,
                frameCount: verified.frameCount, expectedFrameCount: pump.expectedFrames,
                audioBuffersWritten: summary.audioBuffersWritten, fileSizeBytes: verified.fileSizeBytes,
                encodingSeconds: summary.encodingSeconds, finishingSeconds: summary.finishingSeconds,
                elapsedSeconds: Self.seconds(since: started), isFaststart: verified.isFaststart,
                compositor: summary.compositor)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Ends the running export at the next frame, deleting what was written.
    /// `export` then throws `ExportError.cancelled`. A no-op when idle, and
    /// too late once the finished file has been moved into place, which is
    /// the last thing `export` does before returning.
    public func cancel() {
        cancelRequested = true
        pump?.cancel()
    }

    // MARK: Private

    private func checkCancellation() throws {
        guard !cancelRequested, !Task.isCancelled else { throw ExportError.cancelled }
    }

    /// Refuses to start an export the destination volume cannot hold: the
    /// estimate from the bit rates with headroom, plus the free space that
    /// must remain. A volume that reports no capacity is not second-guessed.
    static func guardDiskSpace(
        directory: URL, preset: ExportPreset, settings: ExportWriterSettings, durationSeconds: Double
    ) throws {
        let estimate = ExportEstimate(
            preset: preset, audioBitRate: settings.audio.bitRate, durationSeconds: durationSeconds,
            headroomFactor: settings.disk.headroomFactor)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let required = estimate.bytes + settings.disk.minimumFreeBytes
        guard available >= required else {
            throw ExportError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    /// What the self-check established about the written file.
    struct VerifiedOutput: Sendable {
        var frameCount: Int
        var fileSizeBytes: Int64
        var isFaststart: Bool
    }

    /// Reads the written file back (ARCHITECTURE §6, research §5.2): the
    /// video track's natural size must be the canvas; the video samples are
    /// counted without decoding and their presentation times, sorted, must
    /// step by one frame; the count must match what was written and
    /// `duration × fps ± 1`; the movie and its video track must be as long
    /// as the composition within tolerance, its audio track as long as the
    /// composition's audio (`audioDurationSeconds`, nil for a silent
    /// composition; the mix output ends with the last audio sample, so a
    /// source whose audio stops before its video is not a writer fault);
    /// and `moov` must precede `mdat`. Any miss throws `selfCheckFailed`
    /// with every rule that failed, so a bad file is never moved into place.
    static func verify(
        outputURL: URL, durationSeconds: Double, canvas: CanvasSpec, expectedFrames: Int, framesWritten: Int,
        audioDurationSeconds: Double?, settings: ExportSelfCheckSettings
    ) async throws -> VerifiedOutput {
        var problems: [String] = []
        let frameSeconds = 1 / Double(canvas.frameRate)
        let durationTolerance = frameSeconds * Double(settings.durationToleranceFrames) + settings.timestampTolerance
        let asset = AVURLAsset(url: outputURL)
        let (assetDuration, tracks) = try await asset.load(.duration, .tracks)
        if abs(assetDuration.seconds - durationSeconds) > durationTolerance {
            problems.append(
                "movie duration \(assetDuration.seconds) s, composition \(durationSeconds) s (± \(durationTolerance) s)"
            )
        }
        var frameCount = 0
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            let (timeRange, naturalSize) = try await videoTrack.load(.timeRange, .naturalSize)
            if settings.requiresCanvasSize,
                Int(naturalSize.width.rounded()) != canvas.width || Int(naturalSize.height.rounded()) != canvas.height
            {
                problems.append(
                    "video track is \(Int(naturalSize.width.rounded()))×\(Int(naturalSize.height.rounded())), "
                        + "the canvas \(canvas.width)×\(canvas.height)")
            }
            if abs(timeRange.duration.seconds - durationSeconds) > durationTolerance {
                problems.append(
                    "video track duration \(timeRange.duration.seconds) s, composition \(durationSeconds) s")
            }
            let times = try sampleTimes(of: videoTrack, in: asset)
            frameCount = times.count
            if frameCount != framesWritten {
                problems.append("\(frameCount) frames in the file, \(framesWritten) written")
            }
            if abs(frameCount - expectedFrames) > settings.frameCountTolerance {
                problems.append(
                    "\(frameCount) frames, expected \(expectedFrames) ± \(settings.frameCountTolerance) "
                        + "(\(durationSeconds) s × \(canvas.frameRate) fps)")
            }
            let sorted = times.sorted()
            let irregular = zip(sorted.dropFirst(), sorted).filter {
                abs(($0 - $1) - frameSeconds) > settings.timestampTolerance
            }
            if !irregular.isEmpty {
                problems.append("\(irregular.count) frame intervals differ from \(frameSeconds) s")
            }
        } else {
            problems.append("no video track")
        }
        if let audioDurationSeconds {
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                let timeRange = try await audioTrack.load(.timeRange)
                if abs(timeRange.duration.seconds - audioDurationSeconds) > settings.audioDurationTolerance {
                    problems.append(
                        "audio track duration \(timeRange.duration.seconds) s, composition audio "
                            + "\(audioDurationSeconds) s (± \(settings.audioDurationTolerance) s)")
                }
            } else {
                problems.append("no audio track")
            }
        }
        let boxes = try topLevelBoxTypes(of: outputURL, limit: settings.boxScanLimit)
        let isFaststart: Bool
        if let moov = boxes.firstIndex(of: "moov"), let mdat = boxes.firstIndex(of: "mdat") {
            isFaststart = moov < mdat
        } else {
            isFaststart = false
        }
        if settings.requiresFaststart, !isFaststart {
            problems.append("moov does not precede mdat (boxes: \(boxes.joined(separator: " ")))")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard problems.isEmpty else { throw ExportError.selfCheckFailed(problems) }
        return VerifiedOutput(frameCount: frameCount, fileSizeBytes: fileSize, isFaststart: isFaststart)
    }

    /// The presentation time of every sample of `track`, in file order. A
    /// sample reference output vends timing and byte ranges without loading
    /// the sample data, so a long 4K export is not read back whole.
    private static func sampleTimes(of track: AVAssetTrack, in asset: AVAsset) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderSampleReferenceOutput(track: track)
        guard reader.canAdd(output) else {
            throw ExportError.selfCheckFailed(["the file's video track cannot be read"])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.selfCheckFailed([
                "reading the file back failed: \(reader.error?.localizedDescription ?? "")"
            ])
        }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 1 {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            } else {
                for index in 0..<count {
                    var timing = CMSampleTimingInfo()
                    CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
                    times.append(timing.presentationTimeStamp.seconds)
                }
            }
        }
        guard reader.status == .completed else {
            throw ExportError.selfCheckFailed([
                "reading the file back ended with \(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")"
            ])
        }
        return times
    }

    /// The types of the file's first top-level MP4 boxes, in order; the
    /// 64-bit and to-end size forms are honoured.
    static func topLevelBoxTypes(of url: URL, limit: Int) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        var types: [String] = []
        while offset + 8 <= fileSize, types.count < limit {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let size32 = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header[header.startIndex + 4..<header.startIndex + 8], as: UTF8.self)
            var size = size32
            if size32 == 1 {
                guard header.count >= 16 else { break }
                size = header[header.startIndex + 8..<header.startIndex + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= 8 else { break }
            types.append(type)
            offset += size
        }
        return types
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

// MARK: - Progress reporting

/// Throttles progress callbacks: a report goes out at every phase change,
/// when forced, and otherwise at most once per interval.
final class ProgressReporter: @unchecked Sendable {
    private struct State {
        var lastReport: ContinuousClock.Instant?
        var phase = ExportPhase.preparing
        var writtenSeconds = 0.0
        var framesWritten = 0
        var durationSeconds = 0.0
        var expectedFrames = 0
    }

    private let callback: @Sendable (ExportProgress) -> Void
    private let interval: Duration
    private let started: ContinuousClock.Instant
    private let state = Mutex(State())

    init(callback: @escaping @Sendable (ExportProgress) -> Void, interval: Double, started: ContinuousClock.Instant) {
        self.callback = callback
        self.interval = .seconds(max(interval, 0))
        self.started = started
    }

    /// Tells the reporter how long the export will be, once the composition exists.
    func configure(durationSeconds: Double, expectedFrames: Int) {
        state.withLock { state in
            state.durationSeconds = durationSeconds
            state.expectedFrames = expectedFrames
        }
    }

    func report(phase: ExportPhase, writtenSeconds: Double? = nil, framesWritten: Int? = nil, force: Bool = false) {
        let now = ContinuousClock.now
        let progress: ExportProgress? = state.withLock { state in
            let phaseChanged = state.phase != phase
            state.phase = phase
            if let writtenSeconds { state.writtenSeconds = writtenSeconds }
            if let framesWritten { state.framesWritten = framesWritten }
            let due = state.lastReport.map { now - $0 >= interval } ?? true
            guard force || phaseChanged || due else { return nil }
            state.lastReport = now
            return ExportProgress(
                phase: phase, writtenSeconds: state.writtenSeconds, durationSeconds: state.durationSeconds,
                framesWritten: state.framesWritten, expectedFrames: state.expectedFrames,
                elapsedSeconds: Exporter.seconds(since: started))
        }
        if let progress { callback(progress) }
    }
}

// MARK: - Pump

/// The reader-to-writer loop of one export: the video composition output
/// and the audio mix output of an `AVAssetReader` feeding the inputs of an
/// `AVAssetWriter` through `requestMediaDataWhenReady`, one serial queue per
/// track, with the state the two queues, the writer's completion and
/// `cancel()` share behind a `Mutex`.
///
/// Teardown (cancel or failure) runs on the video queue after fencing the
/// audio queue, because `cancelWriting` must not run concurrently with an
/// append (AVAssetWriter.h); the pumps check the shared state before every
/// append and return as soon as it says stop. A cancel that arrives while
/// `finishWriting` runs lets it finish and deletes the file after.
final class ExportPump: @unchecked Sendable {
    /// What the pump wrote, for the result.
    struct Summary: Sendable {
        var framesWritten: Int
        var audioBuffersWritten: Int
        var encodingSeconds: Double
        var finishingSeconds: Double
        var compositor: MetalCompositorStatistics?
    }

    private enum Phase {
        case idle
        /// The reader and the writer are being started; a cancel waits for
        /// `start` to notice it rather than tearing down what does not exist yet.
        case starting
        case running
        case finishing
        case ended
    }

    private struct State {
        var phase = Phase.idle
        var cancelled = false
        var failure: ExportError?
        var continuation: CheckedContinuation<Summary, any Error>?
        var videoFinished = false
        var audioFinished: Bool
        var framesWritten = 0
        var audioBuffersWritten = 0
        var lastVideoTime: CMTime?
        var writtenEnd = CMTime.zero
        var started: ContinuousClock.Instant?
        var encodingEnded: ContinuousClock.Instant?

        var isStopped: Bool { cancelled || failure != nil || phase == .ended }
    }

    let durationSeconds: Double
    let expectedFrames: Int
    let hasAudio: Bool
    /// Seconds the composition's audio runs for: the end of its last audio
    /// track, at most the composition's duration. What the self-check holds
    /// the written audio to.
    let audioDurationSeconds: Double
    let outputURL: URL
    private let duration: CMTime
    private let frameDuration: CMTime
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let videoQueue = DispatchQueue(label: "app.cutscene.export.video")
    private let audioQueue = DispatchQueue(label: "app.cutscene.export.audio")
    private let reporter: ProgressReporter
    private let state: Mutex<State>

    /// Builds the composition for `job` and the reader and writer over it.
    /// Nothing touches the disk until `run()`.
    static func make(
        job: ExportJob, style: RenderStyle, atlas: CursorAtlas, outputURL: URL, settings: ExportWriterSettings,
        reporter: ProgressReporter
    ) async throws -> ExportPump {
        let built = try await CompositionBuilder.build(
            package: job.package, keptRanges: job.keptRanges, plan: job.plan, style: style, cursor: atlas,
            canvas: job.preset.canvas, settings: job.compositionSettings)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioEnd = CMTime.zero
        for track in audioTracks {
            audioEnd = CMTimeMaximum(audioEnd, try await track.load(.timeRange).end)
        }
        return try ExportPump(
            built: built, videoTracks: videoTracks, audioTracks: audioTracks,
            audioDurationSeconds: CMTimeMinimum(audioEnd, built.duration).seconds, preset: job.preset,
            outputURL: outputURL, settings: settings, reporter: reporter)
    }

    private init(
        built: BuiltComposition, videoTracks: [AVAssetTrack], audioTracks: [AVAssetTrack],
        audioDurationSeconds: Double, preset: ExportPreset, outputURL: URL, settings: ExportWriterSettings,
        reporter: ProgressReporter
    ) throws {
        duration = built.duration
        durationSeconds = built.duration.seconds
        frameDuration = built.canvas.frameDuration
        expectedFrames = built.expectedFrameCount
        hasAudio = !audioTracks.isEmpty
        self.audioDurationSeconds = audioDurationSeconds
        self.outputURL = outputURL
        self.reporter = reporter
        reporter.configure(durationSeconds: durationSeconds, expectedFrames: expectedFrames)
        state = Mutex(State(audioFinished: audioTracks.isEmpty))

        reader = try AVAssetReader(asset: built.composition)
        videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.readerSetup("the reader refused the video composition output")
        }
        reader.add(videoOutput)
        if audioTracks.isEmpty {
            audioOutput = nil
        } else {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks, audioSettings: settings.audioMixOutputSettings())
            output.audioMix = built.audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ExportError.readerSetup("the reader refused the audio mix output")
            }
            reader.add(output)
            audioOutput = output
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = settings.optimizeForNetworkUse
        writer.movieTimeScale = settings.videoTimescale
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings(for: preset))
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = settings.videoTimescale
        guard writer.canAdd(videoInput) else { throw ExportError.writerSetup("the writer refused the video input") }
        writer.add(videoInput)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: ExportWriterSettings.sourcePixelBufferAttributes)
        if audioOutput == nil {
            audioInput = nil
        } else {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioOutputSettings())
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerSetup("the writer refused the audio input") }
            writer.add(input)
            audioInput = input
        }
    }

    /// Runs the export to the end of the composition and returns what was
    /// written; throws `ExportError.cancelled` after `cancel()`, or the
    /// failure that stopped it. The output file exists only on return.
    func run() async throws -> Summary {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation)
        }
    }

    /// Stops the export at the next frame. Safe from any thread, any number of times.
    func cancel() {
        let tearDownNow: Bool = state.withLock { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return state.phase == .running
        }
        if tearDownNow {
            videoQueue.async { self.tearDown() }
        }
    }

    // MARK: Private

    private var compositor: MetalCompositor? {
        videoOutput.customVideoCompositor as? MetalCompositor
    }

    /// Starts the reader and the writer, then opens the pumps. The phase is
    /// `running` only once both have started: a cancel that lands in
    /// between is noticed here and torn down with the reader and writer it
    /// would otherwise have missed (a reader reading ahead for nobody, a
    /// writer's work file left beside the destination).
    private func start(_ continuation: CheckedContinuation<Summary, any Error>) {
        let proceed: Bool = state.withLock { state in
            state.continuation = continuation
            guard state.phase == .idle, !state.cancelled else { return false }
            state.phase = .starting
            state.started = .now
            return true
        }
        guard proceed else {
            videoQueue.async { self.tearDown() }
            return
        }
        var startFailure: ExportError?
        if !reader.startReading() {
            startFailure = .readFailed(reader.error?.localizedDescription ?? "startReading returned false")
        } else if !writer.startWriting() {
            startFailure = .writeFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        } else {
            writer.startSession(atSourceTime: .zero)
        }
        let stopped: Bool = state.withLock { state in
            state.phase = .running
            if let startFailure, state.failure == nil { state.failure = startFailure }
            return state.isStopped
        }
        guard !stopped else {
            videoQueue.async { self.tearDown() }
            return
        }
        reporter.report(phase: .encoding, writtenSeconds: 0, framesWritten: 0, force: true)
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in self?.pumpVideo() }
        if let audioInput {
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in self?.pumpAudio() }
        }
    }

    private func pumpVideo() {
        defer { failIfWriterFailed() }
        while videoInput.isReadyForMoreMediaData {
            guard !state.withLock({ $0.isStopped }) else { return }
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                outputEnded(video: true)
                return
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let (index, previous) = state.withLock { ($0.framesWritten, $0.lastVideoTime) }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                fail(.frameWithoutImage(index: index))
                return
            }
            if let previous, time <= previous {
                fail(.nonIncreasingTimestamp(previous: previous.seconds, next: time.seconds))
                return
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                appendFailed()
                return
            }
            let (frames, end) = state.withLock { state -> (Int, Double) in
                state.framesWritten += 1
                state.lastVideoTime = time
                state.writtenEnd = time + frameDuration
                return (state.framesWritten, state.writtenEnd.seconds)
            }
            reporter.report(phase: .encoding, writtenSeconds: end, framesWritten: frames)
        }
    }

    private func pumpAudio() {
        guard let audioInput, let audioOutput else { return }
        defer { failIfWriterFailed() }
        while audioInput.isReadyForMoreMediaData {
            guard !state.withLock({ $0.isStopped }) else { return }
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                outputEnded(video: false)
                return
            }
            guard audioInput.append(sample) else {
                appendFailed()
                return
            }
            state.withLock { $0.audioBuffersWritten += 1 }
        }
    }

    /// An output returned nil: the end of its track, or the reader stopped.
    /// A writer that failed meanwhile (disk full, an encoder error after
    /// the last append) is noticed here too: nothing else would observe it,
    /// since a failed writer asks for no more media and never completes.
    private func outputEnded(video: Bool) {
        switch reader.status {
        case .failed:
            fail(.readFailed(reader.error?.localizedDescription ?? "the reader failed without an error"))
        case .cancelled:
            // The cancel's teardown is on its way.
            return
        default:
            switch writer.status {
            case .writing:
                (video ? videoInput : audioInput)?.markAsFinished()
                trackFinished(video: video)
            case .failed:
                fail(.writeFailed(writer.error?.localizedDescription ?? "the writer failed without an error"))
            case .cancelled, .completed, .unknown:
                // Cancelled: the teardown is on its way. The other two cannot
                // follow a running pump.
                return
            @unknown default:
                return
            }
        }
    }

    /// A pump loop ended because its input stopped taking data: when that is
    /// the writer failing rather than back-pressure, the failure is recorded,
    /// since the input will never ask for media again.
    private func failIfWriterFailed() {
        guard writer.status == .failed else { return }
        fail(.writeFailed(writer.error?.localizedDescription ?? "the writer failed without an error"))
    }

    /// An append returned false: the writer failed, or was cancelled underneath.
    private func appendFailed() {
        switch writer.status {
        case .cancelled:
            return
        default:
            fail(.writeFailed(writer.error?.localizedDescription ?? "append returned false"))
        }
    }

    private func trackFinished(video: Bool) {
        let shouldFinish: Bool = state.withLock { state in
            if video {
                state.videoFinished = true
            } else {
                state.audioFinished = true
            }
            guard state.phase == .running, state.videoFinished, state.audioFinished, !state.isStopped else {
                return false
            }
            state.phase = .finishing
            state.encodingEnded = .now
            return true
        }
        guard shouldFinish else { return }
        reporter.report(phase: .finishing, force: true)
        // The last frame's duration otherwise runs a whole frame past the
        // composition; the session end pins the movie to the composition.
        writer.endSession(atSourceTime: duration)
        writer.finishWriting { self.finished() }
    }

    /// The writer's completion: the file is closed, or the writer failed, or
    /// a cancel arrived while it was finishing.
    private func finished() {
        let (continuation, cancelled, summary) = state.withLock {
            state -> (CheckedContinuation<Summary, any Error>?, Bool, Summary) in
            let continuation = state.continuation
            state.continuation = nil
            state.phase = .ended
            let now = ContinuousClock.now
            let started = state.started ?? now
            let encodingEnded = state.encodingEnded ?? now
            let summary = Summary(
                framesWritten: state.framesWritten, audioBuffersWritten: state.audioBuffersWritten,
                encodingSeconds: Self.seconds(from: started, to: encodingEnded),
                finishingSeconds: Self.seconds(from: encodingEnded, to: now), compositor: nil)
            return (continuation, state.cancelled, summary)
        }
        let compositor = compositor
        compositor?.flush()
        if writer.status == .completed, !cancelled {
            var summary = summary
            summary.compositor = compositor?.statistics
            continuation?.resume(returning: summary)
        } else {
            removeOutputFile()
            let error: ExportError =
                cancelled
                ? .cancelled : .writeFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
            continuation?.resume(throwing: error)
        }
    }

    private func fail(_ error: ExportError) {
        let shouldTearDown: Bool = state.withLock { state in
            guard state.phase == .running, !state.isStopped else { return false }
            state.failure = error
            return true
        }
        if shouldTearDown {
            videoQueue.async { self.tearDown() }
        }
    }

    /// On the video queue: ends the pump after a cancel or a failure. The
    /// stop is recorded first so no pump block starts another append, the
    /// audio queue is fenced so none is in flight, and only then is the
    /// writer cancelled; what it leaves on disk is removed before the
    /// caller is resumed, so a cancelled export leaves nothing behind.
    private func tearDown() {
        let (continuation, error) = state.withLock { state -> (CheckedContinuation<Summary, any Error>?, ExportError) in
            let continuation = state.continuation
            state.continuation = nil
            state.phase = .ended
            return (continuation, state.cancelled ? .cancelled : (state.failure ?? .cancelled))
        }
        audioQueue.sync {}
        if reader.status == .reading {
            reader.cancelReading()
        }
        if writer.status == .writing {
            writer.cancelWriting()
        }
        compositor?.flush()
        removeOutputFile()
        continuation?.resume(throwing: error)
    }

    /// Removes the output file and the writer's work file beside it: the
    /// writer builds the movie in a sibling named after the output
    /// (`<name>.sb-…`) and renames it at `finishWriting`; after a cancel it
    /// removes that sibling only when it is deallocated, which is later than
    /// the caller looks at the folder. The output's name holds a UUID, so
    /// the prefix matches nothing else.
    private func removeOutputFile() {
        let manager = FileManager.default
        if manager.fileExists(atPath: outputURL.path) {
            try? manager.removeItem(at: outputURL)
        }
        let directory = outputURL.deletingLastPathComponent()
        let prefix = outputURL.lastPathComponent + "."
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
