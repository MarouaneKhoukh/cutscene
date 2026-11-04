import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCore
import CutsceneEngine
import CutsceneRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Spike S2, reader half (PLAN M1-10): the composition path from a
/// `.cutscene` package through `CompositionBuilder`, an
/// `AVAssetReaderVideoCompositionOutput` and `MetalCompositor` at 60 fps.
///
/// `reader <package> [4k] [outputDir]` renders the whole recording, writes
/// eight evenly spaced frames as PNGs, and prints the frame count against
/// the constant-rate expectation, the compositor's request latency (median
/// and maximum), how many requests arrived without a source frame and what
/// they rendered instead, and whether any frame or card came out black. A
/// second pass cuts a hole into the video track of the same composition, so
/// the requests inside it have no source frame, and checks that they render
/// the last delivered frame rather than black. `reader --synthetic [4k]
/// [outputDir]` first fabricates a package with the `package` spike, so no
/// recording and no permission are needed. `4k` reads at 3840×2160, the
/// canvas ARCHITECTURE §5's request-latency trigger is measured on.
enum ReaderSpike {
    static let defaultOutputDirectory = ".build/reader-spike"
    static let defaultCanvas = CanvasSpec.hd1080p60
    static let largeCanvas = CanvasSpec.uhd2160p60
    static let pngCount = 8
    /// `frames = ⌈duration × fps⌉ ± 1` (PLAN M1-10).
    static let frameCountTolerance = 1
    /// One 60 fps interval: ARCHITECTURE §5 trips the v2 decoder when the
    /// median request exceeds it at 4K; at 1080p it is a sanity bound.
    static let maximumMedianLatencyMilliseconds = 16.7
    /// Output timestamps must step by exactly one frame; this absorbs the
    /// conversion of rational times to seconds.
    static let frameStepTolerance = 1e-6
    /// Pixels probed per frame for the black checks.
    static let probeColumns = 16
    static let probeRows = 9
    /// A probe whose brightest channel is below this is dark; the gradient's
    /// darkest corner is 28 and the synthetic desktop's darkest window 13.
    static let blackThreshold = 6
    /// Fraction of the card's width and height kept out of the card probes
    /// on each side, so the rounded corners and the shadow stay out.
    static let cardProbeInset = 0.1
    /// A frame is zoomed when the viewport shows less than this of the source.
    static let zoomedViewportWidth = 0.999
    /// The hold pass: an empty edit this long, this far into the recording
    /// (as a fraction of its duration), where the video track has no frame.
    static let holeSeconds = 0.5
    static let holeFraction = 0.3
    static let syntheticSeconds = 10.0

