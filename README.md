# Cutscene

A native macOS screen recorder for developer demos. Record a screen, window or
area with your camera and mic, and get a finished video with smooth auto-zoom,
a smoothed cursor, click effects and a styled background, without a per-seat
subscription.

> Working codename. Early development: the first build meant for daily use
> (Milestone 1) is done and in use; Milestone 2 (camera, window and area,
> click effects, presets, a minimal editor) is being built; see Status.

## Why another recorder

Screen Studio set the bar for effortless, good-looking demo videos. Using it and
its alternatives across a developer-relations team surfaced three recurring
frustrations: per-seat pricing, editing and workflow limits (one clip, a weak
timeline, no shared presets), and export speed, quality and format gaps.

Cutscene aims at parity on the effects that matter, then goes where those tools
don't:

- **Code and terminal aware.** Zoom to the command being typed, render commands
  as clean callout chips, highlight changed code lines, replace messy typing with
  clean, evenly paced typing.
- **Transcript-driven editing.** Local speech-to-text; cut by deleting words,
  drop filler, burn in styled captions, generate chapters.
- **Brand kits as code.** Backgrounds, cursor style, zoom feel, intro and outro
  defined in a versioned JSON kit the whole team shares through git.

## Status

**Milestone 1 is complete** and passed its live gate (2026-11-03): record a
display from the menu bar with the mic, press Stop, and get a styled MP4
without another click; a take killed with `kill -9` is offered at the next
launch and renders. **Milestone 2 is in progress** (2026-11-04): the camera
bubble, window and area recording, click ripples, the vertical and square
presets, a countdown, a recording pill, a disk guard and the session's pause
path are in the tree; the minimal editor (trim, zoom segments, a live
preview, export from it) and the Pause button itself are still landing. Multi-take, Studio Sound, brand-kit files
and the headless CLI are Milestone 3. The task list is
[`docs/PLAN.md`](docs/PLAN.md); the gate for each milestone is at the top of
its table.

What the tree holds today (`make run`):

- **A recorder window** (also reachable with Show Recorder, ⇧⌘R): choose the
  entire display, one window (thumbnail grid, every Space) or an area, with a
  live preview, the camera bubble where the export places it, a microphone
  meter, Pause/Resume, markers, a teleprompter (⇧⌘T) and an Open Recording
  menu of recent takes.

- **A menu-bar recorder with a launch window.** `LSUIElement`, so no Dock
  icon. The menu offers Record Display ▸ one entry per display, Record
  Window ▸ titles by application, Record Area… (a selection overlay on every
  display, snapped to even pixels), Microphone ▸ devices or Off, System
  Audio, Camera ▸ devices or Off (the camera grant is asked for on the first
  pick only), Stop and Add Marker while recording (with elapsed time, frames,
  drops and markers), Open Last Export, Open Last Recording (the editor, once
  it lands), Reveal Last Recording, Render Last Recording, Settings… (a stub
  until the settings window lands) and Quit. Because a full menu bar on a
  notched MacBook hides new status items, the same controls open at launch in
  a small window that floats above other apps on every Space, full-screen
  apps included (DECISIONS 2026-11-04). A take starts after a 3 s countdown
  drawn on every display, and a pill at the bottom of the screen shows the
  elapsed time, dropped frames and free disk with Marker and Stop; the
  overlays, the pill and the launch window are never in the capture. An
  onboarding window handles Screen Recording and the microphone: it
  preflights without prompting, deep-links into System Settings, and offers
  the relaunch a fresh grant needs; ScreenCaptureKit is never called before
  the grant is usable, and nothing requests Input Monitoring.
- **Three sources and a camera.** A display (our own windows excluded), a
  window (recorded as a display-sized surface with only that window on it,
  so menus and popovers are captured and the per-frame `boundingRect` lets
  the render crop the card and follow a move or a resize; the pinned-frame
  and independent-window strategies exist as options; DECISIONS 2026-11-04)
  or an area. A camera, built-in or Continuity, records to `camera.mp4` at
  up to 1080p30 on the same clock as the screen. `DiskSpaceMonitor` warns
  when under ten minutes of space remain at the current write rate and stops
  the take cleanly under 300 MB (`stopReason: diskFull`); a display that goes
  away, a stream macOS stops, a window that closes and a microphone that
  disconnects each end or degrade the take without losing it. The session
  can pause (`CaptureSession.pause()` / `resume()`: the clock pauses, the
  stream keeps running, what falls inside the pause is left out by its
  stamp, the audio joins sample-exact).
