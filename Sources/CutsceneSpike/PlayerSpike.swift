import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation
import Synchronization

/// Spike S2, player half (PLAN M2-04; ARCHITECTURE §5, §9.2): the
/// composition from `CompositionBuilder` in an `AVPlayerLayer` window
/// opened from the CLI, the preview's path.
///
/// `player <package> [--hold <seconds>]` opens a window on the package's
/// composition and measures, in order:
///
/// 1. **Zero-tolerance seeks** with `seekingWaitsForVideoCompositionRendering`:
///    whether every seek fires `startRequest` on the compositor, at the
///    target time, and how long the seek takes from the call to the
///    rendered frame (ARCHITECTURE §5 trips the v2 decoder above 150 ms;
///    the editor wants under 50 ms).
/// 2. **Paused re-render** on a `videoComposition` reassignment, the live
///    edit path: whether a paused item renders its current frame again
///    when a new composition with a new style is assigned, how long that
///    takes, and whether the engine makes a new compositor instance for
///    it; when it does not re-render by itself, a forced zero-tolerance
///    seek to the current time is timed instead. Above 50 ms either way,
///    the `AVPlayerItemVideoOutput` escalation becomes a task.
/// 3. **Preview against export**: the frame the player shows at a time
///    (through an `AVPlayerItemVideoOutput`) against the frame an
///    `AVAssetReaderVideoCompositionOutput` renders at the same time.
/// 4. **Two instances at once**: the export's read side (an asset reader at
///    full speed) alone, the player playing alone, then both together;
///    the reader's wall time and the player's request cadence and latency
///    say whether the two `MetalCompositor` instances serialize.
///
/// The compositor class on every composition here is `TimedCompositor`, a
/// thin shell around `MetalCompositor` that stamps each request's start and
/// finish; the rendering is the product's. A synthetic package from
/// `make spike ARGS="package"` is enough; nothing here needs a permission,
/// and the window raises no prompt.
enum PlayerSpike {
    /// The preview's canvas: the export's 1080p60 capped at
    /// `previewMaxPixels` (ARCHITECTURE §5 `preview.maxPixels`; 1080p is at
    /// the cap, so the preview renders what the export renders).
    static let canvas = CanvasSpec.hd1080p60
    static let previewMaxPixels = 1920 * 1080
    /// The window's content size, in points; the layer aspect-fits the frame.
    static let windowSize = NSSize(width: 960, height: 540)
    /// How long the item may take to become ready, and the poll while waiting.
    static let playerReadyTimeout = 15.0
    static let pollInterval = 0.005
    /// Seeks measured, spread over the recording and pushed into their GOP
    /// by a fixed fraction so they land between keyframes.
    static let seekSamples = 12
    static let seekPhase = 0.37
    /// A request for the target may land on the frame boundary at or
    /// before it: the engine quantizes composition time to the frame rate.
    static let seekTimeTolerance = 1.0 / Double(canvas.frameRate) + 1e-6
    /// A seek that fires no request within this is one the engine skipped.
    static let seekRequestTimeout = 2.0
    /// The §5 v2-decoder trigger for a zero-tolerance seek, and the
    /// editor's own bound for seeks and paused re-renders (PLAN M2-04).
    static let maximumSeekMilliseconds = 150.0
    static let maximumPausedRerenderMilliseconds = 50.0
    /// Reassignments measured, each with a differently angled gradient so
    /// the change is visible; a paused item that renders nothing within
    /// `reassignmentTimeout` gets the forced seek.
    static let reassignmentSamples = 8
    static let reassignmentGradientStepDegrees = 40.0
    static let reassignmentTimeout = 1.0
    /// The paused frame for the re-render and the match passes, as a
    /// fraction of the recording: inside the first zoom, outside the
    /// synthetic package's static stretch.
    static let pausedFraction = 0.2
    /// How long the player plays alone and, at least, with the reader; the
    /// reader on a 10 s package takes about as long.
    static let playbackSeconds = 3.0
    /// Playback that delivered fewer requests than this share of the
    /// frames in its window stalled.
    static let minimumCadenceShare = 0.9
    /// Reader requests that overlapped a player request run slower than
    /// the rest by more than this share of the player's median render when
    /// a lock is shared between the instances; the GPU is shared either
    /// way, so a smaller difference is expected.
    static let lockInflationShare = 0.5
    /// Two compositors rendering at once from two threads take at least
    /// this share of the sum of their solo times when they serialize; the
    /// GPU is one device, so a parallel pair still takes more than the
    /// longer solo time.
    static let serializationShare = 0.75
    static let benchmarkFrames = 120
    /// Padding kept around the hold for the lead to look at the window.
    static let holdDefaultSeconds = 0.0

