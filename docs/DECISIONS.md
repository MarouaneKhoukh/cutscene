# Decisions

Short architecture decision records. Newest at the bottom. Each entry says what
was decided, why, and what was given up.

## 2026-11-02: macOS only, native Swift

**Decision.** Build for macOS only, in Swift, on ScreenCaptureKit, AVFoundation,
Metal and VideoToolbox.

**Why.** The team records on Macs. First-party frameworks give the highest
capture quality, the smoothest effects and the fastest hardware exports with no
bundled runtime or ffmpeg. It is also the shortest path to parity with Screen
Studio.

**Given up.** Windows and Linux. Tauri + Rust (Cap's approach) and Electron were
considered; both multiply the platform surface and lower the quality ceiling.

## 2026-11-02: v1 is the core recorder

**Decision.** v1 ships screen, window or area capture with mic and webcam
bubble; auto-zoom, smoothed cursor and click effects; background with padding,
rounded corners and shadow; trim; MP4 export at 1080p and 4K with vertical and
square presets.

**Why.** It is the smallest thing the team would use for real videos. Everything
else layers on top.

**Deferred.** Timeline with manual zoom keyframes, speed-up of silences,
keystroke overlay, GIF, device frames, motion blur, templates, iOS recording.

## 2026-11-02: differentiators

**Decision.** After v1, in order: code and terminal aware effects; transcript
driven editing with captions using local speech-to-text; brand kits as versioned
JSON shared through git. One-recording-to-many-formats auto-reframe is deferred.

**Why.** These answer the team's actual frustrations (repeated setup, weak
editing, output formats) and no current tool does them well for developer demos.

## 2026-11-02: effects are metadata, applied at render time

**Decision.** Capture stores the raw screen frames plus a timed metadata track
(cursor positions, clicks, keystrokes, window geometry). Zoom, cursor smoothing
and styling are computed from that metadata when rendering preview or export.

**Why.** Nothing is baked into the recording, so every effect stays editable and
a brand kit can be swapped after the fact. It also keeps the capture path cheap.

## 2026-11-02: module split and Swift Package Manager

**Decision.** One Swift package with `CutsceneCore` and `CutsceneEngine` kept
free of AppKit so they test in milliseconds, framework-facing `CutsceneCapture`,
`CutsceneRender` and `CutsceneExport`, and the `Cutscene` SwiftUI app. Swift 6
language mode, macOS 15 minimum.

**Why.** The algorithms are the product; keeping them pure makes them testable
against recorded traces. SwiftPM builds with the Command Line Tools alone and
opens directly in Xcode.

**Open.** App bundling, signing and an Xcode project for entitlements will be
added once the toolchain question (Command Line Tools vs full Xcode) is settled.

**Note.** Tests use Swift Testing. The Command Line Tools can build every
product target but ship neither the `Testing` nor the `XCTest` module, so
`swift test` requires Xcode (or a swift.org toolchain).

## 2026-11-02: local first

**Decision.** Build and use the app locally before any distribution. No Apple
Developer Program membership for now, so no notarization. Development builds
are signed with a self-signed "Cutscene Dev" identity created by
`scripts/dev-cert.sh`, which keeps the signature stable so TCC permission grants
survive rebuilds. `scripts/bundle.sh` reserves hardened runtime and timestamps
for a future Developer ID signature.

**Why.** The team is the first user. Getting to a recorder they rely on matters
more than distribution plumbing, which can be added without touching the app.

**Given up.** Sharing builds with people outside this machine until a Developer
ID exists; Gatekeeper rejects self-signed apps on other Macs.

## 2026-11-02: the recording path drives the encoder itself

**Decision.** Recordings are written by `CutsceneCapture.RecordingWriter`: a
`VTCompressionSession` (hardware HEVC Main, H.264 fallback; keyframe at least
every 1 s by count, 0.5 s at 4K60 and above, and every 2 s by duration; no
B-frames; BT.709 tags) feeding compressed samples into a passthrough
`AVAssetWriter` input in a fragmented QuickTime movie (2 s fragments), plus
separate AAC tracks for system audio and microphone. At stop the file is
finalized into a progressive faststart MP4; a `needsFinalize` marker survives a
crash. `SCRecordingOutput` is used only by the capture spike.

