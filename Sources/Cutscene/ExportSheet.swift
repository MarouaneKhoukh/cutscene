import CutsceneCore
import CutsceneExport
import SwiftUI

/// The numbers the export sheet is drawn with.
struct ExportSheetSettings: Sendable, Equatable {
    /// Fixed size in points (PLAN M1-F6).
    var width = 440.0
    var height = 360.0
    /// Bytes per megabyte as the estimate quotes sizes, the Finder's decimal form.
    var bytesPerMegabyte = 1_000_000.0
}

/// Preset, codec and frame rate, the estimate, then progress with Cancel,
/// and Reveal or Open when done (PLAN M2-10). The choices are written to
/// the project, so the auto-render uses them next time too.
struct ExportSheet: View {
    let model: EditorModel
    var settings = ExportSheetSettings()

    @Environment(\.dismiss) private var dismiss
    @State private var preset: ExportPresetID
    @State private var codec: ExportCodec
    @State private var frameRate: Int

    init(model: EditorModel, settings: ExportSheetSettings = ExportSheetSettings()) {
        self.model = model
        self.settings = settings
        let export = model.project.export
        _preset = State(initialValue: export.preset)
        _codec = State(initialValue: export.codec ?? ExportPreset.standard(export.preset)?.codec ?? .h264)
        _frameRate = State(initialValue: export.frameRate)
    }

    /// The preset as chosen, for the label and the estimate.
    private var resolved: ExportPreset? {
        guard let base = ExportPreset.standard(preset) else { return nil }
        return try? base.with(codec: codec).with(frameRate: frameRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())
            switch model.exportState {
            case .idle:
                choices
            case .running(let progress):
                running(progress)
            case .done(let result):
                done(result)
            case .cancelled:
                Text("The export was cancelled; nothing was written.").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                }
            case .failed(let message):
                Text("Export failed: \(message)").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: settings.width, height: settings.height)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Preset", selection: $preset) {
                    ForEach(ExportPreset.standard, id: \.id) { preset in
                        Text("\(presetName(preset)) · \(preset.canvas.width)×\(preset.canvas.height)").tag(preset.id)
                    }
                }
                .onChange(of: preset) { _, id in
                    if let base = ExportPreset.standard(id) { codec = base.codec }
                }
                Picker("Codec", selection: $codec) {
                    ForEach(ExportCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(ExportPreset.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                if let resolved {
                    let job = ExportEstimate(
                        preset: resolved, audioBitRate: model.settings.writer.audio.bitRate,
                        durationSeconds: model.timeline.duration,
                        headroomFactor: model.settings.writer.disk.headroomFactor)
                    LabeledContent(
                        "Estimate",
                        value: String(
                            format: "about %.0f MB, %.0f s", Double(job.bytes) / settings.bytesPerMegabyte, job.seconds)
                    )
                }
                LabeledContent("Duration", value: TransportBar.clock(model.timeline.duration))
                LabeledContent("Destination", value: model.exportsDirectory().path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    // The codec goes as chosen; the model keeps the project's
                    // own spelling when it resolves to the same codec.
                    model.export(preset: preset, codec: codec, frameRate: frameRate)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(resolved == nil || model.plan == nil)
            }
        }
    }

    private func running(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress.fraction)
            Text(phaseLine(progress)).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func done(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.outputURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(
                "\(result.preset.label) · \(TransportBar.clock(result.durationSeconds)) · \(result.frameCount) frames · "
                    + String(
                        format: "%.0f MB · %.1f× real time", Double(result.fileSizeBytes) / settings.bytesPerMegabyte,
                        result.speed)
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reveal") { model.reveal(result.outputURL) }
                Button("Open") { model.open(result.outputURL) }
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func phaseLine(_ progress: ExportProgress) -> String {
        switch progress.phase {
        case .preparing: return "Preparing the composition…"
        case .encoding:
            var line = "Encoding \(Int((progress.fraction * 100).rounded())) % · \(progress.framesWritten) frames"
            if let speed = progress.speed { line += String(format: " · %.1f× real time", speed) }
            if let left = progress.estimatedRemainingSeconds { line += String(format: " · about %.0f s left", left) }
            return line
        case .finishing: return "Finishing the file…"
        case .verifying: return "Checking the file…"
        case .done: return "Done"
        }
    }

    private func presetName(_ preset: ExportPreset) -> String {
        switch preset.id {
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        case .vertical1080: "Vertical"
        case .square1080: "Square"
        }
    }

    private func close() {
        model.resetExportState()
        dismiss()
    }
}
