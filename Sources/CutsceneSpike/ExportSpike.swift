import AVFoundation
import CoreGraphics
import CoreMedia
import CutsceneCore
import CutsceneEngine
import CutsceneExport
import CutsceneRender
import Foundation
import Synchronization

/// Export of a package through `Exporter`, probed with ffprobe (PLAN M1-11,
/// M2-08).
///
/// `export <package> [4k|1080p|vertical|square] [30|60] [hevc|h264] [--tones]
/// [--out <directory>]` plans the recording with its project's style,
/// exports the whole take with the chosen preset (the project's own unless
/// the arguments say otherwise) into `~/Movies/Cutscene/Exports` (or
/// `--out`), prints the speed against real time, and checks the file with
/// ffprobe: the codec tag and profile, the size, a constant frame rate,
/// `nb_frames` against `duration × fps ± 1`, keyframes at most 2 s apart,
/// AAC at 48 kHz stereo, `moov` before `mdat`, and the rate control against
/// ARCHITECTURE §6 (the configured average within 20 % of the table, the
/// measured rate under the cap). Two decoded frames must be the canvas
/// size with every edge lit by the background, so a 9:16 or 1:1 export
/// fills its frame rather than sitting in a black box. `--tones`, for a
/// package from `make spike ARGS="package"`, decodes the exported audio
/// and measures its known tones, so the mix levels (mic 0 dB, system
/// −6 dB) are checked as levels and not as settings. Then it exports the
/// same job twice more and cancels each run early, once through
/// `Exporter.cancel()` and once by cancelling the task, and checks that the
/// destination folder is left exactly as it was. No permission is needed.
enum ExportSpike {
    /// Frames to let a cancelled run write before the cancel, so it is
    /// mid-stream rather than at the start.
    static let cancelAfterFrames = 45
    /// The configured average may differ from ARCHITECTURE §6's table by
    /// this fraction, and the measured video rate may exceed the preset's
    /// cap by it (PLAN M2-08: "within 20 %").
    static let bitRateTolerance = 0.2
    /// ARCHITECTURE §6's rate table in Mb/s, by preset and codec; a codec
    /// the table does not quote for a preset (the HEVC toggle of the social
    /// shapes) is reported, not checked.
    static let architectureRateMegabits: [ExportPresetID: [ExportCodec: Double]] = [
        .hd1080: [.h264: 16, .hevc: 10],
        .uhd4K: [.hevc: 45, .h264: 60],
        .vertical1080: [.h264: 16],
        .square1080: [.h264: 12],
    ]
    /// Where in the export the fill check decodes a frame, as fractions of
    /// the duration: early, and in the middle where the zoom is likely in.
    static let fillSampleFractions = [0.1, 0.5]
    /// Pixels in from the frame's edge that the fill samples are taken,
    /// clear of the encoder's edge macroblock.
    static let fillSampleInset = 2
    /// The brightest channel of an edge sample must reach this (of 255) to
    /// count as lit: the default gradient's darkest stop is #1C2B4B, and a
    /// letterboxed frame would be 0 there.
    static let fillBlackThreshold: UInt8 = 8
    /// A measured tone may differ from its expected level by this fraction:
    /// AAC at 192 kbps keeps a pure tone's amplitude well within it.
    static let toneLevelTolerance = 0.15
    /// Seconds trimmed from each end of the package spike's static stretch
    /// before the system tone is measured in it, so the beep before or
    /// after the stretch cannot leak into the window.
    static let toneWindowMargin = 0.25
    /// The microphone beeps are measured over windows this fraction of a
    /// beep long, so one window lies entirely inside a beep.
    static let beepWindowFraction = 0.5
    /// What the audio mix spreads a mono microphone track across the two
    /// output channels at: unity, measured on 2026-11-04 (a beep recorded at
    /// 0.5 came out at 0.5 on each channel), so the mic is never 3 dB quieter
    /// in the export than in the take.
    static let monoToStereoGain = 1.0
    /// Progress lines are printed at most this often, in seconds.
    static let progressPrintInterval = 1.0
    /// `nb_frames = duration × fps ± 1` (PLAN M1-11).
    static let frameCountTolerance = 1
    /// Absorbs the conversion of rational packet times to seconds.
    static let frameStepTolerance = 1e-6
    /// Keyframes come at least every 2 s; the duration rule can only act on
    /// the next frame, so a frame interval and a little slack are allowed.
    static let keyframeGapSlack = 0.05
    /// Top-level MP4 boxes read when looking for `moov` and `mdat`.
    static let boxScanLimit = 8
    /// The AAC track is encoded at a constant rate; ffprobe's figure
    /// includes packet framing, so a little slack either side.
    static let audioBitRateTolerance = 0.1
    /// One 60 fps interval: ARCHITECTURE §5 trips the v2 decoder when the
    /// median compositor request exceeds it at 4K60. Reported, not enforced.
    static let decoderTriggerMedianMilliseconds = 16.7