    static func run(arguments: [String]) async -> Bool {
        var rest = arguments
        var holdSeconds = holdDefaultSeconds
        if let index = rest.firstIndex(of: "--hold") {
            guard index + 1 < rest.count, let value = Double(rest[index + 1]), value >= 0 else {
                print("usage: player <package> [--hold <seconds>]")
                return false
            }
            holdSeconds = value
            rest.removeSubrange(index...index + 1)
        }
        guard rest.count == 1 else {
            print("usage: player <package> [--hold <seconds>]")
            return false
        }
        do {
            let package = try RecordingPackage.open(at: URL(fileURLWithPath: rest[0]))
            let failures = try await stage(package: package, holdSeconds: holdSeconds)
            if failures.isEmpty {
                print("PASS")
                return true
            }
            print("FAIL: " + failures.joined(separator: "; "))
            return false
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - The run

    /// AppKit on the main thread under `NSApplication.run`, the
    /// measurements in a main-actor task underneath it.
    ///
    /// The async entry point is itself one block on the main dispatch
    /// queue, and that queue is serial and not re-entrant: an `app.run()`
    /// called from inside it would let no further main-queue block run,
    /// so neither a main-actor task nor AVFoundation's status callbacks
    /// (which arrive through the main queue) would execute. So the entry
    /// task suspends on a continuation, which frees the queue, and the
    /// application loop starts from a run-loop block instead; the loop
    /// drains the main queue as any AppKit app's does until the
    /// measurement task stops it, and the continuation then returns here.
    /// (The entry point's own `CFRunLoopRun` is not usable in place of
    /// `run` either: pumping events through `nextEvent` returns from it,
    /// and the runtime then exits the process.)
    @MainActor
    private static func stage(package: RecordingPackage, holdSeconds: Double) async throws -> [String] {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = PlayerWindow(size: windowSize)
        window.show()
        app.finishLaunching()
        app.activate()
        let outcome = Outcome()
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    Task { @MainActor in
                        do {
                            outcome.failures = try await measure(
                                package: package, window: window, holdSeconds: holdSeconds)
                        } catch {
                            outcome.error = error
                        }
                        NSApp.stop(nil)
                        // `stop` takes effect once the loop processes another event.
                        if let wake = NSEvent.otherEvent(
                            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
                        {
                            NSApp.postEvent(wake, atStart: true)
                        }
                    }
                    NSApp.run()
                    continuation.resume()
                }
            }
        }
        window.close()
        if let error = outcome.error { throw error }
        return outcome.failures
    }

    /// What the measurement task leaves for `stage` once the loop stops.
    @MainActor
    private final class Outcome {
        var failures: [String] = []
        var error: (any Error)?
    }

