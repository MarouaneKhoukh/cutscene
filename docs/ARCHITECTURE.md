# Cutscene architecture (v1)

The authoritative design, reconciled on 2026-11-02 from the design panel's
winning "platform does the work" plan
([design/architecture-panel.md](design/architecture-panel.md)), the research
brief ([research/brief.md](research/brief.md) §0, §4.5, §5, §7) and the code
verified by spikes (surveyed at 18:30; the tree is under active edit, so type
names are authoritative, signatures are not). Rules, in order: verified facts
(SDK headers, `ffprobe`, [platform-notes.md](platform-notes.md)) beat opinions;
implemented code beats an equivalent proposal; panel-versus-research conflicts
are decided here with rationale and rejected alternative and recorded in
[DECISIONS.md](DECISIONS.md); platform-first choices stand for v1 and the
research's hand-built decoder is v2 with a trigger.

Legend: **exists** = in `Sources/`, exercised by a spike or `make check`;
**to build** = designed, not written; **v2** = deferred with a trigger. Every
numeric default is a **tunable** named with its value, held in a settings
struct, the brand kit or `CaptureRequest`, never as a literal. macOS versions
are from the SDK headers; the floor is 15.0. Tasks: [PLAN.md](PLAN.md).

---

## 1. App structure

**Process model.** One SwiftPM executable, bundled and signed by
`scripts/bundle.sh` (**exists**; `Cutscene Dev` identity from `make dev-cert`).
The app becomes a menu-bar agent (`LSUIElement = true`) that flips to
`NSApp.setActivationPolicy(.regular)` while an editor window is open
(**to build**; today `CutsceneApp.swift` is a development window that runs
`RecordingSpike`). *Why:* record without a window in the way. *Rejected:* an
XPC recorder helper (no UI dependency in capture; crash safety comes from the
on-disk formats) and a Dock-only app.

**Scenes** (**to build**): `MenuBarExtra` (M1-12: Record Display ▸ displays,
Microphone ▸ devices/off, System Audio, Stop, Open Last Export, Reveal Last
Recording, Settings…, Quit; M2-09 adds Record Window ▸, Record Area, Camera ▸
and Open Last Recording → editor; M1 exports on stop, so there is no "Export
Last Recording" item),
`WindowGroup("Editor", id: "editor", for: URL.self)` opened with
`openWindow(value:)`, `Settings`. *Rejected:* a `Window` scene (takes no value)
and `DocumentGroup` (loads packages into memory). **HUD** (**to build**):
`HUDPanel: NSPanel` (`.nonactivatingPanel`, `.borderless`, `level = .statusBar`,
`.canJoinAllSpaces`, `.fullScreenAuxiliary`) with idle controls, then a pill
(elapsed time, dropped frames, free disk, Marker, Stop); countdown and area
overlays are panels per `NSScreen` at `.screenSaver` level. Display and area
modes exclude our application from the capture
(`SCContentFilter(display:excludingApplications:exceptingWindows:)`, which also
covers later windows). *Rejected:* `NSWindow.sharingType = .none` (header
caution about system services) and window-ID exclusion. **Editor window**
(**to build**): `AVPlayerLayer` preview, transport bar with trim handles,
inspector (Style, Cursor, Zoom, Camera, Audio, Export). **No global hotkey in
v1**: `RegisterEventHotKey` has no header in the Command Line Tools SDK and key
monitors need Accessibility.

| Owner | Kind | Holds | Status |
| --- | --- | --- | --- |
| `AppModel` | `@MainActor @Observable` | permissions, recent packages, `RecorderController`, settings | to build |
| `RecorderController` | `@MainActor @Observable` | `idle → selecting → recording → finishing → rendering → done(url) / failed(error, partialURL)` (M1-12); `countdown` between `selecting` and `recording` arrives with M2-09; one `CaptureSession` per take | to build |
| `EditorModel` | `@MainActor @Observable` | the `Project` value, `UndoManager` snapshots, `AVPlayer`, current `RenderPlan`, debounced save only after an edit | to build |
| `CaptureSession` | `actor` on a `DispatchSerialQueue` executor (14.0) | `SCStream`, the clock, encoder, writer, telemetry, `ScreenFrameIndexer`, `CameraRecorder`, `DiskSpaceMonitor`; `AsyncStream<CaptureStatus>` | to build around existing parts |
| `RecordingClock` | `final class`, `Mutex` (15.0) | the one timeline: host origin, pause intervals, stop | exists |
| `VideoEncoder`, `RecordingWriter`, `InputTelemetryRecorder`, `CursorShapeSampler` | `final class, @unchecked Sendable`, lock-guarded | callable from SCK's sample queue, VideoToolbox's callback thread and the tap thread without hops | exist |
| `Compositor` | `final class, @unchecked Sendable`, `Mutex`-guarded caches | device, queue, runtime-compiled library, samplers, pipelines, sprite textures, output pool, texture cache; `render(_:style:)`, `render(_:style:into:)`, `render(_:style:to:)`; §5 | exists |
| `Exporter`; `MetalCompositor` | `actor`; `NSObject, AVVideoCompositing` holding one `Compositor` per instance | §6; §5 | to build |

**Swift 6 strict concurrency.** Values cross boundaries, objects do not:
`CMSampleBuffer` and `CVPixelBuffer` (`@_nonSendable`), `MTLTexture` and
`AVPlayer` never leave their owner. The capture actor's executor is the
`DispatchSerialQueue` also passed to `SCStream.addStreamOutput(_:type:
sampleHandlerQueue:)`; a `StreamOutputShim: NSObject, SCStreamOutput` forwards
each sample with `session.assumeIsolated` (zero hops); the writer and encoder
are lock-guarded classes, not actors, so a sample buffer never crosses an
isolation boundary. Edits rebuild an immutable `RenderPlan` through a
`nonisolated` Engine function returning
`sending RenderPlan`, latest wins, **50 ms** debounce (`editor.planDebounce`);
the 30-minute plan measures ≈ 390 ms in the default debug `make check`, whose
budget there is **1500 ms** (3× the **500 ms** release budget, which
`make check CONFIG=release` pins; measured ≈ 30 ms there, 2026-11-03).

---

## 2. Capture pipeline

**Principle.** ScreenCaptureKit delivers IOSurface-backed frames plus system
audio and microphone on one stream; our code stamps everything through one
`RecordingClock`, writes metadata to append-only files and feeds frames to the
hardware encoder.

**Stream configuration** (`StreamConfigurationBuilder`, **to build**):
`pixelFormat = '420v'` (`capture.pixelFormat`), `colorSpaceName = sRGB`,
`colorMatrix = 709`, `showsCursor = false`, `showMouseClicks = false` (15.0),
`captureResolution = .best` (14.0), `captureDynamicRange = .SDR` (15.0),
`queueDepth = 8` (header maximum), `minimumFrameInterval = 1/60`
(`capture.frameRate` 30/60; `kCMTimeZero` native refresh is v2),
`presenterOverlayPrivacyAlertSetting = .never` (14.0), `capturesAudio` (13.0),
`excludesCurrentProcessAudio = true`, 48 kHz stereo, `captureMicrophone` and
`microphoneCaptureDeviceID` (15.0).

| Mode | Filter | Output | Notes |
| --- | --- | --- | --- |
| Display | `SCContentFilter(display:excludingApplications: [us], exceptingWindows: [])` | display points × `pointPixelScale` | `includeMenuBar` (14.2) default true |
| Window `.displaySurface` (default) | `SCContentFilter(display:including: [window])` | display size (SCStream.h:21), black outside the window (or clear: `backgroundColor` "is clear" by default, SCStream.h:262; the compositor composites transparent texels over the background either way) | `includeChildWindows` (14.2, default YES) covers menus and popovers (**unverified**, S4); `ignoreShadowsDisplay = true`; per-frame `BoundingRect` (14.0) lets the engine crop the card and follow moves |
| Window `.pinnedFrame` | same + `sourceRect` = frame at start | frame × scale, even | smaller files; a moving window leaves the frame |
| Window `.independentWindow` | `SCContentFilter(desktopIndependentWindow:)` | frame × scale, even; `scalesToFit = false`, `preservesAspectRatio = true` (14.0) | this window only, even occluded; **no menus or popovers** |
| Area | display filter + `sourceRect` (display-local points) | rect × scale, rounded down to even | overlay snaps to even pixels |
| Application (v1.1) | `SCContentFilter(display:including: [app], exceptingWindows: [])` | display size | every window of one app |

*Why `.displaySurface`:* the only window path where child windows apply, and a
black surface costs almost nothing to encode. *Rejected:*
`desktopIndependentWindow` as default (the explicit "window only" option) and
the system picker (`SCContentSharingPicker`, 14.0: no region mode; reading its
filter back needs `includedWindows`, 15.2).

**Outputs and frame index.** `.screen` always, `.audio` (13.0) and
`.microphone` (15.0) when enabled. `ScreenFrameIndexer` (**to build**) appends
to `frames.jsonl` per screen sample: frame number, PTS,
`SCStreamFrameInfoDisplayTime` (12.3, via `CMClockMakeHostTimeFromSystemUnits`),
`Status`, and `ContentRect`/`ContentScale`/`ScaleFactor` (12.3), `ScreenRect`
(13.1), `BoundingRect` (14.0) when they change. Idle frames are counted, not
encoded: the intermediate is VFR by design. *Why:* display time is one to two
frames before delivery, and clicks must align with what was on screen.
*Rejected:* a binary index (not diffable; JSONL is ~4 MB per 10 minutes).

**Video path** (**exists**; DECISIONS "the recording path drives the encoder").
`VideoEncoder` (`VTCompressionSession`) compresses SCK frames and
`RecordingWriter` appends them to a passthrough `AVAssetWriterInput(mediaType:
.video, outputSettings: nil, sourceFormatHint:)` in a fragmented QuickTime
movie, finalized at stop to a faststart MP4 through
`AVAssetExportSession(presetName: AVAssetExportPresetPassthrough)`. Verified by
`make spike ARGS="writer"` with `ffprobe`: `hvc1`, `has_b_frames=0`, keyframe
gap ≤ 1.003 s, two AAC tracks, `ftyp → moov → mdat`. *Why:* `SCRecordingOutput`
(15.0) gave B-frames, two keyframes in 5.4 s and one mixed AAC track with no
control (measured); a direct session honours every property for HEVC.
*Rejected:* `SCRecordingOutput` as the editor's source (kept only in
`RecordingSpike`) and the panel's "AVAssetWriter compresses with VideoToolbox
keys" default with an S1 A/B: unverified for HEVC, and the implemented path
already passes those checks.