    static func run(arguments: [String]) async -> Bool {
        var rest = arguments
        var canvas = defaultCanvas
        if let index = rest.firstIndex(where: { $0.lowercased() == "4k" }) {
            canvas = largeCanvas
            rest.remove(at: index)
        }
        guard let first = rest.first, rest.count <= 2 else {
            print("usage: reader <package> [4k] [outputDir] | reader --synthetic [4k] [outputDir]")
            return false
        }
        let outputDirectory = URL(
            fileURLWithPath: rest.count > 1 ? rest[1] : defaultOutputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let package: RecordingPackage
            if first == "--synthetic" {
                let packageDirectory = outputDirectory.appendingPathComponent("package", isDirectory: true)
                guard await PackageSpike.run(arguments: [packageDirectory.path, "\(syntheticSeconds)"]) else {
                    print("FAIL: the package spike did not pass")
                    return false
                }
                package = try newestPackage(in: packageDirectory)
                print("")
            } else {
                package = try RecordingPackage.open(at: URL(fileURLWithPath: first))
            }
            return try await read(package: package, into: outputDirectory, canvas: canvas)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - The run

    private static func read(package: RecordingPackage, into directory: URL, canvas: CanvasSpec) async throws -> Bool {
        print("reader spike: \(package.url.path)")
        print(
            "GPU \(CutsceneRender.gpuName ?? "none"), canvas \(canvas.width)×\(canvas.height) @ \(canvas.frameRate), "
                + "output \(directory.path)")
        let manifest = try package.manifest()
        let log = try package.eventLog()
        // A take that never reached stop has no recorded duration; the movie's is the next best.
        let duration: Double
        if let recorded = manifest.duration {
            duration = recorded
        } else {
            duration = try await AVURLAsset(url: package.screenMovieURL).load(.duration).seconds
        }
        let shapeIDs = Set(
            log.events.compactMap { event -> String? in
                if case .cursorShapeChanged(_, let shape) = event { return shape.id }
                return nil
            })
        print(
            "recording: \(manifest.screen.width)×\(manifest.screen.height) \(manifest.screen.codec), "
                + "\(format(duration)) s, \(manifest.source.label.lowercased()), "
                + "\(manifest.screen.audioTracks.count) audio tracks, "
                + "capture \(format(manifest.content.captureRectPoints.width))×"
                + "\(format(manifest.content.captureRectPoints.height)) pt; "
                + "\(log.events.count) events, cursor shapes \(shapeIDs.sorted())")

        let clock = ContinuousClock()
        var built: RenderPlan?
        let planTime = clock.measure { built = RenderPlan.build(log: log, duration: duration) }
        guard let plan = built else { return false }
        let zooms = plan.zoomSegments.map {
            "\(format($0.start))–\(format($0.end)) s ×\(String(format: "%.1f", $0.amount)) "
                + "@ (\(String(format: "%.2f", $0.focus.x)), \(String(format: "%.2f", $0.focus.y)))"
        }
        print(
            "plan: \(plan.cursor.samples.count) cursor samples @ \(Int(plan.cursor.sampleRate)) Hz, "
                + "\(plan.camera.samples.count) camera samples @ \(Int(plan.camera.sampleRate)) Hz, "
                + "\(plan.cursorShapeChanges.count) shape changes, zoom [\(zooms.joined(separator: "; "))], "
                + "built in \(milliseconds(planTime)) ms")

        let atlas = CursorAtlas.load(for: plan, in: package)
        let sprites = atlas.shapes.sorted { $0.id < $1.id }.map { shape in
            let sprite = atlas.sprite(for: shape)
            return "\(shape.id) \(sprite.image.width)×\(sprite.image.height) px for "
                + "\(format(shape.sizePoints.width))×\(format(shape.sizePoints.height)) pt"
        }
        print("atlas: \(atlas.count) sprites [\(sprites.joined(separator: ", "))], fallbacks \(atlas.missingShapeIDs)")

        var style = RenderStyle()
        style.outputWidth = canvas.width
        style.outputHeight = canvas.height
        var composition: BuiltComposition?
        let buildTime = try await clock.measure {
            composition = try await CompositionBuilder.build(
                package: package, keptRanges: [0...duration], plan: plan, style: style, cursor: atlas, canvas: canvas)
        }
        guard let composition else { return false }
        let expected = composition.expectedFrameCount
        let videoTracks = try await composition.composition.loadTracks(withMediaType: .video)
        print(
            "composition: duration \(format(composition.duration.seconds)) s, \(expected) frames expected, "
                + "\(composition.instructions.count) instruction(s), screen track \(composition.screenTrackID), "
                + "audio mix \(composition.audioMix?.inputParameters.count ?? 0) track(s), "
                + "built in \(milliseconds(buildTime)) ms")
        print("video segments: \(try await describeSegments(of: videoTracks.first))")

        // Pass 1: the recording as it is, eight PNGs along the way.
        var failures: [String] = []
        var pngs: [PNGReport] = []
        let cardRect = cardProbeRect(style: style, canvas: canvas)
        let result = try await readFrames(
            composition.composition, videoComposition: composition.videoComposition, cardRect: cardRect
        ) {
            index, time, buffer, probes in
            guard index % max(expected / pngCount, 1) == 0, pngs.count < pngCount else { return }
            let name = String(format: "frame-%02d.png", pngs.count)
            try writePNG(buffer, to: directory.appendingPathComponent(name))
            pngs.append(
                PNGReport(
                    name: name, frame: index, time: time, state: plan.frameState(at: time),
                    cardIsBlack: probes.cardIsBlack))
        }
        print(
            "read \(result.frames) frames in \(format(result.wallSeconds)) s: "
                + "\(String(format: "%.1f", Double(result.frames) / max(result.wallSeconds, 1e-9))) fps, "
                + "\(String(format: "%.2f", composition.duration.seconds / max(result.wallSeconds, 1e-9)))× real time")
        let missing = result.compositor?.missingSourceFrames ?? []
        for png in pngs {
            let amount = 1 / max(png.state.viewport.size.width, 1e-9)
            let cursor =
                png.state.cursor.map {
                    "cursor (\(String(format: "%.3f", $0.smoothedPosition.x)), "
                        + "\(String(format: "%.3f", $0.smoothedPosition.y)))" + ($0.isPressed ? " pressed" : "")
                        + " opacity \(String(format: "%.2f", $0.opacity))"
                } ?? "no cursor"
            let source =
                missing.first { abs($0.compositionTime - png.time) < frameStepTolerance }
                .map { $0.usedHeldFrame ? "  held frame" : "  blank (no frame yet)" } ?? ""
            print(
                "\(png.name)  frame \(png.frame)  t \(format(png.time)) s  zoom \(String(format: "%.2f", amount))× "
                    + "origin (\(String(format: "%.3f", png.state.viewport.origin.x)), "
                    + "\(String(format: "%.3f", png.state.viewport.origin.y)))  \(cursor)  "
                    + "shape \(png.state.cursorShape?.id ?? "none")\(source)" + (png.cardIsBlack ? "  BLACK CARD" : ""))
        }
        report(result, label: "compositor", failures: &failures)
        if let first = missing.first, let last = missing.last {
            let held = missing.filter(\.usedHeldFrame).count
            print(
                "requests without a source frame: \(missing.count) (\(held) held, \(missing.count - held) blank), "
                    + "\(format(first.compositionTime))–\(format(last.compositionTime)) s")
        } else {
            print("requests without a source frame: none")
        }
        print("black frames \(result.blackFrames), black cards \(result.blackCards)")
        check(result, expected: expected, canvas: canvas, label: "pass 1", failures: &failures)
        if pngs.count < pngCount { failures.append("only \(pngs.count) PNGs written") }
        if !pngs.contains(where: { $0.state.viewport.size.width < zoomedViewportWidth }) {
            failures.append("no PNG shows a zoomed frame")
        }
        if !atlas.missingShapeIDs.isEmpty {
            failures.append("cursor sprites missing for \(atlas.missingShapeIDs) (M1-F1)")
        }
        let captured = pngs.filter { atlas.sprite(for: $0.state.cursorShape) !== atlas.fallback }.count
        print("PNGs drawn with a captured sprite: \(captured) of \(pngs.count)")

        // Pass 2: a hole in the video track, where every request has no
        // source frame and must render the held one.
        print("")
        try await holdPass(
            composition, videoTrack: videoTracks.first, plan: plan, style: style, atlas: atlas, manifest: manifest,
            cardRect: cardRect, canvas: canvas, directory: directory, failures: &failures)

        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    /// Cuts `holeSeconds` of empty edit into the video track at
    /// `holeFraction` of the recording, re-covers the longer composition
    /// with one instruction, reads it again and checks that the frames in
    /// the hole were rendered from the held frame and are not black. The
    /// audio tracks are untouched, so the mapping to recording time drifts
    /// after the hole; only the hole matters here.
    private static func holdPass(
        _ composition: BuiltComposition, videoTrack: AVMutableCompositionTrack?, plan: RenderPlan, style: RenderStyle,
        atlas: CursorAtlas, manifest: RecordingManifest, cardRect: CGRect, canvas: CanvasSpec, directory: URL,
        failures: inout [String]
    ) async throws {
        guard let videoTrack else {
            failures.append("hold pass: the composition has no video track")
            return
        }
        let timescale = composition.duration.timescale
        let holeStart = CMTime(seconds: composition.duration.seconds * holeFraction, preferredTimescale: timescale)
        let hole = CMTimeRange(start: holeStart, duration: CMTime(seconds: holeSeconds, preferredTimescale: timescale))
        videoTrack.insertEmptyTimeRange(hole)
        let duration = try await composition.composition.load(.duration)
        let instruction = RenderInstruction(
            timeRange: CMTimeRange(start: .zero, end: duration), sourceStart: .zero,
            screenTrackID: composition.screenTrackID, plan: plan, style: style, cursorAtlas: atlas,
            sourceWidth: manifest.screen.width, sourceHeight: manifest.screen.height,
            capturePointSize: PointSize(
                width: manifest.content.captureRectPoints.width, height: manifest.content.captureRectPoints.height))
        composition.videoComposition.instructions = [instruction]
        let expected = canvas.frameCount(forDuration: duration.seconds)
        let holeFrames = (hole.start.seconds..<hole.end.seconds)
        print(
            "hold pass: empty edit \(format(hole.start.seconds))–\(format(hole.end.seconds)) s in the video track, "
                + "composition now \(format(duration.seconds)) s, \(expected) frames expected")
        print("video segments: \(try await describeSegments(of: videoTrack))")

        var holeBlackCards = 0
        var wrote = false
        let middle = (hole.start.seconds + hole.end.seconds) / 2
        let result = try await readFrames(
            composition.composition, videoComposition: composition.videoComposition, cardRect: cardRect
        ) {
            _, time, buffer, probes in
            guard holeFrames.contains(time) else { return }
            if probes.cardIsBlack { holeBlackCards += 1 }
            if !wrote, time >= middle {
                wrote = true
                try writePNG(buffer, to: directory.appendingPathComponent("frame-held.png"))
                print("frame-held.png  t \(format(time)) s, inside the hole")
            }
        }
        report(result, label: "hold pass compositor", failures: &failures)
        check(result, expected: expected, canvas: canvas, label: "hold pass", failures: &failures)
        let held =
            result.compositor?.missingSourceFrames.filter {
                $0.usedHeldFrame && holeFrames.contains($0.compositionTime)
            }.count ?? 0
        let holeCount = canvas.frameCount(forDuration: holeSeconds)
        print(
            "frames in the hole rendered from the held frame: \(held) of \(holeCount), black cards among them \(holeBlackCards)"
        )
        if abs(held - holeCount) > frameCountTolerance {
            failures.append(
                "hold pass: \(held) frames rendered from the held frame, expected \(holeCount) ± \(frameCountTolerance)"
            )
        }
        if holeBlackCards > 0 { failures.append("hold pass: \(holeBlackCards) black cards inside the hole") }
        if !wrote { failures.append("hold pass: no frame inside the hole") }
    }

    // MARK: - Reading

    private struct ReadResult {
        var frames = 0
        var times: [Double] = []
        var blackFrames = 0
        var blackCards = 0
        var wallSeconds = 0.0
        var compositor: MetalCompositor?
    }

    private struct PNGReport {
        var name: String
        var frame: Int
        var time: Double
        var state: FrameState
        var cardIsBlack: Bool
    }

    /// Pulls every frame of the composition through a BGRA video
    /// composition output, probing each and handing it to `onFrame`.
    private static func readFrames(
        _ composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, cardRect: CGRect,
        onFrame: (Int, Double, CVPixelBuffer, ProbeResult) throws -> Void
    ) async throws -> ReadResult {
        let reader = try AVAssetReader(asset: composition)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpikeError.reader("the reader refused the video composition output") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SpikeError.reader("startReading returned false without an error")
        }
        var result = ReadResult()
        result.compositor = output.customVideoCompositor as? MetalCompositor
        let started = ContinuousClock.now
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            result.times.append(time)
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw SpikeError.reader("frame \(result.frames) carries no image buffer")
            }
            let probes = try probe(buffer, cardRect: cardRect)
            if probes.frameIsBlack { result.blackFrames += 1 }
            if probes.cardIsBlack { result.blackCards += 1 }
            try onFrame(result.frames, time, buffer, probes)
            result.frames += 1
        }
        result.wallSeconds = seconds(since: started)
        guard reader.status == .completed else {
            throw reader.error ?? SpikeError.reader("the reader ended with status \(reader.status.rawValue)")
        }
        result.compositor?.flush()
        return result
    }