    static func run(arguments: [String]) async -> Bool {
        guard let first = arguments.first else {
            print(
                "usage: export <package> [4k|1080p|vertical|square] [30|60] [hevc|h264] [--tones] [--out <directory>]")
            return false
        }
        var presetID: ExportPresetID?
        var frameRate: Int?
        var codec: ExportCodec?
        var checkTones = false
        var outputDirectory = RecordingPackage.defaultExportsDirectory
        var rest = Array(arguments.dropFirst())
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            switch argument.lowercased() {
            case "4k": presetID = .uhd4K
            case "1080p": presetID = .hd1080
            case "vertical": presetID = .vertical1080
            case "square": presetID = .square1080
            case "30": frameRate = 30
            case "60": frameRate = 60
            case "hevc": codec = .hevc
            case "h264": codec = .h264
            case "--tones": checkTones = true
            case "--out":
                guard !rest.isEmpty else {
                    print("--out needs a directory")
                    return false
                }
                outputDirectory = URL(fileURLWithPath: rest.removeFirst(), isDirectory: true)
            default:
                print("unknown argument \(argument)")
                return false
            }
        }
        do {
            let package = try RecordingPackage.open(at: URL(fileURLWithPath: first))
            return try await export(
                package: package, presetID: presetID, frameRate: frameRate, codec: codec, checkTones: checkTones,
                into: outputDirectory)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - The run

    private static func export(
        package: RecordingPackage, presetID: ExportPresetID?, frameRate: Int?, codec: ExportCodec?, checkTones: Bool,
        into directory: URL
    ) async throws -> Bool {
        print("export spike: \(package.url.path)")
        let manifest = try package.manifest()
        let log = try package.eventLog()
        // A take that never reached stop has no recorded duration; the movie's is the next best.
        let duration: Double
        if let recorded = manifest.duration {
            duration = recorded
        } else {
            duration = try await AVURLAsset(url: package.screenMovieURL).load(.duration).seconds
        }

        // The project's style and export settings, as the app renders with;
        // the built-in defaults when the package has no readable project.
        var kit = BrandKit.default
        var exportSettings = ExportSettings()
        var projectSource = "built-in defaults (no readable project.json)"
        if FileManager.default.fileExists(atPath: package.projectURL.path) {
            do {
                let project = try Project.read(from: package.projectURL)
                kit = project.style
                exportSettings = project.export
                projectSource = "project.json"
            } catch {
                projectSource = "built-in defaults (project.json: \(error.localizedDescription))"
            }
        }
        if let presetID { exportSettings.preset = presetID }
        if let frameRate { exportSettings.frameRate = frameRate }
        if let codec { exportSettings.codec = codec }
        let preset = try ExportPreset.resolve(exportSettings)
        print(
            "recording: \(manifest.screen.width)×\(manifest.screen.height) \(manifest.screen.codec), "
                + "\(format(duration)) s, \(manifest.screen.audioTracks.count) audio tracks, \(log.events.count) events; "
                + "style and levels from \(projectSource)")
        print(
            "preset: \(preset.label) (\(preset.canvas.width)×\(preset.canvas.height)), "
                + "\(preset.rateControl.averageBitRate / 1000) kb/s average, "
                + "\(preset.rateControl.dataRateLimit / 1000) kb/s cap per \(preset.rateControl.dataRateLimitWindow) s; "
                + "mic \(exportSettings.audio.microphoneGainDB) dB, system \(exportSettings.audio.systemAudioGainDB) dB; "
                + "GPU \(CutsceneRender.gpuName ?? "none")")

        let clock = ContinuousClock()
        var built: RenderPlan?
        let planTime = clock.measure { built = RenderPlan.build(log: log, duration: duration, kit: kit) }
        guard let plan = built else { return false }
        print(
            "plan: \(plan.zoomSegments.count) zoom segments, \(plan.cursorShapeChanges.count) shape changes, "
                + "built in \(milliseconds(planTime)) ms")
        let job = ExportJob(
            package: package, keptRanges: [0...duration], plan: plan, kit: kit, preset: preset,
            audio: exportSettings.audio, destinationDirectory: directory)
        let writerSettings = ExportWriterSettings()
        let estimate = job.estimate(settings: writerSettings)
        print(
            "estimate: about \(estimate.bytes >> 20) MB with headroom, \(format(estimate.seconds)) s at "
                + "\(preset.estimatedSpeed)× real time; destination \(directory.path)")

        var failures: [String] = []
        let exporter = Exporter(settings: writerSettings)
        let printer = ProgressPrinter()
        let result = try await exporter.export(job) { progress in printer.print(progress) }
        let compositor = result.compositor
        print(
            "exported \(result.outputURL.path): \(result.fileSizeBytes >> 10) KiB, "
                + "\(format(result.durationSeconds)) s, \(result.frameCount) frames "
                + "(\(result.expectedFrameCount) expected), \(result.audioBuffersWritten) audio buffers, "
                + "\(String(format: "%.0f", result.averageBitRate / 1000)) kb/s overall")
        print(
            "speed: \(String(format: "%.2f", result.speed))× real time overall "
                + "(\(format(result.elapsedSeconds)) s); encoding \(String(format: "%.2f", result.encodingSpeed))× "
                + "(\(format(result.encodingSeconds)) s), finishing \(format(result.finishingSeconds)) s")
        if let compositor {
            let median = compositor.medianLatencySeconds * 1000
            print(
                "compositor: \(compositor.requests) requests, \(compositor.heldFrames) held, "
                    + "\(compositor.blankFrames) blank, \(compositor.failures) failed; "
                    + "median \(String(format: "%.2f", median)) ms, "
                    + "mean \(String(format: "%.2f", compositor.meanLatencySeconds * 1000)) ms, "
                    + "max \(String(format: "%.2f", compositor.maximumLatencySeconds * 1000)) ms, "
                    + "warm-up \(compositor.warmUpSeconds.map { String(format: "%.1f", $0 * 1000) + " ms" } ?? "none")"
                    + " (§5 trigger: median over \(decoderTriggerMedianMilliseconds) ms at 4K60"
                    + (preset.canvas.height >= ExportPreset.uhd4K.canvas.height
                        ? (median > decoderTriggerMedianMilliseconds ? ", TRIPPED)" : ", not tripped)") : ")"))
            if compositor.failures > 0 { failures.append("\(compositor.failures) compositor requests failed") }
        } else {
            failures.append("the reader's compositor was not a MetalCompositor")
        }
        if !result.isFaststart { failures.append("the exporter reports moov after mdat") }

        // ffprobe, independently of the exporter's own self-check.
        guard let ffprobe = findFFprobe() else {
            print("note: ffprobe not found at /opt/homebrew/bin or on PATH; skipping the probe")
            return report(failures)
        }
        let probe = try Probe.run(ffprobe, on: result.outputURL)
        print(
            "ffprobe: codec=\(probe.codec) tag=\(probe.codecTag) profile=\(probe.profile) "
                + "\(probe.width)×\(probe.height) r_frame_rate=\(probe.realFrameRate) "
                + "avg_frame_rate=\(probe.averageFrameRate) nb_frames=\(probe.frameCount) "
                + "has_b_frames=\(probe.bFrames) bit_rate=\(probe.bitRate.map { "\($0 / 1000) kb/s" } ?? "n/a") "
                + "start=\(format(probe.videoStartTime)) s duration=\(format(probe.videoDuration)) s; "
                + "keyframes \(probe.keyframeTimes.count), max gap \(format(probe.maximumKeyframeGap)) s")
        for track in probe.audioTracks {
            print(
                "audio: codec=\(track.codec) sample_rate=\(track.sampleRate) channels=\(track.channels) "
                    + "bit_rate=\(track.bitRate.map { "\($0 / 1000) kb/s" } ?? "n/a") "
                    + "duration=\(format(track.duration)) s")
        }
        let boxes = try topLevelBoxTypes(of: result.outputURL)
        print("boxes: \(boxes.joined(separator: " "))")

        let canvas = preset.canvas
        let expectedFrames = canvas.frameCount(forDuration: result.durationSeconds)
        let expectedProfile = preset.codec == .h264 ? "High" : "Main"
        if probe.codecTag != preset.codec.mp4Tag {
            failures.append("codec tag \(probe.codecTag) is not \(preset.codec.mp4Tag)")
        }
        if probe.profile != expectedProfile { failures.append("profile \(probe.profile) is not \(expectedProfile)") }
        if probe.width != canvas.width || probe.height != canvas.height {
            failures.append("frame size \(probe.width)×\(probe.height) is not \(canvas.width)×\(canvas.height)")
        }
        let expectedRate = "\(canvas.frameRate)/1"
        if probe.realFrameRate != expectedRate || probe.averageFrameRate != expectedRate {
            failures.append(
                "frame rate r=\(probe.realFrameRate) avg=\(probe.averageFrameRate), expected \(expectedRate)")
        }
        if abs(probe.frameCount - expectedFrames) > frameCountTolerance {
            failures.append(
                "nb_frames=\(probe.frameCount), expected \(expectedFrames) ± \(frameCountTolerance) "
                    + "(\(format(result.durationSeconds)) s × \(canvas.frameRate))")
        }
        if probe.frameCount != result.frameCount {
            failures.append("ffprobe counts \(probe.frameCount) frames, the exporter \(result.frameCount)")
        }
        let step = 1 / Double(canvas.frameRate)
        let irregular = zip(probe.presentationTimes.dropFirst(), probe.presentationTimes).filter {
            abs(($0 - $1) - step) > frameStepTolerance
        }
        if !irregular.isEmpty {
            failures.append("\(irregular.count) frame intervals differ from \(format(step)) s")
        }
        if probe.keyframeTimes.isEmpty { failures.append("no keyframes") }
        if probe.maximumKeyframeGap > writerSettings.maxKeyFrameIntervalDuration + step + keyframeGapSlack {
            failures.append(
                "keyframe gap \(format(probe.maximumKeyframeGap)) s > \(writerSettings.maxKeyFrameIntervalDuration) s")
        }
        if manifest.screen.audioTracks.isEmpty {
            if !probe.audioTracks.isEmpty { failures.append("an audio track appeared from a silent recording") }
        } else if probe.audioTracks.count != 1 {
            failures.append("\(probe.audioTracks.count) audio tracks, expected 1")
        } else {
            let track = probe.audioTracks[0]
            if track.codec != "aac" || track.sampleRate != writerSettings.audio.sampleRate
                || track.channels != writerSettings.audio.channelCount
            {
                failures.append(
                    "audio is \(track.codec) \(track.sampleRate) Hz × \(track.channels), expected aac "
                        + "\(writerSettings.audio.sampleRate) Hz × \(writerSettings.audio.channelCount)")
            }
            let target = Double(writerSettings.audio.bitRate)
            if let bitRate = track.bitRate, abs(Double(bitRate) - target) > target * audioBitRateTolerance {
                failures.append(
                    "audio bit rate \(bitRate / 1000) kb/s is not within \(Int(audioBitRateTolerance * 100)) % of "
                        + "\(writerSettings.audio.bitRate / 1000) kb/s")
            }
        }
        if let moov = boxes.firstIndex(of: "moov"), let mdat = boxes.firstIndex(of: "mdat") {
            if moov > mdat { failures.append("moov comes after mdat") }
        } else {
            failures.append("moov or mdat not among the first \(boxScanLimit) boxes")
        }
        checkRates(preset: preset, measuredBitRate: probe.bitRate, failures: &failures)
        try await checkFill(
            of: result.outputURL, canvas: canvas, durationSeconds: result.durationSeconds, failures: &failures)
        if checkTones {
            try await measureTones(
                of: result.outputURL, recordingSeconds: duration, levels: exportSettings.audio,
                settings: writerSettings,
                failures: &failures)
        }

        // A cancelled export leaves nothing behind.
        print("")
        try await cancelThroughExporter(job: job, settings: writerSettings, directory: directory, failures: &failures)
        try await cancelThroughTask(job: job, settings: writerSettings, directory: directory, failures: &failures)

        return report(failures)
    }

    // MARK: - Rates

    /// The preset's configured average against ARCHITECTURE §6's table, and
    /// the file's measured video rate against the preset's cap. The measured
    /// rate is not held to the average: the encoder spends what the content
    /// needs, and a still desktop needs far less than the budget.
    private static func checkRates(preset: ExportPreset, measuredBitRate: Int?, failures: inout [String]) {
        let configured = Double(preset.rateControl.averageBitRate) / 1e6
        if let table = architectureRateMegabits[preset.id]?[preset.codec] {
            let within = abs(configured - table) <= table * bitRateTolerance
            print(
                "rate control: \(preset.id.rawValue) \(preset.codec.label) configured \(configured) Mb/s, "
                    + "§6 \(table) Mb/s (\(within ? "within" : "outside") \(Int(bitRateTolerance * 100)) %)")
            if !within {
                failures.append(
                    "configured \(configured) Mb/s is not within \(Int(bitRateTolerance * 100)) % of §6's \(table) Mb/s"
                )
            }
        } else {
            print(
                "rate control: \(preset.id.rawValue) \(preset.codec.label) configured \(configured) Mb/s; "
                    + "§6 quotes no rate for this codec on this preset")
        }
        guard let measuredBitRate else {
            print("video bit rate: ffprobe reports none")
            return
        }
        let cap = Double(preset.rateControl.dataRateLimit)
        let percentOfAverage = Double(measuredBitRate) / Double(preset.rateControl.averageBitRate) * 100
        print(
            "video bit rate: measured \(measuredBitRate / 1000) kb/s, \(String(format: "%.0f", percentOfAverage)) % of "
                + "the \(preset.rateControl.averageBitRate / 1000) kb/s average, cap \(Int(cap) / 1000) kb/s")
        if Double(measuredBitRate) > cap * (1 + bitRateTolerance) {
            failures.append(
                "measured \(measuredBitRate / 1000) kb/s exceeds the \(Int(cap) / 1000) kb/s cap by more than "
                    + "\(Int(bitRateTolerance * 100)) %")
        }
    }

    // MARK: - Fill

    /// Decodes a frame at each of `fillSampleFractions` and requires it to
    /// be the canvas size with the four corners and four edge midpoints lit:
    /// the background reaches every edge of a filled frame, while a 16:9
    /// picture placed in a tall or square box leaves black bands.
    private static func checkFill(of url: URL, canvas: CanvasSpec, durationSeconds: Double, failures: inout [String])
        async throws
    {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for fraction in fillSampleFractions {
            let requested = CMTime(
                seconds: durationSeconds * fraction, preferredTimescale: CMTimeScale(canvas.frameRate))
            let (image, actual) = try await generator.image(at: requested)
            guard image.width == canvas.width, image.height == canvas.height else {
                failures.append(
                    "decoded frame at \(format(actual.seconds)) s is \(image.width)×\(image.height), "
                        + "not \(canvas.width)×\(canvas.height)")
                continue
            }
            let pixels = try bgraBytes(of: image)
            let last = (x: image.width - 1 - fillSampleInset, y: image.height - 1 - fillSampleInset)
            let samples = [
                (fillSampleInset, fillSampleInset), (last.x, fillSampleInset), (fillSampleInset, last.y),
                (last.x, last.y),
                (image.width / 2, fillSampleInset), (image.width / 2, last.y), (fillSampleInset, image.height / 2),
                (last.x, image.height / 2),
            ]
            var dark: [String] = []
            var brightest: [UInt8] = []
            for (x, y) in samples {
                let offset = (y * image.width + x) * 4
                let peak = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
                brightest.append(peak)
                if peak < fillBlackThreshold { dark.append("(\(x), \(y))") }
            }
            print(
                "fill at \(format(actual.seconds)) s: \(image.width)×\(image.height), edge samples' peak channels "
                    + "\(brightest.map(String.init).joined(separator: " "))"
                    + (dark.isEmpty ? "; every edge lit" : "; dark at \(dark.joined(separator: " "))"))
            if !dark.isEmpty {
                failures.append(
                    "frame at \(format(actual.seconds)) s is not filled: dark at \(dark.joined(separator: " "))")
            }
        }
    }

    /// The image's pixels as 8-bit BGRA rows, `width × 4` bytes each.
    private static func bgraBytes(of image: CGImage) throws -> [UInt8] {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw SpikeError.frameDecode("no BGRA context for \(image.width)×\(image.height)") }
        return pixels
    }