- **A `.cutscene` package per take** in `~/Movies/Cutscene/`: `screen.mp4`
  from our own encoder and writer (hardware HEVC, no B-frames, keyframes at
  most 2 s apart, one AAC track per audio source, written as a fragmented
  movie during the take and finalized to a faststart MP4 at stop),
  `events.json` (pointer at 125 Hz, clicks from permission-free `NSEvent`
  monitors, keystrokes only if Input Monitoring was granted, cursor shapes),
  `frames.jsonl`, `manifest.json`, `project.json` with the default kit, and
  the captured cursor sprites under `cursors/`. A 1 s heartbeat keeps a still
  screen seekable, and a `.needsFinalize` marker survives a crash.
- **The auto-rendered export.** After Stop, `AutoRender` (the
  `RecorderController.renderer`, set at launch) builds the `RenderPlan` off
  the main actor from the package's event log and its project's style
  (smoothed cursor, auto-zoom around clicks and typing bursts, a spring
  camera, click ripples, the camera bubble placed by `LayoutSolver` for the
  canvas aspect, and in window mode the content crop from `ContentMapper`),
  puts the whole recording into one `AVMutableComposition` through
  `CompositionBuilder`, whose video composition is a custom Metal
  `AVVideoCompositing` (gradient background, padded rounded card with shadow,
  the re-drawn cursor at the captured shape, zoom, up to four ripples, the
  bubble), and runs `Exporter`: `AVAssetReader` in, `AVAssetWriter` out,
  1080p60 H.264 High at 16 Mb/s unless the project says otherwise (4K HEVC,
  vertical 1080×1920 and square 1080×1080 are the other presets, each at 30
  or 60 fps, H.264 or HEVC; mic at 0 dB and system audio at −6 dB through
  the audio mix), AAC at 192 kbps, faststart, a self-check and a disk guard,
  into `~/Movies/Cutscene/Exports/`. The menu shows "Rendering… N %"
  meanwhile and Open Last Export reaches the file. At launch, `RecoveryFlow`
  offers "Finish recording" / "Discard" for every package a killed process
  left behind: `RecoveryScanner` finalizes the fragmented movie through its
  `.needsFinalize` marker, rebuilds the event log from its sidecar, and the
  take then renders like any other.
- **The editor's preview, ahead of the editor.** `PreviewView` holds the
  `AVPlayer` the editor will use: the same composition as the export in an
  `AVPlayerLayer`, coalesced zero-tolerance scrubbing, live edits by
  `videoComposition` reassignment (the paused frame re-renders by itself in
  about 2 ms; DECISIONS 2026-11-04), a 1080p cap on the preview canvas. The
  editor window, model, scrubber and inspectors (M2-10) are landing; until
  they do, Open Last Recording has nothing to open.

Everything below runs from the shell without a permission and without a
prompt; CI (`macos-15`) runs the build, `make check`, the lint and the
bundle, and the spikes are run by hand. Numbers are from the Apple M4 Pro
this was last run on (2026-11-04, debug build).

