import Foundation

/// The JSON dialect every file in a package is written in: sorted keys and
/// unescaped slashes, so two writes of the same value are byte-identical and
/// diff cleanly in git, and dates as ISO 8601 strings with millisecond
/// precision rather than Foundation's reference-date seconds.
public enum PackageJSON {
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDateStyle = Date.ISO8601FormatStyle()

    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "\(text) is not an ISO 8601 date.")
            }
            return date
        }
        return decoder
    }

    public static func encode(_ value: some Encodable, prettyPrinted: Bool = false) throws -> Data {
        try encoder(prettyPrinted: prettyPrinted).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// `2026-11-03T10:15:30.250Z`: UTC, rounded to the millisecond. The
    /// fraction is written by hand because the format style truncates it,
    /// and a double holding a rounded `.191` sits a hair below it and would
    /// come out as `.190`, one millisecond off after a round trip.
    public static func string(from date: Date) -> String {
        let totalMilliseconds = Int64((date.timeIntervalSinceReferenceDate * 1000).rounded())
        var seconds = totalMilliseconds / 1000
        var milliseconds = totalMilliseconds % 1000
        if milliseconds < 0 {
            milliseconds += 1000
            seconds -= 1
        }
        let whole = Date(timeIntervalSinceReferenceDate: Double(seconds)).formatted(plainDateStyle)
        return whole.dropLast() + String(format: ".%03dZ", milliseconds)
    }

    /// Parses an ISO 8601 date with or without fractional seconds.
    public static func date(from text: String) -> Date? {
        if let date = try? Date(text, strategy: fractionalDateStyle) { return date }
        return try? Date(text, strategy: plainDateStyle)
    }
}

/// Why a package could not be created or opened.
public enum RecordingPackageError: LocalizedError, Sendable, Equatable {
    /// `create(at:)` refuses to touch an existing package: a recording is
    /// never merged into or written over.
    case alreadyExists(URL)
    case notFound(URL)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let url): "A package already exists at \(url.path)."
        case .notFound(let url): "There is no package at \(url.path)."
        }
    }
}

/// How packages are named: `<yyyy-MM-dd HH.mm.ss> <source>.cutscene`, in
/// the user's time zone, since the name is for people.
public struct PackageNamingSettings: Sendable, Hashable {
    /// Longest source label kept in a file name; a window title can run to
    /// hundreds of characters.
    public var maximumLabelLength = 40
    /// The label when the source gives none usable.
    public var fallbackLabel = "Recording"
    public var timeZone: TimeZone = .current

    public init(maximumLabelLength: Int = 40, fallbackLabel: String = "Recording", timeZone: TimeZone = .current) {
        self.maximumLabelLength = maximumLabelLength
        self.fallbackLabel = fallbackLabel
        self.timeZone = timeZone
    }
}

/// A `.cutscene` package on disk (ARCHITECTURE §3): a folder the Finder
/// shows as one document, holding the project, the recording and its
/// regenerable caches.
///
/// ```
/// Demo.cutscene/
///   project.json             Project: timeline, kit snapshot, style, export settings
///   project.json.previous    the project as opened in the current editing session
///   recording/
///     manifest.json          RecordingManifest, written at start and rewritten at stop
///     screen.mp4             faststart MP4 (HEVC + 2 AAC); screen.mov + .needsFinalize during the take
///     camera.mp4             optional, same shape
///     events.json            EventLog; events.events.jsonl sidecar during the take
///     frames.jsonl           per-frame index
///     cursors/<id>.png       captured cursor sprites; transcript.json reserved
///   thumbnail.jpg, derived/  poster; regenerable caches
/// ```
///
/// The value is a URL with the layout spelled out once, so no other module
/// builds a path by hand. Creating one is the only operation that touches
/// the disk; everything else is a path.
public struct RecordingPackage: Sendable, Hashable {
    public static let pathExtension = "cutscene"
    /// The package's UTI, conforming to `com.apple.package`.
    public static let typeIdentifier = "app.cutscene.project"

    /// The `.cutscene` folder.
    public let url: URL

    /// `url` is kept as a directory URL built from its standardized path, so
    /// the same folder spelled before and after it exists compares equal:
    /// `standardizedFileURL` alone asks the file system whether to end the
    /// URL with a slash.
    public init(url: URL) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    // MARK: Layout