`VideoEncoderConfiguration` (tunables): hardware required
(`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`), HEVC
Main (`kVTProfileLevel_HEVC_Main_AutoLevel`) with hardware H.264 High fallback;
`RealTime = true` (header default NULL); `AllowFrameReordering = false` (no
`ctts`); `MaxKeyFrameInterval = fps × 1 s` (**0.5 s** at ≥ 3840×2160) **and**
`MaxKeyFrameIntervalDuration = 2 s`; `AverageBitRate = w × h × min(fps, 60) /
30 × 5 bit × 0.7 (HEVC) × quality` (`VideoQuality.balanced` 1, `.high` 2, the
implemented `VideoEncoderConfiguration.quality`, which `CaptureRequest.quality`
maps onto; 14.5 Mb/s at 1080p60 HEVC); `ExpectedFrameRate = fps`; colour tags
709/709/709 (`capture.colorTags = .bt709 | .source`, S1); forced keyframe after
a resume. A `pristine` ProRes quality is **v2** (trigger: a text legibility
test that `high` fails).

`RecordingWriterConfiguration` (tunables): `movieFragmentInterval` **2 s** on
internal storage, **10 s** on external or unknown volumes (header advice); one
AAC track per `RecordingAudioSource` (`system` stereo, `microphone` from the
device), **48 kHz**, **160 kbps**; `audioPrerollLimit` **64** buffers before
the first keyframe; `audioGapTolerance` **512** samples, holes filled with
silence, overlaps trimmed; `startSession(atSourceTime: .zero)` with zero = the
clock origin, so a late first frame opens the track with an empty edit
(header-verified) and media time equals event time; a zero-sample end marker
(`kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration`, 10.7) gives the last
frame its duration; `NeedsFinalizeMarker` (`<movie>.needsFinalize`) lives until
the MP4 is complete and `finalize(fragmentedMovie:into:)` is the recovery path.
*Decision (AAC, not LPCM):* keep AAC in v1; LPCM when Studio Sound lands (v2).
*Why:* verified, transparent for speech, gap logic codec-independent.
*Rejected:* the panel's LPCM tracks now (unverified change on the critical
path).

