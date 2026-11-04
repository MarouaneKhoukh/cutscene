import AppKit
import SwiftUI

/// The teleprompter's tunables; the script itself lives in `UserDefaults`.
struct TeleprompterSettings: Sendable, Equatable {
    var width = 560.0
    var height = 300.0
    /// Points scrolled per second at speed 1.
    var baseSpeed = 40.0
    var defaultSpeed = 1.0
    var defaultFontSize = 30.0
    var defaultOpacity = 0.82
    var tick = 1.0 / 30
    var scriptKey = "teleprompter.script"
}

/// Script, playback and layout state shared by the panel and the launcher.
@MainActor @Observable
final class TeleprompterModel {
    let settings: TeleprompterSettings
    var script: String {
        didSet { UserDefaults.standard.set(script, forKey: settings.scriptKey) }
    }
    var isPlaying = false
    var isEditing: Bool
    var speed: Double
    var fontSize: Double
    var opacity: Double
    /// How far the text has scrolled, in points.
    var offset = 0.0

    init(settings: TeleprompterSettings = TeleprompterSettings()) {
        self.settings = settings
        let saved = UserDefaults.standard.string(forKey: settings.scriptKey) ?? ""
        script = saved
        isEditing = saved.isEmpty
        speed = settings.defaultSpeed
        fontSize = settings.defaultFontSize
        opacity = settings.defaultOpacity
    }

    func advance(by seconds: Double) {
        guard isPlaying else { return }
        offset += settings.baseSpeed * speed * seconds
    }

    func restart() {
        offset = 0
    }
}

/// A floating, non-activating script panel that follows the user to every
/// Space and sits over full-screen apps. Our own windows are excluded from
/// display and area captures and a window take captures only its target, so
/// the prompter never ends up in the recording.
@MainActor
final class TeleprompterController {
    let model: TeleprompterModel
    private var panel: NSPanel?

    init(model: TeleprompterModel = TeleprompterModel()) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        model.isPlaying = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let settings = model.settings
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: settings.width, height: settings.height),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Teleprompter"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: TeleprompterView(model: model))
        hosting.sizingOptions = []  // PLAN M1-F6: never size the window from the content
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - settings.width / 2, y: frame.maxY - settings.height - 12))
        }
        return panel
    }
}

/// The prompter: a translucent dark card with the script scrolling upward
/// at a chosen speed, and a small toolbar to play, pause, restart, resize
/// the type and edit the text in place.
struct TeleprompterView: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(model.opacity))
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(.white.opacity(0.15))
                if model.isEditing {
                    editor
                } else {
                    prompter
                }
            }
        }
        .preferredColorScheme(.dark)
        .padding(1)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                model.isPlaying.toggle()
                if model.isPlaying { model.isEditing = false }
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button {
                model.restart()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            Slider(value: $model.speed, in: 0.25...4) { Text("Speed") }
                .frame(width: 120)
            Text(String(format: "%.1f×", model.speed)).font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .leading)
            Stepper("Size", value: $model.fontSize, in: 16...64, step: 2).labelsHidden()
            Slider(value: $model.opacity, in: 0.3...1) { Text("Opacity") }
                .frame(width: 80)
            Spacer()
            Button(model.isEditing ? "Done" : "Edit script") {
                model.isEditing.toggle()
                model.isPlaying = false
            }
            .buttonStyle(.bordered)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        TextEditor(text: $model.script)
            .font(.system(size: 17))
            .scrollContentBackground(.hidden)
            .padding(12)
    }

    private var prompter: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: model.settings.tick)) { _ in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(model.script.isEmpty ? "No script yet. Press Edit script." : model.script)
                        .font(.system(size: model.fontSize, weight: .medium))
                        .lineSpacing(model.fontSize * 0.35)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, geometry.size.height * 0.45)
                        .padding(.bottom, geometry.size.height)
                        .offset(y: -model.offset)
                        .onAppear { model.advance(by: 0) }
                }
                .scrollDisabled(true)
                .task(id: model.isPlaying) {
                    // Advance on a fixed tick while playing; the view redraws
                    // through the timeline schedule.
                    while model.isPlaying, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(model.settings.tick))
                        model.advance(by: model.settings.tick)
                    }
                }
            }
            .overlay(alignment: .top) {
                // A reading line near the top third, the natural eye position
                // below a camera.
                Rectangle().fill(.red.opacity(0.6)).frame(height: 2)
                    .padding(.top, geometry.size.height * 0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
