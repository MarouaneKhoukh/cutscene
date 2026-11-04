import Foundation

/// Why a project could not be read.
public enum ProjectFormatError: LocalizedError, Sendable, Equatable {
    /// The project declares a format newer than this build, or older than
    /// any migration step can lift, so its fields cannot be trusted to mean
    /// what they mean here.
    case unsupportedFormatVersion(Int)
    /// The document has no integer `formatVersion`, so nothing can place it.
    case missingFormatVersion
    /// The document is not a JSON object.
    case notAnObject
    /// The migration chain has a hole: no step lifts this version. A build
    /// error rather than a user's, but typed so it is reported, not trapped.
    case missingMigrationStep(fromVersion: Int)
    /// A brand kit declares a schema this build does not know.
    case unsupportedKitSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "This project uses format version \(version); this build reads versions "
                + "\(Migrator.standard.oldestReadableVersion) through \(Project.currentFormatVersion)."
        case .missingFormatVersion:
            "This project does not say which format version it uses."
        case .notAnObject:
            "This project file does not hold a JSON object."
        case .missingMigrationStep(let version):
            "This build cannot migrate a project from format version \(version)."
        case .unsupportedKitSchemaVersion(let version):
            "This brand kit uses schema version \(version); this build reads versions "
                + "1 through \(BrandKit.currentSchemaVersion)."
        }
    }
}

/// Where a project's `kit` snapshot came from, so "Update from kit" can find
/// the file again: a name in the kit library, or a file at `path` (a kit in
/// a git checkout). Nil on a project means the built-in default.
public struct KitReference: Sendable, Hashable, PreservesUnknownKeys {
    /// The kit's name, the stem of `<name>.cutscenekit.json`.
    public var name: String
    /// Absolute path of the kit file when it lives outside the library.
    public var path: String?
    public var extra: [String: JSONValue]

    public init(name: String, path: String? = nil, extra: [String: JSONValue] = [:]) {
        self.name = name
        self.path = path
        self.extra = extra
    }
}

/// `project.json`: everything about a recording that is not the recording
/// itself (ARCHITECTURE §3). The manifest is snapshotted so the project
/// describes its media on its own; the kit is snapshotted so the edited
/// `style` can be merged against the kit it started from.
///
/// Fields this build does not know survive a round trip through `extra` at
/// every level. Adding a field never bumps `currentFormatVersion`; renaming
/// one or changing what it means does, with a `Migrator` step and a fixture
/// per version, and a newer version is refused rather than misread.
public struct Project: Sendable, Hashable, PreservesUnknownKeys {
    /// The format this build writes.
    public static let currentFormatVersion = CutsceneCore.projectFormatVersion

    /// Always `currentFormatVersion`: the format this value encodes as.
    public let formatVersion: Int
    public var recording: RecordingManifest
    public var timeline: Timeline
    /// The kit as applied, untouched by edits.
    public var kit: BrandKit
    /// The look in effect: `kit` plus the user's changes.
    public var style: BrandKit
    public var kitReference: KitReference?
    public var export: ExportSettings
    public var extra: [String: JSONValue]

    /// A project over `recording`. Without a `timeline` the whole recording
    /// plays (its `duration`, or nothing while the take is still running);
    /// without a `style` the kit is applied as is.
    public init(
        recording: RecordingManifest,
        timeline: Timeline? = nil,
        kit: BrandKit = .default,
        style: BrandKit? = nil,
        kitReference: KitReference? = nil,
        export: ExportSettings = ExportSettings(),
        extra: [String: JSONValue] = [:]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.recording = recording
        self.timeline = timeline ?? Timeline.wholeRecording(duration: recording.duration ?? 0)
        self.kit = kit
        self.style = style ?? kit
        self.kitReference = kitReference
        self.export = export
        self.extra = extra
    }
}

// MARK: - Codable

extension KitReference: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(path, forKey: .path)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case recording
        case timeline
        case kit
        case style
        case kitReference
        case export
    }

    // Hand-written so an unknown version is refused before its fields are
    // misread and the unknown keys are kept. Documents reach this through
    // `init(jsonData:)`, which runs the migrator first, so a readable older
    // version has already been lifted to the current one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (Migrator.standard.oldestReadableVersion...Self.currentFormatVersion).contains(version) else {
            throw ProjectFormatError.unsupportedFormatVersion(version)
        }
        formatVersion = Self.currentFormatVersion
        recording = try container.decode(RecordingManifest.self, forKey: .recording)
        timeline = try container.decode(.timeline, or: Timeline())
        kit = try container.decode(.kit, or: .default)
        style = try container.decode(.style, or: kit)
        kitReference = try container.decodeIfPresent(KitReference.self, forKey: .kitReference)
        export = try container.decode(.export, or: ExportSettings())
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(recording, forKey: .recording)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(kit, forKey: .kit)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(kitReference, forKey: .kitReference)
        try container.encode(export, forKey: .export)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

// MARK: - JSON files

extension Project {
    /// Builds a project from its JSON encoding, lifting an older format
    /// through `migrator` first; a newer one throws
    /// `ProjectFormatError.unsupportedFormatVersion`.
    public init(jsonData data: Data, migrator: Migrator = .standard) throws {
        let document = try migrator.migrate(JSONValue(jsonData: data))
        self = try document.decoded(as: Project.self)
    }

    /// The project as JSON with sorted keys, so two writes of the same
    /// project are byte-identical and an unedited project re-saves unchanged.
    /// The file on disk is pretty-printed for the people who read it; the
    /// compact form is what fixtures pin.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        try PackageJSON.encode(self, prettyPrinted: prettyPrinted)
    }

    /// Reads a project written by `write(to:)`.
    public static func read(from url: URL, migrator: Migrator = .standard) throws -> Project {
        try Project(jsonData: Data(contentsOf: url), migrator: migrator)
    }

    /// Writes the project atomically, so a crash mid-write leaves the
    /// previous complete file rather than a truncated one.
    public func write(to url: URL, prettyPrinted: Bool = true) throws {
        try jsonData(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }
}

// MARK: - Decoding defaults

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when the key is absent or null, so a
    /// sparse kit or a file from before the field was added takes the
    /// default rather than failing to open.
    func decode<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
