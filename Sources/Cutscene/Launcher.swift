import AVFoundation
import AppKit
import CutsceneCore
import SwiftUI

/// The numbers the launcher is drawn with (fixed size, PLAN M1-F6).
struct LauncherSettings: Sendable, Equatable {
    var width = 960.0
    var height = 640.0
    var sidebarWidth = 250.0
    var padding = 18.0
    var previewCornerRadius = 16.0
    var bubbleSize = 150.0
    var bubbleCornerRadius = 30.0
    var thumbnailPixels = 480.0
    var thumbnailWidth = 200.0
}

/// What the launcher is pointed at.
enum LauncherSource: Equatable {
    case display(DisplayChoice)
    case window(WindowChoice)
    case area(AreaSelection)
}

private enum SourceKind: CaseIterable {
    case display, window, area

    var title: String {
        switch self {
        case .display: "Entire display"
        case .window: "A window"
        case .area: "Part of the screen"
        }
    }

    var subtitle: String {
        switch self {
        case .display: "Everything on one screen"
        case .window: "One app window, menus included"
        case .area: "Drag a rectangle to capture"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

private enum Palette {
    static let background = LinearGradient(
        colors: [Color(red: 0.055, green: 0.06, blue: 0.09), Color(red: 0.10, green: 0.09, blue: 0.16)],
        startPoint: .top, endPoint: .bottom)
    static let panel = Color.white.opacity(0.045)
    static let panelBorder = Color.white.opacity(0.08)
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.3)
}

/// The recorder: choose a source on the left, see it live on the right with
/// the camera bubble where the export will put it, and press Record.
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
            Palette.background
            HStack(spacing: settings.padding) {
                sidebar
                VStack(spacing: 12) {
                    stage
                    footer
                }
            }
            .padding(settings.padding)
        }
        .frame(width: settings.width, height: settings.height)
        .preferredColorScheme(.dark)
        .background(FloatingWindowConfigurator())
        .onAppear {
            NSApp.activate()
            model.refreshDisplays()
            model.refreshWindows(force: true)
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

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(Palette.record)
                Text("Cutscene").font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            section("What to record") {
                ForEach(SourceKind.allCases, id: \.self) { candidate in
                    sourceCard(candidate)
                }
            }

            section("Inputs") {
                inputRow(
                    symbol: model.defaults.microphoneID == nil ? "mic.slash" : "mic.fill", title: "Microphone",
                    selection: Binding(get: { model.defaults.microphoneID }, set: { model.selectMicrophone($0) }),
                    options: model.microphones.map { ($0.id, $0.name) }
                )
                .overlay(alignment: .bottomLeading) { levelMeter.padding(.leading, 40).padding(.bottom, 5) }
                inputRow(
                    symbol: model.sources.cameraID == nil ? "video.slash" : "video.fill", title: "Camera",
                    selection: Binding(get: { model.sources.cameraID }, set: { model.selectCamera($0) }),
                    options: model.cameras.map { ($0.id, $0.name) }
                )
                systemAudioRow
            }

            section("Extras") {
                Button {
                    teleprompter.toggle()
                    showsTeleprompter = teleprompter.isVisible
                } label: {
                    HStack {
                        Image(systemName: "text.alignleft").frame(width: 20)
                        Text("Teleprompter")
                        Spacer()
                        Text("⇧⌘T").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(
                        showsTeleprompter ? Palette.accent.opacity(0.25) : Palette.panel,
                        in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            Spacer()

            Button {
                if let url = model.lastRecordingURL { openWindow(id: AppModel.editorWindowID, value: url) }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3").frame(width: 20)
                    Text("Edit last take")
                    Spacer()
                }
                .padding(10)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.lastRecordingURL == nil)
        }
        .frame(width: settings.sidebarWidth)
        .disabled(model.recorder.isBusy)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.leading, 4)
            content()
        }
    }