    @MainActor
    private static func measure(package: RecordingPackage, window: PlayerWindow, holdSeconds: Double) async throws
        -> [String]
    {
        var failures: [String] = []
        print("player spike: \(package.url.path)")
        let manifest = try package.manifest()
        let log = try package.eventLog()
        let duration: Double
        if let recorded = manifest.duration {
            duration = recorded
        } else {
            duration = try await AVURLAsset(url: package.screenMovieURL).load(.duration).seconds
        }
        let preview = canvas.fitting(maximumPixels: previewMaxPixels)
        print(
            "GPU \(CutsceneRender.gpuName ?? "none"); recording \(manifest.screen.width)×\(manifest.screen.height) "
                + "\(format(duration)) s; preview canvas \(preview.width)×\(preview.height) @ \(preview.frameRate) "
                + "(cap \(previewMaxPixels) px)")

        let plan = RenderPlan.build(log: log, duration: duration)
        let atlas = CursorAtlas.load(for: plan, in: package)
        var style = RenderStyle()
        style.outputWidth = preview.width
        style.outputHeight = preview.height
        let built = try await CompositionBuilder.build(
            package: package, keptRanges: [0...duration], plan: plan, style: style, cursor: atlas, canvas: preview)
        built.videoComposition.customVideoCompositorClass = TimedCompositor.self
        print(
            "composition: \(format(built.duration.seconds)) s, \(built.expectedFrameCount) frames, "
                + "\(built.instructions.count) instruction(s), audio mix \(built.audioMix?.inputParameters.count ?? 0) "
                + "track(s)")

        // The player.
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        let player = AVPlayer(playerItem: item)
        // The synthetic package carries a tone and click beeps; this spike
        // measures video timing only and runs unattended, so never play audio.
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        window.playerLayer.player = player
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let windowNumber = window.windowNumber
        let readyStarted = ContinuousClock.now
        while item.status == .unknown, seconds(since: readyStarted) < playerReadyTimeout {
            try await Task.sleep(for: .seconds(pollInterval))
        }
        let registry = TimedCompositorRegistry.shared
        print(
            "player: \(item.status == .readyToPlay ? "ready" : "NOT ready (\(item.error?.localizedDescription ?? "status \(item.status.rawValue)"))") "
                + "after \(milliseconds(seconds(since: readyStarted))); window \(windowNumber); "
                + "compositor instances \(registry.instanceCount) (init \(registry.initTimes.map(milliseconds).joined(separator: ", ")))"
        )
        guard item.status == .readyToPlay else { return ["the player item never became ready"] }
        guard let first = item.customVideoCompositor as? TimedCompositor else {
            return ["the item's customVideoCompositor is not the TimedCompositor"]
        }
        // The engine renders the first frame on its own once the item is
        // ready; let it land so the seek pass counts only its own requests.
        try await settle()
        print("first frame: \(describe(registry.events(instance: first.id)))")

        // 1. Zero-tolerance seeks.
        print("")
        let targets = (0..<seekSamples).map { duration * (Double($0) + seekPhase) / Double(seekSamples) }
        var seekTimes: [Double] = []
        var requestsPerSeek: [Int] = []
        var offTarget = 0
        var unfired = 0
        for target in targets {
            let time = CMTime(seconds: target, preferredTimescale: CMTimeScale(canvas.frameRate * 1000))
            let before = registry.eventCount
            let started = ContinuousClock.now
            let finished = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            let elapsed = seconds(since: started)
            seekTimes.append(elapsed)
            if !finished { failures.append("the seek to \(format(target)) s was interrupted") }
            // The seek waits for the render, so the request has finished;
            // a short grace covers the engine finishing its bookkeeping.
            var fired = registry.events(after: before)
            let graceStarted = ContinuousClock.now
            while fired.isEmpty, seconds(since: graceStarted) < seekRequestTimeout {
                try await Task.sleep(for: .seconds(pollInterval))
                fired = registry.events(after: before)
            }
            requestsPerSeek.append(fired.count)
            if fired.isEmpty {
                unfired += 1
            } else if !fired.contains(where: { abs($0.compositionTime - target) <= seekTimeTolerance }) {
                offTarget += 1
            }
            let latencies = fired.map(\.latencySeconds)
            print(
                "seek \(format(target)) s: \(milliseconds(elapsed)) to the rendered frame; \(fired.count) request(s) "
                    + "at \(fired.map { format($0.compositionTime) + " s" }.joined(separator: ", ")), "
                    + "render \(latencies.map(milliseconds).joined(separator: ", "))")
        }
        let sortedSeeks = seekTimes.sorted()
        print(
            "seeks: \(seekSamples) zero-tolerance, median \(milliseconds(median(sortedSeeks))), "
                + "p95 \(milliseconds(percentile(sortedSeeks, 0.95))), max \(milliseconds(sortedSeeks.last ?? 0)) "
                + "(§5 trigger \(milliseconds(maximumSeekMilliseconds / 1000)) median, editor bound "
                + "\(milliseconds(maximumPausedRerenderMilliseconds / 1000))); requests per seek "
                + "\(Set(requestsPerSeek).sorted()); \(unfired) seeks fired no request, \(offTarget) rendered "
                + "a time off the target")
        if unfired > 0 { failures.append("\(unfired) seeks fired no startRequest") }
        if offTarget > 0 { failures.append("\(offTarget) seeks rendered a time off the target") }
        if median(sortedSeeks) * 1000 > maximumSeekMilliseconds {
            failures.append("median seek \(milliseconds(median(sortedSeeks))) > \(maximumSeekMilliseconds) ms")
        }
        let seeksOverEditorBound = median(sortedSeeks) * 1000 > maximumPausedRerenderMilliseconds

        // 2. Paused re-render on a videoComposition reassignment.
        print("")
        let pausedTime = CMTime(
            value: CMTimeValue((duration * pausedFraction * Double(canvas.frameRate)).rounded()),
            timescale: CMTimeScale(canvas.frameRate))
        _ = await item.seek(to: pausedTime, toleranceBefore: .zero, toleranceAfter: .zero)
        try await settle()
        var rerenderTimes: [Double] = []
        var forcedSeekTimes: [Double] = []
        var assignTimes: [Double] = []
        var newInstances = 0
        var offPausedTime = 0
        var renderedFirst: [Double] = []
        for index in 1...reassignmentSamples {
            var variant = style
            variant.background = .linearGradient(
                from: RenderColor(rgb: 0x1C_2B_4B), to: RenderColor(rgb: 0x4A_1F_5E),
                angleDegrees: 45 + reassignmentGradientStepDegrees * Double(index))
            let replacement = videoComposition(like: built, style: variant)
            let instancesBefore = registry.instanceCount
            let compositorBefore = item.customVideoCompositor as AnyObject?
            let assigned = ContinuousClock.now
            item.videoComposition = replacement
            let assignSeconds = seconds(since: assigned)
            assignTimes.append(assignSeconds)
            let event = await registry.nextEvent(after: assigned, timeout: .seconds(reassignmentTimeout))
            let compositorAfter = item.customVideoCompositor as AnyObject?
            let madeInstance = registry.instanceCount > instancesBefore || compositorBefore !== compositorAfter
            if madeInstance { newInstances += 1 }
            var line = "reassign \(index): assignment \(milliseconds(assignSeconds))"
            if let event {
                let total = Self.seconds(from: assigned, to: event.end)
                rerenderTimes.append(total)
                renderedFirst.append(Self.seconds(from: assigned, to: event.start))
                if abs(event.compositionTime - pausedTime.seconds) > seekTimeTolerance { offPausedTime += 1 }
                line +=
                    ", re-rendered by itself in \(milliseconds(total)) (request began after "
                    + "\(milliseconds(Self.seconds(from: assigned, to: event.start))), render "
                    + "\(milliseconds(event.latencySeconds)), at \(format(event.compositionTime)) s)"
            } else {
                let started = ContinuousClock.now
                let before = registry.eventCount
                _ = await item.seek(to: pausedTime, toleranceBefore: .zero, toleranceAfter: .zero)
                let elapsed = seconds(since: started)
                forcedSeekTimes.append(elapsed)
                let fired = registry.events(after: before)
                line +=
                    ", no request within \(format(reassignmentTimeout)) s; forced seek rendered in "
                    + "\(milliseconds(elapsed)) (\(fired.count) request(s))"
                if fired.isEmpty { failures.append("reassign \(index): the forced seek fired no request") }
            }
            line += madeInstance ? "; new compositor instance" : "; same compositor instance"
            print(line)
        }
        let sortedRerenders = rerenderTimes.sorted()
        let sortedForced = forcedSeekTimes.sorted()
        let initTimes = registry.initTimes
        print(
            "paused re-render: \(rerenderTimes.count) of \(reassignmentSamples) reassignments re-rendered by "
                + "themselves (median \(milliseconds(median(sortedRerenders))), max "
                + "\(milliseconds(sortedRerenders.last ?? 0)); request began after median "
                + "\(milliseconds(median(renderedFirst.sorted())))), \(forcedSeekTimes.count) needed the forced "
                + "seek (median \(milliseconds(median(sortedForced))), max \(milliseconds(sortedForced.last ?? 0))); "
                + "assignment call median \(milliseconds(median(assignTimes.sorted()))); \(newInstances) new "
                + "compositor instances (\(registry.instanceCount) in all, init median "
                + "\(milliseconds(median(initTimes.sorted()))), max \(milliseconds(initTimes.max() ?? 0))); "
                + "\(offPausedTime) rendered a time off the paused frame (bound "
                + "\(maximumPausedRerenderMilliseconds) ms)")
        let pausedPath: Double
        if !rerenderTimes.isEmpty && forcedSeekTimes.isEmpty {
            pausedPath = median(sortedRerenders)
        } else if rerenderTimes.isEmpty {
            pausedPath = median(sortedForced)
        } else {
            pausedPath = max(median(sortedRerenders), median(sortedForced))
        }
        if pausedPath * 1000 > maximumPausedRerenderMilliseconds {
            failures.append(
                "paused re-render \(milliseconds(pausedPath)) > \(maximumPausedRerenderMilliseconds) ms: the "
                    + "AVPlayerItemVideoOutput escalation becomes a task")
        }
        if offPausedTime > 0 { failures.append("\(offPausedTime) re-renders drew a time off the paused frame") }
        if seeksOverEditorBound {
            print(
                "note: the median seek is over the editor's \(maximumPausedRerenderMilliseconds) ms bound; the "
                    + "AVPlayerItemVideoOutput escalation becomes a task")
        }
        guard let current = item.customVideoCompositor as? TimedCompositor else {
            return failures + ["the item's compositor is no longer a TimedCompositor"]
        }

        // 3. The preview's frame against the export's at the paused time.
        print("")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        // The output joins after the frame was composed; a seek to the
        // same time makes the engine deliver it to the output too.
        _ = await item.seek(to: pausedTime, toleranceBefore: .zero, toleranceAfter: .zero)
        let outputStarted = ContinuousClock.now
        while !output.hasNewPixelBuffer(forItemTime: pausedTime), seconds(since: outputStarted) < seekRequestTimeout {
            try await Task.sleep(for: .seconds(pollInterval))
        }
        let previewFrame = output.copyPixelBuffer(forItemTime: pausedTime, itemTimeForDisplay: nil)
        item.remove(output)
        let exportBuilt = try await CompositionBuilder.build(
            package: package, keptRanges: [0...duration], plan: plan, style: current.style(of: item) ?? style,
            cursor: atlas, canvas: preview)
        exportBuilt.videoComposition.customVideoCompositorClass = TimedCompositor.self
        let exportFrame = try await readFrame(exportBuilt, at: pausedTime)
        if let previewFrame, let exportFrame {
            let previewHash = try hash(previewFrame)
            let exportHash = try hash(exportFrame)
            let matches = previewHash == exportHash
            print(
                "frame at \(format(pausedTime.seconds)) s: preview \(String(previewHash, radix: 16)) "
                    + "(\(CVPixelBufferGetWidth(previewFrame))×\(CVPixelBufferGetHeight(previewFrame))), "
                    + "export \(String(exportHash, radix: 16)) "
                    + "(\(CVPixelBufferGetWidth(exportFrame))×\(CVPixelBufferGetHeight(exportFrame))): "
                    + (matches ? "identical bytes" : "DIFFERENT (\(try differingPixels(previewFrame, exportFrame)) px)")
            )
            if !matches { failures.append("the preview frame and the export frame at the paused time differ") }
        } else {
            print(
                "frame at \(format(pausedTime.seconds)) s: preview \(previewFrame == nil ? "missing" : "ok"), "
                    + "export \(exportFrame == nil ? "missing" : "ok")")
            failures.append("could not compare the preview frame with the export frame")
        }

        // 4. The export's read side and the player, alone and together.
        print("")
        let readerAlone = try await readAll(exportBuilt)
        print("reader alone: \(describeRead(readerAlone))")
        _ = await item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        try await settle()
        let playAloneStart = ContinuousClock.now
        player.play()
        try await Task.sleep(for: .seconds(playbackSeconds))
        player.pause()
        let playAloneEnd = ContinuousClock.now
        let playAlone = registry.events(instance: current.id, from: playAloneStart, to: playAloneEnd)
        print(
            "player alone: \(describePlayback(playAlone, window: Self.seconds(from: playAloneStart, to: playAloneEnd)))"
        )

        let togetherBuilt = try await CompositionBuilder.build(
            package: package, keptRanges: [0...duration], plan: plan, style: style, cursor: atlas, canvas: preview)
        togetherBuilt.videoComposition.customVideoCompositorClass = TimedCompositor.self
        _ = await item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        try await settle()
        let togetherStart = ContinuousClock.now
        player.play()
        let readerTogether = try await readAll(togetherBuilt)
        if seconds(since: togetherStart) < playbackSeconds {
            try await Task.sleep(for: .seconds(playbackSeconds - seconds(since: togetherStart)))
        }
        player.pause()
        let playTogether = registry.events(
            instance: current.id, from: readerTogether.start, to: readerTogether.end)
        print("reader with the player playing: \(describeRead(readerTogether))")
        print(
            "player with the reader running: "
                + describePlayback(
                    playTogether, window: Self.seconds(from: readerTogether.start, to: readerTogether.end)))
        let readerEvents = registry.events(instance: readerTogether.instance)
        let overlappedPlayer = playTogether.filter { play in
            readerEvents.contains { $0.start < play.end && play.start < $0.end }
        }
        let overlappedReader = readerEvents.filter { read in
            playTogether.contains { $0.start < read.end && read.start < $0.end }
        }
        let otherReader = readerEvents.filter { read in
            !playTogether.contains { $0.start < read.end && read.start < $0.end }
        }
        let overlappedReaderMedian = median(overlappedReader.map(\.latencySeconds).sorted())
        let otherReaderMedian = median(otherReader.map(\.latencySeconds).sorted())
        let playerMedian = median(playTogether.map(\.latencySeconds).sorted())
        let playerRenderSeconds = playTogether.reduce(0) { $0 + $1.latencySeconds }
        let growth = readerTogether.wallSeconds - readerAlone.wallSeconds
        let expectedFrames = Double(canvas.frameRate) * Self.seconds(from: readerTogether.start, to: readerTogether.end)
        let cadenceShare = Double(playTogether.count) / max(expectedFrames, 1)
        // A lock shared by the instances would hold a reader request for
        // the rest of the player's render whenever the two coincide, so
        // the reader requests that overlapped one would come out slower
        // than the rest by a share of the player's render time.
        let lockInflation = overlappedReaderMedian - otherReaderMedian
        let lockSignature = lockInflation > playerMedian * lockInflationShare
        print(
            "instances: \(overlappedPlayer.count) of \(playTogether.count) player requests were in flight while a "
                + "reader request was, \(overlappedReader.count) of \(readerEvents.count) reader requests while a "
                + "player request was; those reader requests took median \(milliseconds(overlappedReaderMedian)) "
                + "against \(milliseconds(otherReaderMedian)) for the rest "
                + "(\(lockInflation >= 0 ? "+" : "")\(milliseconds(lockInflation)); a shared lock would add about "
                + "half the player's \(milliseconds(playerMedian))); reader wall \(format(readerAlone.wallSeconds)) s "
                + "alone → \(format(readerTogether.wallSeconds)) s together (\(growth >= 0 ? "+" : "")"
                + "\(milliseconds(growth)); the player rendered \(milliseconds(playerRenderSeconds)) meanwhile); "
                + "player cadence \(String(format: "%.0f", cadenceShare * 100)) % of \(Int(expectedFrames)) frames")
        if cadenceShare < minimumCadenceShare {
            failures.append(
                "the player delivered \(playTogether.count) of \(Int(expectedFrames)) frames with the reader running")
        }

        // The same question without AVFoundation in between: two
        // compositors on two threads, against the sum of their solo times.
        let direct = try await directBenchmark()
        let serializedSum = direct.firstAlone + direct.secondAlone
        let directSerialized = direct.together >= serializedSum * serializationShare
        print(
            "two Compositors, \(benchmarkFrames) frames each at \(canvas.width)×\(canvas.height): "
                + "\(format(direct.firstAlone)) s and \(format(direct.secondAlone)) s alone, \(format(direct.together)) s "
                + "both at once from two threads (serialized would be ≥ \(format(serializedSum * serializationShare)) s, "
                + "\(String(format: "%.0f", serializationShare * 100)) % of the sum); "
                + (directSerialized ? "SERIALIZED" : "the instances do not serialize")
                + (lockSignature ? "; but the reader's overlapped requests carry a lock's signature" : ""))
        if directSerialized || lockSignature { failures.append("the two compositor instances serialize") }
        let held = current.inner.statistics.heldFrames
        let blank = current.inner.statistics.blankFrames
        print(
            "player compositor: \(current.inner.statistics.requests) requests in all, \(held) held, \(blank) blank, "
                + "\(current.inner.statistics.failures) failed")
        if current.inner.statistics.failures > 0 {
            failures.append("\(current.inner.statistics.failures) player requests failed")
        }

        if holdSeconds > 0 {
            print("")
            print("holding the window \(format(holdSeconds)) s, playing from the start (window \(windowNumber))")
            fflush(stdout)
            _ = await item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            try await Task.sleep(for: .seconds(holdSeconds))
            player.pause()
        }
        return failures
    }

