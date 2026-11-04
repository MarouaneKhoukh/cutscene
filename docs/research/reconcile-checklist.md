# Reconciliation checklist: research brief vs. design panel

When the design panel's ARCHITECTURE.md and PLAN.md land, check each item
against them and resolve every conflict explicitly in `docs/DECISIONS.md`.
Section references point into [brief.md](brief.md).

Resolved 2026-11-02 against the reconciled `docs/ARCHITECTURE.md`; every item
below carries a "Resolved:" line, and the decisions are in `docs/DECISIONS.md`
(entries dated 2026-11-02).

## Must decide for v1

1. **Source recording path** (§0.6, §5.2). Research: drive `VTCompressionSession`
   directly and append compressed samples to a passthrough `AVAssetWriterInput`
   (`outputSettings: nil`); long-GOP hardware HEVC Main with H.264 fallback;
   `MaxKeyFrameInterval = fps × 1 s` (0.5 s at 4K60 or above) **and**
   `MaxKeyFrameIntervalDuration = 2 s`; `AllowFrameReordering = false`;
   `movieFragmentInterval ≈ 2 s`; finalize to a progressive faststart MP4 at stop
   via passthrough export and keep the fragmented original until that succeeds;
   a "needs finalize" project state for crashes; destination-volume throughput
   check. `SCRecordingOutput` exposes none of these controls, so it is fine for
   the capture spike and a first runnable milestone but must not become the
   editor's source path. Verify HEVC passthrough end to end in week one (§8 Q15).
   Confirmed 2026-11-02 by `ffprobe` on the spike's output: `SCRecordingOutput`
   defaults gave B-frames (`has_b_frames=2`), two keyframes in 5.4 s, one mixed
   AAC track, and ~14 fps variable frame rate on static content (§8 Q14).
   Implemented the same day as `CutsceneCapture.VideoEncoder` +
   `RecordingWriter`; HEVC passthrough verified (keyframes ≤ 1.0 s apart, no
   B-frames, faststart MP4, two AAC tracks). Recorded in `DECISIONS.md`.
   Resolved: adopted as the only v1 video path (ARCHITECTURE §2); the panel's
   "AVAssetWriter compresses with VideoToolbox keys" default and its S1 A/B are
   rejected (ADR "the capture video path stays VideoEncoder plus passthrough");
   `SCRecordingOutput` survives only in `RecordingSpike`.
2. **Consent path** (§0.5, §5.1). Direct path for area capture:
   `SCContentFilter(display:excludingApplications:exceptingWindows:)` plus
   `sourceRect`, selection overlay per screen at `.screenSaver` level. Call
   `CGRequestScreenCaptureAccess()` at first launch; explain the relaunch;
   expect the periodic "bypass the system private window picker" alert on
   macOS 15+ and never promise "no monthly prompt". System picker behind a flag
   until §8 tests 1–3 pass.
   Resolved: adopted (ARCHITECTURE §2 area mode, §7 onboarding). Display and
   area modes exclude our application rather than our windows; the system
   picker is not adopted in v1 because `SCContentFilter.includedWindows` and
   `includedApplications` are macOS 15.2 (header-verified), so its filter cannot
   be read back on the 15.0 floor; it is a v2 item if the bypass alert proves
   frequent (ADR "v1 scope against the research brief").
3. **Telemetry** (§5.1). 120 Hz `DispatchSourceTimer` reading
   `NSEvent.mouseLocation` and `pressedMouseButtons`; cursor shape by hashing
   `NSCursor.currentSystem` image bytes at 16 ms (deprecated at macOS 27, see
   §8 Q7); clicks and keys from a listen-only `CGEventTap` (Input Monitoring
   prompt behaviour is §8 Q6); stamp with `CMClockGetTime(CMClockGetHostTimeClock())`
   minus pause offsets; normalize positions to the capture rect; versioned JSON
   event log beside the media, treated as a product feature.
   Resolved: implemented as `InputTelemetryRecorder` (measured 125 Hz, cursor
   shapes every other tick, tap only when Input Monitoring is already granted,
   `RecordingClock` stamps with pauses removed, JSONL sidecar with crash
   recovery) and kept; the panel's permission-free `NSEvent` global and local
   click monitors are added as the source between the tap and the poll edges
   (spike S3). ADR "telemetry sources".
4. **A/V sync and cadence** (§5.14). Capture-time stamping, never dequeue time;
   one host time base; snap stream starts more than 30 ms apart; EMA cadence
   gate on high-refresh displays (enter decimation at 0.88× nominal interval,
   exit at 0.95×); repeat the last frame only after 3 missed intervals;
   fragmented writes; `stream(_:didStopWithError:)` with auto-restart; a
   clapperboard self-test (white flash plus click every 2 s, drift slope
   < 10 ms/min) on day one.
   Resolved: capture-time stamping through one `RecordingClock` and fragmented
   writes exist; the end marker (exists) plus a 1 s heartbeat replace the
   3-missed-interval repeat, the EMA cadence gate is deferred until
   native-refresh capture (v2), stream-start snapping is replaced by one clock
   for every writer, and the clapperboard test is spike S1 rather than a
   Settings feature. ADR "static content gets an end marker and a 1 s
   heartbeat".
