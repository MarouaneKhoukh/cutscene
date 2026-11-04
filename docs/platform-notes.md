# Platform notes

Facts about the Apple frameworks Cutscene builds on, verified against the
installed SDK headers rather than documentation pages. Each entry gives the
minimum macOS version from the header's availability annotation.

Verified 2026-11-02 against the macOS 26.2 SDK
(`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`). Cutscene targets
macOS 15 or later, so everything marked 15.0 or earlier is usable
unconditionally.

## ScreenCaptureKit

### Choosing what to capture: `SCContentFilter`

| Initializer                                                   | Captures                                           |
| ------------------------------------------------------------- | -------------------------------------------------- |
| `init(desktopIndependentWindow:)`                             | One window, even when occluded or on another space |
| `init(display:excludingWindows:)`                             | A display minus listed windows                     |
| `init(display:including:)` (windows)                          | A display showing only listed windows              |
| `init(display:including:exceptingWindows:)` (applications)    | A display showing only listed apps                 |
| `init(display:excludingApplications:exceptingWindows:)`       | A display minus listed apps                        |

Properties: `style` (`SCShareableContentStyle`), `pointPixelScale` (Retina
scale of the captured content), `contentRect` (bounds in points),
`includeMenuBar` (display filters only; the header says it "has no effect for
the desktop independent window filter", defaults to YES for
`initWithDisplay:excluding` filters and to NO for `initWithDisplay:including`
filters). `includedWindows` and `includedApplications` are **15.2**, so a
filter returned by the system picker cannot be read back on the 15.0 floor.

There is no region initializer. An area recording is a display filter plus
`SCStreamConfiguration.sourceRect`, with our own selection overlay.

Window-bound display filters (`display:including:`): "the width and height
will be that of the display passed in for the filter" and the background of
such sample buffers "will be default black and can be set through the
SCStreamConfiguration" (SCStream.h:21). `initWithDesktopIndependentWindow`
"captures just the independent window passed in" (SCStream.h:144).

### Stream configuration: `SCStreamConfiguration`

| Property                             | Min macOS | Use                                                        |
| ------------------------------------ | --------- | ---------------------------------------------------------- |
| `width`, `height`                    | 12.3      | Output size in pixels                                      |
| `minimumFrameInterval`               | 12.3      | Frame-rate cap (`CMTime`); default 1/60; `kCMTimeZero` = the display's native refresh rate |
| `pixelFormat`                        | 12.3      | Header list: BGRA, l10r (ARGB2101010), 420v, 420f, xf44 (10-bit 4:4:4 full range), RGhA (half float) |
| `showsCursor`                        | 12.3      | Hide the real cursor so we can draw a smoothed one         |
| `sourceRect`, `destinationRect`      | 12.3      | Area capture and letterboxing; `sourceRect` is in points in the display's logical coordinate system |
| `queueDepth`                         | 12.3      | Frames kept in the queue; default 8 and the header says it "should not exceed 8 frames" |
| `backgroundColor`                    | 12.3      | "By default the background color is clear"                 |
| `colorSpaceName`, `colorMatrix`      | 12.3      | Pin to sRGB or Display P3; the matrix applies to 420v/420f only |
| `capturesAudio`, `sampleRate`, `channelCount`, `excludesCurrentProcessAudio` | 13.0 | System audio                        |
| `scalesToFit`, `preservesAspectRatio` | 12.3 / 14.0 | Scaling behavior                                        |
| `captureResolution`                  | 14.0      | `.automatic`, `.best`, `.nominal`                          |
| `ignoreShadowsDisplay`, `ignoreShadowsSingleWindow` | 14.0 | Drop window shadows; we draw our own          |
| `shouldBeOpaque`                     | 14.0      | Fill transparent window regions                            |
| `ignoreGlobalClipDisplay`, `ignoreGlobalClipSingleWindow` | 14.0 | Capture offscreen parts of windows       |
| `presenterOverlayPrivacyAlertSetting` | 14.0     | Suppress the Presenter Overlay alert                       |
| `includeChildWindows`                | 14.2      | "Show the child windows in display bound windows and applications sharing. Child windows are included by default." Applies to display-bound filters, not to `desktopIndependentWindow` |
| `showMouseClicks`                    | 15.0      | System click highlight; we render our own instead          |
| `captureMicrophone`, `microphoneCaptureDeviceID` | 15.0 | Mic on the same stream clock as video; the ID is an `AVCaptureDevice.uniqueID` |
| `captureDynamicRange`                | 15.0      | SDR or HDR capture; "adding a recording output to a stream with SCCaptureDynamicRangeHDR set will fail" |

`SCStream.synchronizationClock` (13.0, nullable) is the "synchronization clock
used for media capture". `updateConfiguration(_:)` and `updateContentFilter(_:)`
change a running stream; a configuration update stops an attached recording
output. The delegate methods `streamDidBecomeActive(_:)` and
`streamDidBecomeInactive(_:)` (all shared windows closed, then one re-opened)
are **15.2** and need an `if #available` gate.

