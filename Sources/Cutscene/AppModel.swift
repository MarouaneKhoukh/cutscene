import AVFoundation
import AppKit
import CutsceneCapture
import CutsceneCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// A display as the menu lists it, from `NSScreen`, which needs no
/// permission; the session resolves the id against ScreenCaptureKit when the
/// take starts.
struct DisplayChoice: Identifiable, Sendable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let widthPoints: Int
    let heightPoints: Int
    /// The display the menu bar is on.
    let isMain: Bool

    var menuTitle: String {
        "\(name) · \(widthPoints) × \(heightPoints)" + (isMain ? " (main)" : "")
    }
}

/// A microphone as the menu lists it: the `Sendable` part of an `AVCaptureDevice`.
struct MicrophoneChoice: Identifiable, Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID`, the name `CaptureRequest.microphoneID` takes.
    let id: String
    let name: String
}

/// The app's state (ARCHITECTURE §1): permissions, the user's defaults,
/// recent packages, the recorder, what the menu lists, and the recording
/// overlays (countdown, area picker, pill). Created once at launch, before
/// the user can have reached System Settings, so the permissions baseline
/// is right.
@MainActor @Observable final class AppModel {
    /// The id of M2-10's `WindowGroup("Editor", id:, for: URL.self)`, which
    /// Open Last Recording opens with `openWindow(id:value:)`.
    static let editorWindowID = "editor"

    let settings: AppSettings
    let defaults: Defaults
    /// The camera and the window strategy (M2-09), kept beside `defaults`.
    let sources: SourceChoices
    let sourceSettings: SourceMenuSettings
    let countdownSettings: CountdownSettings
    let permissions: PermissionsModel
    let recorder: RecorderController
    private(set) var displays: [DisplayChoice] = []
    private(set) var microphones: [MicrophoneChoice] = []
    /// The windows Record Window ▸ offers, by application; filled when a
    /// menu opens and Screen Recording is usable.
    private(set) var windowGroups: [WindowsByApplication] = []
    /// Why the window listing is empty, when a listing failed.
    private(set) var windowListError: String?
    private(set) var cameras: [CameraSummary] = []
    /// Why the last relaunch did not happen, for the onboarding window.
    private(set) var relaunchError: String?

    private var onboarding: OnboardingWindow?
    /// The launch-time offer for takes a killed process left (M1-13).
    private var recovery: RecoveryFlow?
    private let countdownOverlay: CountdownOverlay
    private var pill: RecordingPill?
    /// The area picker while it is on screen.
    private var areaSelection: AreaSelectionController?
    private var windowListTask: Task<Void, Never>?
    private var windowListFetchedAt: Date?
    /// Whether `startTake` is between its first line and the recorder's
    /// `record`, so a second Record in that gap starts nothing.
    private var startingTake = false
    /// Whether `settleForQuit` has run; the delegate's reply to the
    /// termination request is given once.
    private var quitting = false
    /// Kept for the life of the model, which is the life of the process.
    private var observers: [any NSObjectProtocol] = []

    var recentPackages: [URL] { defaults.recentPackages }
    var lastExportURL: URL? { defaults.lastExportURL }
    var lastRecordingURL: URL? { defaults.lastRecordingURL }
    /// Whether the area picker is on screen.
    var isSelectingArea: Bool { areaSelection != nil }

    /// Whether a take, its render, or a recovered take's finish or render is
    /// in flight: nothing that would compete with it for the encoder or the
    /// package (a new take, a relaunch) starts beside it.
    var isBusy: Bool { recorder.isBusy || recoveryBusy }
    /// Whether the launch-time recovery is finishing or rendering a package.
    var recoveryBusy: Bool { recovery?.isBusy == true }

    init(
        settings: AppSettings = AppSettings(), store: UserDefaults = .standard,
        sourceSettings: SourceMenuSettings = SourceMenuSettings(),
        countdownSettings: CountdownSettings = CountdownSettings()
    ) {
        self.settings = settings
        self.sourceSettings = sourceSettings
        self.countdownSettings = countdownSettings
        let defaults = Defaults(store: store, settings: settings)
        self.defaults = defaults
        sources = SourceChoices(store: store)
        countdownOverlay = CountdownOverlay(settings: countdownSettings)
        // The asked-for set is this process's only (see `Permissions`): a
        // persisted one outlived the `tccutil reset` of development builds
        // and read a fresh Screen Recording state as declined.
        permissions = PermissionsModel(
            refreshInterval: settings.onboardingRefreshInterval, answerTimeout: settings.permissionAnswerTimeout)
        recorder = RecorderController(permissions: permissions.permissions, sessionSettings: settings.capture)

        recorder.onTakeComplete = { [weak self] package, _ in
            self?.defaults.remember(package: package.url)
        }
        recorder.onExportComplete = { [weak self] url in
            self?.defaults.lastExportURL = url
        }
        recorder.onStateChange = { [weak self] state in
            self?.recorderStateChanged(state)
        }
        // M1-13: every finished take is rendered into the exports folder.
        recorder.renderer = AutoRender(
            preset: { [defaults] in ExportPresetID(rawValue: defaults.defaultPresetID) },
            destination: { [defaults] in defaults.exportsDirectory })

        refreshDisplays()
        refreshMicrophones()
        refreshCameras()
        observe(NSApplication.didFinishLaunchingNotification) { $0.didFinishLaunching() }
        observe(NSApplication.didChangeScreenParametersNotification) { $0.refreshDisplays() }
        observe(AVCaptureDevice.wasConnectedNotification) {
            $0.refreshMicrophones()
            $0.refreshCameras()
        }
        observe(AVCaptureDevice.wasDisconnectedNotification) {
            $0.refreshMicrophones()
            $0.refreshCameras()
        }
        // A menu opening (the status item's, or a pull-down in the recorder
        // window) is when the window listing has to be current.
        observe(NSMenu.didBeginTrackingNotification) { $0.refreshWindows() }
    }

    /// The app is up: without a usable Screen Recording grant the onboarding
    /// window opens by itself, since the menu cannot record yet. M1-13's
    /// `RecoveryFlow` (an `inProgress` take from a killed process) runs here
    /// before it.
    func didFinishLaunching() {
        let recovery = RecoveryFlow(model: self)
        self.recovery = recovery
        recovery.checkAtLaunch()
        if !permissions.canRecord {
            showOnboarding()
        }
    }

    // MARK: Recording

    /// Starts a take of `display` with the menu's choices, after the
    /// countdown, or opens onboarding when Screen Recording is not usable yet.
    func record(display: DisplayChoice) {
        startTake(source: .display(display.id), named: .display)
    }

    /// Starts a take of `window` the way `sources.windowStrategy` says; the
    /// package is named after the window's application.
    func record(window: WindowChoice) {
        startTake(source: .window(window.id), named: window.namedSource)
    }

    /// Opens the area picker on every display; the take starts once a
    /// selection is confirmed, and a cancelled picker starts nothing.
    /// Lets the user drag an area without starting a take, so the launcher
    /// can preview it and record it later with `record(area:)`.
    func pickArea(_ completion: @escaping @MainActor (AreaSelection?) -> Void) {
        guard permissions.canRecord else {
            showOnboarding()
            completion(nil)
            return
        }
        guard areaSelection == nil else {
            completion(nil)
            return
        }
        let picker = AreaSelectionController { [weak self] selection in
            self?.areaSelection = nil
            completion(selection)
        }
        areaSelection = picker
        picker.begin()
    }

    /// Records an area chosen earlier with `pickArea`.
    func record(area selection: AreaSelection) {
        startTake(source: .area(displayID: selection.displayID, rect: selection.rect), named: .area)
    }

    func recordArea() {
        guard permissions.canRecord else {
            showOnboarding()
            return
        }
        guard !isBusy, areaSelection == nil else { return }
        let picker = AreaSelectionController { [weak self] selection in
            guard let self else { return }
            areaSelection = nil
            guard let selection else { return }
            startTake(source: .area(displayID: selection.displayID, rect: selection.rect), named: .area)
        }
        areaSelection = picker
        picker.begin()
    }

    func pause() { recorder.pause() }
    func resume() { recorder.resume() }

    /// A file chooser for an earlier take (any `.cutscene` package).
    func openRecording(_ open: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.package]
        panel.directoryURL = defaults.recordingsDirectory
        panel.message = "Choose a .cutscene recording"
        panel.begin { response in
            guard response == .OK, let url = panel.url, url.pathExtension == "cutscene" else { return }
            MainActor.assumeIsolated { open(url) }
        }
    }

    func stop() {
        Task { await recorder.stop() }
    }

    /// The pill's Marker button: a `takeMarker` event at this moment.
    func mark() {
        recorder.mark()
    }

    /// The take: the menu's microphone, system audio and camera choices on
    /// `source`, refused while the recovery window finishes or renders a
    /// package (a real-time capture and an offline export would share the
    /// encoder), and refused with onboarding open when a chosen camera has
    /// no usable grant.
    private func startTake(source: CaptureRequest.Source, named: CaptureSource) {
        guard permissions.canRecord else {
            showOnboarding()
            return
        }
        guard !recoveryBusy, !isBusy, !startingTake else { return }
        let directory = defaults.recordingsDirectory
        var countdown = countdownSettings
        countdown.seconds = defaults.countdownSeconds
        startingTake = true
        Task {
            defer { startingTake = false }
            let camera: CaptureRequest.CameraSelection?
            switch cameraChoice() {
            case .none: camera = nil
            case .camera(let selection): camera = selection
            case .refused: return
            }
            // The take is the recorder's from here; `record` is busy from
            // its first line, so a second Record cannot stack a take on it.
            guard !recoveryBusy, !isBusy else { return }
            let request = CaptureRequest(
                source: source, windowStrategy: sources.windowStrategy, microphoneID: defaults.microphoneID,
                systemAudio: defaults.systemAudio, camera: camera)
            await recorder.record(request, in: directory, countdown: countdown, named: named)
        }
    }

    /// The camera for the next take.
    private enum CameraChoice {
        /// No camera is chosen.
        case none
        case camera(CaptureRequest.CameraSelection)
        /// A camera is chosen but the system will not let us open it;
        /// onboarding has been shown and the take must not start.
        case refused
    }

    /// Resolves the chosen camera against its grant. Record never asks for
    /// it (PLAN M2-09: "camera permission on first toggle only", the pick in
    /// `selectCamera`): a grant that is denied, or not determined because
    /// the pick's prompt was dismissed or the grant was reset since, sends
    /// the user to onboarding, whose camera row says to pick the camera
    /// again, and the take does not start.
    private func cameraChoice() -> CameraChoice {
        guard let cameraID = sources.cameraID else { return .none }
        guard permissions.state(of: .camera) == .granted else {
            showOnboarding()
            return .refused
        }
        return .camera(CaptureRequest.CameraSelection(deviceID: cameraID))
    }

    /// Renders the last complete take again, after a failed or cancelled
    /// auto-render (ARCHITECTURE §1 has no export item in M1; this stands in
    /// until the editor's export sheet, M2-10).
    func renderLastRecording() {
        guard let url = defaults.lastRecordingURL, !isBusy else { return }
        recorder.renderLast(package: RecordingPackage(url: url))
    }

    /// Picks the microphone for the next take. The first pick is the "first
    /// toggle" §7 asks on; a declined grant sends the user to onboarding,
    /// whose deep link reaches the switch macOS will not prompt for again.
    func selectMicrophone(_ id: String?) {
        defaults.microphoneID = id
        guard id != nil else { return }
        Task {
            var state = permissions.state(of: .microphone)
            if state == .notDetermined {
                state = await permissions.request(.microphone)
            }
            if state == .denied {
                showOnboarding()
            }
        }
    }

    /// Picks the camera for the next take. The first pick asks for the
    /// camera grant (§7 "on first toggle only"); Off asks nothing, and a
    /// declined grant sends the user to onboarding.
    func selectCamera(_ id: String?) {
        sources.cameraID = id
        guard id != nil else { return }
        Task {
            var state = permissions.state(of: .camera)
            if state == .notDetermined {
                state = await permissions.request(.camera)
            }
            if state == .denied {
                showOnboarding()
            }
        }
    }

    /// The overlays follow the recorder: the countdown badge while it
    /// counts, the pill from the countdown to the end of the finish. The
    /// pill is up before the session lists the shareable content, so a
    /// window of ours is on screen for the display filter to exclude.
    private func recorderStateChanged(_ state: RecorderController.State) {
        switch state {
        case .countdown(let remaining):
            countdownOverlay.show(remaining: remaining)
            showPill()
        case .selecting, .recording, .finishing:
            countdownOverlay.hide()
            showPill()
        case .idle, .rendering, .done, .failed, .renderFailed:
            countdownOverlay.hide()
            pill?.hide()
        }
    }

    private func showPill() {
        let pill = pill ?? RecordingPill(model: self)
        self.pill = pill
        pill.show()
    }

    // MARK: Menu actions

    func openLastExport() {
        guard let url = defaults.lastExportURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLastRecording() {
        guard let url = defaults.lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindow(model: self)
        }
        onboarding?.show()
    }

    /// Relaunches so a pending grant takes effect; refused while a take, a
    /// render or a recovery runs, since quitting mid-way would leave it to
    /// the next launch's recovery.
    func relaunch() {
        guard !isBusy else { return }
        relaunchError = nil
        Task {
            do {
                try await Relauncher.relaunch()
            } catch {
                relaunchError = error.localizedDescription
            }
        }
    }

    /// Quits through the application delegate, which settles what is half
    /// done first (`settleForQuit`) and then lets the termination proceed;
    /// ⌘Q from the main menu, the Dock tile's Quit and a logout reach the
    /// same delegate, so every quit path is this one.
    func quit() {
        areaSelection?.cancel()
        NSApp.terminate(nil)
    }

    /// What an orderly quit waits for (`AppDelegate.applicationShouldTerminate`):
    /// a take still starting, recording or finishing is stopped and its
    /// package completed (seconds), a render in flight is cancelled rather
    /// than waited for (minutes for a long take; the package is complete and
    /// Render Last Recording redoes it), a recovered package's finish is
    /// waited for the same way, and every open editor writes its pending
    /// save and drops its export in flight. Runs once; a second call returns
    /// at once.
    func settleForQuit() async {
        guard !quitting else { return }
        quitting = true
        areaSelection?.cancel()
        await recorder.stop()
        await recorder.cancelRender()
        await recovery?.settleForQuit()
        EditorActivation.shared.closeAllForQuit()
    }

    /// Whether `settleForQuit` has run.
    var isQuitting: Bool { quitting }

    // MARK: Devices

    func refreshDisplays() {
        let mainID = CGMainDisplayID()
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayChoice(
                id: id, name: screen.localizedName, widthPoints: Int(screen.frame.width),
                heightPoints: Int(screen.frame.height), isMain: id == mainID)
        }
    }

    /// Lists the microphones. Discovery needs no permission; the grant is
    /// asked for when one is picked.
    func refreshMicrophones() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        microphones = discovery.devices.map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Lists the cameras, Continuity Cameras included. Discovery never
    /// prompts; the grant is asked for when one is picked.
    func refreshCameras() {
        cameras = CameraRecorder.availableCameras()
    }

    /// Lists the windows Record Window ▸ offers, through ScreenCaptureKit,
    /// which `ShareableContent` refuses to call until Screen Recording is
    /// usable, so this never prompts. One listing at a time, and none within
    /// `sourceSettings.windowListRefreshInterval` of the last.
    func refreshWindows(force: Bool = false) {
        guard permissions.canRecord, windowListTask == nil else { return }
        if !force, let fetchedAt = windowListFetchedAt,
            Date().timeIntervalSince(fetchedAt) < sourceSettings.windowListRefreshInterval
        {
            return
        }
        let own = Bundle.main.bundleIdentifier
        let settings = sourceSettings
        let permissions = permissions.permissions
        windowListTask = Task { [weak self] in
            defer { self?.windowListTask = nil }
            do {
                // Every Space, not just the current one: a window the user wants is
                // often behind a full-screen app.
                let content = try await ShareableContent.current(permissions: permissions, onScreenWindowsOnly: false)
                let groups = WindowsByApplication.grouped(
                    content.windowSummaries, excludingBundleID: own, settings: settings)
                guard let self else { return }
                windowGroups = groups
                windowListError = nil
                windowListFetchedAt = Date()
            } catch {
                guard let self else { return }
                windowGroups = []
                windowListError = error.localizedDescription
                windowListFetchedAt = Date()
            }
        }
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AppModel) -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            })
    }
}
