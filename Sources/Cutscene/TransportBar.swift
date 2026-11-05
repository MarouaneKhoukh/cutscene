import SwiftUI

/// Play, pause, step and jump, the playhead over the duration, and Undo and
/// Redo (PLAN M2-10). Times are timeline seconds: what the export will be.
struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.goToStart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Go to start")
            Button {
                model.step(frames: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .help("Step back one frame")
            Button {
                model.preview.togglePlayback()
            } label: {
                Image(systemName: model.preview.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.preview.isPlaying ? "Pause" : "Play")
            Button {
                model.step(frames: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .help("Step forward one frame")
            Button {
                model.goToEnd()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Go to end")

            Text("\(Self.clock(model.preview.currentTime))")
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .padding(.leading, 10)
            Text("/ \(Self.clock(model.preview.duration))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("Undo")
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("Redo")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .disabled(model.preview.item == nil)
        .padding(.horizontal, 14)
    }

    /// `m:ss.ff` with hundredths, enough to tell frames apart at 60 fps.
    static func clock(_ seconds: Double) -> String {
        let clamped = max(seconds.isFinite ? seconds : 0, 0)
        let whole = Int(clamped)
        let hundredths = Int(((clamped - Double(whole)) * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", whole / 60, whole % 60, hundredths)
    }
}