**Why.** The spike's `SCRecordingOutput` output measured with `ffprobe` had
B-frames, two keyframes in 5.4 s and one mixed audio track, and offers no
control over any of it. The editor needs sub-second keyframes for scrubbing,
no reordering so the keyframe index comes straight from the sample table,
fragments so a crash never loses the recording, and separate voice and system
tracks for Studio Sound. See `docs/research/brief.md` §5.2 and §5.14.

**Given up.** The simplicity of letting ScreenCaptureKit write the file, and
intra-only or ProRes intermediates (a 4K60 hour would be 530 GB).

## 2026-11-02: preview and export share one AVVideoCompositing compositor

**Decision.** Preview and export both run `MetalCompositor`, a custom
`AVVideoCompositing` driven by an `AVMutableComposition` built from
`Timeline.keptRanges()`; `AVPlayer` plays it and `AVAssetReader` exports it.
The research brief's hand-built decoder (keyframe index, 5–8 positioned
`AVAssetReader`s, byte-budgeted frame cache, scrub detector) is the v2 upgrade,
triggered when spike S2 measures a zero-tolerance seek over 150 ms or a request
over 16.7 ms at 4K60, a paused re-render over 50 ms per slider change after the
`AVPlayerItemVideoOutput` escalation, export under 1× real time at 1080p60, or
stale frames inside kept ranges.

**Why.** Preview equals export by construction, AVFoundation does decoding,
scheduling, sync and scrubbing, and it is the least code on the path to a
styled export. The 1 s GOP, `ctts`-free intermediate is what the hand-built
decoder would need anyway, so deferring it costs no format change.

**Given up.** Frame-identity control in the editor until the trigger fires;
Cap's reader-reliability lessons are kept as an export self-check instead.

## 2026-11-02: the capture video path stays VideoEncoder plus passthrough

**Decision.** `VideoEncoder` (`VTCompressionSession`) feeding
`RecordingWriter`'s passthrough `AVAssetWriterInput` remains the only v1 video
path. The panel's `AVAssetWriter`-compresses alternative (VideoToolbox keys
through `AVVideoCompressionPropertiesKey`) and its S1 A/B are dropped.

**Why.** The implemented path is verified by `make spike ARGS="writer"` with
`ffprobe` (no B-frames, keyframes ≤ 1 s, two audio tracks, faststart MP4,
pause, static tail); the alternative is unverified for HEVC and would only
remove code that already works.

**Given up.** A possibly smaller writer; revisit only if VideoToolbox ever
stops honouring properties on a direct session.

## 2026-11-02: AAC audio tracks in v1, LPCM when Studio Sound lands

**Decision.** The intermediate keeps one AAC track per source (48 kHz,
160 kbps, `RecordingWriterConfiguration.AudioTrack`), as implemented. The
writer's inputs switch to LPCM when Studio Sound or transcript editing starts.

**Why.** Verified today; 160 kbps is transparent for speech; the writer's gap,
trim and pre-roll logic is codec-independent. Rejected the panel's LPCM tracks
now: an unverified change on the critical path for a second lossy generation
nobody will hear.

**Given up.** Lossless audio before v2.

## 2026-11-02: one RecordingClock; pause stays in the data path, not the UI

**Decision.** `RecordingClock` (host origin at Record, pause intervals, stop)
is the single time base for media and telemetry; the writer starts its session
at zero so media time equals event time. The clock, encoder and writer keep
pause support, exercised by the writer and telemetry spikes; the v1 UI exposes
Pause only after spike S1 repeats the pause case on a live `SCStream`.

**Why.** The code handles pause correctly on synthetic feeds (keyframe after
resume, sample-exact audio join); the research brief names pause timing the
largest writer bug class, so the button waits for the live proof. Rejected the
panel's `t0 = first complete frame` origin (equivalent; the clock already
exists) and removing pause (discards verified code).