    // MARK: - Compositions

    /// A fresh video composition with the same engine settings as `built`'s
    /// and the same instructions carrying `style`: what a live edit assigns.
    /// A player item copies the composition it is given, so mutating the
    /// one it holds changes nothing; a reassignment is the only path.
    private static func videoComposition(like built: BuiltComposition, style: RenderStyle) -> AVMutableVideoComposition
    {
        let source = built.videoComposition
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = TimedCompositor.self
        composition.renderSize = source.renderSize
        composition.renderScale = source.renderScale
        composition.frameDuration = source.frameDuration
        composition.sourceTrackIDForFrameTiming = source.sourceTrackIDForFrameTiming
        composition.colorPrimaries = source.colorPrimaries
        composition.colorTransferFunction = source.colorTransferFunction
        composition.colorYCbCrMatrix = source.colorYCbCrMatrix
        composition.instructions = built.instructions.map { instruction in
            RenderInstruction(
                timeRange: instruction.timeRange, sourceStart: instruction.sourceStart,
                screenTrackID: instruction.screenTrackID, plan: instruction.plan, style: style,
                cursorAtlas: instruction.cursorAtlas, sourceWidth: instruction.sourceWidth,
                sourceHeight: instruction.sourceHeight, capturePointSize: instruction.capturePointSize)
        }
        return composition
    }