    private static func report(_ result: ReadResult, label: String, failures: inout [String]) {
        guard let compositor = result.compositor else {
            failures.append("\(label): the output's customVideoCompositor is not a MetalCompositor")
            return
        }
        let statistics = compositor.statistics
        let latencies = compositor.requestLatencies.sorted()
        let median = latencies.isEmpty ? 0 : median(latencies)
        print(
            "\(label): \(statistics.requests) requests, \(statistics.heldFrames) held, "
                + "\(statistics.blankFrames) blank (before the first frame), \(statistics.failures) failed; "
                + "latency median \(String(format: "%.2f", median * 1000)) ms, "
                + "p95 \(String(format: "%.2f", percentile(latencies, 0.95) * 1000)) ms, "
                + "mean \(String(format: "%.2f", statistics.meanLatencySeconds * 1000)) ms, "
                + "max \(String(format: "%.2f", statistics.maximumLatencySeconds * 1000)) ms "
                + "(budget \(maximumMedianLatencyMilliseconds) ms median); "
                + "warm-up \(statistics.warmUpSeconds.map { String(format: "%.1f", $0 * 1000) + " ms" } ?? "none"); "
                + "render context \(statistics.renderWidth)×\(statistics.renderHeight)")
        if statistics.failures > 0 { failures.append("\(label): \(statistics.failures) requests failed") }
        if statistics.requests < result.frames {
            failures.append("\(label): \(statistics.requests) requests for \(result.frames) frames")
        }
        if median * 1000 > maximumMedianLatencyMilliseconds {
            failures.append(
                "\(label): median request latency \(String(format: "%.2f", median * 1000)) ms "
                    + "> \(maximumMedianLatencyMilliseconds) ms")
        }
    }