**Given up.** Pause in the first menu-bar builds.

## 2026-11-02: formats keep EventLog, Double seconds and one planned bump

**Decision.** `EventLog`/`InputEvent` (one JSON document, flat rows, sorted
keys, `Double` seconds, JSONL sidecar with `recoverLog`) stay the event log.
Format 2 is one planned bump in M0 adding `scroll`, `focus`, `geometry`,
optional global points and `.unknown(kind:raw:)` round-tripping; afterwards
additive kinds never bump. The frame index is a separate `frames.jsonl`.
Project, manifest, timeline and brand-kit files adopt `PreservesUnknownKeys`
(`extra: [String: JSONValue]`) and `EditorModel` never saves an unedited
project.

**Why.** The log is implemented and pinned by a fixture; the research demands
an open, forward-compatible format, which `.unknown` and `PreservesUnknownKeys`
give. Rejected the panel's `MediaTime { ns: Int64 }` and its replacement JSONL
event log: equivalent goals, would touch every engine type.

**Given up.** Byte-identical preservation of foreign number formatting (JSON
equality only) and a version-1 log that refuses unknown kinds.

## 2026-11-02: the effects engine stays spring-based

**Decision.** `CursorSmoother` (closed-form spring with phase-lead
compensation, click anticipation, drag spring, shake filter), `ZoomPlanner`
(clicks and typing bursts) and `CameraPlanner` (three spring channels in travel
space, dead zone, pre-aim) are the v1 engine. The panel's segment metadata
(`id`, `source: .auto(generation:) | .manual`, `locked`, `merge`) is added
around `ZoomSegment` as `ZoomTrackSegment`. The fixed 2.0× level stays the
default; the card-native `ZoomLevel.auto` is v2 after a taste test.

**Why.** `make check` pins over 300 facts about the engine, including tracking error
under 0.003 of the frame, the cursor on the click point at click time, C1
continuity, the inside-frame invariant and a 30-minute plan under 500 ms.
Rejected the panel's zero-phase Gaussian smoother and log-space zoom solver:
the same goals, unverified, and a rewrite of verified code.

**Given up.** The panel's exact-pixel zoom level as a default.

## 2026-11-02: telemetry sources

**Decision.** `InputTelemetryRecorder` stays (125 Hz pointer poll, listen-only
`CGEventTap` for exact clicks and keys when Input Monitoring is already
granted, cursor shapes through `CursorShapeSampler` with an arrow fallback).
Permission-free `NSEvent` global and local click monitors are added as the
source between the tap and the poll edges, verified by spike S3. The recorder
never prompts; Input Monitoring is an opt-in Settings action.

**Why.** The recorder is measured and recovers from a crash; `NSEvent`
monitors give exact click times with no TCC prompt (header: only key events
need Accessibility), which the panel added and the poll cannot. Rejected the
panel's `CGEvent(source:)` poll (equivalent) and dropping cursor shapes.

**Given up.** Nothing in v1; `NSCursor.currentSystem` is deprecated, so shapes
may degrade to the arrow on a future macOS.

## 2026-11-02: static content gets an end marker and a 1 s heartbeat

**Decision.** The writer's end marker (exists) gives the last frame its
duration; a `capture.heartbeat` of 1 s re-encodes the last complete frame on
static content so the 2 s keyframe cap can fire. Spike S1 verifies a retained
SCK surface stays unchanged, else the frame is copied. A clapperboard sync
test joins the spikes, not Settings.

**Why.** A frame-count GOP stretches to minutes on a static screen; one frame
per second bounds seek cost at negligible size. Rejected the research's
"repeat after 3 missed intervals" (50 ms at 60 fps inflates static takes) and
its EMA cadence gate (only needed for native-refresh capture, v2).

**Given up.** A perfectly variable-frame-rate intermediate.

## 2026-11-02: v1 scope against the research brief

