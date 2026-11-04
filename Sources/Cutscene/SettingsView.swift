import AppKit
import CutsceneCore
import SwiftUI

/// The numbers the settings window is drawn with (fixed size, PLAN M1-F6).
struct SettingsViewSettings: Sendable, Equatable {
    var width = 560.0
    var height = 520.0
}

/// Working settings: every control writes through `Defaults` (persisted in
/// `UserDefaults`) and the recorder reads those defaults when a take starts,
/// so a choice made here drives the next launch as well.
struct SettingsView: View {
    let model: AppModel
    var settings = SettingsViewSettings()

    var body: some View {
        @Bindable var defaults = model.defaults
        Form {
            Section("Recording") {
                Picker("Microphone", selection: microphoneSelection) {
                    Text("Off").tag(String?.none)
                    ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("settings.microphone")
                Picker("Camera", selection: cameraSelection) {
                    Text("Off").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("settings.camera")
                Toggle("Record system audio", isOn: $defaults.systemAudio)
                    .accessibilityIdentifier("settings.systemAudio")
                Stepper(value: $defaults.countdownSeconds, in: 0...10) {
                    LabeledContent(
                        "Countdown", value: defaults.countdownSeconds == 0 ? "Off" : "\(defaults.countdownSeconds) s")
                }
                .accessibilityIdentifier("settings.countdown")
            }

            Section("Export") {
                Picker("Default preset", selection: $defaults.defaultPresetID) {
                    ForEach(ExportPresetID.allCases, id: \.rawValue) { preset in
                        Text(Self.title(of: preset)).tag(preset.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.defaultPreset")
                Text("Used by the automatic render after each take and as the editor's starting preset.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Folders") {
                folderRow("Recordings", url: defaults.recordingsDirectory, identifier: "settings.recordingsFolder") {
                    defaults.recordingsDirectory = $0
                }
                folderRow("Exports", url: defaults.exportsDirectory, identifier: "settings.exportsFolder") {
                    defaults.exportsDirectory = $0
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: settings.width, height: settings.height)
        .onAppear {
            model.refreshMicrophones()
            model.refreshCameras()
        }
    }

    private var microphoneSelection: Binding<String?> {
        Binding(get: { model.defaults.microphoneID }, set: { model.selectMicrophone($0) })
    }

    private var cameraSelection: Binding<String?> {
        Binding(get: { model.sources.cameraID }, set: { model.selectCamera($0) })
    }

    private func folderRow(
        _ title: String, url: URL, identifier: String, onChange: @escaping @MainActor (URL) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    panel.begin { response in
                        guard response == .OK, let chosen = panel.url else { return }
                        MainActor.assumeIsolated { onChange(chosen) }
                    }
                }
                .accessibilityIdentifier(identifier)
            }
        }
    }

    static func title(of preset: ExportPresetID) -> String {
        switch preset {
        case .hd1080: "1080p · 16:9"
        case .uhd4K: "4K · 16:9"
        case .vertical1080: "Vertical 1080×1920 · 9:16"
        case .square1080: "Square 1080×1080 · 1:1"
        }
    }
}
