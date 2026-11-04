import AVFoundation
import AppKit
import CutsceneCapture
import CutsceneCore
import CutsceneEngine
import CutsceneExport
import CutsceneRender
import Foundation
import Synchronization

/// Why a take could not be rendered.
enum AutoRenderError: LocalizedError {
    /// The package has no recorded duration and no playable movie.
    case nothingToRender(URL)

    var errorDescription: String? {
        switch self {
        case .nothingToRender(let url): "\(url.lastPathComponent) holds nothing to render."
        }
    }
}

/// The numbers the auto-render is tuned with.
struct AutoRenderSettings: Sendable, Equatable {
    /// What a package without a readable `project.json` renders with: the
    /// built-in kit and the ARCHITECTURE §6 default export, 1080p60 H.264.
    /// A package the session wrote always has one; a synthetic one may not.
    var fallbackKit = BrandKit.default
    var fallbackExport = ExportSettings()
    /// The writer's knobs: offline encoding, 2 s keyframes, faststart, AAC
    /// at 192 kbps, the self-check and the disk guard.
    var writer = ExportWriterSettings()
    /// Whether the finished movie is opened in the default player at once.
    /// Off, since a take ends with the user mid-sentence; the menu's Open
    /// Last Export reaches the file through `onExportComplete`.
    var opensExportWhenDone = false
}

/// What a package is rendered with, from its `project.json`.
struct RenderLook: Sendable, Equatable {
    var kit: BrandKit
    var export: ExportSettings
    /// Where the look came from, for the report.
    var source: String
}

/// Renders every finished take (PLAN M1-13), as `RecorderController.renderer`:
/// the plan from the package's event log with its project's style, the
/// whole recording as the one kept range, and the `Exporter` with the
/// project's preset, 1080p60 H.264 unless the project says otherwise, into
/// the exports folder. Progress reaches the controller, which the menu
/// shows as "Rendering… N %", and the finished file reaches the menu's Open
/// Last Export through `onExportComplete`.
///
/// `render` is nonisolated, so although the controller calls it from the
/// main actor it runs on the global executor: the event log is read and the
/// plan built off the main actor, and the menu stays responsive through a
/// long take's plan. The same job construction serves the recovery flow and
/// the verification harness through `job(for:manifest:destination:settings:)`.
/// One render at a time: the controller and the recovery flow never render
/// together (`AppModel.isBusy`), so `cancel()` ends the one in flight.
final class AutoRender: TakeRenderer {
    let settings: AutoRenderSettings
    /// Where exports go, read when a render starts, so a folder changed in
    /// Settings applies from the next take on.
    let destination: @MainActor @Sendable () -> URL
    /// The export in flight, for `cancel()`.
    private let current = Mutex<Exporter?>(nil)

    init(settings: AutoRenderSettings = AutoRenderSettings(), destination: @escaping @MainActor @Sendable () -> URL) {
        self.settings = settings
        self.destination = destination
    }

    func render(
        package: RecordingPackage, manifest: RecordingManifest, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let directory = await destination()
        let job = try await Self.job(for: package, manifest: manifest, destination: directory, settings: settings)
        let exporter = Exporter(settings: settings.writer)
        current.withLock { $0 = exporter }
        defer { current.withLock { $0 = nil } }
        let result = try await exporter.export(job) { progress($0.fraction) }
        if settings.opensExportWhenDone {
            let url = result.outputURL
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        return result.outputURL
    }

    func cancel() async {
        guard let exporter = current.withLock({ $0 }) else { return }
        await exporter.cancel()
    }

    /// The export job for `package`: its look, its plan over the recorded
    /// duration (the movie's when the manifest has none) and the whole
    /// recording as one kept range, into `destination` under the package's
    /// name. Static and nonisolated so a caller on any actor gets the plan
    /// built off it.
    static func job(
        for package: RecordingPackage, manifest: RecordingManifest, destination: URL, settings: AutoRenderSettings
    ) async throws -> ExportJob {
        let look = look(of: package, settings: settings)
        let duration = try await duration(of: package, manifest: manifest)
        guard duration > 0 else { throw AutoRenderError.nothingToRender(package.url) }
        let log = try eventLog(of: package, manifest: manifest)
        let plan = RenderPlan.build(log: log, duration: duration, kit: look.kit)
        let preset = try ExportPreset.resolve(look.export)
        return ExportJob(
            package: package, keptRanges: [0...duration], plan: plan, kit: look.kit, preset: preset,
            audio: look.export.audio, destinationDirectory: destination)
    }

    /// The project's `style` and export settings, or the fallbacks when the
    /// package has no project this build can read: a render must not fail
    /// on a stray project file when the recording itself is fine.
    static func look(of package: RecordingPackage, settings: AutoRenderSettings) -> RenderLook {
        guard FileManager.default.fileExists(atPath: package.projectURL.path) else {
            return RenderLook(
                kit: settings.fallbackKit, export: settings.fallbackExport,
                source: "built-in defaults (no project.json)")
        }
        do {
            let project = try Project.read(from: package.projectURL)
            return RenderLook(kit: project.style, export: project.export, source: "project.json")
        } catch {
            return RenderLook(
                kit: settings.fallbackKit, export: settings.fallbackExport,
                source: "built-in defaults (project.json: \(error.localizedDescription))")
        }
    }

    /// The manifest's duration, or the movie's when the manifest carries
    /// none or nothing positive.
    static func duration(of package: RecordingPackage, manifest: RecordingManifest) async throws -> Double {
        if let recorded = manifest.duration, recorded.isFinite, recorded > 0 { return recorded }
        guard FileManager.default.fileExists(atPath: package.screenMovieURL.path) else { return 0 }
        let seconds = try await AVURLAsset(url: package.screenMovieURL).load(.duration).seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    /// The package's log, or an empty one when it has none: a recovered
    /// take whose telemetry never reached the disk still renders, without
    /// cursor or zoom.
    static func eventLog(of package: RecordingPackage, manifest: RecordingManifest) throws -> EventLog {
        guard FileManager.default.fileExists(atPath: package.eventsURL.path) else {
            return RecoveryScanner.emptyEventLog(
                for: manifest, samplingRateHz: RecoveryScannerSettings().fallbackSamplingRateHz)
        }
        return try package.eventLog()
    }
}
