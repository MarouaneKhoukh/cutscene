import AVFoundation
import CoreMedia
import CutsceneCore
import Foundation

/// Why a package could not be finished or discarded.
public enum RecoveryError: LocalizedError, Sendable, Equatable {
    /// The fragmented movie could not be rewritten as an MP4. Its files are
    /// left as they were, so the next launch offers the take again and the
    /// user can still discard it.
    case finalizeFailed(movie: String, detail: String)
    /// The package could not be moved to the Trash (or deleted).
    case discardFailed(URL, detail: String)

    public var errorDescription: String? {
        switch self {
        case .finalizeFailed(let movie, let detail): "\(movie) could not be finalized: \(detail)"
        case .discardFailed(let url, let detail): "\(url.lastPathComponent) could not be discarded: \(detail)"
        }
    }
}

/// The numbers and places recovery works with.
public struct RecoveryScannerSettings: Sendable, Equatable {
    /// Folders scanned for packages, one level deep: a package is a direct
    /// child of its recordings folder, and `Exports/` holds no packages.
    public var directories: [URL]
    /// Whether `discard` moves the package to the Trash rather than deleting
    /// it: a take the user gives up on at launch is still a take.
    public var discardsToTrash: Bool
    /// The poll rate a synthesized log claims when the take died before its
    /// first telemetry flush, so no header exists to copy it from: the
    /// recorder's own.
    public var fallbackSamplingRateHz: Double
    /// The kit `project.json` is rebuilt with when the package has no
    /// readable project; the session writes the same one.
    public var kit: BrandKit
    /// A package whose marker names a process that is still running and
    /// whose fragmented movie changed within this many seconds is a take
    /// another process is recording right now (a second instance, the CLI),
    /// not one a crash left: it is skipped and reported. A live writer
    /// rewrites the movie every fragment, so the window is the longest
    /// fragment interval (external storage, 10 s) plus a margin.
    public var livenessWindow: TimeInterval
    /// How far a final manifest's `duration` may run past the movie's
    /// playable length before the manifest is rewritten to it: one audio
    /// buffer (21 ms at 48 kHz) and a little, which the export's self-check
    /// absorbs.
    public var playableDurationTolerance: Double

    public init(
        directories: [URL] = [RecordingPackage.defaultRecordingsDirectory], discardsToTrash: Bool = true,
        fallbackSamplingRateHz: Double = 1 / InputTelemetryRecorder.samplingInterval, kit: BrandKit = .default,
        livenessWindow: TimeInterval = RecordingWriter.externalVolumeFragmentInterval.seconds + 5,
        playableDurationTolerance: Double = 0.05
    ) {
        self.directories = directories
        self.discardsToTrash = discardsToTrash
        self.fallbackSamplingRateHz = fallbackSamplingRateHz
        self.kit = kit
        self.livenessWindow = livenessWindow
        self.playableDurationTolerance = playableDurationTolerance
    }
}

/// A package a killed process left behind, as the scan found it.
public struct RecoveryCandidate: Sendable, Equatable, Identifiable {
    public var id: URL { package.url }
    public let package: RecordingPackage
    /// The manifest as it is on disk; `inProgress` unless only a marker
    /// brought the package here.
    public let manifest: RecordingManifest
    /// Every `.needsFinalize` marker in `recording/`, in name order; each
    /// names a fragmented movie and the MP4 it was to become.
    public let markers: [NeedsFinalizeMarker]
    /// Bytes of `screen.mov`; 0 when there is none.
    public let fragmentedMovieBytes: Int64
    /// Whether `screen.mp4` already exists: the finalize completed and the
    /// crash came before the manifest was rewritten.
    public let hasFinalizedMovie: Bool
    /// Whether the telemetry wrote its header, so `recoverLog` has something
    /// to rebuild from.
    public let hasEventLogHeader: Bool
    /// Bytes of the events sidecar; 0 when there is none.
    public let eventsSidecarBytes: Int64

    public init(
        package: RecordingPackage, manifest: RecordingManifest, markers: [NeedsFinalizeMarker],
        fragmentedMovieBytes: Int64, hasFinalizedMovie: Bool, hasEventLogHeader: Bool, eventsSidecarBytes: Int64
    ) {
        self.package = package
        self.manifest = manifest
        self.markers = markers
        self.fragmentedMovieBytes = fragmentedMovieBytes
        self.hasFinalizedMovie = hasFinalizedMovie
        self.hasEventLogHeader = hasEventLogHeader
        self.eventsSidecarBytes = eventsSidecarBytes
    }