    private static func check(
        _ result: ReadResult, expected: Int, canvas: CanvasSpec, label: String, failures: inout [String]
    ) {
        if abs(result.frames - expected) > frameCountTolerance {
            failures.append("\(label): \(result.frames) frames, expected \(expected) ± \(frameCountTolerance)")
        }
        if let first = result.times.first, abs(first) > frameStepTolerance {
            failures.append("\(label): the first frame is at \(format(first)) s, not 0")
        }
        let step = 1 / Double(canvas.frameRate)
        let irregular = zip(result.times.dropFirst(), result.times).filter {
            abs(($0 - $1) - step) > frameStepTolerance
        }
        if !irregular.isEmpty {
            failures.append("\(label): \(irregular.count) frame intervals differ from \(format(step)) s")
        }
        if result.blackFrames > 0 { failures.append("\(label): \(result.blackFrames) black frames") }
        if result.blackCards > 0 { failures.append("\(label): \(result.blackCards) frames with a black card") }
    }

    private static func describeSegments(of track: AVAssetTrack?) async throws -> String {
        guard let track else { return "none" }
        return try await track.load(.segments).map { segment in
            let target = segment.timeMapping.target
            let source = segment.timeMapping.source
            return segment.isEmpty
                ? "empty \(format(target.start.seconds))–\(format(target.end.seconds))"
                : "\(format(target.start.seconds))–\(format(target.end.seconds)) ← source "
                    + "\(format(source.start.seconds))–\(format(source.end.seconds))"
        }.joined(separator: " | ")
    }