### Stream outputs: `SCStreamOutputType`

`screen` (12.3), `audio` (13.0), `microphone` (15.0). Screen samples arrive as
`CMSampleBuffer`s backed by `IOSurface`, which Metal can wrap without a copy.

Per-frame attachments (`SCStreamFrameInfo`): `status`, `displayTime` ("the
mach absolute time … when the frame was displayed by the window server"),
`scaleFactor`, `contentScale`, `contentRect` ("size and location of content in
points in surface"), `dirtyRects` (all 12.3); `screenRect` (13.1, the onscreen
location of the captured content); `boundingRect` (14.0, the smallest box
containing all captured windows, in points, surface coordinates);
`presenterOverlayContentRect` (14.2). `displayTime` converts with
`CMClockMakeHostTimeFromSystemUnits`.

`SCStreamError` codes: `userDeclined` −3801 and `userStopped` −3817 (12.3),
`failedToStartMicrophoneCapture` −3820 and `systemStoppedStream` −3821 (15.0).

Capturing the microphone through the stream, rather than a separate
`AVCaptureSession`, puts voice and video on one clock and removes the main
source of lip-sync drift.

### Direct-to-file recording: `SCRecordingOutput` (15.0)

`SCRecordingOutputConfiguration` takes `outputURL`, `videoCodecType` (default
H.264), `outputFileType` (default MPEG-4), and exposes `availableVideoCodecTypes`
and `availableOutputFileTypes`; nothing else is configurable.
`SCRecordingOutput` reports `recordedDuration` and `recordedFileSize`. Header
rules: only one recording output per stream; add it before `startCapture()`
"to guarantee the first sample captured in the stream to be written"; stopping
the capture finishes the file; updating the stream configuration during a
recording stops the recording. Attached to an `SCStream`, it writes the raw
capture to disk with hardware encoding while the app records metadata
alongside, so a bootstrap capture path needs no `AVAssetWriter` of its own.

Observed 2026-11-02 with the capture spike (5.4 s of a mostly static Retina
display, HEVC): the encoder defaults are long-GOP **with B-frames**
(`has_b_frames=2`), keyframes only at 0.00 s and 1.06 s, 5.9 Mb/s at
3024×1964, BT.709; frames arrive only when pixels change (75 frames in 5.4 s,
about 14 fps average, variable frame rate); system audio and microphone came
out as a single AAC 48 kHz stereo track. So `SCRecordingOutput` gives no
control over GOP, B-frames (which add `ctts` and seek cost) or audio track
layout. Use it for proofs only; the recording path drives
`VTCompressionSession` and `AVAssetWriter` directly (research brief §5.2).

Confirmed the same day with `CutsceneCapture.RecordingWriter`
(`make spike ARGS="writer"`, 3 s of synthetic 1080p60): HEVC compressed samples
pass through a nil-`outputSettings` `AVAssetWriterInput` into a fragmented
`.mov` and finalize to a faststart MP4 (`ftyp` → `moov` → `mdat`, tag `hvc1`);
`ffprobe` reports 180 frames, `has_b_frames=0`, keyframes at 0.000, 1.003 and
2.002 s (max gap 1.003 s), and with audio two AAC tracks (stereo system, mono
microphone). H.264 behaves the same. That settles research brief §8 Q15.

## Input telemetry

`InputTelemetryRecorder` samples `NSEvent.mouseLocation` and
`pressedMouseButtons` from an 8 ms `DispatchSourceTimer` and measured 125.0 Hz
(`make spike ARGS="telemetry 3"`). Lesson from the first attempt, which ran at
31 Hz: `NSCursor.currentSystem` carries four bitmaps and hashing all of them
every tick is too slow; hash only the smallest, on every other tick. First-call
costs worth knowing: `CGPreflightListenEventAccess` 13–19 ms per call (not
cached), the first `NSEvent.mouseLocation` 16 ms, the first `CGDisplayBounds`
29 ms. Clicks and keys come from a listen-only `CGEventTap` only when Input
Monitoring is already granted; otherwise button edges are derived from
`pressedMouseButtons`. The tap path is compiled and wired but not yet exercised
at runtime.

### System picker: `SCContentSharingPicker` (14.0)

`SCContentSharingPicker.shared` with a `SCContentSharingPickerConfiguration`:
`allowedPickerModes` (single window, multiple windows, single application,
multiple applications, single display), `excludedWindowIDs`,
`excludedBundleIDs`, `allowsChangingSelectedContent`. Observers receive
`didUpdateWithFilter:forStream:` and `didCancelForStream:`. No region mode, and
no customization of its look; useful as the window and display picker, with our
own overlay for area selection.

### Thumbnails: `SCScreenshotManager` (14.0)

`captureImage(contentFilter:configuration:)` (14.0) returns a `CGImage` and
`captureSampleBuffer(contentFilter:configuration:)` (14.0) a `CMSampleBuffer`;
`captureImage(in:)` is **15.2**, so it needs an `if #available` gate on the
15.0 floor (corrected 2026-11-02; an earlier revision listed it under 14.0).
The newer `captureScreenshot(...)` variants and `SCScreenshotConfiguration` are
macOS 26.0 only.

## AVFoundation and VideoToolbox

Verified against `AVVideoSettings.h`, `AVAssetWriter.h`, `AVAssetWriterInput.h`,
`AVVideoCompositing.h`, `VTCompressionProperties.h`, `CMSampleBuffer.h` and
the AVFoundation Swift interface (`usr/lib/swift/AVFoundation.swiftmodule/arm64e-apple-macos.swiftinterface`):

- `AVVideoCompressionPropertiesKey` "can also include keys from
  VideoToolbox/VTCompressionProperties.h". `AVVideoAverageBitRateKey`,
  `AVVideoMaxKeyFrameIntervalKey` and `AVVideoMaxKeyFrameIntervalDurationKey`
  are annotated "H.264 only"; `AVVideoProfileLevelKey` accepts VideoToolbox
  constants such as `kVTProfileLevel_HEVC_Main_AutoLevel`.
- `AVVideoColorPropertiesKey`: when set and the source buffers are tagged,
  "if necessary the source buffers will be color converted to match"; when not
  set, "the output will be tagged according to the source buffer color
  properties". `AVVideoTransferFunction_IEC_sRGB` is **15.0**; the 709, 240M,
  PQ, HLG and Linear (13.0) transfer constants are older.
- `AVAssetWriter.startSession(atSourceTime:)` "must be called after writing
  has started … but before any sample data is appended"; a sample at T plays
  at movie time T − startTime; earlier samples are written but edited out; an
  input whose first sample is later than the start gets "an empty edit … to
  preserve synchronization between tracks". `movieFragmentInterval` (default
  invalid = no fragments) makes an interrupted file playable "up to multiples
  of the specified time interval"; for external storage the header advises
  10 s or more; it cannot be set after writing starts.