    // MARK: - Tones

    /// Decodes the export's audio and measures the package spike's tones in
    /// it: the steady system tone, over the static stretch where the mic is
    /// silent, must come out at its recorded amplitude times the system
    /// gain; the loudest microphone beep at its amplitude times the mic
    /// gain. Levels are compared as amplitudes, so the gains the mix was
    /// asked for are what the file carries.
    private static func measureTones(
        of url: URL, recordingSeconds: Double, levels: ExportAudioSettings, settings: ExportWriterSettings,
        failures: inout [String]
    ) async throws {
        let (samples, channels, sampleRate) = try await decodeAudio(of: url, settings: settings)
        let frameCount = samples.count / max(channels, 1)
        guard frameCount > 0 else {
            failures.append("tones: the export has no audio to measure")
            return
        }
        func frames(from start: Double, to end: Double) -> Range<Int> {
            let lower = min(max(Int(start * sampleRate), 0), frameCount)
            let upper = min(max(Int(end * sampleRate), lower), frameCount)
            return lower..<upper
        }
        // Composition time 0 is the first screen frame, `firstFrameDelay`
        // into the recording; the package spike's stretches are recording time.
        let shift = PackageSpike.firstFrameDelay
        let staticWindow = frames(
            from: recordingSeconds * PackageSpike.staticStart - shift + toneWindowMargin,
            to: recordingSeconds * PackageSpike.staticEnd - shift - toneWindowMargin)
        guard staticWindow.count > 0 else {
            failures.append("tones: the static stretch is empty in the export")
            return
        }
        let expectedTone = Double(PackageSpike.systemToneAmplitude) * linearGain(decibels: levels.systemAudioGainDB)
        let expectedBeep =
            Double(PackageSpike.microphoneBeepAmplitude) * linearGain(decibels: levels.microphoneGainDB)
            * monoToStereoGain
        let beepWindow = max(Int(PackageSpike.microphoneBeepLength * beepWindowFraction * sampleRate), 1)
        for channel in 0..<channels {
            let tone = amplitude(
                of: samples, channel: channel, channels: channels, frames: staticWindow,
                frequency: PackageSpike.systemToneHz, sampleRate: sampleRate)
            var beep = 0.0
            for start in stride(from: 0, to: frameCount - beepWindow, by: beepWindow) {
                let window = start..<start + beepWindow
                guard !window.overlaps(staticWindow) else { continue }
                beep = max(
                    beep,
                    amplitude(
                        of: samples, channel: channel, channels: channels, frames: window,
                        frequency: PackageSpike.microphoneBeepHz, sampleRate: sampleRate))
            }
            print(
                "tones channel \(channel): system \(Int(PackageSpike.systemToneHz)) Hz "
                    + "\(String(format: "%.4f", tone)) (expected \(String(format: "%.4f", expectedTone)) at "
                    + "\(levels.systemAudioGainDB) dB), mic beep \(Int(PackageSpike.microphoneBeepHz)) Hz "
                    + "\(String(format: "%.4f", beep)) (expected \(String(format: "%.4f", expectedBeep)) at "
                    + "\(levels.microphoneGainDB) dB)")
            if abs(tone - expectedTone) > expectedTone * toneLevelTolerance {
                failures.append(
                    "channel \(channel) system tone \(String(format: "%.4f", tone)) is not within "
                        + "\(Int(toneLevelTolerance * 100)) % of \(String(format: "%.4f", expectedTone))")
            }
            if abs(beep - expectedBeep) > expectedBeep * toneLevelTolerance {
                failures.append(
                    "channel \(channel) mic beep \(String(format: "%.4f", beep)) is not within "
                        + "\(Int(toneLevelTolerance * 100)) % of \(String(format: "%.4f", expectedBeep))")
            }
        }
    }