    // MARK: - Probes

    /// The card's probe rectangle in output pixels: the compositor's layout
    /// (padding, aspect fit, centred) for a full-frame viewport of a source
    /// with the canvas's aspect, inset so the corners and the edge stay out.
    /// A zoomed viewport keeps the source's aspect, so the card does not move.
    private static func cardProbeRect(style: RenderStyle, canvas: CanvasSpec) -> CGRect {
        let padding = style.padding * Double(min(canvas.width, canvas.height))
        let width = Double(canvas.width) - 2 * padding
        let height = Double(canvas.height) - 2 * padding
        return CGRect(x: padding, y: padding, width: width, height: height)
            .insetBy(dx: width * cardProbeInset, dy: height * cardProbeInset)
    }

    private struct ProbeResult {
        var frameIsBlack: Bool
        var cardIsBlack: Bool
    }

    /// Samples a grid over the whole frame and one over the card.
    private static func probe(_ buffer: CVPixelBuffer, cardRect: CGRect) throws -> ProbeResult {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            return max(pixel[0], pixel[1], pixel[2]) < UInt8(blackThreshold)
        }
        func allDark(in rect: CGRect) -> Bool {
            for row in 0..<probeRows {
                for column in 0..<probeColumns {
                    let x = Int(rect.minX + rect.width * (Double(column) + 0.5) / Double(probeColumns))
                    let y = Int(rect.minY + rect.height * (Double(row) + 0.5) / Double(probeRows))
                    if !isDark(min(max(x, 0), width - 1), min(max(y, 0), height - 1)) { return false }
                }
            }
            return true
        }
        return ProbeResult(
            frameIsBlack: allDark(in: CGRect(x: 0, y: 0, width: width, height: height)),
            cardIsBlack: allDark(in: cardRect))
    }

    // MARK: - Output

    private static func writePNG(_ buffer: CVPixelBuffer, to url: URL) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError.pixelBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            for row in 0..<height {
                raw.baseAddress!.advanced(by: row * width * 4)
                    .copyMemory(from: base.advanced(by: row * bytesPerRow), byteCount: width * 4)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SpikeError.png(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpikeError.png(url.lastPathComponent) }
    }

    /// The package the `package` spike just wrote: names start with the
    /// take's timestamp, so the last in order is the newest.
    private static func newestPackage(in directory: URL) throws -> RecordingPackage {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".\(RecordingPackage.pathExtension)") }
            .sorted()
        guard let newest = names.last else { throw SpikeError.reader("no package in \(directory.path)") }
        return try RecordingPackage.open(at: directory.appendingPathComponent(newest))
    }

    // MARK: - Helpers

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(
            format: "%.1f", Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func median(_ sorted: [Double]) -> Double {
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
        case png(String)

        var errorDescription: String? {
            switch self {
            case .reader(let detail): "The asset reader failed: \(detail)."
            case .pixelBuffer: "A frame's pixel buffer could not be read."
            case .png(let name): "Could not write \(name)."
            }
        }
    }
}
