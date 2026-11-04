import AVFoundation
import CoreMedia
import CutsceneCore
import CutsceneEngine
import Foundation

/// Why a composition could not be built from a package.
public enum CompositionBuilderError: Error, LocalizedError, Sendable {
    /// The screen movie has no video track.
    case noScreenTrack(URL)
    /// A kept range is not a finite span inside the recording.
    case invalidKeptRange(start: Double, end: Double)
    /// No kept range covers any of the recording.
    case nothingKept

    public var errorDescription: String? {
        switch self {
        case .noScreenTrack(let url): "\(url.lastPathComponent) has no video track."
        case .invalidKeptRange(let start, let end): "The kept range \(start)–\(end) s is not a span of the recording."
        case .nothingKept: "No kept range covers any of the recording."
        }
    }
}

/// The knobs of the composition that are not part of the look.
public struct CompositionSettings: Sendable, Hashable {
    /// Linear gain of the system-audio track through the audio mix; 1 is unity.
    public var systemAudioGain: Float = 1
    /// Linear gain of the microphone track; 1 is unity.
    public var microphoneGain: Float = 1
    /// Timescale for the kept-range arithmetic when the screen track reports
    /// none; the QuickTime default.
    public var fallbackTimescale: CMTimeScale = 600

    public init() {}
}

/// What `CompositionBuilder.build` returns: the composition and the two
/// objects a player item or an asset reader attaches to it. The objects are
/// the engine's and are handed to it as they are; the rest is for the caller.
public struct BuiltComposition {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    /// nil when the recording has no audio track.
    public let audioMix: AVMutableAudioMix?
    public let screenTrackID: CMPersistentTrackID
    /// The composition track carrying `camera.mp4`; `kCMPersistentTrackID_Invalid`
    /// when the recording has no camera (or its movie is missing).
    public let cameraTrackID: CMPersistentTrackID
    /// One per kept range, in composition order; also set on `videoComposition`.
    public let instructions: [RenderInstruction]
    public let duration: CMTime
    public let canvas: CanvasSpec

    /// How many frames reading the composition at the canvas rate yields.
    public var expectedFrameCount: Int {
        canvas.frameCount(forDuration: duration.seconds)
    }
}

/// Builds the `AVMutableComposition` that preview and export share
/// (ARCHITECTURE §5): one insert of the screen movie per kept range, back
/// to back, with the audio tracks alongside and the camera movie's video
/// track, when there is one, on a track of its own; an
/// `AVMutableVideoComposition` that runs `MetalCompositor` at the canvas size
/// and a constant frame rate over one `RenderInstruction` per kept range;
/// and an `AVMutableAudioMix` with one level per audio track.
///
/// The caller passes the kept ranges (`Timeline.keptRanges()`, or the whole
/// recording as one range for the M1 auto-render), so no project is needed.
/// Whether the bubble is drawn is the plan's: a plan built with a camera in
/// its layout settings places one, and the instruction's camera track feeds
/// it.
public enum CompositionBuilder {
    /// Builds the composition for `package` over `keptRanges`, in recording
    /// seconds and in timeline order.
    ///
    /// Every range is clipped to the movie's media: its start is raised to
    /// the screen track's first frame (the recorder opens the track with an
    /// empty edit from the clock origin to the first captured frame, and a
    /// composition starting inside it would open on an empty card, which is
    /// the poster Finder and QuickTime show), and its end is lowered to the
    /// shortest track's end (a recovered take's audio can end up to a
    /// fragment before its video, and the export's self-check compares the
    /// audio written with the composition). The instruction's time mapping
    /// follows the clipped start, so recording time stays exact; the audio
    /// before the first frame, at most the stream's start latency, is
    /// dropped. A range that is empty after clipping is skipped.
    public static func build(
        package: RecordingPackage, keptRanges: [ClosedRange<Double>], plan: RenderPlan, style: RenderStyle,
        cursor: CursorAtlas, canvas: CanvasSpec, settings: CompositionSettings = CompositionSettings()
    ) async throws -> BuiltComposition {
        let manifest = try package.manifest()
        let asset = AVURLAsset(url: package.screenMovieURL)
        let tracks = try await asset.load(.tracks)
        guard let screenTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw CompositionBuilderError.noScreenTrack(package.screenMovieURL)
        }
        let (naturalTimeScale, formatDescriptions, screenSegments) = try await screenTrack.load(
            .naturalTimeScale, .formatDescriptions, .segments)
        // The movie's own precision: a cut rounded to it loses nothing the
        // samples could tell apart.
        let timescale = naturalTimeScale > 0 ? naturalTimeScale : settings.fallbackTimescale
        let firstFrame = screenSegments.first { !$0.isEmpty }?.timeMapping.target.start ?? .zero
        var mediaEnd = try await screenTrack.load(.timeRange).end
        for track in tracks where track.mediaType == .audio {
            mediaEnd = CMTimeMinimum(mediaEnd, try await track.load(.timeRange).end)
        }