    /// The export's audio as interleaved Float32 at the writer's rate and
    /// layout (the mix output's own format), with the channel count and rate.
    private static func decodeAudio(of url: URL, settings: ExportWriterSettings) async throws -> (
        samples: [Float], channels: Int, sampleRate: Double
    ) {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpikeError.audioDecode("no audio track")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings.audioMixOutputSettings())
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpikeError.audioDecode("the reader refused the track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw SpikeError.audioDecode(reader.error?.localizedDescription ?? "startReading returned false")
        }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw SpikeError.audioDecode("block buffer copy \(status)") }
            bytes.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        guard reader.status == .completed else {
            throw SpikeError.audioDecode(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        return (samples, settings.audio.channelCount, Double(settings.audio.sampleRate))
    }

    /// The amplitude of a sine at `frequency` in one channel over `frames`,
    /// by the Goertzel recurrence: `2 |X| / N`, so a full-scale sine reads 1.
    private static func amplitude(
        of samples: [Float], channel: Int, channels: Int, frames: Range<Int>, frequency: Double, sampleRate: Double
    ) -> Double {
        guard !frames.isEmpty else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for frame in frames {
            let current = Double(samples[frame * channels + channel]) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let real = previous - beforePrevious * cos(omega)
        let imaginary = beforePrevious * sin(omega)
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(frames.count)
    }

    /// `10^(dB / 20)`: the amplitude ratio a level in decibels names.
    private static func linearGain(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    // MARK: - Cancel

    /// Exports `job` again and calls `Exporter.cancel()` from the progress
    /// callback once `cancelAfterFrames` are written.
    private static func cancelThroughExporter(
        job: ExportJob, settings: ExportWriterSettings, directory: URL, failures: inout [String]
    ) async throws {
        let before = try directoryListing(directory)
        let exporter = Exporter(settings: settings)
        let sent = Mutex(false)
        let outcome = await outcome {
            try await exporter.export(job) { progress in
                guard progress.phase == .encoding, progress.framesWritten >= cancelAfterFrames else { return }
                let first = sent.withLock { sent -> Bool in
                    if sent { return false }
                    sent = true
                    return true
                }
                guard first else { return }
                Task { await exporter.cancel() }
            }
        }
        check(outcome, label: "cancel()", before: before, directory: directory, failures: &failures)
    }

    /// Exports `job` in a task and cancels the task once `cancelAfterFrames`
    /// are written.
    private static func cancelThroughTask(
        job: ExportJob, settings: ExportWriterSettings, directory: URL, failures: inout [String]
    ) async throws {
        let before = try directoryListing(directory)
        let exporter = Exporter(settings: settings)
        let gate = Gate()
        let task = Task {
            try await exporter.export(job) { progress in
                guard progress.phase == .encoding, progress.framesWritten >= cancelAfterFrames else { return }
                gate.open()
            }
        }
        await gate.wait()
        task.cancel()
        let outcome = await outcome { try await task.value }
        check(outcome, label: "task cancellation", before: before, directory: directory, failures: &failures)
    }

    private static func outcome(_ body: () async throws -> ExportResult) async -> Result<ExportResult, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    private static func check(
        _ outcome: Result<ExportResult, any Error>, label: String, before: Set<String>, directory: URL,
        failures: inout [String]
    ) {
        switch outcome {
        case .success(let result):
            failures.append("\(label): the export finished (\(result.outputURL.lastPathComponent)) instead of stopping")
            try? FileManager.default.removeItem(at: result.outputURL)
        case .failure(let error):
            if case ExportError.cancelled = error {
                print("\(label): the export threw ExportError.cancelled")
            } else {
                failures.append("\(label): the export threw \(error.localizedDescription), not cancelled")
            }
        }
        do {
            let after = try directoryListing(directory)
            let partials = after.filter { $0.hasPrefix(ExportWriterSettings().temporaryFilePrefix) }
            if !partials.isEmpty { failures.append("\(label): partial files left behind: \(partials.sorted())") }
            if after != before {
                failures.append(
                    "\(label): the destination changed: added \(after.subtracting(before).sorted()), "
                        + "removed \(before.subtracting(after).sorted())")
            } else {
                print("\(label): \(directory.lastPathComponent) unchanged (\(after.count) entries, no partial file)")
            }
        } catch {
            failures.append("\(label): could not list \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Every entry of `directory`, hidden ones included.
    private static func directoryListing(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// A one-shot latch: `wait()` returns once `open()` has been called,
    /// whichever comes first.
    private final class Gate: Sendable {
        private struct State {
            var opened = false
            var waiter: CheckedContinuation<Void, Never>?
        }
        private let state = Mutex(State())

        func open() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.opened = true
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.opened { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    // MARK: - Progress

    /// Prints a progress line per phase change and at most every
    /// `progressPrintInterval` seconds while encoding.
    private final class ProgressPrinter: Sendable {
        private struct State {
            var lastPhase: ExportPhase?
            var lastPrint: ContinuousClock.Instant?
        }
        private let state = Mutex(State())

        func print(_ progress: ExportProgress) {
            let now = ContinuousClock.now
            let due = state.withLock { state -> Bool in
                let phaseChanged = state.lastPhase != progress.phase
                let elapsed = state.lastPrint.map { now - $0 >= .seconds(progressPrintInterval) } ?? true
                guard phaseChanged || elapsed else { return false }
                state.lastPhase = progress.phase
                state.lastPrint = now
                return true
            }
            guard due else { return }
            let speed = progress.speed.map { String(format: "%.2f× real time", $0) } ?? "–"
            let remaining =
                progress.estimatedRemainingSeconds.map { ", about \(String(format: "%.1f", $0)) s left" } ?? ""
            Swift.print(
                "  \(progress.phase.rawValue) \(String(format: "%3.0f", progress.fraction * 100))%  "
                    + "\(format(progress.writtenSeconds))/\(format(progress.durationSeconds)) s  "
                    + "\(progress.framesWritten)/\(progress.expectedFrames) frames  \(speed)\(remaining)")
        }
    }

    // MARK: - Helpers

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

    private static func milliseconds(_ duration: Duration) -> String {
        String(
            format: "%.1f", Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15)
    }

    private static func findFFprobe() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffprobe" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The types of the file's first top-level boxes: `ftyp moov mdat` is a
    /// faststart file, `ftyp mdat moov` is not.
    private static func topLevelBoxTypes(of url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        var types: [String] = []
        while offset + 8 <= fileSize, types.count < boxScanLimit {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            let size32 = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var size = size32
            if size32 == 1 {
                guard bytes.count >= 16 else { break }
                size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= 8 else { break }
            types.append(String(decoding: bytes[4..<8], as: UTF8.self))
            offset += size
        }
        return types
    }

    enum SpikeError: LocalizedError {
        case probeExited(Int32)
        case probeOutput(String)
        case frameDecode(String)
        case audioDecode(String)

        var errorDescription: String? {
            switch self {
            case .probeExited(let status): "ffprobe exited with status \(status)."
            case .probeOutput(let detail): "Could not read ffprobe output: \(detail)."
            case .frameDecode(let detail): "Could not decode a frame of the export: \(detail)."
            case .audioDecode(let detail): "Could not decode the export's audio: \(detail)."
            }
        }
    }

    // MARK: - ffprobe

    /// What ffprobe reports about the streams.
    private struct Probe {
        struct AudioTrack {
            var codec: String
            var sampleRate: Int
            var channels: Int
            var bitRate: Int?
            var duration: Double
        }

        var codec: String
        var codecTag: String
        var profile: String
        var width: Int
        var height: Int
        var realFrameRate: String
        var averageFrameRate: String
        var frameCount: Int
        var bFrames: Int
        var bitRate: Int?
        var videoStartTime: Double
        var videoDuration: Double
        /// Every video packet's presentation time, sorted: decode order
        /// differs from it once frames are reordered.
        var presentationTimes: [Double]
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
                var profile: String?
                var width: Int?
                var height: Int?
                var realFrameRate: String?
                var averageFrameRate: String?
                var frameCount: String?
                var bFrames: Int?
                var bitRate: String?
                var sampleRate: String?
                var channels: Int?
                var startTime: String?
                var duration: String?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case codecTag = "codec_tag_string"
                    case profile
                    case width
                    case height
                    case realFrameRate = "r_frame_rate"
                    case averageFrameRate = "avg_frame_rate"
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
                "stream=codec_name,codec_tag_string,profile,width,height,r_frame_rate,avg_frame_rate,nb_frames,"
                + "has_b_frames,bit_rate,sample_rate,channels,start_time,duration"
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
            var presentationTimes: [Double] = []
            var keyframeTimes: [Double] = []
            for line in packets.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 2, let time = Double(fields[0]) else { continue }
                presentationTimes.append(time)
                if fields[1].contains("K") { keyframeTimes.append(time) }
            }
            return Probe(
                codec: stream.codecName, codecTag: stream.codecTag ?? "", profile: stream.profile ?? "",
                width: stream.width ?? 0, height: stream.height ?? 0, realFrameRate: stream.realFrameRate ?? "",
                averageFrameRate: stream.averageFrameRate ?? "", frameCount: stream.frameCount.flatMap(Int.init) ?? 0,
                bFrames: stream.bFrames ?? 0, bitRate: stream.bitRate.flatMap(Int.init),
                videoStartTime: stream.startTime.flatMap(Double.init) ?? 0,
                videoDuration: stream.duration.flatMap(Double.init) ?? 0, presentationTimes: presentationTimes.sorted(),
                keyframeTimes: keyframeTimes.sorted(),
                audioTracks: audio.map {
                    AudioTrack(
                        codec: $0.codecName, sampleRate: $0.sampleRate.flatMap(Int.init) ?? 0,
                        channels: $0.channels ?? 0, bitRate: $0.bitRate.flatMap(Int.init),
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
