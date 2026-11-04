import AVFoundation
import CoreGraphics
import Foundation
import Synchronization

/// The capabilities a recording may need from the user (ARCHITECTURE §7).
public enum Capability: String, Sendable, Codable, CaseIterable {
    /// Screen Recording: frames and system audio through ScreenCaptureKit.
    case screenRecording
    case microphone
    case camera
    /// Input Monitoring: keystrokes and exact click times from the event tap.
    /// Opt-in from Settings; the recorder works without it.
    case inputMonitoring

    /// The name System Settings uses.
    public var displayName: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// The System Settings pane for this capability, for when a request can
    /// no longer prompt: macOS asks once per app and then leaves the switch to
    /// the user.
    public var settingsURL: URL {
        let pane =
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .microphone: "Privacy_Microphone"
            case .camera: "Privacy_Camera"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
        // A fixed, well-formed literal: the only way this fails is a typo above.
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Where a capability stands for this process.
public enum PermissionState: String, Sendable, Codable, Equatable, CaseIterable {
    /// Never asked, as far as this process knows; a request may prompt.
    case notDetermined
    /// Declined, or restricted by management; only System Settings can change it.
    case denied
    /// Switched on since this process started. Screen Recording and Input
    /// Monitoring reach a process only when it launches (platform-notes), so
    /// the app has to relaunch before it can use the grant.
    case grantedPendingRelaunch
    /// Usable now.
    case granted

    /// Whether the capability can be used by this process right now.
    public var isUsable: Bool {
        self == .granted
    }
}

/// Where the four capabilities stand for this process, read without ever
/// prompting, and the one place that may prompt.
///
/// `CGPreflightScreenCaptureAccess` and `CGPreflightListenEventAccess` answer
/// yes or no, and they answer yes the moment the user flips the switch, even
/// though the running process gains nothing until it relaunches: the window
/// server decides at connection time (observed, platform-notes). So the two
/// preflights are remembered when this object is created, and a capability
/// that was off then and is on now is `.grantedPendingRelaunch`. That is why
/// the app creates `shared` at launch, before the user can have reached System
/// Settings. Microphone and camera take effect at once and report three
/// states of their own.
///
/// The two preflights also cannot tell "never asked" from "declined".
/// `request` records what it has asked for: a false preflight is
/// `.notDetermined` until then and `.denied` after. The record is this
/// process's, never persisted: TCC keeps the answer itself and macOS never
/// re-prompts an answered app, so asking again is harmless, while a record
/// outliving a `tccutil reset` (which development builds run on every code
/// change) would read as `.denied` for a capability the system is ready to
/// ask about. `previouslyRequested` seeds the record for a caller that wants
/// to carry it; the app does not.
///
/// Thread-safe; every method may be called from any thread.
public final class Permissions: @unchecked Sendable {
    /// The process-wide instance. Touch it at launch so its baseline predates
    /// any grant the user makes while the app runs.
    public static let shared = Permissions()

    private struct State {
        /// Preflight results when this object was created, for the
        /// capabilities whose grant needs a relaunch.
        var grantedAtStart: [Capability: Bool]
        var requested: Set<Capability>
    }

    private let state: Mutex<State>

    /// Takes the relaunch baseline now. `previouslyRequested` seeds the
    /// asked set from an earlier launch.
    public init(previouslyRequested: Set<Capability> = []) {
        state = Mutex(
            State(
                grantedAtStart: [
                    .screenRecording: CGPreflightScreenCaptureAccess(),
                    .inputMonitoring: CGPreflightListenEventAccess(),
                ],
                requested: previouslyRequested))
    }

    /// The capabilities a request has been made for, in this process or as
    /// seeded by `init`. Persist it so "ask once" holds across launches.
    public var requestedCapabilities: Set<Capability> {
        state.withLock { $0.requested }
    }

    /// Where `capability` stands now. Never prompts.
    public func preflight(_ capability: Capability) -> PermissionState {
        switch capability {
        case .screenRecording:
            relaunchRuled(capability, grantedNow: CGPreflightScreenCaptureAccess())
        case .inputMonitoring:
            relaunchRuled(capability, grantedNow: CGPreflightListenEventAccess())
        case .microphone:
            Self.state(of: AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            Self.state(of: AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    /// Every capability's state, in `Capability.allCases` order. Never prompts.
    public func preflightAll() -> [(Capability, PermissionState)] {
        Capability.allCases.map { ($0, preflight($0)) }
    }

    /// Asks the system for `capability` and returns the state afterwards.
    ///
    /// Every call asks: the system itself prompts at most once per app and
    /// answers silently after that, so a user who dismissed the Screen
    /// Recording dialog can press the button again. The Screen Recording and
    /// Input Monitoring prompts come back asynchronously, so the state
    /// returned is the one at the time of the call and the app re-preflights
    /// when it becomes active again. Microphone and camera wait for the
    /// user's answer. Input Monitoring is asked for from a Settings action
    /// only, never by the recording path.
    public func request(_ capability: Capability) async -> PermissionState {
        claimRequest(for: capability)
        switch capability {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        return preflight(capability)
    }

    /// Records the request, which is what turns a false preflight into `.denied`.
    private func claimRequest(for capability: Capability) {
        state.withLock { _ = $0.requested.insert(capability) }
    }

    private func relaunchRuled(_ capability: Capability, grantedNow: Bool) -> PermissionState {
        state.withLock { state in
            if grantedNow {
                return state.grantedAtStart[capability] == true ? .granted : .grantedPendingRelaunch
            }
            return state.requested.contains(capability) ? .denied : .notDetermined
        }
    }

    private static func state(of status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}