    private struct ReadResult {
        var instance: Int
        var frames = 0
        var start: ContinuousClock.Instant
        var end: ContinuousClock.Instant
        var events: [RequestEvent] = []

        var wallSeconds: Double { PlayerSpike.seconds(from: start, to: end) }
    }

    /// The export's read side: every frame of the composition through a
    /// BGRA video composition output, as fast as the engine goes.
    private static func readAll(_ built: BuiltComposition) async throws -> ReadResult {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpikeError.reader("the reader refused the output") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SpikeError.reader("startReading returned false without an error")
        }
        guard let compositor = output.customVideoCompositor as? TimedCompositor else {
            throw SpikeError.reader("the output's compositor is not the TimedCompositor")
        }
        var result = ReadResult(instance: compositor.id, start: ContinuousClock.now, end: ContinuousClock.now)
        while let sample = output.copyNextSampleBuffer() {
            _ = sample
            result.frames += 1
        }
        result.end = ContinuousClock.now
        guard reader.status == .completed else {
            throw reader.error ?? SpikeError.reader("the reader ended with status \(reader.status.rawValue)")
        }
        compositor.inner.flush()
        result.events = TimedCompositorRegistry.shared.events(instance: compositor.id)
        return result
    }

    /// One frame of the composition at `time`, through the same output.
    private static func readFrame(_ built: BuiltComposition, at time: CMTime) async throws -> CVPixelBuffer? {
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: time, duration: canvas.frameDuration)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw SpikeError.reader("the reader refused the output") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SpikeError.reader("startReading returned false without an error")
        }
        var frame: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if frame == nil, abs(stamp.seconds - time.seconds) <= seekTimeTolerance {
                frame = CMSampleBufferGetImageBuffer(sample)
            }
        }
        (output.customVideoCompositor as? TimedCompositor)?.inner.flush()
        return frame
    }

    // MARK: - Direct benchmark

    private struct DirectBenchmark {
        var firstAlone: Double
        var secondAlone: Double
        var together: Double
    }

    /// `benchmarkFrames` renders on each of two `Compositor`s alone, then
    /// the same on both from two tasks at once, on a transparent 1080p
    /// source (the background and card are the whole cost either way).
    private static func directBenchmark() async throws -> DirectBenchmark {
        let first = try Compositor()
        let second = try Compositor()
        let firstAlone = try renderBurst(first)
        let secondAlone = try renderBurst(second)
        let started = ContinuousClock.now
        async let firstTogether = Task.detached { try renderBurst(first) }.value
        async let secondTogether = Task.detached { try renderBurst(second) }.value
        _ = try await (firstTogether, secondTogether)
        return DirectBenchmark(firstAlone: firstAlone, secondAlone: secondAlone, together: seconds(since: started))
    }

    /// One warm-up render, then `benchmarkFrames` timed ones; the frames
    /// go back to the compositor's pool as they are dropped.
    private static func renderBurst(_ compositor: Compositor) throws -> Double {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, canvas.width, canvas.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
            &created)
        guard status == kCVReturnSuccess, let source = created else { throw SpikeError.pixelBuffer }
        var style = RenderStyle()
        style.outputWidth = canvas.width
        style.outputHeight = canvas.height
        let frame = SourceFrame(pixelBuffer: source)
        _ = try compositor.render(frame, style: style)
        let started = ContinuousClock.now
        for _ in 0..<benchmarkFrames {
            _ = try compositor.render(frame, style: style)
        }
        compositor.flush()
        return seconds(since: started)
    }

    // MARK: - Reporting

    private static func describe(_ events: [RequestEvent]) -> String {
        guard !events.isEmpty else { return "no request yet" }
        return "\(events.count) request(s) at "
            + events.map { format($0.compositionTime) + " s" }.joined(separator: ", ") + ", render "
            + events.map { milliseconds($0.latencySeconds) }.joined(separator: ", ")
    }

    private static func describeRead(_ result: ReadResult) -> String {
        let latencies = result.events.map(\.latencySeconds).sorted()
        let busy = latencies.reduce(0, +)
        return "\(result.frames) frames in \(format(result.wallSeconds)) s "
            + "(\(String(format: "%.1f", Double(result.frames) / max(result.wallSeconds, 1e-9))) fps), "
            + "\(result.events.count) requests, render median \(milliseconds(median(latencies))), p95 "
            + "\(milliseconds(percentile(latencies, 0.95))), max \(milliseconds(latencies.last ?? 0)), compositor busy "
            + "\(String(format: "%.0f", busy / max(result.wallSeconds, 1e-9) * 100)) % of the wall"
    }

    private static func describePlayback(_ events: [RequestEvent], window: Double) -> String {
        let latencies = events.map(\.latencySeconds).sorted()
        let expected = Int((window * Double(canvas.frameRate)).rounded())
        return "\(events.count) requests in \(format(window)) s (\(expected) frames at \(canvas.frameRate) fps), "
            + "render median \(milliseconds(median(latencies))), p95 \(milliseconds(percentile(latencies, 0.95))), "
            + "max \(milliseconds(latencies.last ?? 0))"
    }

    // MARK: - Frames

    /// FNV-1a over the frame's pixels, row by row, so padding stays out.
    private static func hash(_ buffer: CVPixelBuffer) throws -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in 0..<height {
            let bytes = UnsafeRawBufferPointer(start: base.advanced(by: row * bytesPerRow), count: width * 4)
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    private static func differingPixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> Int {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let baseA = CVPixelBufferGetBaseAddress(a), let baseB = CVPixelBufferGetBaseAddress(b) else {
            throw SpikeError.pixelBuffer
        }
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        let rowA = CVPixelBufferGetBytesPerRow(a)
        let rowB = CVPixelBufferGetBytesPerRow(b)
        var count = 0
        for row in 0..<height {
            let pixelsA = baseA.advanced(by: row * rowA).assumingMemoryBound(to: UInt32.self)
            let pixelsB = baseB.advanced(by: row * rowB).assumingMemoryBound(to: UInt32.self)
            for column in 0..<width where pixelsA[column] != pixelsB[column] { count += 1 }
        }
        return count
    }

    // MARK: - Run loop

    /// A few frames of quiet, so a render the engine started on its own
    /// lands before the next measurement counts requests.
    static let settleSeconds = 0.25

    private static func settle() async throws {
        try await Task.sleep(for: .seconds(settleSeconds))
    }

    // MARK: - Helpers

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        seconds(from: start, to: ContinuousClock.now)
    }

    static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
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

    enum SpikeError: LocalizedError {
        case reader(String)
        case pixelBuffer

        var errorDescription: String? {
            switch self {
            case .reader(let detail): "The asset reader failed: \(detail)."
            case .pixelBuffer: "A frame's pixel buffer could not be read."
            }
        }
    }
}