    public var projectURL: URL { url.appendingPathComponent("project.json") }
    /// The project as it was when the current editing session opened it.
    public var previousProjectURL: URL { url.appendingPathComponent("project.json.previous") }
    public var recordingDirectory: URL { url.appendingPathComponent("recording", isDirectory: true) }
    public var manifestURL: URL { recordingDirectory.appendingPathComponent("manifest.json") }
    /// The finalized faststart MP4.
    public var screenMovieURL: URL { recordingDirectory.appendingPathComponent("screen.mp4") }
    /// The fragmented movie written during the take; `RecordingWriter`
    /// derives the MP4 and the `.needsFinalize` marker from this name.
    public var screenFragmentedMovieURL: URL { recordingDirectory.appendingPathComponent("screen.mov") }
    public var cameraMovieURL: URL { recordingDirectory.appendingPathComponent("camera.mp4") }
    public var cameraFragmentedMovieURL: URL { recordingDirectory.appendingPathComponent("camera.mov") }
    public var eventsURL: URL { recordingDirectory.appendingPathComponent("events.json") }
    /// The JSON Lines sidecar the telemetry recorder appends to between
    /// flushes; the same name `InputTelemetryRecorder.sidecarURL(for:)`
    /// derives from `eventsURL`.
    public var eventsSidecarURL: URL { eventsURL.deletingPathExtension().appendingPathExtension("events.jsonl") }
    public var frameIndexURL: URL { recordingDirectory.appendingPathComponent("frames.jsonl") }
    public var cursorsDirectory: URL { recordingDirectory.appendingPathComponent("cursors", isDirectory: true) }
    /// Reserved for the transcript.
    public var transcriptURL: URL { recordingDirectory.appendingPathComponent("transcript.json") }
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }
    /// Regenerable caches; safe to delete.
    public var derivedDirectory: URL { url.appendingPathComponent("derived", isDirectory: true) }

    /// The sprite for a cursor shape, by the id `cursorShapeChanged` events
    /// carry (a name such as `arrow` or a content hash).
    public func cursorSpriteURL(shapeID: String) -> URL {
        cursorsDirectory.appendingPathComponent(shapeID).appendingPathExtension("png")
    }

    // MARK: Disk

    /// Whether the package folder exists.
    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Creates the folder tree for a new recording: the package, `recording/`
    /// and `cursors/`. `derived/` appears when a cache is first written.
    /// Refuses an existing path rather than merging into it.
    public static func create(at url: URL) throws -> RecordingPackage {
        let package = RecordingPackage(url: url)
        guard !FileManager.default.fileExists(atPath: package.url.path) else {
            throw RecordingPackageError.alreadyExists(package.url)
        }
        try FileManager.default.createDirectory(at: package.cursorsDirectory, withIntermediateDirectories: true)
        return package
    }

    /// The package at `url`, which must exist.
    public static func open(at url: URL) throws -> RecordingPackage {
        let package = RecordingPackage(url: url)
        guard package.exists else { throw RecordingPackageError.notFound(package.url) }
        return package
    }

    // MARK: JSON files

    /// Writes `value` as package JSON, atomically: a crash mid-write leaves
    /// the previous complete file rather than a truncated one.
    public func writeJSON(_ value: some Encodable, to fileURL: URL, prettyPrinted: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PackageJSON.encode(value, prettyPrinted: prettyPrinted).write(to: fileURL, options: .atomic)
    }

    /// Reads a file written by `writeJSON`.
    public func readJSON<T: Decodable>(_ type: T.Type, from fileURL: URL) throws -> T {
        try PackageJSON.decode(type, from: Data(contentsOf: fileURL))
    }

    public func manifest() throws -> RecordingManifest {
        try RecordingManifest.read(from: manifestURL)
    }

    public func writeManifest(_ manifest: RecordingManifest) throws {
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        try manifest.write(to: manifestURL)
    }

    public func eventLog() throws -> EventLog {
        try EventLog.read(from: eventsURL)
    }

    public func frameIndex() throws -> FrameIndex {
        try FrameIndex.read(from: frameIndexURL)
    }

    // MARK: Default folders

    /// `~/Movies/Cutscene`, where recordings go unless the settings say otherwise.
    public static var defaultRecordingsDirectory: URL {
        let movies =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("Cutscene", isDirectory: true)
    }

    /// `~/Movies/Cutscene/Exports`, where finished MP4s go.
    public static var defaultExportsDirectory: URL {
        defaultRecordingsDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Creates both default folders if they are missing.
    public static func ensureDefaultDirectories() throws {
        try FileManager.default.createDirectory(at: defaultExportsDirectory, withIntermediateDirectories: true)
    }

    // MARK: Naming

    /// `<yyyy-MM-dd HH.mm.ss> <label>.cutscene`. Dots rather than colons in
    /// the time because a colon is the Finder's path separator; the label is
    /// cleaned by `sanitizedLabel`.
    public static func name(
        createdAt: Date, label: String, settings: PackageNamingSettings = PackageNamingSettings()
    ) -> String {
        // A `Date.FormatString` is built by interpolation and cannot be
        // concatenated, hence one literal with a continuation.
        let stamp = Date.VerbatimFormatStyle(
            format: """
                \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \
                \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\
                \(second: .twoDigits)
                """,
            timeZone: settings.timeZone, calendar: Calendar(identifier: .gregorian))
        return "\(createdAt.formatted(stamp)) \(sanitizedLabel(label, settings: settings)).\(pathExtension)"
    }

    /// The package URL for a take started at `createdAt` from `source`, in
    /// `directory`.
    public static func url(
        createdAt: Date, source: CaptureSource, in directory: URL = defaultRecordingsDirectory,
        settings: PackageNamingSettings = PackageNamingSettings()
    ) -> URL {
        directory.appendingPathComponent(name(createdAt: createdAt, label: source.label, settings: settings))
    }

    /// `label` made safe for a file name: path separators replaced, control
    /// characters and surrounding whitespace dropped, length capped, and the
    /// fallback when nothing is left.
    public static func sanitizedLabel(_ label: String, settings: PackageNamingSettings = PackageNamingSettings())
        -> String
    {
        var cleaned = ""
        for character in label {
            if character == "/" || character == ":" {
                cleaned.append("-")
            } else if character.isNewline
                || character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control })
            {
                continue
            } else {
                cleaned.append(character)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > settings.maximumLabelLength {
            cleaned = String(cleaned.prefix(settings.maximumLabelLength)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? settings.fallbackLabel : cleaned
    }

    /// `proposed` when nothing is there, else the first of `<name> 2`,
    /// `<name> 3`, … that is free, so two takes started in the same second
    /// both get a package.
    public static func availableURL(for proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let stem = proposed.deletingPathExtension().lastPathComponent
        let pathExtension = proposed.pathExtension
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
