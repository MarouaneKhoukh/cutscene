import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCapture
import CutsceneCore
import Foundation
import ScreenCaptureKit
import Synchronization

/// Spike S1, the live `CaptureSession` on a real `SCStream` (PLAN M1-09,
/// ARCHITECTURE §9.1).
///
/// `session [seconds]` records the main display with system audio and the
/// default microphone into a temporary `.cutscene` package through
/// `CaptureSession`, prints the frame counts (content, idle, holds, gaps),
/// the encoder, writer, telemetry and heartbeat statistics, the stream clock
/// against the host clock and the first frame's buffer attachments (from
/// `recording/capture-debug.json`), checks the package (manifest, project,
/// frame index, event log, one sprite per cursor shape) and probes
/// `screen.mp4` with ffprobe: `hvc1`, no B-frames, keyframes at most 2 s
/// apart, one AAC track per source, every track ending with the video, and
/// `moov` before `mdat`. Then it times the load and zero-tolerance seeks of
/// the movie, which `--long N` turns into the pass/fail numbers of §9.1.
///
/// `--crash` spawns this binary recording 10 s into a package, sends it
/// `SIGKILL` 5 s after the stream started and recovers what the kill left
/// through `RecoveryScanner` (the app's own launch-time path): the
/// fragmented movie finalized, the log rebuilt from the telemetry sidecar,
/// the torn frame index repaired, a `recovered` manifest, then ffprobe.
/// `--crash-synthetic` runs the same harness on the `package` spike, which
/// needs no permission, so the harness is verified anywhere.
/// `--pause` records with the clock, encoder and writer on a live stream and
/// pauses the clock for 2 s halfway: the buffers captured in the pause must
/// vanish, the first frame after it must be a keyframe, and the audio must
/// join without a hole or an overlap, with every track ending on the
/// recorded duration. `--fill-disk` (PLAN M2-07) records onto a 600 MB APFS
/// disk image made with `hdiutil` and fills it 3 s in: the disk guard must
/// end the take with `diskFull` within one poll, with a complete manifest
/// and a playable `screen.mp4` finalized into the reserve; the image is
/// detached afterwards. `--inspect <package>` and `--recover <package>` run
/// the checks on an existing package without recording.
///
/// Every live mode preflights Screen Recording (and the microphone unless
/// `--no-mic`) and exits 3 when the grant is missing, before any
/// ScreenCaptureKit call; nothing here prompts.
enum SessionSpike {
    static let defaultSeconds = 10.0
    /// Under this the quiet tail and the pause would leave no recording.
    static let minimumSeconds = 2.0
    /// What the crash child records and when the parent kills it, measured
    /// from the moment the child reports its stream started (PLAN M1-09).
    static let crashRecordSeconds = 10.0
    static let crashKillAfterSeconds = 5.0
    /// The child's telemetry flush interval. The production default is 5 s,
    /// which would race the 5 s kill for the first flush; recovery needs
    /// the header and sidecar on disk, so the child flushes every 2 s.
    static let crashPersistenceInterval = 2.0
    /// The movie's fragments are flushed every 2 s on internal storage, so
    /// a kill at 5 s leaves at least this much playable video.
    static let crashMinimumRecoveredSeconds = 1.0
    /// How long the parent waits for the child to report its stream.
    static let childStartTimeout = 60.0
    static let childPollInterval = 0.05
    /// The pause in `--pause`, halfway through the recorded seconds.
    static let pauseLength = 2.0
    /// Slack on the recorded duration against wall time minus the pause:
    /// two timer wake-ups and the stop's own latency.
    static let pauseElapsedTolerance = 0.05
    /// Audio buffers of either source that may land in or out of the pause
    /// beyond the exact count: the buffer straddling each edge, plus one.
    static let pauseOutsideBufferTolerance = 3
    /// Seconds ScreenCaptureKit's audio buffers span: 1024 frames at 48 kHz.
    static let audioBufferSeconds = 1024.0 / 48_000
    /// For the last seconds of a long enough take the spike prints nothing,
    /// so a still screen (holds, the 2 s keyframe cap) is on the test even
    /// when the terminal is on the recorded display.
    static let quietTailSeconds = 4.0
    static let quietTailMinimumSeconds = 8.0
    /// Progress lines per take, whatever its length.
    static let progressLines = 20
    /// Slack on the keyframe distance beyond the encoder's duration cap plus
    /// one frame interval (the cap can only act on the next frame).
    static let keyframeSlack = 0.05
    /// How close a keyframe must sit to the first frame after a resume.
    static let keyframeMatchTolerance = 0.02
    /// The video track ends on the clock's stop through the end marker; one
    /// frame interval covers the stamp's rounding (PLAN: ± 1 frame).
    static let frameCountTolerance = 1
    /// An audio buffer that starts before the stop is written whole, so a
    /// track may end up to one buffer after the video.
    static let audioEndSlack = audioBufferSeconds
    /// Load and seek bounds (ARCHITECTURE §5, §9.1), enforced by `--long`.
    static let maximumLoadSeconds = 1.0
    static let maximumSeekSeconds = 0.150
    static let seekSamples = 12
    static let playerReadyTimeout = 15.0
    static let playerPollInterval = 0.01
    /// How long a seek may take to produce its frame before it counts as
    /// missing; far above the bound, so a stall shows as a number, not a hang.
    static let seekFrameTimeout = 5.0
    static let seekPollInterval = 0.001
    /// Longest string printed from the attachments dump before it is cut.
    static let maximumPrintedValueLength = 96
    /// The disk image `--fill-disk` records onto: small enough to fill in
    /// a second, large enough for the 300 MB floor, the take and the
    /// finalize beside it.
    static let fillDiskImageMegabytes = 600
    static let fillDiskVolumeName = "CutsceneFillDisk"
    /// The session's preflight minimum for that volume; the 2 GB default
    /// would refuse the 600 MB image before anything was written.
    static let fillDiskPreflightBytes: Int64 = 100_000_000
    /// Recording seconds after which the filler is written, so the movie
    /// holds a few seconds before the guard stops the take.
    static let fillDiskAt = 3.0
    /// How far under the floor the filler pulls the free space: enough that
    /// the guard's next reading is unambiguously `full`, little enough that
    /// the finalize still has its reserve.
    static let fillDiskOvershootBytes: Int64 = 20_000_000
    /// Chunk the filler is written in.
    static let fillDiskChunkBytes = 8 << 20
    /// Slack on the stop against the filler's end plus one poll: the stream
    /// stop and the status cadence.
    static let fillDiskStopSlack = 1.0
    /// How long the guard gets to end the take once the volume is full.
    static let fillDiskStopTimeout = 20.0

    // MARK: - Arguments

    private enum Mode {
        case live(seconds: Double)
        case long(seconds: Double)
        case pause(seconds: Double)
        /// Record onto a small disk image and fill it under the take, so
        /// the disk guard ends the take with `diskFull`.
        case fillDisk(seconds: Double)
        case crash(synthetic: Bool)
        /// The crash harness's child: record into `package`.
        case child(seconds: Double, package: URL)
        case inspect(URL)
        case recover(URL)
    }

    private struct Options {
        var mode = Mode.live(seconds: defaultSeconds)
        var seconds = defaultSeconds
        var microphoneID: String?
        var usesMicrophone = true
        var outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutscene-spike", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
    }

    private static let usage = """
        usage: session [seconds] [--long N | --pause | --fill-disk | --crash | --crash-synthetic |
                       --inspect <package> | --recover <package>] [--mic <uniqueID> | --no-mic] [--out <dir>]
                       [--package <path>]
        """