- `AVAssetWriterInput.expectsMediaDataInRealTime` only ensures that
  `readyForMoreMediaData` "is calculated appropriately for real-time usage";
  it says nothing about the encoder's mode. The last sample's duration comes,
  in order, from a marker buffer carrying
  `kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration` (10.7), its own
  duration, or the previous sample's duration (AVAssetWriterInput.h:230).
- `AVVideoCompositing`: `sourceFrame(byTrackID:)`, `finish(withComposedVideoFrame:)`
  and `AVAssetWriterInputPixelBufferAdaptor` are `API_DEPRECATED(…,
  API_TO_BE_DEPRECATED)` in Swift, with no version; their replacements
  `sourceReadOnlyPixelBuffer(byTrackID:) -> CVReadOnlyPixelBuffer?`,
  `AVAssetWriterInput.PixelBufferReceiver` and
  `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)` are
  declared in the Swift overlay at **macOS 26.0** (interface lines 1171–1175
  and 1261–1266). This corrects the research brief's "adaptor deprecated at
  27.0": there is no hard version, and the 15.0 path stays valid.
  `supportsWideColorSourceFrames == false` makes the composition engine convert
  wide-gamut sources to BT.709 before calling the compositor;
  `canConformColorOfSourceFrames` is 12.0; `AVPlayerItem.seekingWaitsForVideoCompositionRendering`
  is 10.9; `AVAssetReaderVideoCompositionOutput` is 10.7.
- VideoToolbox: `kVTCompressionPropertyKey_RealTime` (10.9) "By default, this
  property is NULL, indicating unknown"; `MaximumRealTimeFrameRate` (15.0)
  "can only be used when kVTCompressionPropertyKey_RealTime has been set to
  true"; `MaxAllowedFrameQP` (12.0) "is not supported in all encoders or in
  all encoder operating modes. kVTPropertyNotSupportedErr will be returned".
- `AVCaptureSession.synchronizationClock`: "All capture output sample buffer
  timestamps are on the synchronizationClock timebase".
  `AVCaptureDeviceType.continuityCamera` needs the
  `NSCameraUseContinuityCameraDeviceType` Info.plist key from macOS 14.0.

## AppKit, Foundation and Swift

- `NSEvent.addGlobalMonitorForEvents`: "Key-related events may only be
  monitored if accessibility is enabled or if your application is trusted for
  accessibility access", events "are delivered asynchronously", and "your
  handler will not be called for events that are sent to your own
  application" (hence a local monitor as well).
- `NSWindow.sharingType = .none`: the window "will also not be able to
  participate in a number of system services, so this setting should be used
  with caution".
- `NSCursor.currentSystemCursor` is `API_DEPRECATED(…, API_TO_BE_DEPRECATED)`
  and "will always be `nil` in a future version of macOS"; the header points
  at `SCStreamConfiguration.showsCursor` and `NSCursor.currentCursor`
  (own-app only).
- `NSActivityLatencyCritical` "should be reserved for activities like audio or
  video recording".
- `Synchronization.Mutex` is macOS 15.0. The Swift overlay for AVFoundation and
  Dispatch lives under `MacOSX.sdk/usr/lib/swift/`, not inside the frameworks.