// MARK: - Timing shell

/// One compositor request as the shell saw it.
struct RequestEvent: Sendable {
    let instance: Int
    let start: ContinuousClock.Instant
    let end: ContinuousClock.Instant
    let compositionTime: Double
    let failed: Bool

    var latencySeconds: Double { PlayerSpike.seconds(from: start, to: end) }
}

/// Every `TimedCompositor` the engine made and every request they served,
/// in one place, since the engine instantiates compositors itself and hands
/// out no reference before the first request.
final class TimedCompositorRegistry: Sendable {
    static let shared = TimedCompositorRegistry()

    private struct Waiter {
        let generation: Int
        let after: ContinuousClock.Instant
        let continuation: CheckedContinuation<RequestEvent?, Never>
    }

    private struct State {
        var initTimes: [Double] = []
        var events: [RequestEvent] = []
        var waiter: Waiter?
        var generation = 0
    }

    private let state = Mutex(State())

    /// Registers a new instance; returns its id, an index in creation order.
    func register(initSeconds: Double) -> Int {
        state.withLock { state in
            state.initTimes.append(initSeconds)
            return state.initTimes.count
        }
    }

    func record(_ event: RequestEvent) {
        let waiter = state.withLock { state -> Waiter? in
            state.events.append(event)
            guard let waiter = state.waiter, event.start >= waiter.after else { return nil }
            state.waiter = nil
            return waiter
        }
        waiter?.continuation.resume(returning: event)
    }