    private func sourceCard(_ candidate: SourceKind) -> some View {
        let selected = kind == candidate
        return Button {
            select(candidate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: candidate.symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(selected ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title).font(.body.weight(.medium))
                    Text(candidate.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(selected ? Palette.accent.opacity(0.18) : Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Palette.accent.opacity(0.6) : Palette.panelBorder))
        }
        .buttonStyle(.plain)
    }

    private func inputRow(symbol: String, title: String, selection: Binding<String?>, options: [(String, String)])
        -> some View
    {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
                .foregroundStyle(selection.wrappedValue == nil ? .secondary : Palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: selection) {
                    Text("Off").tag(String?.none)
                    ForEach(options, id: \.0) { option in Text(option.1).tag(Optional(option.0)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var systemAudioRow: some View {
        @Bindable var defaults = model.defaults
        return HStack(spacing: 10) {
            Image(systemName: defaults.systemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                .frame(width: 20)
                .foregroundStyle(defaults.systemAudio ? Palette.accent : .secondary)
            Text("System audio")
            Spacer()
            Toggle("", isOn: $defaults.systemAudio).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(meter.level > 0.85 ? Palette.record : Color.green)
                    .frame(width: max(0, geometry.size.width * meter.level))
            }
        }
        .frame(width: 120, height: 3)
        .opacity(model.defaults.microphoneID == nil ? 0 : 1)
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: settings.previewCornerRadius).fill(Color.black.opacity(0.5))
            if kind == .window, choosingWindow || source == nil, !model.recorder.isBusy {
                windowGrid
            } else if let image = preview.image, !model.recorder.isBusy {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: settings.previewCornerRadius - 4))
                    .padding(6)
                stageCaption
            } else {
                stagePlaceholder
            }
            if !(kind == .window && (choosingWindow || source == nil)) { cameraBubble }
            if !model.permissions.canRecord { permissionOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: settings.previewCornerRadius).strokeBorder(Palette.panelBorder))
    }

    /// A one-line description of what Record will capture, over the preview.
    private var stageCaption: some View {
        VStack {
            HStack {
                Label(sourceDescription, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                Spacer()
                if kind != .display {
                    Button(kind == .window ? "Change window" : "Change area") {
                        if kind == .window { beginChoosingWindow() } else { pickArea() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(14)
            Spacer()
        }
    }

    private var sourceDescription: String {
        switch source {
        case .display(let display): "Ready to record \(display.name)"
        case .window(let window):
            "Ready to record \(window.applicationName)\(window.title.isEmpty ? "" : " · \(window.title)")"
        case .area(let area): "Ready to record a \(Int(area.rect.width)) × \(Int(area.rect.height)) pt area"
        case nil: ""
        }
    }

    private var windowGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Click the window to record").font(.headline)
                Spacer()
                Button("Refresh") { beginChoosingWindow() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.windowGroups.isEmpty {
                        Text(model.windowListError ?? "Looking for windows…").foregroundStyle(.secondary).padding()
                    }
                    ForEach(model.windowGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.applicationName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: settings.thumbnailWidth), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(group.windows) { window in windowCell(window) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private func windowCell(_ window: WindowChoice) -> some View {
        Button {
            source = .window(window)
            choosingWindow = false
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05))
                    if let image = windowThumbnails[window.id] {
                        Image(decorative: image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).padding(3)
                    } else {
                        Image(systemName: "macwindow").font(.title).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: settings.thumbnailWidth * 0.6)
                Text(window.title.isEmpty ? window.applicationName : window.title)
                    .font(.caption).lineLimit(1)
            }
            .padding(6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.panelBorder))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Record this window")
    }

    @ViewBuilder private var stagePlaceholder: some View {
        switch model.recorder.state {
        case .countdown(let remaining):
            Text("\(remaining)").font(.system(size: 140, weight: .bold, design: .rounded))
        case .selecting:
            ProgressView().controlSize(.large)
        case .recording:
            VStack(spacing: 10) {
                Circle().fill(Palette.record).frame(width: 14, height: 14)
                Text(elapsed).font(.system(size: 48, weight: .medium, design: .rounded).monospacedDigit())
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
                ProgressView(value: progress ?? 0).frame(width: 280)
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
            } else if kind == .area, source == nil {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Drag the area to record on your screen.").foregroundStyle(.secondary)
                    Button("Choose area") { pickArea() }.buttonStyle(.borderedProminent)
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
        VStack(spacing: 14) {
            Image(decorative: thumbnail, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 18, y: 8)
            HStack(spacing: 10) {
                Button {
                    model.openLastExport()
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    if let url = model.lastRecordingURL { openWindow(id: AppModel.editorWindowID, value: url) }
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                Button {
                    if let url = model.lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Text("Recorded again? Pick a source on the left and press Record.").font(.caption).foregroundStyle(
                .tertiary)
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
            let shape = RoundedRectangle(cornerRadius: settings.bubbleCornerRadius, style: .continuous)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CameraPreviewView(deviceID: cameraID, mirrored: camera?.isBuiltIn ?? true)
                        .frame(width: settings.bubbleSize, height: settings.bubbleSize)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.45), lineWidth: 1.5))
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerHint).font(.callout).foregroundStyle(.secondary)
            Spacer()
            recordButton
        }
        .frame(height: 56)
    }

    private var footerHint: String {
        switch model.recorder.state {
        case .recording: "Recording. Press Stop or ⌘. when you're done."
        case .countdown: "Get ready…"
        case .selecting, .finishing: "One moment…"
        case .rendering: "Rendering your video; it opens from the card when ready."
        case .idle, .done, .failed, .renderFailed:
            switch source {
            case nil: kind == .window ? "Click a window above to select it." : "Choose what to record."
            case .display: "Press Record (⌘R). A 3-second countdown follows."
            case .window: "Menus and popovers of this window are captured too. Press Record (⌘R)."
            case .area: "Only the chosen rectangle is captured. Press Record (⌘R)."
            }
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch model.recorder.state {
        case .recording:
            bigButton("Stop", symbol: "stop.fill", tint: Palette.record) { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
        case .countdown, .selecting, .finishing, .rendering:
            bigButton("Cancel", symbol: "xmark", tint: .gray) { model.stop() }
        case .idle, .done, .failed, .renderFailed:
            bigButton(recordTitle, symbol: "record.circle", tint: Palette.record, action: startRecording)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.permissions.canRecord || model.isBusy || source == nil)
        }
    }

    private var recordTitle: String {
        switch kind {
        case .display: "Record display"
        case .window: "Record window"
        case .area: "Record area"
        }
    }

    private func bigButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: tint.opacity(0.45), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions and sync

    private func select(_ candidate: SourceKind) {
        kind = candidate
        switch candidate {
        case .display: chooseMainDisplay()
        case .window:
            source = nil
            beginChoosingWindow()
        case .area:
            source = nil
            pickArea()
        }
    }

    private func chooseMainDisplay() {
        if let display = model.displays.first(where: \.isMain) ?? model.displays.first {
            source = .display(display)
        }
    }

    private func beginChoosingWindow() {
        model.refreshWindows(force: true)
        choosingWindow = true
        let pixels = settings.thumbnailPixels
        Task {
            // The list arrives asynchronously; thumbnails follow it.
            try? await Task.sleep(for: .milliseconds(350))
            let ids = model.windowGroups.flatMap { $0.windows.map(\.id) }
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
        if model.defaults.microphoneID != nil, !model.recorder.isBusy { meter.start() } else { meter.stop() }
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
            if let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                exportThumbnail = image
            }
        }
    }

    private var elapsed: String {
        Duration.seconds(model.recorder.elapsedSeconds).formatted(.time(pattern: .minuteSecond))
    }
}