**Decision.** v1 records `takeMarker` events with a pill button but does no
stitching or retake detection; Studio Sound and loudness normalization are v2;
`cutscene-tool` ships data-only commands (events dump, plan dump and bench,
fixtures) and the headless `record`/`export` CLI is v2; keystrokes are
captured only when Input Monitoring is already granted; the system picker is
not adopted (its filter cannot be read back below macOS 15.2).

**Why.** The team's priority is a usable local build; each item is a plug
point the formats already carry (marker events, LPCM switch, pure Core and
Engine modules for the tool), so deferring costs no rework. The research ranks
multi-take first among differentiators, which is why the marker data is
captured from day one.

**Given up.** Shipping the research brief's full v1 list in v1; the team
confirms markers, Studio Sound and the CLI order when M1 exists.

## 2026-11-03: milestones re-cut; multi-take, Studio Sound and the CLI are M3

**Decision.** The milestones are the lead's three, and PLAN.md is the task
list: **M1** records a display from the menu bar with the mic and, on Stop,
writes a styled MP4 by itself (no editor); **M2** adds the camera bubble,
window and area modes, click effects, the vertical and square presets and a
minimal editor; **M3** adds multi-take, Studio Sound and loudness, brand
kits and the headless CLI. Against ARCHITECTURE's earlier draft: old M0 plus
M1a without click effects is M1 (ripples are M2-01 and M2-03); the old M1
editor plus old M2 is M2; old M3 plus the three items the ADR "v1 scope
against the research brief" listed as v2 (take stitching and retake review,
Studio Sound and loudness normalization, the `record`/`export` CLI) is M3.
The pull-forward is at the lead's instruction and pending team confirmation;
ARCHITECTURE §10 and the reconcile checklist carry the numbering.

**Why.** The first build the team can use is a recorder, not an editor. A
take that exports by itself exercises every stage (live stream, own writer,
telemetry, plan, compositor, export) and starts dogfooding earliest, and the
ripples are a render-time effect with no capture-side dependency, so they
leave M1 without touching a format. The three M3 items each have their plug
point in place already (`takeMarker` events, the AAC-to-LPCM switch, pure
Core and Engine for the tool), which is what makes them schedulable rather
than v2; the research brief ranks multi-take first among the differentiators.

**Given up.** Click feedback in the first team build. The earlier ADR's v2
list stands for everything else; if the team does not confirm the three, they
return to v2 and M3 is brand kits, benchmarks, settings and the soak test.

## 2026-11-03: brand kits mirror the Engine settings and `RenderStyle` in Core

