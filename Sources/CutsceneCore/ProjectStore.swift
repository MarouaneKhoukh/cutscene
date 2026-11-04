import Foundation
import Synchronization

/// Reads and writes a package's `project.json` for one editing session.
///
/// Saves are atomic, so a crash mid-write leaves the previous complete file.
/// The first save of a session first copies the file as it was opened to
/// `project.json.previous`, byte for byte, and later saves leave that copy
/// alone: a session can always be undone as a whole, and the copy never
/// drifts to a mid-session state. A store is a session; a new store starts a
/// new one. Saving is the caller's decision (`EditorModel` never saves an
/// unedited project), so an opened project that is only read leaves no trace.
public final class ProjectStore: Sendable {
    public let package: RecordingPackage
    /// Lifts an older `project.json` on load.
    public let migrator: Migrator
    /// Whether this session has already preserved the file it opened. Held
    /// across the save so two saves cannot race for the first copy.
    private let previousPreserved = Mutex(false)

    public init(package: RecordingPackage, migrator: Migrator = .standard) {
        self.package = package
        self.migrator = migrator
    }

    /// Whether the package has a `project.json`.
    public var projectExists: Bool {
        FileManager.default.fileExists(atPath: package.projectURL.path)
    }

    /// Whether this session has written `project.json.previous`.
    public var hasPreservedPrevious: Bool {
        previousPreserved.withLock { $0 }
    }

    /// The project on disk, migrated to the current format. Throws
    /// `ProjectFormatError` for a version this build cannot read.
    public func load() throws -> Project {
        try Project.read(from: package.projectURL, migrator: migrator)
    }

    /// The project as it was when this session first saved, if the session
    /// has preserved one and the file is still there.
    public func loadPrevious() throws -> Project? {
        guard FileManager.default.fileExists(atPath: package.previousProjectURL.path) else { return nil }
        return try Project.read(from: package.previousProjectURL, migrator: migrator)
    }

    /// Writes `project` atomically, preserving the opened file first on the
    /// session's first save. A first save that creates the file preserves
    /// nothing: there was no opened state.
    public func save(_ project: Project) throws {
        try previousPreserved.withLock { preserved in
            if !preserved {
                if let opened = try? Data(contentsOf: package.projectURL) {
                    try opened.write(to: package.previousProjectURL, options: .atomic)
                }
                preserved = true
            }
            try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
            try project.write(to: package.projectURL)
        }
    }
}
