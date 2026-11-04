import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCapture
import CutsceneCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fabricates a complete `.cutscene` package without any permission, so the
/// reader, export and recovery work has a fixture before the live session
/// exists (lead amendment to PLAN M1-01).
///
/// `package [outputDir] [seconds]` writes `<outputDir>/<yyyy-MM-dd HH.mm.ss>
/// Display.cutscene` (default `.build/package-spike`, 10 s): a synthetic
/// desktop (wallpaper, menu bar, windows with text-like stripes, a dock) with
/// an orange block that wanders the screen, encoded at 1920×1080 60 fps
/// through `VideoEncoder` and `RecordingWriter` exactly as a take is, paced
/// in real time so the encoder's real-time mode sees a capture cadence; the
/// pointer follows the block and clicks on it every few seconds; the screen
/// goes still for a stretch (no frames, idle samples, heartbeat holds) and a
/// typing burst follows; the system track is a steady tone and the
/// microphone track beeps at every click, so sync can be checked by ear or
/// by waveform. Then `manifest.json` (`.complete`), `events.json`,
/// `frames.jsonl` consistent with the frames written, cursor sprites and a
/// `project.json` with the default kit, and ffprobe confirms the movie.
enum PackageSpike {
    static let width = 1920
    static let height = 1080
    static let frameRate = 60
    static let defaultSeconds = 10.0
    static let defaultOutputDirectory = ".build/package-spike"
    /// A Retina display, so the capture rect is in points at 2×.
    static let pointPixelScale = 2.0
    static let displayID: UInt32 = 1
    /// ScreenCaptureKit delivers its first frame some time after Record; the
    /// track opens with an empty edit of this length, as a real take's does.
    static let firstFrameDelay = 0.1
    /// Nothing changes on screen between these fractions of the duration:
    /// no frames are encoded, samples are idle, and the heartbeat holds.
    static let staticStart = 0.55
    static let staticEnd = 0.75
    static let heartbeat = 1.0
    /// Clicks land on the block at `firstClickAt + k × clickInterval`,
    /// except inside the static stretch, where nothing may change.
    static let firstClickAt = 1.5
    static let clickInterval = 3.0
    static let clickHold = 0.08
    /// The typing burst starts this long after the static stretch ends.
    static let typingDelay = 0.4
    static let typingKeys = 8
    static let keyInterval = 0.09
    static let keyHold = 0.05
    /// The cursor becomes an I-beam this long before typing and an arrow
    /// again this long after it.
    static let cursorShapeLead = 0.3
    /// The pointer poll and its movement threshold, as the recorder's.
    static let samplingRateHz = 125.0
    static let movementThreshold = 1.0 / 4096
    static let systemToneHz = 220.0
    static let systemToneAmplitude: Float = 0.1
    static let microphoneBeepHz = 880.0
    static let microphoneBeepAmplitude: Float = 0.5
    static let microphoneBeepLength = 0.1
    static let durationTolerance = 0.1
    /// Nanoseconds, the host clock's own resolution, for the scheduled stamps.
    static let hostTimescale: CMTimeScale = 1_000_000_000