    /// Whether there is video to finish; without any, finishing only records the loss.
    public var hasMovie: Bool {
        fragmentedMovieBytes > 0 || hasFinalizedMovie
    }
}

/// A package the scan could not examine, left where it is.
public struct UnreadablePackage: Sendable, Hashable {
    public var url: URL
    public var detail: String

    public init(url: URL, detail: String) {
        self.url = url
        self.detail = detail
    }
}

/// What a scan found.
public struct RecoveryScanResult: Sendable, Equatable {
    /// Newest first.
    public var candidates: [RecoveryCandidate]
    public var unreadable: [UnreadablePackage]
    /// Packages another process is recording into right now
    /// (`RecoveryScannerSettings.livenessWindow`), left alone.
    public var inUse: [UnreadablePackage]

    public init(
        candidates: [RecoveryCandidate] = [], unreadable: [UnreadablePackage] = [], inUse: [UnreadablePackage] = []
    ) {
        self.candidates = candidates
        self.unreadable = unreadable
        self.inUse = inUse
    }
}

/// What finishing a package did, for the window and the report.
public struct RecoveryResult: Sendable, Equatable {
    public var package: RecordingPackage
    /// The manifest as rewritten: `recovered` with the playable duration, or
    /// `failed` when no video could be finished.
    public var manifest: RecordingManifest
    /// Seconds every track of `screen.mp4` covers; 0 when there is no movie.
    public var playableSeconds: Double
    /// File names of the movies finalized now.
    public var finalizedMovies: [String]
    /// Events in the log written back, from the header and sidecar or none
    /// when the log had to be synthesized.
    public var eventCount: Int
    public var logRecovered: Bool
    /// Lines of `frames.jsonl` after the header; nil when it could not be read.
    public var frameIndexLines: Int?
    /// Where the index was torn by the crash, if it was; the file is
    /// rewritten without the torn line.
    public var frameIndexTornAtLine: Int?
    /// Sprites in `cursors/`: none after a crash, since the session writes
    /// them at stop, so every shape renders as the arrow.
    public var cursorSpriteCount: Int
    public var elapsedSeconds: Double
    /// What did not go to plan but did not stop the recovery.
    public var notes: [String]
}

/// Finds the packages a killed process left behind and finishes them
/// (ARCHITECTURE §2 "Failure handling", §3): the `inProgress` manifest the
/// session writes before the stream starts, the `.needsFinalize` marker the
/// writer keeps beside the fragmented movie and the telemetry sidecar are
/// what a crash leaves, and together they say what to do.
///
/// Finishing mirrors the session's own stop in order: the movie first
/// (`RecordingWriter.finalize`, then the marker, then the fragmented
/// original, so an interrupted recovery is itself recoverable), the log
/// (`InputTelemetryRecorder.recoverLog`), the frame index, and last the
/// manifest, which is the commit point: a crash before it leaves the package
/// a candidate again, a crash after it leaves a complete package. The
/// recovered duration is the shortest track's end, not the video's: the
/// tracks end at their own last fragment, so a recovered audio track can be
/// up to a fragment shorter than the video (platform-notes, S1), and a
/// composition cut past the audio would fail the export's self-check.
///
/// Nothing here prompts; it reads and writes the user's own folders.
public enum RecoveryScanner {
    /// The file-name suffix of a writer marker.
    public static let markerPathExtension = "needsFinalize"

    // MARK: Scan