        // One insert per kept range. The asset-level insert carries the
        // movie's edit list with it, so a hole in the video track inside a
        // range stays an empty edit here and the audio keeps its place.
        let composition = AVMutableComposition()
        var segments: [(offset: CMTime, sourceStart: CMTime, duration: CMTime)] = []
        var offset = CMTime.zero
        for range in keptRanges {
            guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0 else {
                throw CompositionBuilderError.invalidKeptRange(start: range.lowerBound, end: range.upperBound)
            }
            let start = CMTimeMaximum(CMTime(seconds: range.lowerBound, preferredTimescale: timescale), firstFrame)
            let end = CMTimeMinimum(CMTime(seconds: range.upperBound, preferredTimescale: timescale), mediaEnd)
            guard end > start else { continue }
            let sourceRange = CMTimeRange(start: start, end: end)
            try await composition.insertTimeRange(sourceRange, of: asset, at: offset)
            segments.append((offset, start, sourceRange.duration))
            offset = offset + sourceRange.duration
        }
        guard !segments.isEmpty else { throw CompositionBuilderError.nothingKept }
        // The screen's own tracks come first, so the first video track is
        // the screen's whether or not a camera follows.
        guard let screenCompositionTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw CompositionBuilderError.noScreenTrack(package.screenMovieURL)
        }
        let screenTrackID = screenCompositionTrack.trackID
        let camera = try await insertCamera(into: composition, package: package, manifest: manifest, segments: segments)
        let duration = try await composition.load(.duration)
        let capturePointSize = PointSize(
            width: manifest.content.captureRectPoints.width, height: manifest.content.captureRectPoints.height)
        var instructions: [RenderInstruction] = []
        for (index, segment) in segments.enumerated() {
            // The last instruction must reach the composition's end, which
            // an audio track may put a little past the last video segment.
            let end =
                index == segments.count - 1
                ? CMTimeMaximum(segment.offset + segment.duration, duration) : segment.offset + segment.duration
            instructions.append(
                RenderInstruction(
                    timeRange: CMTimeRange(start: segment.offset, end: end), sourceStart: segment.sourceStart,
                    screenTrackID: screenTrackID, plan: plan, style: style, cursorAtlas: cursor,
                    sourceWidth: manifest.screen.width, sourceHeight: manifest.screen.height,
                    capturePointSize: capturePointSize, cameraTrackID: camera.trackID, cameraIsBuiltIn: camera.isBuiltIn
                ))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MetalCompositor.self
        videoComposition.renderSize = canvas.renderSize
        videoComposition.renderScale = 1
        videoComposition.frameDuration = canvas.frameDuration
        // Constant output rate from the variable-rate intermediate: the
        // engine asks for a frame every `frameDuration` whatever the source did.
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        let color = colorTriple(of: formatDescriptions.first)
        videoComposition.colorPrimaries = color.primaries
        videoComposition.colorTransferFunction = color.transferFunction
        videoComposition.colorYCbCrMatrix = color.matrix
        videoComposition.instructions = instructions

        let audioMix = try await audioMix(for: composition, manifest: manifest, settings: settings)
        return BuiltComposition(
            composition: composition, videoComposition: videoComposition, audioMix: audioMix,
            screenTrackID: screenTrackID, cameraTrackID: camera.trackID, instructions: instructions,
            duration: duration, canvas: canvas)
    }

    /// Puts the camera movie's video track on a composition track of its own,
    /// one insert per kept segment at the segment's offset, each clipped to
    /// the camera's media (a camera that started late or stopped early
    /// leaves the bubble on its last frame rather than cutting the take).
    /// A manifest that names a camera whose movie is not there (a take
    /// killed before `camera.mov` was finalized) builds without one, so the
    /// screen still exports. The camera's audio, if a movie ever carries
    /// any, stays out: the microphone lives in the screen movie.
    private static func insertCamera(
        into composition: AVMutableComposition, package: RecordingPackage, manifest: RecordingManifest,
        segments: [(offset: CMTime, sourceStart: CMTime, duration: CMTime)]
    ) async throws -> (trackID: CMPersistentTrackID, isBuiltIn: Bool) {
        let none = (kCMPersistentTrackID_Invalid, false)
        guard let info = manifest.camera, FileManager.default.fileExists(atPath: package.cameraMovieURL.path) else {
            return none
        }
        let asset = AVURLAsset(url: package.cameraMovieURL)
        guard let cameraTrack = try await asset.loadTracks(withMediaType: .video).first,
            let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return none }
        let media = try await cameraTrack.load(.timeRange)
        for segment in segments {
            let start = CMTimeMaximum(segment.sourceStart, media.start)
            let end = CMTimeMinimum(segment.sourceStart + segment.duration, media.end)
            guard end > start else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: start, end: end), of: cameraTrack, at: segment.offset + (start - segment.sourceStart)
            )
        }
        return (track.trackID, info.isBuiltIn)
    }

    /// The video composition's colour triple, copied from the screen track
    /// so the engine tags the output as the recording is tagged and converts
    /// nothing; BT.709 for an untagged track, which is what the recorder writes.
    private static func colorTriple(of formatDescription: CMFormatDescription?) -> (
        primaries: String, transferFunction: String, matrix: String
    ) {
        func tag(_ key: CFString, fallback: String) -> String {
            guard let formatDescription,
                let value = CMFormatDescriptionGetExtension(formatDescription, extensionKey: key) as? String
            else { return fallback }
            return value
        }
        return (
            tag(kCMFormatDescriptionExtension_ColorPrimaries, fallback: AVVideoColorPrimaries_ITU_R_709_2),
            tag(kCMFormatDescriptionExtension_TransferFunction, fallback: AVVideoTransferFunction_ITU_R_709_2),
            tag(kCMFormatDescriptionExtension_YCbCrMatrix, fallback: AVVideoYCbCrMatrix_ITU_R_709_2)
        )
    }

    /// One level per audio track, matched to the manifest's track list by
    /// file order; unity for every track when the two disagree.
    private static func audioMix(
        for composition: AVMutableComposition, manifest: RecordingManifest, settings: CompositionSettings
    ) async throws -> AVMutableAudioMix? {
        let tracks = try await composition.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard !tracks.isEmpty else { return nil }
        let sources = manifest.screen.audioTracks
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            var gain: Float = 1
            if sources.count == tracks.count {
                switch sources[index].source {
                case .system: gain = settings.systemAudioGain
                case .microphone: gain = settings.microphoneGain
                }
            }
            parameters.setVolume(gain, at: .zero)
            return parameters
        }
        return mix
    }
}