    static func run(arguments: [String]) async -> Bool {
        var outputDirectory = URL(fileURLWithPath: defaultOutputDirectory, isDirectory: true)
        var seconds = defaultSeconds
        if let first = arguments.first {
            outputDirectory = URL(fileURLWithPath: first, isDirectory: true)
        }
        if arguments.count > 1 {
            guard let value = Double(arguments[1]), value >= 2 else {
                print("unknown argument \(arguments[1]); expected a duration in seconds (at least 2)")
                return false
            }
            seconds = value
        }
        if arguments.count > 2 {
            print("too many arguments; expected [outputDir] [seconds]")
            return false
        }
        do {
            return try await fabricate(in: outputDirectory, seconds: seconds)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - The take

    private static func fabricate(in outputDirectory: URL, seconds: Double) async throws -> Bool {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let createdAt = Date()
        let packageURL = RecordingPackage.availableURL(
            for: RecordingPackage.url(createdAt: createdAt, source: .display, in: outputDirectory))
        let package = try RecordingPackage.create(at: packageURL)
        let recordingID = UUID()
        let captureRect = PointRect(
            x: 0, y: 0, width: Double(width) / pointPixelScale, height: Double(height) / pointPixelScale)
        let content = ContentGeometry(
            displayID: displayID, displayBoundsPoints: captureRect, captureRectPoints: captureRect,
            pointPixelScale: pointPixelScale)

        let staticRange = (seconds * staticStart)..<(seconds * staticEnd)
        let typingStart = staticRange.upperBound + typingDelay
        let typingEnd = typingStart + Double(typingKeys - 1) * keyInterval + keyHold
        let clickTimes = stride(from: firstClickAt, to: seconds - clickHold, by: clickInterval)
            .filter { !staticRange.contains($0) }
        // The painter draws its backdrop now, before the clock starts, so
        // the wall schedule below lines up with the recording timeline.
        let desktop = try DesktopPainter(width: width, height: height)
        let script = Script(
            seconds: seconds, staticRange: staticRange, clickTimes: clickTimes, typingStart: typingStart)
        let tones = [
            try ToneSource(source: .system, channels: 2, interleaved: true),
            try ToneSource(source: .microphone, channels: 1, interleaved: false),
        ]

        let tracks: [RecordingAudioSource: RecordingWriterConfiguration.AudioTrack] = [
            .system: RecordingWriterConfiguration.AudioTrack(channelCount: 2),
            .microphone: RecordingWriterConfiguration.AudioTrack(channelCount: 1),
        ]
        let clock = RecordingClock()
        let writer = try RecordingWriter(
            movieURL: package.screenFragmentedMovieURL, clock: clock,
            configuration: RecordingWriterConfiguration(audioTracks: tracks))
        let configuration = VideoEncoderConfiguration(width: width, height: height, frameRate: frameRate, codec: .hevc)
        let encoder = try VideoEncoder(configuration: configuration, clock: clock) { sample in
            writer.appendVideo(sample)
        }
        var manifest = RecordingManifest(
            recordingID: recordingID, createdAt: createdAt, source: .display, content: content,
            screen: ScreenTrackInfo(
                width: configuration.width, height: configuration.height, frameRate: frameRate,
                codec: encoder.codec.rawValue,
                audioTracks: [
                    AudioTrackInfo(source: .system, channelCount: 2),
                    AudioTrackInfo(
                        source: .microphone, channelCount: 1, deviceID: "synthetic-microphone",
                        deviceName: "Synthetic Microphone"),
                ]))
        // What a real take writes first: the in-progress manifest, so a
        // crash from here on is recoverable.
        try package.writeManifest(manifest)
        let index = try FrameIndexWriter(url: package.frameIndexURL, header: FrameIndexHeader(recordingID: recordingID))
        print(
            "package spike: \(width)×\(height) @ \(frameRate) fps for \(seconds) s, "
                + "encoder \(encoder.codec.rawValue) (\(encoder.isHardwareAccelerated ? "hardware" : "software")); "
                + "first frame at \(firstFrameDelay) s, static \(format(staticRange.lowerBound))–"
                + "\(format(staticRange.upperBound)) s with a \(heartbeat) s heartbeat, "
                + "clicks at \(clickTimes.map(format).joined(separator: ", ")) s, "
                + "typing \(format(typingStart))–\(format(typingEnd)) s")
        print("package: \(package.url.path)")

        let origin = clock.origin
        func hostTime(_ recordingSeconds: Double) -> CMTime {
            origin + CMTime(seconds: recordingSeconds, preferredTimescale: hostTimescale)
        }
        var nextAudioTime = [CMTime](repeating: origin, count: tones.count)
        func feedAudio(until recordingSeconds: Double) throws {
            let limit = hostTime(recordingSeconds)
            for (slot, tone) in tones.enumerated() {
                while nextAudioTime[slot] <= limit {
                    let time = nextAudioTime[slot]
                    nextAudioTime[slot] = time + ToneSource.bufferDuration
                    let offset = (time - origin).seconds
                    let samples =
                        tone.source == .system
                        ? tone.tone(at: offset, frequency: systemToneHz, amplitude: systemToneAmplitude)
                        : tone.beeps(
                            at: offset, times: clickTimes, length: microphoneBeepLength, frequency: microphoneBeepHz,
                            amplitude: microphoneBeepAmplitude)
                    writer.appendAudio(try tone.buffer(samples, at: time), from: tone.source)
                }
            }
        }

        // Frames at their scheduled times, stamped with the scheduled time:
        // the stamp is the capture instant, never the moment of the call.
        let start = ContinuousClock.now
        let slots = Int((seconds * Double(frameRate)).rounded(.down))
        var frameNumber = 0
        var encodedFrames = 0
        var idleSamples = 0
        var holds = 0
        var lastEncodedTime: Double?
        var lastFrame: CVPixelBuffer?
        for slot in 0..<slots {
            let time = Double(slot) / Double(frameRate)
            guard time >= firstFrameDelay else { continue }
            try await Task.sleep(until: start + .seconds(time), tolerance: .milliseconds(1), clock: .continuous)
            try feedAudio(until: time)
            if staticRange.contains(time) {
                // The screen is still: the sample is idle, and the heartbeat
                // re-encodes the last frame so the keyframe cap can fire.
                try index.append(FrameIndexEntry(number: frameNumber, time: time, displayTime: time, status: .idle))
                frameNumber += 1
                idleSamples += 1
                if let last = lastEncodedTime, let lastFrame, time - last >= heartbeat {
                    try encoder.encode(lastFrame, hostTime: hostTime(time))
                    try index.appendHold(at: time)
                    lastEncodedTime = time
                    holds += 1
                }
                continue
            }
            let frame = try desktop.paint(script.scene(at: time))
            try encoder.encode(frame, hostTime: hostTime(time))
            try index.append(
                FrameIndexEntry(
                    number: frameNumber, time: time, displayTime: time, status: .complete,
                    contentRect: captureRect, contentScale: 1, scaleFactor: pointPixelScale, screenRect: captureRect))
            frameNumber += 1
            encodedFrames += 1
            lastEncodedTime = time
            lastFrame = frame
        }
        try await Task.sleep(until: start + .seconds(seconds), tolerance: .milliseconds(1), clock: .continuous)
        clock.stop()
        let duration = clock.elapsed.seconds
        // Audio keeps arriving until the stream is told to stop; the buffer
        // that straddles the stop is written whole, as on a live take.
        try feedAudio(until: duration)
        try encoder.finish()
        try index.close()
        let movieURL = try await writer.finish()

        // Telemetry: the pointer rides the block at the poll rate, writing a
        // move only when it travelled at least the threshold, as the
        // recorder does; clicks, keys and shape changes at their times.
        var log = EventLog(
            recordingID: recordingID, startHostTimeSeconds: origin.seconds, captureRectPoints: captureRect,
            displayID: displayID, pointPixelScale: pointPixelScale, samplingRateHz: samplingRateHz)
        let arrow = CursorShape(
            id: "arrow", hotspot: NormalizedPoint(x: 0.06, y: 0.04), sizePoints: PointSize(width: 17, height: 23))
        let iBeam = CursorShape(
            id: "iBeam", hotspot: NormalizedPoint(x: 0.5, y: 0.5), sizePoints: PointSize(width: 9, height: 18))
        log.append(.cursorShapeChanged(time: 0, shape: arrow))
        var lastWritten: NormalizedPoint?
        var tick = 0
        while true {
            let time = Double(tick) / samplingRateHz
            guard time < duration else { break }
            tick += 1
            let position = script.pointer(at: time)
            if let lastWritten, hypot(position.x - lastWritten.x, position.y - lastWritten.y) < movementThreshold {
                continue
            }
            log.append(.pointerMoved(time: time, position: position))
            lastWritten = position
        }
        // Nothing after the stop: a short take cuts the typing burst off, as
        // Stop would.
        var timed: [InputEvent] = []
        for click in clickTimes {
            let position = script.pointer(at: click)
            timed.append(.buttonDown(time: click, position: position, button: .left))
            timed.append(.buttonUp(time: click + clickHold, position: position, button: .left))
        }
        timed.append(.cursorShapeChanged(time: typingStart - cursorShapeLead, shape: iBeam))
        for key in 0..<typingKeys {
            let time = typingStart + Double(key) * keyInterval
            let keyCode = UInt16(Script.keyCodes[key % Script.keyCodes.count])
            timed.append(.keyDown(time: time, keyCode: keyCode, modifiers: [], isRepeat: false))
            timed.append(.keyUp(time: time + keyHold, keyCode: keyCode, modifiers: []))
        }
        timed.append(.cursorShapeChanged(time: typingEnd + cursorShapeLead, shape: arrow))
        log.append(contentsOf: timed.filter { $0.time < duration })
        try log.write(to: package.eventsURL)
        try SpriteWriter.write(arrow, to: package.cursorSpriteURL(shapeID: arrow.id), scale: pointPixelScale)
        try SpriteWriter.write(iBeam, to: package.cursorSpriteURL(shapeID: iBeam.id), scale: pointPixelScale)

        manifest.state = .complete
        manifest.stopReason = .userStopped
        manifest.duration = duration
        try package.writeManifest(manifest)
        try package.writeJSON(try projectTree(manifest: manifest), to: package.projectURL)

        // Report and verify.
        let encoderStatistics = encoder.statistics
        let writerStatistics = writer.statistics
        print(
            "recorded \(format(duration)) s; \(encodedFrames) frames encoded, \(idleSamples) idle samples, "
                + "\(holds) holds; encoder \(encoderStatistics.encodedFrames) encoded, "
                + "\(encoderStatistics.droppedFrames) dropped; writer \(writerStatistics.videoFrames) frames, "
                + "\(writerStatistics.audioBuffers) audio buffers, \(writerStatistics.audioGapsFilled) gaps filled")
        print("events: \(log.events.count) (\(clickTimes.count) clicks, \(typingKeys) keys)")
        let size = (try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? Int64) ?? 0
        for url in [
            package.manifestURL, movieURL, package.eventsURL, package.frameIndexURL,
            package.cursorSpriteURL(shapeID: arrow.id), package.cursorSpriteURL(shapeID: iBeam.id), package.projectURL,
        ] {
            print("  \(url.path)")
        }
        print("screen movie: \(size / 1024) KiB")

        var failures: [String] = []
        if movieURL != package.screenMovieURL {
            failures.append("the writer finalized to \(movieURL.lastPathComponent), not screen.mp4")
        }
        for leftover in [package.screenFragmentedMovieURL, writer.markerURL]
        where FileManager.default.fileExists(atPath: leftover.path) {
            failures.append("leftover \(leftover.lastPathComponent) after finalize")
        }
        if encoderStatistics.droppedFrames > 0 { failures.append("encoder dropped \(encoderStatistics.droppedFrames)") }
        if writerStatistics.videoFrames != encodedFrames + holds {
            failures.append("writer wrote \(writerStatistics.videoFrames) frames, expected \(encodedFrames + holds)")
        }
        do {
            let read = try package.manifest()
            if read.state != .complete { failures.append("manifest reads back as \(read.state)") }
            if read != manifest { failures.append("the manifest did not round-trip") }
            let readIndex = try package.frameIndex()
            if readIndex.truncatedAtLine != nil { failures.append("frames.jsonl reads back torn") }
            if readIndex.expectedMovieFrameCount != encodedFrames + holds {
                failures.append(
                    "frames.jsonl implies \(readIndex.expectedMovieFrameCount) movie frames, "
                        + "expected \(encodedFrames + holds)")
            }
            if readIndex.frames().count != frameNumber {
                failures.append("frames.jsonl holds \(readIndex.frames().count) samples, expected \(frameNumber)")
            }
            if readIndex.holdTimes.count != holds {
                failures.append("frames.jsonl holds \(readIndex.holdTimes.count) holds")
            }
            let readLog = try package.eventLog()
            if readLog != log { failures.append("the event log did not round-trip") }
            let project = try package.readJSON(JSONValue.self, from: package.projectURL)
            if project["recording"]?["state"]?.stringValue != "complete" {
                failures.append("project.json does not carry the complete manifest")
            }
        } catch {
            failures.append("reading the package back failed: \(error.localizedDescription)")
        }

        guard let ffprobe = findFFprobe() else {
            print("note: ffprobe not found at /opt/homebrew/bin or on PATH; skipping the probe")
            return report(failures)
        }
        let probe = try Probe.run(ffprobe, on: movieURL)
        print(
            "ffprobe: codec=\(probe.codec) tag=\(probe.codecTag) \(probe.width)×\(probe.height) "
                + "nb_frames=\(probe.frameCount) has_b_frames=\(probe.bFrames) "
                + "start=\(format(probe.videoStartTime)) s duration=\(format(probe.videoDuration)) s; "
                + "keyframes \(probe.keyframeTimes.count), max gap \(format(probe.maximumKeyframeGap)) s")
        for track in probe.audioTracks {
            print(
                "audio: codec=\(track.codec) sample_rate=\(track.sampleRate) channels=\(track.channels) "
                    + "start=\(format(track.startTime)) s duration=\(format(track.duration)) s")
        }
        let expectedTag = encoder.codec == .hevc ? "hvc1" : "avc1"
        if probe.codecTag != expectedTag { failures.append("codec tag \(probe.codecTag) is not \(expectedTag)") }
        if probe.bFrames != 0 { failures.append("has_b_frames=\(probe.bFrames)") }
        if probe.width != configuration.width || probe.height != configuration.height {
            failures.append("frame size \(probe.width)×\(probe.height)")
        }
        if probe.frameCount != encodedFrames + holds {
            failures.append("nb_frames=\(probe.frameCount), expected \(encodedFrames + holds) (frames.jsonl agrees)")
        }
        if probe.maximumKeyframeGap > 2 + 1 / Double(frameRate) + 0.05 {
            failures.append("keyframe gap \(format(probe.maximumKeyframeGap)) s > 2 s")
        }
        let videoEnd = probe.videoStartTime + probe.videoDuration
        if abs(videoEnd - duration) > durationTolerance {
            failures.append("video ends at \(format(videoEnd)) s, expected ≈ \(format(duration)) s")
        }
        if probe.audioTracks.count != tones.count {
            failures.append("\(probe.audioTracks.count) audio tracks, expected \(tones.count)")
        }
        for (track, tone) in zip(probe.audioTracks, tones) {
            if track.codec != "aac" || track.sampleRate != ToneSource.sampleRate || track.channels != tone.channels {
                failures.append(
                    "\(tone.source.rawValue) track is \(track.codec) \(track.sampleRate) Hz × \(track.channels)")
            }
            if abs(track.startTime + track.duration - duration) > durationTolerance {
                failures.append("\(tone.source.rawValue) track ends at \(format(track.startTime + track.duration)) s")
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

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func findFFprobe() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffprobe" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - project.json

    /// A minimal project around the manifest with the default kit, spelled
    /// with the ARCHITECTURE §3 field names until `Project` (PLAN M1-03)
    /// lands and this is built through it. The kit groups mirror the Engine
    /// settings field for field.
    private static func projectTree(manifest: RecordingManifest) throws -> JSONValue {
        func spring(_ tension: Double, _ mass: Double, _ friction: Double) -> JSONValue {
            ["tension": .number(tension), "mass": .number(mass), "friction": .number(friction)]
        }
        let kit: JSONValue = [
            "schemaVersion": 1,
            "name": "Default",
            "background": ["kind": "linearGradient", "from": "#3B2F8F", "to": "#1E6FD9", "angleDegrees": 135],
            "frame": [
                "padding": 0.06, "cornerRadius": 14,
                "shadow": ["opacity": 0.45, "blurRadius": 40, "offsetX": 0, "offsetY": 20],
            ],
            "cursor": [
                "spring": spring(470, 3, 70), "clickSpring": spring(530, 1, 40), "dragSpring": spring(1000, 1, 40),
                "shakeLegThreshold": 0.015, "shakeWindow": 0.1, "maximumInputRate": 60,
                "minimumTravel": .number(1.0 / 1920), "leadTimeConstant": 0.13, "clickAnticipationWindow": 0.5,
                "clickSpringLead": 0.175, "idleHoldGap": 0.067, "settleTimeout": 5, "idleFadeDelay": 2,
                "fadeOutDuration": 0.4, "fadeInLead": 0.25, "pressScale": 0.8, "pressScaleDuration": 0.13,
                "scale": 1.8,
                "click": [
                    "radius": 44, "duration": 0.5, "easing": "easeOutCubic", "strokeWidth": 2.5, "opacity": 0.65,
                    "color": "#FFFFFF", "maximumConcurrent": 4,
                ],
            ],
            "zoom": [
                "leadIn": 0.3, "holdAfter": 2.5, "mergeGap": 2.5, "trailingIgnore": 1, "amount": 2,
                "detectsTypingBursts": true, "typingBurstMinimumKeys": 3, "typingBurstMaximumGap": 0.5,
                "camera": [
                    "sampleRate": 120, "retargetInterval": 0.008, "spring": spring(200, 2.25, 40),
                    "deadZoneWidth": 0.5, "deadZoneHeight": 0.7, "preAimThreshold": 1.0005,
                    "fallbackFocus": ["x": 0.5, "y": 0.5],
                ],
            ],
            "camera": [
                "shape": "circle", "size": 0.2, "inset": 0.03, "position": "bottomTrailing",
                "mirrorsBuiltInCamera": true, "border": nil, "shadow": "frame",
            ],
        ]
        return [
            "formatVersion": .integer(Int64(CutsceneCore.projectFormatVersion)),
            "recording": try JSONValue(encoding: manifest),
            "timeline": [
                "clips": [
                    [
                        "id": .string(UUID().uuidString), "sourceStart": 0,
                        "sourceEnd": .number(manifest.duration ?? 0),
                    ]
                ],
                "cuts": [], "zoom": ["segments": []], "captions": [], "callouts": [],
            ],
            "kit": kit,
            "style": kit,
            "kitReference": nil,
            "export": ["preset": "1080p", "frameRate": 60, "codec": "h264"],
        ]
    }

    // MARK: - Script

    /// Where everything is at a given time: the block (and the pointer on
    /// it) rides a Lissajous loop that pauses during the static stretch, and
    /// the terminal shows a command growing as the keys are typed.
    private struct Script {
        static let keyCodes = [8, 14, 2, 1, 32, 3, 38, 45]
        /// Loop periods in seconds; incommensurate so the path never repeats
        /// within a take.
        static let loopPeriodX = 7.0
        static let loopPeriodY = 5.0
        static let blockSize = 120.0
        /// The loop's centre and half-extents, in pixels of the 1920×1080 frame.
        static let centreX = 960.0
        static let centreY = 540.0
        static let extentX = 700.0
        static let extentY = 380.0

        let seconds: Double
        let staticRange: Range<Double>
        let clickTimes: [Double]
        let typingStart: Double

        struct Scene {
            var blockX: Double
            var blockY: Double
            var typedKeys: Int
            var pressed: Bool
        }

        /// Seconds of motion up to `time`: the clock the loop runs on stops
        /// during the static stretch.
        private func motionTime(_ time: Double) -> Double {
            if time < staticRange.lowerBound { return time }
            if time < staticRange.upperBound { return staticRange.lowerBound }
            return time - (staticRange.upperBound - staticRange.lowerBound)
        }

        func scene(at time: Double) -> Scene {
            let motion = motionTime(time)
            let blockX = Self.centreX + Self.extentX * sin(2 * .pi * motion / Self.loopPeriodX) - Self.blockSize / 2
            let blockY = Self.centreY + Self.extentY * sin(2 * .pi * motion / Self.loopPeriodY + 1) - Self.blockSize / 2
            let typedKeys = max(0, min(typingKeys, Int(((time - typingStart) / keyInterval).rounded(.down)) + 1))
            let pressed = clickTimes.contains { time >= $0 && time < $0 + clickHold }
            return Scene(
                blockX: blockX, blockY: blockY, typedKeys: time >= typingStart ? typedKeys : 0, pressed: pressed)
        }

        /// The pointer sits on the block's centre, normalized to the frame.
        func pointer(at time: Double) -> NormalizedPoint {
            let scene = scene(at: time)
            return NormalizedPoint(
                x: (scene.blockX + Self.blockSize / 2) / Double(width),
                y: (scene.blockY + Self.blockSize / 2) / Double(height))
        }
    }

    // MARK: - Desktop

    /// Paints the desktop into IOSurface-backed BGRA frames: the still parts
    /// (wallpaper, menu bar, windows with text-like stripes, dock) are drawn
    /// once and blitted, then the typed command and the block go on top.
    private final class DesktopPainter {
        private let width: Int
        private let height: Int
        private let pool: CVPixelBufferPool
        private let colorSpace: CGColorSpace
        private let backdrop: CGImage
        /// The terminal's command line, where typed keys appear.
        private let commandLine = CGRect(x: 1256 + 72, y: 156 + 22 * 14, width: 0, height: 10)

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
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw SpikeError.context }
            self.colorSpace = colorSpace
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw SpikeError.context }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            Self.drawBackdrop(in: context, width: CGFloat(width), height: CGFloat(height), colorSpace: colorSpace)
            guard let backdrop = context.makeImage() else { throw SpikeError.context }
            self.backdrop = backdrop
        }

        func paint(_ scene: Script.Scene) throws -> CVPixelBuffer {
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            guard status == kCVReturnSuccess, let buffer = created else { throw SpikeError.pixelBuffer(status) }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer),
                let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw SpikeError.context }
            // The backdrop was drawn flipped, so it is blitted unflipped; the
            // rest is drawn with a top-left origin, like the screen.
            context.draw(backdrop, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            if scene.typedKeys > 0 {
                var line = commandLine
                line.size.width = CGFloat(scene.typedKeys) * 14
                Self.fill(context, line, Self.rgb(0.95, 0.95, 0.95), radius: 3)
            }
            let block = CGRect(x: scene.blockX, y: scene.blockY, width: Script.blockSize, height: Script.blockSize)
            Self.fill(context, block, scene.pressed ? Self.rgb(1.0, 0.80, 0.30) : Self.rgb(1.0, 0.55, 0.10), radius: 14)
            return buffer
        }

        private static func drawBackdrop(
            in context: CGContext, width w: CGFloat, height h: CGFloat, colorSpace: CGColorSpace
        ) {
            if let gradient = CGGradient(
                colorsSpace: colorSpace, colors: [rgb(0.10, 0.16, 0.34), rgb(0.33, 0.14, 0.40)] as CFArray,
                locations: [0, 1])
            {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
            fill(context, CGRect(x: 0, y: 0, width: w, height: 28), rgba(0.96, 0.96, 0.98, 0.9))
            var random = StripeRandom(state: 0x5EED)
            var x: CGFloat = 16
            for _ in 0..<7 {
                let length = CGFloat(random.next(in: 36...90))
                fill(context, CGRect(x: x, y: 9, width: length, height: 10), rgb(0.2, 0.2, 0.22), radius: 3)
                x += length + 22
            }
            window(
                context, CGRect(x: 64, y: 92, width: 1120, height: 912), title: rgb(0.86, 0.86, 0.88),
                body: rgb(0.12, 0.12, 0.14))
            codeStripes(context, in: CGRect(x: 96, y: 160, width: 1056, height: 820), random: &random)
            window(
                context, CGRect(x: 1232, y: 92, width: 624, height: 440), title: rgb(0.24, 0.24, 0.27),
                body: rgb(0.05, 0.05, 0.07))
            terminalStripes(context, in: CGRect(x: 1256, y: 156, width: 576, height: 350), random: &random)
            window(
                context, CGRect(x: 1232, y: 564, width: 624, height: 440), title: rgb(0.93, 0.93, 0.95),
                body: rgb(1, 1, 1))
            pageStripes(context, in: CGRect(x: 1256, y: 628, width: 576, height: 350), random: &random)
            fill(context, CGRect(x: 640, y: 1004, width: 640, height: 64), rgba(0.9, 0.9, 0.95, 0.35), radius: 16)
            let dockColors = [
                rgb(0.95, 0.30, 0.25), rgb(0.98, 0.65, 0.15), rgb(0.95, 0.85, 0.20), rgb(0.30, 0.75, 0.35),
                rgb(0.25, 0.60, 0.95), rgb(0.55, 0.35, 0.85), rgb(0.90, 0.40, 0.70), rgb(0.30, 0.80, 0.80),
                rgb(0.60, 0.60, 0.65), rgb(0.20, 0.20, 0.25),
            ]
            for (slot, color) in dockColors.enumerated() {
                fill(context, CGRect(x: 656 + CGFloat(slot) * 62, y: 1012, width: 48, height: 48), color, radius: 11)
            }
        }

        private static func window(_ context: CGContext, _ rect: CGRect, title: CGColor, body: CGColor) {
            fill(context, rect, body, radius: 12)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.clip()
            fill(context, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44), title)
            context.restoreGState()
            let lights = [rgb(1.0, 0.37, 0.34), rgb(1.0, 0.74, 0.18), rgb(0.16, 0.78, 0.25)]
            for (slot, color) in lights.enumerated() {
                context.setFillColor(color)
                context.fillEllipse(
                    in: CGRect(x: rect.minX + 18 + CGFloat(slot) * 22, y: rect.minY + 15, width: 14, height: 14))
            }
        }

        /// Lines of "code": indented runs of coloured tokens.
        private static func codeStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            let palette = [
                rgb(0.78, 0.47, 0.87), rgb(0.40, 0.72, 0.98), rgb(0.60, 0.85, 0.55), rgb(0.95, 0.60, 0.35),
                rgb(0.75, 0.75, 0.78),
            ]
            var indent = 0
            var y = area.minY
            while y + 12 <= area.maxY {
                indent = max(0, min(indent + Int(random.next(in: -1.5...1.5)), 4))
                var x = area.minX + CGFloat(indent) * 32
                for _ in 0..<Int(random.next(in: 2...5.99)) {
                    let length = CGFloat(random.next(in: 40...180))
                    guard x + length <= area.maxX else { break }
                    let color = palette[Int(random.next(in: 0...Double(palette.count) - 0.01))]
                    fill(context, CGRect(x: x, y: y, width: length, height: 12), color, radius: 4)
                    x += length + 12
                }
                y += 26
            }
        }

        /// A prompt in green followed by a white command on every other
        /// line; the last prompt's command is empty, for the typing burst.
        private static func terminalStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            var y = area.minY
            var isPrompt = true
            var line = 0
            while y + 10 <= area.maxY {
                if isPrompt {
                    fill(context, CGRect(x: area.minX, y: y, width: 60, height: 10), rgb(0.35, 0.9, 0.45), radius: 3)
                    if line < 14 {
                        let length = CGFloat(random.next(in: 120...380))
                        fill(
                            context, CGRect(x: area.minX + 72, y: y, width: length, height: 10), rgb(0.9, 0.9, 0.9),
                            radius: 3)
                    }
                } else if line < 14 {
                    let length = CGFloat(random.next(in: 200...540))
                    fill(context, CGRect(x: area.minX, y: y, width: length, height: 10), rgb(0.6, 0.6, 0.62), radius: 3)
                }
                isPrompt.toggle()
                y += 22
                line += 1
            }
        }