    /// Looks through `settings.directories` for packages whose manifest is
    /// `inProgress` or whose `recording/` holds a marker, skipping
    /// `excluding` (the package of a take running in this process) and any
    /// package another process is still writing (`inUse`). Reads one JSON
    /// file per package and no media, so it is cheap enough for every
    /// launch; a package whose manifest cannot be read is reported, not
    /// offered, since nothing can be rebuilt without its geometry.
    public static func scan(settings: RecoveryScannerSettings = RecoveryScannerSettings(), excluding: Set<URL> = [])
        -> RecoveryScanResult
    {
        let manager = FileManager.default
        let excluded = Set(excluding.map { RecordingPackage(url: $0).url })
        var seen: Set<URL> = []
        var result = RecoveryScanResult()
        for directory in settings.directories {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".\(RecordingPackage.pathExtension)") {
                let package = RecordingPackage(url: directory.appendingPathComponent(name))
                guard seen.insert(package.url).inserted, !excluded.contains(package.url), package.exists else {
                    continue
                }
                let markers = markers(in: package)
                if let writer = liveWriter(of: package, markers: markers, settings: settings) {
                    result.inUse.append(
                        UnreadablePackage(url: package.url, detail: "is still being recorded by process \(writer)"))
                    continue
                }
                guard manager.fileExists(atPath: package.manifestURL.path) else {
                    if !markers.isEmpty {
                        result.unreadable.append(
                            UnreadablePackage(
                                url: package.url, detail: "a movie is unfinished but there is no manifest"))
                    }
                    continue
                }
                let manifest: RecordingManifest
                do {
                    manifest = try package.manifest()
                } catch {
                    result.unreadable.append(UnreadablePackage(url: package.url, detail: error.localizedDescription))
                    continue
                }
                guard manifest.state == .inProgress || !markers.isEmpty else { continue }
                result.candidates.append(
                    RecoveryCandidate(
                        package: package, manifest: manifest, markers: markers,
                        fragmentedMovieBytes: fileSize(package.screenFragmentedMovieURL),
                        hasFinalizedMovie: manager.fileExists(atPath: package.screenMovieURL.path),
                        hasEventLogHeader: manager.fileExists(atPath: package.eventsURL.path),
                        eventsSidecarBytes: fileSize(package.eventsSidecarURL)))
            }
        }
        result.candidates.sort { $0.manifest.createdAt > $1.manifest.createdAt }
        return result
    }

    /// The writer markers in `recording/`, in name order. A marker that does
    /// not decode is skipped: the movie beside it is still found by name.
    public static func markers(in package: RecordingPackage) -> [NeedsFinalizeMarker] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: package.recordingDirectory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.sorted().filter { $0.hasSuffix(".\(markerPathExtension)") }.compactMap { name in
            guard let data = try? Data(contentsOf: package.recordingDirectory.appendingPathComponent(name)) else {
                return nil
            }
            return try? decoder.decode(NeedsFinalizeMarker.self, from: data)
        }
    }

    // MARK: Finish

    /// Finishes `candidate` and returns what was done. Throws only when a
    /// fragmented movie exists and cannot be finalized; everything else that
    /// goes wrong is a note, since a package with a playable movie is worth
    /// more than a refusal.
    public static func recover(
        _ candidate: RecoveryCandidate, settings: RecoveryScannerSettings = RecoveryScannerSettings()
    ) async throws -> RecoveryResult {
        let started = ContinuousClock.now
        let package = candidate.package
        var notes: [String] = []

        let finalizedMovies = try await finalizeMovies(of: candidate, notes: &notes)
        let playableSeconds = await playableSeconds(of: package.screenMovieURL, notes: &notes)
        let (eventCount, logRecovered) = recoverEventLog(
            of: package, manifest: candidate.manifest, settings: settings, notes: &notes)
        let (frameIndexLines, frameIndexTornAtLine) = repairFrameIndex(of: package, notes: &notes)
        let cursorSpriteCount =
            (try? FileManager.default.contentsOfDirectory(atPath: package.cursorsDirectory.path))?
            .filter { $0.hasSuffix(".png") }.count ?? 0

        // The manifest last: it is the commit point. An `inProgress` one is
        // rewritten; a final one too when this run produced the movie (a
        // take whose own finish failed, left `failed` with its marker) or
        // when its duration runs past what the movie plays, since a
        // whole-recording composition would otherwise run off the end. A
        // final manifest that already matches its movie stays as it is: the
        // cleanup above was all it needed.
        var manifest = candidate.manifest
        let overstated = (manifest.duration ?? 0) > playableSeconds + settings.playableDurationTolerance
        if manifest.state == .inProgress || !finalizedMovies.isEmpty || overstated {
            manifest.stopReason = manifest.state == .inProgress ? .crashed : (manifest.stopReason ?? .crashed)
            manifest.state = playableSeconds > 0 ? .recovered : .failed
            manifest.duration = playableSeconds
            try package.writeManifest(manifest)
            rewriteProject(of: package, manifest: manifest, settings: settings, notes: &notes)
        }

        return RecoveryResult(
            package: package, manifest: manifest, playableSeconds: playableSeconds, finalizedMovies: finalizedMovies,
            eventCount: eventCount, logRecovered: logRecovered, frameIndexLines: frameIndexLines,
            frameIndexTornAtLine: frameIndexTornAtLine, cursorSpriteCount: cursorSpriteCount,
            elapsedSeconds: seconds(since: started), notes: notes)
    }

    /// Moves the package to the Trash (or deletes it, per the settings) and
    /// returns where it went.
    @discardableResult
    public static func discard(
        _ candidate: RecoveryCandidate, settings: RecoveryScannerSettings = RecoveryScannerSettings()
    ) throws -> URL? {
        let url = candidate.package.url
        do {
            if settings.discardsToTrash {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return trashed as URL?
            }
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            throw RecoveryError.discardFailed(url, detail: error.localizedDescription)
        }
    }

    /// An event log with no events for a take whose telemetry never reached
    /// the disk, so the package still opens and renders (without cursor or
    /// zoom). The host time of its zero is unknown and recorded as 0; nothing
    /// aligns against it once the media is on the recording timeline.
    public static func emptyEventLog(for manifest: RecordingManifest, samplingRateHz: Double) -> EventLog {
        EventLog(
            recordingID: manifest.recordingID, startHostTimeSeconds: 0,
            captureRectPoints: manifest.content.captureRectPoints, displayID: manifest.content.displayID,
            pointPixelScale: manifest.content.pointPixelScale, samplingRateHz: samplingRateHz)
    }

    // MARK: Steps

    /// Finalizes every movie a marker names, plus a marker-less `screen.mov`
    /// (a crash between the writer's two removals leaves one). An MP4 that
    /// already exists means the finalize completed, so the leftovers are
    /// only cleared; the writer removes the marker first for the same
    /// reason it does: an orphan movie wastes disk, an orphan marker would
    /// bring the package back next launch.
    private static func finalizeMovies(of candidate: RecoveryCandidate, notes: inout [String]) async throws -> [String]
    {
        let package = candidate.package
        let manager = FileManager.default
        var movies: [(fragmented: URL, finalized: URL, marker: URL?)] = candidate.markers.map { marker in
            let fragmented = package.recordingDirectory.appendingPathComponent(marker.fragmentedMovie)
            return (
                fragmented, package.recordingDirectory.appendingPathComponent(marker.finalizedMovie),
                RecordingWriter.markerURL(for: fragmented)
            )
        }
        if !movies.contains(where: { $0.fragmented == package.screenFragmentedMovieURL }),
            manager.fileExists(atPath: package.screenFragmentedMovieURL.path)
        {
            movies.append((package.screenFragmentedMovieURL, package.screenMovieURL, nil))
        }
        var finalized: [String] = []
        for movie in movies {
            let fragmentedExists = fileSize(movie.fragmented) > 0
            let finalizedExists = manager.fileExists(atPath: movie.finalized.path)
            if finalizedExists {
                if fragmentedExists { notes.append("\(movie.finalized.lastPathComponent) was already finalized") }
            } else if fragmentedExists {
                do {
                    try await RecordingWriter.finalize(fragmentedMovie: movie.fragmented, into: movie.finalized)
                    finalized.append(movie.finalized.lastPathComponent)
                } catch {
                    throw RecoveryError.finalizeFailed(
                        movie: movie.fragmented.lastPathComponent, detail: error.localizedDescription)
                }
            } else {
                notes.append("\(movie.fragmented.lastPathComponent) holds no video")
            }
            if let marker = movie.marker {
                try? manager.removeItem(at: marker)
            }
            if manager.fileExists(atPath: movie.fragmented.path) {
                try? manager.removeItem(at: movie.fragmented)
            }
        }
        return finalized
    }

    /// The end of the shortest track of the movie at `movieURL`, in seconds:
    /// what a whole-recording composition can safely span. The track ends
    /// rather than the asset's duration, so a recovered audio track that
    /// stops a fragment early bounds the composition (see the type's note).
    /// Nil when the movie has no video track; throws when it cannot be read.
    public static func playableSeconds(of movieURL: URL) async throws -> Double? {
        let tracks = try await AVURLAsset(url: movieURL).load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { return nil }
        var end = try await video.load(.timeRange).end.seconds
        for track in tracks where track.mediaType == .audio {
            end = min(end, try await track.load(.timeRange).end.seconds)
        }
        return end.isFinite ? max(end, 0) : 0
    }

    /// `playableSeconds(of:)` with every way of having none as a note and 0.
    private static func playableSeconds(of movieURL: URL, notes: inout [String]) async -> Double {
        guard FileManager.default.fileExists(atPath: movieURL.path) else { return 0 }
        do {
            guard let seconds = try await playableSeconds(of: movieURL) else {
                notes.append("\(movieURL.lastPathComponent) has no video track")
                return 0
            }
            return seconds
        } catch {
            notes.append("\(movieURL.lastPathComponent) could not be read: \(error.localizedDescription)")
            return 0
        }
    }

    /// The id of the process still recording into `package`, if one is: a
    /// marker names a process that exists and the fragmented movie it names
    /// changed within the liveness window. Both are required, since a pid
    /// is reused after a reboot and a crashed take's movie can be seconds
    /// old at the next launch.
    private static func liveWriter(
        of package: RecordingPackage, markers: [NeedsFinalizeMarker], settings: RecoveryScannerSettings
    ) -> Int32? {
        for marker in markers {
            guard let pid = marker.processID, pid != ProcessInfo.processInfo.processIdentifier, isRunning(pid)
            else { continue }
            let movie = package.recordingDirectory.appendingPathComponent(marker.fragmentedMovie)
            guard
                let modified = try? movie.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                Date().timeIntervalSince(modified) < settings.livenessWindow
            else { continue }
            return pid
        }
        return nil
    }

    /// Whether a process with `pid` exists: `kill` with signal 0 delivers
    /// nothing and answers with ESRCH when there is none (EPERM means it is
    /// there but not ours).
    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Rebuilds `events.json` from its header and sidecar, or synthesizes an
    /// empty log when the take died before the first flush. A header that
    /// exists but cannot be read (a newer format) is left alone with its
    /// sidecar rather than overwritten with nothing.
    private static func recoverEventLog(
        of package: RecordingPackage, manifest: RecordingManifest, settings: RecoveryScannerSettings,
        notes: inout [String]
    ) -> (eventCount: Int, recovered: Bool) {
        let manager = FileManager.default
        let log: EventLog
        let recovered: Bool
        if manager.fileExists(atPath: package.eventsURL.path) {
            do {
                log = try InputTelemetryRecorder.recoverLog(persistenceURL: package.eventsURL)
                recovered = true
            } catch {
                notes.append("events.json could not be read and was left as it is: \(error.localizedDescription)")
                return (0, false)
            }
        } else {
            log = emptyEventLog(for: manifest, samplingRateHz: settings.fallbackSamplingRateHz)
            recovered = false
            notes.append("the telemetry never reached the disk; an empty event log was written")
        }
        do {
            try log.write(to: package.eventsURL)
            try? manager.removeItem(at: package.eventsSidecarURL)
        } catch {
            notes.append("events.json could not be written: \(error.localizedDescription)")
        }
        return (log.events.count, recovered)
    }

    /// Reads the index with the torn-line-tolerant reader and, when the
    /// crash tore its last line, writes it back whole, so later readers
    /// need no tolerance.
    private static func repairFrameIndex(of package: RecordingPackage, notes: inout [String]) -> (
        lines: Int?, tornAtLine: Int?
    ) {
        guard FileManager.default.fileExists(atPath: package.frameIndexURL.path) else {
            notes.append("there is no frames.jsonl")
            return (nil, nil)
        }
        do {
            let index = try package.frameIndex()
            if index.truncatedAtLine != nil {
                do {
                    try index.jsonLines().write(to: package.frameIndexURL, options: .atomic)
                } catch {
                    notes.append("frames.jsonl could not be rewritten: \(error.localizedDescription)")
                }
            }
            return (index.lines.count, index.truncatedAtLine)
        } catch {
            notes.append("frames.jsonl could not be read: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    /// Writes `project.json` as the session does at stop: a fresh
    /// whole-recording timeline over the final manifest, keeping the kit,
    /// style and export settings of the project on disk when it reads (the
    /// one written at start cannot have been edited), the settings' kit
    /// otherwise. Written directly rather than through `ProjectStore`, whose
    /// `.previous` copy belongs to an editing session.
    private static func rewriteProject(
        of package: RecordingPackage, manifest: RecordingManifest, settings: RecoveryScannerSettings,
        notes: inout [String]
    ) {
        let existing = try? Project.read(from: package.projectURL)
        let project = Project(
            recording: manifest, kit: existing?.kit ?? settings.kit, style: existing?.style,
            kitReference: existing?.kitReference, export: existing?.export ?? ExportSettings(),
            extra: existing?.extra ?? [:])
        do {
            try project.write(to: package.projectURL)
        } catch {
            notes.append("project.json could not be written: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