**Idle heartbeat** (**to build**, `capture.heartbeat = 1.0 s`): a static screen
yields no `.complete` frames, so the 2 s keyframe cap never fires;
`CaptureSession` re-encodes the last complete frame retimed to now and writes
`{"k":"hold"}`. **Unverified** that SCK leaves a retained surface untouched; S1
checks a checksum and falls back to a copy. *Rejected:* the research's "repeat
after 3 missed intervals" (inflates static takes).

**Clock and sync** (`RecordingClock`, **exists**): `origin` = host clock
(`CMClockGetHostTimeClock`) at Record; `pause()`, `resume()`, `stop()`;
`recordingTime(forHostTime:)` maps a capture stamp to the timeline or nil
(before the origin, inside a pause, after stop). Every stamp is the sample's
own capture time, never arrival; the tap uses `CGEventTimestamp` (same base).
SCK PTS are assumed host-clock; if S1 shows `SCStream.synchronizationClock`
(13.0, nullable) differs, `CMSyncConvertTime(_:from:to:)` is applied first.
*Decision (pause):* clock, encoder and writer keep pause support (the writer
spike pauses mid-take and checks a sample-exact audio join); the UI exposes
Pause only after S1 repeats that case live. *Why:* the research names pause
timing the largest writer bug class; the live proof is one spike away.
*Rejected:* removing pause (panel) or shipping the button untested (research).

**Dropped frames and pacing.** `isReadyForMoreMediaData == false` drops and
counts (`videoDroppedNotReady`, **exists**), adds `{"k":"gap"}` and a pill
counter (**to build**). `ProcessInfo.processInfo.beginActivity(options:
[.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason:
"Recording")` is held for the take. Disk (`disk.*`): preflight
`volumeAvailableCapacityForImportantUsageKey` (10.13) ≥ **2 GB**, warn under
**10 min** remaining, auto-stop below **300 MB**.

**Camera** (**to build**): `CameraRecorder` actor on its own queue;
`AVCaptureSession` with `AVCaptureDevice.DiscoverySession(deviceTypes:
[.builtInWideAngleCamera, .external, .continuityCamera])` (14.0; needs
`NSCameraUseContinuityCameraDeviceType`), the largest format ≤ **1920×1080**
at **30 fps** (`camera.maxSize`, `camera.fps`), `AVCaptureVideoDataOutput`
'420v' with `alwaysDiscardsLateVideoFrames = true`, feeding a second
`VideoEncoder` + `RecordingWriter` pair on the same clock; PTS converted with
`CMSyncConvertTime` from `AVCaptureSession.synchronizationClock`. Frames before
the origin are dropped on the callback thread, never retained (retained
buffers starve the pool). *Rejected:* `AVCaptureMovieFileOutput` (no exact
first-sample time, no fragments).

**Cursor, clicks, keystrokes** (`InputTelemetryRecorder`, **exists**):

| Signal | Source | Permission |
| --- | --- | --- |
| Pointer | `NSEvent.mouseLocation` + `pressedMouseButtons` from an 8 ms strict `DispatchSourceTimer` (measured **125 Hz**); written when moved ≥ **1/4096** (`movementThreshold`) | none |
| Clicks | listen-only `CGEventTap` when Input Monitoring is already granted (exact stamps, re-enabled on `tapDisabledByTimeout`); else **to build** `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` (header: Accessibility only for key events; global monitors skip our own app; S3 calibrates `NSEvent.timestamp`); else button edges from the poll | none for the last two |
| Cursor shape | `CursorShapeSampler`: FNV-1a hash of the smallest `NSCursor.currentSystem` bitmap every other tick, PNG sprite of the largest | none; `API_TO_BE_DEPRECATED`, so the renderer falls back to the arrow |
| Keystrokes | the same tap: `keyDown`/`keyUp`/`flagsChanged`, repeat flag, modifiers | Input Monitoring, opt-in; never prompted by the recorder |
| Scroll, focus, geometry | **to build** (format 2): `.scrollWheel` monitors; `NSWorkspace.didActivateApplicationNotification`; `CGWindowListCopyWindowInfo` at **4 Hz** (**10 Hz** in window mode) | none |
| Markers | `takeMarker` event (exists); pill button (to build) | none |

Positions are normalized to the capture rect. The log is flushed to a JSONL
sidecar every **5 s** (`persistenceInterval`); `recoverLog(persistenceURL:)`
rebuilds it after a crash. *Decision:* keep the recorder, add the
permission-free `NSEvent` monitors. *Rejected:* the panel's `CGEvent(source:)`
poll (equivalent) and dropping cursor shapes.

**Failure handling.** Display gone or window closed:
`stream(_:didStopWithError:)` (`systemStoppedStream` −3821, 15.0) and
`streamDidBecomeInactive` (15.2, gated) → end marker, finish writers, manifest
`.complete(stopReason:)`, open the editor on what exists. Microphone failure
(`failedToStartMicrophoneCapture` −3820, 15.0; `wasDisconnectedNotification`) →
offer to continue; mid-take the track is silence-filled (exists). Disk full →
warning, then auto-stop. Crash → the `.inProgress` manifest (M1-01), the
`.needsFinalize` marker and the sidecar (both exist) let `RecoveryScanner`
(M1-13) finalize the movie and recover the log. Writer failure → the finish path; the last
fragment survives.

---

## 3. Project and recording format

**Package** (`.cutscene`, UTI `app.cutscene.project` conforming to
`com.apple.package`, at `~/Movies/Cutscene/<yyyy-MM-dd HH.mm.ss> <source>.cutscene`;
**to build** around the files that exist):

```
Demo.cutscene/
  project.json             Project: timeline, kit snapshot, style, export settings
  project.json.previous    the project as opened in the current editing session
  recording/
    manifest.json          RecordingManifest, written at start and rewritten at stop
    screen.mp4             faststart MP4 (HEVC + 2 AAC); screen.mov + .needsFinalize during the take
    camera.mp4             optional, same shape
    events.json            EventLog (exists); events.events.jsonl sidecar during the take
    frames.jsonl           per-frame index (to build)
    cursors/<CursorShape.id>.png  captured sprites, written at stop (M1-08); the id is the
                           FNV-1a content hash or a name such as `arrow`; transcript.json reserved
  derived/                 regenerable caches (M3-04's mic-enhanced.caf); a poster has no v1 task
```