| Command | Verifies |
| --- | --- |
| `make check` | 1362 golden checks on the pure modules: event-log formats 1 and 2 (pinned JSON, unknown kinds kept), manifest, frame index and package layout, project round trips and the migrator, brand kit against every engine default, springs, cursor smoother, zoom and camera planners, click ripples (the curve pinned at five times), the card and bubble layout per canvas aspect (the bubble never overlaps the card on 9:16 and 1:1), the zoom-track merge (a locked and a manual segment survive a replan), the window content crop (a 0.2 s window jump yields a C1-continuous crop inside the frame), `RenderPlan` determinism and the 30-minute, 50k-event plan budget (1500 ms allowed in debug, 500 ms in release) |
| `make spike ARGS="package"` | fabricates a complete 10 s package with no permission: a synthetic desktop through `VideoEncoder` and `RecordingWriter` in real time, telemetry with clicks, a typing burst, an I-beam cursor and its sprite, a still stretch with heartbeat holds, a tone and click beeps on the two audio tracks; reads it all back and probes the movie with ffprobe (`hvc1`, `has_b_frames=0`, keyframe gap under 2 s) |
| `make spike ARGS="reader --synthetic"` | the composition path at 60 fps on that package: 608 frames for 10.1 s (⌈duration × 60⌉ ± 1), request latency 0.45 ms median against a 16.7 ms bound, 8 PNGs drawn with the captured sprites, no black frame, and a hole cut into the video track renders the held frame rather than black (30 of 30) |
| `make spike ARGS="player <package>"` | the same composition in an `AVPlayerLayer` window (spike S2's player half): every zero-tolerance seek fires one `startRequest` at the target frame, 13 ms median and 22 ms max from the call to the frame; a paused item re-renders by itself after a `videoComposition` reassignment in 2 ms median, 4.4 ms max; the player's frame and the reader's at one time are byte-identical; a reader at full speed alongside leaves the player 97 % of its 60 fps |
| `make spike ARGS="export <package> [4k\|1080p\|vertical\|square] [30\|60] [hevc\|h264]"` | `Exporter` on a package: `avc1` High 1920×1080 (or `hvc1`, 3840×2160, 1080×1920 fully filled, 1080×1080) at a constant frame rate, frame count = duration × fps, keyframes at most 2 s apart, bit rates within 20 % of the preset table, AAC 48 kHz 192 kbps, `ftyp moov mdat`; mic and system levels through the audio mix (`--tones`); a cancel through `cancel()` and one through task cancellation leave the Exports folder untouched |
| `make spike ARGS="render"` | the Metal compositor against pinned pixels (gradient, shadow, corner mask, content, cursor, a click ripple on the pressed frame, the camera bubble from a synthetic camera with its mirroring and corner), 420v against BGRA, a 4K source box-filtered onto 1080p, P3-tagged frames refused; 1080p frames under an 8 ms bound |
| `make spike ARGS="writer"` | the capture writer on synthetic 1080p60 frames with a pause, a still stretch, a late audio start and a dropped buffer: `hvc1`, no B-frames, keyframes at most 2 s apart, two AAC tracks, audio gaps filled |
| `make spike ARGS="telemetry 3"` | the input recorder: 125 Hz poll, cursor shapes with PNG sprites, the JSONL sidecar and its recovery |
| `make spike ARGS="permissions"` | the four permission states without a prompt; `--config W H scale` prints the stream configuration for a synthetic display (420v, sRGB and the 709 matrix, cursor hidden, 1/60) |
| `make spike ARGS="window own"` | spike S4 on the spike's own window, 10 s per window strategy, with a popup menu, a popover, a move and a resize of its own: frame counts, the recorded `boundingRect` changes, the lit area of the rendered card against them; `--strategy` picks one |

Some spikes need a person at the Mac or a grant the terminal has.
`make spike ARGS="clicks 10"` opens a window for ten seconds and counts the
clicks the `NSEvent` monitors see against the poll's edges (no permission,
never prompts). The `session` modes need Screen Recording (and the
microphone) granted to the terminal; they preflight first and exit 3
otherwise: `session 10` (a real `CaptureSession` on the main display,
ffprobe and seek timing), `session --crash` (`kill -9` at 5 s, then
recovery), `session --pause` (the live proof behind the Pause button) and
`session --long 600`. `camera 5` needs the camera grant and records
`camera.mp4` on the session's clock (30 fps, the first sample within a
frame of the origin). `window <title>` runs S4 on another application's
window while the person opens a menu, a popover and drags it. The findings
go into [`docs/platform-notes.md`](docs/platform-notes.md).

### Make targets

| Target | What it does |
| --- | --- |
| `make build` | `swift build`; `CONFIG=release` for an optimized build (`CONFIG` also applies to `check`, `spike` and `bundle`) |
| `make check` | builds and runs `cutscene-check`, the golden-vector runner for the pure modules; works with the Command Line Tools alone |
| `make spike ARGS="…"` | runs one `cutscene-spike` experiment: `ARGS` is the spike's name (`writer`, `telemetry`, `render`, `permissions`, `clicks`, `session`, `reader`, `export`, `package`, `player`, `camera`, `window`) followed by its arguments; `make spike` alone lists them. Live spikes preflight their grant and exit 3 without it, so nothing here raises a macOS prompt |
| `make test` | `swift test`; needs Xcode for the Swift Testing module |
| `make bundle` | builds and assembles a signed `dist/Cutscene.app` (`scripts/bundle.sh`: Info.plist with `LSUIElement`, the usage strings, `NSCameraUseContinuityCameraDeviceType` and the `.cutscene` document type; "Cutscene Dev" identity when present, else ad-hoc) |
| `make run` | `make bundle`, quits a running Cutscene (waits up to 3 s for it to go) and opens the new one: the menu-bar icon plus the floating launch window; `pkill -x Cutscene` quits it |
| `make dev-cert` | creates the local "Cutscene Dev" signing identity once, so macOS keeps the Screen Recording grant across rebuilds |
| `make format` | `swift format` in place over `Sources`, `Tests` and `Package.swift` |
| `make clean` | removes `.build` and `dist` |

