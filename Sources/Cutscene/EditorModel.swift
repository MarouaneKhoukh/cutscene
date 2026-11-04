import AVFoundation
import AppKit
import CutsceneCore
import CutsceneEngine
import CutsceneExport
import CutsceneRender
import Foundation
import Observation

/// The numbers the editor is tuned with (ARCHITECTURE §1, PLAN M2-10).
struct EditorSettings: Sendable, Equatable {
    /// Seconds an edit waits for the next one before the plan and the
    /// composition are rebuilt (`editor.planDebounce`): a slider drag
    /// delivers edits faster than a plan can be built, and only the last
    /// one needs rendering.
    var planDebounce: TimeInterval = 0.05
    /// Seconds after the last edit before `project.json` is written, so a
    /// drag saves once rather than per mouse event. Closing the window
    /// saves at once.
    var saveDebounce: TimeInterval = 0.5
    /// Seconds a zoom added at the playhead spans, before its edges are dragged.
    var addedZoomDuration = 2.0
    /// Shortest a zoom segment can be dragged to.
    var minimumSegmentDuration = 0.2
    /// Shortest the kept stretch can be trimmed to.
    var minimumKeptDuration = 0.5
    /// The magnifications the zoom inspector offers.
    var zoomAmountRange: ClosedRange<Double> = 1...4
    /// Two times closer than this are the same time: a trim handle at the
    /// clip's own edge is no trim.
    var timeEpsilon = 1e-6
    /// Size of the editor window in points. Fixed: the hosting view must
    /// not size itself from its content (PLAN M1-F6).
    var windowWidth = 1180.0
    var windowHeight = 760.0
    /// Width of the inspector column on the right.
    var inspectorWidth = 300.0
    /// Height of the transport bar and of the scrubber, in points.
    var transportHeight = 44.0
    var scrubberHeight = 120.0
    /// Undo steps kept per window.
    var undoLevels = 200
    var preview = PreviewSettings()
    /// The writer's knobs for the export sheet: offline encoding, 2 s
    /// keyframes, faststart, AAC at 192 kbps, the self-check, the disk guard.
    var writer = ExportWriterSettings()
    var contentMapper = ContentMapperSettings()
    var merge = ZoomTrackMergeSettings()
}

/// Why a package could not be opened in the editor.
enum EditorError: LocalizedError {
    case noRecording(URL)
    case nothingToPlay(URL)

    var errorDescription: String? {
        switch self {
        case .noRecording(let url): "\(url.lastPathComponent) has no finished recording."
        case .nothingToPlay(let url): "\(url.lastPathComponent) holds no video to play."
        }
    }
}

/// Where the export sheet's export stands.
enum EditorExportState: Equatable {
    case idle
    case running(ExportProgress)
    case done(ExportResult)
    case cancelled
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Which end of a span a drag moves.
enum SpanEdge: Sendable {
    case start
    case end
}

/// Everything read from a package before its editor opens: files on disk,
/// read off the main actor, as values.
struct LoadedPackage: Sendable {
    var package: RecordingPackage
    var manifest: RecordingManifest
    var log: EventLog
    /// Recording seconds, the manifest's or the movie's.
    var duration: Double
    var contentCrop: ContentCropTimeline
    var hasCamera: Bool
    var project: Project
    /// Where `project` came from, for the window's status line.
    var projectSource: String
}

/// One editor window's state (ARCHITECTURE §1, PLAN M2-10): the `Project`
/// value, undo as whole-project snapshots, the `RenderPlan` rebuilt off the
/// main actor after every edit with the latest edit winning, the preview
/// player, and the export.
///
/// Edits are values: every change goes through `edit(_:_:)`, which swaps the
/// project for a new value, registers the old one with the undo manager and
/// schedules the rebuild and the save. A drag opens a transaction so its
/// many updates are one undo step and one save. Nothing is saved until an
/// edit has happened, so a package that is opened and closed is left byte
/// for byte as it was, `project.json.previous` included (there is none).
@MainActor @Observable final class EditorModel {
    let settings: EditorSettings
    let package: RecordingPackage
    let manifest: RecordingManifest
    let log: EventLog
    /// Recording seconds: the clip, the cuts and the zoom track live on this axis.
    let recordingDuration: Double
    /// The window crop for a window recording; identity otherwise.
    let contentCrop: ContentCropTimeline
    let hasCamera: Bool
    let projectSource: String
    let preview: PreviewPlayer
    /// Where exports go, read when one starts.
    let exportsDirectory: @MainActor () -> URL

    private(set) var project: Project
    /// The project as `project.json` holds it: the one opened, then the one
    /// last saved. Nothing is written while `project` equals it, so an
    /// edit undone back to the opened project saves nothing, and one undone
    /// after a save is saved again.
    private var savedProject: Project
    /// Whether `project` differs from what `project.json` holds; only then
    /// is anything written.
    var isEdited: Bool { project != savedProject }
    /// Set by `close()`: a rebuild that was already past its debounce when
    /// the window closed drops its result instead of loading it into the
    /// torn-down player.
    private var isClosed = false
    /// The plan the preview shows; nil until the first build finishes.
    private(set) var plan: RenderPlan?
    /// Why the last rebuild or save failed, for the status line.
    private(set) var rebuildError: String?
    private(set) var saveError: String?
    private(set) var selectedSegmentID: UUID?
    private(set) var exportState = EditorExportState.idle
    /// The undo manager edits register with: the window's, once the view
    /// hands it over, so the Edit menu works; the model's own before that.
    var undoManager: UndoManager {
        didSet { undoManager.levelsOfUndo = settings.undoLevels }
    }

