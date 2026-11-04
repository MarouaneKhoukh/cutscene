import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// A screenshot of the selected source, refreshed a few times a second, so
/// the launcher shows what a take would capture before Record is pressed.
/// Screenshots rather than a stream: nothing to tear down when the real
/// stream starts, and a 6 fps preview costs almost nothing.
@MainActor @Observable
final class SourcePreviewModel {
    /// Seconds between refreshes (`launcher.previewInterval`).
    var interval = 0.16
    /// Longest side of the preview in pixels (`launcher.previewPixels`).
    var maximumPixels = 1280.0
    private(set) var image: CGImage?
    private(set) var isLive = false
    private var task: Task<Void, Never>?

    enum Source: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    func start(_ source: Source) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let frame = await Self.capture(source, maximumPixels: maximumPixels) {
                    image = frame.image
                    isLive = true
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isLive = false
    }

    /// `CGImage` carries no Sendable annotation; it is immutable, so moving
    /// one across the capture task's boundary is safe.
    private struct Frame: @unchecked Sendable {
        let image: CGImage
    }

    private nonisolated static func capture(_ source: Source, maximumPixels: Double) async -> Frame? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let filter: SCContentFilter
        let size: CGSize
        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            filter = SCContentFilter(display: display, excludingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumPixels / max(size.width, size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(size.width * scale))
        configuration.height = max(2, Int(size.height * scale))
        configuration.showsCursor = true
        configuration.scalesToFit = true
        guard
            let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { return nil }
        return Frame(image: image)
    }
}

/// Live camera preview for the launcher's bubble. Owns its own capture
/// session; the recording uses a separate one through `CameraRecorder`.
struct CameraPreviewView: NSViewRepresentable {
    let deviceID: String
    var mirrored = true

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.configure(deviceID: deviceID, mirrored: mirrored)
        return view
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.configure(deviceID: deviceID, mirrored: mirrored)
    }

    static func dismantleNSView(_ view: CameraPreviewNSView, coordinator: ()) {
        view.shutDown()
    }
}

final class CameraPreviewNSView: NSView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDeviceID: String?
    private let queue = DispatchQueue(label: "app.cutscene.launcher.camera-preview")

    func configure(deviceID: String, mirrored: Bool) {
        if previewLayer == nil {
            wantsLayer = true
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            self.layer?.addSublayer(layer)
            previewLayer = layer
        }
        previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer?.connection?.isVideoMirrored = mirrored
        guard deviceID != currentDeviceID else { return }
        currentDeviceID = deviceID
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = AVCaptureDevice(uniqueID: deviceID)
        else { return }
        let box = SessionBox(session: session, device: device)
        queue.async {
            box.session.beginConfiguration()
            for input in box.session.inputs { box.session.removeInput(input) }
            if let device = box.device, let input = try? AVCaptureDeviceInput(device: device),
                box.session.canAddInput(input)
            {
                box.session.addInput(input)
            }
            box.session.commitConfiguration()
            if !box.session.isRunning { box.session.startRunning() }
        }
    }

    func shutDown() {
        let box = SessionBox(session: session, device: nil)
        queue.async { if box.session.isRunning { box.session.stopRunning() } }
    }

    /// AVFoundation's session and device carry no Sendable annotation; they
    /// are used only on `queue`, so moving them there is safe.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
        let device: AVCaptureDevice?
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

/// Input level of the default microphone, for the launcher's meter. Runs
/// only while the launcher is idle; the take captures the microphone through
/// ScreenCaptureKit, on its own clock.
@MainActor @Observable
final class MicrophoneLevelModel {
    /// 0...1, smoothed; `launcher.meterAttack` / `launcher.meterRelease`.
    private(set) var level = 0.0
    var attack = 0.6
    var release = 0.15
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += data[index] * data[index] }
            let rms = count > 0 ? sqrt(sum / Float(count)) : 0
            // Perceptual scale: -60 dBFS maps to 0, 0 dBFS to 1.
            let decibels = 20 * log10(max(rms, 1e-6))
            let normalized = Double(min(1, max(0, (decibels + 60) / 60)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(normalized) }
            }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    private func update(_ sample: Double) {
        let factor = sample > level ? attack : release
        level += (sample - level) * factor
    }
}
