import AppKit
import CutsceneCapture
import SwiftUI

/// The menu-bar icon: the recorder's state at a glance.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.recorder.state.menuBarSymbolName)
    }
}

/// The menu under the icon (ARCHITECTURE §1, PLAN M1-12 and M2-09): Record
/// Display ▸ displays, Record Window ▸ titles by application, Record Area…,
/// Microphone ▸ devices or off, System Audio, Camera ▸ devices or off, Stop,
/// Open Last Export, Open Last Recording (the editor), Reveal Last
/// Recording, Settings…, Quit. The same view fills the recorder window
/// (`RecorderPanel`), so the two never drift apart.
struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var defaults = model.defaults
        recordItems
        Divider()
        Picker("Microphone", selection: microphoneSelection) {
            Text("Off").tag(String?.none)
            ForEach(model.microphones) { microphone in
                Text(microphone.name).tag(Optional(microphone.id))
            }
            if let stale = disconnectedMicrophoneID {
                Text("Chosen microphone (disconnected)").tag(Optional(stale))
            }
        }
        Toggle("System Audio", isOn: $defaults.systemAudio)
        CameraPicker(model: model)
        Divider()
        Button("Show Recorder") { openWindow(id: "recorder") }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Menu("Open Recording") {
            ForEach(model.recentPackages, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    openWindow(id: AppModel.editorWindowID, value: url)
                }
            }
            if !model.recentPackages.isEmpty { Divider() }
            Button("Other Recording…") {
                model.openRecording { openWindow(id: AppModel.editorWindowID, value: $0) }
            }
        }
        Button("Open Last Export") { model.openLastExport() }
            .disabled(model.lastExportURL == nil)
        Button("Open Last Recording") {
            if let url = model.lastRecordingURL {
                openWindow(id: AppModel.editorWindowID, value: url)
            }
        }
        .disabled(model.lastRecordingURL == nil)
        Button("Reveal Last Recording") { model.revealLastRecording() }
            .disabled(model.lastRecordingURL == nil)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Cutscene") { model.quit() }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var recordItems: some View {
        switch model.recorder.state {
        case .idle, .done, .failed, .renderFailed:
            if model.recoveryBusy {
                // The recovery window is finishing or rendering a package;
                // a take beside its export would share the encoder.
                Text("Finishing a recovered recording…")
            } else if model.permissions.canRecord {
                Menu("Record Display") {
                    if model.displays.isEmpty {
                        Text("No displays")
                    }
                    ForEach(model.displays) { display in
                        Button(display.menuTitle) { model.record(display: display) }
                    }
                }
                RecordWindowMenu(model: model)
                RecordAreaButton(model: model)
            } else {
                Button("Record Display…") { model.showOnboarding() }
                Text(permissionHint)
                if model.permissions.relaunchNeeded {
                    Button("Relaunch Cutscene") { model.relaunch() }
                }
            }
            lastTakeLine
            if model.lastRecordingURL != nil {
                Button("Render Last Recording") { model.renderLastRecording() }
                    .disabled(model.isBusy)
            }
        case .countdown(let remaining):
            Button("Cancel") { model.stop() }
            Text("Recording in \(remaining)…")
        case .selecting:
            Text("Starting…")
        case .recording:
            Button(model.recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                if model.recorder.isPaused { model.resume() } else { model.pause() }
            }
            Button("Stop Recording") { model.stop() }
            Button("Add Marker") { model.mark() }
            Text(recordingStatus)
        case .finishing:
            Text("Finishing…")
        case .rendering(let progress):
            Text(progress.map { "Rendering… \(Int(($0 * 100).rounded())) %" } ?? "Rendering…")
        }
    }

    @ViewBuilder private var lastTakeLine: some View {
        switch model.recorder.state {
        case .done(let url):
            Text("Last take: \(url.lastPathComponent)")
            if let warning = model.recorder.markerWarning {
                Text(truncated(warning))
            }
        case .failed(let error, _):
            Text("Recording failed: \(truncated(error.localizedDescription))")
        case .renderFailed(let error, _):
            Text("Export failed: \(truncated(error.localizedDescription))")
        case .idle, .countdown, .selecting, .recording, .finishing, .rendering:
            EmptyView()
        }
    }

    private var microphoneSelection: Binding<String?> {
        Binding(get: { model.defaults.microphoneID }, set: { model.selectMicrophone($0) })
    }

    /// The chosen microphone when it is not connected right now, so the
    /// picker still has a row to mark.
    private var disconnectedMicrophoneID: String? {
        guard let chosen = model.defaults.microphoneID, !model.microphones.contains(where: { $0.id == chosen })
        else { return nil }
        return chosen
    }

    private var permissionHint: String {
        switch model.permissions.screenRecording {
        case .notDetermined: "Screen Recording has not been granted yet"
        case .denied: "Screen Recording is off in System Settings"
        case .grantedPendingRelaunch: "Relaunch to use the new Screen Recording grant"
        case .granted: ""
        }
    }

    private var recordingStatus: String {
        let elapsed = Duration.seconds(model.recorder.elapsedSeconds).formatted(.time(pattern: .minuteSecond))
        let frames = model.recorder.statistics.frames.contentFrames
        let dropped = model.recorder.statistics.dropped.screenFrames
        let markers = model.recorder.markerCount
        return "Recording · \(elapsed) · \(frames) frames" + (dropped > 0 ? " · \(dropped) dropped" : "")
            + (markers > 0 ? " · \(markers) markers" : "")
    }

    private func truncated(_ message: String) -> String {
        let limit = model.settings.menuMessageLimit
        guard message.count > limit else { return message }
        return String(message.prefix(limit)) + "…"
    }
}

extension RecorderController.State {
    /// The SF Symbol the menu bar shows for this state.
    var menuBarSymbolName: String {
        switch self {
        case .idle, .done: "record.circle"
        case .countdown: "timer"
        case .selecting: "circle.dotted"
        case .recording: "record.circle.fill"
        case .finishing: "stop.circle.fill"
        case .rendering: "gearshape"
        case .failed, .renderFailed: "exclamationmark.circle"
        }
    }
}