    private let store: ProjectStore
    private let ownUndoManager = UndoManager()
    private var transaction: (before: Project, name: String)?
    private var rebuildGeneration = 0
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadedComposition: CompositionKey?
    private var atlas: CursorAtlas?
    /// Where the playhead was asked to be, in recording seconds, for when
    /// the player's time cannot be mapped back (a seek still in flight).
    private var requestedSourceTime = 0.0
    private var exporter: Exporter?
    private var exportTask: Task<Void, Never>?

    /// What the loaded player item was built on; the same key means a new
    /// video composition can replace the item's in place.
    private struct CompositionKey: Equatable {
        var keptRanges: [TimeRange]
        var canvas: CanvasSpec
        var screenTrackID: CMPersistentTrackID
        var cameraTrackID: CMPersistentTrackID
        var audio: ExportAudioSettings
    }

    /// The values a plan is built from, so the build can run off the main actor.
    private struct PlanInputs: Sendable {
        var log: EventLog
        var duration: Double
        var zoomTrack: ZoomTrack
        var kit: BrandKit
        var hasCamera: Bool
        var contentCrop: ContentCropTimeline
    }

    init(
        loaded: LoadedPackage, settings: EditorSettings = EditorSettings(),
        exportsDirectory: @escaping @MainActor () -> URL
    ) {
        self.settings = settings
        package = loaded.package
        manifest = loaded.manifest
        log = loaded.log
        recordingDuration = loaded.duration
        contentCrop = loaded.contentCrop
        hasCamera = loaded.hasCamera
        projectSource = loaded.projectSource
        project = loaded.project
        // The baseline is the post-`read()` value: the silent clip and
        // zoom-plan fill-in is no edit.
        savedProject = loaded.project
        self.exportsDirectory = exportsDirectory
        store = ProjectStore(package: loaded.package)
        preview = PreviewPlayer(settings: settings.preview)
        undoManager = ownUndoManager
        ownUndoManager.levelsOfUndo = settings.undoLevels
        scheduleRebuild(immediate: true)
    }

    // MARK: Loading

    /// Reads the package's files off the main actor and returns the editor
    /// for them. The project is the package's `project.json`; a package
    /// without a readable one (the synthetic fixture predates the format)
    /// opens over a fresh project, which is written only if edited. A
    /// timeline without a clip gets the whole recording, and a zoom track
    /// never planned gets the planner's first plan, so the preview shows
    /// what the auto-render exported; neither counts as an edit.
    static func load(
        url: URL, settings: EditorSettings = EditorSettings(), exportsDirectory: @escaping @MainActor () -> URL
    ) async throws -> EditorModel {
        let loaded = try await read(url: url, settings: settings)
        return EditorModel(loaded: loaded, settings: settings, exportsDirectory: exportsDirectory)
    }

    /// The files, read on the global executor.
    nonisolated static func read(url: URL, settings: EditorSettings) async throws -> LoadedPackage {
        let package = try RecordingPackage.open(at: url)
        let manifest = try package.manifest()
        guard manifest.state != .inProgress else { throw EditorError.noRecording(package.url) }
        let duration = try await AutoRender.duration(of: package, manifest: manifest)
        guard duration > 0 else { throw EditorError.nothingToPlay(package.url) }
        let log = try AutoRender.eventLog(of: package, manifest: manifest)
        var crop = ContentCropTimeline.identity
        if case .window = manifest.source, let index = try? package.frameIndex() {
            crop = ContentMapper(settings: settings.contentMapper)
                .cropTimeline(manifest: manifest, index: index, duration: duration)
        }
        let hasCamera = manifest.camera != nil && FileManager.default.fileExists(atPath: package.cameraMovieURL.path)

        var project: Project
        var source: String
        let store = ProjectStore(package: package)
        if store.projectExists {
            do {
                project = try store.load()
                source = "project.json"
            } catch {
                project = Project(recording: manifest)
                source = "a new project (project.json: \(error.localizedDescription))"
            }
        } else {
            project = Project(recording: manifest)
            source = "a new project (no project.json)"
        }
        if project.timeline.clips.allSatisfy({ $0.end <= $0.start }) {
            project.timeline.clips = Timeline.wholeRecording(duration: duration).clips
        }
        if project.timeline.zoom.planGeneration == 0, project.timeline.zoom.segments.isEmpty {
            let planned = ZoomPlanner(settings: ZoomPlannerSettings(kit: project.style)).plan(
                log, recordingEnd: duration)
            project.timeline.zoom = ZoomTrackMerge.replan(
                project.timeline.zoom, with: planned, settings: settings.merge)
        }
        return LoadedPackage(
            package: package, manifest: manifest, log: log, duration: duration, contentCrop: crop, hasCamera: hasCamera,
            project: project, projectSource: source)
    }

    // MARK: Derived

    var timeline: Timeline { project.timeline }

    /// The preset the project exports with, with its codec and rate; the
    /// default preset if the project names one this build lacks.
    var exportPreset: ExportPreset {
        (try? ExportPreset.resolve(project.export)) ?? .hd1080
    }

