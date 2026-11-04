import AVFoundation
import CoreMedia
import CoreVideo
import CutsceneCapture
import CutsceneCore
import Foundation
import Synchronization

/// Camera capture proof (PLAN M2-05; ARCHITECTURE §2 "Camera"):
/// `CameraRecorder` on a shared `RecordingClock`, checking that `camera.mp4`
/// runs at the selection's 30 fps, that its first sample lies at most one
/// frame after the origin, and that media time 0 is the origin (the first
/// packet's time is the first frame's recording time).
///
/// `camera [seconds] [--device <uniqueID>] [--out <dir>]` runs the recorder
/// alone: the session is started, the clock's origin is taken a warm-up
/// later, `seconds` are recorded, the clock stops, the movie is finished
/// and probed with ffprobe. `--session` records the main display with the
/// camera through `CaptureSession` instead, so `camera.mp4` lands in a
/// `.cutscene` package beside `screen.mp4` with `CameraTrackInfo` in the
/// manifest; that path needs Screen Recording too. `--list` prints the
/// cameras and exits. `--self-test` checks the format rule and the
/// request's JSON round trip offline, with no grant and no device.
///
/// Every live mode preflights the camera (and Screen Recording for
/// `--session`) and exits 3 when the grant is missing, before any
/// AVFoundation call that could prompt (PLAN "Permission rule for spikes").
/// The spike binary has no Info.plist, so Continuity Cameras are not
/// listed here; the bundled app carries `NSCameraUseContinuityCameraDeviceType`.
enum CameraSpike {
    static let defaultSeconds = 5.0
    /// Under this the probe's rate and keyframe checks have nothing to work on.
    static let minimumSeconds = 2.0
    /// How long the camera runs before the origin is taken: cameras ramp
    /// their exposure and frame rate over the first frames, and the check
    /// is on a camera already running, as in the app.
    static let warmupSeconds = 1.0
    /// Slack on "the first sample is at most one frame after the origin":
    /// the delivery queue's wake-up and the clock's own lock.
    static let firstFrameSlack = 0.005
    /// How far the first packet's time may sit from the first frame's
    /// recording time once both are in the file's timescale.
    static let originTolerance = 0.002
    /// Frames the count may differ from the writer's and from the recorded
    /// seconds times the rate: the frame straddling each end.
    static let frameCountTolerance = 2
    /// The measured rate must land within this of the selection's.
    static let frameRateTolerance = 1.0
    /// Slack on the keyframe distance beyond the encoder's duration cap plus
    /// one frame interval (the cap can only act on the next frame).
    static let keyframeSlack = 0.05
    /// Progress lines per take.
    static let progressLines = 5

    // MARK: - Arguments

    private enum Mode {
        case live
        case session
        case list
        case selfTest
    }

    private struct Options {
        var mode = Mode.live
        var seconds = defaultSeconds
        var deviceID: String?
        var outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutscene-spike", isDirectory: true)
            .appendingPathComponent("camera", isDirectory: true)
    }

    private static let usage =
        "usage: camera [seconds] [--device <uniqueID>] [--out <dir>] [--session | --list | --self-test]"