**Decision.** `BrandKit` (Core) carries `cursor`, `zoom`, `zoom.camera`,
`background` and `frame` groups that mirror `CursorSmootherSettings`,
`ZoomPlannerSettings`, `CameraPlannerSettings` and `RenderStyle` field for
field with the same defaults, each group a `PreservesUnknownKeys` struct;
`ZoomTrackSegment` mirrors `ZoomSegment` the same way. One-way adapters bring
them across: `Engine/KitSettings.swift` (`CursorSmootherSettings(kit:)`,
`ZoomPlannerSettings(kit:)`, `CameraPlannerSettings(kit:)`) and
`Render/KitStyle.swift` (`RenderStyle(kit:canvas:)`, pixel values scaled from
the kit's reference height to the canvas height). The kit's defaults are the
implemented `RenderStyle` ones (#1C2B4B → #4A1F5E at 45°, radius 18 px,
shadow 0.55 / 48 px / (0, 18), cursor scale 1), and `make check` pins that
`BrandKit.default` reaches every Engine default, that `RenderStyle(kit:
.default, canvas: 1920×1080) == RenderStyle()`, that the 4K style is the
1080p one scaled by 2, and that every field of a fully non-default kit lands
in its Engine or style field.

**Why.** Core is the format module and cannot import Engine or Render
(`Package.swift` has Engine depending on Core and Render on both). A kit file
must keep unknown keys and encode with sorted keys; the Engine structs are
plain values with no `extra` and should stay free of file concerns, and the
planners must stay usable without a kit. Two copies kept equal by checks cost
less than inverting the dependency (the planners in the format module) or a
third module of protocols. Rejected the panel's #3B2F8F → #1E6FD9, 14 px,
0.45 and 1.8× defaults: implemented code wins, and a taste test can change the
kit later.

**Given up.** One declaration per default: a new Engine tunable is added
three times (struct, mirror, check), and the fully non-default kit in
`KitChecks` is what catches a mirror that stopped reaching its field.

## 2026-11-03: the synthetic package spike stands in for live recordings

**Decision.** `make spike ARGS="package [outputDir] [seconds]"` (the lead's
amendment to PLAN M1-01) fabricates a complete `.cutscene` package without
any permission: a synthetic desktop with a wandering block, encoded at
1920×1080 60 fps through `VideoEncoder` and `RecordingWriter` exactly as a
take is and paced in real time; telemetry at the recorder's 125 Hz poll with
clicks on the block, a static stretch with idle samples and heartbeat holds,
a typing burst with an I-beam `cursorShapeChanged` and its sprite; a tone on
the system track and a beep on the microphone track at every click;
`manifest.json` (`.inProgress` first, `.complete` at the end), `events.json`,
`frames.jsonl` consistent with the frames written, `cursors/` and
`project.json`, all read back and the movie probed with ffprobe. It is the
input of `reader --synthetic`, of `export <package>` and of `session
--crash-synthetic`, and the fixture automated verification runs on; the live
modes of `session` are the lead's runs.

**Why.** An agent's terminal holds neither Screen Recording nor the
microphone and must never prompt (PLAN "Permission rule for spikes"), so
every live spike exits 3 in automation and the reader, export and recovery
tasks would have waited on M1-09's recording. The synthetic package has the
same files from the same encoder and writer, and known expected numbers
(frames, clicks, shapes, beeps at the clicks), so a failure downstream is
attributable; it also makes the crash harness, the reader and the export
reproducible on CI without a display.

**Given up.** Proof of ScreenCaptureKit itself: the colour tags on an
sRGB-pinned 420v frame, whether SCK stamps are host-clock, whether a retained
surface stays unchanged for the heartbeat, the stream-stop paths and real
click-to-frame sync come only from `session 10`, `--crash`, `--pause` and
`--long 600` with the grant. The fixture's `project.json` is hand-written
with the panel's values and predates `Project` (M1-03), so it does not decode
as one and the export spike falls back to `BrandKit.default` for it; writing
it through `ProjectStore` is a follow-up.

## 2026-11-03: spike S2 runs as a reader half (M1) and a player half (M2)

**Decision.** S2, the custom compositor under `AVAssetReader` and `AVPlayer`
(ARCHITECTURE §9.2), is two spikes. The reader half (M1-10, `make spike
ARGS="reader --synthetic"` or `reader <package>`) pulls the composition from
`CompositionBuilder` through `AVAssetReaderVideoCompositionOutput` and
`MetalCompositor` at 60 fps and checks frames = ⌈duration × 60⌉ ± 1, the
request latency (median under 16.7 ms), that a request without a source
frame renders the last delivered frame rather than black, and PNGs showing
background, card, shadow, the captured non-arrow cursor and zoom. The player
half (M2-04, `player <package>`) puts the same composition in an
`AVPlayerLayer` and times `startRequest` on zero-tolerance seeks, the paused
re-render after a `videoComposition` reassignment or a forced seek against
50 ms, and a player and a reader instance running at once. The v2-decoder
triggers (ADR "preview and export share one AVVideoCompositing compositor")
are measured half by half: the reader-side ones in M1, the preview-side ones
in M2.

**Why.** M1 has no preview: the auto-render reads the composition once, so
the reader half answers everything M1 can act on, needs no window, no player
and, on the synthetic package, no permission. The player questions have no
consumer before M2-10's editor, and the compositor is the same class in both
halves, so nothing is verified twice. S1 gave an early partial answer for the
player side: headless zero-tolerance seeks on the synthetic package took
10 ms median through an `AVPlayerItemVideoOutput` (platform-notes "Live
session").

**Given up.** Until M2-04: the exported-frames-match-preview-frames check,
the serialization check between instances, and any number for the paused
re-render, so the `AVPlayerItemVideoOutput` escalation stays a plan rather
than a decision.

## 2026-11-03: the compositor takes sRGB / BT.709 sources only

**Decision.** `StreamConfigurationBuilder` pins `colorSpaceName = sRGB` and
`colorMatrix = 709` on every stream, `VideoEncoder` tags 709/709/709, and
`Compositor` throws `RenderError.unsupportedColorSpace` for a source frame
whose primaries, transfer function, YCbCr matrix or `CGColorSpace`
attachment names anything but sRGB / BT.709; an untagged frame is taken as
sRGB. `make spike ARGS="render"` pins the refusal of a P3-primaries and a
Display P3 frame. `CaptureRequest.colorTags` stays `.bt709`; `.source`
(`AVVideoTransferFunction_IEC_sRGB`, 15.0) waits on S1's dump of the first
live frame's `CVBufferCopyAttachments`.

**Why.** Left unset, "the output buffer uses the same color space as the
display" (SCStream.h), Display P3 on current Macs, and P3 samples composited
under 709 tags come out desaturated in a way nobody notices until a viewer
does. One colour pipeline with a loud failure is cheaper and safer than a
conversion path: the mistake surfaces as an error in a spike, not as a tint
in a video. HDR and wide gamut are out of scope for v1.

**Given up.** HDR capture (`captureDynamicRange = .HDR`) and wide-gamut
sources: a P3 or HDR display is recorded as sRGB. Should S1 show that SCK
tags sRGB-pinned 420v buffers with a transfer the rule does not list, the
rule is widened for that tag, not relaxed.

## 2026-11-03: audio stays first-party; no RNNoise, no Silero

**Decision.** Studio Sound (M3-04) is an offline `AVAudioEngine`
manual-rendering chain on the microphone track, `AVAudioUnitEQ` high-pass,
`DynamicsProcessor` as expander and compressor, `PeakLimiter`, with a
`strength` wet/dry mix, written to `derived/mic-enhanced.caf` behind a
bypass; loudness is BS.1770-4 integrated LUFS with 4× oversampled true peak
in Swift, presets −16 LUFS / −1 dBTP, −14 and −23. Take-boundary trimming
(M3-01) reads an RMS envelope with `silenceThresholdDB`, `minimumSilence` and
`boundaryPad`. The research brief's xiph/rnnoise denoiser, Silero VAD and
DeepFilterNet are not vendored, and `AVAudioEngine`'s live voice processing
(`setVoiceProcessingEnabled`) is not used.

**Why.** Cutscene is first-party Apple frameworks only, with no package
dependencies, and builds with the Command Line Tools alone. RNNoise is a C
library with a weights blob to build and a licence to carry, Silero an ONNX
model that needs a runtime; each adds a toolchain and a licence question for
a stage behind a bypass toggle. Live voice processing fails on its own
terms: live-only, unavailable in manual rendering, and it would take the mic
off the ScreenCaptureKit clock that keeps voice and video in sync.

**Given up.** Quality. An expander behind a high-pass is a static gate, not a
learned denoiser: it lowers fan and room noise between words and softens
keyboard clicks, but cannot separate noise from speech while the speaker
talks, as RNNoise's network does (neither has de-reverb). An RMS envelope
takes breaths and clicks for speech and quiet speech for silence more often
than a VAD, so take boundaries lean on `boundaryPad`. The M3-04 acceptance
(silent spans down ≥ 10 dB, target ± 0.5 LU, true peak ≤ −1 dBTP) is the bar,
and the enhancer is one stage behind a bypass, so a better denoiser can
replace it without a format change if the bar proves too low.

## 2026-11-04: window recordings default to `.displaySurface`

**Decision.** `CaptureRequest.windowStrategy` keeps ARCHITECTURE §2's
default: a window is recorded as `SCContentFilter(display:including:
[window])` with `includeChildWindows = true` and `ignoreShadowsDisplay =
true`, a display-sized surface with the window on black (or clear), and
`ContentMapper` crops the card to the per-frame `boundingRect` that
`ScreenFrameIndexer` writes to `frames.jsonl` when it changes. `.pinnedFrame`
(the same filter with `sourceRect` = the frame at start) and
`.independentWindow` (`SCContentFilter(desktopIndependentWindow:)`) stay as
explicit options, chosen from Settings once M3-09 lands; the manifest's
`WindowSource.strategy` records which one a take used. `WindowGeometryPoller`
(10 Hz in window scope) writes `geometry` events for the log; the crop does
not depend on it on the default strategy.

**Why.** Spike S4 (`make spike ARGS="window own"`, M2-06, platform-notes
"Window capture") measured all three on the spike's own window with a popup
menu, an `NSPopover`, a move and a resize. Only `.displaySurface` captured
the menu and the popover, and its `boundingRect` grew with them (640×432 →
640×509 under the menu, 660×602 under the popover) and followed the move and
the resize, so the crop has a per-frame target through everything a demo
does to a window. The independent window never showed the menu or the
popover (as SCStream.h says) and scaled the resized window down into its
fixed output; the pinned frame showed child windows only where they
overlapped the frame and lost the part of the window that moved out of it.
The size cost is modest: 536–552 KiB for 10 s of HEVC `balanced` at
3024×1964 against 325–356 KiB for the pinned 1280×864 frame, about a third
more, not the five times the pixel count suggests; the independent window
cost the most (875–928 KiB) because that stream reports no idle frames and
re-sends a static window every interval.

**Given up.** The smallest files, and a window captured while occluded
(`.independentWindow` remains the explicit "window only" choice). Menu
translucency over the black surface shows black, since nothing else is on
it. The measurements are from the spike's own window, unattended; the lead's
run on another application's window (`window <title>`, with a sheet and a
drag while the cursor stays on the pointer) is pending and can only confirm
or narrow this, not change the default's reasons. A window on another Space
reports off-display geometry through the poller, which consumers of
`geometry` events must expect.

## 2026-11-04: the paused preview re-renders by `videoComposition` reassignment

**Decision.** A live edit in the editor builds a new
`AVMutableVideoComposition` (new `RenderInstruction`s, the same
`customVideoCompositorClass`) and assigns it to the paused `AVPlayerItem`;
`PreviewView` relies on the engine re-rendering the current frame by itself
and keeps the zero-tolerance seek to the current time only as a watchdog
(`reassignmentRenderTimeout`, 100 ms). The `AVPlayerItemVideoOutput` +
`CAMetalLayer` escalation and the v2 hand-built decoder are not taken;
`preview.pauseDuringExport` stays off; scrubbing is a coalesced
zero-tolerance seek with `seekingWaitsForVideoCompositionRendering = true`
and the preview composition is capped at `preview.maxPixels`
(1920×1080-equivalent).

**Why.** Spike S2's player half (`make spike ARGS="player <package>"`,
M2-04, platform-notes "Preview playback") measured every preview-side
trigger of the ADR "preview and export share one AVVideoCompositing
compositor" on the 10 s synthetic 1080p60 package: a paused item given a
new composition re-rendered on its own 8 of 8 times, 1.5–2.1 ms median and
4.4 ms at most from the assignment to the finished request, far under the
50 ms bound, and the engine reused the same `MetalCompositor` instance
across reassignments, so an edit pays no compositor creation or warm-up.
Zero-tolerance seeks fired exactly one `startRequest` each at the target
frame, 13.1 ms median and 22 ms max from the call to the rendered frame
(bounds 150 ms and 50 ms). The frame the player shows and the frame the
export's reader renders at the same time are byte-identical, and a reader
at full speed beside the playing player left it 97 % of its 60 fps cadence
with no shared lock showing in the request times, so nothing pauses during
an export. `AVPlayerItem.videoComposition` is `copy`, so reassignment is the
only live-edit path anyway.