    /// The canvas the preview is composed on: the export's shape and rate
    /// under `preview.maxPixels`.
    var previewCanvas: CanvasSpec {
        settings.preview.canvas(for: exportPreset.canvas)
    }

    /// The first and last recording second any clip covers.
    var clipSpan: ClosedRange<Double> {
        let clips = project.timeline.clips.filter { $0.end > $0.start }
        let start = clips.map(\.start).min() ?? 0
        let end = clips.map(\.end).max() ?? recordingDuration
        return start...max(start, end)
    }

    /// Where the head trim ends: the kept stretch starts here.
    var trimStart: Double {
        let span = clipSpan
        return project.timeline.cuts
            .filter { $0.provenance == .trim && $0.start <= span.lowerBound + settings.timeEpsilon }
            .map(\.end).max() ?? span.lowerBound
    }

    /// Where the tail trim starts: the kept stretch ends here.
    var trimEnd: Double {
        let span = clipSpan
        return project.timeline.cuts
            .filter { $0.provenance == .trim && $0.end >= span.upperBound - settings.timeEpsilon }
            .map(\.start).min() ?? span.upperBound
    }

    var selectedSegment: ZoomTrackSegment? {
        guard let id = selectedSegmentID else { return nil }
        return project.timeline.zoom.segments.first { $0.id == id }
    }

    /// The kept ranges the player's item was built from: the axis its
    /// composition time lies on. The project's own until the first
    /// composition is loaded; afterwards the loaded one's, which an edit
    /// changes only once the rebuild has replaced the item (a trim drag
    /// edits the project several times per rebuild).
    private var playingRanges: [TimeRange] {
        loadedComposition?.keptRanges ?? project.timeline.keptRanges()
    }

    /// The playhead in recording seconds: the player's time mapped back
    /// through the kept ranges its item plays, or the last time asked for
    /// while a seek is in flight or the time falls in a cut.
    var playheadSourceTime: Double {
        Timeline.sourceTime(forTimelineTime: preview.currentTime, keptRanges: playingRanges) ?? requestedSourceTime
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    // MARK: Transport

    /// Shows the frame at `sourceTime` (recording seconds); a time inside a
    /// cut shows the nearest kept moment.
    func scrub(toSourceTime sourceTime: Double) {
        let target = nearestKeptSourceTime(sourceTime)
        requestedSourceTime = target
        guard let timelineTime = Timeline.timelineTime(forSourceTime: target, keptRanges: playingRanges) else {
            return
        }
        preview.scrub(to: timelineTime)
    }

    /// Moves the playhead by `frames` of the preview's rate; negative steps back.
    func step(frames: Int) {
        preview.pause()
        let frame = 1 / Double(previewCanvas.frameRate)
        let time = min(max(preview.currentTime + Double(frames) * frame, 0), preview.duration)
        requestedSourceTime =
            Timeline.sourceTime(forTimelineTime: time, keptRanges: playingRanges) ?? requestedSourceTime
        preview.scrub(to: time)
    }

    func goToStart() {
        preview.pause()
        requestedSourceTime = trimStart
        preview.scrub(to: 0)
    }

    func goToEnd() {
        preview.pause()
        requestedSourceTime = trimEnd
        preview.scrub(to: preview.duration)
    }

    /// `sourceTime` if it plays, else the kept boundary nearest to it; the
    /// clip's own start when nothing is kept.
    func nearestKeptSourceTime(_ sourceTime: Double) -> Double {
        let ranges = project.timeline.keptRanges()
        guard !ranges.isEmpty else { return clipSpan.lowerBound }
        if ranges.contains(where: { $0.contains(sourceTime) }) { return sourceTime }
        let candidates = ranges.flatMap { [$0.start, $0.end] }
        return candidates.min { abs($0 - sourceTime) < abs($1 - sourceTime) } ?? sourceTime
    }

    // MARK: Editing

    /// Applies `body` to the project as one undoable edit named `name`
    /// (inside a transaction, as part of it), then rebuilds and saves.
    /// A body that changes nothing registers nothing.
    func edit(_ name: String, _ body: (inout Project) -> Void) {
        let before = project
        var changed = project
        body(&changed)
        guard changed != before else { return }
        project = changed
        if transaction == nil {
            registerUndo(restoring: before, name: name)
        }
        didEdit()
    }

    /// Opens a transaction: every `edit` until `endTransaction()` is one
    /// undo step named `name`. A second begin while one is open is ignored.
    func beginTransaction(_ name: String) {
        guard transaction == nil else { return }
        transaction = (project, name)
    }

    func endTransaction() {
        guard let transaction else { return }
        self.transaction = nil
        guard project != transaction.before else { return }
        registerUndo(restoring: transaction.before, name: transaction.name)
    }

    func undo() {
        endTransaction()
        undoManager.undo()
    }

    func redo() {
        undoManager.redo()
    }

    private func registerUndo(restoring before: Project, name: String) {
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.project
            model.project = before
            model.registerUndo(restoring: current, name: name)
            model.didEdit()
        }
        undoManager.setActionName(name)
    }

    private func didEdit() {
        if let id = selectedSegmentID, !project.timeline.zoom.segments.contains(where: { $0.id == id }) {
            selectedSegmentID = nil
        }
        scheduleRebuild()
        // No autosave: the window asks on close, and ⌘S saves on demand.
    }

    // MARK: Trim