5. **Editor decoder** (§5.2). Keyframe index from the MP4 sample table; a pool
   of 5–8 `AVAssetReader`s positioned across the timeline; a byte-budgeted frame
   cache (a 4K NV12 frame is 12.4 MB); scrub detector (jump ≥ 5 frames, 100 ms
   cooldown); check reader status on every empty read (error −11821) and
   recreate; never serve a cached neighbour as the requested frame during
   export; export self-check that compares each frame's PTS to the request.
   Resolved: v1 uses the panel's custom `AVVideoCompositing` compositor shared
   by `AVPlayer` preview and `AVAssetReader` export (ARCHITECTURE §5); the
   hand-built decoder is the v2 upgrade with measured triggers (seek > 150 ms,
   request > 16.7 ms at 4K60, re-render > 50 ms, export < 1× real time, stale
   frames); the export self-check is kept in v1 (monotonic PTS, frame count,
   duration match). ADR "preview and export share one AVVideoCompositing
   compositor".
6. **Cursor smoothing** (§5.3). Closed-form spring per step (Juckett), presets
   (tension/mass/friction) Mellow 470/3.0/70, Slow 200/2.25/40, Smooth
   80/2.5/28, Fast 380/1.0/30; phase-lead compensation of `friction/tension`
   seconds eased with a ~130 ms one-pole filter; click anticipation when the
   next click is ≤ 500 ms away with a snappy spring 530/1/40 from 175 ms before
   the click; drag spring 1000/1/40 while a button is held; shake pre-filter
   (reversals < 1.5% of screen within 100 ms); decimate to ≤ 60 samples/s;
   hold on idle gaps > 67 ms; per-segment disable; shape from the raw timeline;
   shrink to 0.8× over 130 ms on click; fade out after 2 s idle.
   Resolved: implemented as `CursorSmoother` with every constant in
   `CursorSmootherSettings` and pinned by `make check`; kept over the panel's
   zero-phase Gaussian smoother. ADR "the effects engine stays spring-based".
7. **Auto-zoom** (§5.4). Segments from clicks padded −300 ms / +2.5 s, merged at
   gaps ≤ 2.5 s, ignoring the last 1 s, 2.0× default; add typing bursts (≥ 3
   non-modifier key-downs with gaps < 0.5 s) as anchors; camera from three
   spring channels (center, amount, activity) retargeted every 8 ms with
   velocity carried over (stiffness 200, damping 40, mass 2.25); dead-zone box
   ≤ 50% × 70% of the zoomed viewport; viewport kept in frame by construction
   in 0..1 travel space with `edge_snap_ratio 0.25`; pre-aim while amount
   ≤ 1.0005; C1 continuity tests across segments; precompute budget 500 ms for
   50k events; user knobs for lead, hold, level (below 100% allowed), follow
   speed, dead zone, and a Loupe mode.
   Resolved: implemented as `ZoomPlanner` (clicks and typing bursts) and
   `CameraPlanner` (three spring channels, travel space, dead zone, pre-aim,
   C1 and budget checks) and kept over the panel's log-space solver; the
   panel's segment metadata (`id`, `source`, `locked`, merge) is added around
   `ZoomSegment`; zoom below 100 %, Loupe mode and the card-native `.auto`
   level are v2 after a taste test. ADR "the effects engine stays
   spring-based".
8. **Export** (§5.15). `AVAssetWriter` + VideoToolbox with `RealTime = false`,
   `AVAssetWriterInput.PixelBufferReceiver` on macOS 26+ and the adaptor on
   15.x (adaptor deprecated at 27); 2 s export GOP; faststart; size and time
   estimate plus disk and memory guards; preview and export share one Metal
   pass bit for bit.
   Resolved: adopted (ARCHITECTURE §6) with one correction from the headers:
   the adaptor is `API_TO_BE_DEPRECATED` in Swift with no version, and
   `PixelBufferReceiver`/`inputPixelBufferReceiver` are macOS 26.0 in the Swift
   overlay, so the 15.0 path has no version pressure; a `#available(macOS 26)`
   branch comes later. Preview and export share the compositor by
   construction.
9. **Audio** (§5.16, §7). Research puts on-device Studio Sound (vendored
   xiph/rnnoise, BSD-3) and BS.1770 leveling to −16 LUFS / −1 dBTP, applied
   non-destructively with a bypass, in v1.
   Resolved: first v2 (ADRs "AAC audio tracks in v1, LPCM when Studio Sound
   lands" and "v1 scope against the research brief"), then pulled forward
   into M3 at the lead's instruction, pending team confirmation (PLAN M3-04: a
   first-party `AVAudioEngine` chain, no RNNoise; the mic track switches to
   LPCM there; M1-14 records the ADR). The AAC-per-source intermediate stays
   until then, and the mix levels (mic 0 dB, system −6 dB) are the M2 audio
   controls.