- Carbon's `RegisterEventHotKey` is exported by `HIToolbox.tbd` but declared in
  no header of the Command Line Tools SDK, so there is no global hotkey until
  an Xcode SDK is available.

## Permissions

| Capability                           | Mechanism                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------- |
| Screen and system audio capture      | Screen Recording (TCC). Check silently with `CGPreflightScreenCaptureAccess()` (10.15); prompt with `CGRequestScreenCaptureAccess()` (10.15) or the first `SCShareableContent` call. A grant only takes effect after the app relaunches |
| Microphone                           | `NSMicrophoneUsageDescription` + AVFoundation authorization               |
| Camera                               | `NSCameraUsageDescription` + AVFoundation authorization                   |
| Cursor position                      | No permission needed (`NSEvent.mouseLocation`, `CGEvent(source:)`)        |
| Clicks and keystrokes (event tap)    | Input Monitoring or Accessibility, depending on tap type. Check without prompting via `CGPreflightListenEventAccess` (10.15); request via `CGRequestListenEventAccess` (10.15) or `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt` (10.9) |

TCC ties grants to the bundle identifier and code-signing identity. Ad-hoc
signatures change on every build, so expect re-prompts during development until
a stable signing identity exists.

Observed on macOS 26.7 (2026-11-02, first launch of the placeholder app): the
`SCShareableContent` call raised the Screen Recording prompt; on Allow, tccd
wrote the access record and macOS offered "Quit & Reopen", because the running
process does not gain access. The relaunched process then called
`SCShareableContent` successfully. Onboarding must therefore treat "granted but
this process predates the grant" as its own state: detect it with
`CGPreflightScreenCaptureAccess()` after the user returns from System Settings
and offer a one-click relaunch.

The ad-hoc trap, observed the same day after the first code change: TCC had
stored the grant as `cdhash H"da1bb071…"`, the hash of the exact earlier build.
The rebuilt app hashed to `b4a44c24…`; tccd logged
`matchesCodeRequirement … cdhash` mismatches and prompted again, while System
Settings still showed Cutscene enabled (for the old hash), so toggling it did
nothing. Unstick either by turning the Cutscene switch off and on again in that
pane (macOS re-reads the bundle on disk and rebinds the grant to the current
build, then offers Quit & Reopen), or with
`tccutil reset ScreenCapture app.cutscene.Cutscene` followed by a relaunch and a
fresh allow; `scripts/bundle.sh` now does the reset itself whenever an ad-hoc
build's hash changes. Prevent it by signing with a stable identity
(`make dev-cert`): the stored requirement becomes identifier plus certificate
and survives rebuilds. Onboarding should recognise this state in development
builds: `CGPreflightScreenCaptureAccess()` false while the user insists it is
enabled.

With the self-signed "Cutscene Dev" identity (observed 15:56): the designated
requirement becomes `identifier "app.cutscene.Cutscene" and certificate leaf =
H"…"`, and tccd's first response to `CGRequestScreenCaptureAccess()` is to
create a record "Denied (System Set)" bound to that requirement while showing
the prompt; switching the app on in System Settings updates it to Allowed, and
because the requirement names the certificate rather than a build hash, every
later build matches it.

From the research brief (`docs/research/brief.md` §5.1, §8), not yet observed
here: on macOS 15 and later, apps that capture through an app-built
`SCContentFilter` rather than the system picker get a periodic "bypass the
system private window picker" alert (Apple has not published the interval;
Screen Studio, Cap and Reframed all take this path). Area capture has no picker
mode, so Cutscene will see it; onboarding copy must not promise "no monthly
prompt". Two more items to verify empirically: whether a listen-only
`CGEventTap` with mouse-only masks triggers the Input Monitoring prompt (only
keyboard events are documented as gated), and the replacement for
`NSCursor.currentSystem` for reading another app's cursor shape, which the
brief reports as deprecated at macOS 27 with no named successor.

Also observed: one second after launch the process preflighted
`kTCCServiceListenEvent` (Input Monitoring) on the main thread, with tccd
replying `preflight_unknown = true`, `auth_value = 1` (unknown) and no prompt.
Nothing in Cutscene requests it; a system framework does this on its own. It is
harmless, but it will appear in TCC logs and should not be mistaken for our
event-tap request.

## Metal and CoreVideo

- `MTLResource.h`: shared storage is "the default storage mode for iOS
  Textures"; managed storage "relaxes the coherency requirements" and needs a
  blit synchronization before the CPU reads GPU results. The header does not
  document shared textures for macOS at all, and `MTLDevice.hasUnifiedMemory`
  (10.15) is also true on Intel integrated GPUs, so `Compositor` creates its
  CPU-filled textures as managed (on Apple silicon that is one allocation).
- `CVMetalTextureCache.h:124`: `CVMetalTextureCacheFlush` "must be made
  periodically to give the texture cache a chance to do internal housekeeping
  operations"; textures otherwise age out after one second. `Compositor.flush()`
  exposes it for the end of a batch or a paused preview.