**Given up.** The frame-identity control the escalation would give, until a
measurement needs it. The numbers are from a 1080p source on the M4 Pro;
the 16.7 ms request bound at 4K60 is measured on the reader side only
(platform-notes "Preview playback" and the reader spike), and a 4K preview
is built at 1080p by the `maxPixels` cap, so the 4K60 trigger stays open
until a 4K recording goes through the player.

## 2026-11-04: Pause ships; the session pauses the clock, the stream keeps running

**Decision.** The gate in "one RecordingClock; pause stays in the data path,
not the UI" is met: spike S1 repeated the writer spike's pause case on a live
`SCStream` (`make spike ARGS="session --pause"`: the clock paused 2 s
halfway, the buffers captured inside the pause absent from the take, a
keyframe on the first frame after the resume, the audio joined without a
hole or an overlap, every track ending on the recorded duration), and
M2-07 added `CaptureSession.pause()` and `resume()`. They pause
`RecordingClock` at the moment of the call and nothing else: the stream
keeps running, and the encoder, the writer, the telemetry and the camera
recorder each leave out what falls inside the pause by its stamp, the
encoder forces the keyframe after the resume, the writer trims the audio
buffer straddling it, and the heartbeat encodes nothing while paused.
`CaptureStatus` carries `isPaused`, `pauses` and `pausedSeconds`; the phase
stays `.recording`, so the menu and the pill show one state with a Pause /
Resume button beside Stop, wired to those two calls, and the elapsed time
shown excludes pauses.

