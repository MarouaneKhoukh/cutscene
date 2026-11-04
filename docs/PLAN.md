# Cutscene plan (v1, cut for parallel coding agents)

Binding inputs, in order: [ARCHITECTURE.md](ARCHITECTURE.md), [DECISIONS.md](DECISIONS.md),
[platform-notes.md](platform-notes.md), the code under `Sources/`. The panel's
engineer-day plan ([design/plan-panel.md](design/plan-panel.md)) is superseded.
Milestones are the lead's: **M1** = the first build the team uses (record a
display from the menu bar with the mic, stop, get a styled MP4 automatically;
no editor), **M2** = camera, window and area, click effects, presets, a minimal
editor, **M3** = multi-take, Studio Sound and loudness, brand kits, headless
CLI. ARCHITECTURE §10 uses this numbering and carries the mapping from its
earlier draft (M1 ≈ old M0 + M1a without click effects, M2 ≈ the old M1 editor
+ M2, M3 ≈ old M3 plus three items DECISIONS.md lists as v2: multi-take, Studio
Sound, CLI, pulled forward at the lead's instruction; M1-14 records the ADR).

**Every task.** `G` = `swift build` with zero warnings, `swift format` then
`swift format lint --strict` clean, `make check` green. Edit only the files the
task lists; never touch git or delete `.build`. Every number is a named tunable
in a settings struct, `BrandKit` or `CaptureRequest`. Comments say why.
Paths: `Core`=`Sources/CutsceneCore`, `Engine`=`Sources/CutsceneEngine`,
`Capture`=`Sources/CutsceneCapture`, `Render`=`Sources/CutsceneRender`,
`Export`=`Sources/CutsceneExport`, `App`=`Sources/Cutscene`,
`Spike`=`Sources/CutsceneSpike`, `Check`=`Sources/CutsceneCheck`.

**Permission rule for spikes.** A live spike first preflights
(`CGPreflightScreenCaptureAccess()`, `AVCaptureDevice.authorizationStatus`,
`CGPreflightListenEventAccess()`) and exits with code **3**, "skipped:
<capability> not granted to this terminal"; no request API or
`SCShareableContent` call before the preflight passes. An agent runs a live
spike only when the preflight passes; otherwise the lead runs it and pastes
the output into the task. Nothing an agent runs may raise a macOS prompt.

**Shared entry files.** `Spike/main.swift`, `Check/main.swift` and
`Package.swift` are edited only by each milestone's `-00` task, which
registers that milestone's spike and check files as stubs; the owning task
fills its own file. Ownership is disjoint among tasks marked ∥ (parallel).

---

## Foundations (DONE)

| id | What | Files | Verified by |
| --- | --- | --- | --- |
| F1 | Core vocabulary, `EventLog` format 1 | `Core/{CutsceneCore,InputEvent,EventLog}.swift` | `make check` fixture |
| F2 | Springs, `CursorSmoother`, `ZoomPlanner`, `CameraPlanner` | `Engine/{Spring,Easing,CursorSmoother,ZoomPlanner,CameraPlanner,CutsceneEngine}.swift` | `make check`, 323 checks, 500 ms budget |
| F3 | `RecordingClock` | `Capture/RecordingClock.swift` | writer and telemetry spikes |
| F4 | `VideoEncoder` + `RecordingWriter` (fragmented mov, passthrough, AAC tracks, end marker, `NeedsFinalizeMarker`, `finalize`) | `Capture/{VideoEncoder,RecordingWriter}.swift`, `Spike/WriterSpike.swift` | `make spike ARGS="writer"` + ffprobe |
| F5 | `InputTelemetryRecorder` (125 Hz poll, tap when granted, sidecar, `recoverLog`), `CursorShapeSampler` | `Capture/{InputTelemetryRecorder,CursorShapeSampler}.swift`, `Spike/TelemetrySpike.swift` | `make spike ARGS="telemetry 3"` |
| F6 | Compositor core: `Compositor.render(_:style:)` / `render(_:style:to:)`, `SourceFrame`, `RenderStyle`, `CursorSprite.arrow`, runtime-compiled shader | `Render/{Compositor,RenderStyle,CursorSprite,ShaderSource,CutsceneRender}.swift`, `Spike/RenderSpike.swift` | `make spike ARGS="render"`, PNGs, median < 8 ms |
| F7 | Package, Makefile, bundle and dev-cert scripts, CI, check and spike runners | `Package.swift`, `Makefile`, `scripts/*.sh`, `.github/workflows/ci.yml`, `Check/main.swift`, `Spike/main.swift` | `swift build`, `make check` |
| F8 | Dev window (preflight, request, relaunch); `SCRecordingOutput` proof | `App/CutsceneApp.swift`, `Capture/{RecordingSpike,CutsceneCapture}.swift` | manual; M1-12 replaces the window, the proof stays |

---

## Milestone 1: record a display from the menu bar, get a styled MP4

**Gate.** From `make run` with Screen Recording granted: menu bar → Record
Display → talk and click for 30 s → Stop → a `.cutscene` package in
`~/Movies/Cutscene/` (`manifest.json`, `screen.mp4`, `events.json`,
`frames.jsonl`, `project.json`) and, without another click, an MP4 in
`~/Movies/Cutscene/Exports/` that opens in QuickTime: gradient background,
padded rounded card with shadow, re-drawn smooth cursor, auto-zoom around
clicks, mic in sync. A take killed with `kill -9` is offered at the next launch
and renders. No editor, ripples or camera.

| id | Task · module · files · builds on | Acceptance (from the shell) | Deps | ∥ |
| --- | --- | --- | --- | --- |
| M1-00 | **Entry-point registry.** Edit `Spike/main.swift`: cases `permissions`, `clicks`, `session`, `reader`, `export`; stubs `Spike/{PermissionsSpike,ClickSpike,SessionSpike,ReaderSpike,ExportSpike}.swift` (`enum XSpike { static func run(arguments: [String]) async -> Bool }` printing "not implemented"). Edit `Check/main.swift` to call `runRecordingFormatChecks`, `runProjectChecks`, `runRenderPlanChecks`, `runKitChecks`, empty `@MainActor func`s in new `Check/{RecordingFormatChecks,ProjectChecks,RenderPlanChecks,KitChecks}.swift`. `Package.swift`: `CutsceneCheck` also depends on `CutsceneRender` (`RenderStyle` is pure). | G; `make check` still 323 passes; `swift run cutscene-spike clicks` exits 1 | — | no, first |
| M1-01 | **Core: recording format.** Create `Core/JSONValue.swift` (`JSONValue`, `PreservesUnknownKeys` with `extra`), `Core/RecordingManifest.swift` (`RecordingManifest`, `CaptureSource` `.display/.window/.area` + `WindowStrategy`, `ContentGeometry`, `ScreenTrackInfo`, `CameraTrackInfo`, `RecordingState`, `StopReason`), `Core/FrameIndex.swift` (`FrameIndexEntry`, `gap`/`hold`, JSONL writer, torn-line-tolerant reader), `Core/RecordingPackage.swift` (§3 layout, `create(at:)`, atomic JSON writes, default folders). Fill `Check/RecordingFormatChecks.swift`. Builds on F1. | G; pinned manifest JSON; invented fields at two levels survive decode → encode (JSON-equal); a torn last `frames.jsonl` line yields every complete entry; geometry keys only when changed; package URLs stable | M1-00 | yes |
| M1-02 | **Core: event log format 2.** Edit `Core/{InputEvent,EventLog}.swift`: `scroll`, `focus`, `geometry`, optional global `gx`/`gy`, `.unknown(kind:raw:)` re-emitted verbatim; `currentFormatVersion = 2`; reads 1 and 2, refuses newer. The one M1 edit allowed in `Check/main.swift`: its `eventLogFixture` block and the flipped "unknown kinds" check. | G; the format-1 fixture decodes and re-encodes as 2 (pinned); `{"type":"shell",…}` round-trips JSON-equal; each new kind pinned; `telemetry 3` still passes | M1-00 | yes |
| M1-03 | **Core: project model.** Create `Core/Project.swift` (`formatVersion`, `recording`, `timeline`, `kit`, `style`, `kitReference`, `export`, `extra`), `Core/Timeline.swift` (`Timeline`, `Clip`, `Cut` + `Provenance` `.trim/.manual/.retake(UUID)/.silence/.transcriptWords`, `ZoomTrack`, `ZoomTrackSegment` per §3, `keptRanges()`), `Core/BrandKit.swift` (schema 1; the §3 groups and defaults as named fields), `Core/ExportSettings.swift`, `Core/ProjectStore.swift` (atomic, `.previous` once per session), `Core/Migrator.swift` (ordered steps, v1 identity, newer refused). Fill `Check/ProjectChecks.swift`. *Decision:* Core mirrors the Engine settings and `ZoomSegment` field-for-field (Core cannot import Engine); M1-05 and M2-01 adapt. | G; pinned round trip; `keptRanges()` of one clip with two `.trim` cuts is the inner range; unknown keys at every level survive load → edit → save; `BrandKit.default` JSON pinned; `formatVersion: 99` refused with a typed error | M1-01 | yes |
| M1-04 | **Engine: `RenderPlan`.** Create `Engine/RenderPlan.swift`: immutable `Sendable` plan (cursor `CursorTimeline`, `[ZoomSegment]`, `CameraTimeline`, cursor-shape changes, duration); `nonisolated static func build(log:duration:cursor:zoom:camera:) -> sending RenderPlan`; `frameState(at:) -> FrameState { viewport, viewportVelocity, cursor: CursorSample?, cursorShape: CursorShape? }` from `CameraTimeline.viewport(at:)` and `CursorTimeline.sample(at:)`. Fill `Check/RenderPlanChecks.swift`. Builds on F2. | G; identical inputs give identical `FrameState`s; viewport inside [0,1]² at 1 000 times of the 30-minute fixture, whose build prints its time and stays under the `make check` budget (1500 ms in the default debug run, 500 ms in release); `cursorShape` at t is the last `cursorShapeChanged` ≤ t | M1-00 | yes |
| M1-05 | **Kit adapters.** Create `Engine/KitSettings.swift` (`CursorSmootherSettings(kit:)`, `ZoomPlannerSettings(kit:)`, `CameraPlannerSettings(kit:)`), `Render/KitStyle.swift` (`RenderStyle(kit:canvas:)`: background, padding, radius scaled by height/1080, shadow, cursor scale). `BrandKit.default` carries `RenderStyle`'s implemented defaults (ARCHITECTURE §3: #1C2B4B → #4A1F5E at 45°, radius 18, shadow 0.55 / 48 / (0, 18), cursor scale 1), so one set of defaults exists; if M1-03 landed other values, change the kit, not `RenderStyle`. Fill `Check/KitChecks.swift`. | G; `BrandKit.default` maps to each Engine default; `RenderStyle(kit: .default, canvas: 1920×1080) == RenderStyle()`; the default kit at 3840×2160 equals the 1080p style `.scaled(by: 2)` with the size doubled | M1-03, M1-04 | yes |
| M1-06 | **Capture: request, permissions, stream configuration.** Create `Capture/CaptureRequest.swift` (§8 fields and defaults; `quality: VideoQuality` maps straight onto `VideoEncoderConfiguration.quality`, the encoder's own name for the bit-rate tier), `Capture/Permissions.swift` (four capabilities; `.notDetermined/.denied/.grantedPendingRelaunch/.granted`; preflight never prompts; request; deep links), `Capture/ShareableContent.swift` (displays, windows, our `SCRunningApplication`; only after `.granted`), `Capture/StreamConfigurationBuilder.swift` (§2 display mode, `colorSpaceName = sRGB` and `colorMatrix = 709` pinned, since the compositor refuses frames tagged for any other space; window and area throw until M2-06). Fill `Spike/PermissionsSpike.swift`: prints the four states; `--config W H scale` prints the resolved configuration for a synthetic display. Builds on F8. | G; `make spike ARGS="permissions"` prints four states, no dialog, exit 0; `--config 3024 1964 2` prints every §2 value (`420v`, sRGB/709, cursor and clicks hidden, `queueDepth 8`, `1/60`, `.best`, `.SDR`, audio, mic) | M1-00 | yes |
| M1-07 | **Capture: `ClickMonitors` + spike S3.** Create `Capture/ClickMonitors.swift` (`NSEvent` global **and** local monitors for mouse down/up and scroll; `NSEvent.timestamp` is seconds, so host time is `RecordingClock.hostTime(eventTimestamp: UInt64(event.timestamp * 1e9))`, the nanosecond `CGEventTimestamp` form that function takes; S3 checks the two agree within 8 ms); edit `Capture/InputTelemetryRecorder.swift` to take monitor edges as the source between the tap and the poll (still never prompts). Fill `Spike/ClickSpike.swift`: 10 s with its own `NSWindow`; clicks seen by monitors vs poll edges (vs the tap only when Input Monitoring is already granted). Results into `docs/platform-notes.md`. | G; `make spike ARGS="clicks 10"` catches every click incl. those on its own window; monitor − poll-edge offset median ≤ 8 ms; no Input Monitoring or Accessibility prompt (lead confirms from a reset state); `telemetry 3` passes | M1-00 | yes |
| M1-08 | **Capture: `CaptureSession`.** Create `Capture/CaptureSession.swift` (`actor` on a `DispatchSerialQueue` executor; `start(request:package:) -> AsyncStream<CaptureStatus>`; `stop() -> RecordingManifest`; owns `RecordingClock`, `VideoEncoder`, `RecordingWriter`, `InputTelemetryRecorder` (sidecar in the package), `ClickMonitors`, `ScreenFrameIndexer`; 1 s heartbeat re-encoding the last complete frame (checksum, copy fallback) with `hold` lines; `beginActivity`; disk preflight ≥ 2 GB; manifest `.inProgress` → `.complete` with `stopReason`; `didStopWithError` → finish path; `project.json` via `ProjectStore` with the default kit; at stop, `telemetry.sprites()` written as `recording/cursors/<CursorShape.id>.png`, the files `CursorAtlas` (M1-10) reads), `Capture/StreamOutputShim.swift` (`SCStreamOutput` → `assumeIsolated`), `Capture/ScreenFrameIndexer.swift`. Builds on F3–F5. | G under strict concurrency, no `@unchecked` on the session; proof is M1-09, whose package holds one PNG per cursor shape seen | M1-01, M1-03, M1-06, M1-07 | yes |
| M1-09 | **Spike S1: live session.** Fill `Spike/SessionSpike.swift`: preflight; record the main display N s with the mic into a temp package; print frame counts (complete/idle/hold), encoder and writer statistics, SCK PTS vs `synchronizationClock`, the first frame's `CVBufferCopyAttachments`; ffprobe: `hvc1`, `has_b_frames=0`, keyframe gap ≤ 2 s on static content, two AAC tracks, video = audio ± 1 frame, `moov` before `mdat`. `--crash`: spawn itself recording 10 s, `SIGKILL` at 5 s, `RecordingWriter.finalize` + `recoverLog`, ffprobe. `--pause`: 2 s pause, sample-exact audio join. `--long 600`: load < 1 s, zero-tolerance seek < 150 ms. `--mic <uniqueID>` for a 4-channel interface. Findings into `docs/platform-notes.md` (colour tags decide `capture.colorTags`). | `make spike ARGS="session 10"`, `--crash` and `--pause` print PASS; `cursors/` holds a PNG for every `cursorShapeChanged` id in `events.json`; `--long 600` numbers recorded; exit 3 without the grant | M1-08 | no |
| M1-10 | **Render: composition path + spike S2 (reader half).** Create `Render/CanvasSpec.swift`, `Render/RenderInstruction.swift` (carries `RenderPlan`, `RenderStyle`, `CursorAtlas`, time mapping), `Render/MetalCompositor.swift` (`AVVideoCompositing` holding one `Compositor`: BGRA/IOSurface/Metal attributes; synchronous `startRequest`: `sourceFrame(byTrackID:)`, the last delivered frame retained and reused when nil, `Compositor.render(_:style:into:)` on the context's `newPixelBuffer()`; `finish`; cancel; `flush()` on cancel and after the last request), `Render/CompositionBuilder.swift` (§5: `build(package:keptRanges:plan:style:cursor:canvas:)`, one insert per kept range handed in by the caller (M1-13 passes the whole recording, M2-10 `timeline.keptRanges()`, so no `Project` is needed here), `customVideoCompositorClass`, `renderSize`, `frameDuration 1/fps`, `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid`, source colour triple, `AVMutableAudioMix`), `Render/CursorAtlas.swift` (`CursorSprite` per `CursorShape.id` from `cursors/<CursorShape.id>.png`, written by M1-08; `.arrow` fallback). Fill `Spike/ReaderSpike.swift`: 60 fps through `AVAssetReaderVideoCompositionOutput`, 8 PNGs, request latency median/max, held-frame count; `--synthetic` first builds its own package (WriterSpike's frame source through `VideoEncoder` + `RecordingWriter`, a fixture `EventLog` with clicks and a non-arrow `cursorShapeChanged` plus its PNG, through `RecordingPackage.create(at:)`), so the acceptance needs no M1-09 recording. Builds on F6. | G; `make spike ARGS="reader --synthetic"` (and `reader <package>` on an M1-09 recording): PNGs show background, card, shadow, the non-arrow cursor, zoom; frames = ⌈duration × 60⌉ ± 1; no black frame at holds; median latency printed (> 16.7 ms at 4K trips the v2 decoder) | M1-01, M1-04 | yes |
| M1-11 | **Export.** Create `Export/ExportPreset.swift` (1080p H.264 High 16/24 Mb/s, 4K HEVC 45/70; 60 fps, 30 option), `Export/ExportWriterSettings.swift` (`RealTime false`, reordering on, 2 s keyframes, 709, hardware required), `Export/Exporter.swift` (`actor` per §6: reader with video-composition and audio-mix outputs → `AVAssetWriter` mp4 through the pixel-buffer adaptor, faststart, AAC 192 kbps; progress; cancel; self-check; disk guard; atomic move to `Exports`), `Export/ExportProgress.swift`; edit `Export/CutsceneExport.swift`. Fill `Spike/ExportSpike.swift`. | G; `make spike ARGS="export <package> [4k]"` PASS: ffprobe `avc1` High (or `hvc1`), constant 60 fps, `nb_frames` = duration × 60 ± 1, AAC 48 kHz, faststart; prints speed × real time; cancel leaves nothing | M1-10, M1-05 | yes |
| M1-12 | **App: menu-bar recorder.** Rewrite `App/CutsceneApp.swift` (`MenuBarExtra`, `Settings` stub); create `App/AppModel.swift`, `App/RecorderController.swift` (`idle → selecting → recording → finishing → rendering → done(url) / failed(error, partialURL)`), `App/MenuBarMenu.swift` (Record Display ▸ displays, Microphone ▸ devices/off, System Audio, Stop, Open Last Export, Reveal Last Recording, Settings…, Quit), `App/PermissionsModel.swift` (§7 re-preflight), `App/OnboardingWindow.swift` (rows, deep links, Relaunch), `App/Relauncher.swift` (`openApplication(at:configuration:)` + `createsNewApplicationInstance`), `App/Defaults.swift`. Edit `scripts/bundle.sh`: `LSUIElement`, `NSCameraUseContinuityCameraDeviceType`, `.cutscene` document type. Builds on F8. | G; `make run`: no Dock icon; Record Display → icon changes → Stop → package with manifest `.complete`; menu and onboarding absent from the capture; after a fresh grant the relaunch state shows and Relaunch works | M1-06, M1-08 | yes |
| M1-13 | **App: auto-render + recovery.** Create `App/AutoRender.swift` (after stop: `RenderPlan.build` off the main actor, `CompositionBuilder` with the whole recording as the one kept range, `Exporter` 1080p default, progress in the menu, Open Last Export), `App/RecoveryFlow.swift` (launch: "Finish recording" / "Discard"), `Capture/RecoveryScanner.swift` (`.inProgress` manifests and `.needsFinalize` markers; finalize, `recoverLog`, `.recovered`). | The M1 gate end to end; `kill -9` mid-take → next launch offers it → it renders; G | M1-11, M1-12 | no |
| M1-14 | **Docs + CI grep.** `docs/DECISIONS.md` entries: the re-cut (click effects to M2; multi-take, Studio Sound, CLI into M3 pending team confirmation; ARCHITECTURE §10 and the reconcile checklist already carry the lead's numbering), Core mirrors of Engine settings and `RenderStyle`, S2 split into reader and player halves, first-party-only audio (no RNNoise or Silero), the compositor's sRGB/709-only rule. Add to `.github/workflows/ci.yml` a step that fails on `grep -rnE '^import (AppKit|SwiftUI)' Sources/CutsceneCore Sources/CutsceneEngine`, then flip ARCHITECTURE §8 ("to add, M1-14") and the checklist's "Portable engine boundary" line to say the grep exists. S1/S3 results reach platform-notes via M1-07/M1-09. | Entries follow the file's format; CI runs the grep | M1-09 | yes |

Critical path: M1-00 → M1-06, M1-07 → M1-08 → M1-09 ∥ (M1-01 → M1-03 → M1-05; M1-04 → M1-10 → M1-11) → M1-12 → M1-13.

---

## Milestone 2: camera, window and area, click effects, presets, minimal editor

**Gate.** Record a window or an area with the camera bubble; click ripples;
export 16:9, 9:16 and 1:1; in the editor, trim, move, lock and add zoom
segments with the preview following, then export from it.

| id | Task · module · files · builds on | Acceptance (from the shell) | Deps | ∥ |
| --- | --- | --- | --- | --- |
| M2-00 | **Registry.** `Spike/main.swift` (`player`, `camera`, `window`), stubs `Spike/{PlayerSpike,CameraSpike,WindowSpike}.swift`; `Check/main.swift` calls `runLayoutChecks`, `runContentMapperChecks` in new `Check/{LayoutChecks,ContentMapperChecks}.swift`. | G; counts unchanged | — | no |
| M2-01 | **Engine: ripples, layout, zoom track.** Create `Engine/ClickEffects.swift` (§3 `cursor.click` ripples, ≤ 4 concurrent), `Engine/LayoutSolver.swift` (card per canvas aspect; bubble bottom-trailing on 16:9, above/below the card on 9:16 and 1:1), `Engine/ZoomTrackMerge.swift` (`ZoomTrackSegment` ↔ `ZoomSegment`; replan replaces only unlocked `.auto`); edit `Engine/RenderPlan.swift` (`frameState(at:canvas:)`; `FrameState.ripples`, `.layout`, `.camera` and `.contentCrop`, the crop read from a `ContentCropTimeline` input of `build` that is identity by default, so M2-02's mapper plugs in without touching this file; build from a `ZoomTrack`). Fill `Check/LayoutChecks.swift`, extend `Check/RenderPlanChecks.swift`. | G; a ripple's curve pinned at 5 times; the bubble never overlaps the card on 9:16 and 1:1; a locked and a `.manual` segment survive a replan; determinism holds | M2-00 | yes |
| M2-02 | **Engine: `ContentMapper`.** Create `Engine/ContentMapper.swift` (display and area: identity; window: per-frame `BoundingRect` crop from `frames.jsonl` smoothed with the camera spring, producing the `ContentCropTimeline` M2-01 defines; edits no RenderPlan file). Fill `Check/ContentMapperChecks.swift`. | G; a synthetic index with a 0.2 window jump yields a C1-continuous crop inside the frame | M2-00, M2-01 | yes |
| M2-03 | **Render: ripples, bubble, crop.** Edit `Render/ShaderSource.swift`, `Render/Compositor.swift` (uniforms: ≤ 4 ripples, bubble rect/shape/mirror, camera texture slot, content crop; minification is already box-filtered by the tap grid), `Render/RenderStyle.swift` (`camera` bubble), `Render/MetalCompositor.swift` (camera source frame), `Render/CompositionBuilder.swift` (camera track, mix levels), `Render/KitStyle.swift`, `Spike/RenderSpike.swift` (ripple and camera frames). | `make spike ARGS="render"`: a ripple on the pressed frame, a bubble from the synthetic camera, median still < 8 ms; `reader` on an M1 package unchanged | M2-01 | yes |
| M2-04 | **Spike S2 (player half) + `PreviewView`.** Fill `Spike/PlayerSpike.swift` (an `AVPlayerLayer` window from the CLI: `startRequest` on zero-tolerance seeks; paused re-render on `videoComposition` reassignment, else forced seek, timed; player + reader concurrently); create `App/PreviewView.swift` (`AVPlayerLayer`, `seekingWaitsForVideoCompositionRendering`, coalesced seeks, `preview.maxPixels`). Results into `docs/platform-notes.md`. | `make spike ARGS="player <package>"` prints seek and paused re-render times (< 50 ms, else the `AVPlayerItemVideoOutput` escalation becomes a task); instances do not serialize | M1-10 | yes |
| M2-05 | **Capture: `CameraRecorder`.** Create `Capture/CameraRecorder.swift` (§2: `actor`, discovery incl. Continuity, ≤ 1080p30 420v, late frames discarded, a second `VideoEncoder` + `RecordingWriter` on the same clock via `CMSyncConvertTime`, pre-origin frames dropped on the callback thread); edit `Capture/CaptureSession.swift` (start/stop camera, `camera.mp4`, `CameraTrackInfo`), `Capture/CaptureRequest.swift` (`camera`). Fill `Spike/CameraSpike.swift`. | `make spike ARGS="camera 5"`: `camera.mp4` 30 fps, first sample ≤ 1 frame after the origin, media time 0 = origin; exit 3 without the camera grant | M1-09 | yes |
| M2-06 | **Capture: window and area modes + spike S4.** Edit `Capture/StreamConfigurationBuilder.swift` (the three §2 window strategies; area `sourceRect` to even pixels), `Capture/ScreenFrameIndexer.swift` (§2 geometry attachments when changed), `Capture/ClickMonitors.swift` (scroll, `focus`), create `Capture/WindowGeometryPoller.swift` (4 Hz, 10 Hz in window mode). Fill `Spike/WindowSpike.swift`: a named window 10 s per strategy while the lead opens a menu, a popover and drags it; size, frames, geometry changes; PNGs through the reader path. Findings into `docs/platform-notes.md`. | `make spike ARGS="window <title>"` runs all three; `.displaySurface` PNGs show the menu and popover; the cursor stays on the pointer through the drag; the default strategy goes into DECISIONS.md | M1-09, M2-02 | yes |
| M2-07 | **Capture: robustness.** Create `Capture/DiskSpaceMonitor.swift` (2 s poll, warn < 10 min, auto-stop < 300 MB); edit `Capture/CaptureSession.swift` (display gone / `systemStoppedStream` → end marker, `.complete(stopReason:)`; mic disconnect → silence fill + status; `streamDidBecomeInactive` behind `#available(15.2)`; `gap` lines and dropped counters in `CaptureStatus`; Pause if M1-09 `--pause` passed). | G; `session 10 --fill-disk` (small `hdiutil` volume) stops cleanly: `stopReason: diskFull`, playable movie | M2-05 | no |
| M2-08 | **Export: presets and levels.** Edit `Export/{ExportPreset,ExportWriterSettings,Exporter}.swift`: `vertical1080`, `square1080`, 30/60 fps, mic 0 dB / system −6 dB via the audio mix, HEVC toggle. | `make spike ARGS="export <package> vertical"` → 1080×1920 fully filled, `square` → 1080×1080; bit rates within 20 % of the §6 table | M2-03 | yes |
| M2-09 | **App: sources, camera, HUD.** Create `App/SourceMenus.swift` (Record Window ▸ titles by app, Record Area, Camera ▸ devices/off), `App/AreaSelectionOverlay.swift` (`.screenSaver` panel per display, handles, even-pixel snap, AppKit → Quartz), `App/CountdownOverlay.swift` (3 s tunable), `App/RecordingPill.swift` (`HUDPanel`: elapsed, dropped, free disk, Marker, Stop); edit `App/RecorderController.swift` (`countdown`), `App/MenuBarMenu.swift` (sources, Open Last Recording → editor window). Camera permission on first toggle only. | `make run`: a window recording exports that window; overlay, countdown and pill absent from the capture; marker events in `events.json` | M2-05, M2-06, M2-07 | yes |
| M2-10 | **App: minimal editor.** Create `App/EditorWindow.swift` (`WindowGroup("Editor", id:, for: URL.self)`, activation-policy flip), `App/EditorModel.swift` (`Project` value, `UndoManager` snapshots, plan rebuild off-main, latest wins, 50 ms debounce, save only after an edit, `.previous`), `App/TransportBar.swift`, `App/Scrubber.swift` (trim handles → `.trim` cuts; zoom segments drawn; drag edges, lock, delete, add `.manual` at the playhead, amount), `App/ZoomInspector.swift`, `App/StyleInspector.swift`, `App/ExportSheet.swift` (preset, codec, fps, progress, cancel, Reveal). | An M1 package opened and closed unedited stays byte-identical; trim changes the exported duration; a moved, locked segment survives a replan; undo/redo; Dock icon only while the editor is open; the sheet's export matches the `export` spike | M2-01, M2-03, M2-04, M2-08 | yes |
| M2-11 | **Docs.** DECISIONS (window strategy, paused re-render path, Pause button); platform-notes from S2 and S4. | format | M2-04, M2-06 | yes |

---

## Milestone 3: multi-take, Studio Sound and loudness, brand kits, headless CLI

| id | Task · module · files · builds on | Acceptance (from the shell) | Deps | ∥ |
| --- | --- | --- | --- | --- |
| M3-00 | **Registry.** `Package.swift` (`CutsceneTool`: Core + Engine only; `CutsceneCLI`: all libraries; `Tests/Fixtures` as resources), `Spike/main.swift` (`audio`, `bench`), stubs `Spike/{AudioSpike,BenchSpike}.swift`, `Check/main.swift` + `Check/{TakeChecks,KitMergeChecks,LoudnessChecks}.swift`. | G | — | no |
| M3-01 | **Core + Engine: takes (research §5.17).** Edit `Core/Timeline.swift` (`Take`, `takes`, `takeDecisions`); create `Engine/TakeSegmenter.swift` (`takeMarker` events incl. the `retake` label → takes; "last complete take wins"; boundary trim from an RMS envelope (Silero is third-party) with `silenceThresholdDB`, `minimumSilence`, `boundaryPad`; cuts `.retake(id)`; zoom replanned on the kept timeline). Fill `Check/TakeChecks.swift`. | G; a fixture with 5 takes of one line yields 4 candidates, the last complete take kept, cuts at the envelope minima | M3-00 | yes |
| M3-02 | **App: markers at record time.** Edit `App/RecordingPill.swift` (Mark take, "Retake from here" writing `takeMarker(label: "retake")`, take count), `App/RecorderController.swift`; the recorder's marker entry exists (F5). No global hotkey in v1. | `events.json` holds the labelled markers; `telemetry` spike unchanged | M2-09 | yes |
| M3-03 | **App: retake review.** Create `App/TakeReviewView.swift` (candidates with next/prev, A/B preview kept vs removed, accept/reject, persisted in `project.json`); edit `App/EditorModel.swift`. | A 5-take recording exports only the kept takes; decisions survive relaunch | M3-01, M2-10 | yes |
| M3-04 | **Audio: Studio Sound + loudness (first-party only).** Create `Export/AudioEnhancer.swift` (offline `AVAudioEngine` manual rendering on the mic track: `AVAudioUnitEQ` high-pass, `DynamicsProcessor` expander + compressor, `PeakLimiter`; `strength` wet/dry; `derived/mic-enhanced.caf`, bypass), `Export/Loudness.swift` (BS.1770-4 integrated LUFS and 4× oversampled true peak; presets −16/−1, −14, −23), `App/AudioInspector.swift`; edit `App/EditorWindow.swift`, `Render/CompositionBuilder.swift` (enhanced track swap), `Capture/RecordingWriter.swift` + `Spike/WriterSpike.swift` (mic track LPCM per the ADR). Fill `Spike/AudioSpike.swift`, `Check/LoudnessChecks.swift`. | `make check`: a −23 LUFS sine fixture measures −23 ± 0.1 LU; `make spike ARGS="audio <package>"` prints before/after: within ± 0.5 LU of target, TP ≤ −1 dBTP, silent-span RMS down ≥ 10 dB; `writer` spike PASS with LPCM | M3-00 | yes |
| M3-05 | **Core + App: brand kits.** Create `Core/KitLibrary.swift` (the §3 kit folders, `<name>.cutscenekit.json`, `kitReference`), `Core/KitMerge.swift` (`update(style:from:to:)` three-way, `overriddenFields`), `App/KitsSettings.swift` (folder picker, list, Save as kit…); edit `App/StyleInspector.swift` (kit header, Update from kit, modified badges); fixtures `Tests/Fixtures/kits/{default,future}.cutscenekit.json`. Fill `Check/KitMergeChecks.swift`. | G; merge keeps touched fields and takes untouched ones; a kit with unknown fields survives re-save; sorted-key JSON is byte-stable; two projects share one kit file | M3-00 | yes |
| M3-06 | **`cutscene-tool`.** Create `Sources/CutsceneTool/{main,Commands}.swift`: `events dump`, `plan dump`, `plan bench`, `fixtures regen`. | `swift run cutscene-tool plan bench <fixture>` prints the 30-minute plan time; `events dump <package>` lists kinds and counts | M3-00 | yes |
| M3-07 | **`cutscene` CLI.** Create `Sources/CutsceneCLI/{main,RecordCommand,ExportCommand}.swift`: `record --display N --mic <id> --seconds S --out X.cutscene` (preflight, exit 3, `SIGINT` stops cleanly), `export X.cutscene --preset 4k --kit team.cutscenekit.json --out Y.mp4`. | `export` of an M1 package matches the app's export in ffprobe frame count, duration and size ± 5 %; `record` writes a complete package | M3-00, M3-05 | yes |
| M3-08 | **Export: spike S5 benchmark.** Create `Export/Benchmark.swift`; fill `Spike/BenchSpike.swift`: a 2-minute package through all four presets, alone and with a concurrent reader instance. Levers in order: native 4:2:0 sampling (the compositor already reads 420v/420f planes), asynchronous `finish` (a `Compositor.render(_:style:completion:)` on `addCompletedHandler` so one frame stays in flight), `preview.pauseDuringExport`. Numbers into `docs/platform-notes.md`. | 1080p60 ≥ 2× and 4K60 ≥ 1× real time on the M4 Pro, sizes within 20 % of the table; else the next lever becomes a task | M2-08 | yes |
| M3-09 | **App: settings + soak.** Create `App/SettingsView.swift` (output folder, default preset, devices, countdown, system audio, window strategy, Permissions incl. the Input Monitoring opt-in, requested from here only); soak via `make spike ARGS="session --long 1800"` on a clapperboard page: drift slope < 10 ms/min, RSS flat, zero drops on the internal display, video = audio length. | Values persist and drive the menu defaults; soak numbers in platform-notes | M2-09 | yes |
| M3-10 | **Docs.** README usage and status; DECISIONS (takes, audio chain, CLI); platform-notes S5. | format | M3-08 | yes |

---

## Post-M1 follow-ups (lead's list, 2026-11-03)

Raised by the docs verifier and the compositor review after the M1 agents had
already received their task text; check each against the M1 result before
starting M2 and fold any that is still open into a short follow-up task.

| id | What | Why |
| --- | --- | --- |
| M1-F1 | `CaptureSession` (M1-08) writes `InputTelemetryRecorder.sprites()` to `recording/cursors/<CursorShape.id>.png` at stop, and `CursorAtlas` (M1-10) is verified to pick them up on the synthetic package | otherwise every cursor renders as the arrow |
| M1-F2 | `.github/workflows/ci.yml`: a grep step failing on `import AppKit` or `import SwiftUI` under `Sources/CutsceneCore` and `Sources/CutsceneEngine` | ARCHITECTURE §8 promises it |
| M1-F3 | `DECISIONS.md` entries: the M3 pull-forward (multi-take, Studio Sound, CLI) pending team confirmation; the compositor's sRGB/709-only colour rule | the ADR log must match the docs |
| M1-F4 | Warm the compositor (one throwaway render) before the first `AVVideoCompositing` request in `MetalCompositor` | the first frame costs 8–26 ms (sprite upload, mip generation, pipeline) |
| M1-F5 | `SourceFrame.sourcePixelsPerPoint` in the glue (M1-10) comes from the frame width and `contentRect`, not `EventLog.pointPixelScale` | the cursor-size formula needs source pixels per captured point |
| M1-F6 | Two crashes on 2026-11-03 (15:12, 15:15, agent `make run` tests before the fixer): `NSInternalInconsistencyException` from `-[NSWindow _postWindowNeedsUpdateConstraints]` ("more Update Constraints passes than views in the window") reached through `NSHostingController.preferredContentSize` → `ViewGraph.setSize` → `NSHostingView.setNeedsUpdate` on the main thread. Find the hosted window whose size depends on its content (onboarding window, recovery window or a `.window`-style `MenuBarExtra`), give it a fixed content size and `NSHostingView.sizingOptions = []` (or host it as `NSHostingView` rather than a content view controller), and reproduce by opening every window from a cold launch | an uncaught AppKit exception kills the app; reports in `~/Library/Logs/DiagnosticReports/Cutscene-2026-11-03-15*.ips` |

## Spikes and permission tests (ARCHITECTURE §9)

Permission states without prompting: M1-06 (relaunch verified in M1-12). S3
clicks: M1-07. S1 live writer: M1-09 (also decides Pause, M2-07). S2: reader
half M1-10, player half M2-04. Camera preflight: M2-05. S4 window geometry:
M2-06. S5 throughput and the soak: M3-08, M3-09. The picker-bypass alert
interval is observed during M1 dogfooding; the system picker stays v2.

## Later (not scheduled; plug points exist)

Hand-built editor decoder when S2 trips a threshold; `AVPlayerItemVideoOutput`
preview escalation; transcript-similarity retake detection; captions and
transcript cuts; secret redaction; shell integration, command callouts,
auto-chapters; keystroke overlay and clean typing; code and terminal callouts;
`ZoomLevel.auto`, zoom below 100 %, Loupe; camera re-solve per aspect; motion
blur (`viewportVelocity` is carried); native-refresh cadence gate; ProRes
`pristine`, HEVC-with-alpha, GIF; system picker if the bypass alert is frequent
and the floor moves to 15.2; application capture mode; global hotkey (no header
in the CLT SDK); live voice processing (the mic would leave the SCK clock);
precompiled `metallib`; macOS 26 pixel-buffer APIs; MCP server; Developer ID,
notarization, Sparkle, Homebrew; `swift test` with fixtures once Xcode is standard.

## Milestones after M2 (lead's stages, 2026-11-05)

- **S1, recording workflow (done 2026-11-05):** working Settings (folders,
  default preset, microphone, camera, system audio, countdown; persisted and
  read at take start), Pause/Resume on the launcher, pill and menu through
  `CaptureSession.pause/resume` (one clock), markers mapped through
  `recordingTime(forHostSeconds:)`, Show Recorder (⇧⌘R), Open Recording
  (recent list and chooser), accessibility identifiers on the main controls.
- **S2, AI script workflow:** `AssistantProvider` boundary, OpenAI Responses
  API (streaming, cancel), OpenAI-compatible endpoint behind explicit
  capability flags, Keychain for secrets, an Assistant panel that generates
  and rewrites a script and replaces the teleprompter text only on accept;
  mocked success/cancel/failure checks; real API check only with credentials.
- **S3, editing and a bounded assistant:** interior cuts on `Timeline.cuts`
  and `keptRanges()`, a typed `EditingAction` layer over `EditorModel.edit`
  with validation and a project revision check, an assistant that proposes a
  preview-able single-undo edit; stale or invalid proposals change nothing.
- **Later:** timed transcription with word-level alignment (verify timestamp
  support before choosing a model), searchable transcripts, word deletion,
  styled captions and subtitle export; separate mic/system levels and loudness
  cleanup; brand kits; embedded Codex through the app-server protocol and an
  external MCP bridge, both over the S3 actions, as their own milestone.