Exports go to `~/Movies/Cutscene/Exports/`. *Why:* human-readable,
git-diffable, crash-tolerant. *Rejected:* one container file and separate CAF
audio files.

**Time.** `Double` seconds on the recording timeline (**exists**); `CMTime` at
module boundaries. *Rejected:* the panel's `MediaTime { ns: Int64 }` (no
measured benefit).

**Event log** (`EventLog`, **exists**, format **1**): one JSON document with
`formatVersion`, `recordingID`, `startHostTimeSeconds` (the clock origin),
`captureRectPoints`, `displayID`, `pointPixelScale`, `samplingRateHz` and
`events` in time order. Each `InputEvent` is a flat row with a `type`:
`pointerMoved`, `buttonDown`, `buttonUp`, `keyDown`, `keyUp`,
`cursorShapeChanged`, `takeMarker`; sorted keys, pinned by a `make check`
fixture. **Format 2** (**to build**, one bump in M1-02): adds `scroll`, `focus`,
`geometry`, global points `gx`/`gy` and `.unknown(kind:raw:)` round-tripping
verbatim; afterwards additive kinds never bump. Reserved shapes:
`transcriptSegment`, `codeContext`, `terminalCommand`. *Why:* an open,
forward-compatible format (research); refusing unknown kinds would strand
recordings between builds once kinds are added.

**Frame index** (`frames.jsonl`, **to build**): a header line, then
`{"n":0,"t":0.051,"d":0.034,"s":"started","cr":[…],"cs":2,"sf":2,"sr":[…],"br":[…]}`
with geometry keys only when they change, `{"k":"gap"}` and `{"k":"hold"}`.

**Core model** (**to build**): `Project` (`formatVersion`, `recording:
RecordingManifest`, `timeline`, `kit` and `style: BrandKit`, `kitReference`,
`export: ExportSettings`, `extra`); `Timeline` (`clips`, `cuts: [Cut]` with
`Provenance .trim | .manual | .retake(UUID) | .silence | .transcriptWords([UUID])`, `zoom:
ZoomTrack`, `camera`, `captions`, `callouts`; `keptRanges()` is the one
source↔timeline mapping); `ZoomTrackSegment` wraps the Engine's `ZoomSegment`
(**exists**) with `id`, `source: .auto(generation:) | .manual`, `locked` and
`extra`, so replanning replaces only unlocked `.auto` segments.
`RecordingManifest`: `source: CaptureSource` (`.display | .window(id, title,
bundleID, frame, strategy) | .area`), `content: ContentGeometry`, `screen:
ScreenTrackInfo`, `camera: CameraTrackInfo?`, `state: .inProgress | .complete
| .recovered | .failed`, `stopReason`, `duration`. Extensible containers adopt
`PreservesUnknownKeys` (`extra: [String: JSONValue]` captured from `allKeys`,
re-emitted on encode) so an older build never strips a newer one's fields;
`EditorModel` never saves an unedited project. `Migrator` applies ordered
steps; additive fields never bump, renames do (with a fixture per version),
newer versions are refused.

**Brand kit** (**to build**): `BrandKit` schema 1, a versioned JSON file
(`<name>.cutscenekit.json`) in `~/Library/Application Support/Cutscene/Kits/`
or a git checkout. A project keeps the snapshot (`kit`) and the edited `style`;
"Update from kit" is a three-way merge (`KitMerge.update(style:from:to:)`). The
kit's effect groups are Core mirrors of the Engine settings structs and of
`RenderStyle`, field for field with the same defaults (Core cannot import
Engine or Render; Package.swift has Engine depending on Core).
`Engine/KitSettings.swift` adapts them with `CursorSmootherSettings(kit:)`,
`ZoomPlannerSettings(kit:)` and `CameraPlannerSettings(kit:)`, and
`Render/KitStyle.swift` with `RenderStyle(kit:canvas:)`; M1-05 pins
`RenderStyle(kit: .default, canvas: 1920×1080) == RenderStyle()` so only one
set of defaults exists. The defaults below are the implemented ones
(`RenderStyle.swift`; the panel's #3B2F8F → #1E6FD9 / 14 px / 0.45 / 1.8×
proposal lost to implemented code, and a taste test can change the kit later):

| Group | Tunables (default) |
| --- | --- |
| `background` | `.linearGradient(#1C2B4B → #4A1F5E, 45°)` (`RenderStyle.background`); `.solid`, `.image` slots |
| `frame` | `padding` 0.06 of the shorter canvas side per side; `cornerRadius` 18 px at 1080p scaling with height; `shadow` opacity 0.55, blur 48 px, offset (0, 18) px (`RenderShadow`: a smoothstep over ± blur around the offset edge, which lands on the CSS `box-shadow` curve, so design-tool values transfer one to one) |
| `cursor` (mirror of `CursorSmootherSettings`, exists) | `spring` mellow 470/3.0/70; `clickSpring` snappy 530/1/40; `dragSpring` 1000/1/40; `shakeLegThreshold` 0.015, `shakeWindow` 0.1 s; `maximumInputRate` 60/s; `minimumTravel` 1/1920; `leadTimeConstant` 0.13 s; `clickAnticipationWindow` 0.5 s; `clickSpringLead` 0.175 s; `idleHoldGap` 0.067 s; `settleTimeout` 5 s; `idleFadeDelay` 2 s, `fadeOutDuration` 0.4 s, `fadeInLead` 0.25 s; `pressScale` 0.8 over 0.13 s; `disabledRanges`; render `scale` 1.0 × native (`RenderStyle.cursorScale`, 1.0–3.0) |
| `cursor.click` | ripple radius 0 → 44 pt over 0.5 s `easeOutCubic`, stroke 2.5 → 0 pt, opacity 0.65 → 0, white, ≤ 4 concurrent |
| `zoom` (mirror of `ZoomPlannerSettings`, exists) | `leadIn` 0.3 s, `holdAfter` 2.5 s, `mergeGap` 2.5 s, `trailingIgnore` 1.0 s, `amount` 2.0, `detectsTypingBursts` true, `typingBurstMinimumKeys` 3, `typingBurstMaximumGap` 0.5 s |
| `zoom.camera` (mirror of `CameraPlannerSettings`, exists) | `sampleRate` 120 Hz, `retargetInterval` 8 ms, `spring` camera 200/2.25/40, `deadZoneWidth` 0.5, `deadZoneHeight` 0.7 of the zoomed viewport, `preAimThreshold` 1.0005, `fallbackFocus` (0.5, 0.5) |
| `camera` | circle, `size` 0.20 of canvas height, `inset` 0.03, bottom-trailing, mirrored for built-in cameras, no border, the frame shadow |
| `typography`, `captions`, `callout`, `intro`, `outro` | reserved, nil |