## Architecture

| Module            | Role                                                                      |
| ----------------- | ------------------------------------------------------------------------- |
| `CutsceneCore`    | Projects, recordings, timeline, brand kits. No AppKit.                    |
| `CutsceneEngine`  | Pure math for cursor smoothing, auto-zoom and easing. Unit-tested.        |
| `CutsceneCapture` | ScreenCaptureKit, camera, microphone, cursor and input events.            |
| `CutsceneRender`  | Metal compositor for preview and export frames.                           |
| `CutsceneExport`  | AVAssetWriter / VideoToolbox encoding.                                    |
| `Cutscene`        | The SwiftUI app.                                                          |
| `CutsceneCheck`   | `cutscene-check`, the golden-vector runner behind `make check`.           |
| `CutsceneSpike`   | `cutscene-spike`, the platform experiments behind `make spike`.           |

Effects are applied at render time from recorded metadata (cursor positions,
clicks, keystrokes), never baked into the capture, so every choice stays
editable.

## Install from source

Cutscene is built on the Mac that runs it; no download is published yet.

Requirements:

- macOS 15 or later (Apple silicon or Intel).
- The Xcode Command Line Tools: run `xcode-select --install` and accept the
  dialog; it brings Swift 6.2. Full Xcode is not needed.
- Access to this private repository: ask to be added as a collaborator, then
  either add an SSH key to your GitHub account or use the HTTPS URL
  (`https://github.com/MarouaneKhoukh/cutscene.git`) and sign in when `git`
  asks.

```bash
git clone git@github.com:MarouaneKhoukh/cutscene.git
cd cutscene
make dev-cert   # one-time: a local signing identity, so permission grants survive rebuilds
make install    # builds, signs, copies Cutscene.app to /Applications and launches it
```

`make dev-cert` asks for your Mac login password once (it marks the new
certificate as trusted for code signing in your login keychain; nothing
leaves the machine). The first `make install` compiles everything and takes
a few minutes; later ones are quick. To update, `git pull && make install`.

### First recording (a five-minute test)

1. Cutscene has no Dock icon: look for the ◎ record icon in the menu bar. The
   recorder window opens on its own at launch (or choose Show Recorder,
   ⇧⌘R).
2. Pick **Display**, enable the microphone, and press **Record**. macOS asks
   for Screen Recording: allow it, then quit and relaunch Cutscene once (the
   grant only applies to a fresh launch). The microphone and camera prompts
   appear the first time you enable each one.
3. The window hides and a small recording pill appears. Click around, type
   something, then press **Stop** in the pill or the menu bar.
4. The editor opens with the take: trim, scrub, and press **Export video**
   (⌘E). The MP4 lands in `~/Movies/Cutscene/Exports` by default (Settings changes
   the folder and preset).

If recording never starts or keeps prompting, check System Settings >
Privacy & Security > Screen & System Audio Recording for Cutscene, or reset
the grant with `tccutil reset ScreenCapture app.cutscene.Cutscene` and
relaunch.

## Developing

Requires macOS 15 or later and Xcode 16 or later. The Command Line Tools alone
can build the app (`swift build`) but ship neither XCTest nor Swift Testing, so
`swift test` needs Xcode.

```bash
swift build
swift test
```

Without Xcode, `make check` builds and runs `cutscene-check`, a plain-Swift
runner that verifies the pure modules against golden vectors.

To run the app with a stable local signature, so macOS remembers the Screen
Recording grant across rebuilds, create a development identity once with
`make dev-cert`, then `make run`.

The design is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), the task
list in [`docs/PLAN.md`](docs/PLAN.md), the decisions in
[`docs/DECISIONS.md`](docs/DECISIONS.md) and the verified framework facts in
[`docs/platform-notes.md`](docs/platform-notes.md).

## License

To be decided before the first public release.