    /// Sets the kept stretch to `start...end` with `.trim` cuts at the head
    /// and the tail of the clip span; a bound at the span's own edge leaves
    /// no cut there. The stretch keeps at least `minimumKeptDuration`: the
    /// edge that moved (`movingEdge`; inferred from which bound changed
    /// when nil) gives way, and never past the span, so a start handle
    /// dragged beyond the end lands `minimumKeptDuration` before the span's
    /// end rather than on it.
    func setTrim(start: Double, end: Double, movingEdge: SpanEdge? = nil) {
        let span = clipSpan
        let minimum = min(settings.minimumKeptDuration, span.upperBound - span.lowerBound)
        var start = min(max(start, span.lowerBound), span.upperBound)
        var end = min(max(end, span.lowerBound), span.upperBound)
        if end - start < minimum {
            let moving = movingEdge ?? (start == trimStart ? SpanEdge.end : .start)
            switch moving {
            case .end:
                // The end came too close: it stays and the start gives way,
                // then the end is pushed back out if the start hit the span.
                start = max(end - minimum, span.lowerBound)
                end = min(max(end, start + minimum), span.upperBound)
            case .start:
                end = min(start + minimum, span.upperBound)
                start = max(min(start, end - minimum), span.lowerBound)
            }
        }
        let epsilon = settings.timeEpsilon
        edit("Trim") { project in
            let trims = project.timeline.cuts.filter { $0.provenance == .trim }
            // The existing cuts keep their ids, so a drag edits two cuts
            // rather than minting two per mouse event.
            let headID = trims.first { $0.start <= span.lowerBound + epsilon }?.id ?? UUID()
            let tailID = trims.first { $0.end >= span.upperBound - epsilon && $0.id != headID }?.id ?? UUID()
            project.timeline.cuts.removeAll { $0.provenance == .trim }
            if start > span.lowerBound + epsilon {
                project.timeline.cuts.append(Cut(id: headID, start: span.lowerBound, end: start, provenance: .trim))
            }
            if end < span.upperBound - epsilon {
                project.timeline.cuts.append(Cut(id: tailID, start: end, end: span.upperBound, provenance: .trim))
            }
        }
    }

    // MARK: Zoom segments

    func select(segment id: UUID?) {
        selectedSegmentID = id
    }

    /// Adds a `.manual` zoom of `settings.addedZoomDuration` at the
    /// playhead, aimed at the smoothed cursor there (the frame's centre
    /// without one) at the style's zoom amount, and selects it.
    func addZoomAtPlayhead() {
        let start = min(max(playheadSourceTime, 0), max(recordingDuration - settings.minimumSegmentDuration, 0))
        let end = min(start + settings.addedZoomDuration, recordingDuration)
        let focus = plan?.cursor.sample(at: start)?.smoothedPosition ?? NormalizedPoint(x: 0.5, y: 0.5)
        let segment = ZoomTrackSegment(
            start: start, end: end, focus: focus, amount: project.style.zoom.amount, source: .manual)
        edit("Add Zoom") { $0.timeline.zoom.segments.append(segment) }
        selectedSegmentID = segment.id
    }

    func deleteSegment(_ id: UUID) {
        edit("Delete Zoom") { $0.timeline.zoom.segments.removeAll { $0.id == id } }
    }

    /// Moves the segment so it starts at `start`, keeping its length inside
    /// the recording; the user has taken it over, so an automatic segment
    /// becomes `.manual`.
    func moveSegment(_ id: UUID, toStart start: Double) {
        updateSegment(id, "Move Zoom") { segment in
            let length = segment.end - segment.start
            let newStart = min(max(start, 0), max(self.recordingDuration - length, 0))
            segment.start = newStart
            segment.end = newStart + length
        }
    }

    /// Drags one edge of the segment to `time`, never past the other edge
    /// by less than `minimumSegmentDuration`.
    func resizeSegment(_ id: UUID, edge: SpanEdge, to time: Double) {
        let minimum = settings.minimumSegmentDuration
        updateSegment(id, "Resize Zoom") { segment in
            switch edge {
            case .start: segment.start = min(max(time, 0), segment.end - minimum)
            case .end: segment.end = max(min(time, self.recordingDuration), segment.start + minimum)
            }
        }
    }

    func setSegmentAmount(_ id: UUID, _ amount: Double) {
        let range = settings.zoomAmountRange
        updateSegment(id, "Zoom Amount") { $0.amount = min(max(amount, range.lowerBound), range.upperBound) }
    }

    func setSegmentFocus(_ id: UUID, _ focus: NormalizedPoint) {
        updateSegment(id, "Zoom Focus") {
            $0.focus = NormalizedPoint(x: min(max(focus.x, 0), 1), y: min(max(focus.y, 0), 1))
        }
    }

    /// Locking keeps the segment's source: a locked automatic segment is
    /// still the planner's, just one the replan may not touch.
    func setSegmentLocked(_ id: UUID, _ locked: Bool) {
        edit(locked ? "Lock Zoom" : "Unlock Zoom") { project in
            guard let index = project.timeline.zoom.segments.firstIndex(where: { $0.id == id }) else { return }
            project.timeline.zoom.segments[index].locked = locked
        }
    }

    /// Plans the zoom again from the log with the style's zoom settings and
    /// merges it onto the track: locked and manual segments stay, the rest
    /// is replaced (`ZoomTrackMerge.replan`).
    func replanZoom() {
        let planned = ZoomPlanner(settings: ZoomPlannerSettings(kit: project.style))
            .plan(log, recordingEnd: recordingDuration)
        let merge = settings.merge
        edit("Replan Zoom") { project in
            project.timeline.zoom = ZoomTrackMerge.replan(project.timeline.zoom, with: planned, settings: merge)
        }
    }

