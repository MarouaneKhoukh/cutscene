import AppKit
import CutsceneCapture
import Foundation
import Observation

/// Where the four capabilities stand, as the menu and the onboarding window
/// see them (ARCHITECTURE §7).
///
/// Wraps the Capture module's `Permissions`, whose relaunch baseline is taken
/// when this model is created at launch, and re-preflights on
/// `didBecomeActiveNotification` (the user comes back from System Settings
/// or from the system's own prompt) and once per `refreshInterval` while
/// onboarding is visible, so a switch flipped there shows up as
/// `.grantedPendingRelaunch` without a click. The periodic preflights run
/// off the main actor: `CGPreflightListenEventAccess` alone costs 13–19 ms
/// a call (platform-notes), which the window would otherwise pay every
/// second. A Screen Recording or Input Monitoring request is answered in a
/// dialog the system puts up later, so until the app becomes active again
/// (or `answerTimeout` passes) a false preflight after a request still
/// reads as "not determined", not "declined". Nothing here prompts except
/// `request`, which only a button reaches.
@MainActor @Observable final class PermissionsModel {
    /// The Capture-side object, handed to every `CaptureSession` so the
    /// session and the UI agree on the relaunch baseline.
    let permissions: Permissions
    let refreshInterval: TimeInterval
    /// How long after a request a false preflight is still read as waiting
    /// for the user's answer when no activation has shown the dialog gone.
    let answerTimeout: TimeInterval
    /// Every capability's state as of the last preflight.
    private(set) var states: [Capability: PermissionState]
    /// Toggled by the onboarding window; drives the periodic re-preflight.
    var isOnboardingVisible = false {
        didSet { updatePolling() }
    }

    private var pollingTask: Task<Void, Never>?
    /// Kept for the life of the model, which is the life of the process, so
    /// it is never removed.
    private var activationObserver: (any NSObjectProtocol)?
    /// Capabilities asked for whose answer has not been seen yet, with the
    /// time of the ask.
    private var awaitingAnswer: [Capability: Date] = [:]

    init(refreshInterval: TimeInterval, answerTimeout: TimeInterval) {
        permissions = Permissions()
        self.refreshInterval = refreshInterval
        self.answerTimeout = answerTimeout
        states = Dictionary(uniqueKeysWithValues: permissions.preflightAll())
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    func state(of capability: Capability) -> PermissionState {
        states[capability] ?? .notDetermined
    }

    var screenRecording: PermissionState { state(of: .screenRecording) }

    /// Whether a take can start: Screen Recording usable by this process.
    var canRecord: Bool { screenRecording == .granted }

    /// Whether some grant waits for a relaunch to reach this process.
    var relaunchNeeded: Bool {
        states.values.contains(.grantedPendingRelaunch)
    }

    /// Re-preflights every capability, on the main actor. Never prompts.
    func refresh() {
        publish(Dictionary(uniqueKeysWithValues: permissions.preflightAll()))
    }

    /// Asks the system for `capability` (the one call that may prompt), then
    /// re-preflights. For the capabilities the system answers later the
    /// state stays "not determined" until the answer can have arrived.
    @discardableResult
    func request(_ capability: Capability) async -> PermissionState {
        if Self.answersLater(capability) {
            awaitingAnswer[capability] = Date()
        }
        _ = await permissions.request(capability)
        refresh()
        return state(of: capability)
    }

    /// Opens the System Settings pane for `capability`; no prompt, the user
    /// flips the switch there.
    func openSystemSettings(for capability: Capability) {
        NSWorkspace.shared.open(capability.settingsURL)
    }

    // MARK: Private

    /// The app is active again: the system's dialog, if one was up, is gone,
    /// so a false preflight now means what it says.
    private func becameActive() {
        awaitingAnswer = [:]
        refresh()
    }

    /// Publishes a preflight, holding a requested-and-unanswered capability
    /// at "not determined". Unchanged states are not republished, so a
    /// one-second poll does not redraw the menu for nothing.
    private func publish(_ fresh: [Capability: PermissionState]) {
        var fresh = fresh
        let now = Date()
        awaitingAnswer = awaitingAnswer.filter { now.timeIntervalSince($0.value) < answerTimeout }
        for capability in awaitingAnswer.keys where fresh[capability] == .denied {
            fresh[capability] = .notDetermined
        }
        if fresh != states { states = fresh }
    }

    /// Whether the system answers a request for `capability` in a dialog of
    /// its own after the call returns (`Permissions.request`).
    private static func answersLater(_ capability: Capability) -> Bool {
        switch capability {
        case .screenRecording, .inputMonitoring: true
        case .microphone, .camera: false
        }
    }

    /// The preflights on the global executor, where their IPC round trips
    /// cost the window nothing.
    private nonisolated static func preflightAll(_ permissions: Permissions) async -> [Capability: PermissionState] {
        Dictionary(uniqueKeysWithValues: permissions.preflightAll())
    }

    private func updatePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isOnboardingVisible else { return }
        pollingTask = Task { [weak self, refreshInterval, permissions] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { return }
                let fresh = await Self.preflightAll(permissions)
                self?.publish(fresh)
            }
        }
    }
}