        /// Grey paragraph lines with a blue button.
        private static func pageStripes(_ context: CGContext, in area: CGRect, random: inout StripeRandom) {
            fill(context, CGRect(x: area.minX, y: area.minY, width: 320, height: 22), rgb(0.15, 0.15, 0.18), radius: 5)
            var y = area.minY + 44
            while y + 10 <= area.maxY - 60 {
                let length = CGFloat(random.next(in: 300...560))
                fill(context, CGRect(x: area.minX, y: y, width: length, height: 10), rgb(0.72, 0.72, 0.75), radius: 3)
                y += 22
            }
            fill(
                context, CGRect(x: area.minX, y: area.maxY - 44, width: 140, height: 40), rgb(0.2, 0.5, 0.95), radius: 8
            )
        }

        private static func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            context.setFillColor(color)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else {
                context.fill(rect)
            }
        }

        private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// Deterministic stripe lengths, so every run paints the same desktop.
    private struct StripeRandom {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func next(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }

    // MARK: - Cursor sprites

    /// Draws a cursor shape as a PNG at the display's scale: a white shape
    /// with a dark outline, as the system cursors are.
    private enum SpriteWriter {
        static func write(_ shape: CursorShape, to url: URL, scale: Double) throws {
            let width = Int((shape.sizePoints.width * scale).rounded())
            let height = Int((shape.sizePoints.height * scale).rounded())
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw SpikeError.context }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            let path = CGMutablePath()
            switch shape.id {
            case "iBeam":
                let w = shape.sizePoints.width
                let h = shape.sizePoints.height
                path.move(to: CGPoint(x: 1, y: 1))
                path.addLine(to: CGPoint(x: w - 1, y: 1))
                path.move(to: CGPoint(x: w / 2, y: 1))
                path.addLine(to: CGPoint(x: w / 2, y: h - 1))
                path.move(to: CGPoint(x: 1, y: h - 1))
                path.addLine(to: CGPoint(x: w - 1, y: h - 1))
                context.addPath(path)
                context.setLineWidth(3)
                context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.strokePath()
                context.addPath(path)
                context.setLineWidth(1.2)
                context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.strokePath()
            default:
                path.move(to: CGPoint(x: 1, y: 1))
                path.addLine(to: CGPoint(x: 1, y: 17))
                path.addLine(to: CGPoint(x: 5, y: 13))
                path.addLine(to: CGPoint(x: 8, y: 20))
                path.addLine(to: CGPoint(x: 11, y: 19))
                path.addLine(to: CGPoint(x: 8, y: 12))
                path.addLine(to: CGPoint(x: 14, y: 12))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fillPath()
                context.addPath(path)
                context.setLineWidth(1)
                context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.strokePath()
            }
            guard let image = context.makeImage(),
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw SpikeError.context }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SpikeError.context }
        }
    }

    // MARK: - Audio

    /// LPCM audio in the shape ScreenCaptureKit delivers it: Float32 at
    /// 48 kHz, 1024 frames per buffer, interleaved (system) or planar (mic).
    private final class ToneSource {
        static let sampleRate = 48_000
        static let framesPerBuffer = 1024
        static let bufferDuration = CMTime(value: CMTimeValue(framesPerBuffer), timescale: CMTimeScale(sampleRate))

        let source: RecordingAudioSource
        let channels: Int
        let interleaved: Bool
        private let format: CMAudioFormatDescription

        init(source: RecordingAudioSource, channels: Int, interleaved: Bool) throws {
            self.source = source
            self.channels = channels
            self.interleaved = interleaved
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

        /// One buffer of a steady tone starting at `offset` seconds.
        func tone(at offset: Double, frequency: Double, amplitude: Float) -> [Float] {
            samples { frame in
                Float(sin(2 * .pi * frequency * (offset + Double(frame) / Double(Self.sampleRate)))) * amplitude
            }
        }

        /// One buffer that is silent except during a short beep after each
        /// of `times`.
        func beeps(at offset: Double, times: [Double], length: Double, frequency: Double, amplitude: Float) -> [Float] {
            samples { frame in
                let time = offset + Double(frame) / Double(Self.sampleRate)
                guard times.contains(where: { time >= $0 && time < $0 + length }) else { return 0 }
                return Float(sin(2 * .pi * frequency * time)) * amplitude
            }
        }

        private func samples(_ value: (Int) -> Float) -> [Float] {
            var samples = [Float](repeating: 0, count: Self.framesPerBuffer * channels)
            for frame in 0..<Self.framesPerBuffer {
                let sample = value(frame)
                for channel in 0..<channels {
                    // Planar data is one channel after another; interleaved alternates.
                    let index = interleaved ? frame * channels + channel : channel * Self.framesPerBuffer + frame
                    samples[index] = sample
                }
            }
            return samples
        }

        /// A sample buffer whose first frame plays at `time`.
        func buffer(_ samples: [Float], at time: CMTime) throws -> CMSampleBuffer {
            let byteCount = samples.count * MemoryLayout<Float>.size
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                flags: 0, blockBufferOut: &block)
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

    // MARK: - ffprobe

    enum SpikeError: LocalizedError {
        case pixelBufferPool(CVReturn)
        case pixelBuffer(CVReturn)
        case context
        case audioBuffer(OSStatus)
        case probeExited(Int32)
        case probeOutput(String)

        var errorDescription: String? {
            switch self {
            case .pixelBufferPool(let status): "CVPixelBufferPoolCreate failed (\(status))."
            case .pixelBuffer(let status): "CVPixelBufferPoolCreatePixelBuffer failed (\(status))."
            case .context: "A CoreGraphics context or image could not be created."
            case .audioBuffer(let status): "Building an LPCM sample buffer failed (\(status))."
            case .probeExited(let status): "ffprobe exited with status \(status)."
            case .probeOutput(let detail): "Could not read ffprobe output: \(detail)."
            }
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
        var codecTag: String
        var width: Int
        var height: Int
        var frameCount: Int
        var bFrames: Int
        var videoStartTime: Double
        var videoDuration: Double
        var keyframeTimes: [Double]
        var audioTracks: [AudioTrack]

        var maximumKeyframeGap: Double {
            zip(keyframeTimes.dropFirst(), keyframeTimes).map(-).max() ?? 0
        }

        /// ffprobe's JSON; counts and rates it derives arrive as strings.
        private struct StreamReport: Decodable {
            struct Stream: Decodable {
                var codecName: String
                var codecTag: String?
                var width: Int?
                var height: Int?
                var frameCount: String?
                var bFrames: Int?
                var sampleRate: String?
                var channels: Int?
                var startTime: String?
                var duration: String?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case codecTag = "codec_tag_string"
                    case width
                    case height
                    case frameCount = "nb_frames"
                    case bFrames = "has_b_frames"
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
                "stream=codec_name,codec_tag_string,width,height,nb_frames,has_b_frames,sample_rate,channels,"
                + "start_time,duration"
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
            for line in packets.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 2, let time = Double(fields[0]), fields[1].contains("K") else { continue }
                keyframeTimes.append(time)
            }
            return Probe(
                codec: stream.codecName, codecTag: stream.codecTag ?? "", width: stream.width ?? 0,
                height: stream.height ?? 0, frameCount: stream.frameCount.flatMap(Int.init) ?? 0,
                bFrames: stream.bFrames ?? 0, videoStartTime: stream.startTime.flatMap(Double.init) ?? 0,
                videoDuration: stream.duration.flatMap(Double.init) ?? 0, keyframeTimes: keyframeTimes.sorted(),
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