**Why.** The research brief names pause timing the largest writer bug
class, which is why the button waited for the live proof rather than the
synthetic one. Pausing the clock instead of the stream keeps one time base
and one stop path: a stopped stream would need a restart with a new first
frame, a new audio pre-roll and a second origin, every one a place for the
drift the brief warns about, while a paused clock makes the pause a gap that
every stage already handles by stamp. The take's `events.json` and
`frames.jsonl` stay continuous in recording time, so the editor needs no
pause concept at all.

**Given up.** Nothing captured during a pause survives, so a pause is not
a cut that can be undone in the editor; a "retake from here" marker (M3)
is the way to keep the footage. The live run's output is the lead's and is
not yet pasted into platform-notes "Live session", whose S1 numbers are
still the synthetic ones; the Pause / Resume button itself is wired to the
session as part of the HUD and menu work (M2-09's pill holds Marker and
Stop as this entry is written).

## 2026-11-04: a floating launch window beside the menu-bar icon

**Decision.** `CutsceneApp` adds `Window("Cutscene", id: "recorder")` with
`.defaultLaunchBehavior(.presented)`: a small, fixed-width (360 pt, PLAN
M1-F6) `RecorderPanel` that hosts the same `MenuBarMenu` view the menu-bar
icon shows, so the two cannot drift apart. `FloatingWindowConfigurator`
sets the hosting window to `level = .floating` with `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary]`, movable by its background and
ordered front regardless, and the panel calls `NSApp.activate()` on appear.
The window is the idle-time face of the app; M2-09's `HUDPanel` pill
(`.nonactivatingPanel`, `.statusBar` level, the same Spaces behaviour)
takes over during a take.

**Why.** On a notched MacBook a full menu bar hides new status items, and
macOS gives no warning: on 2026-11-04 the app launched, drew nothing
reachable and, being `LSUIElement`, had no Dock icon either, so the first
user had no way in. A window the app presents at launch is reachable
whatever the menu bar holds. It floats and joins every Space because the
first fix, a plain window, sat on the desktop Space and was invisible to
someone working in a full-screen app, which is where demos are recorded.
`NSApp.activate()` is needed because an agent app is never frontmost on its
own and the window otherwise opens behind whatever was active.

**Given up.** ARCHITECTURE §1's "record without a window in the way" in its
pure form: a 360 pt window floats at launch until closed, and it is excluded
from display and area captures with the rest of our application. Rejected:
a Dock icon (the activation policy flips to `.regular` only while the editor
is open), a status item with a custom length (the notch rule hides it all
the same), and a global hotkey (no `RegisterEventHotKey` header in the
Command Line Tools SDK). Menu-bar managers that fold items under the notch
are the user's choice, not something the app can rely on.