    var instanceCount: Int { state.withLock { $0.initTimes.count } }
    var initTimes: [Double] { state.withLock { $0.initTimes } }
    var eventCount: Int { state.withLock { $0.events.count } }

    /// The events recorded after the first `count` of them.
    func events(after count: Int) -> [RequestEvent] {
        state.withLock { Array($0.events.dropFirst(count)) }
    }

    func events(instance: Int) -> [RequestEvent] {
        state.withLock { $0.events.filter { $0.instance == instance } }
    }

    func events(instance: Int, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> [RequestEvent] {
        state.withLock { $0.events.filter { $0.instance == instance && $0.start >= start && $0.start <= end } }
    }

    /// The first request that starts after `after`, or nil when none does
    /// within `timeout`.
    func nextEvent(after: ContinuousClock.Instant, timeout: Duration) async -> RequestEvent? {
        if let already = state.withLock({ $0.events.first { $0.start >= after } }) { return already }
        let generation = state.withLock { state in
            state.generation += 1
            return state.generation
        }
        return await withCheckedContinuation { continuation in
            let pending = state.withLock { state -> RequestEvent? in
                if let already = state.events.first(where: { $0.start >= after }) { return already }
                state.waiter = Waiter(generation: generation, after: after, continuation: continuation)
                return nil
            }
            if let pending {
                continuation.resume(returning: pending)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let waiter = state.withLock { state -> Waiter? in
                    guard let waiter = state.waiter, waiter.generation == generation else { return nil }
                    state.waiter = nil
                    return waiter
                }
                waiter?.continuation.resume(returning: nil)
            }
        }
    }
}

/// `MetalCompositor` with a stopwatch around each request: the engine
/// instantiates this class in place of the product's, every call is
/// forwarded, and the start and finish of each request go to the registry.
final class TimedCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let inner: MetalCompositor
    let id: Int

