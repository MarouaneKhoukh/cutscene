import CutsceneCapture
import CutsceneCore
import Foundation
import Observation

/// The numbers the app shell is tuned with (ARCHITECTURE §1, §7). The user's
/// own choices are `Defaults`.
struct AppSettings: Sendable, Equatable {
    /// Seconds between re-preflights while the onboarding window is visible,
    /// so a switch flipped in System Settings shows up without a click (§7).
    var onboardingRefreshInterval: TimeInterval = 1
    /// How long after a Screen Recording or Input Monitoring request a false
    /// preflight still reads as "waiting for the answer" when the app has
    /// not become active again meanwhile (`PermissionsModel.answerTimeout`).
    var permissionAnswerTimeout: TimeInterval = 60
    /// Packages the menu remembers, newest first.
    var recentPackageLimit = 10
    /// Characters of an error message a menu item shows before it is cut: a
    /// menu item is one line, and the full text reaches the log.
    var menuMessageLimit = 90
    /// Width of the onboarding window in points; the height follows its rows.
    var onboardingWindowWidth = 600.0
    /// Where recordings and exports go unless the user chose otherwise.
    var recordingsDirectory = RecordingPackage.defaultRecordingsDirectory
    var exportsDirectory = RecordingPackage.defaultExportsDirectory
    /// The session's tunables: disk preflight, heartbeat source, status cadence.
    var capture = CaptureSessionSettings()

    init() {}
}

/// The user's choices, kept in `UserDefaults` and observed by the menu.
///
/// Each property writes through on change, so the menu binds to it directly
/// and a value chosen in one launch drives the next one. Reading happens
/// once, at launch: `UserDefaults` is the store, this object is the truth
/// while the process runs.
@MainActor @Observable final class Defaults {
    enum Key: String, CaseIterable {
        case microphoneID = "recorder.microphoneID"
        case systemAudio = "recorder.systemAudio"
        case recordingsDirectory = "paths.recordingsDirectory"
        case exportsDirectory = "paths.exportsDirectory"
        case lastRecording = "recent.lastRecording"
        case lastExport = "recent.lastExport"
        case recentPackages = "recent.packages"
    }

    let settings: AppSettings
    private let store: UserDefaults

    /// `AVCaptureDevice.uniqueID` of the microphone to record, nil for none.
    var microphoneID: String? {
        didSet { store.set(microphoneID, forKey: Key.microphoneID.rawValue) }
    }
    /// Whether system audio is captured as its own track.
    var systemAudio: Bool {
        didSet { store.set(systemAudio, forKey: Key.systemAudio.rawValue) }
    }
    var recordingsDirectory: URL {
        didSet { store.set(recordingsDirectory.path, forKey: Key.recordingsDirectory.rawValue) }
    }
    var exportsDirectory: URL {
        didSet { store.set(exportsDirectory.path, forKey: Key.exportsDirectory.rawValue) }
    }
    /// The package of the last complete take.
    var lastRecordingURL: URL? {
        didSet { store.set(lastRecordingURL?.path, forKey: Key.lastRecording.rawValue) }
    }
    /// The last movie a render wrote.
    var lastExportURL: URL? {
        didSet { store.set(lastExportURL?.path, forKey: Key.lastExport.rawValue) }
    }
    /// Packages of recent takes, newest first, at most `settings.recentPackageLimit`.
    var recentPackages: [URL] {
        didSet { store.set(recentPackages.map(\.path), forKey: Key.recentPackages.rawValue) }
    }

    init(store: UserDefaults = .standard, settings: AppSettings = AppSettings()) {
        self.store = store
        self.settings = settings
        microphoneID = store.string(forKey: Key.microphoneID.rawValue)
        systemAudio = store.bool(forKey: Key.systemAudio.rawValue)
        recordingsDirectory =
            Self.directory(store.string(forKey: Key.recordingsDirectory.rawValue)) ?? settings.recordingsDirectory
        exportsDirectory =
            Self.directory(store.string(forKey: Key.exportsDirectory.rawValue)) ?? settings.exportsDirectory
        lastRecordingURL = Self.file(store.string(forKey: Key.lastRecording.rawValue))
        lastExportURL = Self.file(store.string(forKey: Key.lastExport.rawValue))
        recentPackages = (store.stringArray(forKey: Key.recentPackages.rawValue) ?? []).compactMap(Self.file)
    }

    /// Puts `url` at the front of `recentPackages` and makes it the last
    /// recording.
    func remember(package url: URL) {
        lastRecordingURL = url
        var recent = recentPackages.filter { $0 != url }
        recent.insert(url, at: 0)
        recentPackages = Array(recent.prefix(settings.recentPackageLimit))
    }

    private static func directory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func file(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