**Atomic writes.** `Data.write(to:options: .atomic)` (exists for the log); the
manifest's `.inProgress → .complete` is the commit point.

---

## 4. Effects engine (`CutsceneEngine`, pure, **exists**)

**Decision.** Keep the implemented engine: `EventLog → CursorSmoother →
CursorTimeline` (60 Hz), `ZoomPlanner → [ZoomSegment]`, `CameraPlanner →
CameraTimeline` (120 Hz) whose `viewport(at:)` is always inside the frame.
Everything is a `Sendable` value, deterministic, reads no clock, and the full
30-minute, 50k-event plan runs under **500 ms** (`make check`, 323 checks).
*Why:* implemented and verified beats an equivalent proposal.
*Rejected:* the panel's zero-phase Gaussian smoother (σ 30 ms, click anchoring,
jitter gate) and log-space zoom solver (`ω = 3.9 / 0.45 s`, dead zone 0.6):
same goals, unverified, and the phase-led spring already tracks within 0.003
of the frame and sits within 0.01 of the click point at click time.

**Springs** (`Spring`, `Spring2D`, `SpringStep`, `SpringParameters`): the
closed-form damped spring per fixed step (Juckett), three branches, rest snap
at displacement 1e-5 and velocity 1e-4, presets
mellow/slow/smooth/fast/snappy/drag/camera; `Easing`, `OnePoleLowPass`.
**Cursor smoothing** (`CursorSmoother`): shake pre-filter, decimation keeping
every rest point, hold through idle gaps; the spring chases the target read
`friction/tension` seconds ahead (phase-lead compensation); snappy spring and
click-point target before a click; drag spring while a button is held;
per-range disable; idle fade; press scale. Output `CursorSample { time,
smoothedPosition, rawPosition, isPressed, opacity, scale }`. **Zoom planner**
(`ZoomPlanner`): anchors are mouse-downs and typing bursts; windows `[t −
leadIn, t + holdAfter]` merge when gaps ≤ `mergeGap`, focus = anchor-weighted
centre, the last `trailingIgnore` is ignored (the stop click). **Camera
planner** (`CameraPlanner`): centre, amount and activity springs retargeted
every `retargetInterval` with velocity carried over; the centre lives in travel
space (0 = flush left/top, 1 = flush right/bottom) so the viewport is inside
the frame by construction; `edgeSnapRatio(forAmount:)` is half the viewport
side; a greedy dead-zone box re-aims the camera when the cursor leaves it;
pre-aim snaps the centre while amount ≤ `preAimThreshold`; framing holds during
zoom-out. `make check` pins C1 continuity, the inside-frame invariant, pre-aim
and mid-flight retargets.

**To build on top:** `RenderPlan` (M1-04: `build(log:duration:cursor:zoom:camera:)
-> sending RenderPlan`; `frameState(at:) -> FrameState { viewport,
viewportVelocity, cursor, cursorShape }`; M2-01 adds `canvas:` to the call and
`layout`, `contentCrop`, `ripples`, `camera` to the state, the crop fed from a
`ContentCropTimeline` input that is identity by default), `LayoutSolver` (card
= canvas minus padding, aspect-fit; bubble above or below the card on 9:16 and
1:1), `ClickEffects`, `ContentMapper` (M2-02, after M2-01: window mode,
per-frame `BoundingRect` → `ContentCropTimeline` smoothed with the camera
spring), `ZoomTrack` merge. `ZoomLevel.auto`
(card-native `clamp(round(contentHeight / cardHeight × 4) / 4, 1.5, 3.0)`) is
**v2**: the fixed 2.0× default exists and the choice is a taste test.

---

## 5. Render pipeline (`CutsceneRender`: the compositor **exists**, the AVFoundation glue is **to build**)

**Decision.** One code path: `MetalCompositor`, a custom `AVVideoCompositing`
driven by an `AVMutableComposition`, shared by the `AVPlayer` preview and the
`AVAssetReader` export. *Why:* preview equals export by construction;
AVFoundation does decoding, scheduling, A/V sync, audio and scrubbing; trim and
later word-level cuts are composition edits; least code to a styled export.
*Rejected for v1:* the research's hand-built decoder (keyframe index, 5–8
positioned `AVAssetReader`s, byte-budgeted frame cache, scrub detector, reader
recreation on −11821). It is the **v2** upgrade when S2 measures any of:
zero-tolerance seek > **150 ms** or `startRequest` > **16.7 ms** at 4K60, paused
re-render > **50 ms** per change after the `AVPlayerItemVideoOutput`
escalation, export below **1× real time** at 1080p60, or stale source frames
inside kept ranges. The 1 s GOP, `ctts`-free intermediate is what that decoder
needs, so the file format does not change.

`CompositionBuilder.build(package:keptRanges:plan:style:cursor:canvas:) ->
BuiltComposition` (the caller passes `timeline.keptRanges()`, or the whole
recording as one range for the M1 auto-render, so the builder needs no
`Project` and M1-10 does not wait for M1-03): `AVMutableComposition` with the
screen, audio and camera tracks, **one insert per kept range**;
`AVMutableVideoComposition` with
`customVideoCompositorClass = MetalCompositor.self` (10.9), `renderSize` =
canvas, `frameDuration = 1/fps`, `sourceTrackIDForFrameTiming =
kCMPersistentTrackID_Invalid` (10.13, constant output rate from the VFR
source), the colour triple copied from the screen track, one
`RenderInstruction` per kept range (carrying `RenderPlan`, `RenderStyle`,
`CursorAtlas` and the time mapping); `AVMutableAudioMix` for levels.

