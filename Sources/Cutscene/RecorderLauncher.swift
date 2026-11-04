import AVFoundation
import AppKit
import SwiftUI

/// The numbers the launcher is drawn with (fixed size, PLAN M1-F6).
struct LauncherSettings: Sendable, Equatable {
    var width = 860.0
    var height = 600.0
    var padding = 20.0
    var previewCornerRadius = 18.0
    var bubbleDiameter = 132.0
    var recordButtonDiameter = 64.0
    var chipCornerRadius = 12.0
}

/// What the launcher is pointed at. Area has no live preview: the selection
/// overlay is drawn on the screen itself and recording starts from it.
enum LauncherSource: Equatable {
    case display(DisplayChoice)
    case window(WindowChoice)
    case area
}

/// The recorder window: a live look at the source, the camera bubble as it
/// will appear, the microphone meter, one Record button, and the result.
struct RecorderLauncher: View {
    let model: AppModel
    var settings = LauncherSettings()

    @Environment(\.openWindow) private var openWindow
    @State private var preview = SourcePreviewModel()
    @State private var meter = MicrophoneLevelModel()
    @State private var source: LauncherSource?
    @State private var exportThumbnail: CGImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.10), Color(red: 0.11, green: 0.10, blue: 0.17)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                header
                sourcePicker
                previewCard
                controls
            }
            .padding(settings.padding)
        }
        .frame(width: settings.width, height: settings.height)
        .preferredColorScheme(.dark)
        .background(FloatingWindowConfigurator())
        .onAppear {
            NSApp.activate()
            model.refreshDisplays()
            model.refreshWindows()
            model.refreshMicrophones()
            model.refreshCameras()
            if source == nil, let display = model.displays.first(where: \.isMain) ?? model.displays.first {
                source = .display(display)
            }
            syncPreview()
            syncMeter()
        }
        .onDisappear {
            preview.stop()
            meter.stop()
        }
        .onChange(of: source) { syncPreview() }
        .onChange(of: model.recorder.isBusy) {
            syncPreview(); syncMeter()
        }
        .onChange(of: model.defaults.microphoneID) { syncMeter() }
        .onChange(of: model.lastExportURL) { loadExportThumbnail() }
        .task { loadExportThumbnail() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle").font(.title2).foregroundStyle(.red)
            Text("Cutscene").font(.title2.weight(.semibold))
            stateBadge
            Spacer()
            Button {
                if let url = model.lastRecordingURL { openWindow(id: AppModel.editorWindowID, value: url) }
            } label: {
                Label("Edit last take", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .disabled(model.lastRecordingURL == nil)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch model.recorder.state {
        case .recording:
            badge("Recording", color: .red)
        case .countdown, .selecting:
            badge("Starting", color: .orange)
        case .finishing:
            badge("Finishing", color: .orange)
        case .rendering:
            badge("Rendering", color: .blue)
        case .failed, .renderFailed:
            badge("Failed", color: .red)
        case .idle, .done:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Source

    private var sourcePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: sourceKind) {
                Label("Display", systemImage: "display").tag(0)
                Label("Window", systemImage: "macwindow").tag(1)
                Label("Area", systemImage: "rectangle.dashed").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .disabled(model.recorder.isBusy)

            switch source {
            case .display(let chosen):
                Menu {
                    ForEach(model.displays) { display in
                        Button(display.menuTitle) { source = .display(display) }
                    }
                } label: {
                    Label(chosen.menuTitle, systemImage: "display")
                }
                .fixedSize()
            case .window(let chosen):
                Menu {
                    ForEach(model.windowGroups) { group in
                        Section(group.applicationName) {
                            ForEach(group.windows) { window in
                                Button(window.menuTitle(limit: model.sourceSettings.windowTitleLimit)) {
                                    source = .window(window)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Refresh windows") { model.refreshWindows() }
                } label: {
                    Label("\(chosen.applicationName) · \(chosen.title)", systemImage: "macwindow")
                        .lineLimit(1)
                }
                .fixedSize()
            case .area:
                Text("Press Record, then drag the area to capture.")
                    .font(.callout).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            Spacer()
        }
        .disabled(model.recorder.isBusy)
    }

    private var sourceKind: Binding<Int> {
        Binding(
            get: {
                switch source {
                case .display, nil: 0
                case .window: 1
                case .area: 2
                }
            },
            set: { kind in
                switch kind {
                case 1:
                    model.refreshWindows()
                    if let window = model.windowGroups.first?.windows.first { source = .window(window) }
                case 2:
                    source = .area
                default:
                    if let display = model.displays.first(where: \.isMain) ?? model.displays.first {
                        source = .display(display)
                    }
                }
            })
    }

    // MARK: Preview

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: settings.previewCornerRadius)
                .fill(Color.black.opacity(0.55))
            if let image = preview.image, !model.recorder.isBusy, source != .area {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: settings.previewCornerRadius - 4))
                    .padding(6)
            } else {
                previewPlaceholder
            }
            cameraBubble
            if !model.permissions.canRecord {
                permissionOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: settings.previewCornerRadius).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private var previewPlaceholder: some View {
        switch model.recorder.state {
        case .countdown(let remaining):
            Text("\(remaining)").font(.system(size: 120, weight: .bold, design: .rounded))
        case .selecting:
            ProgressView().controlSize(.large)
        case .recording:
            VStack(spacing: 8) {
                Image(systemName: "record.circle.fill").font(.system(size: 44)).foregroundStyle(.red)
                Text(elapsed).font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
                Text("\(model.recorder.statistics.frames.contentFrames) frames · \(model.recorder.markerCount) markers")
                    .foregroundStyle(.secondary)
            }
        case .finishing:
            VStack(spacing: 8) {
                ProgressView(); Text("Finishing the take…").foregroundStyle(.secondary)
            }
        case .rendering(let progress):
            VStack(spacing: 10) {
                ProgressView(value: progress ?? 0).frame(width: 260)
                Text(progress.map { "Rendering… \(Int(($0 * 100).rounded())) %" } ?? "Rendering…")
                    .foregroundStyle(.secondary)
            }
        case .done, .idle, .failed, .renderFailed:
            if source == .area {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("The area is chosen on screen when you press Record.").foregroundStyle(.secondary)
                }
            } else if case .done = model.recorder.state, let thumbnail = exportThumbnail {
                resultCard(thumbnail)
            } else if case .failed(let error, _) = model.recorder.state {
                failure("Recording failed", error)
            } else if case .renderFailed(let error, _) = model.recorder.state {
                failure("Export failed", error)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing the preview…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultCard(_ thumbnail: CGImage) -> some View {
        VStack(spacing: 12) {
            Image(decorative: thumbnail, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 18, y: 8)
            HStack(spacing: 10) {
                Button {
                    model.openLastExport()
                } label: {
                    Label("Open", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    if let url = model.lastRecordingURL { openWindow(id: AppModel.editorWindowID, value: url) }
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                Button {
                    model.revealLastRecording()
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Button {
                    if let url = model.lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("Export in Finder", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func failure(_ title: String, _ error: any Error) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(error.localizedDescription).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding()
    }

    @ViewBuilder private var cameraBubble: some View {
        if let cameraID = model.sources.cameraID, !model.recorder.isBusy {
            let camera = model.cameras.first { $0.id == cameraID }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CameraPreviewView(deviceID: cameraID, mirrored: camera?.isBuiltIn ?? true)
                        .frame(width: settings.bubbleDiameter, height: settings.bubbleDiameter)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                        .shadow(radius: 14, y: 6)
                        .padding(22)
                }
            }
        }
    }

    private var permissionOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 36))
            Text("Screen Recording is not granted to this build").font(.headline)
            Text(
                model.permissions.relaunchNeeded
                    ? "The grant exists; relaunch so this process can use it."
                    : "Grant it in System Settings, then relaunch."
            )
            .foregroundStyle(.secondary)
            HStack {
                Button("Grant…") { model.showOnboarding() }.buttonStyle(.borderedProminent)
                if model.permissions.relaunchNeeded {
                    Button("Relaunch Cutscene") { model.relaunch() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            microphoneChip
            cameraChip
            systemAudioChip
            Spacer()
            recordButton
        }
    }

    private var microphoneChip: some View {
        chip {
            Image(systemName: model.defaults.microphoneID == nil ? "mic.slash" : "mic.fill")
            Menu {
                Button("Off") { model.selectMicrophone(nil) }
                ForEach(model.microphones) { microphone in
                    Button(microphone.name) { model.selectMicrophone(microphone.id) }
                }
            } label: {
                Text(model.microphones.first { $0.id == model.defaults.microphoneID }?.name ?? "No microphone")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            levelMeter
        }
    }

    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(meter.level > 0.85 ? Color.red : Color.green)
                    .frame(width: max(0, geometry.size.width * meter.level))
            }
        }
        .frame(width: 70, height: 6)
        .opacity(model.defaults.microphoneID == nil ? 0.3 : 1)
    }

    private var cameraChip: some View {
        chip {
            Image(systemName: model.sources.cameraID == nil ? "video.slash" : "video.fill")
            Menu {
                Button("Off") { model.selectCamera(nil) }
                ForEach(model.cameras) { camera in
                    Button(camera.name) { model.selectCamera(camera.id) }
                }
            } label: {
                Text(model.cameras.first { $0.id == model.sources.cameraID }?.name ?? "No camera").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var systemAudioChip: some View {
        @Bindable var defaults = model.defaults
        return chip {
            Image(systemName: defaults.systemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            Toggle("System audio", isOn: $defaults.systemAudio).toggleStyle(.switch).controlSize(.small)
        }
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: settings.chipCornerRadius))
            .disabled(model.recorder.isBusy)
    }

    @ViewBuilder private var recordButton: some View {
        switch model.recorder.state {
        case .recording:
            Button {
                model.stop()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("Stop").font(.headline)
                }
                .frame(width: 120, height: settings.recordButtonDiameter - 16)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .keyboardShortcut(".", modifiers: .command)
        case .countdown, .selecting, .finishing, .rendering:
            Button {
                model.stop()
            } label: {
                Text("Cancel").frame(width: 120, height: settings.recordButtonDiameter - 16)
            }
            .buttonStyle(.bordered)
        case .idle, .done, .failed, .renderFailed:
            Button(action: startRecording) {
                ZStack {
                    Circle().fill(Color.red)
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).padding(5)
                }
                .frame(width: settings.recordButtonDiameter, height: settings.recordButtonDiameter)
                .shadow(color: .red.opacity(0.5), radius: 14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.permissions.canRecord || model.isBusy || source == nil)
            .help("Record (⌘R)")
        }
    }

    // MARK: Actions and sync

    private func startRecording() {
        preview.stop()
        meter.stop()
        switch source {
        case .display(let display): model.record(display: display)
        case .window(let window): model.record(window: window)
        case .area: model.recordArea()
        case nil: break
        }
    }

    private func syncPreview() {
        guard model.permissions.canRecord, !model.recorder.isBusy else {
            preview.stop()
            return
        }
        switch source {
        case .display(let display): preview.start(.display(display.id))
        case .window(let window): preview.start(.window(window.id))
        case .area, nil: preview.stop()
        }
    }

    private func syncMeter() {
        if model.defaults.microphoneID != nil, !model.recorder.isBusy {
            meter.start()
        } else {
            meter.stop()
        }
    }

    private func loadExportThumbnail() {
        guard let url = model.lastExportURL else {
            exportThumbnail = nil
            return
        }
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 720)
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                exportThumbnail = image
            }
        }
    }

    private var elapsed: String {
        Duration.seconds(model.recorder.elapsedSeconds).formatted(.time(pattern: .minuteSecond))
    }
}
