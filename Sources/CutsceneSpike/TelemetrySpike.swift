import CoreGraphics
import CoreMedia
import CutsceneCapture
import CutsceneCore
import Foundation

/// Proves the telemetry path without any permission: records the main display
/// for a few seconds through `InputTelemetryRecorder` on a `RecordingClock`,
/// pausing the clock once so the pause handling is on the test, then checks
/// the poll rate, the time bounds of every event, the incremental sidecar and
/// the persisted file. The event tap is installed only if Input Monitoring is
/// already granted; nothing here prompts.
enum TelemetrySpike {
    static let defaultSeconds = 3.0
    /// Below this the poll is not delivering the cadence the smoothing spring
    /// is tuned for; the nominal rate is 125 Hz.
    static let minimumRateHz = 100.0
    /// Halfway through, the clock pauses this long.
    static let pauseSeconds = 0.5
    /// Slack for an event stamped by the last tick before `stop` took effect.
    static let timeTolerance = 0.05
    /// Flushes come this often, so even a short run exercises the sidecar.
    static let persistenceInterval = 0.5

    static func run(arguments: [String]) async -> Bool {
        var seconds = defaultSeconds
        var outputURL: URL?
        if let first = arguments.first {
            guard let value = Double(first), value > 0 else {
                print("unknown argument \(first); expected a duration in seconds")
                return false
            }
            seconds = value
        }
        if arguments.count > 1 {
            outputURL = URL(fileURLWithPath: arguments[1])
        }
        if arguments.count > 2 {
            print("too many arguments; expected [seconds] [outputPath]")
            return false
        }
        do {
            return try await record(seconds: seconds, outputURL: outputURL)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return false
        }
    }

    private static func record(seconds: Double, outputURL: URL?) async throws -> Bool {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let scale = pointPixelScale(of: displayID)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let url =
            outputURL
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cutscene-spike", isDirectory: true)
            .appendingPathComponent("telemetry-\(stamp).json")
        let sidecarURL = InputTelemetryRecorder.sidecarURL(for: url)
        let granted = InputTelemetryRecorder.isInputMonitoringGranted
        print(
            "telemetry spike: display \(displayID), \(Int(bounds.width))×\(Int(bounds.height)) pt at \(scale)×, "
                + "\(seconds) s with a \(pauseSeconds) s pause halfway; input monitoring "
                + (granted ? "granted, event tap on" : "not granted, tap skipped and buttons polled")
                + " (nothing here prompts)")

        let clock = RecordingClock()
        let recorder = InputTelemetryRecorder(
            displayBounds: bounds,
            captureRectPoints: PointRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
            displayID: displayID, pointPixelScale: scale, persistenceURL: url,
            persistenceInterval: persistenceInterval)
        recorder.start(clock: clock)
        try await Task.sleep(for: .seconds(seconds / 2))
        clock.pause()
        try await Task.sleep(for: .seconds(pauseSeconds))
        clock.resume()
        try await Task.sleep(for: .seconds(seconds / 2))
        // What a crash at this moment would leave behind: the header plus the
        // sidecar must rebuild a prefix of the log `stop` returns.
        let recovered = try InputTelemetryRecorder.recoverLog(persistenceURL: url)
        let sidecarBytes = (try? FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? Int64) ?? 0
        let log = recorder.stop()
        clock.stop()
        let statistics = recorder.statistics
        let sprites = recorder.sprites()

        var counts: [String: Int] = [:]
        for event in log.events {
            counts[kind(of: event), default: 0] += 1
        }
        print(
            "events: \(log.events.count) total; "
                + kinds.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", "))
        print(
            "sampling: \(statistics.samplerTicks) ticks in \(String(format: "%.3f", statistics.activeSeconds)) s active "
                + "= \(String(format: "%.1f", statistics.measuredSamplingRateHz)) Hz "
                + "(nominal \(String(format: "%.0f", log.samplingRateHz)) Hz); event tap "
                + (statistics.eventTapActive ? "active, \(statistics.eventTapReenables) re-enables" : "off"))
        print(
            "clock: recorded \(String(format: "%.3f", clock.elapsed.seconds)) s of "
                + "\(String(format: "%.3f", seconds + pauseSeconds)) s wall, \(clock.completedPauses) pause")
        if let last = log.events.last(where: { $0.position != nil })?.position {
            print("pointer: last position (\(String(format: "%.4f", last.x)), \(String(format: "%.4f", last.y)))")
        }
        print("cursor: \(sprites.count) distinct shapes")
        for event in log.events {
            guard case .cursorShapeChanged(let time, let shape) = event else { continue }
            print(
                "  \(String(format: "%.3f", time)) s: \(shape.id) \(shape.sizePoints.width)×\(shape.sizePoints.height) pt, "
                    + "hotspot (\(String(format: "%.2f", shape.hotspot.x)), \(String(format: "%.2f", shape.hotspot.y))), "
                    + "sprite \(sprites[shape.id]?.count ?? 0) bytes PNG")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        print(
            "persisted: \(url.path) (\(size) bytes, \(statistics.persistedWrites) writes, "
                + "\(statistics.persistenceFailures) failures); sidecar held \(sidecarBytes) bytes and "
                + "\(recovered.events.count) events before stop")

        var failures: [String] = []
        if statistics.measuredSamplingRateHz < minimumRateHz {
            failures.append(
                "sampling rate \(String(format: "%.1f", statistics.measuredSamplingRateHz)) Hz < \(minimumRateHz) Hz")
        }
        if statistics.persistenceFailures > 0 {
            failures.append("persistence failed: \(statistics.lastPersistenceError ?? "unknown error")")
        }
        do {
            let persisted = try EventLog.read(from: url)
            if persisted != log { failures.append("the persisted log differs from the one `stop` returned") }
        } catch {
            failures.append("could not read the persisted log back: \(error.localizedDescription)")
        }
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            failures.append("the sidecar \(sidecarURL.lastPathComponent) survived stop")
        }
        if statistics.persistedWrites < 2 {
            failures.append("only \(statistics.persistedWrites) flushes; the incremental path did not run")
        }
        if recovered.events.isEmpty {
            failures.append("recovery from the header and sidecar produced no events")
        } else if !recovered.events.allSatisfy({ log.events.contains($0) }) {
            failures.append("the recovered log holds events the final log does not")
        } else if recovered.startHostTimeSeconds != log.startHostTimeSeconds {
            failures.append("the recovered log's origin differs from the final log's")
        }
        let limit = statistics.activeSeconds + timeTolerance
        if let stray = log.events.first(where: { $0.time < 0 || $0.time > limit }) {
            failures.append(
                "event at \(stray.time) s lies outside 0...\(String(format: "%.3f", limit)) s of active time")
        }
        if abs(statistics.activeSeconds - seconds) > 0.1 {
            failures.append(
                "active time \(String(format: "%.3f", statistics.activeSeconds)) s is not the \(seconds) s "
                    + "outside the pause")
        }
        if log.events.count < 2 {
            failures.append("only \(log.events.count) events; expected at least the first pointer and cursor samples")
        }
        if failures.isEmpty {
            print("PASS")
            return true
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return false
    }

    /// Pixels per point of the display's current mode; 1 when unknown.
    private static func pointPixelScale(of displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    private static let kinds = [
        "pointerMoved", "buttonDown", "buttonUp", "keyDown", "keyUp", "cursorShapeChanged", "takeMarker", "scroll",
        "focus", "geometry", "unknown",
    ]

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
        case .unknown: "unknown"
        }
    }
}