    override init() {
        let started = ContinuousClock.now
        inner = MetalCompositor()
        id = TimedCompositorRegistry.shared.register(initSeconds: PlayerSpike.seconds(since: started))
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? { inner.sourcePixelBufferAttributes }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        inner.requiredPixelBufferAttributesForRenderContext
    }

    var supportsWideColorSourceFrames: Bool { inner.supportsWideColorSourceFrames }

    var supportsHDRSourceFrames: Bool { inner.supportsHDRSourceFrames }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        inner.renderContextChanged(newRenderContext)
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let start = ContinuousClock.now
        let failures = inner.statistics.failures
        inner.startRequest(request)
        let end = ContinuousClock.now
        TimedCompositorRegistry.shared.record(
            RequestEvent(
                instance: id, start: start, end: end, compositionTime: request.compositionTime.seconds,
                failed: inner.statistics.failures > failures))
    }

    func cancelAllPendingVideoCompositionRequests() {
        inner.cancelAllPendingVideoCompositionRequests()
    }

    /// The style the item's current composition renders with, from its
    /// first instruction, so the export half of the match pass draws the
    /// same look the preview was last given. `videoComposition` is
    /// main-actor isolated in this SDK's overlay.
    @MainActor
    func style(of item: AVPlayerItem) -> RenderStyle? {
        (item.videoComposition?.instructions.first as? RenderInstruction)?.style
    }
}

// MARK: - Window

/// The window the composition plays in: a layer-backed view whose layer is
/// the `AVPlayerLayer`, at a fixed size so nothing sizes itself from
/// content (PLAN M1-F6).
@MainActor
private final class PlayerWindow {
    let window: NSWindow
    let playerLayer = AVPlayerLayer()

    init(size: NSSize) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered,
            defer: false)
        window.title = "Cutscene player spike"
        window.isReleasedWhenClosed = false
        window.level = .floating
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        view.layer = playerLayer
        view.autoresizingMask = [.width, .height]
        window.contentView = view
    }

    var windowNumber: Int { window.windowNumber }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}