**Preview.** `AVPlayerItem` with `videoComposition`, `audioMix`,
`seekingWaitsForVideoCompositionRendering = true` (10.9), in an
`AVPlayerLayer`; scrubbing is a coalesced zero-tolerance seek; `renderSize`
capped at a 1920×1080-equivalent area (`preview.maxPixels`). Live edits assign
a new `videoComposition`; if a paused item does not re-compose (S2), a seek
forces it; above 50 ms per change, escalate to `AVPlayerItemVideoOutput`
(10.8) + `CAMetalLayer`. **Export** reads with
`AVAssetReaderVideoCompositionOutput` (10.7, BGRA) and the same composition
(§6); two compositor instances share nothing mutable
(`preview.pauseDuringExport`, default false).

**`Compositor`** (**exists**, `Render/Compositor.swift`, verified by `make
spike ARGS="render"`): owns the device, its command queue, the library
compiled at init with `MTLDevice.makeLibrary(source:options:)` and
`MTLCompileOptions.mathMode = .relaxed` (the Command Line Tools have no Metal
compiler), the pipelines per target format, the sprite textures (mipmapped,
at most 32 cached), the BGRA output pool (`maximumPooledFrames` 16) and the
`CVMetalTextureCache`, all behind one `Mutex`. `render(_:style:)` fills a
frame from its pool, `render(_:style:into:)` a caller's BGRA IOSurface buffer
and `render(_:style:to:)` a renderable non-sRGB texture; each is synchronous
(`commit(); waitUntilCompleted()`) and callable from several threads at once;
`flush()` lets the texture cache recycle when a batch ends. Sources are
`SourceFrame`s: BGRA (premultiplied), 420v or 420f, IOSurface-backed, tagged
sRGB / BT.709 or untagged; a frame tagged for anything else throws
`unsupportedColorSpace`. An asynchronous `render(_:style:completion:)` on
`addCompletedHandler` is an M3-08 lever, not built.

**`MetalCompositor`** (**to build**, M1-10): the `AVVideoCompositing` adapter
holding one `Compositor` per instance. `sourcePixelBufferAttributes =
requiredPixelBufferAttributesForRenderContext = [BGRA, Metal-compatible,
IOSurface]`, `supportsWideColorSourceFrames = false`; `startRequest` runs
synchronously: `sourceFrame(byTrackID:)` for screen and camera
(`API_TO_BE_DEPRECATED`; `sourceReadOnlyPixelBuffer(byTrackID:)` is macOS 26.0
in the Swift overlay, a later `#available` branch), the last delivered screen
frame is retained so a request without one renders it rather than an empty
card, `Compositor.render(_:style:into:)` on the context's `newPixelBuffer()`,
`finish(withComposedVideoFrame:)`.

**The single pass** (one fullscreen triangle, `ShaderSource.composite`;
**exists** up to the cursor, bubble and ripples are M2-03), per pixel:
background (solid or two-stop gradient) → analytic soft shadow (smoothstep
over ± blur around the offset card edge) → content card as a signed-distance
rounded box with 1 px anti-aliasing → screen sample at `uv = crop.origin +
(viewport.origin + p × viewport.size) × crop.size`, one bilinear tap, or an
n × n grid of taps over the output pixel's footprint (n = ⌈minification⌉ ≤ 4)
once the card minifies the source past 1.05×, 4:2:0 chroma read at its
left-sited position, composited premultiplied over the shadowed background →
camera bubble (SDF, aspect-fill) → up to 4 click ripples → cursor quad from
`CursorAtlas`, trilinear from the sprite's mip chain, premultiplied over.
`bgra8Unorm`, gamma-space blending.

**Colour.** The encoder tags 709/709/709 (exists); the transfer tag SCK puts
on sRGB-pinned 420v buffers is not in the headers, so S1 dumps
`CVBufferCopyAttachments` of the first frame into platform-notes and sets
`capture.colorTags` (`.source` would use `AVVideoTransferFunction_IEC_sRGB`,
15.0). `StreamConfigurationBuilder` pins `colorSpaceName = sRGB`: unset, "the
output buffer uses the same color space as the display" (SCStream.h), Display
P3 on current Macs, and the compositor would tag P3 samples 709. The
compositor therefore refuses a frame whose primaries, transfer function,
YCbCr matrix or `CGColorSpace` attachment says anything but sRGB / 709, so
that mistake surfaces as an error. HDR and P3 are out of scope.

---

## 6. Export (`CutsceneExport`, **to build**)

`Exporter` actor: builds the composition for the preset canvas, reads with
`AVAssetReader` (video composition output + `AVAssetReaderAudioMixOutput`),
writes with `AVAssetWriter(outputURL: tmp, fileType: .mp4)`,
`shouldOptimizeForNetworkUse = true`, video through
`AVAssetWriterInputPixelBufferAdaptor` (10.7; `API_TO_BE_DEPRECATED` in Swift in
favour of `inputPixelBufferReceiver(for:pixelBufferAttributes:)`, 26.0),
progress = written time / duration, cancel = `cancelWriting()`, atomic move.

| Preset | Size | Codec | Rate control (tunables) |
| --- | --- | --- | --- |
| 1080p (default) | 1920×1080 | H.264 High (`AVVideoProfileLevelH264HighAutoLevel`) | `AverageBitRate` 16 Mb/s, `DataRateLimits` 24 Mb/s per 1 s; HEVC toggle 10 Mb/s |
| 4K | 3840×2160 | HEVC (`kVTProfileLevel_HEVC_Main_AutoLevel`) | 45 Mb/s, limit 70 Mb/s; H.264 toggle 60 Mb/s |
| Vertical | 1080×1920 | H.264 High | 16 Mb/s |
| Square | 1080×1080 | H.264 High | 12 Mb/s |

Common: **60 fps** (30 option), `MaxKeyFrameIntervalDuration = 2 s`,
`AllowFrameReordering = true`, `kVTCompressionPropertyKey_RealTime = false`
(offline declared; the header default is unknown), 709 triple, hardware encoder
required, even dimensions. Audio `kAudioFormatMPEG4AAC` 48 kHz stereo
**192 kbps**; mic **0 dB**, system **−6 dB** (`export.audio.*`). Self-check
(research §5.2): output PTS strictly increasing, frame count = kept duration ×
fps ± 1, durations within one frame, else fail loudly. Size and time estimate
plus disk guard before starting. Throughput is an estimate until S5 (1080p60 at
3–5× real time, 4K60 at 1.5–2.5×); levers: native 4:2:0 sampling in the
shader, asynchronous `finish`, the v2 reader pool.

