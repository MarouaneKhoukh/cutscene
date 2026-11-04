import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

/// What a test recording measured.
public struct RecordingSpikeReport: Sendable {
    public let fileURL: URL
    public let fileSizeBytes: Int64
    public let recordedDuration: TimeInterval
    public let completeFrames: Int
    public let measuredFPS: Double
    public let outputWidth: Int
    public let outputHeight: Int
    public let microphoneIncluded: Bool
}

public enum RecordingSpikeError: LocalizedError {
    case noDisplay
    case finishTimeout

    public var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to capture."
        case .finishTimeout: "The recording stopped but the file was not finalized in time."
        }
    }
}

/// Records the main display for a fixed duration with ScreenCaptureKit's
/// direct-to-file `SCRecordingOutput`, while counting the frames the stream
/// delivers so the result can be checked against the requested frame rate.
///
/// A spike, not product code: it proves the simplest capture path on this
/// machine (display + system audio + microphone in, hardware-encoded `.mov`
/// out) and bypasses the project model entirely. The real capture pipeline
/// replaces it.
public final class RecordingSpike: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate,
    @unchecked Sendable
{
    private struct State {
        var completeFrames = 0
        var firstPTS: CMTime?
        var lastPTS: CMTime?
        var finished: CheckedContinuation<Void, any Error>?
        var failure: (any Error)?
    }

    private let state = Mutex(State())
    private let sampleQueue = DispatchQueue(label: "app.cutscene.spike.samples")

    override public init() {
        super.init()
    }

    /// Records for `seconds` and returns what happened. Writes into
    /// `~/Movies/Cutscene` unless another directory is given.
    public func record(seconds: Double = 5, into directory: URL? = nil) async throws -> RecordingSpikeReport {
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecordingSpikeError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int((CGFloat(display.width) * scale).rounded())
        let height = Int((CGFloat(display.height) * scale).rounded())

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphoneGranted

        let outputDirectory =
            directory
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutscene", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileURL = outputDirectory.appendingPathComponent("Test \(stamp.string(from: Date())).mov")

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = fileURL
        recordingConfiguration.videoCodecType = .hevc
        recordingConfiguration.outputFileType = .mov
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addRecordingOutput(recording)

        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))

        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }

        // Stop, then wait for the recording output to finalize the file. A
        // watchdog guards against the finish callback never arriving.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.finished = continuation }
            stream.stopCapture { [weak self] error in
                if let error {
                    self?.resumeFinished(throwing: error)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    self?.resumeFinished(throwing: RecordingSpikeError.finishTimeout)
                }
            }
        }

        let snapshot = state.withLock { $0 }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        var fps = 0.0
        if let first = snapshot.firstPTS, let last = snapshot.lastPTS, snapshot.completeFrames > 1 {
            let span = CMTimeSubtract(last, first).seconds
            if span > 0 { fps = Double(snapshot.completeFrames - 1) / span }
        }

        return RecordingSpikeReport(
            fileURL: fileURL,
            fileSizeBytes: size,
            recordedDuration: recording.recordedDuration.seconds,
            completeFrames: snapshot.completeFrames,
            measuredFPS: fps,
            outputWidth: width,
            outputHeight: height,
            microphoneIncluded: microphoneGranted
        )
    }

    /// Resumes the waiting `record` call exactly once; later calls are no-ops.
    private func resumeFinished(throwing error: (any Error)?) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            let waiting = state.finished
            state.finished = nil
            if let error, waiting != nil, state.failure == nil { state.failure = error }
            return waiting
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rawStatus = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status == .complete || status == .started
        else { return }

        let pts = sampleBuffer.presentationTimeStamp
        state.withLock { state in
            state.completeFrames += 1
            if state.firstPTS == nil { state.firstPTS = pts }
            state.lastPTS = pts
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        resumeFinished(throwing: error)
    }

    // MARK: SCRecordingOutputDelegate

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        resumeFinished(throwing: error)
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resumeFinished(throwing: nil)
    }
}