- `CVBuffer.h`: `CVBufferGetAttachment` is deprecated at macOS 12.0 in favour
  of `CVBufferCopyAttachment` (12.0), which the compositor uses to read
  `kCVImageBufferColorPrimariesKey`, `TransferFunctionKey`, `YCbCrMatrixKey`
  and `CGColorSpaceKey` per frame.
- `SCStream.h:287`: `SCStreamConfiguration.colorSpaceName` "If not set the
  output buffer uses the same color space as the display", so an unpinned
  stream on a Display P3 Mac delivers P3-encoded samples; the compositor
  refuses frames tagged for anything but sRGB / BT.709 and
  `StreamConfigurationBuilder` pins sRGB. `SCStream.h:262`: "By default the
  background color is clear", while `SCStream.h:21` says multi-window buffers
  are "default black"; the compositor composites BGRA sources premultiplied
  over the background, so both come out right.

## Click monitors

Spike S3 (`make spike ARGS="clicks 10"`, M1-07, 2026-11-03, the Command Line
Tools build run from a terminal). `ClickMonitors` installs
`NSEvent.addGlobalMonitorForEvents` and `addLocalMonitorForEvents` with the
six button masks plus `scrollWheel`; the header facts it is built on are in
the AppKit section above (global monitors skip our own application, so a
local one is needed; local monitors see only events dispatched through
`sendEvent`, not those consumed by control, menu or window-drag tracking
loops; delivery is asynchronous). `InputTelemetryRecorder` uses the monitors
between the tap and the poll, keeping the poll as a backstop: a poll edge
waits `monitorGracePeriod` (100 ms) for the monitors' copy before it is
written with the poll's stamp, and an edge the monitors delivered first is
recognized by button and time (`edgeMatchTolerance`, 50 ms) when the poll
notices the same change. The `InputTelemetryStatistics` fields
`clickMonitorsActive`, `pollEdgesSuperseded`, `pollEdgesWritten`,
`monitorDuplicatesDropped` and `monitorPollOffsetsSeconds` show which source
wrote what.

Observed with Input Monitoring not granted (`CGPreflightListenEventAccess()`
false) and Accessibility not trusted (`AXIsProcessTrusted()` false):

- Both monitors installed (non-nil tokens) and the recorder reported them
  active; the poll kept its 125.0 Hz beside them. Nobody clicked during the
  agent's run, so the human-click measurement (global delivery count against
  poll edges, clicks on the spike's own window and on its button, the
  monitor − poll-edge offset median against the 8 ms bound, the stamp
  difference on real events) is pending the lead's run from a reset TCC
  state.