---

## 7. Permissions and onboarding

| Capability | Check | Request | Deep link |
| --- | --- | --- | --- |
| Screen Recording (video + system audio) | `CGPreflightScreenCaptureAccess()` (10.15) | `CGRequestScreenCaptureAccess()` once (exists), else the deep link | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | `requestAccess(for: .audio)` on first toggle | `?Privacy_Microphone` |
| Camera | `authorizationStatus(for: .video)` | `requestAccess(for: .video)` on first toggle | `?Privacy_Camera` |
| Input Monitoring (keystrokes, exact tap clicks) | `CGPreflightListenEventAccess()` (exists) | `CGRequestListenEventAccess()` from a Settings action only | `?Privacy_ListenEvent` |

A grant takes effect only after relaunch (observed). `PermissionsModel`
re-preflights on `didBecomeActiveNotification` and once per second while
onboarding is visible; states `.notDetermined → .denied →
.grantedPendingRelaunch → .granted`; `Relauncher` (to build, M1-12, on `openApplication(at:configuration:)` with `createsNewApplicationInstance`; the dev window's `relaunch()` through `/usr/bin/open -n` is the prototype
) quits and reopens the bundle. `SCShareableContent` is never called
before `.granted`. Development builds name the ad-hoc trap ("run `make
dev-cert`"). Copy never promises "no further prompts": the periodic picker-
bypass alert for app-built filters is expected (unverified here).
`bundle.sh` has the usage strings; `LSUIElement`,
`NSCameraUseContinuityCameraDeviceType` and the `.cutscene` document type are
to add.

---

## 8. Module mapping

### What exists today

| Module | Files | Verified by | Status |
| --- | --- | --- | --- |
| `CutsceneCore` | `CutsceneCore.swift` (`projectFormatVersion = 1`), `InputEvent.swift` (`NormalizedPoint`, `PointSize`, `PointRect`, `CursorShape`, `InputEvent`), `EventLog.swift` (format 1) | `make check` fixture pins the JSON | exists |
| `CutsceneEngine` | `Spring.swift`, `Easing.swift`, `CursorSmoother.swift`, `ZoomPlanner.swift`, `CameraPlanner.swift` | `make check`: 323 checks (presets, closed form vs Euler, planner, smoother, C1 continuity, inside-frame, 500 ms budget, determinism) | exists |
| `CutsceneCapture` | `RecordingClock.swift`, `VideoEncoder.swift`, `RecordingWriter.swift`, `InputTelemetryRecorder.swift`, `CursorShapeSampler.swift`, `RecordingSpike.swift` (`SCRecordingOutput` proof), `CutsceneCapture.swift` (smoke test) | `make spike ARGS="writer"` (ffprobe: hvc1, no B-frames, ≤ 1 s keyframes, two AAC tracks; pause, static hole, audio gaps); `make spike ARGS="telemetry 3"` (125 Hz, pause, sidecar recovery, sprites) | exists |
| `CutsceneRender` | `Compositor.swift` (`Compositor`, `SourceFrame`, `CameraViewport`, `RenderedFrame`, `RenderTiming`, `RenderError`), `RenderStyle.swift` (`RenderStyle`, `RenderShadow`, `RenderBackground`, `RenderColor`), `CursorSprite.swift` (`CursorSprite.arrow`), `ShaderSource.swift` (runtime-compiled MSL, `CompositorUniforms`), `CutsceneRender.swift` (`gpuName`) | `make spike ARGS="render"`: pinned pixels of gradient, shadow, corner mask and content; cursor box, body and sub-pixel stability; a transparent region; 420v against BGRA; P3 tags refused; 1-px stripes of a 4K source box-filtered; median 1080p frame < 8 ms, warm 4K < 16.7 ms | exists |
| `CutsceneExport` | `CutsceneExport.swift` (`codecs`) | link | placeholder |
| `Cutscene` | `CutsceneApp.swift` (permission flow, relaunch, spike button) | manual | dev window |
| `CutsceneCheck`, `CutsceneSpike` | `main.swift` and the M1-00 check stubs; `WriterSpike.swift`, `TelemetrySpike.swift`, `RenderSpike.swift` and the M1-00 spike stubs | `make check`, `make spike` | exist |
| Build | `Package.swift` (Swift 6, macOS 15), `Makefile`, `scripts/{bundle,dev-cert}.sh` | `swift build` clean | exists |

### To build, by module

- **CutsceneCore** (Foundation only; a CI grep forbidding `import AppKit|SwiftUI`
  here and in Engine is to add, M1-14): `RecordingManifest`, `CaptureSource`, `ContentGeometry`,
  `FrameIndexEntry`, `RecordingPackage`, `JSONValue`, `PreservesUnknownKeys`,
  `Migrator`, `ProjectStore`, `Project`, `Timeline`, `Cut`, `ZoomTrack`,
  `BrandKit`, `KitMerge`, `KitLibrary`; `EventLog` format 2.
- **CutsceneEngine**: `RenderPlan`, `FrameState`, `KitSettings`, `LayoutSolver`,
  `ClickEffects`, `ContentMapper`, `ZoomTrackMerge`.
- **CutsceneCapture**: `CaptureSession`, `CaptureRequest` (`source`,
  `windowStrategy = .displaySurface`, `frameRate = 60`, `microphoneID`,
  `systemAudio = false`, `camera`, `quality = .balanced` (`VideoQuality`), `heartbeat = 1 s`,
  `includeMenuBar = true`, `colorTags = .bt709`), `StreamConfigurationBuilder`,
  `StreamOutputShim`, `ScreenFrameIndexer`, `ClickMonitors`,
  `WindowGeometryPoller`, `CameraRecorder`, `DiskSpaceMonitor`,
  `RecoveryScanner`, `Permissions`.
- **CutsceneRender**: `KitStyle`, `CursorAtlas`, `CompositionBuilder`,
  `RenderInstruction`, `MetalCompositor`, `CanvasSpec`. **CutsceneExport**:
  `ExportPreset`, `ExportWriterSettings`, `Exporter`, `Benchmark`.
- **Cutscene**: `AppModel`, `RecorderController`, `EditorModel`,
  `PermissionsModel`, `MenuBarMenu`, `HUDPanel`, `AreaSelectionOverlay`,
  `EditorWindow`, `PreviewView`, inspectors, onboarding, settings.
- **CutsceneTool** (new executable, Core + Engine only): `events dump`, `plan
  dump`, `plan bench`, `fixtures regen`; the headless `record`/`export` CLI is
  **CutsceneCLI** (all libraries; M3-07, pending team confirmation). Package:
  the new targets and `Tests/Fixtures/`, no new dependencies.

---

## 9. Risks and spikes

1. **S1, own writer on a live stream (one day, M1-09).** `WriterSpike` covers
   pause, static hole and audio gaps on synthetic frames. On a real
   `SCStream`: click-to-frame and clap-to-transient ≤ 1 frame; whether SCK
   PTS equal the host clock; `kill -9` at 10 s recovers through the marker;
   heartbeat checksum; colour attachments dump; a 4-channel audio interface; a
   10-minute fragmented file loads < 1 s and seeks < 150 ms. Fallback:
   `RecordingSpike`'s `SCRecordingOutput` with a derived offset.
2. **S2, custom compositor in `AVPlayer` and `AVAssetReader` (one day; reader half M1-10, player half M2-04).**
   `startRequest` fires on zero-tolerance seeks; a paused item re-renders on
   assignment or after a forced seek < 50 ms; exported frames hash-match
   preview frames; nil source frames render the held frame; request latency at
   4K60; two instances do not serialize. Fallback: `AVPlayerItemVideoOutput` +
   `CAMetalLayer`; then the v2 decoder.
3. **S3, permission-free clicks (two hours, M1-07).** `NSEvent` monitors raise no
   prompt from a reset TCC state; `NSEvent.timestamp × 1e9` matches
   `CGEventTimestamp` within 8 ms; the local monitor catches our own clicks.
4. **S4, window-mode geometry (one day, M2-06).** Menus, popovers and sheets on
   all three strategies; drag and resize while the synthetic cursor stays on
   the pointer; file size of a display-sized surface versus a pinned frame.
5. **S5, export throughput (two hours, M3-08).** `Benchmark.run` on a 2-minute
   recording in all four presets, preview playing and paused.
6. **Feel** is subjective and the research sweep is still running: every
   parameter is a tunable, fixture traces pin behaviour, the editor gets a
   debug overlay for planned segments.
7. **Unit tests need Xcode**; the Swift Testing targets are link placeholders,
   and `make check` (323 golden checks) and CI on `macos-15` run until then.
8. **Periodic picker-bypass alert**: observe its interval during M1 dogfooding.
9. **`NSCursor.currentSystem` deprecation**: shapes degrade to the arrow.
10. **Concurrent edits**: Sources change daily; this document names types and
    roles, DECISIONS.md records changes.

---

## 10. Milestones

Tasks, acceptance criteria and dependencies are in [PLAN.md](PLAN.md), whose
numbering is the lead's; this section and the §9 spike tags use it. Mapping
from this document's earlier draft: old M0 + M1a without click effects →
**M1**; the old M1 editor + old M2 → **M2**; old M3 plus multi-take, Studio
Sound and the headless CLI, which DECISIONS.md still lists as v2 → **M3**,
pending team confirmation (M1-14 records the ADR).

| Milestone | Outcome | Scope |
| --- | --- | --- |
| **M1, record a display from the menu bar, get a styled MP4** | A one-permission menu-bar recorder writing a `.cutscene` package (`screen.mp4` from the existing encoder and writer on a live stream, `events.json`, `frames.jsonl`, `manifest.json`, `project.json`, `cursors/`) and, without another click, a 1080p MP4 with auto-zoom, smoothed cursor, gradient background, padded rounded card and shadow; a take killed with `kill -9` is offered at the next launch and renders. No editor, ripples or camera | `CaptureSession`, `StreamConfigurationBuilder`, `ScreenFrameIndexer`, `ClickMonitors` (S3), `RenderPlan`, kit adapters, `MetalCompositor` + `CompositionBuilder` (S2 reader half), `Exporter`, menu-bar shell, onboarding, auto-render, `RecoveryScanner` |
| **M2, camera, window and area, click effects, presets, minimal editor** | Camera bubble, three window strategies (S4), area overlay, click ripples, vertical and square presets, system-audio levels, countdown, disk guard, failure paths, event-log format 2; an editor with trim and zoom-segment edits whose preview follows (S2 player half), exporting from it | `CameraRecorder`, overlays, `ClickEffects`, `LayoutSolver`, `ContentMapper`, `EditorModel`, `PreviewView` |
| **M3, multi-take, Studio Sound and loudness, brand kits, headless CLI** | Take markers and "retake from here", retake review and stitching (research §5.17); first-party Studio Sound and BS.1770 loudness with the mic track switched to LPCM; kit files and library; `cutscene-tool` and the `cutscene` `record`/`export` CLI; benchmarks (S5), settings, soak test; v1 complete | `TakeSegmenter`, `AudioEnhancer`, `Loudness`, `KitLibrary`, `KitMerge`, `CutsceneTool`, `CutsceneCLI`, `Benchmark` |

### Deferred to v2 (each with its trigger)

- **Hand-built editor decoder** (keyframe index, reader pool, frame cache,
  scrub detector; research §5.2): when S2 misses the §5 thresholds.
- **Pause button**: after S1 repeats the writer spike's pause case live.
- **`ZoomLevel.auto`, zoom below 100 %, Loupe mode**: after a taste test.
- **Camera re-solve per aspect ratio**: v1 aspect-fits the card.
- **Motion blur** (research §5.5): `viewportVelocity` is carried.
- **Keystroke overlay, typing re-timing, code and terminal callouts**: the tap
  and the reserved event shapes exist.
- **Cadence gate for native-refresh capture**: only if 120 Hz is adopted.
- **ProRes `pristine` tier, HEVC-with-alpha, GIF**: on request.
- **System picker**: if the bypass alert proves frequent and the floor moves
  to 15.2.
- **Application capture mode, global hotkey, precompiled `metallib`, the
  macOS 26 pixel buffer APIs, MCP server**: as toolchain and floor allow.
- **Secret redaction, captions, shell integration**: the DECISIONS.md
  differentiators, in order.