    private static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 0
        func value(after flag: String) -> String? {
            guard index + 1 < arguments.count else {
                print("\(flag) needs a value")
                return nil
            }
            index += 2
            return arguments[index - 1]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--session":
                options.mode = .session
                index += 1
            case "--list":
                options.mode = .list
                index += 1
            case "--self-test":
                options.mode = .selfTest
                index += 1
            case "--device":
                guard let id = value(after: argument) else { return nil }
                options.deviceID = id
            case "--out":
                guard let path = value(after: argument) else { return nil }
                options.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            default:
                guard let seconds = Double(argument), seconds >= minimumSeconds else {
                    print("camera expects a duration in seconds of at least \(Int(minimumSeconds)), not \(argument)")
                    print(usage)
                    return nil
                }
                options.seconds = seconds
                index += 1
            }
        }
        return options
    }

    // MARK: - Entry

    static func run(arguments: [String]) async -> Bool {
        guard let options = parse(arguments) else { return false }
        do {
            switch options.mode {
            case .selfTest:
                return report(selfTest())
            case .list, .live, .session:
                return try await liveModes(options: options)
            }
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    private static func liveModes(options: Options) async throws -> Bool {
        // The relaunch baseline, as the app takes it at launch.
        let permissions = Permissions()
        let camera = permissions.preflight(.camera)
        guard camera == .granted else {
            print(
                "skipped: Camera not granted to this terminal (\(camera.rawValue)). Grant it to the terminal "
                    + "application under System Settings > Privacy & Security > Camera "
                    + "(\(Capability.camera.settingsURL)) and run again; the spike never prompts.")
            exit(3)
        }
        if case .session = options.mode {
            let screen = permissions.preflight(.screenRecording)
            guard screen == .granted else {
                print(
                    "skipped: Screen Recording not granted to this terminal (\(screen.rawValue)); --session records "
                        + "the display beside the camera. Grant it under System Settings > Privacy & Security > "
                        + "Screen & System Audio Recording (\(Capability.screenRecording.settingsURL)), relaunch "
                        + "the terminal and run again.")
                exit(3)
            }
        }
        let cameras = CameraRecorder.availableCameras()
        print("camera spike: Camera granted; \(cameras.count) camera(s)")
        for summary in cameras {
            print(
                "  camera: \"\(summary.name)\" id \(summary.id), \(summary.deviceType)"
                    + (summary.isBuiltIn ? ", built-in" : "") + (summary.isContinuityCamera ? ", Continuity" : ""))
        }
        if case .list = options.mode { return true }
        guard let chosen = choose(from: cameras, id: options.deviceID) else { return false }
        print("recording \"\(chosen.name)\" for \(format(options.seconds)) s")
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let selection = CaptureRequest.CameraSelection(deviceID: chosen.id)
        switch options.mode {
        case .session:
            return report(try await sessionRun(selection: selection, options: options, permissions: permissions))
        case .live:
            return report(try await recorderRun(selection: selection, options: options, permissions: permissions))
        case .list, .selfTest:
            return false
        }
    }

    /// The camera `id` names, else the built-in one, else the first.
    private static func choose(from cameras: [CameraSummary], id: String?) -> CameraSummary? {
        if let id {
            guard let camera = cameras.first(where: { $0.id == id }) ?? CameraRecorder.camera(id: id) else {
                print("no camera has the identifier \(id); the ids are listed above")
                return nil
            }
            return camera
        }
        guard let camera = cameras.first(where: \.isBuiltIn) ?? cameras.first else {
            print("no camera is connected")
            return nil
        }
        return camera
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    // MARK: - The recorder alone

    /// The recorder on its own clock, as the session drives it: started,
    /// warmed up, the origin taken, `seconds` recorded, the clock stopped,
    /// the movie finished.
    private static func recorderRun(
        selection: CaptureRequest.CameraSelection, options: Options, permissions: Permissions
    ) async throws -> [String] {
        let movieURL = options.outputDirectory.appendingPathComponent("camera-\(Int(Date().timeIntervalSince1970)).mov")
        let clock = RecordingClock.unstarted()
        let recorder = CameraRecorder(permissions: permissions)
        var started = ContinuousClock.now
        let track = try await recorder.start(selection: selection, movieURL: movieURL, clock: clock)
        print(
            "started in \(milliseconds(elapsed(since: started))): \(track.width)×\(track.height) \(track.codec) @ "
                + "\(track.frameRate) fps, \(track.isBuiltIn ? "built-in" : "external"); warming up "
                + "\(format(warmupSeconds)) s")
        try await Task.sleep(for: .seconds(warmupSeconds))
        let warm = recorder.statistics
        print("  before the origin: \(warm.framesBeforeOrigin) frames dropped, \(warm.framesEncoded) encoded")
        clock.start()
        started = ContinuousClock.now
        let interval = max(1, (options.seconds / Double(progressLines)).rounded())
        var nextLine = interval
        while elapsed(since: started) < options.seconds {
            try await Task.sleep(for: .seconds(min(interval, options.seconds - elapsed(since: started))))
            guard elapsed(since: started) >= nextLine else { continue }
            nextLine += interval
            print("  " + progressLine(recorder.statistics, elapsed: clock.elapsed.seconds))
        }
        clock.stop()
        let recordedSeconds = clock.elapsed.seconds
        started = ContinuousClock.now
        let finalized = try await recorder.stop()
        let statistics = recorder.statistics
        print(
            "stopped: \(format(recordedSeconds)) s recorded; stop took \(milliseconds(elapsed(since: started))); "
                + finalized.path)
        printCounters(statistics)
        var failures = checkTake(statistics, selection: selection, movieURL: movieURL)
        failures += try probeMovie(
            finalized, track: track, statistics: statistics, recordedSeconds: recordedSeconds, selection: selection)
        return failures
    }

    // MARK: - Through the session

    /// The main display with the camera and no audio through `CaptureSession`,
    /// so the package path (manifest, `camera.mp4` beside `screen.mp4`, no
    /// leftovers) is on the test.
    private static func sessionRun(
        selection: CaptureRequest.CameraSelection, options: Options, permissions: Permissions
    ) async throws -> [String] {
        let content = try await ShareableContent.current(permissions: permissions)
        guard let display = content.mainDisplay else { throw SpikeError.noDisplay }
        let request = CaptureRequest(source: .display(display.displayID), camera: selection)
        let package = RecordingPackage(
            url: RecordingPackage.availableURL(
                for: RecordingPackage.url(createdAt: Date(), source: .display, in: options.outputDirectory)))
        let session = CaptureSession(permissions: permissions)
        let statuses = try await session.start(request: request, package: package)
        print("recording: \(package.url.path)")
        let last = Mutex<CaptureStatus?>(nil)
        let printer = Task {
            var nextLine = max(1, (options.seconds / Double(progressLines)).rounded())
            for await status in statuses {
                last.withLock { $0 = status }
                switch status.phase {
                case .recording:
                    guard status.elapsedSeconds >= nextLine, let camera = status.statistics.camera else { continue }
                    nextLine += nextLine
                    print("  " + progressLine(camera, elapsed: status.elapsedSeconds))
                case .finishing:
                    print("  finishing at \(format(status.elapsedSeconds)) s")
                case .finished(let reason):
                    print("  finished: \(reason.rawValue)")
                case .failed(let reason, let message):
                    print("  failed: \(reason.rawValue), \(message)")
                }
            }
        }
        try await Task.sleep(for: .seconds(options.seconds))
        let started = ContinuousClock.now
        let manifest = try await session.stop()
        await printer.value
        let statistics = await session.statistics
        print(
            "stopped: \(format(manifest.duration ?? 0)) s recorded, \(manifest.state.rawValue) "
                + "(\(manifest.stopReason?.rawValue ?? "no reason")); stop took \(milliseconds(elapsed(since: started)))"
        )
        for warning in statistics.warnings { print("  warning: \(warning)") }
        var failures: [String] = []
        if manifest.state != .complete { failures.append("manifest state \(manifest.state.rawValue)") }
        guard let track = manifest.camera else {
            failures.append("the manifest carries no camera track")
            return failures
        }
        print(
            "manifest camera: \(track.width)×\(track.height) \(track.codec) @ \(track.frameRate) fps, "
                + "\"\(track.deviceName)\" (\(track.deviceID)), built-in \(track.isBuiltIn)")
        if track.deviceID != selection.deviceID { failures.append("the manifest names another camera") }
        guard let camera = statistics.camera else {
            failures.append("the session reports no camera statistics")
            return failures
        }
        printCounters(camera)
        failures += checkTake(camera, selection: selection, movieURL: package.cameraFragmentedMovieURL)
        failures += try probeMovie(
            package.cameraMovieURL, track: track, statistics: camera, recordedSeconds: manifest.duration,
            selection: selection)
        if let screen = try? await RecoveryScanner.playableSeconds(of: package.screenMovieURL),
            let cameraEnd = try? await RecoveryScanner.playableSeconds(of: package.cameraMovieURL)
        {
            let frame = 1 / Double(selection.frameRate)
            print("screen.mp4 plays \(format(screen)) s, camera.mp4 \(format(cameraEnd)) s")
            if abs(screen - cameraEnd) > frame {
                failures.append("camera.mp4 ends \(milliseconds(cameraEnd - screen)) from screen.mp4")
            }
        }
        return failures
    }

    // MARK: - Checks

    private static func progressLine(_ s: CameraRecorderStatistics, elapsed: Double) -> String {
        "t=\(format(elapsed)) s  camera \(s.framesEncoded) encoded, \(s.framesBeforeOrigin) before origin, "
            + "\(s.framesOutsideRecording) outside, \(s.framesDroppedByOutput) dropped by the output; encoder "
            + "\(s.encoder.encodedFrames) out, \(s.encoder.droppedFrames) dropped; writer \(s.writer.videoFrames) frames"
    }

    private static func printCounters(_ s: CameraRecorderStatistics) {
        print(
            "camera frames: \(s.framesEncoded) encoded, \(s.framesBeforeOrigin) before the origin, "
                + "\(s.framesOutsideRecording) outside the recording, \(s.framesDroppedByOutput) dropped by the output, "
                + "\(s.framesWithoutPixels) without pixels, \(s.encodeFailures) encode failures; first frame at "
                + "\(s.firstFrameRecordingSeconds.map(format) ?? "never") s, last at "
                + "\(s.lastFrameRecordingSeconds.map(format) ?? "never") s")
        print(
            "camera encoder: \(s.encoder.submittedFrames) submitted, \(s.encoder.encodedFrames) encoded, "
                + "\(s.encoder.droppedFrames) dropped, \(s.encoder.skippedOutsideRecording) outside, "
                + "\(s.encoder.droppedNonIncreasing) non-increasing, last error \(s.encoder.lastErrorStatus ?? 0)")
        print(
            "camera writer: \(s.writer.videoFrames) video frames (\(s.writer.videoDroppedNotReady) not ready, "
                + "\(s.writer.videoDroppedBeforeKeyframe) before keyframe, \(s.writer.videoDroppedNonIncreasing) "
                + "non-increasing)" + (s.writer.failureDescription.map { "; FAILED: \($0)" } ?? ""))
        print(
            "camera clock: synchronizationClock is host clock "
                + (s.synchronizationClockIsHostClock.map { $0 ? "yes" : "NO" } ?? "unknown (none reported)")
                + ", \(s.sampleTimesConverted) sample times converted"
                + (s.sessionFailure.map { "; session failure: \($0)" } ?? ""))
        for warning in s.warnings { print("  warning: \(warning)") }
    }

    /// What the take itself must satisfy, beyond the file.
    private static func checkTake(
        _ s: CameraRecorderStatistics, selection: CaptureRequest.CameraSelection, movieURL: URL
    ) -> [String] {
        var failures: [String] = []
        let frame = 1 / Double(selection.frameRate)
        if s.framesEncoded == 0 { failures.append("no camera frame was encoded") }
        if s.encodeFailures > 0 { failures.append("\(s.encodeFailures) encode failures") }
        if let failure = s.writer.failureDescription { failures.append("camera writer failed: \(failure)") }
        if let failure = s.sessionFailure { failures.append(failure) }
        if let status = s.encoder.lastErrorStatus, status != noErr { failures.append("camera encoder error \(status)") }
        if s.writer.videoDroppedBeforeKeyframe + s.writer.videoDroppedNonIncreasing > 0 {
            failures.append("the camera writer refused video (before keyframe / non-increasing)")
        }
        if let first = s.firstFrameRecordingSeconds {
            let limit = frame + firstFrameSlack
            print(
                "first camera sample at \(milliseconds(first)) after the origin (limit one frame, "
                    + "\(milliseconds(limit)))")
            if first > limit { failures.append("the first camera sample is \(milliseconds(first)) after the origin") }
        }
        let leftovers = [movieURL, RecordingWriter.markerURL(for: movieURL)].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if !leftovers.isEmpty { failures.append("leftovers \(leftovers.map(\.lastPathComponent))") }
        return failures
    }

    // MARK: - ffprobe

    /// Probes the finalized movie: codec and tag, no B-frames, the track's
    /// size, the frame count against the writer and the recorded seconds,
    /// the measured rate, the first packet at the first frame's recording
    /// time (media time 0 is the origin), keyframes within the cap, the
    /// end marker, and `moov` before `mdat`.
    private static func probeMovie(
        _ movieURL: URL, track: CameraTrackInfo, statistics: CameraRecorderStatistics, recordedSeconds: Double?,
        selection: CaptureRequest.CameraSelection
    ) throws -> [String] {
        var failures: [String] = []
        let size = (try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? Int64) ?? 0
        let boxes = try topLevelBoxes(of: movieURL)
        print("\(movieURL.lastPathComponent): \(size / 1024) KiB, boxes \(boxes.joined(separator: " → "))")
        if let moov = boxes.firstIndex(of: "moov"), let mdat = boxes.firstIndex(of: "mdat") {
            if moov > mdat { failures.append("mdat precedes moov (not faststart)") }
        } else {
            failures.append("moov or mdat missing from the top-level boxes")
        }
        guard let ffprobe = findFFprobe() else {
            print("note: ffprobe not found at /opt/homebrew/bin or on PATH; skipping the probe")
            return failures
        }
        let probe = try Probe.run(ffprobe, on: movieURL)
        let frame = 1 / Double(selection.frameRate)
        let codec = VideoEncoderConfiguration(width: track.width, height: track.height, frameRate: track.frameRate)
        let maximumGap = codec.maxKeyFrameIntervalDuration + frame + keyframeSlack
        let span = probe.videoEnd - probe.videoStartTime
        let measuredRate = span > 0 ? Double(max(probe.frameCount - 1, 0)) / span : 0
        print(
            "ffprobe: codec=\(probe.codec) tag=\(probe.codecTag) \(probe.width)×\(probe.height) nb_frames=\(probe.frameCount) "
                + "has_b_frames=\(probe.bFrames) bit_rate=\(probe.bitRate.map { "\($0 / 1000) kb/s" } ?? "n/a") "
                + "r_frame_rate=\(probe.reportedFrameRate) start=\(format(probe.videoStartTime)) s "
                + "duration=\(format(probe.videoDuration)) s end=\(format(probe.videoEnd)) s; measured "
                + "\(String(format: "%.2f", measuredRate)) fps over \(probe.frameCount) frames")
        print(
            "keyframes: \(probe.keyframeTimes.count), max gap \(format(probe.maximumKeyframeGap)) s (limit "
                + "\(format(maximumGap)) s), longest GOP \(probe.framesPerGOP.max() ?? 0) frames (limit "
                + "\(codec.maxKeyFrameInterval)); first packet at \(probe.firstPacketTime.map(format) ?? "n/a") s")

        let expectedTag = track.codec == VideoCodec.hevc.rawValue ? "hvc1" : "avc1"
        if probe.codecTag != expectedTag { failures.append("codec tag \(probe.codecTag) is not \(expectedTag)") }
        if probe.bFrames != 0 { failures.append("has_b_frames=\(probe.bFrames)") }
        if probe.width != track.width || probe.height != track.height {
            failures.append(
                "frame size \(probe.width)×\(probe.height) is not the track's \(track.width)×\(track.height)")
        }
        if probe.keyframeTimes.isEmpty { failures.append("no keyframes") }
        if probe.maximumKeyframeGap > maximumGap {
            failures.append("keyframe gap \(format(probe.maximumKeyframeGap)) s > \(format(maximumGap)) s")
        }
        if let longest = probe.framesPerGOP.max(), longest > codec.maxKeyFrameInterval + frameCountTolerance {
            failures.append("a GOP of \(longest) frames exceeds \(codec.maxKeyFrameInterval)")
        }
        if probe.frameCount != statistics.writer.videoFrames {
            failures.append("nb_frames=\(probe.frameCount), the writer wrote \(statistics.writer.videoFrames)")
        }
        if let recordedSeconds {
            // Frames the output or the encoder dropped are not in the file
            // and are reported, not counted against the cadence.
            let dropped = statistics.framesDroppedByOutput + statistics.encoder.droppedFrames
            let expected = Int((recordedSeconds * Double(selection.frameRate)).rounded()) - dropped
            if abs(probe.frameCount - expected) > frameCountTolerance {
                failures.append(
                    "nb_frames=\(probe.frameCount), \(format(recordedSeconds)) s at \(selection.frameRate) fps less "
                        + "\(dropped) dropped implies \(expected)")
            }
            if abs(probe.videoEnd - recordedSeconds) > frame {
                failures.append("video ends at \(format(probe.videoEnd)) s, recorded \(format(recordedSeconds)) s")
            }
        }
        if abs(measuredRate - Double(selection.frameRate)) > frameRateTolerance {
            failures.append(
                "measured \(String(format: "%.2f", measuredRate)) fps, not \(selection.frameRate) ± "
                    + "\(format(frameRateTolerance))")
        }
        if probe.videoStartTime > frame + firstFrameSlack {
            failures.append("the track starts at \(milliseconds(probe.videoStartTime)), past one frame")
        }
        if let first = statistics.firstFrameRecordingSeconds, let packet = probe.firstPacketTime {
            if abs(packet - first) > originTolerance {
                failures.append(
                    "the first packet is at \(format(packet)) s but the first frame was recorded at \(format(first)) s"
                        + " after the origin (media time 0 is not the origin)")
            }
        } else {
            failures.append("no first packet time to compare with the origin")
        }
        return failures
    }

    /// The four-character types of the file's top-level boxes, in order.
    private static func topLevelBoxes(of url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        var boxes: [String] = []
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(
                header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian })
            boxes.append(String(decoding: header[header.startIndex + 4..<header.startIndex + 8], as: UTF8.self))
            var headerLength: UInt64 = 8
            if boxSize == 1 {
                guard header.count >= 16 else { break }
                boxSize = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian }
                headerLength = 16
            } else if boxSize == 0 {
                boxSize = fileSize - offset
            }
            guard boxSize >= headerLength else { break }
            offset += boxSize
        }
        return boxes
    }

    private static func findFFprobe() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffprobe" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// What ffprobe reports about the video stream.
    private struct Probe {
        var codec: String
        var codecTag: String
        var width: Int
        var height: Int
        var frameCount: Int
        var bFrames: Int
        var bitRate: Int?
        var reportedFrameRate: String
        var videoStartTime: Double
        var videoDuration: Double
        var firstPacketTime: Double?
        var keyframeTimes: [Double]
        var framesPerGOP: [Int]

        /// The track starts at its first frame (an empty edit covers the gap
        /// from zero) and ffprobe's duration excludes that edit.
        var videoEnd: Double { videoStartTime + videoDuration }
        var maximumKeyframeGap: Double { zip(keyframeTimes.dropFirst(), keyframeTimes).map(-).max() ?? 0 }

        /// ffprobe's JSON; counts and rates it derives arrive as strings.
        private struct StreamReport: Decodable {
            struct Stream: Decodable {
                var codecName: String
                var codecTag: String?
                var width: Int?
                var height: Int?
                var frameCount: String?
                var bFrames: Int?
                var bitRate: String?
                var frameRate: String?
                var startTime: String?
                var duration: String?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case codecTag = "codec_tag_string"
                    case width
                    case height
                    case frameCount = "nb_frames"
                    case bFrames = "has_b_frames"
                    case bitRate = "bit_rate"
                    case frameRate = "r_frame_rate"
                    case startTime = "start_time"
                    case duration
                }
            }

            var streams: [Stream]
        }

        static func run(_ ffprobe: URL, on file: URL) throws -> Probe {
            let entries =
                "stream=codec_name,codec_tag_string,width,height,nb_frames,has_b_frames,bit_rate,r_frame_rate,"
                + "start_time,duration"
            let json = try output(
                of: ffprobe,
                ["-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "json", file.path])
            guard let stream = try JSONDecoder().decode(StreamReport.self, from: Data(json.utf8)).streams.first
            else { throw SpikeError.probeOutput("no video stream") }
            // Packet flags need no decoding; "K" marks a keyframe.
            let packets = try output(
                of: ffprobe,
                [
                    "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of",
                    "csv=p=0", file.path,
                ])
            var keyframeTimes: [Double] = []
            var framesPerGOP: [Int] = []
            var firstPacketTime: Double?
            for line in packets.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 2, let time = Double(fields[0]) else { continue }
                if firstPacketTime == nil { firstPacketTime = time }
                if fields[1].contains("K") {
                    keyframeTimes.append(time)
                    framesPerGOP.append(0)
                }
                if !framesPerGOP.isEmpty { framesPerGOP[framesPerGOP.count - 1] += 1 }
            }
            return Probe(
                codec: stream.codecName, codecTag: stream.codecTag ?? "", width: stream.width ?? 0,
                height: stream.height ?? 0, frameCount: stream.frameCount.flatMap(Int.init) ?? 0,
                bFrames: stream.bFrames ?? 0, bitRate: stream.bitRate.flatMap(Int.init),
                reportedFrameRate: stream.frameRate ?? "n/a",
                videoStartTime: stream.startTime.flatMap(Double.init) ?? 0,
                videoDuration: stream.duration.flatMap(Double.init) ?? 0, firstPacketTime: firstPacketTime,
                keyframeTimes: keyframeTimes.sorted(), framesPerGOP: framesPerGOP)
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

    // MARK: - Self-test

    /// The format rule and the selection's JSON, checked without a device.
    private static func selfTest() -> [String] {
        var failures: [String] = []
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let f420 = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let selection = CaptureRequest.CameraSelection(deviceID: "self-test")
        func check(_ name: String, _ candidates: [CameraFormatCandidate], expect: Int?, line: Int = #line) {
            let chosen = CameraRecorder.chooseFormat(from: candidates, selection: selection, preferredPixelFormat: v420)
            let verdict = chosen == expect ? "ok" : "FAIL"
            print(
                "  \(verdict): \(name) → \(chosen.map(String.init) ?? "nil") (expected \(expect.map(String.init) ?? "nil"))"
            )
            if chosen != expect { failures.append("\(name) chose \(chosen.map(String.init) ?? "nil") (line \(line))") }
        }
        // A FaceTime HD camera's list: the largest ≤ 1080p at 30 fps wins,
        // 420v before 420f at the same size, whatever the order.
        let faceTime = [
            CameraFormatCandidate(width: 640, height: 480, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1280, height: 720, pixelFormat: f420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1280, height: 720, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1920, height: 1080, pixelFormat: f420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1920, height: 1080, pixelFormat: v420, frameRateRanges: [1...30]),
        ]
        check("FaceTime HD list", faceTime, expect: 4)
        check("FaceTime HD list reversed", Array(faceTime.reversed()), expect: 0)
        // A 4K camera: 1080p at 30 beats 4K, and a 1080p format whose only
        // range is 60 fps cannot hold a constant 30 and is skipped.
        let fourK = [
            CameraFormatCandidate(width: 3840, height: 2160, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1920, height: 1080, pixelFormat: v420, frameRateRanges: [60...60]),
            CameraFormatCandidate(width: 1920, height: 1080, pixelFormat: f420, frameRateRanges: [15...30, 60...60]),
            CameraFormatCandidate(width: 1280, height: 720, pixelFormat: v420, frameRateRanges: [1...60]),
        ]
        check("4K camera list", fourK, expect: 2)
        // Only formats above the cap: the smallest usable one.
        let oversized = [
            CameraFormatCandidate(width: 3840, height: 2160, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 2560, height: 1440, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 2560, height: 1440, pixelFormat: f420, frameRateRanges: [1...30]),
        ]
        check("oversized list", oversized, expect: 1)
        // A 1080p format exactly at the cap fits; a width one over does not.
        let edge = [
            CameraFormatCandidate(width: 1921, height: 1080, pixelFormat: v420, frameRateRanges: [1...30]),
            CameraFormatCandidate(width: 1920, height: 1080, pixelFormat: f420, frameRateRanges: [1...30]),
        ]
        check("cap edge", edge, expect: 1)
        check(
            "no usable rate",
            [CameraFormatCandidate(width: 1280, height: 720, pixelFormat: v420, frameRateRanges: [60...60])],
            expect: nil)
        check("empty list", [], expect: nil)

        // The selection round-trips through JSON with its tier by name, and
        // a selection written before the tunables existed still decodes.
        do {
            let original = CaptureRequest.CameraSelection(
                deviceID: "cam-1", maximumWidth: 1280, maximumHeight: 720, frameRate: 24, tier: .high)
            let data = try PackageJSON.encode(original)
            let decoded = try PackageJSON.decode(CaptureRequest.CameraSelection.self, from: data)
            let json = String(decoding: data, as: UTF8.self)
            print("  \(decoded == original ? "ok" : "FAIL"): selection round trip \(json)")
            if decoded != original { failures.append("the selection did not round-trip") }
            let legacy = try PackageJSON.decode(
                CaptureRequest.CameraSelection.self, from: Data("{\"deviceID\":\"cam-2\"}".utf8))
            let expected = CaptureRequest.CameraSelection(deviceID: "cam-2")
            print("  \(legacy == expected ? "ok" : "FAIL"): a device-only selection decodes with the defaults")
            if legacy != expected { failures.append("a device-only selection did not take the defaults") }
            if (try? PackageJSON.decode(
                CaptureRequest.CameraSelection.self, from: Data("{\"deviceID\":\"cam-3\",\"tier\":\"ultra\"}".utf8)))
                != nil
            {
                failures.append("an unknown tier decoded")
            } else {
                print("  ok: an unknown tier is refused")
            }
        } catch {
            failures.append("selection JSON: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - Helpers

    enum SpikeError: LocalizedError {
        case noDisplay
        case probeExited(Int32)
        case probeOutput(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: "ScreenCaptureKit lists no display to record."
            case .probeExited(let status): "ffprobe exited with status \(status)."
            case .probeOutput(let detail): "Could not read ffprobe output: \(detail)."
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