- No prompt was requested. The unified log for the run (`/usr/bin/log show
  --predicate 'process == "tccd"'`) holds only `preflight=yes` checks of
  `kTCCServiceListenEvent` (ours, AppKit's own at `NSApplication` start,
  and the WindowServer's, which also appears during the telemetry spike) and
  of `kTCCServiceAccessibility` (ours; tccd: "does not allow prompting;
  returning Unknown"), and no request. After the first global monitor, later
  ListenEvent preflights for the binary answered `authValue=0, authReason=4`
  instead of `1, 5` (unknown), so tccd now holds a record for it; whether
  that lists the spike under Input Monitoring in System Settings, switched
  off, is for the lead to check.
- One unrelated line in the same log: `zOutlookPluginAgent` (Zoom's Outlook
  plug-in agent, installed on this Mac) asks tccd about Apple Events to the
  spike as soon as it registers as a GUI application ("Prompting for access
  to indirect object cutscene-spike by zOutlookPluginAgent"). It does not
  appear for the telemetry spike, which never creates `NSApplication`, and
  it would appear for any new app, so a dialog of that kind during the
  lead's run belongs to Zoom, not to the monitors.
- `NSEvent.timestamp` is the `CGEventTimestamp` base in seconds: for events
  converted either way (`NSEvent.mouseEvent(…timestamp:)` read back through
  `cgEvent.timestamp`, and `NSEvent(cgEvent:)` read back through
  `timestamp`) the two agree to the double's precision (0.00 ms skew on 3 of
  3), so `RecordingClock.hostTime(eventTimestamp:)` has an overload for each
  and neither applies an offset. `cgEvent` was non-nil for every event,
  including the AppKit-made ones, and `cgEvent.location` gives the Quartz
  global position without a window conversion.
- The local monitor is reachable without the window server: events posted
  with `NSApp.postEvent` reach it through a manual
  `nextEvent(matching:until:inMode:dequeue:)` + `sendEvent` loop (the spike's
  self-test, 3 of 3 seen: left down, left up, a precise scroll of −12 pt
  built from `CGEvent(scrollWheelEvent2Source:…)`). Posting to our own queue
  needs no permission; `CGEvent.post` would.
- The monitors need the application's event loop, so the recorder installs
  them only when `NSApp` exists (the telemetry spike has none and stays on
  the poll), on the main thread. A hop to the main thread from the capture
  queue goes through `RunLoop.main.perform(inModes: [.common])`, not the
  main dispatch queue: Swift's async `main` runs the run loop from inside a
  main-queue callback, and a run loop nested there (`NSApplication.run`
  called from a `MainActor.run` closure, as the spike does) does not drain
  the main queue until it returns, which also means no `Task` on the main
  actor runs during the spike's 10 s; the countdown is a run-loop `Timer`
  in the common modes and `NSApplication.stop` plus a posted
  `applicationDefined` event ends the loop.
- `NSApplication.activate()` from a `swift run` process does not activate it
  (cooperative activation since macOS 14; `isActive` was false at the start
  and the end of the run). The spike's window is `.floating` and ordered
  front regardless, so it is visible and the first click on it activates
  the process; the deprecated `activate(ignoringOtherApps:)` would warn and
  break the zero-warning build.

## Live session (spike S1)

`make spike ARGS="session …"` (M1-09, 2026-11-03). The agent's terminal had
neither Screen Recording nor Microphone granted (`CGPreflightScreenCaptureAccess`
false, `AVCaptureDevice.authorizationStatus(for: .audio)` notDetermined), so
every live mode exited 3 before any ScreenCaptureKit call and the facts
below come from the permission-free modes; the live facts are pending the
lead's run (see the task report for the commands).

- Crash recovery (`--crash-synthetic`: the `package` spike spawned by the
  session spike, `SIGKILL` 5 s after its `.needsFinalize` marker appeared,
  which is 0.3–0.4 s after launch): the fragmented `screen.mov` (1.4 MiB,
  2 s fragments) loaded in 14 ms with 4.100 s playable of the ~5.1 s
  captured, `RecordingWriter.finalize(fragmentedMovie:into:)` wrote the
  faststart MP4 in 30 ms (`ftyp → moov → mdat`, `hvc1`, `has_b_frames=0`,
  240 frames, keyframes every 1.000 s), and `frames.jsonl` read back whole
  (295 lines, the writer flushes it every second). The tracks end at their
  own last fragment: video at 4.100 s, both AAC tracks at 3.967 s, 133 ms
  earlier, so a recovered movie's audio is shorter than its video by up to
  one fragment and `RecoveryScanner` (M1-13) or the composition must expect
  that. Cursor sprites are written at stop only, so a killed take has an
  empty `cursors/` and every shape renders as the arrow after recovery;
  writing them at each telemetry flush would close that hole.
- A killed child's stdout is lost with it (a pipe is fully buffered; the
  package spike never flushes), which is why the harness triggers on the
  marker file rather than on an output line; the session spike flushes its
  own `recording:` line for the lead's eyes.
- Zero-tolerance seeks on the 10 s synthetic 1080p60 package, headless: an
  `AVPlayerItem` seek completes in 0.1 ms without a layer because nothing
  decodes; with an `AVPlayerItemVideoOutput` attached and the seek timed
  until the frame can be copied, the median is 10 ms (p95 27 ms); exact-time
  `AVAssetImageGenerator` decodes take 18 ms median, 29 ms max. The asset
  loads in 28 ms and the player item is ready after 188 ms. The frame the
  generator returns for a time inside a static stretch is the preceding
  hold, up to the heartbeat older; that is the VFR intermediate, not a
  tolerance failure. The 10-minute numbers (`--long 600`) are pending.
- The package spike's hand-written `project.json` predates `Project`
  (M1-03) and does not decode as one (`timeline.clips[0]` lacks `start`);
  a session's `project.json` goes through `ProjectStore`, so this concerns
  only synthetic packages.

## Preview playback (spike S2, player half)

`make spike ARGS="player <package> [--hold <seconds>]"` (M2-04, 2026-11-04,
M4 Pro, 10 s synthetic 1080p60 package from `make spike ARGS="package"`,
preview canvas 1920×1080 @ 60, the `preview.maxPixels` cap). The
composition from `CompositionBuilder` in an `AVPlayerLayer` window opened
from the CLI, `seekingWaitsForVideoCompositionRendering = true`, with every
request timed by a shell class around `MetalCompositor`; `--hold` keeps the
window playing afterwards. No permission is involved and nothing prompts.

- **Zero-tolerance seeks fire `startRequest`**: 12 seeks spread over the
  recording, each fired exactly one request, at the target time to the
  frame (the engine quantizes composition time to `frameDuration`). Seek
  call to rendered frame: median 13.1 ms, p95 22 ms, max 22 ms over two
  runs; the compositor's own render inside that is 0.8–2.6 ms. Both
  thresholds hold (§5 trigger 150 ms, editor bound 50 ms); the
  `AVPlayerItemVideoOutput` escalation is not needed. The first frame
  renders on its own once the item is ready (ready after 158 ms).
- **Paused re-render on `videoComposition` reassignment**: a paused item
  given a new `AVMutableVideoComposition` (same engine settings, new
  `RenderInstruction`s with a new style) re-renders its current frame by
  itself every time: 8 of 8 reassignments in two runs, median 1.5–2.1 ms
  and 4.4 ms at most from the assignment to the finished request, the
  request beginning about 1 ms after the assignment, at the paused time
  exactly. The forced seek was never needed; `PreviewView` keeps it as a
  watchdog (`reassignmentRenderTimeout`). The engine **reuses the same
  compositor instance** across reassignments when
  `customVideoCompositorClass` is unchanged, so the live-edit path pays no
  `MetalCompositor()` (2.4 ms with Metal's shader cache warm) and no
  warm-up. `AVPlayerItem.videoComposition` is `copy`, so the composition an
  item holds cannot be mutated in place; a reassignment is the path, and
  the assignment call itself is 0.1–0.7 ms on the main thread.
- **Preview equals export**: the frame the player shows at a time (through
  a temporarily attached `AVPlayerItemVideoOutput`) and the frame an
  `AVAssetReaderVideoCompositionOutput` renders at the same time are
  byte-identical (FNV-1a of the 1920×1080 BGRA pixels agrees).
- **Two instances do not serialize**: the export's read side (an asset
  reader pulling the composition at full speed: 600 frames in 0.94–1.00 s,
  compositor busy 64 % of the wall) ran alongside the player playing
  (one request per displayed frame). With the two together the player kept
  97 % of its 60 fps cadence at 1.1 ms median render, the reader lost
  34–81 ms over a second (the GPU is one device), and the 50 reader
  requests that overlapped a player request took only +0.2 ms over the
  rest (1.1–1.2 vs 1.0 ms), where a shared lock would add about half the
  player's render (0.6 ms). Directly, two `Compositor`s rendering 120
  1080p frames each took 0.069–0.075 s alone and 0.049–0.051 s both at
  once from two threads, less than either alone (the GPU clocks up), so
  `preview.pauseDuringExport` stays off.
- The player made one request per displayed frame while playing (177–178
  in 3.04 s, 97 % of 60 fps) and no request was held, blank or failed
  across the run (392–396 requests in all).
- **Running AppKit from the spike's async `main`**: the async entry point is
  one block on the main dispatch queue, so `NSApplication.run()` called
  from inside it drains no further main-queue block, and neither a
  main-actor task nor `AVPlayerItem.status` (delivered through the main
  queue) ever arrives; the item stays `.unknown`. Pumping events by hand
  through `nextEvent(matching:until:inMode:dequeue:)` under the entry
  point's own `CFRunLoopRun` instead makes that run loop return, after
  which the runtime calls `exit(0)`. What works: the entry task suspends on
  a continuation (freeing the queue) and `NSApp.run()` starts from a
  `RunLoop.main.perform` block, where the loop drains the main queue as in
  any AppKit app; the measurements run as a main-actor task underneath,
  and `NSApp.stop(nil)` plus a posted `.applicationDefined` event ends the
  loop and resumes the continuation.
- In this SDK's overlay `AVPlayerItem` and `AVPlayer` are `NS_SWIFT_UI_ACTOR`;
  `init(asset:)`, `videoComposition` and `audioMix` are main-actor
  isolated, while `status`, `seek`, `currentTime`, `customVideoCompositor`,
  `seekingWaitsForVideoCompositionRendering` and the output add/remove are
  `NS_SWIFT_NONISOLATED` (`videoComposition` becomes nonisolated only when
  deploying to the 2025 releases).

## Toolchain

- The Command Line Tools build every target but ship neither `XCTest` nor the
  Swift `Testing` module; `swift test` needs Xcode.
- The Command Line Tools have no Metal shader compiler (`xcrun metal`). Until
  Xcode is standard, shaders compile at runtime from source through
  `MTLDevice.makeLibrary(source:options:)`.
- `swift format` 6.2.3 is available and configured via `.swift-format`.

## Window capture

Spike S4 (`make spike ARGS="window own"`, M2-06, 2026-11-04, macOS 26.7 on
the built-in 1512×982 pt Retina display at 2×, run unattended while the
lead was using the Mac; `window <title>` is the lead's run on another
application's window). The spike's own 640×432 pt window, captured 10 s
under each `CaptureRequest.WindowStrategy` through the session's pipeline
pieces into a `.cutscene` package, with a popup menu at 3 s, an `NSPopover`
(child window) from 5 s to 7 s, a 160×120 pt move at 7.2 s and a +120×+80 pt
resize at 8.5 s; then each package through `ContentMapper`, `RenderPlan`,
`CompositionBuilder` and `MetalCompositor` to PNGs whose lit area inside the
card is measured against the recorded `boundingRect`. Logs and PNGs land
under `$TMPDIR/cutscene-spike/window/`.

- **`.displaySurface`** (`SCContentFilter(display:including: [window])`,
  `includeChildWindows = true`, `ignoreShadowsDisplay = true`): the stream
  is the display's size (3024×1964 px) with the window on black. Every
  sample carries `contentRect` and `screenRect` equal to the whole display
  and a `boundingRect` in display points that is the window's frame
  (436, 143, 640×432) and **grows with the menu** (640×509: the four-item
  popup menu hangs 77 pt below the window) **and the popover** (416, 143,
  660×602: the popover is wider than the window and hangs below it) and
  **follows the move and the resize** (596, 263, 640×432 then 760×512):
  24–26 `boundingRect` changes in the take, written sparsely by
  `FrameIndexWriter`. The PNGs show the menu and the popover rendered over
  the black surface (menu translucency shows black, since nothing else is
  on the surface); the lit area of the card grew 4.6 % with the menu and
  15 % with the popover, and the lit box matched the recorded
  `boundingRect` within one probe cell after the move and the resize. The
  menu is dismissed by any click elsewhere, so the unattended menu finding
  needs the pointer left alone for its 1.5 s. A moving window therefore
  needs no poll on this strategy: the per-frame rect is the crop's input
  and `ContentMapper` already followed it in the PNGs (M2-02 and M2-03
  landed during this task, so the reader path applied the crop).
- **`.pinnedFrame`** (the same filter with `sourceRect` = the frame at
  start, 1280×864 px): `contentRect` and `boundingRect` are surface-local
  (0, 0, 640×432) and `screenRect` is the frame's place on the display.
  After the move the `boundingRect` shrank to the part of the window still
  inside the frame (160, 120, 480×312), as predicted: the window leaves the
  frame. The menu and the popover, which hang below the window, were
  clipped by the source rect and never appeared (lit area unchanged), so
  child windows are shown only where they overlap the pinned frame.
- **`.independentWindow`** (`SCContentFilter(desktopIndependentWindow:)`,
  `scalesToFit = false`, `preservesAspectRatio = true`, 1280×864 px):
  `contentRect` and `boundingRect` are the window itself (0, 0, 640×432);
  `screenRect` **follows the window on screen** (596, 263 after the move,
  760×512 after the resize) while the output stays the size it was
  configured with, so the enlarged window is **scaled down** to fit
  (content 640×431.2: a sliver of letterbox from the aspect). Neither the
  menu nor the popover appeared, as the header says. This stream reported
  **no idle frames at all** (372–423 content frames out of as many samples
  against 366–390 content plus 140–200 idle on the display-bound streams),
  so a static window still costs a frame per interval here.
- **File size** at HEVC `balanced`: display surface 536–552 KiB (449–486
  kbit/s at 3024×1964), pinned frame 325–356 KiB (266–292 kbit/s at
  1280×864), independent window 875–928 KiB (717–973 kbit/s at 1280×864,
  every sample a content frame). The black surface costs about a third more
  than the pinned frame, not the five times its pixel count suggests, which
  is what ARCHITECTURE §2 assumed.
- **Default strategy**: the measurements agree with ARCHITECTURE §2:
  `.displaySurface` stays the default. It is the only strategy that
  captures menus and popovers (the independent window never does, the
  pinned frame only inside the frame), its `boundingRect` gives the crop a
  per-frame target through moves, resizes and child windows, and its size
  cost is modest. DECISIONS.md gets the entry from M2-11.
- **`WindowGeometryPoller`** (`CGWindowListCopyWindowInfo`, 10 Hz in window
  scope): 98–100 ticks in 10 s, the first call 290–305 ms (the window
  server connection), every later one 0.6–2.7 ms median; 3–5 events for a
  move and a resize plus the first sighting. The bounds the list reports
  are the frame without shadow, equal to `SCWindow.frame`, and the
  `boundingRect` of a `.displaySurface` sample (which excludes shadows with
  `ignoreShadowsDisplay`). On one take the lead switched Spaces mid-take:
  the list then put the window at x = 5185 (its position on the inactive
  Space, offset by whole displays) and the poll wrote 24 events, so a
  consumer of `geometry` events must expect frames outside the display
  while a window is on another Space.
- **`FocusMonitor`** (`NSWorkspace.didActivateApplicationNotification`):
  one initial observation per take (the frontmost application at start,
  with its frontmost ordinary window from the window list) and one per
  activation; the notification carries no stamp, so events are stamped at
  delivery.
- **A spike window from a `swift run` process and Spaces**: with a
  full-screen Space in front, a plain `NSWindow` of a process that cannot
  activate itself (`activate()` is cooperative) lands on the desktop Space
  even with `canJoinAllSpaces` and `fullScreenAuxiliary`:
  `isOnActiveSpace` false, absent from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
  and from `SCShareableContent`, so a capture of it fails with
  `windowNotFound`. A **non-activating `NSPanel`** (`.nonactivatingPanel`,
  `hidesOnDeactivate = false`, the same collection behaviour) joins the
  active Space at once and is listed. The window also needs a few run-loop
  turns after `orderFront` before ScreenCaptureKit lists it; the spike
  retries the listing at 100 ms for up to 3 s.
- **Ending an AppKit spike from its async entry point**: `NSApplication.stop`
  also ends the run loop the async `main` waits in, after which the Swift
  runtime exits 0 at once, before buffered stdout is flushed and whatever
  the verdict was (a failing run exited 0 and lost its summary). A spike
  that runs its work as a main-actor task under `NSApp.run()` must print
  its verdict, `fflush(stdout)` and `exit` from inside that task.
