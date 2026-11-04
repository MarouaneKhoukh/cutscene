import AVFoundation
import AppKit
import CoreMedia
import CutsceneRender
import Observation
import SwiftUI

/// The numbers the editor's preview is tuned with (ARCHITECTURE §5
/// "Preview"); the measurements behind them are spike S2's player half,
/// platform-notes "Preview playback".
struct PreviewSettings: Sendable, Equatable {
    /// Cap on the preview composition's render area, a 1920×1080-equivalent
    /// (`preview.maxPixels`): the editor builds its composition on
    /// `canvas(for:)`, so a 4K preset previews at 1080p and a 1080p one at
    /// its own size, and the compositor's request stays near 1 ms.
    var maxPixels = 1920 * 1080
    /// How long a paused item gets to render its current frame again by
    /// itself after a live edit assigns a new `videoComposition`, before a
    /// zero-tolerance seek to the current time forces it. S2 measured the
    /// engine re-rendering on its own in 1.5–2 ms median, 4.4 ms at most,
    /// on the same compositor instance; the seek is the §5 fallback and
    /// only a watchdog here.
    var reassignmentRenderTimeout: TimeInterval = 0.1
    /// Poll while waiting for that re-render.
    var reassignmentPollInterval: TimeInterval = 0.005
    /// How often `currentTime` is refreshed from the player while it plays,
    /// for the playhead; a scrubber frame, not a video frame.
    var timeObserverInterval: TimeInterval = 1.0 / 30
    /// Timescale seeks are expressed in: whole frames at any rate the
    /// presets allow, with room for the millisecond a scrubber hands over.
    var seekTimescale: CMTimeScale = 60_000
    /// Whether playback pauses while an export runs
    /// (`preview.pauseDuringExport`). Off: S2 found the preview's and the
    /// export's compositor instances do not serialize, and the player kept
    /// 97 % of its frames with a reader at full speed alongside.
    var pauseDuringExport = false

    /// The canvas the preview composition is built on: the export's
    /// aspect and rate at no more than `maxPixels`.
    func canvas(for export: CanvasSpec) -> CanvasSpec {
        export.fitting(maximumPixels: maxPixels)
    }
}

/// The editor's player: the `AVPlayer` behind `PreviewView`, the item built
/// from a `BuiltComposition`, coalesced zero-tolerance scrubbing, live
/// edits by `videoComposition` reassignment, and the transport.
///
/// Scrubbing is "latest wins": a position that arrives while a seek is in
/// flight replaces any position waiting, and the seek that finishes
/// issues the one waiting, so a fast drag costs one seek per rendered
/// frame rather than one per mouse event, and the frame shown is always
/// the last position asked for. `seekingWaitsForVideoCompositionRendering`
/// makes each seek's completion, and so `currentTime`, follow the rendered
/// frame (S2: 13 ms median, 22 ms max from the call to the frame, one
/// `startRequest` per seek at the exact target).
///
/// The owner (M2-10's `EditorModel`) calls `tearDown()` when its window
/// closes: the periodic time observer must be removed from the player
/// before it goes, and a main-actor object cannot do that in `deinit`.
@MainActor @Observable final class PreviewPlayer {
    let settings: PreviewSettings
    let player = AVPlayer()
    /// The item playing, nil before `load` and after `tearDown`.
    private(set) var item: AVPlayerItem?
    /// The composition the item was built from, for the owner's bookkeeping.
    private(set) var duration: Double = 0
    /// The playhead in composition seconds, refreshed every
    /// `settings.timeObserverInterval` while playing and after each seek.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    private var pendingSeekTime: CMTime?
    private var seekInFlight = false
    /// Counts live edits so a re-render watchdog from an older edit does
    /// nothing once a newer one has been assigned.
    private var editGeneration = 0
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?

    init(settings: PreviewSettings = PreviewSettings()) {
        self.settings = settings
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: settings.timeObserverInterval, preferredTimescale: settings.seekTimescale),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    /// Plays `built`, whose `videoComposition` must have been built on
    /// `settings.canvas(for:)`; replaces whatever was loaded.
    func load(_ built: BuiltComposition) {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        pendingSeekTime = nil
        seekInFlight = false
        editGeneration += 1
        self.item = item
        duration = built.duration.seconds
        currentTime = 0
        isPlaying = false
        player.replaceCurrentItem(with: item)
    }

    /// Shows the frame at `seconds`, coalescing with any seek in flight.
    func scrub(to seconds: Double) {
        pendingSeekTime = CMTime(
            seconds: min(max(seconds, 0), duration), preferredTimescale: settings.seekTimescale)
        guard !seekInFlight else { return }
        performPendingSeek()
    }

    /// A live edit: the new composition (same canvas, new instructions)
    /// replaces the item's. Playing, the next frame renders with it; paused,
    /// the engine re-renders the current frame by itself (S2), and the
    /// watchdog forces a seek only if it has not within
    /// `settings.reassignmentRenderTimeout`.
    func replaceVideoComposition(_ composition: AVVideoComposition) {
        guard let item else { return }
        item.videoComposition = composition
        editGeneration += 1
        guard !isPlaying else { return }
        let generation = editGeneration
        let compositorBefore = item.customVideoCompositor as? MetalCompositor
        let requestsBefore = compositorBefore?.statistics.requests ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(settings.reassignmentRenderTimeout)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(settings.reassignmentPollInterval))
                guard self.item === item, generation == editGeneration else { return }
                let compositor = item.customVideoCompositor as? MetalCompositor
                let requests = compositor?.statistics.requests ?? 0
                if compositor !== compositorBefore ? requests > 0 : requests > requestsBefore { return }
            }
            guard self.item === item, generation == editGeneration, !isPlaying, pendingSeekTime == nil,
                !seekInFlight
            else { return }
            scrub(to: item.currentTime().seconds)
        }
    }

    func play() {
        guard item != nil else { return }
        isPlaying = true
        player.play()
    }

    func pause() {
        player.pause()
        isPlaying = false
        if let item { currentTime = item.currentTime().seconds }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Stops playback and releases the item and the observers; the player
    /// is unusable afterwards.
    func tearDown() {
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        item = nil
        pendingSeekTime = nil
        seekInFlight = false
    }

    private func performPendingSeek() {
        guard let time = pendingSeekTime, let item else { return }
        pendingSeekTime = nil
        seekInFlight = true
        Task { @MainActor [weak self] in
            _ = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            // A completion from an item `load` has since replaced says
            // nothing about the current item's seek, which `load` reset.
            guard let self, self.item === item else { return }
            seekInFlight = false
            currentTime = item.currentTime().seconds
            performPendingSeek()
        }
    }
}

/// The `AVPlayerLayer` in SwiftUI: a layer-hosting `NSView` whose layer is
/// the player's. The view reports no intrinsic size, so the window that
/// hosts it is sized by its owner, never by this content (PLAN M1-F6);
/// the frame aspect-fits the view and the window's background shows
/// around it.
struct PreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// The hosting view: layer-hosting (the layer is set before `wantsLayer`),
/// so AppKit draws nothing of its own into it.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