10. **Multi-take recording** (§3 row 1, §5.17, §7). Research ranks take-level
    retake detection as the number one DevRel differentiator and puts marker
    hotkey + auto-stitch + "last complete take wins" with a review list in v1.
    `DECISIONS.md` v1 scope does not include it. User decision.
    Resolved: `takeMarker` events (the case exists in `InputEvent`) are
    recorded from the first builds; auto-stitch, retake detection and the
    review list were v2 (ADR "v1 scope against the research brief") and are
    now PLAN M3-01/M3-03 at the lead's instruction, pending team confirmation
    (M1-14 records the ADR).
11. **Camera bubble, backgrounds, click effects, keystroke overlay**
    (§5.6–§5.9): read those sections before implementing their milestones.
    Resolved: camera bubble (§5.8) is M2 through `CameraRecorder` feeding a
    second `VideoEncoder` + `RecordingWriter` on the same clock; backgrounds,
    padding, corners and shadow (§5.6) are the single Metal pass in
    ARCHITECTURE §5 with the kit defaults in §3; click ripples (§5.7) are
    `ClickEffects` in M2 (PLAN M2-01); the keystroke overlay (§5.9) stays deferred per
    DECISIONS.md, with key capture available today behind Input Monitoring.

## Cross-cutting requirements the research found users demand

- Open, versioned JSON event log and project format (§3).
  Resolved: `EventLog` format 1 exists and is pinned; format 2 (one planned
  bump) adds scroll, focus, geometry and `.unknown(kind:raw:)` round-tripping;
  project, manifest and kit files adopt `PreservesUnknownKeys`. ADR "formats
  keep EventLog, Double seconds and one planned bump".
- Headless CLI (record, export) from day one; MCP later (§3, §7).
  Resolved: `cutscene-tool` ships data-only commands (events dump, plan dump
  and bench, fixtures; PLAN M3-06); the `record`/`export` CLI was v2 (ADR "v1
  scope against the research brief") and is now PLAN M3-07 at the lead's
  instruction, pending team confirmation (M1-14 records the ADR); MCP stays
  later.
- Review-before-apply for every automated edit (§2 item 13).
  Resolved: no automated edits ship in v1 beyond auto-zoom, whose segments are
  editable data (`ZoomTrackSegment.source`, `locked`, merge keeps manual
  work); the review-list pattern is reserved for the v2 transcript and retake
  features.
- Portable engine boundary with golden test vectors (§0.1).
  Resolved: `CutsceneCore` and `CutsceneEngine` are Foundation-only, every type
  is a `Sendable` value, and `cutscene-check` holds 323 golden checks; the
  Swift Testing targets are link placeholders until Xcode is standard
  (ARCHITECTURE §9.7). The CI grep forbidding AppKit and SwiftUI imports there
  is to add (PLAN M1-14).
- License Apache-2.0 with DCO; Cap is AGPL and stays a spec-only reference;
  Reframed (MIT, Swift/Metal, macOS 15+) is the permissive code reference (§6).
  Resolved: unchanged, decided before the first public release (README);
  nothing in the architecture depends on it.
- H.264/HEVC patent licensing for a free download is an open legal question
  for distribution (§8 Q32); irrelevant while the app is used locally.
  Resolved: unchanged; local use only for now (DECISIONS "local first").

## Conflicts with the repository as it stands

- The capture spike records through `SCRecordingOutput` with HEVC: valid as a
  proof of capture, invalid as the recording path (item 1).
  Resolved: `RecordingSpike` stays a proof only; the recording path is
  `VideoEncoder` + `RecordingWriter` (ARCHITECTURE §2).
- `DECISIONS.md` v1 scope omits multi-take, Studio Sound and the CLI; the
  research recommends all three in v1 (items 9, 10 and the cross-cutting list).
  Resolved: markers captured in v1, stitching v2; Studio Sound v2; data-only
  CLI v1, record/export CLI v2 (ADR "v1 scope against the research brief").
  Re-cut 2026-11-03 at the lead's instruction: all three are PLAN M3, pending
  team confirmation (items 9, 10 and the CLI bullet above; M1-14 records the
  ADR).
- `platform-notes.md` lacks the periodic consent alert, the
  `NSCursor.currentSystem` deprecation, and the Input Monitoring question.
  Resolved: all three are in platform-notes (Permissions section and the
  AppKit list), with the deprecation text quoted from the header.
- The design panel ran without the brief; expect it to lean on
  `SCRecordingOutput` and click-only zoom. Both are acceptable for milestone 1
  only if the project format and engine types already leave room for items 1
  and 7.
  Resolved: the panel did lean on `SCRecordingOutput` for its M0 and on click-only
  zoom; the reconciled architecture uses the existing encoder and writer from
  M0 and the existing planner, which already anchors on typing bursts, so no
  room had to be reserved.
