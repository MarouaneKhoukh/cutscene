import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ShareableContentError: LocalizedError {
    case screenRecordingNotGranted(PermissionState)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingNotGranted(let state):
            "Screen Recording is \(state.rawValue), so the shareable content cannot be listed."
        }
    }
}

/// A display as a menu can list it: the `Sendable` part of an `SCDisplay`.
public struct DisplaySummary: Sendable, Equatable, Identifiable {
    public var id: CGDirectDisplayID
    public var widthPoints: Int
    public var heightPoints: Int
    /// Bounds in Quartz global coordinates, the space of `CGDisplayBounds`.
    public var frame: CGRect
    /// Whether this is the display the menu bar is on (`CGMainDisplayID`).
    public var isMain: Bool
}

/// A window as a picker can list it: the `Sendable` part of an `SCWindow`.
public struct WindowSummary: Sendable, Equatable, Identifiable {
    public var id: CGWindowID
    public var title: String?
    public var applicationName: String?
    public var bundleIdentifier: String?
    /// Frame in Quartz global coordinates.
    public var frame: CGRect
    /// `CGWindowLevel`; ordinary document windows sit at 0.
    public var layer: Int
    public var isOnScreen: Bool
    public var isActive: Bool
}

/// The displays, windows and applications ScreenCaptureKit lets this process
/// capture, fetched only once Screen Recording is `.granted`.
///
/// `SCShareableContent` is the call that raises the Screen Recording prompt,
/// and in a process that predates its grant it fails rather than works
/// (platform-notes), so `current()` refuses to make it in any other state and
/// never prompts. The objects it returns are not `Sendable`: they stay with
/// whoever fetched them, and the request that travels between the app and the
/// session names a source by identifier (`CaptureRequest.Source`), which
/// `display(id:)` and `window(id:)` resolve again on the session's side.
public struct ShareableContent {
    public let displays: [SCDisplay]
    public let windows: [SCWindow]
    public let applications: [SCRunningApplication]
    /// This process as ScreenCaptureKit lists it, which the display and area
    /// filters exclude so the menu bar item, the HUD and later windows stay
    /// out of the capture. Nil when ScreenCaptureKit lists no window of ours,
    /// in which case there is nothing to exclude yet.
    public let currentApplication: SCRunningApplication?

    /// Lists the content once Screen Recording is `.granted` per
    /// `permissions`; throws `screenRecordingNotGranted` otherwise, before any
    /// ScreenCaptureKit call. `excludingDesktopWindows` drops the desktop
    /// picture and icon windows, which no picker should offer; `onScreenWindowsOnly`
    /// drops windows on other Spaces and minimized ones.
    public static func current(
        permissions: Permissions = .shared, excludingDesktopWindows: Bool = true, onScreenWindowsOnly: Bool = true
    ) async throws -> ShareableContent {
        let state = permissions.preflight(.screenRecording)
        guard state == .granted else { throw ShareableContentError.screenRecordingNotGranted(state) }
        let content = try await SCShareableContent.excludingDesktopWindows(
            excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly)
        let processID = ProcessInfo.processInfo.processIdentifier
        return ShareableContent(
            displays: content.displays, windows: content.windows, applications: content.applications,
            currentApplication: content.applications.first { $0.processID == processID })
    }

    public init(
        displays: [SCDisplay], windows: [SCWindow], applications: [SCRunningApplication],
        currentApplication: SCRunningApplication?
    ) {
        self.displays = displays
        self.windows = windows
        self.applications = applications
        self.currentApplication = currentApplication
    }

    public func display(id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }

    public func window(id: CGWindowID) -> SCWindow? {
        windows.first { $0.windowID == id }
    }

    /// The display the menu bar is on, or the first one listed when
    /// ScreenCaptureKit does not list it (a display asleep or mirrored).
    public var mainDisplay: SCDisplay? {
        display(id: CGMainDisplayID()) ?? displays.first
    }

    /// The displays as `Sendable` rows, in ScreenCaptureKit's order.
    public var displaySummaries: [DisplaySummary] {
        let mainID = CGMainDisplayID()
        return displays.map {
            DisplaySummary(
                id: $0.displayID, widthPoints: $0.width, heightPoints: $0.height, frame: $0.frame,
                isMain: $0.displayID == mainID)
        }
    }

    /// The windows as `Sendable` rows, in ScreenCaptureKit's order (front to
    /// back). A picker filters by title and layer; nothing is dropped here.
    public var windowSummaries: [WindowSummary] {
        windows.map {
            WindowSummary(
                id: $0.windowID, title: $0.title, applicationName: $0.owningApplication?.applicationName,
                bundleIdentifier: $0.owningApplication?.bundleIdentifier, frame: $0.frame, layer: $0.windowLayer,
                isOnScreen: $0.isOnScreen, isActive: $0.isActive)
        }
    }
}
