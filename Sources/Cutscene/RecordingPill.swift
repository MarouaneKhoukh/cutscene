import AppKit
import CutsceneCapture
import Foundation
import Observation

/// The numbers the recording pill is drawn with (ARCHITECTURE §1 "HUD").
struct RecordingPillSettings: Sendable, Equatable {
    /// Size of the pill in points: wide enough for the time, the counters
    /// and two buttons on one line.
    var width = 500.0
    var height = 44.0
    /// Points between the pill and the bottom edge of the screen it sits on.
    var bottomMargin = 24.0
    var dotDiameter = 10.0
    var horizontalPadding = 16.0
    var spacing = 12.0
    var fontSize = 13.0
}

/// The HUD's window (ARCHITECTURE §1): a borderless non-activating panel on
/// every Space, full-screen apps included, that never takes the keyboard
/// from what is being recorded. Our application is excluded from a display
/// or area capture and a window capture includes only the chosen window,
/// so the panel is never in the recording.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    /// The buttons work on the first click without the panel being key, and
    /// a key panel would take keystrokes from the window being recorded.
    override var canBecomeKey: Bool { false }
}

/// The pill shown while a take runs (PLAN M2-09): elapsed time, dropped
/// frames, free disk, Marker and Stop; during the countdown the number and
/// Cancel. AppKit controls rather than a hosted SwiftUI view: the panel is
/// fixed-size (PLAN M1-F6) and `NSButton` reacts to the first click in a
/// window that is not key. The labels follow the recorder through
/// `withObservationTracking`, re-armed after every change.
@MainActor final class RecordingPill {
    let settings: RecordingPillSettings
    private unowned let model: AppModel
    private var panel: HUDPanel?
    private var content: RecordingPillContentView?
    /// Bumped on every show and hide; only the tracking chain started for
    /// the current value keeps re-arming itself.
    private var observationGeneration = 0

    init(model: AppModel, settings: RecordingPillSettings = RecordingPillSettings()) {
        self.model = model
        self.settings = settings
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the pill at the bottom centre of the main screen and starts
    /// following the recorder. Showing it again leaves it where the user
    /// dragged it.
    func show() {
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - settings.width / 2, y: frame.minY + settings.bottomMargin))
        }
        panel.orderFrontRegardless()
        observationGeneration += 1
        observe(generation: observationGeneration)
    }

    func hide() {
        // Retires the armed tracking, so a later `show` starts one chain,
        // not a second one beside the old.
        observationGeneration += 1
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let size = NSSize(width: settings.width, height: settings.height)
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size))
        let content = RecordingPillContentView(frame: NSRect(origin: .zero, size: size), settings: settings)
        content.onMarker = { [weak self] in self?.model.mark() }
        content.onStop = { [weak self] in self?.model.stop() }
        panel.contentView = content
        self.panel = panel
        self.content = content
        return panel
    }

    /// One render per change: the tracking closure reads what the pill
    /// shows, and the change handler schedules the next render on the main
    /// actor, which re-arms the tracking. A chain whose `generation` is no
    /// longer the current one (the pill was hidden, or shown again) ends.
    private func observe(generation: Int) {
        guard isVisible, generation == observationGeneration else { return }
        withObservationTracking {
            render()
        } onChange: {
            Task { @MainActor [weak self] in self?.observe(generation: generation) }
        }
    }

    private func render() {
        guard let content else { return }
        let recorder = model.recorder
        let statistics = recorder.statistics
        switch recorder.state {
        case .countdown(let remaining):
            content.update(
                dotVisible: false, status: "Recording in \(remaining)…", detail: "", marker: nil, stop: "Cancel",
                stopEnabled: true)
        case .selecting:
            content.update(
                dotVisible: false, status: "Starting…", detail: "", marker: nil, stop: "Stop", stopEnabled: true)
        case .recording:
            let elapsed = Duration.seconds(recorder.elapsedSeconds).formatted(.time(pattern: .minuteSecond))
            var details = [
                statistics.dropped.screenFrames > 0 ? "\(statistics.dropped.screenFrames) dropped" : "no drops"
            ]
            if let free = statistics.freeDiskBytes {
                let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                details.append(statistics.disk?.level == .low ? "\(text) free, running low" : "\(text) free")
            }
            let markers = recorder.markerCount
            content.update(
                dotVisible: true, status: elapsed, detail: details.joined(separator: " · "),
                marker: markers > 0 ? "Marker (\(markers))" : "Marker", stop: "Stop", stopEnabled: true)
        case .finishing:
            content.update(
                dotVisible: false, status: "Finishing…", detail: "", marker: nil, stop: "Stop", stopEnabled: false)
        case .idle, .rendering, .done, .failed, .renderFailed:
            content.update(dotVisible: false, status: "", detail: "", marker: nil, stop: "Stop", stopEnabled: false)
        }
    }
}

/// The pill's face: a HUD-material capsule with the red dot, two labels and
/// the two buttons in a row.
final class RecordingPillContentView: NSVisualEffectView {
    var onMarker: (() -> Void)?
    var onStop: (() -> Void)?

    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let markerButton = NSButton(title: "Marker", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    init(frame: NSRect, settings: RecordingPillSettings) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = settings.height / 2
        layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = settings.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: settings.dotDiameter).isActive = true
        dot.heightAnchor.constraint(equalToConstant: settings.dotDiameter).isActive = true

        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: settings.fontSize, weight: .semibold)
        statusLabel.textColor = .labelColor
        detailLabel.font = NSFont.systemFont(ofSize: settings.fontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [markerButton, stopButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        markerButton.action = #selector(markerPressed)
        stopButton.action = #selector(stopPressed)

        let stack = NSStackView(views: [dot, statusLabel, detailLabel, NSView(), markerButton, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = settings.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: settings.horizontalPadding, bottom: 0, right: settings.horizontalPadding)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecordingPillContentView is made in code.")
    }

    /// Sets every control at once; a nil `marker` hides the Marker button.
    func update(dotVisible: Bool, status: String, detail: String, marker: String?, stop: String, stopEnabled: Bool) {
        dot.isHidden = !dotVisible
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        markerButton.isHidden = marker == nil
        markerButton.title = marker ?? "Marker"
        stopButton.title = stop
        stopButton.isEnabled = stopEnabled
    }

    @objc private func markerPressed() {
        onMarker?()
    }

    @objc private func stopPressed() {
        onStop?()
    }
}
