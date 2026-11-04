import AppKit
import CutsceneCapture
import CutsceneCore
import Foundation
import Observation
import SwiftUI

/// The numbers the source menus run on (PLAN M2-09).
struct SourceMenuSettings: Sendable, Equatable {
    /// Smallest window listed, in points on each side: anything under it is
    /// a tooltip, a status item or a helper window nobody means to record.
    var minimumWindowSide = 64.0
    /// Only windows on this `CGWindowLevel` are listed: ordinary document
    /// windows sit at 0, while menus, panels, the Dock and the menu bar live
    /// on other levels and are no take of their own.
    var listedWindowLayer = 0
    /// Characters of a window title a menu item shows before it is cut; a
    /// browser tab's title can run to a sentence.
    var windowTitleLimit = 60
    /// Seconds a window listing stays fresh: a menu opened again within it
    /// is served from the last listing rather than another
    /// `SCShareableContent` round trip, which costs tens of milliseconds.
    var windowListRefreshInterval: TimeInterval = 1
}

/// A window as the Record Window menu lists it: the `Sendable` facts of an
/// `SCWindow` the request and the package name need.
struct WindowChoice: Identifiable, Sendable, Equatable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let bundleID: String
    /// Frame in Quartz global coordinates (`SCWindow.frame`).
    let frame: CGRect

    /// The manifest's description of this window, for the package name;
    /// the session records the frame it resolves at start, so the frame here
    /// is only a placeholder.
    var namedSource: CaptureSource {
        .window(
            WindowSource(
                windowID: id, title: title, bundleID: bundleID, applicationName: applicationName,
                frame: PointRect(x: 0, y: 0, width: frame.width, height: frame.height), strategy: .displaySurface))
    }

    /// `title` cut to `limit` characters for a one-line menu item.
    func menuTitle(limit: Int) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit)) + "…"
    }
}

/// The windows of one application, as the Record Window menu groups them.
struct WindowsByApplication: Identifiable, Sendable, Equatable {
    let applicationName: String
    let bundleID: String
    let windows: [WindowChoice]

    var id: String { bundleID }

    /// Groups `summaries` by owning application, dropping windows the menu
    /// should not offer: other levels than `settings.listedWindowLayer`,
    /// off-screen and untitled windows, tiny ones, and our own. Applications
    /// and titles come out sorted so the menu reads the same every time.
    static func grouped(
        _ summaries: [WindowSummary], excludingBundleID own: String?, settings: SourceMenuSettings
    ) -> [WindowsByApplication] {
        var byApplication: [String: (name: String, windows: [WindowChoice])] = [:]
        for summary in summaries {
            // Windows on other Spaces, minimised ones and untitled ones are all
            // recordable, so only the layer, a usable size and the owner filter.
            guard summary.layer == settings.listedWindowLayer,
                summary.frame.width >= settings.minimumWindowSide, summary.frame.height >= settings.minimumWindowSide,
                let bundleID = summary.bundleIdentifier, bundleID != own
            else { continue }
            let name = summary.applicationName ?? bundleID
            let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Helper processes (AutoFill panels, control-centre helpers) own
            // layer-0 windows nobody wants to record; off-screen windows are
            // offered only when they carry a title, which real documents do.
            let helper =
                name.localizedCaseInsensitiveContains("helper") || name.localizedCaseInsensitiveContains("autofill")
            if helper || (!summary.isOnScreen && title.isEmpty) { continue }
            let choice = WindowChoice(
                id: summary.id, title: title, applicationName: name, bundleID: bundleID, frame: summary.frame)
            byApplication[bundleID, default: (name, [])].windows.append(choice)
        }
        return byApplication.map { bundleID, entry in
            WindowsByApplication(
                applicationName: entry.name, bundleID: bundleID,
                windows: entry.windows.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                })
        }
        .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
    }
}

/// The user's source choices that outlive the menu: the camera and the
/// window strategy. Kept in `UserDefaults` the way `Defaults` keeps the
/// microphone, in this file so the M2-09 surface stays in one place; M3-09's
/// settings window reads them from here.
@MainActor @Observable final class SourceChoices {
    enum Key: String, CaseIterable {
        case cameraID = "recorder.cameraID"
        case windowStrategy = "recorder.windowStrategy"
    }

    private let store: UserDefaults

    /// `AVCaptureDevice.uniqueID` of the camera to record, nil for none.
    var cameraID: String? {
        didSet { store.set(cameraID, forKey: Key.cameraID.rawValue) }
    }
    /// How a window is captured; `.displaySurface` is the default spike S4
    /// confirmed (platform-notes "Window capture").
    var windowStrategy: CaptureRequest.WindowStrategy {
        didSet { store.set(windowStrategy.rawValue, forKey: Key.windowStrategy.rawValue) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        cameraID = store.string(forKey: Key.cameraID.rawValue)
        windowStrategy =
            store.string(forKey: Key.windowStrategy.rawValue).flatMap(CaptureRequest.WindowStrategy.init(rawValue:))
            ?? CaptureRequest(source: .display(CGMainDisplayID())).windowStrategy
    }
}

/// Record Window ▸ one submenu per application, its windows by title.
/// The listing comes from ScreenCaptureKit, so it exists only once Screen
/// Recording is usable; `AppModel.refreshWindows` fills it when a menu opens.
struct RecordWindowMenu: View {
    let model: AppModel

    var body: some View {
        Menu("Record Window") {
            if model.windowGroups.isEmpty {
                Text(model.windowListError ?? "No windows to record")
            }
            ForEach(model.windowGroups) { group in
                Menu(group.applicationName) {
                    ForEach(group.windows) { window in
                        Button(window.menuTitle(limit: model.sourceSettings.windowTitleLimit)) {
                            model.record(window: window)
                        }
                    }
                }
            }
        }
    }
}

/// Record Area…: opens the selection overlay on every display.
struct RecordAreaButton: View {
    let model: AppModel

    var body: some View {
        Button("Record Area…") { model.recordArea() }
            .disabled(model.isSelectingArea)
    }
}

/// Camera ▸ devices or off. The first pick asks for the camera grant (§7
/// "on first toggle"); the system remembers the answer, so later picks are
/// silent.
struct CameraPicker: View {
    let model: AppModel

    var body: some View {
        Picker("Camera", selection: selection) {
            Text("Off").tag(String?.none)
            ForEach(model.cameras) { camera in
                Text(camera.name).tag(Optional(camera.id))
            }
            if let stale = disconnectedCameraID {
                Text("Chosen camera (disconnected)").tag(Optional(stale))
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.sources.cameraID }, set: { model.selectCamera($0) })
    }

    /// The chosen camera when it is not connected right now, so the picker
    /// still has a row to mark.
    private var disconnectedCameraID: String? {
        guard let chosen = model.sources.cameraID, !model.cameras.contains(where: { $0.id == chosen }) else {
            return nil
        }
        return chosen
    }
}