    private func updateSegment(_ id: UUID, _ name: String, _ body: (inout ZoomTrackSegment) -> Void) {
        edit(name) { project in
            guard let index = project.timeline.zoom.segments.firstIndex(where: { $0.id == id }) else { return }
            var segment = project.timeline.zoom.segments[index]
            body(&segment)
            if case .auto = segment.source, segment != project.timeline.zoom.segments[index] {
                segment.source = .manual
            }
            project.timeline.zoom.segments[index] = segment
        }
    }

    // MARK: Style and export settings

    /// Changes the look; `name` is the undo action's.
    func editStyle(_ name: String, _ body: (inout BrandKit) -> Void) {
        edit(name) { body(&$0.style) }
    }

    /// Records the export sheet's choices in the project, as the auto-render
    /// reads them next time. The codec is stored as the project already
    /// stores it (explicit, or nil for the preset's own) whenever that
    /// resolves to the same codec on the new preset, so exporting with the
    /// project's own settings changes nothing and is no edit.
    func setExport(preset: ExportPresetID, codec: ExportCodec?, frameRate: Int) {
        edit("Export Settings") { project in
            var changed = project.export
            changed.preset = preset
            changed.codec = codec
            changed.frameRate = frameRate
            var asStored = changed
            asStored.codec = project.export.codec
            if let stored = try? ExportPreset.resolve(asStored), let chosen = try? ExportPreset.resolve(changed),
                stored.codec == chosen.codec
            {
                changed.codec = asStored.codec
            }
            project.export = changed
        }
    }

    // MARK: Rebuild

