import Foundation

/// One format bump of `project.json`: lifts a document from `fromVersion`
/// to `fromVersion + 1`. Steps work on the JSON tree rather than on typed
/// values, since the typed model only knows the current format.
public struct MigrationStep: Sendable {
    public let fromVersion: Int
    /// What changed, for the log and the ADR.
    public let summary: String
    /// Rewrites the object; the migrator sets `formatVersion` afterwards.
    public let transform: @Sendable ([String: JSONValue]) throws -> [String: JSONValue]

    public init(
        fromVersion: Int, summary: String,
        transform: @escaping @Sendable ([String: JSONValue]) throws -> [String: JSONValue]
    ) {
        self.fromVersion = fromVersion
        self.summary = summary
        self.transform = transform
    }

    public var toVersion: Int {
        fromVersion + 1
    }
}

/// Lifts a project document to the current format by applying the steps in
/// version order (ARCHITECTURE §3). The current version passes through as
/// it is, a newer one is refused, and one older than the first step is
/// refused too: additive fields never bump the version, so every step
/// stands for a rename or a change of meaning that cannot be guessed.
public struct Migrator: Sendable {
    /// The format the chain ends at.
    public let currentVersion: Int
    /// In ascending `fromVersion` order, whatever order they were given in.
    public let steps: [MigrationStep]

    /// The chain this build ships: format 1 is the first, so there is
    /// nothing to lift yet and version 1 is the identity.
    public static let standard = Migrator(currentVersion: Project.currentFormatVersion, steps: [])

    public init(currentVersion: Int, steps: [MigrationStep]) {
        self.currentVersion = currentVersion
        self.steps = steps.sorted { $0.fromVersion < $1.fromVersion }
    }

    /// The oldest format a document may declare: the first step's, or the
    /// current one when there is no step.
    public var oldestReadableVersion: Int {
        steps.first?.fromVersion ?? currentVersion
    }

    /// `document` at `currentVersion`. Throws `ProjectFormatError` when the
    /// document is not an object, carries no integer `formatVersion`, is
    /// newer than this build or older than its chain, or the chain has a hole.
    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard case .object(var object) = document else { throw ProjectFormatError.notAnObject }
        guard let declared = object[Project.versionKey]?.intValue else { throw ProjectFormatError.missingFormatVersion }
        guard (oldestReadableVersion...currentVersion).contains(declared) else {
            throw ProjectFormatError.unsupportedFormatVersion(declared)
        }
        var version = declared
        while version < currentVersion {
            guard let step = steps.first(where: { $0.fromVersion == version }) else {
                throw ProjectFormatError.missingMigrationStep(fromVersion: version)
            }
            object = try step.transform(object)
            version = step.toVersion
            object[Project.versionKey] = .integer(Int64(version))
        }
        return .object(object)
    }
}

extension Project {
    /// The key the migrator reads and rewrites.
    static let versionKey = "formatVersion"
}
