import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCapture
import CutsceneCore
import Foundation
import ScreenCaptureKit

/// Permission states and stream configuration (PLAN M1-06).
///
/// Prints where the four capabilities stand for this process, through
/// preflights that never prompt. `--config W H scale` resolves the §2 display
/// configuration for a synthetic display of W×H points at the given scale,
/// prints every value read back from the `SCStreamConfiguration` and checks
/// each against the architecture. `--content` lists the displays and windows
/// ScreenCaptureKit offers and resolves the main display's stream for real;
/// that path needs Screen Recording and exits 3 without it, before any
/// ScreenCaptureKit call.
enum PermissionsSpike {
    /// Stands in for a real microphone so the microphone path of the
    /// configuration resolves on a machine with no grant.
    static let syntheticMicrophoneID = "spike-microphone"
    /// Windows listed under `--content`, so a busy desktop stays readable.
    static let listedWindowLimit = 12
    /// Column the deep link starts in, so the four rows line up.
    static let stateColumnWidth = 22
    /// A window and an area that need no real content to reach the refusal.
    static let probeWindowID: CGWindowID = 1
    static let probeAreaSide = 100.0

    static func run(arguments: [String]) async -> Bool {
        var syntheticDisplay: DisplayGeometry?
        var listContent = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--config":
                guard index + 3 < arguments.count,
                    let width = Int(arguments[index + 1]), let height = Int(arguments[index + 2]),
                    let scale = Double(arguments[index + 3]), width > 0, height > 0, scale > 0
                else {
                    print("--config needs W H scale, all positive, e.g. --config 3024 1964 2")
                    return false
                }
                syntheticDisplay = DisplayGeometry(
                    displayID: CGMainDisplayID(), widthPoints: width, heightPoints: height, pointPixelScale: scale)
                index += 4
            case "--content":
                listContent = true
                index += 1
            default:
                print("unknown argument \(arguments[index]); expected [--config W H scale] [--content]")
                return false
            }
        }

        // The baseline for the relaunch rule is taken here, as the app takes
        // it at launch.
        let permissions = Permissions()
        print("permissions spike: four preflights, none of which prompts")
        let nameWidth = Capability.allCases.map(\.displayName.count).max() ?? 0
        for (capability, state) in permissions.preflightAll() {
            let name = capability.displayName.padding(toLength: nameWidth + 1, withPad: " ", startingAt: 0)
            let column = state.rawValue.padding(toLength: stateColumnWidth, withPad: " ", startingAt: 0)
            print("  \(name) \(column) \(capability.settingsURL)")
        }

        var failures: [String] = []
        if let syntheticDisplay {
            failures += checkConfiguration(display: syntheticDisplay)
        }
        if listContent {
            do {
                failures += try await checkContent(permissions: permissions)
            } catch {
                failures.append("content: \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    // MARK: Configuration

    /// Resolves the M1 request (system audio on, microphone on) for `display`,
    /// prints the configuration read back from ScreenCaptureKit's object, and
    /// returns what differs from ARCHITECTURE §2.
    private static func checkConfiguration(display: DisplayGeometry) -> [String] {
        var failures: [String] = []
        let request = CaptureRequest(
            source: .display(display.displayID), microphoneID: syntheticMicrophoneID, systemAudio: true)
        print(
            "configuration for a synthetic display \(display.widthPoints)×\(display.heightPoints) pt at "
                + "\(display.pointPixelScale)× (id \(display.displayID)); request: \(request.frameRate) fps, "
                + "system audio on, microphone \"\(syntheticMicrophoneID)\", menu bar "
                + (request.includeMenuBar ? "included" : "excluded"))
        let summary: StreamSummary
        let geometry: CaptureGeometry
        do {
            summary = StreamConfigurationBuilder.summary(
                of: try StreamConfigurationBuilder.configuration(for: request, display: display))
            geometry = try StreamConfigurationBuilder.geometry(for: request, display: display)
        } catch {
            return ["configuration: \(error.localizedDescription)"]
        }
        for line in summary.description.split(separator: "\n") {
            print("  \(line)")
        }
        print(
            "geometry: captureRect (\(geometry.captureRectPoints.x), \(geometry.captureRectPoints.y), "
                + "\(geometry.captureRectPoints.width), \(geometry.captureRectPoints.height)) pt, "
                + "scale \(geometry.pointPixelScale)×, output \(geometry.outputWidth)×\(geometry.outputHeight) px, "
                + "display \(geometry.displayID)")

        let expectedWidth = Int((Double(display.widthPoints) * display.pointPixelScale).rounded(.down)) & ~1
        let expectedHeight = Int((Double(display.heightPoints) * display.pointPixelScale).rounded(.down)) & ~1
        func expect(_ condition: Bool, _ what: String) {
            if !condition { failures.append(what) }
        }
        expect(summary.width == expectedWidth && summary.height == expectedHeight, "size is not the even pixel size")
        expect(
            geometry.outputWidth == summary.width && geometry.outputHeight == summary.height, "geometry size differs")
        expect(
            geometry.captureRectPoints
                == PointRect(x: 0, y: 0, width: Double(display.widthPoints), height: Double(display.heightPoints)),
            "capture rect is not the whole display")
        expect(geometry.pointPixelScale == display.pointPixelScale, "scale was not carried")
        expect(summary.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "pixel format is not 420v")
        expect(summary.pixelFormatName == "420v", "pixel format name is not 420v")
        expect(summary.colorSpaceName == CGColorSpace.sRGB as String, "colour space is not sRGB")
        expect(summary.colorMatrix == CGDisplayStream.yCbCrMatrix_ITU_R_709_2 as String, "matrix is not 709")
        expect(!summary.showsCursor, "cursor is shown")
        expect(!summary.showMouseClicks, "mouse clicks are shown")
        expect(summary.captureResolution == .best, "resolution is not .best")
        expect(summary.captureDynamicRange == .SDR, "dynamic range is not .SDR")
        expect(summary.queueDepth == request.stream.queueDepth, "queue depth is not \(request.stream.queueDepth)")
        expect(
            summary.minimumFrameInterval == CMTime(value: 1, timescale: CMTimeScale(request.frameRate)),
            "frame interval is not 1/\(request.frameRate)")
        expect(summary.presenterOverlayPrivacyAlertSetting == .never, "presenter overlay alert is not .never")
        expect(summary.capturesAudio, "system audio is off")
        expect(summary.excludesCurrentProcessAudio, "our own audio is not excluded")
        expect(
            summary.sampleRate == request.stream.audioSampleRate, "sample rate is not \(request.stream.audioSampleRate)"
        )
        expect(
            summary.channelCount == request.stream.audioChannelCount,
            "channels are not \(request.stream.audioChannelCount)")
        expect(summary.captureMicrophone, "microphone is off")
        expect(summary.microphoneCaptureDeviceID == syntheticMicrophoneID, "microphone device is not the requested one")

        // The defaults: no audio of either kind until the user turns it on.
        let defaults = CaptureRequest(source: .display(display.displayID))
        do {
            let quiet = StreamConfigurationBuilder.summary(
                of: try StreamConfigurationBuilder.configuration(for: defaults, display: display))
            print(
                "defaults (system audio off, no microphone): capturesAudio \(quiet.capturesAudio), "
                    + "captureMicrophone \(quiet.captureMicrophone), microphoneCaptureDeviceID "
                    + (quiet.microphoneCaptureDeviceID.map { "\"\($0)\"" } ?? "nil"))
            expect(!quiet.capturesAudio && !quiet.captureMicrophone, "the default request captures audio")
            expect(quiet.microphoneCaptureDeviceID == nil, "the default request names a microphone")
        } catch {
            failures.append("default configuration: \(error.localizedDescription)")
        }

        // Since M2-06 an area resolves to a source rect of its own size, and
        // a window request without the window's geometry is refused as not
        // found rather than guessed.
        let rect = PointRect(x: 0, y: 0, width: probeAreaSide, height: probeAreaSide)
        do {
            let area = try StreamConfigurationBuilder.configuration(
                for: CaptureRequest(source: .area(displayID: display.displayID, rect: rect)), display: display)
            let summary = StreamConfigurationBuilder.summary(of: area)
            expect(
                summary.sourceRect == rect && summary.width == Int(probeAreaSide * display.pointPixelScale),
                "the area resolves to its own rect: \(summary.sourceRect.map { "\($0)" } ?? "none"), \(summary.width) px"
            )
            print(
                "area capture: sourceRect \(rect.width)×\(rect.height) pt, output \(summary.width)×\(summary.height) px"
            )
        } catch {
            failures.append("area capture failed with \(error.localizedDescription)")
        }
        do {
            _ = try StreamConfigurationBuilder.configuration(
                for: CaptureRequest(source: .window(probeWindowID)), display: display)
            failures.append("a window request resolved without the window's geometry")
        } catch StreamConfigurationError.windowNotFound(let id) {
            print("window capture: refused as windowNotFound(\(id)) without the window's geometry")
        } catch {
            failures.append("window capture failed with \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: Content

    /// Lists what ScreenCaptureKit offers and resolves the main display's
    /// stream through the real content. Exits 3 unless Screen Recording is
    /// granted to this process, before any ScreenCaptureKit call.
    private static func checkContent(permissions: Permissions) async throws -> [String] {
        let state = permissions.preflight(.screenRecording)
        guard state == .granted else {
            print("skipped: Screen Recording not granted to this terminal (\(state.rawValue))")
            exit(3)
        }
        var failures: [String] = []
        let content = try await ShareableContent.current(permissions: permissions)
        print(
            "content: \(content.displays.count) displays, \(content.windows.count) on-screen windows, "
                + "\(content.applications.count) applications; this process "
                + (content.currentApplication.map { "listed as \($0.applicationName) (\($0.bundleIdentifier))" }
                    ?? "not listed, nothing of ours to exclude"))
        for display in content.displaySummaries {
            print(
                "  display \(display.id): \(display.widthPoints)×\(display.heightPoints) pt at "
                    + "(\(Int(display.frame.minX)), \(Int(display.frame.minY)))\(display.isMain ? ", main" : "")")
        }
        for window in content.windowSummaries.prefix(listedWindowLimit) {
            print(
                "  window \(window.id): \"\(window.title ?? "")\" \(window.applicationName ?? "?") "
                    + "\(Int(window.frame.width))×\(Int(window.frame.height)) pt, layer \(window.layer)"
                    + (window.isActive ? ", active" : ""))
        }
        guard let main = content.mainDisplay else {
            return ["content: no display to resolve"]
        }
        let request = CaptureRequest(source: .display(main.displayID), systemAudio: true)
        let stream = try StreamConfigurationBuilder.build(request: request, content: content)
        print(
            "stream for display \(main.displayID): filter \(stream.filter.pointPixelScale)× over "
                + "\(Int(stream.filter.contentRect.width))×\(Int(stream.filter.contentRect.height)) pt, "
                + "menu bar \(stream.filter.includeMenuBar ? "included" : "excluded"); output "
                + "\(stream.geometry.outputWidth)×\(stream.geometry.outputHeight) px "
                + "at \(stream.geometry.pointPixelScale)×")
        for line in StreamConfigurationBuilder.summary(of: stream.configuration).description.split(separator: "\n") {
            print("  \(line)")
        }
        if stream.geometry.outputWidth != stream.configuration.width
            || stream.geometry.outputHeight != stream.configuration.height
        {
            failures.append("the live geometry and configuration disagree on the size")
        }
        if stream.filter.includeMenuBar != request.includeMenuBar {
            failures.append("includeMenuBar was not applied to the filter")
        }
        return failures
    }
}