    /// Builds the plan and the composition for the current project after
    /// `planDebounce`, dropping the result if a newer edit has arrived
    /// meanwhile (latest wins).
    private func scheduleRebuild(immediate: Bool = false) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                guard (try? await Task.sleep(for: .seconds(settings.planDebounce))) != nil else { return }
                guard generation == rebuildGeneration else { return }
            }
            await rebuild(generation: generation)
        }
    }

    private func rebuild(generation: Int) async {
        let inputs = PlanInputs(
            log: log, duration: recordingDuration, zoomTrack: project.timeline.zoom, kit: project.style,
            hasCamera: hasCamera, contentCrop: contentCrop)
        let keptRanges = project.timeline.keptRanges()
        let canvas = previewCanvas
        let audio = project.export.audio
        let plan = await Self.buildPlan(inputs)
        guard generation == rebuildGeneration, !isClosed else { return }
        self.plan = plan
        let atlas = atlas ?? CursorAtlas.load(for: plan, in: package)
        self.atlas = atlas
        do {
            let built = try await CompositionBuilder.build(
                package: package, keptRanges: keptRanges.map(\.closedRange), plan: plan,
                style: RenderStyle(kit: inputs.kit, canvas: canvas), cursor: atlas, canvas: canvas,
                settings: Self.compositionSettings(audio))
            guard generation == rebuildGeneration, !isClosed else { return }
            rebuildError = nil
            apply(
                built,
                key: CompositionKey(
                    keptRanges: keptRanges, canvas: canvas, screenTrackID: built.screenTrackID,
                    cameraTrackID: built.cameraTrackID, audio: audio))
        } catch {
            guard generation == rebuildGeneration else { return }
            rebuildError = error.localizedDescription
        }
    }

    /// A composition over the same kept ranges, canvas and tracks replaces
    /// the item's video composition in place (the paused frame re-renders
    /// by itself, S2); anything else is a new item, with the playhead put
    /// back where it was in recording time: read through the old item's
    /// kept ranges before `loadedComposition` moves to the new ones, so a
    /// trim never carries the playhead along with it.
    private func apply(_ built: BuiltComposition, key: CompositionKey) {
        if key == loadedComposition, preview.item != nil {
            preview.replaceVideoComposition(built.videoComposition)
            return
        }
        let wasLoaded = loadedComposition != nil
        let sourceTime = playheadSourceTime
        loadedComposition = key
        preview.load(built)
        if wasLoaded {
            scrub(toSourceTime: sourceTime)
        }
    }

    /// The three planners, on the global executor.
    private nonisolated static func buildPlan(_ inputs: PlanInputs) async -> RenderPlan {
        RenderPlan.build(
            log: inputs.log, duration: inputs.duration, zoomTrack: inputs.zoomTrack, kit: inputs.kit,
            hasCamera: inputs.hasCamera, contentCrop: inputs.contentCrop)
    }

    /// The mix levels as the composition builder takes them: linear gains
    /// from the project's decibels, as the exporter converts them.
    private static func compositionSettings(_ audio: ExportAudioSettings) -> CompositionSettings {
        var settings = CompositionSettings()
        settings.systemAudioGain = Float(pow(10, audio.systemAudioGainDB / 20))
        settings.microphoneGain = Float(pow(10, audio.microphoneGainDB / 20))
        return settings
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await Task.sleep(for: .seconds(settings.saveDebounce))) != nil else { return }
            save()
        }
    }

    /// Writes `project.json` now, if an edit has been made; the store
    /// preserves the opened file as `project.json.previous` on the
    /// session's first save.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard isEdited else { return }
        do {
            try store.save(project)
            savedProject = project
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The window is closing: the pending save is written, the export in
    /// flight is cancelled and the player released. Safe to call twice.
    /// Set by the close prompt's Don't Save: the edits stay in memory only.
    var discardsOnClose = false

    func close() {
        endTransaction()
        isClosed = true
        rebuildGeneration += 1
        rebuildTask?.cancel()
        rebuildTask = nil
        if !discardsOnClose { save() }
        cancelExport()
        preview.tearDown()
    }

    // MARK: Export

    /// Exports the project with the sheet's choices (recorded in the
    /// project first) into the exports folder, through the same plan the
    /// preview shows, built fresh from the project so a debounced rebuild
    /// cannot lag behind it. Progress and the result arrive in `exportState`.
    func export(preset: ExportPresetID, codec: ExportCodec?, frameRate: Int) {
        guard !exportState.isRunning else { return }
        setExport(preset: preset, codec: codec, frameRate: frameRate)
        let inputs = PlanInputs(
            log: log, duration: recordingDuration, zoomTrack: project.timeline.zoom, kit: project.style,
            hasCamera: hasCamera, contentCrop: contentCrop)
        let project = project
        let package = package
        let directory = exportsDirectory()
        let exporter = Exporter(settings: settings.writer)
        self.exporter = exporter
        exportState = .running(
            ExportProgress(
                phase: .preparing, writtenSeconds: 0, durationSeconds: 0, framesWritten: 0, expectedFrames: 0,
                elapsedSeconds: 0))
        exportTask = Task { [weak self] in
            guard let self else { return }
            await runExport(
                inputs: inputs, project: project, package: package, directory: directory, exporter: exporter)
        }
    }

    private func runExport(
        inputs: PlanInputs, project: Project, package: RecordingPackage, directory: URL, exporter: Exporter
    ) async {
        do {
            let plan = await Self.buildPlan(inputs)
            let job = try ExportJob(package: package, project: project, plan: plan, destinationDirectory: directory)
            let result = try await exporter.export(job) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.exportState.isRunning else { return }
                    self.exportState = .running(progress)
                }
            }
            exportState = .done(result)
        } catch let error as ExportError where error == .cancelled {
            exportState = .cancelled
        } catch {
            exportState = .failed(error.localizedDescription)
        }
        self.exporter = nil
        exportTask = nil
    }

    /// Ends the export in flight; nothing is left on disk.
    func cancelExport() {
        guard let exporter else { return }
        Task { await exporter.cancel() }
    }

    /// Waits for the export in flight to end, for callers that need its result.
    func awaitExport() async {
        await exportTask?.value
    }

    func resetExportState() {
        guard !exportState.isRunning else { return }
        exportState = .idle
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Self-check

/// `Cutscene --editor-check <package> [--exports <directory>]`: drives an
/// `EditorModel` over a package without a window (PLAN M2-10 acceptance)
/// and prints PASS or FAIL. Opening and closing leaves `project.json` byte
/// for byte and writes no `.previous`; a trim shortens the export; a moved
/// and locked segment survives a replan; undo and redo restore the
/// project; the first edit saves and preserves the opened file. The full
/// export's numbers are printed for comparison with the export spike. The
/// package is edited, so the caller passes a copy. No permission is needed.
enum EditorSelfCheck {
    /// Seconds trimmed off each end of the recording for the trim check.
    static let trimSeconds = 1.0
    /// Seconds a segment is moved by for the replan check.
    static let moveSeconds = 0.5
    /// Composition and export durations may differ from the kept seconds
    /// by the first-frame clipping (the recorder's start latency) plus one
    /// frame.
    static let durationTolerance = 0.3
    /// How long the first composition may take to appear in the player.
    static let loadTimeout = 10.0
    static let pollInterval = 0.02
    /// Where the playhead is parked for the trim check, past the head trim.
    static let parkedSeconds = 4.0
    /// How far the playhead may read from where it was parked: a frame at
    /// the preview's rate, the seek being zero-tolerance.
    static let playheadTolerance = 1.0 / 60
    /// How long a seek may take to settle the playhead.
    static let seekTimeout = 3.0

    /// Runs the check on the main actor under the main run loop, which the
    /// player's and the exporter's completions need, and returns the exit code.
    @MainActor static func run(arguments: [String]) -> Int32 {
        let outcome = Outcome()
        // The run loop needs a source to keep running between callbacks.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        Task { @MainActor in
            let code = await check(arguments: arguments)
            outcome.code = code
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while outcome.code == nil {
            CFRunLoopRun()
        }
        keepAlive.invalidate()
        return outcome.code ?? 1
    }

    @MainActor private final class Outcome {
        var code: Int32?
    }

    @MainActor private static func check(arguments: [String]) async -> Int32 {
        guard let first = arguments.first else {
            print("usage: Cutscene --editor-check <package> [--exports <directory>]")
            return 2
        }
        var exports = RecordingPackage.defaultExportsDirectory
        if let index = arguments.firstIndex(of: "--exports"), index + 1 < arguments.count {
            exports = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        let url = URL(fileURLWithPath: first)
        var failures: [String] = []
        do {
            try await checks(url: url, exports: exports, failures: &failures)
        } catch {
            failures.append("threw \(error.localizedDescription)")
        }
        if failures.isEmpty {
            print("PASS")
            return 0
        }
        print("FAIL: " + failures.joined(separator: "; "))
        return 1
    }

    @MainActor private static func checks(url: URL, exports: URL, failures: inout [String]) async throws {
        let package = RecordingPackage(url: url)
        let originalBytes = try? Data(contentsOf: package.projectURL)
        print("editor check: \(package.url.path)")
        let destination: @MainActor () -> URL = { exports }

        // 1. Open, wait for the preview, close: nothing written.
        let unedited = try await EditorModel.load(url: url, exportsDirectory: destination)
        try await waitForComposition(unedited)
        print(
            "opened: project from \(unedited.projectSource), \(format(unedited.recordingDuration)) s, "
                + "\(unedited.timeline.zoom.segments.count) zoom segments (plan generation "
                + "\(unedited.timeline.zoom.planGeneration)), preview \(unedited.previewCanvas.width)×"
                + "\(unedited.previewCanvas.height) @ \(unedited.previewCanvas.frameRate), composition "
                + "\(format(unedited.preview.duration)) s")
        let unlockedAuto = unedited.timeline.zoom.segments.filter(\.isReplaceableByReplan).count
        unedited.close()
        let afterBytes = try? Data(contentsOf: package.projectURL)
        if originalBytes == afterBytes {
            print("unedited: project.json byte-identical (\(afterBytes?.count ?? 0) bytes)")
        } else {
            failures.append("project.json changed after an unedited open and close")
        }
        if FileManager.default.fileExists(atPath: package.previousProjectURL.path) {
            failures.append("project.json.previous was written without an edit")
        }
        if unedited.isEdited { failures.append("the model reports an edit after none") }

        // 2. Full export, as the sheet would with the project's settings.
        let model = try await EditorModel.load(url: url, exportsDirectory: destination)
        try await waitForComposition(model)
        let fullDuration = model.preview.duration
        let settings = model.project.export
        model.export(preset: settings.preset, codec: settings.codec, frameRate: settings.frameRate)
        await model.awaitExport()
        guard case .done(let full) = model.exportState else {
            failures.append("the full export did not finish: \(model.exportState)")
            return
        }
        print(
            "full export: \(full.outputURL.lastPathComponent): \(full.preset.label), \(format(full.durationSeconds)) s, "
                + "\(full.frameCount) frames (\(full.expectedFrameCount) expected), \(full.fileSizeBytes >> 10) KiB, "
                + "\(String(format: "%.2f", full.speed))× real time, faststart \(full.isFaststart)")
        if abs(full.durationSeconds - fullDuration) > durationTolerance {
            failures.append("the full export is \(full.durationSeconds) s, the preview \(fullDuration) s")
        }
        // The export settings written by the sheet are the project's own,
        // so recording them is no change.
        if model.isEdited { failures.append("exporting with the project's own settings counted as an edit") }

        // 3. Trim with the playhead parked, undo, redo. The playhead is
        // read through the kept ranges the player's item was built on, so
        // the head trim must not carry it forward by the trimmed second.
        let span = model.clipSpan
        let start = span.lowerBound + trimSeconds
        let end = span.upperBound - trimSeconds
        let parked = min(start + parkedSeconds, end)
        model.scrub(toSourceTime: parked)
        try await waitForPlayhead(model, at: parked)
        model.beginTransaction("Trim")
        model.setTrim(start: start, end: end)
        model.setTrim(start: start, end: end)
        model.endTransaction()
        let trimCuts = model.timeline.cuts.filter { $0.provenance == .trim }
        if trimCuts.count != 2 || abs(model.trimStart - start) > 1e-9 || abs(model.trimEnd - end) > 1e-9 {
            failures.append("trim left \(trimCuts.count) cuts, \(model.trimStart)–\(model.trimEnd)")
        }
        let keptSeconds = model.timeline.duration
        try await waitForComposition(model, expecting: keptSeconds)
        do {
            try await waitForPlayhead(model, at: parked)
            print(
                "playhead parked at \(format(parked)) s stayed at \(format(model.playheadSourceTime)) s through the trim"
            )
        } catch {
            failures.append(
                "the playhead parked at \(format(parked)) s drifted to \(format(model.playheadSourceTime)) s after the trim"
            )
        }
        print(
            "trimmed to \(format(start))–\(format(end)) s: \(trimCuts.count) .trim cuts, kept \(format(keptSeconds)) s, "
                + "composition \(format(model.preview.duration)) s")
        if !model.canUndo { failures.append("no undo after the trim") }
        model.undo()
        if !model.timeline.cuts.isEmpty { failures.append("undo left \(model.timeline.cuts.count) cuts") }
        if !model.canRedo { failures.append("no redo after the undo") }
        model.redo()
        if model.timeline.cuts.filter({ $0.provenance == .trim }).count != 2 {
            failures.append("redo did not restore the trim")
        }
        print(
            "undo and redo: cuts \(model.timeline.cuts.count) after redo, undo \(model.canUndo), redo \(model.canRedo)")

        // The start handle dragged past the end keeps the minimum stretch
        // before the span's end rather than cutting everything; the trim is
        // then put back for the steps below.
        model.setTrim(start: span.upperBound, end: model.trimEnd, movingEdge: .start)
        let overshoot = model.trimEnd - model.trimStart
        if abs(overshoot - model.settings.minimumKeptDuration) > 1e-9 || model.timeline.keptRanges().isEmpty {
            failures.append("a start handle past the end left \(overshoot) s kept")
        }
        print("start handle past the end: kept \(format(model.trimStart))–\(format(model.trimEnd)) s")
        model.setTrim(start: start, end: end)

        // 4. A moved, locked segment survives a replan; a manual one too.
        guard let moved = model.timeline.zoom.segments.first(where: \.isReplaceableByReplan) else {
            failures.append("no automatic segment to move")
            return
        }
        // Forward unless the segment already reaches the recording's end
        // (a zoom held to the stop click does), then back.
        let movedStart =
            moved.end + moveSeconds <= model.recordingDuration
            ? moved.start + moveSeconds : max(moved.start - moveSeconds, 0)
        model.beginTransaction("Move Zoom")
        model.moveSegment(moved.id, toStart: movedStart)
        model.endTransaction()
        model.setSegmentLocked(moved.id, true)
        model.scrub(toSourceTime: end - trimSeconds)
        model.addZoomAtPlayhead()
        let addedID = model.selectedSegmentID
        let generationBefore = model.timeline.zoom.planGeneration
        model.replanZoom()
        let track = model.timeline.zoom
        guard let survivor = track.segments.first(where: { $0.id == moved.id }) else {
            failures.append("the moved, locked segment vanished in the replan")
            return
        }
        if abs(survivor.start - movedStart) > 1e-9 || !survivor.locked {
            failures.append("the locked segment moved in the replan: \(survivor.start) vs \(movedStart)")
        }
        if survivor.source != .manual { failures.append("a moved segment did not become .manual: \(survivor.source)") }
        if let addedID, !track.segments.contains(where: { $0.id == addedID && $0.source == .manual }) {
            failures.append("the added manual segment vanished in the replan")
        }
        if track.planGeneration != generationBefore + 1 {
            failures.append("replan generation \(track.planGeneration), expected \(generationBefore + 1)")
        }
        let auto = track.segments.filter(\.isReplaceableByReplan)
        if auto.contains(where: { $0.source != .auto(generation: track.planGeneration) }) {
            failures.append("a replaceable segment is not from the new generation")
        }
        print(
            "replan: generation \(track.planGeneration), \(track.segments.count) segments "
                + "(\(auto.count) automatic, \(unlockedAuto) before), moved segment at \(format(survivor.start)) s "
                + "locked \(survivor.locked) \(survivor.source)")

        // 5. The trimmed export is shorter by the trims.
        try await waitForComposition(model, expecting: model.timeline.duration)
        model.export(preset: settings.preset, codec: settings.codec, frameRate: settings.frameRate)
        await model.awaitExport()
        guard case .done(let trimmed) = model.exportState else {
            failures.append("the trimmed export did not finish: \(model.exportState)")
            return
        }
        print(
            "trimmed export: \(trimmed.outputURL.lastPathComponent): \(format(trimmed.durationSeconds)) s, "
                + "\(trimmed.frameCount) frames, \(trimmed.fileSizeBytes >> 10) KiB "
                + "(full \(format(full.durationSeconds)) s, kept \(format(model.timeline.duration)) s)")
        let expectedShorter = full.durationSeconds - model.timeline.duration
        if abs((full.durationSeconds - trimmed.durationSeconds) - expectedShorter) > durationTolerance
            || trimmed.durationSeconds >= full.durationSeconds
        {
            failures.append(
                "the trimmed export is \(trimmed.durationSeconds) s against \(full.durationSeconds) s full; "
                    + "expected about \(full.durationSeconds - expectedShorter) s")
        }

        // 6. Close saves; the opened file is preserved once.
        model.close()
        let saved = try? Data(contentsOf: package.projectURL)
        let previous = try? Data(contentsOf: package.previousProjectURL)
        if saved == originalBytes { failures.append("the edited project was not saved") }
        if originalBytes != nil, previous != originalBytes {
            failures.append("project.json.previous is not the opened file")
        }
        let reloaded = try Project.read(from: package.projectURL)
        if reloaded != model.project { failures.append("the saved project does not read back equal") }
        print(
            "saved: project.json \(saved?.count ?? 0) bytes, .previous \(previous?.count ?? 0) bytes "
                + "(opened \(originalBytes?.count ?? 0)), reads back equal \(reloaded == model.project)")
    }

    /// Waits until the player holds a composition, of about `expecting`
    /// seconds when given.
    @MainActor private static func waitForComposition(_ model: EditorModel, expecting: Double? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(loadTimeout)
        while ContinuousClock.now < deadline {
            if model.preview.item != nil, model.plan != nil, model.rebuildError == nil,
                expecting.map({ abs(model.preview.duration - $0) <= durationTolerance }) ?? true
            {
                return
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw CocoaError(
            .fileReadUnknown,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "the composition did not load in \(loadTimeout) s"
                    + (model.rebuildError.map { ": \($0)" } ?? "") + " (duration \(model.preview.duration))"
            ])
    }

    /// Waits until the playhead reads `sourceTime` within `playheadTolerance`.
    @MainActor private static func waitForPlayhead(_ model: EditorModel, at sourceTime: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(seekTimeout)
        while ContinuousClock.now < deadline {
            if abs(model.playheadSourceTime - sourceTime) <= playheadTolerance { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw CocoaError(
            .fileReadUnknown,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "the playhead reads \(model.playheadSourceTime) s, not \(sourceTime) s, after \(seekTimeout) s"
            ])
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