    private static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var childPackage: URL?
        var index = 0
        func value(after flag: String) -> String? {
            guard index + 1 < arguments.count else {
                print("\(flag) needs a value")
                return nil
            }
            index += 2
            return arguments[index - 1]
        }
        func seconds(_ text: String, for flag: String) -> Double? {
            guard let value = Double(text), value >= minimumSeconds else {
                print("\(flag) expects a duration in seconds of at least \(Int(minimumSeconds)), not \(text)")
                return nil
            }
            return value
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--long":
                guard let text = value(after: argument), let value = seconds(text, for: argument) else { return nil }
                options.seconds = value
                options.mode = .long(seconds: value)
            case "--pause":
                options.mode = .pause(seconds: options.seconds)
                index += 1
            case "--fill-disk":
                options.mode = .fillDisk(seconds: options.seconds)
                index += 1
            case "--crash":
                options.mode = .crash(synthetic: false)
                index += 1
            case "--crash-synthetic":
                options.mode = .crash(synthetic: true)
                index += 1
            case "--inspect":
                guard let path = value(after: argument) else { return nil }
                options.mode = .inspect(URL(fileURLWithPath: path))
            case "--recover":
                guard let path = value(after: argument) else { return nil }
                options.mode = .recover(URL(fileURLWithPath: path))
            case "--mic":
                guard let id = value(after: argument) else { return nil }
                options.microphoneID = id
            case "--no-mic":
                options.usesMicrophone = false
                index += 1
            case "--out":
                guard let path = value(after: argument) else { return nil }
                options.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            case "--package":
                guard let path = value(after: argument) else { return nil }
                childPackage = URL(fileURLWithPath: path)
            default:
                guard let value = seconds(argument, for: "session") else {
                    print(usage)
                    return nil
                }
                options.seconds = value
                switch options.mode {
                case .live: options.mode = .live(seconds: value)
                case .pause: options.mode = .pause(seconds: value)
                case .fillDisk: options.mode = .fillDisk(seconds: value)
                default: break
                }
                index += 1
            }
        }
        if let childPackage {
            options.mode = .child(seconds: options.seconds, package: childPackage)
        }
        return options
    }

    // MARK: - Entry

    static func run(arguments: [String]) async -> Bool {
        guard let options = parse(arguments) else { return false }
        do {
            switch options.mode {
            case .inspect(let url):
                let package = try RecordingPackage.open(at: url)
                print("session spike: inspecting \(package.url.path)")
                var failures = try await analyze(package: package, statistics: nil, expectDebugFacts: false)
                failures += try await measureLoadAndSeeks(movieURL: package.screenMovieURL, enforce: false)
                return report(failures)
            case .recover(let url):
                let package = try RecordingPackage.open(at: url)
                print("session spike: recovering \(package.url.path)")
                return report(try await recover(package: package))
            case .crash(let synthetic):
                return report(try await crashRun(options: options, synthetic: synthetic))
            case .live, .long, .pause, .fillDisk, .child:
                return try await liveModes(options: options)
            }
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    /// The modes that touch the screen: preflight first, exit 3 without the
    /// grant, then the stream.
    private static func liveModes(options: Options) async throws -> Bool {
        // The relaunch baseline, as the app takes it at launch.
        let permissions = Permissions()
        let screen = permissions.preflight(.screenRecording)
        guard screen == .granted else {
            print(
                "skipped: Screen Recording not granted to this terminal (\(screen.rawValue)). Grant it to the "
                    + "terminal application under System Settings > Privacy & Security > Screen & System Audio "
                    + "Recording (\(Capability.screenRecording.settingsURL)), relaunch the terminal and run again.")
            exit(3)
        }
        var microphone: AVCaptureDevice?
        if options.usesMicrophone {
            let state = permissions.preflight(.microphone)
            guard state == .granted else {
                print(
                    "skipped: Microphone not granted to this terminal (\(state.rawValue)). Grant it under System "
                        + "Settings > Privacy & Security > Microphone (\(Capability.microphone.settingsURL)), or "
                        + "pass --no-mic to record without the microphone track.")
                exit(3)
            }
            guard let device = try resolveMicrophone(id: options.microphoneID) else { return false }
            microphone = device
        }
        let inputMonitoring = permissions.preflight(.inputMonitoring)
        print(
            "session spike: Screen Recording granted; microphone "
                + (microphone.map { "\"\($0.localizedName)\" (\($0.uniqueID), \(channelCount(of: $0)) ch)" } ?? "off")
                + "; Input Monitoring \(inputMonitoring.rawValue) (tap "
                + (inputMonitoring == .granted ? "on" : "off, clicks from the monitors and the poll") + ")")
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        switch options.mode {
        case .pause(let seconds):
            return report(
                try await pauseRun(
                    seconds: seconds, microphone: microphone, permissions: permissions,
                    outputDirectory: options.outputDirectory))
        case .fillDisk:
            return report(
                try await fillDiskRun(
                    microphone: microphone, permissions: permissions, outputDirectory: options.outputDirectory))
        case .child(let seconds, let packageURL):
            let request = try await displayRequest(microphone: microphone, permissions: permissions)
            var settings = CaptureSessionSettings()
            settings.telemetryPersistenceInterval = crashPersistenceInterval
            let package = RecordingPackage(url: packageURL)
            _ = try await record(seconds: seconds, request: request, package: package, settings: settings)
            // Reached only when the parent failed to kill this process.
            print("the crash child was not killed and finished its take")
            return false
        case .live(let seconds), .long(let seconds):
            let request = try await displayRequest(microphone: microphone, permissions: permissions)
            let package = RecordingPackage(
                url: RecordingPackage.availableURL(
                    for: RecordingPackage.url(createdAt: Date(), source: .display, in: options.outputDirectory)))
            let result = try await record(
                seconds: seconds, request: request, package: package, settings: CaptureSessionSettings())
            var failures = try await analyze(package: package, statistics: result.statistics, expectDebugFacts: true)
            failures += checkTake(result, seconds: seconds)
            let isLong: Bool
            if case .long = options.mode { isLong = true } else { isLong = false }
            failures += try await measureLoadAndSeeks(movieURL: package.screenMovieURL, enforce: isLong)
            return report(failures)
        case .crash, .inspect, .recover:
            return false
        }
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    // MARK: - Microphone

    /// The requested microphone, or the system default input. Listing and
    /// opening devices never prompts; only capturing from one does, and the
    /// grant was checked first.
    private static func resolveMicrophone(id: String?) throws -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        for device in devices {
            print("  microphone: \"\(device.localizedName)\" id \(device.uniqueID), \(channelCount(of: device)) ch")
        }
        if let id {
            guard let device = AVCaptureDevice(uniqueID: id) else {
                print("no microphone has the identifier \(id); the ids are listed above")
                return nil
            }
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            print("no default microphone; pass --mic <uniqueID> or --no-mic")
            return nil
        }
        return device
    }

    /// Channels of the device's active format, which is what its track gets.
    private static func channelCount(of device: AVCaptureDevice) -> Int {
        max(1, Int(device.activeFormat.formatDescription.audioStreamBasicDescription?.mChannelsPerFrame ?? 1))
    }

    /// The M1 request: the main display, system audio and the microphone.
    private static func displayRequest(microphone: AVCaptureDevice?, permissions: Permissions) async throws
        -> CaptureRequest
    {
        let content = try await ShareableContent.current(permissions: permissions)
        guard let display = content.mainDisplay else { throw SpikeError.noDisplay }
        print(
            "display \(display.displayID): \(display.width)×\(display.height) pt"
                + (content.displays.count > 1 ? " (of \(content.displays.count))" : ""))
        return CaptureRequest(
            source: .display(display.displayID), microphoneID: microphone?.uniqueID, systemAudio: true)
    }

    // MARK: - The live take

    private struct LiveResult: Sendable {
        var manifest: RecordingManifest
        var statistics: CaptureStatistics
        /// Wall seconds from `start` returning to `stop` returning.
        var wallSeconds: Double
        var stopSeconds: Double
    }

    /// Records `seconds` through a `CaptureSession`, printing a progress
    /// line every `seconds / progressLines` and nothing during the quiet
    /// tail, and returns the manifest and the final counters.
    private static func record(
        seconds: Double, request: CaptureRequest, package: RecordingPackage, settings: CaptureSessionSettings
    ) async throws -> LiveResult {
        let session = CaptureSession(settings: settings, permissions: Permissions())
        let statuses = try await session.start(request: request, package: package)
        // The crash harness waits for this line; flushed because a pipe is
        // fully buffered and the kill would otherwise come before it.
        print("recording: \(package.url.path)")
        fflush(nil)
        let quietFrom = seconds >= quietTailMinimumSeconds ? seconds - quietTailSeconds : seconds
        let interval = max(1, (seconds / Double(progressLines)).rounded())
        print(
            "GO: \(format(seconds)) s of \(request.source.modeName); talk, move the pointer, click, scroll, "
                + "open a menu" + (quietFrom < seconds ? "; keep the screen still from \(format(quietFrom)) s" : ""))
        let last = Mutex<CaptureStatus?>(nil)
        let printer = Task {
            var nextLine = 0.0
            for await status in statuses {
                last.withLock { $0 = status }
                switch status.phase {
                case .recording:
                    guard status.elapsedSeconds >= nextLine, status.elapsedSeconds < quietFrom else { continue }
                    nextLine += interval
                    print("  " + progressLine(status))
                case .finishing:
                    print("  finishing at \(format(status.elapsedSeconds)) s")
                case .finished(let reason):
                    print("  finished: \(reason.rawValue)")
                case .failed(let reason, let message):
                    print("  failed: \(reason.rawValue), \(message)")
                }
            }
        }
        let started = ContinuousClock.now
        try await Task.sleep(for: .seconds(seconds))
        let stopStarted = ContinuousClock.now
        let manifest = try await session.stop()
        let stopSeconds = elapsed(since: stopStarted)
        let wallSeconds = elapsed(since: started)
        await printer.value
        let statistics = await session.statistics
        print(
            "stopped: \(format(manifest.duration ?? 0)) s recorded, \(manifest.state.rawValue) "
                + "(\(manifest.stopReason?.rawValue ?? "no reason")); stop took \(milliseconds(stopSeconds)); "
                + "package \(package.url.path)")
        return LiveResult(
            manifest: manifest, statistics: statistics, wallSeconds: wallSeconds, stopSeconds: stopSeconds)
    }

    // MARK: - Disk full

    /// M2-07's acceptance: a take onto a 600 MB APFS disk image whose free
    /// space is pulled under the guard's floor by a filler file written at
    /// `fillDiskAt` seconds. The guard's next reading ends the take with
    /// `diskFull`; the movie must still finalize into the reserve the floor
    /// kept, so the package is analyzed and probed like a stopped take, and
    /// the stop must land within one poll of the filler.
    private static func fillDiskRun(microphone: AVCaptureDevice?, permissions: Permissions, outputDirectory: URL)
        async throws -> [String]
    {
        let image = outputDirectory.appendingPathComponent("\(fillDiskVolumeName)-\(UUID().uuidString).dmg")
        let mount = try attachDiskImage(at: image, megabytes: fillDiskImageMegabytes)
        defer { detachDiskImage(mount: mount, image: image) }
        var failures: [String] = []
        let request = try await displayRequest(microphone: microphone, permissions: permissions)
        var settings = CaptureSessionSettings()
        settings.minimumFreeBytes = fillDiskPreflightBytes
        let package = RecordingPackage(
            url: RecordingPackage.availableURL(
                for: RecordingPackage.url(createdAt: Date(), source: .display, in: mount)))
        let freeAtStart = DiskSpaceMonitor.freeBytes(at: mount) ?? 0
        print(
            "fill-disk: image \(image.lastPathComponent) mounted at \(mount.path), \(freeAtStart / 1_000_000) MB free; "
                + "floor \(settings.disk.autoStopBytes / 1_000_000) MB + \(settings.disk.finalizeReserveFactor)× the take, "
                + "poll \(format(settings.disk.pollInterval)) s; filler at \(format(fillDiskAt)) s")

        let session = CaptureSession(settings: settings, permissions: Permissions())
        let statuses = try await session.start(request: request, package: package)
        let started = ContinuousClock.now
        print("recording: \(package.url.path)")
        let last = Mutex<CaptureStatus?>(nil)
        let printer = Task {
            for await status in statuses {
                last.withLock { $0 = status }
                switch status.phase {
                case .recording:
                    if let disk = status.statistics.disk {
                        print(
                            "  t=\(format(status.elapsedSeconds)) s  free \(disk.freeBytes.map { $0 / 1_000_000 } ?? -1) MB, "
                                + "written \(disk.bytesWritten / 1_000_000) MB, floor \(disk.floorBytes / 1_000_000) MB, "
                                + "level \(disk.level.rawValue), frames \(status.statistics.frames.contentFrames) content"
                        )
                    }
                case .finishing:
                    print("  finishing at \(format(status.elapsedSeconds)) s")
                case .finished(let reason):
                    print("  finished: \(reason.rawValue) at \(format(status.elapsedSeconds)) s")
                case .failed(let reason, let message):
                    print("  failed: \(reason.rawValue), \(message)")
                }
            }
        }

        try await Task.sleep(for: .seconds(fillDiskAt))
        // Under the floor by the overshoot, against the take's size now;
        // the floor rises with what the take writes meanwhile, which only
        // makes the next reading more surely `full`.
        let free = DiskSpaceMonitor.freeBytes(at: mount) ?? 0
        let written = DiskSpaceMonitor.allocatedBytes(under: package.url)
        let floor = settings.disk.autoStopBytes + Int64(Double(written) * settings.disk.finalizeReserveFactor)
        let fillerBytes = max(free - floor + fillDiskOvershootBytes, 0)
        let filler = mount.appendingPathComponent("filler.bin")
        try writeFiller(at: filler, bytes: fillerBytes)
        let filledAt = elapsed(since: started)
        print(
            "  filler: \(fillerBytes / 1_000_000) MB written at \(format(filledAt)) s (free was \(free / 1_000_000) MB, "
                + "floor \(floor / 1_000_000) MB, now \((DiskSpaceMonitor.freeBytes(at: mount) ?? 0) / 1_000_000) MB)")

        // The guard ends the take; the stream ends with it.
        let deadline = ContinuousClock.now + .seconds(fillDiskStopTimeout)
        while ContinuousClock.now < deadline {
            if let status = last.withLock({ $0 }) {
                if case .finished = status.phase { break }
                if case .failed = status.phase { break }
            }
            try await Task.sleep(for: .seconds(childPollInterval))
        }
        let stopStarted = ContinuousClock.now
        let manifest = try await session.stop()
        let stopSeconds = elapsed(since: stopStarted)
        await printer.value
        let statistics = await session.statistics
        print(
            "stopped: \(format(manifest.duration ?? 0)) s recorded, \(manifest.state.rawValue) "
                + "(\(manifest.stopReason?.rawValue ?? "no reason")); stop() returned in \(milliseconds(stopSeconds)); "
                + "free now \((DiskSpaceMonitor.freeBytes(at: mount) ?? 0) / 1_000_000) MB")
        try? FileManager.default.removeItem(at: filler)

        guard let final = last.withLock({ $0 }) else {
            failures.append("the status stream yielded nothing")
            return failures
        }
        if final.phase != .finished(.diskFull) { failures.append("the status stream ended in \(final.phase)") }
        if manifest.state != .complete { failures.append("manifest state \(manifest.state.rawValue)") }
        if manifest.stopReason != .diskFull {
            failures.append("stop reason \(manifest.stopReason?.rawValue ?? "none")")
        }
        if let duration = manifest.duration {
            let latest = filledAt + settings.disk.pollInterval + fillDiskStopSlack
            if duration < fillDiskAt - fillDiskStopSlack || duration > latest {
                failures.append(
                    "the take stopped at \(format(duration)) s; the filler landed at \(format(filledAt)) s and the "
                        + "guard polls every \(format(settings.disk.pollInterval)) s")
            }
        }
        if !FileManager.default.fileExists(atPath: package.screenMovieURL.path) {
            failures.append("no screen.mp4")
        }
        if FileManager.default.fileExists(atPath: RecordingWriter.markerURL(for: package.screenFragmentedMovieURL).path)
        {
            failures.append("the needsFinalize marker is still there")
        }
        if statistics.frames.contentFrames == 0 { failures.append("no content frame arrived") }
        failures += try await analyze(package: package, statistics: statistics, expectDebugFacts: true)
        return failures
    }

    /// Makes and mounts an APFS disk image of `megabytes`, hidden from the
    /// Finder; returns the mount point. Needs no permission.
    private static func attachDiskImage(at image: URL, megabytes: Int) throws -> URL {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        _ = try toolOutput(
            of: hdiutil,
            [
                "create", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", fillDiskVolumeName, "-quiet",
                image.path,
            ])
        let plist = try toolOutput(of: hdiutil, ["attach", "-plist", "-nobrowse", image.path])
        guard
            let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)
                as? [String: Any], let entities = parsed["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw SpikeError.diskImage("hdiutil attach reported no mount point") }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    private static func detachDiskImage(mount: URL, image: URL) {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        do {
            _ = try toolOutput(of: hdiutil, ["detach", "-force", "-quiet", mount.path])
            try FileManager.default.removeItem(at: image)
            print("fill-disk: detached \(mount.path) and removed the image")
        } catch {
            print("note: the disk image at \(image.path) could not be detached: \(error.localizedDescription)")
        }
    }

    /// Writes `bytes` of zeros to `url` in chunks.
    private static func writeFiller(at url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(count: fillDiskChunkBytes)
        var remaining = bytes
        while remaining > 0 {
            let count = Int(min(Int64(chunk.count), remaining))
            try handle.write(contentsOf: count == chunk.count ? chunk : chunk.prefix(count))
            remaining -= Int64(count)
        }
        try handle.synchronize()
    }

    private static func toolOutput(of executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SpikeError.diskImage(
                "\(executable.lastPathComponent) exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func progressLine(_ status: CaptureStatus) -> String {
        let s = status.statistics
        return
            "t=\(format(status.elapsedSeconds)) s  frames \(s.frames.contentFrames) content / \(s.frames.idleFrames) "
            + "idle / \(s.frames.holds) holds / \(s.frames.gaps) gaps  encoder \(s.encoder.encodedFrames) encoded, "
            + "\(s.encoder.droppedFrames) dropped  writer \(s.writer.videoFrames) video, \(s.writer.audioBuffers) "
            + "audio  events \(s.telemetry.samplerTicks) ticks  free \(gigabytes(s.freeDiskBytes))"
    }

    /// What the take itself must satisfy, beyond the files.
    private static func checkTake(_ result: LiveResult, seconds: Double) -> [String] {
        var failures: [String] = []
        let s = result.statistics
        if result.manifest.state != .complete { failures.append("manifest state \(result.manifest.state.rawValue)") }
        if result.manifest.stopReason != .userStopped {
            failures.append("stop reason \(result.manifest.stopReason?.rawValue ?? "none")")
        }
        if let duration = result.manifest.duration, abs(duration - seconds) > pauseElapsedTolerance + 0.5 {
            failures.append("recorded \(format(duration)) s for a \(format(seconds)) s take")
        }
        if let status = s.encoder.lastErrorStatus, status != noErr {
            failures.append("encoder error \(status)")
        }
        if s.writer.videoDroppedBeforeKeyframe + s.writer.videoDroppedNonIncreasing > 0 {
            failures.append("writer refused video (before keyframe / non-increasing)")
        }
        if s.writer.videoDroppedNotReady != s.frames.gaps {
            failures.append("\(s.writer.videoDroppedNotReady) frames dropped not ready but \(s.frames.gaps) gap lines")
        }
        if s.frames.contentFrames == 0 { failures.append("no content frame arrived") }
        if s.frames.writeFailures > 0 {
            failures.append("frame index write failures: \(s.frames.lastWriteError ?? "")")
        }
        if s.telemetry.persistenceFailures > 0 {
            failures.append("telemetry persistence failed: \(s.telemetry.lastPersistenceError ?? "")")
        }
        if s.holdsSkipped > 0 { failures.append("\(s.holdsSkipped) heartbeat holds skipped") }
        return failures
    }

    // MARK: - Analysis of a complete package

    /// Prints what the package holds and returns what is wrong with it.
    /// `statistics` are the session's counters for a take this process
    /// made; nil for a package opened from disk.
    private static func analyze(package: RecordingPackage, statistics: CaptureStatistics?, expectDebugFacts: Bool)
        async throws -> [String]
    {
        var failures: [String] = []
        let manifest = try package.manifest()
        print(
            "manifest: \(manifest.state.rawValue), \(manifest.stopReason?.rawValue ?? "no stop reason"), "
                + "\(format(manifest.duration ?? 0)) s, \(manifest.screen.width)×\(manifest.screen.height) "
                + "\(manifest.screen.codec) @ \(manifest.screen.frameRate) fps, audio "
                + manifest.screen.audioTracks.map { "\($0.source.rawValue) ×\($0.channelCount)" }
                .joined(separator: ", ") + "; capture \(format(manifest.content.captureRectPoints.width))×"
                + "\(format(manifest.content.captureRectPoints.height)) pt at \(manifest.content.pointPixelScale)×")
        if let statistics { printCounters(statistics) }

        // Clock and colour facts.
        let debugURL = package.recordingDirectory.appendingPathComponent(CaptureSessionSettings().debugFileName)
        if let data = try? Data(contentsOf: debugURL), let facts = try? JSONValue(jsonData: data) {
            printDebugFacts(facts)
        } else if expectDebugFacts {
            failures.append("no \(debugURL.lastPathComponent) (no content frame reached the session?)")
        } else {
            print("capture-debug.json: none (not a live take)")
        }

        // Frame index. The index implies the movie's frame count (content
        // frames plus holds minus gaps); frames VideoToolbox dropped are
        // known to the session only.
        let index = try package.frameIndex()
        var statuses: [String: Int] = [:]
        for case .frame(let entry) in index.lines {
            statuses[entry.status.rawValue, default: 0] += 1
        }
        let encoderDropped = statistics?.encoder.droppedFrames ?? 0
        let expectedFrames = index.expectedMovieFrameCount - encoderDropped
        print(
            "frames.jsonl: \(index.lines.count) lines, \(statuses.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")), "
                + "\(index.holdTimes.count) holds, \(index.gapTimes.count) gaps"
                + (index.truncatedAtLine.map { ", torn at line \($0)" } ?? "")
                + "; movie frames expected \(expectedFrames)"
                + (encoderDropped > 0
                    ? " (\(index.expectedMovieFrameCount) less \(encoderDropped) the encoder dropped)" : ""))
        if index.truncatedAtLine != nil { failures.append("frames.jsonl is torn") }

        // Event log and sprites.
        let log = try package.eventLog()
        var kinds: [String: Int] = [:]
        var shapeIDs: [String] = []
        for event in log.events {
            kinds[kind(of: event), default: 0] += 1
            if case .cursorShapeChanged(_, let shape) = event, !shapeIDs.contains(shape.id) {
                shapeIDs.append(shape.id)
            }
        }
        print(
            "events.json: \(log.events.count) events, "
                + kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                + "; cursor shapes \(shapeIDs)")
        let spriteFiles =
            (try? FileManager.default.contentsOfDirectory(atPath: package.cursorsDirectory.path))?
            .filter { $0.hasSuffix(".png") } ?? []
        let missingSprites = shapeIDs.filter {
            let url = package.cursorSpriteURL(shapeID: $0)
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0) == 0
        }
        print("cursors/: \(spriteFiles.count) PNGs\(missingSprites.isEmpty ? "" : ", missing \(missingSprites)")")
        if !missingSprites.isEmpty { failures.append("no sprite for cursor shapes \(missingSprites)") }
        if shapeIDs.isEmpty { failures.append("no cursorShapeChanged event") }
        if let last = log.events.last, let duration = manifest.duration, last.time > duration + 0.05 {
            failures.append("an event at \(format(last.time)) s lies after the \(format(duration)) s take")
        }

        // Project and leftovers.
        do {
            let project = try ProjectStore(package: package).load()
            print("project.json: format \(project.formatVersion), recording \(project.recording.state.rawValue)")
            if project.recording.state != manifest.state { failures.append("project.json carries another state") }
        } catch {
            // A session writes project.json through ProjectStore, so for a
            // live take this is a failure; a package from another writer
            // (the package spike's hand-rolled tree) is only reported.
            if statistics != nil {
                failures.append("project.json: \(error.localizedDescription)")
            } else {
                print("note: project.json does not load as Project: \(error)")
            }
        }
        let leftovers = [
            package.screenFragmentedMovieURL, RecordingWriter.markerURL(for: package.screenFragmentedMovieURL),
            package.eventsSidecarURL,
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !leftovers.isEmpty { failures.append("leftovers \(leftovers.map(\.lastPathComponent))") }

        failures += try probeMovie(
            package.screenMovieURL, manifest: manifest, expectedFrames: expectedFrames,
            writerFrames: statistics?.writer.videoFrames, recordedSeconds: manifest.duration)
        return failures
    }

    private static func printCounters(_ s: CaptureStatistics) {
        print(
            "frames: \(s.frames.samples) samples, \(s.frames.contentFrames) content (\(s.frames.startedFrames) started), "
                + "\(s.frames.idleFrames) idle, \(s.frames.blankFrames) blank, \(s.frames.suspendedFrames) suspended, "
                + "\(s.frames.stoppedFrames) stopped, \(s.frames.otherFrames) other, \(s.frames.outsideRecording) outside; "
                + "\(s.frames.holds) holds, \(s.frames.gaps) gaps; first content at "
                + "\(s.frames.firstContentTime.map(format) ?? "never") s, last at \(s.frames.lastContentTime.map(format) ?? "never") s"
        )
        print(
            "encoder: \(s.encoder.submittedFrames) submitted, \(s.encoder.encodedFrames) encoded, "
                + "\(s.encoder.droppedFrames) dropped, \(s.encoder.skippedOutsideRecording) outside, "
                + "\(s.encoder.droppedNonIncreasing) non-increasing, last error \(s.encoder.lastErrorStatus ?? 0)")
        print(
            "writer: \(s.writer.videoFrames) video frames (\(s.writer.videoDroppedNotReady) not ready, "
                + "\(s.writer.videoDroppedBeforeKeyframe) before keyframe, \(s.writer.videoDroppedNonIncreasing) "
                + "non-increasing); \(s.writer.audioBuffers) audio buffers, \(s.writer.audioDropped) dropped, "
                + "\(s.writer.audioOutsideRecording) outside, \(s.writer.audioGapsFilled) gaps filled with "
                + "\(format(s.writer.audioSilenceSeconds)) s silence, \(s.writer.audioOverlapsTrimmed) overlaps trimmed, "
                + "\(s.writer.audioEndPadded) end buffers padding \(format(s.writer.audioEndPaddingSeconds)) s to the stop"
                + (s.writer.failureDescription.map { "; FAILED: \($0)" } ?? ""))
        print(
            "heartbeat: \(s.holdsEncoded) holds encoded, \(s.holdsSkipped) skipped, \(s.holdCollisions) late frames "
                + "nudged past a hold; retained surface checked \(s.retainedSurfaceChecks)×, "
                + "\(s.retainedSurfaceMismatches) mismatches; source in use \(s.holdSourceInUse.rawValue), "
                + "\(s.copiedFrames) copies, \(s.copyFailures) copy failures")
        print(
            "clock: synchronizationClock is host clock "
                + (s.synchronizationClockIsHostClock.map { $0 ? "yes" : "NO" } ?? "unknown (none reported)")
                + ", \(s.sampleTimesConverted) sample times converted")
        let t = s.telemetry
        print(
            "telemetry: \(t.samplerTicks) ticks in \(format(t.activeSeconds)) s = "
                + "\(String(format: "%.1f", t.measuredSamplingRateHz)) Hz; tap \(t.eventTapActive ? "on" : "off"), "
                + "monitors \(t.clickMonitorsActive ? "on" : "off"); monitor buttons \(t.monitorButtonEvents), "
                + "poll edges \(t.pollEdgesDetected) (\(t.pollEdgesWritten) written); \(t.persistedWrites) flushes; "
                + "sprites written \(s.cursorSpritesWritten)")
        let g = s.geometry
        print(
            "geometry poll: \(g.ticks) ticks, \(g.events) events for \(g.windowsSeen) window(s), watched window missing "
                + "on \(g.watchedWindowMissing) ticks; focus events \(s.focusEvents)")
        for warning in s.warnings { print("  warning: \(warning)") }
    }

    /// The clock comparison and the attachments the session dumped from the
    /// first content frame (`capture-debug.json`).
    private static func printDebugFacts(_ facts: JSONValue) {
        if let stream = facts["stream"] {
            print(
                "stream clock: present \(stream["synchronizationClockPresent"]?.boolValue ?? false), host clock "
                    + "\(stream["synchronizationClockIsHostClock"]?.boolValue.map { $0 ? "yes" : "NO" } ?? "n/a"), "
                    + "might drift \(stream["synchronizationClockMightDrift"]?.boolValue ?? false), offset "
                    + "\(stream["synchronizationClockOffsetSeconds"]?.doubleValue.map(milliseconds) ?? "n/a"), "
                    + "samples converted \(stream["sampleTimesConvertedToHostClock"]?.boolValue ?? false)")
            if let configuration = stream["configuration"] {
                print("  configuration: \(oneLine(configuration))")
            }
        }
        if let frame = facts["firstScreenFrame"] {
            let pts = frame["presentationStreamSeconds"]?.doubleValue
            let host = frame["presentationHostSeconds"]?.doubleValue
            print(
                "first frame: status \(frame["status"]?.stringValue ?? "?"), SCK PTS \(pts.map(format) ?? "n/a") s, host "
                    + "\(host.map(format) ?? "n/a") s (PTS − host "
                    + (pts.flatMap { p in host.map { milliseconds(p - $0) } } ?? "n/a") + "), "
                    + "recording time \(frame["recordingTimeSeconds"]?.doubleValue.map(format) ?? "n/a") s, PTS − display "
                    + "\(frame["presentationMinusDisplaySeconds"]?.doubleValue.map(milliseconds) ?? "n/a"), delivery latency "
                    + "\(frame["deliveryLatencySeconds"]?.doubleValue.map(milliseconds) ?? "n/a"); contentRect "
                    + "\(frame["contentRect"].map(oneLine) ?? "n/a"), contentScale \(frame["contentScale"].map(oneLine) ?? "n/a"), "
                    + "scaleFactor \(frame["scaleFactor"].map(oneLine) ?? "n/a"), dirty rects "
                    + "\(frame["dirtyRectCount"].map(oneLine) ?? "n/a")")
        }
        if let buffer = facts["pixelBuffer"] {
            print(
                "first buffer: \(buffer["pixelFormat"]?.stringValue ?? "?") \(buffer["width"].map(oneLine) ?? "?")×"
                    + "\(buffer["height"].map(oneLine) ?? "?"), planes \(buffer["planeCount"].map(oneLine) ?? "?"), "
                    + "bytesPerRow \(buffer["bytesPerRow"].map(oneLine) ?? "?"), IOSurface "
                    + "\(buffer["isIOSurfaceBacked"]?.boolValue ?? false), media subtype "
                    + "\(buffer["formatDescriptionMediaSubType"]?.stringValue ?? "?")")
            for key in ["attachmentsShouldPropagate", "attachmentsShouldNotPropagate", "formatDescriptionExtensions"] {
                print("  \(key):")
                printTree(buffer[key] ?? .null, indent: "    ")
            }
        }
    }

    // MARK: - ffprobe

    /// Probes the finalized movie and returns what differs from the
    /// recording path's promises (ARCHITECTURE §2 "Video path").
    private static func probeMovie(
        _ movieURL: URL, manifest: RecordingManifest, expectedFrames: Int?, writerFrames: Int?,
        recordedSeconds: Double?, requiresMatchingEnds: Bool = true
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
        let codec = VideoEncoderConfiguration(
            width: manifest.screen.width, height: manifest.screen.height, frameRate: manifest.screen.frameRate)
        let maximumGap = codec.maxKeyFrameIntervalDuration + 1 / Double(manifest.screen.frameRate) + keyframeSlack
        print(
            "ffprobe: codec=\(probe.codec) tag=\(probe.codecTag) \(probe.width)×\(probe.height) nb_frames=\(probe.frameCount) "
                + "has_b_frames=\(probe.bFrames) bit_rate=\(probe.bitRate.map { "\($0 / 1000) kb/s" } ?? "n/a") "
                + "start=\(format(probe.videoStartTime)) s duration=\(format(probe.videoDuration)) s "
                + "end=\(format(probe.videoEnd)) s")
        print(
            "keyframes: \(probe.keyframeTimes.count), max gap \(format(probe.maximumKeyframeGap)) s (limit "
                + "\(format(maximumGap)) s), longest GOP \(probe.framesPerGOP.max() ?? 0) frames (limit "
                + "\(codec.maxKeyFrameInterval)); first at \(probe.keyframeTimes.prefix(6).map(format).joined(separator: " "))"
        )
        for track in probe.audioTracks {
            print(
                "audio: codec=\(track.codec) sample_rate=\(track.sampleRate) channels=\(track.channels) "
                    + "nb_frames=\(track.frameCount) start=\(format(track.startTime)) s duration=\(format(track.duration)) s "
                    + "end=\(format(track.end)) s (video − audio end \(milliseconds(probe.videoEnd - track.end)))")
        }

        let expectedTag = manifest.screen.codec == VideoCodec.hevc.rawValue ? "hvc1" : "avc1"
        if probe.codecTag != expectedTag { failures.append("codec tag \(probe.codecTag) is not \(expectedTag)") }
        if probe.bFrames != 0 { failures.append("has_b_frames=\(probe.bFrames)") }
        if probe.width != manifest.screen.width || probe.height != manifest.screen.height {
            failures.append("frame size \(probe.width)×\(probe.height) is not the manifest's")
        }
        if probe.keyframeTimes.isEmpty { failures.append("no keyframes") }
        if probe.maximumKeyframeGap > maximumGap {
            failures.append("keyframe gap \(format(probe.maximumKeyframeGap)) s > \(format(maximumGap)) s")
        }
        if let longest = probe.framesPerGOP.max(), longest > codec.maxKeyFrameInterval + frameCountTolerance {
            failures.append("a GOP of \(longest) frames exceeds \(codec.maxKeyFrameInterval)")
        }
        if let expectedFrames, abs(probe.frameCount - expectedFrames) > frameCountTolerance {
            failures.append("nb_frames=\(probe.frameCount), frames.jsonl implies \(expectedFrames)")
        }
        if let writerFrames, probe.frameCount != writerFrames {
            failures.append("nb_frames=\(probe.frameCount), the writer wrote \(writerFrames)")
        }
        let frameSeconds = 1 / Double(manifest.screen.frameRate)
        if let recordedSeconds, abs(probe.videoEnd - recordedSeconds) > frameSeconds {
            failures.append("video ends at \(format(probe.videoEnd)) s, recorded \(format(recordedSeconds)) s")
        }
        if probe.audioTracks.count != manifest.screen.audioTracks.count {
            failures.append(
                "\(probe.audioTracks.count) audio tracks, manifest lists \(manifest.screen.audioTracks.count)")
        }
        for (track, info) in zip(probe.audioTracks, manifest.screen.audioTracks) {
            if track.codec != "aac" || track.sampleRate != 48_000 || track.channels != info.channelCount {
                failures.append(
                    "\(info.source.rawValue) track is \(track.codec) \(track.sampleRate) Hz × \(track.channels), "
                        + "expected aac 48000 Hz × \(info.channelCount)")
            }
            let difference = track.end - probe.videoEnd
            if difference < -frameSeconds || difference > frameSeconds + audioEndSlack {
                let message =
                    "\(info.source.rawValue) track ends \(milliseconds(difference)) from the video "
                    + "(limit −1 frame … +1 frame + 1 buffer)"
                if requiresMatchingEnds {
                    failures.append(message)
                } else {
                    // A recovered movie holds each track up to its last
                    // flushed fragment, so the ends differ by design.
                    print("note: \(message)")
                }
            }
        }
        return failures
    }

    /// The four-character types of the file's top-level boxes, in order.
    static func topLevelBoxes(of url: URL) throws -> [String] {
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

    /// What ffprobe reports about the streams.
    private struct Probe {
        struct AudioTrack {
            var codec: String
            var sampleRate: Int
            var channels: Int
            var frameCount: Int
            var startTime: Double
            var duration: Double
            var end: Double { startTime + duration }
        }

        var codec: String
        var codecTag: String
        var width: Int
        var height: Int
        var frameCount: Int
        var bFrames: Int
        var bitRate: Int?
        var videoStartTime: Double
        var videoDuration: Double
        var keyframeTimes: [Double]
        var framesPerGOP: [Int]
        var audioTracks: [AudioTrack]

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
                "stream=codec_name,codec_tag_string,width,height,nb_frames,has_b_frames,bit_rate,sample_rate,channels,"
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
                codec: stream.codecName, codecTag: stream.codecTag ?? "", width: stream.width ?? 0,
                height: stream.height ?? 0, frameCount: stream.frameCount.flatMap(Int.init) ?? 0,
                bFrames: stream.bFrames ?? 0, bitRate: stream.bitRate.flatMap(Int.init),
                videoStartTime: stream.startTime.flatMap(Double.init) ?? 0,
                videoDuration: stream.duration.flatMap(Double.init) ?? 0, keyframeTimes: keyframeTimes.sorted(),
                framesPerGOP: framesPerGOP,
                audioTracks: audio.map {
                    AudioTrack(
                        codec: $0.codecName, sampleRate: $0.sampleRate.flatMap(Int.init) ?? 0,
                        channels: $0.channels ?? 0, frameCount: $0.frameCount.flatMap(Int.init) ?? 0,
                        startTime: $0.startTime.flatMap(Double.init) ?? 0,
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

    // MARK: - Load and seek

    /// Times the asset load, the player's readiness and zero-tolerance seeks
    /// through `AVPlayerItem` (the preview's path) and exact-time decodes
    /// through `AVAssetImageGenerator`. `enforce` applies the §9.1 bounds.
    private static func measureLoadAndSeeks(movieURL: URL, enforce: Bool) async throws -> [String] {
        var failures: [String] = []
        let asset = AVURLAsset(url: movieURL)
        var started = ContinuousClock.now
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        _ = try await asset.loadTracks(withMediaType: .video)
        let loadSeconds = elapsed(since: started)
        let item = AVPlayerItem(asset: asset)
        // Without a layer a player decodes nothing, and a seek would
        // "finish" at once; a video output makes it produce the frame, and
        // the seek is timed until that frame can be copied.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        // Seek timing only; the recording's audio must never reach the speakers
        // from an unattended spike.
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        started = ContinuousClock.now
        while item.status == .unknown, elapsed(since: started) < playerReadyTimeout {
            try await Task.sleep(for: .seconds(playerPollInterval))
        }
        let readySeconds = elapsed(since: started)
        print(
            "load: \(format(duration.seconds)) s movie, playable \(playable); asset loaded in \(milliseconds(loadSeconds)), "
                + "player \(item.status == .readyToPlay ? "ready" : "NOT ready (\(item.error?.localizedDescription ?? "status \(item.status.rawValue)"))") "
                + "after \(milliseconds(readySeconds)) (limit \(milliseconds(maximumLoadSeconds)))")
        guard item.status == .readyToPlay else {
            failures.append("the player item never became ready")
            return failures
        }

        // Evenly spaced targets, each pushed into its GOP by a fixed
        // fraction so the seek lands between keyframes rather than on them.
        let targets = (0..<seekSamples).map { index in
            duration.seconds * (Double(index) + 0.37) / Double(seekSamples)
        }
        var seekSeconds: [Double] = []
        var framesMissing = 0
        for target in targets {
            let time = CMTime(seconds: target, preferredTimescale: 1_000_000_000)
            started = ContinuousClock.now
            let finished = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if !finished { failures.append("the seek to \(format(target)) s was interrupted") }
            while !output.hasNewPixelBuffer(forItemTime: time), elapsed(since: started) < seekFrameTimeout {
                try await Task.sleep(for: .seconds(seekPollInterval))
            }
            if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) == nil { framesMissing += 1 }
            seekSeconds.append(elapsed(since: started))
        }
        if framesMissing > 0 {
            failures.append("\(framesMissing) seeks produced no frame within \(format(seekFrameTimeout)) s")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var decodeSeconds: [Double] = []
        var worstActualOffset = 0.0
        for target in targets {
            let time = CMTime(seconds: target, preferredTimescale: 1_000_000_000)
            started = ContinuousClock.now
            let result = try await generator.image(at: time)
            decodeSeconds.append(elapsed(since: started))
            worstActualOffset = max(worstActualOffset, abs(result.actualTime.seconds - target))
        }
        player.replaceCurrentItem(with: nil)
        let sortedSeeks = seekSeconds.sorted()
        let sortedDecodes = decodeSeconds.sorted()
        print(
            "seek: \(seekSamples) zero-tolerance player seeks, median \(milliseconds(median(sortedSeeks))), p95 "
                + "\(milliseconds(percentile(sortedSeeks, 0.95))), max \(milliseconds(sortedSeeks.last ?? 0)) (limit "
                + "\(milliseconds(maximumSeekSeconds)) median); exact-time decodes median "
                + "\(milliseconds(median(sortedDecodes))), max \(milliseconds(sortedDecodes.last ?? 0)); the frame on "
                + "screen at a requested time was up to \(milliseconds(worstActualOffset)) older (VFR: up to the "
                + "heartbeat on static content)")
        guard enforce else { return failures }
        if loadSeconds + readySeconds > maximumLoadSeconds {
            failures.append("load \(milliseconds(loadSeconds + readySeconds)) > \(milliseconds(maximumLoadSeconds))")
        }
        if median(sortedSeeks) > maximumSeekSeconds {
            failures.append("median seek \(milliseconds(median(sortedSeeks))) > \(milliseconds(maximumSeekSeconds))")
        }
        return failures
    }

    // MARK: - Crash

    /// Spawns a recording child, kills it `crashKillAfterSeconds` after its
    /// movie opens (the `.needsFinalize` marker appears with the first
    /// keyframe), then recovers the package it left. The trigger is on
    /// disk rather than in the child's output, which a pipe buffers until
    /// exit unless the child flushes.
    private static func crashRun(options: Options, synthetic: Bool) async throws -> [String] {
        guard let executable = Bundle.main.executableURL else { throw SpikeError.noExecutable }
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let arguments: [String]
        let marker: String
        var knownPackage: URL?
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: options.outputDirectory.path)) ?? [])
        if synthetic {
            // The package spike needs no grant and names its own package,
            // so the harness is verified on any machine; its package is
            // the one that appears in the directory after the spawn.
            arguments = ["package", options.outputDirectory.path, "\(crashRecordSeconds)"]
            marker = "package: "
        } else {
            let packageURL = RecordingPackage.availableURL(
                for: RecordingPackage.url(createdAt: Date(), source: .display, in: options.outputDirectory))
            arguments =
                ["session", "\(crashRecordSeconds)", "--package", packageURL.path]
                + (options.microphoneID.map { ["--mic", $0] } ?? []) + (options.usesMicrophone ? [] : ["--no-mic"])
            marker = "recording: "
            knownPackage = packageURL
        }
        print(
            "crash harness: spawning \(executable.lastPathComponent) \(arguments.joined(separator: " ")); SIGKILL "
                + "\(format(crashKillAfterSeconds)) s after the movie opens")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        let output = ChildOutput(marker: marker)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            output.append(data)
        }
        try process.run()
        var started = ContinuousClock.now
        var package: RecordingPackage?
        while package == nil, process.isRunning, elapsed(since: started) < childStartTimeout {
            try await Task.sleep(for: .seconds(childPollInterval))
            let candidate: URL?
            if let knownPackage {
                candidate = knownPackage
            } else {
                let now = (try? FileManager.default.contentsOfDirectory(atPath: options.outputDirectory.path)) ?? []
                candidate = now.filter { !before.contains($0) && $0.hasSuffix(".\(RecordingPackage.pathExtension)") }
                    .sorted().first.map { options.outputDirectory.appendingPathComponent($0) }
            }
            guard let candidate else { continue }
            let opened = RecordingPackage(url: candidate)
            if FileManager.default.fileExists(
                atPath: RecordingWriter.markerURL(for: opened.screenFragmentedMovieURL).path)
            {
                package = opened
            }
        }
        guard let package else {
            while process.isRunning { try await Task.sleep(for: .seconds(childPollInterval)) }
            output.flushLines()
            let status = process.terminationStatus
            if status == 3 {
                print("skipped: the child exited 3 (see its output above)")
                exit(3)
            }
            throw SpikeError.childFailed(status, "no movie opened within \(format(childStartTimeout)) s")
        }
        print(
            "child's movie opened at \(package.url.lastPathComponent) after \(milliseconds(elapsed(since: started))); "
                + "killing in \(format(crashKillAfterSeconds)) s")
        try await Task.sleep(for: .seconds(crashKillAfterSeconds))
        started = ContinuousClock.now
        guard process.isRunning else {
            throw SpikeError.childFailed(process.terminationStatus, "it exited before the kill")
        }
        kill(process.processIdentifier, SIGKILL)
        while process.isRunning { try await Task.sleep(for: .seconds(childPollInterval)) }
        // Whatever the child printed after the marker.
        output.flushLines()
        print(
            "child \(process.processIdentifier) ended by "
                + (process.terminationReason == .uncaughtSignal
                    ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)")
                + " \(milliseconds(elapsed(since: started))) after SIGKILL")
        var failures: [String] = []
        if process.terminationReason != .uncaughtSignal || process.terminationStatus != SIGKILL {
            failures.append("the child was not ended by SIGKILL")
        }
        failures += try await recover(package: package)
        return failures
    }

    /// The child's stdout: lines echoed with a prefix, and the package path
    /// from the line starting with `marker`.
    private final class ChildOutput: Sendable {
        private struct State {
            var pending = Data()
            var packagePath: String?
        }

        private let marker: String
        private let state = Mutex(State())

        init(marker: String) {
            self.marker = marker
        }

        var packagePath: String? {
            state.withLock { $0.packagePath }
        }

        func append(_ data: Data) {
            state.withLock { state in
                state.pending.append(data)
                while let newline = state.pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: state.pending[state.pending.startIndex..<newline], as: UTF8.self)
                    state.pending.removeSubrange(state.pending.startIndex...newline)
                    print("  child | \(line)")
                    if state.packagePath == nil, line.hasPrefix(marker) {
                        state.packagePath = String(line.dropFirst(marker.count))
                    }
                }
            }
        }

        func flushLines() {
            state.withLock { state in
                guard !state.pending.isEmpty else { return }
                print("  child | \(String(decoding: state.pending, as: UTF8.self))")
                state.pending.removeAll()
            }
        }
    }

    /// Recovery through the production path on the package a killed take
    /// left: `RecoveryScanner.scan` must offer it and `RecoveryScanner.recover`
    /// finalizes the fragmented movie, rebuilds the log from the sidecar,
    /// repairs the torn index and marks the manifest recovered, as the app
    /// does at the next launch (M1-13); the checks here are on its result.
    private static func recover(package: RecordingPackage) async throws -> [String] {
        var failures: [String] = []
        let before = try package.manifest()
        print("manifest before recovery: \(before.state.rawValue), duration \(before.duration.map(format) ?? "none")")
        if before.state != .inProgress {
            failures.append("the manifest is \(before.state.rawValue), not inProgress")
        }

        let settings = RecoveryScannerSettings(directories: [package.url.deletingLastPathComponent()])
        var started = ContinuousClock.now
        let scan = RecoveryScanner.scan(settings: settings)
        print(
            "scan: \(scan.candidates.count) candidate(s), \(scan.unreadable.count) unreadable, \(scan.inUse.count) in "
                + "use, in \(milliseconds(elapsed(since: started)))")
        for other in scan.inUse { print("  in use: \(other.url.lastPathComponent) \(other.detail)") }
        guard let candidate = scan.candidates.first(where: { $0.package == package }) else {
            failures.append("the scan did not offer \(package.url.lastPathComponent)")
            return failures
        }
        for marker in candidate.markers {
            print(
                "marker: finalize \(marker.fragmentedMovie) into \(marker.finalizedMovie), started "
                    + "\(PackageJSON.string(from: marker.startedAt)), process "
                    + (marker.processID.map { "\($0)" } ?? "unknown"))
        }
        if candidate.markers.isEmpty { failures.append("no .needsFinalize marker") }
        print(
            "candidate: \(candidate.fragmentedMovieBytes / 1024) KiB of fragmented movie, finalized movie "
                + "\(candidate.hasFinalizedMovie), log header \(candidate.hasEventLogHeader), sidecar "
                + "\(candidate.eventsSidecarBytes) bytes")
        guard candidate.hasMovie else {
            failures.append("no fragmented movie to finalize")
            return failures
        }

        started = ContinuousClock.now
        let result = try await RecoveryScanner.recover(candidate, settings: settings)
        print(
            "recovered in \(milliseconds(elapsed(since: started))) (\(milliseconds(result.elapsedSeconds)) inside): "
                + "\(format(result.playableSeconds)) s playable, finalized \(result.finalizedMovies), "
                + "\(result.eventCount) events "
                + (result.logRecovered
                    ? "from the header and sidecar" : "(no header on disk; an empty log was written)")
                + ", frames.jsonl " + (result.frameIndexLines.map { "\($0) lines" } ?? "unreadable")
                + (result.frameIndexTornAtLine.map { ", torn at line \($0) and rewritten whole" }
                    ?? ", every line intact")
                + ", cursors/ \(result.cursorSpriteCount) PNGs (written at stop only, so a crash loses them)")
        for note in result.notes { print("  note: \(note)") }
        let manifest = result.manifest
        print(
            "manifest after recovery: \(manifest.state.rawValue), \(manifest.stopReason?.rawValue ?? ""), "
                + "\(format(manifest.duration ?? 0)) s")

        if manifest.state != .recovered { failures.append("manifest state \(manifest.state.rawValue)") }
        if manifest.stopReason != .crashed { failures.append("stop reason \(manifest.stopReason?.rawValue ?? "none")") }
        if manifest.duration != result.playableSeconds {
            failures.append("the manifest's duration is not the playable length")
        }
        if try package.manifest() != manifest { failures.append("the manifest on disk differs from the result") }
        if (try? ProjectStore(package: package).load())?.recording.state != .recovered {
            failures.append("project.json does not carry the recovered manifest")
        }
        if result.playableSeconds < crashMinimumRecoveredSeconds {
            failures.append(
                "only \(format(result.playableSeconds)) s recovered (< \(format(crashMinimumRecoveredSeconds)) s)")
        }
        if result.logRecovered {
            let log = try package.eventLog()
            if log.events.isEmpty { failures.append("the recovered log holds no events") }
            if let last = log.events.last, last.time < result.playableSeconds - crashPersistenceInterval {
                failures.append(
                    "the recovered log ends \(format(result.playableSeconds - last.time)) s before the movie")
            }
        }
        let leftovers = [
            package.screenFragmentedMovieURL, RecordingWriter.markerURL(for: package.screenFragmentedMovieURL),
            package.eventsSidecarURL,
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !leftovers.isEmpty { failures.append("leftovers \(leftovers.map(\.lastPathComponent))") }
        if !RecoveryScanner.scan(settings: settings).candidates.contains(where: { $0.package == package }) {
            print("a second scan no longer offers the package")
        } else {
            failures.append("the package is offered again after recovery")
        }
        failures += try probeMovie(
            package.screenMovieURL, manifest: manifest, expectedFrames: nil, writerFrames: nil, recordedSeconds: nil,
            requiresMatchingEnds: false)
        return failures
    }

    // MARK: - Pause

    /// The writer spike's pause case on a live stream (DECISIONS "pause
    /// stays in the data path"): `CaptureSession` has no pause until M2-07,
    /// so the clock, encoder and writer are driven here directly.
    private static func pauseRun(
        seconds: Double, microphone: AVCaptureDevice?, permissions: Permissions, outputDirectory: URL
    ) async throws -> [String] {
        let request = try await displayRequest(microphone: microphone, permissions: permissions)
        let content = try await ShareableContent.current(permissions: permissions)
        let built = try StreamConfigurationBuilder.build(request: request, content: content)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let directory = outputDirectory.appendingPathComponent("pause-\(stamp)", isDirectory: true)
        var tracks: [RecordingAudioSource: RecordingWriterConfiguration.AudioTrack] = [
            .system: RecordingWriterConfiguration.AudioTrack(channelCount: request.stream.audioChannelCount)
        ]
        var audioInfo = [AudioTrackInfo(source: .system, channelCount: request.stream.audioChannelCount)]
        if let microphone {
            let channels = channelCount(of: microphone)
            tracks[.microphone] = RecordingWriterConfiguration.AudioTrack(channelCount: channels)
            audioInfo.append(
                AudioTrackInfo(
                    source: .microphone, channelCount: channels, deviceID: microphone.uniqueID,
                    deviceName: microphone.localizedName))
        }
        let clock = RecordingClock()
        let writer = try RecordingWriter(
            movieURL: directory.appendingPathComponent("screen.mov"), clock: clock,
            configuration: RecordingWriterConfiguration(
                audioTracks: tracks, audioSampleRate: Double(request.stream.audioSampleRate)))
        let configuration = VideoEncoderConfiguration(
            width: built.geometry.outputWidth, height: built.geometry.outputHeight, frameRate: request.frameRate)
        let encoder = try VideoEncoder(configuration: configuration, clock: clock) { writer.appendVideo($0) }
        let shim = PauseStreamOutput(clock: clock, encoder: encoder, writer: writer)
        let queue = DispatchQueue(label: "app.cutscene.spike.pause", qos: .userInitiated)
        let stream = SCStream(filter: built.filter, configuration: built.configuration, delegate: shim)
        try stream.addStreamOutput(shim, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(shim, type: .audio, sampleHandlerQueue: queue)
        if microphone != nil {
            try stream.addStreamOutput(shim, type: .microphone, sampleHandlerQueue: queue)
        }
        let half = seconds / 2
        print(
            "pause run: \(configuration.width)×\(configuration.height) \(encoder.codec.rawValue), \(format(half)) s, a "
                + "\(format(pauseLength)) s pause, \(format(half)) s; the clock's origin is just before the stream starts"
        )
        let started = ContinuousClock.now
        try await stream.startCapture()
        print("GO: talk and move things on screen through the pause as well")
        try await Task.sleep(for: .seconds(half))
        clock.pause()
        print("PAUSED at \(format(clock.elapsed.seconds)) s recorded")
        try await Task.sleep(for: .seconds(pauseLength))
        clock.resume()
        let resumedAt = RecordingClock.hostTime()
        shim.noteResumed(at: resumedAt)
        print("RESUMED at \(format(clock.elapsed.seconds)) s recorded (\(format(elapsed(since: started))) s wall)")
        try await Task.sleep(for: .seconds(half))
        clock.stop()
        let recorded = clock.elapsed.seconds
        let wall = elapsed(since: started)
        try await stream.stopCapture()
        try encoder.finish()
        let movieURL = try await writer.finish()
        let counts = shim.counts
        let e = encoder.statistics
        let w = writer.statistics
        print(
            "recorded \(format(recorded)) s of \(format(wall)) s wall; screen samples \(counts.screenSamples) "
                + "(\(counts.contentFrames) content, \(counts.idleFrames) idle, \(counts.otherFrames) other), audio buffers "
                + "\(counts.audioBuffers.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))"
                + "; stream stopped itself: \(counts.stopError ?? "no")")
        print(
            "encoder: \(e.submittedFrames) submitted, \(e.encodedFrames) encoded, \(e.droppedFrames) dropped, "
                + "\(e.skippedOutsideRecording) in the pause, \(e.droppedNonIncreasing) non-increasing; first frame after "
                + "the resume at \(counts.firstFrameAfterResume.map(format) ?? "none") s")
        print(
            "writer: \(w.videoFrames) video frames, \(w.audioBuffers) audio buffers, \(w.audioOutsideRecording) outside "
                + "the recording, \(w.audioDropped) dropped, \(w.audioGapsFilled) gaps filled with "
                + "\(format(w.audioSilenceSeconds)) s silence, \(w.audioOverlapsTrimmed) overlaps trimmed; first audio at "
                + counts.firstAudioTime.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) \(format($0.value)) s" }.joined(separator: ", "))

        var failures: [String] = []
        if let error = counts.stopError { failures.append("the stream stopped: \(error)") }
        if abs(recorded - (wall - pauseLength)) > pauseElapsedTolerance {
            failures.append("recorded \(format(recorded)) s, wall minus pause \(format(wall - pauseLength)) s")
        }
        let sources = tracks.count
        let expectedOutside = Int((pauseLength / audioBufferSeconds).rounded()) * sources
        if abs(w.audioOutsideRecording - expectedOutside) > pauseOutsideBufferTolerance * sources {
            failures.append(
                "\(w.audioOutsideRecording) audio buffers fell in the pause, expected \(expectedOutside) ± "
                    + "\(pauseOutsideBufferTolerance * sources)")
        }
        if w.audioDropped > 0 { failures.append("writer dropped \(w.audioDropped) audio buffers") }
        if w.videoDroppedNotReady + w.videoDroppedBeforeKeyframe + w.videoDroppedNonIncreasing > 0 {
            failures.append("writer dropped video")
        }
        // The join: silence beyond each source's late start is the hole the
        // writer filled at the resume, and it must be under one buffer.
        let initialSilence = counts.firstAudioTime.values.reduce(0, +)
        let joinSilence = w.audioSilenceSeconds - initialSilence
        print(
            "join: \(format(joinSilence)) s of silence beyond the late starts (limit \(format(audioBufferSeconds * Double(sources))) s), "
                + "\(w.audioOverlapsTrimmed) trims (limit \(sources))")
        if joinSilence > audioBufferSeconds * Double(sources) + 0.001 {
            failures.append("the resume join filled \(format(joinSilence)) s of silence")
        }
        if w.audioOverlapsTrimmed > sources { failures.append("\(w.audioOverlapsTrimmed) overlaps trimmed") }
        guard let resumeFrame = counts.firstFrameAfterResume else {
            failures.append("no content frame arrived after the resume (nothing changed on screen?)")
            return failures
                + (try probeMovie(
                    movieURL,
                    manifest: pauseManifest(configuration, request: request, audio: audioInfo, duration: recorded),
                    expectedFrames: nil, writerFrames: w.videoFrames, recordedSeconds: recorded))
        }
        let manifest = pauseManifest(configuration, request: request, audio: audioInfo, duration: recorded)
        failures += try probeMovie(
            movieURL, manifest: manifest, expectedFrames: nil, writerFrames: w.videoFrames, recordedSeconds: recorded)
        if let ffprobe = findFFprobe() {
            let keyframes = try Probe.run(ffprobe, on: movieURL).keyframeTimes
            if !keyframes.contains(where: { abs($0 - resumeFrame) < keyframeMatchTolerance }) {
                failures.append("no keyframe at the first frame after the resume (\(format(resumeFrame)) s)")
            } else {
                print("keyframe at the resume: yes (\(format(resumeFrame)) s)")
            }
        }
        return failures
    }

    /// A manifest for the pause run's movie, so `probeMovie` can check it
    /// like a package's.
    private static func pauseManifest(
        _ configuration: VideoEncoderConfiguration, request: CaptureRequest, audio: [AudioTrackInfo], duration: Double
    ) -> RecordingManifest {
        RecordingManifest(
            source: .display,
            content: ContentGeometry(
                displayID: 0, displayBoundsPoints: PointRect(x: 0, y: 0, width: 0, height: 0),
                captureRectPoints: PointRect(x: 0, y: 0, width: 0, height: 0), pointPixelScale: 1),
            screen: ScreenTrackInfo(
                width: configuration.width, height: configuration.height, frameRate: request.frameRate,
                codec: configuration.codec.rawValue, audioTracks: audio),
            state: .complete, stopReason: .userStopped, duration: duration)
    }

    /// The stream's outputs for the pause run: every sample goes straight
    /// into the encoder or the writer on the sample queue, as the session's
    /// shim does, and the counts the checks need are kept under a lock.
    private final class PauseStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
        struct Counts: Sendable {
            var screenSamples = 0
            var contentFrames = 0
            var idleFrames = 0
            var otherFrames = 0
            var audioBuffers: [RecordingAudioSource: Int] = [:]
            /// Recording time of each source's first buffer: the late start
            /// the writer fills with silence.
            var firstAudioTime: [RecordingAudioSource: Double] = [:]
            var resumedAt: CMTime?
            /// Recording time of the first content frame stamped after the
            /// resume, which the encoder must open a GOP with.
            var firstFrameAfterResume: Double?
            var stopError: String?
        }

        private let clock: RecordingClock
        private let encoder: VideoEncoder
        private let writer: RecordingWriter
        private let state = Mutex(Counts())

        init(clock: RecordingClock, encoder: VideoEncoder, writer: RecordingWriter) {
            self.clock = clock
            self.encoder = encoder
            self.writer = writer
            super.init()
        }

        var counts: Counts {
            state.withLock { $0 }
        }

        func noteResumed(at hostTime: CMTime) {
            state.withLock { $0.resumedAt = hostTime }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
        {
            switch type {
            case .screen:
                let info = ScreenFrameInfo(sampleBuffer: sampleBuffer)
                let time = sampleBuffer.presentationTimeStamp
                state.withLock { state in
                    state.screenSamples += 1
                    if info.carriesContent {
                        state.contentFrames += 1
                    } else if info.status == .idle {
                        state.idleFrames += 1
                    } else {
                        state.otherFrames += 1
                    }
                }
                guard info.carriesContent, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let recordingTime = clock.recordingTime(forHostTime: time)
                state.withLock { state in
                    if let resumedAt = state.resumedAt, state.firstFrameAfterResume == nil, time >= resumedAt,
                        let recordingTime
                    {
                        state.firstFrameAfterResume = recordingTime.seconds
                    }
                }
                try? encoder.encode(pixelBuffer, hostTime: time)
            case .audio, .microphone:
                let source: RecordingAudioSource = type == .audio ? .system : .microphone
                if let time = clock.recordingTime(forHostTime: sampleBuffer.presentationTimeStamp) {
                    state.withLock { state in
                        state.audioBuffers[source, default: 0] += 1
                        if state.firstAudioTime[source] == nil { state.firstAudioTime[source] = time.seconds }
                    }
                }
                writer.appendAudio(sampleBuffer, from: source)
            @unknown default:
                break
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            state.withLock { $0.stopError = error.localizedDescription }
        }
    }

    // MARK: - Helpers

    enum SpikeError: LocalizedError {
        case noDisplay
        case noExecutable
        case childFailed(Int32, String)
        case probeExited(Int32)
        case probeOutput(String)
        case diskImage(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: "ScreenCaptureKit lists no display to record."
            case .noExecutable: "The spike cannot find its own executable to spawn the crash child."
            case .childFailed(let status, let detail): "The crash child exited with status \(status); \(detail)."
            case .probeExited(let status): "ffprobe exited with status \(status)."
            case .probeOutput(let detail): "Could not read ffprobe output: \(detail)."
            case .diskImage(let detail): "The fill-disk image failed: \(detail)."
            }
        }
    }

    private static func kind(of event: InputEvent) -> String {
        switch event {
        case .pointerMoved: "pointerMoved"
        case .buttonDown: "buttonDown"
        case .buttonUp: "buttonUp"
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .cursorShapeChanged: "cursorShapeChanged"
        case .takeMarker: "takeMarker"
        case .scroll: "scroll"
        case .focus: "focus"
        case .geometry: "geometry"
        case .unknown(let kind, _): "unknown(\(kind))"
        }
    }

    /// A JSON value on one line, keys sorted.
    private static func oneLine(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .integer(let integer): "\(integer)"
        case .number(let number): String(format: "%.6g", number)
        case .string(let string): "\"\(truncated(string))\""
        case .array(let array): "[" + array.map(oneLine).joined(separator: ", ") + "]"
        case .object(let object):
            "{" + object.sorted { $0.key < $1.key }.map { "\($0.key): \(oneLine($0.value))" }.joined(separator: ", ")
                + "}"
        }
    }

    /// A JSON object one key per line, nested objects indented, so the
    /// attachment dump reads like the plist it came from.
    private static func printTree(_ value: JSONValue, indent: String) {
        guard case .object(let object) = value, !object.isEmpty else {
            print("\(indent)\(oneLine(value))")
            return
        }
        for (key, member) in object.sorted(by: { $0.key < $1.key }) {
            if case .object(let nested) = member, !nested.isEmpty {
                print("\(indent)\(key):")
                printTree(member, indent: indent + "    ")
            } else {
                print("\(indent)\(key): \(oneLine(member))")
            }
        }
    }

    private static func truncated(_ string: String) -> String {
        string.count <= maximumPrintedValueLength
            ? string : string.prefix(maximumPrintedValueLength) + "… (\(string.count) chars)"
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private static func gigabytes(_ bytes: Int64?) -> String {
        bytes.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "n/a"
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up))
        return sorted[max(min(rank, sorted.count) - 1, 0)]
    }
}
