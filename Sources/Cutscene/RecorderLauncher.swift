import AVFoundation
import AppKit
import CutsceneCore
import SwiftUI

/// The numbers the launcher is drawn with (fixed size, PLAN M1-F6).
struct LauncherSettings: Sendable, Equatable {
    var width = 880.0
    var height = 620.0
    var padding = 20.0
    var previewCornerRadius = 18.0
    var bubbleSize = 150.0
    var bubbleCornerRadius = 32.0
    var recordButtonDiameter = 64.0
    var chipCornerRadius = 12.0
    var thumbnailPixels = 480.0
    var thumbnailWidth = 220.0
}

/// What the launcher is pointed at.
enum LauncherSource: Equatable {
    case display(DisplayChoice)
    case window(WindowChoice)
    case area(AreaSelection)
}

private enum SourceKind: Int {
    case display, window, area
}

/// The recorder window: a live look at the source, the camera bubble as it
/// will appear, the microphone meter, one Record button, and the result.
struct RecorderLauncher: View {
    let model: AppModel
    var settings = LauncherSettings()

    @Environment(\.openWindow) private var openWindow
    @State private var preview = SourcePreviewModel()
    @State private var meter = MicrophoneLevelModel()
    @State private var teleprompter = TeleprompterController()
    @State private var kind: SourceKind = .display
    @State private var source: LauncherSource?
    @State private var windowThumbnails: [CGWindowID: CGImage] = [:]
    @State private var choosingWindow = false
    @State private var exportThumbnail: CGImage?
    @State private var showsTeleprompter = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.10), Color(red: 0.11, green: 0.10, blue: 0.17)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                header
                sourceBar
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
            if source == nil { chooseMainDisplay() }
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
        case .recording: badge("Recording", color: .red)
        case .countdown, .selecting: badge("Starting", color: .orange)
        case .finishing: badge("Finishing", color: .orange)
        case .rendering: badge("Rendering", color: .blue)
        case .failed, .renderFailed: badge("Failed", color: .red)
        case .idle, .done: EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Source bar

    private var sourceBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: kindBinding) {
                Label("Display", systemImage: "display").tag(SourceKind.display)
                Label("Window", systemImage: "macwindow").tag(SourceKind.window)
                Label("Area", systemImage: "rectangle.dashed").tag(SourceKind.area)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

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
                Label("\(chosen.applicationName) · \(chosen.title)", systemImage: "macwindow").lineLimit(1)
                Button("Change…") { beginChoosingWindow() }.buttonStyle(.bordered)
            case .area(let area):
                Label("\(Int(area.rect.width)) × \(Int(area.rect.height)) pt", systemImage: "rectangle.dashed")
                Button("Change…") { pickArea() }.buttonStyle(.bordered)
            case nil:
                if kind == .window {
                    Text("Pick a window below").foregroundStyle(.secondary)
                } else if kind == .area {
                    Button("Choose an area…") { pickArea() }.buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .disabled(model.recorder.isBusy)
    }

    private var kindBinding: Binding<SourceKind> {
        Binding(get: { kind }) { newKind in
            guard newKind != kind else { return }
            kind = newKind
            switch newKind {
            case .display: chooseMainDisplay()
            case .window:
                source = nil
                beginChoosingWindow()
            case .area:
                source = nil
                pickArea()
            }
        }
    }

    private func chooseMainDisplay() {
        if let display = model.displays.first(where: \.isMain) ?? model.displays.first {
            source = .display(display)
        }
    }

    private func beginChoosingWindow() {
        model.refreshWindows()
        choosingWindow = true
        let ids = model.windowGroups.flatMap { $0.windows.map(\.id) }
        let pixels = settings.thumbnailPixels
        Task {
            let frames = await SourceScreenshots.thumbnails(for: ids, maximumPixels: pixels)
            windowThumbnails = frames.mapValues(\.image)
        }
    }

    private func pickArea() {
        model.pickArea { selection in
            if let selection {
                source = .area(selection)
            } else if source == nil {
                kind = .display
                chooseMainDisplay()
            }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: settings.previewCornerRadius)
                .fill(Color.black.opacity(0.55))
            if kind == .window, choosingWindow || source == nil, !model.recorder.isBusy {
                windowGrid
            } else if let image = preview.image, !model.recorder.isBusy {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: settings.previewCornerRadius - 4))
                    .padding(6)
                cameraBubble
            } else {
                previewPlaceholder
                cameraBubble
            }
            if !model.permissions.canRecord {
                permissionOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: settings.previewCornerRadius).strokeBorder(.white.opacity(0.08)))
    }

    /// The window picker: one thumbnail per window, grouped by app.
    private var windowGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.windowGroups.isEmpty {
                    Text(model.windowListError ?? "No windows to record").foregroundStyle(.secondary).padding()
                }
                ForEach(model.windowGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.applicationName).font(.headline).padding(.leading, 4)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: settings.thumbnailWidth), spacing: 12)], spacing: 12
                        ) {
                            ForEach(group.windows) { window in
                                windowCell(window)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func windowCell(_ window: WindowChoice) -> some View {
        Button {
            source = .window(window)
            choosingWindow = false
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                    if let image = windowThumbnails[window.id] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(4)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: settings.thumbnailWidth * 0.62)
                Text(window.title.isEmpty ? window.applicationName : window.title)
                    .font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
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
                ProgressView()
                Text("Finishing the take…").foregroundStyle(.secondary)
            }
        case .rendering(let progress):
            VStack(spacing: 10) {
                ProgressView(value: progress ?? 0).frame(width: 260)
                Text(progress.map { "Rendering… \(Int(($0 * 100).rounded())) %" } ?? "Rendering…")
                    .foregroundStyle(.secondary)
            }
        case .done, .idle, .failed, .renderFailed:
            if case .done = model.recorder.state, let thumbnail = exportThumbnail {
                resultCard(thumbnail)
            } else if case .failed(let error, _) = model.recorder.state {
                failure("Recording failed", error)
            } else if case .renderFailed(let error, _) = model.recorder.state {
                failure("Export failed", error)
            } else if source == nil {
                VStack(spacing: 8) {
                    Image(systemName: kind == .area ? "rectangle.dashed" : "macwindow")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(kind == .area ? "Choose the area to record." : "Pick a window.").foregroundStyle(.secondary)
                }
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

    /// The bubble as the export draws it: a rounded square with a hairline
    /// border and the card's shadow, bottom trailing.
    @ViewBuilder private var cameraBubble: some View {
        if let cameraID = model.sources.cameraID, !model.recorder.isBusy {
            let camera = model.cameras.first { $0.id == cameraID }
            let shape = RoundedRectangle(cornerRadius: settings.bubbleCornerRadius, style: .continuous)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CameraPreviewView(deviceID: cameraID, mirrored: camera?.isBuiltIn ?? true)
                        .frame(width: settings.bubbleSize, height: settings.bubbleSize)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                        .padding(24)
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
            teleprompterChip
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

    /// The prompter floats on its own; it stays available while recording.
    private var teleprompterChip: some View {
        Button {
            teleprompter.toggle()
            showsTeleprompter = teleprompter.isVisible
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                Text("Teleprompter")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                (showsTeleprompter ? Color.accentColor.opacity(0.35) : .white.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: settings.chipCornerRadius))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .fixedSize(horizontal: true, vertical: false)
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
        case .area(let area): model.record(area: area)
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
        case .area(let area):
            let rect = CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width, height: area.rect.height)
            preview.start(.area(display: area.displayID, rect: rect))
        case nil: preview.stop()
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
