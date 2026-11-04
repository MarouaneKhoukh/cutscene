# Cutscene v1 architecture

Final design, produced by the architecture panel on 2026-11-02 from three
proposals and three judges' scorecards, then revised after adversarial review
(two reviewers, 2026-11-02). It starts from the judges' winner (the "platform
does the work" plan), grafts the ideas two or more judges asked for, fixes
every error a judge or reviewer found, and keeps the user's priority: **use it
locally as soon as possible**.

Every API claim below was checked against the headers in
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (macOS 26.2 SDK, Swift
6.2.3) or is already listed in [`platform-notes.md`](platform-notes.md). Facts
I could not confirm are marked **unverified**. Every numeric default is a
**tunable**: it lives in the brand kit or in `EngineDefaults`, never as a
literal in render or capture code, so the running research sweep can retune
without code changes.

Verified in this pass (new, to be folded into platform-notes.md by task 0.8):

- `SCRecordingOutputConfiguration` exposes only `outputURL`, `videoCodecType`,
  `outputFileType` (plus the two `available…` lists); `SCRecordingOutput` has
  `recordedDuration` and `recordedFileSize`. `addRecordingOutput(_:)` must be
  called before `startCapture()` to guarantee the first sample is written, only
  one recording output per stream, and a configuration update mid-recording
  stops the recording. HDR + recording output fails by design.
- `SCStream.synchronizationClock` (13.0, nullable). `SCStreamFrameInfoDisplayTime`
  is "the mach absolute time … when the frame was displayed by the window
  server"; `ContentRect` (12.3) is "size and location of content in points in
  surface"; `ScreenRect` (13.1) is "the onscreen location of the captured
  content"; `BoundingRect` (14.0) is "the smallest bounding box containing all
  captured windows in points and in surface coordinates"; `ScaleFactor`,
  `ContentScale`, `Status` (12.3).
- `SCStreamConfiguration.queueDepth` default is 8 and "should not exceed 8";
  `minimumFrameInterval` default 1/60, `kCMTimeZero` = native refresh;
  `sourceRect` is in points in the display's logical coordinate system;
  `scalesToFit` true scales up and down, false only down; `colorMatrix` applies
  to 420v/420f only; `backgroundColor` "by default … is clear".
  `streamDidBecomeActive/Inactive` are **15.2** (gate them).
  `SCStream.updateConfiguration(_:)` and `updateContentFilter(_:)` exist for
  mid-stream changes.
- **Window filters.** `includeChildWindows` (14.2) is "SCStreamProperty to show
  the child windows in display bound windows and applications sharing. Child
  windows are included by default" (SCStream.h:353). `initWithDesktopIndependentWindow`
  "captures just the independent window passed in" (SCStream.h:144) and
  `includeMenuBar` "has no effect for the desktop independent window filter"
  (SCStream.h:122); for `initWithDisplay:including` filters `includeMenuBar`
  defaults to NO. With window-bound display filters "the width and height will
  be that of the display passed in for the filter" and the background is
  black by default, settable through the configuration (SCStream.h:21).
- `SCContentFilter.includedWindows` / `includedApplications` are **15.2**, so
  the system picker's result cannot be read back on the 15.0 floor; v1 uses its
  own picker over `SCShareableContent`. `SCScreenshotManager.captureImage(in:)`
  is 15.2 (platform-notes lists it under 14.0; `captureImage(contentFilter:configuration:)` is 14.0).
- `SCError`: `userDeclined` −3801, `userStopped` −3817,
  `failedToStartMicrophoneCapture` −3820 (15.0), `systemStoppedStream` −3821 (15.0).
- `AVVideoCompositing`: `sourceFrame(byTrackID:)` carries a Swift-only
  `API_TO_BE_DEPRECATED` note (no warning today). Its replacement
  `sourceReadOnlyPixelBuffer(byTrackID:) -> CVReadOnlyPixelBuffer?` **is
  declared in the AVFoundation Swift overlay at macOS 26.0**
  (`AVFoundation.swiftmodule/arm64e-apple-macos.swiftinterface:1171-1175`), as
  are `AVAssetWriterInput.PixelBufferReceiver` (26.0, :1239-1242) and
  `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)` (26.0,
  :1266). On the 15.0 floor v1 uses `sourceFrame(byTrackID:)` and
  `AVAssetWriterInputPixelBufferAdaptor`; the 26.0 APIs are an
  `if #available(macOS 26, *)` optimization branch later, nothing more.
  `supportsWideColorSourceFrames == false` makes the composition engine convert
  wide-gamut sources to BT.709 before calling us; `canConformColorOfSourceFrames`
  (12.0); `renderContext.newPixelBuffer()`; requests are only re-entered if
  `startRequest` returns before finishing.
- `AVVideoComposition.customVideoCompositorClass` (10.9),
  `sourceTrackIDForFrameTiming` (10.13; `kCMPersistentTrackID_Invalid` plus
  `frameDuration` "to specify the maximum output frame rate independent of the
  source track timing"), `AVPlayerItem.seekingWaitsForVideoCompositionRendering`
  (10.9). The composition's `colorPrimaries/colorYCbCrMatrix/colorTransferFunction`
  "are also used to specify the required color space of the source frames" for
  custom compositing (AVVideoComposition.h:129), and the header's recipe for
  preserving the source colour space is to copy the source track's triple.
- `AVAssetWriter.startSession(atSourceTime:)` "must be called after writing has
  started (using -startWriting) but before any sample data is appended"; movie
  time = T − startTime; samples earlier than startTime are written but edited
  out; a track whose first sample is later than startTime gets an empty edit
  "to preserve synchronization between tracks". `endSession(atSourceTime:)`
  edits out later samples and may create an empty edit; without it the session
  ends at the latest appended sample. `movieFragmentInterval` makes an
  interrupted file playable up to the last fragment. `cancelWriting()` deletes
  the file.
- `AVAssetWriterInput`: for non-audio tracks every sample's duration is the DTS
  difference to the next sample; the **last** sample's duration comes from (1) a
  marker sample with `kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration`,
  else (2) its own valid duration, else (3) the second-to-last sample's duration
  (AVAssetWriterInput.h:229-232). `expectsMediaDataInRealTime` only ensures
  "that readyForMoreMediaData is calculated appropriately for real-time usage";
  it says nothing about the encoder's rate-control mode. LPCM output settings
  must include all relevant `AVLinearPCM*Key`s; `AVNumberOfChannelsKey > 2`
  requires `AVChannelLayoutKey`.
- CoreMedia: `kCMSampleBufferAttachmentKey_EmptyMedia`, `…PermanentEmptyMedia`,
  `…EndsPreviousSampleDuration` (all 10.7); `CMSampleBufferCreate` accepts
  `numSamples == 0` (marker buffers); `CMSampleBufferCreateCopyWithNewTiming`.
  The host time clock is `mach_absolute_time()`; `CMSyncConvertTime`,
  `CMClockMakeHostTimeFromSystemUnits`. `CMSampleBufferRef` and `CVPixelBufferRef`
  are `@_nonSendable` in Swift (they never cross an isolation boundary here).
- `AVVideoSettings.h`: `AVVideoCompressionPropertiesKey` "can also include keys
  from VideoToolbox/VTCompressionProperties.h"; `AVVideoAverageBitRateKey`,
  `AVVideoMaxKeyFrameIntervalKey/DurationKey` are annotated "H.264 only";
  `AVVideoProfileLevelKey` accepts VideoToolbox profile constants;
  `AVVideoEncoderSpecificationKey` (10.10) is a top-level key. Even dimensions
  are required for 4:2:0. **Colour:** if `AVVideoColorPropertiesKey` is set and
  the source buffers are tagged, "if necessary the source buffers will be color
  converted to match" (:152); if it is not set, "the output will be tagged
  according to the source buffer color properties" with no conversion (:156).
  Transfer constants: 709, 240M, PQ, HLG, Linear (13.0), `IEC_sRGB` (**15.0**).
  CoreVideo has `kCVImageBufferTransferFunction_sRGB` (10.13).
- VideoToolbox: `kVTCompressionPropertyKey_RealTime` (10.9) "By default, this
  property is NULL, indicating unknown"; `MaximumRealTimeFrameRate` (15.0) "can
  only be used when kVTCompressionPropertyKey_RealTime has been set to true";
  `AverageBitRate`, `DataRateLimits`, `MaxKeyFrameInterval`,
  `MaxKeyFrameIntervalDuration`, `AllowFrameReordering`, `ExpectedFrameRate`,
  `ConstantBitRate` (13.0), `MaxAllowedFrameQP` (12.0, "not supported in all
  encoders"), `kVTProfileLevel_HEVC_Main_AutoLevel`,
  `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`.
- AVCapture: `AVCaptureSession.synchronizationClock`; `AVCaptureDevice(uniqueID:)`
  (class 10.7), `activeFormat.formatDescription` (so a microphone's channel
  count is known before capture starts); `AVCaptureDeviceType.external`,
  `.continuityCamera` (14.0, needs `NSCameraUseContinuityCameraDeviceType`);
  `recommendedVideoSettings(forVideoCodecType:assetWriterOutputFileType:)` (10.15).
  `AVCaptureVideoDataOutput`: "If multiple sample buffers reference such pools of
  memory for too long, inputs will no longer be able to copy new samples into
  memory and those samples will be dropped" (never retain camera buffers).
- AppKit: `NSEvent.addGlobalMonitorForEvents` needs Accessibility only for key
  events, delivers asynchronously, and is not called for our own app's events
  (hence a local monitor too). `NSWindow.sharingType = .none` carries a header
  caution. `NSCursor.currentSystemCursor` "will always be nil in a future
  version of macOS". `NSView.displayLink(target:selector:)` (14.0).
- Foundation/CG: `NSActivityLatencyCritical` is documented for "audio or video
  recording"; `volumeAvailableCapacityForImportantUsageKey` (10.13);
  `CGPreflight/RequestScreenCaptureAccess`, `CGPreflight/RequestListenEventAccess`
  (10.15); `CGEventTimestamp` is "roughly, nanoseconds since startup".
- Swift: `Synchronization.Mutex` is macOS 15.0; `DispatchSerialQueue` conforms
  to `SerialExecutor`; `Actor.assumeIsolated`. SwiftUI: `MenuBarExtra`,
  `Settings`, `WindowGroup(id:for:)`, `openWindow(value:)`; `Window` takes no value.
- Metal: `makeLibrary(source:options:)`, `MTLCompileOptions.mathMode`
  (replaces `fastMathEnabled`, deprecated at 15.0), `MTLBinaryArchive` (11.0).
- Carbon `RegisterEventHotKey` is exported by `HIToolbox.tbd` but has no header
  in this SDK: no global hotkey in v1.

Unverified and tracked by spikes (section 9): the clock base of
`NSEvent.timestamp`; whether `SCRecordingOutput` starts its movie at the first
video or the first audio sample and whether its video track ends at the last
changed frame; the colour attachments ScreenCaptureKit puts on 420v buffers
pinned to `kCGColorSpaceSRGB`; whether VideoToolbox rate-control keys passed
through `AVAssetWriter` take effect for HEVC; whether a compressing
`AVAssetWriterInput` honours an `EndsPreviousSampleDuration` marker; whether a
retimed copy of an SCK sample buffer may be appended while the original surface
is pooled; load and scrub cost of a fragmented `.mov`; `MaxAllowedFrameQP`
support on the M4 Pro HEVC encoder; retaining a request's source pixel buffer
after `finish`; whether `includeChildWindows` covers menus, popovers and sheets
for `display:including:` filters; the periodic "bypass the system private
window picker" alert reported by the research brief.

---

## 1. App structure

**Process model.** One process, one SwiftPM executable, assembled by
`scripts/bundle.sh`. The app is a menu-bar agent (`LSUIElement = true`) that
flips to `NSApp.setActivationPolicy(.regular)` while an editor window is open
(Dock icon, Cmd-Tab) and back to `.accessory` when the last editor closes.
*Why:* record without a window in the way, edit in a normal document window.
*Rejected:* an XPC recorder helper (capture has no UI dependency; crash safety
comes from the on-disk formats in section 3) and a Dock-only app.

**Scenes** (`Sources/Cutscene/CutsceneApp.swift`):

```swift
@main struct CutsceneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()
    var body: some Scene {
        MenuBarExtra("Cutscene", systemImage: app.recorder.isRecording ? "record.circle.fill" : "record.circle") {
            MenuBarMenu(app: app)      // Record Display / Window / Area…, Stop Recording, Open Last Recording, Recent, Export Last Recording (1080p), Settings…, Quit
        }.menuBarExtraStyle(.menu)
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in EditorWindow(app: app, packageURL: url) }
        Settings { SettingsView(app: app) }
    }
}
```

The editor opens with `openWindow(value: packageURL)`. *Rejected:* a `Window`
scene "opened with a URL" (a `Window` takes no value) and
`DocumentGroup`/`FileDocument` (loads packages through `FileWrapper` into
memory, wrong for gigabyte media).

**Recording HUD.** `HUDPanel: NSPanel` with `styleMask = [.nonactivatingPanel,
.borderless]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary, .stationary]`, `hidesOnDeactivate = false`,
`isMovableByWindowBackground = true`, SwiftUI content via `NSHostingView`. Idle:
mode segmented control (Display / Window / Area), source popup, mic and camera
toggles with device menus, system-audio toggle, Record. Recording: collapses to
a pill with elapsed time, dropped-frame count, free disk, Stop. The countdown
overlay and the area-selection overlays (one borderless panel per `NSScreen` at
`.screenSaver` level) are panels too. All of them are kept out of the capture by
**excluding our application** in display and area mode
(`SCContentFilter(display:excludingApplications: [ourSCRunningApplication],
exceptingWindows: [])`), which also covers windows created after the stream
started; window mode uses including filters, which never contain our windows.
`sharingType` stays at its default. *Rejected:* `sharingType = .none` (header
caution, redundant) and window-ID exclusion (misses later windows unless
`updateContentFilter` is called on every panel). The menu-bar menu carries
**Record Display** and **Stop Recording** items from the first build (task
0.6a), so recording works before the HUD exists (0.6b).

**Editor window.** Preview (`AVPlayerLayer` in an `NSViewRepresentable`),
transport bar with scrubber and trim handles, right-hand inspector (Style,
Cursor, Zoom, Camera, Audio, Export button). One editor window per package;
recording and export are mutually exclusive (Record disabled while an export
runs and vice versa; preview pauses while recording). Preview and export are
*not* mutually exclusive; section 5 keeps them from contending on the GPU.

**No global hotkey in v1.** `RegisterEventHotKey` has no header in the CLT SDK
and `NSEvent` key monitors need Accessibility. Stop is the menu-bar item or the
pill. `Support/HotKey.swift` is a v1.1 item once Xcode's SDK is available.

**State ownership.**

| Owner | Type | Holds |
| --- | --- | --- |
| `AppModel` | `@MainActor @Observable final class` | permission states, recent packages, recorder controller, settings |
| `RecorderController` | `@MainActor @Observable final class` | state machine `idle → selecting → countdown(n) → recording(status) → finishing → done(url) / failed(error, partialURL)`; owns one `CaptureSession` per recording and the HUD panels |
| `EditorModel` | `@MainActor @Observable final class` | the `Project` value, `UndoManager` (value snapshots of `Project`), `AVPlayer`, the current `RenderPlan` (built off the main actor, latest wins), dirty flag, debounced atomic save **only after an edit** |
| `CaptureSession` | `actor` (Capture) | `SCStream`, the active `CaptureSink`, `InputTracker` + `EventLog`, `CameraRecorder`, `DiskSpaceMonitor`; publishes `AsyncStream<CaptureStatus>` |
| `Exporter` | `actor` (Export) | `AVAssetReader` → `AVAssetWriter` loop; publishes `AsyncThrowingStream<ExportProgress, Error>` |
| `RenderContext` | `final class, Sendable` (Render) | **immutable after creation**: `MTLDevice`, runtime-compiled library, pipeline states; a `Mutex` guards only lazy creation |
| `CompositorScratch` | per `MetalCompositor` instance (Render) | its own `MTLCommandQueue`, `CVMetalTextureCache`, mip texture, hold-last-frame texture, uniforms ring |
| `MetalCompositor` | `final class: NSObject, AVVideoCompositing` | instances created by AVFoundation; owns one `CompositorScratch` |

**Swift 6 strict-concurrency model.**

- *Values cross boundaries, objects do not.* Everything in CutsceneCore and
  CutsceneEngine is a `Sendable` value type. `CMSampleBuffer`, `CVPixelBuffer`,
  `MTLTexture`, `AVPlayer` never leave their owner.
- *The capture actor runs on the capture queue.* `CaptureSession` is an actor
  whose `unownedExecutor` is `queue.asUnownedSerialExecutor()` for a
  `DispatchSerialQueue(label: "app.cutscene.capture", qos: .userInteractive)`.
  The same queue is passed to `SCStream.addStreamOutput(_:type:sampleHandlerQueue:)`.
  `StreamOutputShim: NSObject, SCStreamOutput, @unchecked Sendable` forwards each
  sample synchronously with `session.assumeIsolated { $0.handle(sampleBuffer, type) }`:
  zero hops, zero copies, and the sample buffer never escapes the actor.
  `SampleWriter` and `EventLog` are plain classes confined to that actor.
  `SCStreamDelegate` and `SCRecordingOutputDelegate` callbacks that arrive on
  other queues post `Sendable` events with `Task { await session.streamStopped(error) }`.
- *Camera samples* arrive on their own serial queue; `CameraRecorder` is an
  actor with the same executor trick and its own `SampleWriter`.
- *Click and scroll monitors* run on the main thread and hop into the capture
  actor (`Task { await session.record(event) }`). Actor hops are not FIFO
  across tasks, so **`events.jsonl` is append-ordered, not time-ordered**; the
  reader sorts stably (section 3).
- *Hot render state is per instance.* Each compositor instance owns its scratch
  and waits on its own command buffers; the only shared render objects are
  immutable (device, library, pipelines), so no lock is held around a GPU wait.
- *UI is `@MainActor`.* Actors push status through `AsyncStream`, consumed in `.task {}`.
- *Editing* rebuilds an immutable `RenderPlan` with a `nonisolated` pure Engine
  function returning `sending RenderPlan`, awaited from `EditorModel` with
  latest-wins coalescing and a 50 ms debounce on continuous controls; the
  previous plan stays on screen until the new one lands, then a new
  `AVVideoComposition` is assigned. Cost is **tens of milliseconds for a
  10-minute trace (estimate: 144k steps at 240 Hz, ~43 Gaussian taps, spring
  and clamp per step; measured by `cutscene-tool plan bench`)**, which is why it
  never runs on the main actor. Only kept ranges are precomputed.

---

## 2. Capture pipeline

**Principle.** The capture path owns no pixel code and no encoder code of its
own beyond configuring `AVAssetWriter` (the existing `VideoEncoder` stays as a
measured alternative, see `SampleWriter`). ScreenCaptureKit delivers hardware
IOSurface frames plus system audio and microphone on one clock; our code
records metadata (cursor, clicks, geometry, per-frame display times) into
append-only JSONL files and hands sample buffers to a `CaptureSink`.

### Stream configuration

Common (`StreamConfigurationBuilder`): `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
('420v', straight into the HEVC encoder; tunable `capture.pixelFormat`, BGRA
for debugging), `colorSpaceName = kCGColorSpaceSRGB`,
`colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2`, `showsCursor = false`
(we draw the cursor), `showMouseClicks = false`, `captureResolution = .best`,
`captureDynamicRange = .SDR`, `queueDepth = 8`, `minimumFrameInterval =
CMTime(value: 1, timescale: 60)` (tunable 30/60; `kCMTimeZero` for native
refresh later), `presenterOverlayPrivacyAlertSetting = .never`,
`capturesAudio = request.systemAudio`, `excludesCurrentProcessAudio = true`,
`sampleRate = 48_000`, `channelCount = 2`, `captureMicrophone = request.microphoneID != nil`,
`microphoneCaptureDeviceID = request.microphoneID` (an `AVCaptureDevice.uniqueID`).

| Mode | Filter | Output size (pixels) | Mode-specific |
| --- | --- | --- | --- |
| Display | `SCContentFilter(display:excludingApplications: [us], exceptingWindows: [])` | `display.width/height` points × `pointPixelScale` | `includeMenuBar` (14.2) per setting, default true |
| Window (default strategy `.displaySurface`) | `SCContentFilter(display:including: [window])`, a **display-bound** filter, so `includeChildWindows` applies and defaults to YES (menus, popovers and sheets that SCK treats as child windows are captured; **unverified** for menus, S4) | the display's size (SCStream.h:21); the surface is black outside the window, so static area compresses to almost nothing | `includeMenuBar = request.includeMenuBar` (default false in this mode), `ignoreShadowsDisplay = true` (we draw our own), `backgroundColor` left clear/black; per-frame `BoundingRect`/`ContentRect` recorded in `frames.jsonl`; the engine crops the card to the window rect (`ContentMapper`), so moving and resizing the window works by construction |
| Window, strategy `.pinnedFrame` | same filter + `sourceRect` = window frame at start (display-local points), size = frame × scale rounded to even | fixed for the recording | smaller files; a window that moves or grows leaves the frame (the "keep the window still" warning); child windows outside the frame are clipped; S4 may promote this to default if `.displaySurface` costs too much |
| Window, strategy `.independentWindow` | `SCContentFilter(desktopIndependentWindow:)` | window frame × scale, even, fixed; `scalesToFit = false`, `preservesAspectRatio = true` (14.0), `ignoreShadowsSingleWindow = true`, `shouldBeOpaque = false` | explicit "this window only, even when occluded or on another Space" option; **no menus or popovers** (`includeChildWindows` has no effect here); exposed in the picker as an advanced choice |
| Application (v1.1 option) | `SCContentFilter(display:including: [app], exceptingWindows: [])` | display size | every window of one app, menus included regardless of child-window semantics; same geometry path as `.displaySurface` |
| Area | display filter as above + `sourceRect` (points, display-local) | rect × scale, rounded down to even; the overlay snaps the selection to even pixels | the output rect stays fixed for the recording |

Our app is excluded by application in display and area modes; including
filters never contain it. The manifest stores `source: .window(id, title,
bundleID, frame, strategy)` so the engine knows which geometry path applies.

### Outputs and the frame index

`.screen` always, `.audio` (13.0) when system audio is on, `.microphone` (15.0)
when a mic is chosen, all through `addStreamOutput` on the capture queue. On
every screen sample `ScreenFrameIndexer` reads the attachments and appends a
line to `frames.jsonl`: frame number, PTS and `SCStreamFrameInfoDisplayTime`
(converted with `CMClockMakeHostTimeFromSystemUnits`) relative to `t0`,
`Status`, and `ContentRect`/`ContentScale`/`ScaleFactor`/`ScreenRect`/`BoundingRect`
whenever they change. Frames whose status is not `.complete` or `.started` are
counted (`idleFrames`) and not written to the movie: the intermediate is
variable-frame-rate by design. **The static tail and long static stretches are
covered explicitly** (reviewer finding): see "Idle heartbeat and end marker"
under `SampleWriter`. *Why:* display time is 1–2 frames before delivery time,
and aligning clicks to what was on screen is the most visible sync error in
competing tools; the per-frame geometry is what makes window-mode cursor
mapping exact. *Rejected:* a binary frame index (not diffable; JSONL costs
~4 MB per 10 minutes).

### `CaptureSink`: own `AVAssetWriter` as the v1 path, `SCRecordingOutput` as bootstrap and fallback

```swift
public protocol CaptureSink: AnyObject {           // confined to the CaptureSession actor
    func attach(to stream: SCStream, configuration: SCStreamConfiguration, package: RecordingPackage, audio: AudioInputPlan) throws
    func handle(_ sample: CMSampleBuffer, type: SCStreamOutputType, hostPTS: CMTime)   // no-op for the recording output
    func tick(now: CMTime)                           // idle heartbeat hook, called from the capture queue timer
    func finish(at stopTime: CMTime) async throws -> ScreenTrackInfo   // waits for the file to be finalized
}
public final class RecordingOutputSink: CaptureSink { … }   // SCRecordingOutput; M0 bootstrap, permanent fallback
public final class AssetWriterSink: CaptureSink { … }       // SampleWriter; default from M1
```

**Decision.** `AssetWriterSink` writes `recording/screen.mov` with our own
`AVAssetWriter` (`SampleWriter`): HEVC with VideoToolbox rate control, no
B-frames, 1 s keyframes, 2 s fragments, the session started at `t0`, and
microphone and system audio as two separate LPCM tracks.
`RecordingOutputSink` (the code that already runs in `RecordingSpike.swift`)
ships in M0 so the team records within the first week, and stays selectable
(`CaptureRequest.sink = .recordingOutput`) as the fallback. *Why:* the
repository's own `ffprobe` observation of `SCRecordingOutput` (platform-notes)
shows B-frames, no keyframe or bitrate control, and mic and system audio mixed
into one AAC track, which blocks independent levels and clean speech for later
transcript editing; the file-time-to-host-time mapping of a recording output
cannot be a constant. `startSession(atSourceTime: t0)` makes movie time 0 equal
event time 0 in every file by construction (header-verified). The writer is
needed for the camera anyway. *Rejected:* `SCRecordingOutput` as the editor's
source path.

**`SampleWriter` evolves from the existing `RecordingWriter.swift`** (reviewer
finding: the repository already has a writer, an encoder and a spike harness).
Fate of each file, executed in task 1.1:

| Existing file | Fate |
| --- | --- |
| `Sources/CutsceneCapture/RecordingWriter.swift` | renamed to `Sink/SampleWriter.swift`; keeps the fragmented `.mov`, the bounded audio pre-roll, the `NeedsFinalizeMarker` sidecar and the passthrough `AVAssetExportSession` faststart finalize (that *is* task 3.1b, already probed); the `Mutex` goes away because the writer is confined to the owning actor; audio becomes LPCM with formats resolved up front; gains `startSession(at:)`, the end marker, the heartbeat and `VideoPath` |
| `Sources/CutsceneCapture/VideoEncoder.swift` | kept as `SampleWriter.VideoPath.vtPassthrough` (VTCompressionSession feeding a nil-settings passthrough input, the path DECISIONS.md describes and platform-notes confirmed); `.assetWriterCompression` (the writer compresses, same VideoToolbox keys through `AVVideoCompressionPropertiesKey`) is the default candidate. S1 A/Bs both on the same synthetic feed; the loser is deleted at the end of 1.2b and DECISIONS.md records the winner |
| `Sources/CutsceneSpike/WriterSpike.swift` | kept as the S1 harness for synthetic feeds (`make spike ARGS="writer"`), extended with the static-tail, heartbeat, marker, multichannel-mic and RealTime on/off cases |
| `Sources/CutsceneCapture/RecordingSpike.swift` | absorbed into `RecordingOutputSink` and deleted in task 0.4 |
| `Sources/CutsceneCapture/InputTelemetryRecorder.swift` | evolves into `Input/InputTracker.swift` in 0.5a (keeps the 8 ms `DispatchSourceTimer` and the first-call-cost lessons; the `CGEventTap` path moves to v1.1 `KeystrokeTap`) |
| `Sources/CutsceneCapture/CursorShapeSampler.swift` | parked; becomes `CursorShapeProbe` in 3.5 |
| `Sources/CutsceneCore/{EventLog,InputEvent}.swift` | replaced by the JSONL format of section 3 in 0.1/0.2; `cutscene-check` golden vectors regenerated |

`SampleWriter` settings (`WriterSettings.screen(for:)`), all tunables in
`CaptureRequest.tier`:

| Key | `balanced` (default) | `pristine` |
| --- | --- | --- |
| `AVVideoCodecKey` | `.hevc` (`hvc1`); `.h264` if `hvc1` is unavailable | `.proRes422HQ` (`apch`) |
| `AVVideoProfileLevelKey` | `kVTProfileLevel_HEVC_Main_AutoLevel` (`AVVideoProfileLevelH264HighAutoLevel` for H.264) | — |
| `kVTCompressionPropertyKey_AverageBitRate` | `clamp(width × height × fps × 0.12 bit, 8 Mb/s, 120 Mb/s)` → ≈ 43 Mb/s at 3024×1964@60, ≈ 60 Mb/s at 4K60, ≈ 106 Mb/s at 5K60; actual data is far lower on static screens (VFR) | — |
| `kVTCompressionPropertyKey_DataRateLimits` | `[1.5 × average / 8 bytes, 1 s]` | — |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` / `…Duration` | `fps × 1` frames **and** 2.0 s (the duration cap only fires if frames arrive; the idle heartbeat guarantees they do) | — |
| `kVTCompressionPropertyKey_AllowFrameReordering` | `false` (no B-frames: no `ctts`, cheaper seeks, lower latency) | — |
| `kVTCompressionPropertyKey_ExpectedFrameRate` | `fps` | — |
| `kVTCompressionPropertyKey_RealTime` | `true` (tunable `capture.realTime`; S1 compares drop counts with it on and off); optionally `MaximumRealTimeFrameRate = fps` (15.0) | `true` |
| `AVVideoColorPropertiesKey` | **omitted** on the capture writer: the output is tagged from the source buffers with no conversion (AVVideoSettings.h:156); S1 records what SCK tags | omitted |
| `AVVideoEncoderSpecificationKey` (top level) | `[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]` | same |
| `expectsMediaDataInRealTime` | `true` (readiness accounting for a real-time source; it does not set the encoder's mode, hence the explicit `RealTime` key) | `true` |
| `movieFragmentInterval` | `CMTime(value: 2, timescale: 1)` | same |
| audio inputs | one per source, created **before `startWriting`** from formats resolved before `startCapture`: `kAudioFormatLinearPCM`, 48 kHz, 16-bit signed integer, interleaved (all `AVLinearPCM*Key`s set); channels: system = the configured `channelCount` (2); microphone = `AVCaptureDevice(uniqueID: microphoneID)?.activeFormat.formatDescription` channel count clamped to ≤ 2, else `AVChannelLayoutKey` with the device layout (multichannel interface case in S1) | same |

`kVTCompressionPropertyKey_MaxAllowedFrameQP` is deliberately not set (header:
unsupported encoders fail with `kVTPropertyNotSupportedErr`, which would fail
`startWriting`); S1 probes it as an optional text-sharpness lever. The SCK
sample buffers are appended directly to the video input (`append(_:)`; zero
copy, the input compresses); the pixel-buffer adaptor is only used by the
exporter, which creates its own buffers.

**Idle heartbeat and end marker** (fixes the static-tail loss). A static screen
yields no `.complete` frames, so a naive writer ends the video track one frame
after the last pixel change while audio runs on, and the encoder never gets the
chance to emit the duration-capped keyframes. `AssetWriterSink` therefore:

1. keeps the last appended `.complete` sample buffer (one SCK surface out of a
   pool of 8); if `tick(now:)` finds no append for `capture.heartbeat` (1.0 s,
   tunable), it appends a copy of it retimed to `now` with
   `CMSampleBufferCreateCopyWithNewTiming` and writes `{"k":"hold","t":…}` to
   `frames.jsonl`. This bounds GOP length and seek cost on static content.
   **Unverified** that SCK leaves a retained surface untouched; S1 checks the
   held frame's checksum against the next real frame and falls back to a
   `CVPixelBuffer` copy if it changed.
2. at stop appends a zero-sample marker buffer (`CMSampleBufferCreate` with
   `numSamples = 0`) carrying `kCMSampleBufferAttachmentKey_EmptyMedia` and
   `kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration` at the stop time,
   so the last frame spans to the end of the session (AVAssetWriterInput.h rule
   1). **Unverified** that a compressing input forwards the marker; S1 verifies,
   and the fallback is re-appending the last frame at `stop − 1/fps`.

Acceptance (S1 / 1.2a): a 10 s recording with one change at 0.5 s yields a video
track whose duration equals the audio track's within one frame. The same test
runs against `RecordingOutputSink`; if its video track also ends early, M0
recordings get `screen.tail = .short` in the manifest and rely on the
compositor's hold-last-frame copy (section 5).

**Session and clock.** The master clock is `CMClockGetHostTimeClock()`
(`mach_absolute_time`). SCK PTS are converted with `CMSyncConvertTime(pts, from:
stream.synchronizationClock ?? host, to: host)` (identity if the clocks are
the same; S1 measures). `t0` = the host-clock PTS of the first `.complete` or
`.started` screen frame; the manifest stores `t0HostNs`. **Every writer starts
its session at `t0` expressed in that writer's own source clock** (the stream
clock for `screen.mov`, the capture session clock for `camera.mov`, via
`CMSyncConvertTime`), so media time 0 = `t0` in every file and the composition
needs no per-file offsets. Audio and mic samples that arrive before the first
frame are held in a small actor-confined pre-roll buffer (≤ 1 s, **timing
only**, never format discovery) and appended after `startSession`; the writer
edits out the part before `t0` (header-verified), so audio is gapless from
frame zero. Every stored time is `MediaTime` (Int64 nanoseconds) relative to `t0`.

For `RecordingOutputSink` recordings (M0 and fallback) the mapping is **derived
per recording, never assumed**: at stop, `AVURLAsset(url: screenURL)` is
loaded, the video track's `timeRange.start` is stored as
`screen.movieTimeOriginNs`, and the composition inserts source ranges offset by
it so that the first video sample lands at `t0`. The residual is measured by S1
and reported in the manifest as `screen.alignment = .derived`. `AssetWriterSink`
recordings store `.session` (exact by construction).

**Dropped frames and pacing.** If `isReadyForMoreMediaData` is false for the
real-time video input, the frame is dropped, counted (`droppedFrames`) and a
`{"k":"gap"}` line is written to `frames.jsonl`; the count is live in the pill
and stored in the manifest. `ProcessInfo.processInfo.beginActivity(options:
[.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason:
"Recording")` is held for the recording's lifetime. No pause/resume in v1;
each take is its own recording.

### Camera

`CameraRecorder` actor (own `DispatchSerialQueue` executor): `AVCaptureSession`
with the device from `AVCaptureDevice.DiscoverySession(deviceTypes:
[.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video,
position: .unspecified)`, active format = the largest ≤ 1920×1080 whose frame
rate ranges include 30 fps (tunable), `AVCaptureVideoDataOutput` with '420v'
and `alwaysDiscardsLateVideoFrames = true`, writing `recording/camera.mov`
through a second `SampleWriter` whose settings come from
`recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov)`
overridden with `AllowFrameReordering = false`, `RealTime = true`, a 1 s
keyframe interval and `movieFragmentInterval = 2 s`.

**Start order and alignment** (fixes the pre-`t0` buffer problem). The capture
session starts during the countdown **only to warm up exposure and white
balance**; `AVAssetWriter.startWriting()` is called then too (inputs are fully
configured from the chosen format). Every camera frame that arrives before `t0`
is known, and every frame with PTS < `t0`, is **dropped on the callback thread,
never retained** (AVCaptureVideoDataOutput's buffers are pooled IOSurfaces;
retaining ~90 frames of 1080p30 would starve the pool). On the first frame with
PTS ≥ `t0` the recorder calls `startSession(at: CMSyncConvertTime(t0, from:
host, to: session.synchronizationClock))` and appends from there; because that
first sample is later than the session start, the writer inserts an empty
leading edit (header-verified), so media time 0 is still `t0`. `CameraTrackInfo.firstFrameNs`
records the gap. Mirroring is a render-time flag. *Rejected:*
`AVCaptureMovieFileOutput` (no exact first-sample host time, no fragment
control) and appending pre-`t0` frames (illegal before `startSession`).

### Cursor, clicks, keystrokes

| Signal | API | Rate | Permission |
| --- | --- | --- | --- |
| Cursor position | `CGEvent(source: nil)?.location` (global display points, top-left origin, the space of `SCDisplay.frame`) from a `DispatchSourceTimer` on the capture queue; written only when the position changed, plus a 250 ms heartbeat | 120 Hz (tunable `capture.cursorSampleRate`) | none |
| Clicks | `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp])` **and** `addLocalMonitorForEvents`; button, `clickCount`, location converted to CG coordinates | event-driven | none (header: only key events need Accessibility) |
| Scroll (0.5b) | `.scrollWheel` global + local monitors, deltas and phase | event-driven | none |
| App focus (0.5b) | `NSWorkspace.didActivateApplicationNotification` → bundle id, pid | event-driven | none |
| Window geometry (0.5b) | frontmost window bounds via `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)`, and in window mode the captured window via `CGWindowListCreateDescriptionFromArray` → `kCGWindowBounds` | 4 Hz (10 Hz in window mode) | Screen Recording (already granted) |
| Keystrokes | **deferred to v1.1** behind an opt-in: `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .listenOnly, …)` | event-driven | Input Monitoring |
| Markers | pill button (v1.1; hotkey later) → `marker` event | — | none |

**Timestamps are the event's own, not arrival time.** `NSEvent.timestamp` is
documented by Apple as seconds since system startup, the same base as
`ProcessInfo.systemUptime` (**unverified** in the headers; S3 measures): at
launch `TimestampCalibration` records `uptimeOffsetNs = hostNowNs −
Int64(ProcessInfo.processInfo.systemUptime × 1e9)` and stores it in the
event-log header; each click's `t` is `Int64(event.timestamp × 1e9) +
uptimeOffsetNs − t0HostNs`. Cursor polls are stamped with
`CMClockGetTime(CMClockGetHostTimeClock())` at the poll.

**`t0` and the event log.** `InputTracker` starts before the stream so the
first frames have cursor data, but `t0` exists only when the first
`.complete`/`.started` frame arrives. `EventLog` therefore **buffers events in
memory (host-absolute stamps) until `start(t0HostNs:)` is called from
`ScreenFrameIndexer` on that frame**, then writes the header and the buffered
lines with `t` relative to `t0`. **Negative `t` is legal** (events during the
countdown's last instant and the pre-frame window), skipped by the engine
outside `[0, duration]`, and covered by `EventLogTests`. If the stream fails
before any frame, the buffer is written with `t0 = stop time` so nothing is lost.
Positions are stored twice: `gx, gy` (global points) and `x, y` normalized to
the captured content using the latest geometry; the engine consumes `x, y` and
can re-normalize from `gx, gy` when geometry tracking improves. Cursor shape is
`nil` in v1 (the arrow is always drawn).

### Failure handling

| Failure | Detection | Behaviour |
| --- | --- | --- |
| Display disconnected, display sleep, window closed | `stream(_:didStopWithError:)` (`systemStoppedStream` −3821 and friends); `streamDidBecomeInactive` (15.2, gated) for the window case; `NSApplication.didChangeScreenParametersNotification` for the HUD | stop input tracking, end sessions, finish writers (end marker at the last known time), manifest `.complete` with `stopReason`, sheet "Recording stopped: …", open the editor on what exists |
| Screen Recording revoked mid-recording | same stream error path | same; onboarding reflects the new state |
| Microphone fails to start / unplugged | `failedToStartMicrophoneCapture` −3820 at start; `AVCaptureDevice.wasDisconnectedNotification` | at start: offer to continue without mic; mid-recording: continue, mark the mic track's end time |
| Disk full | pre-flight `volumeAvailableCapacityForImportantUsageKey ≥ 2 GB`; every 2 s compare file growth to free space | pill warning under 10 min remaining; auto-stop below 300 MB, finalized as `.complete(stopReason: .diskFull)` |
| App crash mid-recording | `manifest.json` written at start with `state: .inProgress`; `events.jsonl`/`frames.jsonl` flushed every 250 ms; fragments every 2 s (own writer) | next launch: `RecoveryScanner` finds `.inProgress` packages; if `screen.mov` loads (`AVURLAsset`, duration > 0) mark `.recovered` and offer to open, else offer Discard. **M0 (`SCRecordingOutput`) has no fragment control; whether its file survives `kill -9` is measured in task 0.4** |
| Stop in the first second | `durationNs < 1 s` | still finalized; the editor shows a one-second clip |
| Writer failure | `AVAssetWriter.status == .failed` | same finish path; everything up to the last fragment survives |

---

## 3. Project and recording format

**Package layout.** A project is a directory package (`.cutscene`, Info.plist
UTI `app.cutscene.project` conforming to `com.apple.package`) at
`~/Movies/Cutscene/<yyyy-MM-dd HH.mm.ss> <source>.cutscene`:

```
Demo.cutscene/
  project.json          Project: timeline, kit snapshot, effective style, kit reference, export settings
  project.json.previous the project as it was when the current editing session opened
  recording/
    manifest.json       RecordingManifest (written at start, rewritten at stop)
    screen.mov          fragmented QuickTime: HEVC video + mic LPCM + system LPCM tracks (immutable)
    camera.mov          optional, fragmented QuickTime (immutable)
    events.jsonl        append-only input events, one JSON object per line
    frames.jsonl        append-only per-frame index
    cursors/<hash>.png  optional captured cursor shapes (v1.1)
    transcript.json     reserved (local speech-to-text, v1.1+)
  thumbnail.jpg         first-frame poster for the recent list
  derived/              regenerable caches (waveform, thumbnails); safe to delete
```

Exports go to `~/Movies/Cutscene/Exports/` by default, never inside the package.
*Why:* human-readable, git-diffable, crash-tolerant by construction, and each
later differentiator adds files or optional fields without a format break.
*Rejected:* a single container file and separate CAF audio files.

**Time.** `MediaTime { ns: Int64 }` everywhere in Core/Engine; frame n at fps f
is `(n × 1_000_000_000 + f / 2) / f`; `CMTime(value: ns, timescale:
1_000_000_000)` only at module boundaries.

**Event log** (`events.jsonl`): compact keys, flushed every 250 ms or 64
events, `synchronize()` at stop; ~40 bytes per cursor sample ≈ 3 MB per 10
minutes at 120 Hz. **The file is append-ordered, not time-ordered** (cursor
polls and click monitors reach the log through separate paths);
`EventLogReader` sorts stably by `t`, ties keeping file order, and
`EventLogTests` has a fixture with interleaved out-of-order lines and one with
negative `t`. A torn last line is skipped. Unknown kinds decode to
`InputEvent.unknown(kind:raw:)` and round-trip byte-identically.

```
{"k":"header","v":1,"t0":712345678000000,"uptimeOffsetNs":1234,"space":"globalPointsTopLeft","rate":120,"app":"0.1.0 (42)"}
{"t":-4100000,"k":"cursor","x":0.5123,"y":0.4410,"gx":1180.5,"gy":612.0}          negative: before the first frame, legal
{"t":1245100000,"k":"click","x":0.5131,"y":0.4418,"gx":1182.0,"gy":613.0,"b":0,"p":"down","n":1}
{"t":1330200000,"k":"click","x":0.5131,"y":0.4418,"gx":1182.0,"gy":613.0,"b":0,"p":"up","n":1}
{"t":4002000000,"k":"scroll","x":0.51,"y":0.44,"dx":0,"dy":-12.5,"ph":"changed"}
{"t":6500000000,"k":"geometry","win":{"id":1234,"x":120,"y":80,"w":1440,"h":900},"scale":2.0}
{"t":9120000000,"k":"focus","bundle":"com.apple.Terminal","pid":512}
{"t":12500000000,"k":"key","code":36,"chars":"\n","mods":0,"rep":false}          v1.1 (Input Monitoring)
{"t":20000000000,"k":"marker","name":"take"}                                      v1.1
{"t":…,"k":"transcriptSegment","speaker":"a","words":[{"w":"deploy","s":…,"e":…,"c":0.97}]}   reserved shape
{"t":…,"k":"codeContext","lang":"swift","caret":{"x":…,"y":…,"w":…,"h":…},"lines":[12,14]}   reserved shape
{"t":…,"k":"terminalCommand","cmd":"swift build","rect":{…},"exit":0}                        reserved shape
```

**Frame index** (`frames.jsonl`): `{"k":"header","v":1,"t0":…,"size":[3024,1964],"scale":2.0}`
then `{"n":0,"t":0,"d":-16700000,"s":"started","cr":[0,0,1512,982],"cs":2,"sf":2,"sr":[0,0,1512,982],"br":[120,80,1440,900]}`
with `cr/cs/sf/sr/br` only when they change, `{"k":"gap","t":…,"n":5}` for
dropped frames and `{"k":"hold","t":…}` for heartbeat re-appends. `d` is
display time relative to `t0`; `br` is `BoundingRect` (window mode).

**JSON files** are written by `JSONEncoder` with `[.sortedKeys, .prettyPrinted,
.withoutEscapingSlashes]`, ISO-8601 dates.

**Core model** (`Sources/CutsceneCore/Model`):

```swift
public struct Project: Codable, Sendable, Equatable, PreservesUnknownKeys {
    public var formatVersion: Int = CutsceneCore.projectFormatVersion   // 1
    public var id: UUID; public var title: String; public var createdAt: Date
    public var recording: RecordingManifest
    public var timeline: Timeline
    public var kit: BrandKit                      // immutable snapshot of the referenced kit
    public var style: BrandKit                    // the effective, edited style; overrides = fields where style != kit
    public var kitReference: BrandKitReference?   // { id, name, version, contentHash, path? }
    public var export: ExportSettings
    public var extra: [String: JSONValue] = [:]   // keys this build does not know, preserved verbatim
}
public struct Timeline: Codable, Sendable, Equatable, PreservesUnknownKeys {
    public var clips: [Clip]                      // v1: one clip = the whole recording
    public var cuts: [Cut]                        // v1: the trim = up to two cuts with provenance .trim
    public var zoom: ZoomTrack                    // { enabled, segments: [ZoomSegment], extra }
    public var camera: CameraTrack?               // visibility ranges; nil = always
    public var captions: CaptionTrack?            // nil in v1; { words: [Word], style: ref, extra }
    public var callouts: [Callout] = []           // empty in v1; .commandChip, .codeHighlight, .typingReplace, .unknown(kind, raw)
    public var extra: [String: JSONValue] = [:]
    public func keptRanges() -> [TimeRange]       // clips minus cuts: THE source↔timeline mapping
    public func sourceTime(at timelineTime: MediaTime) -> MediaTime?
}
public struct Clip: Codable, Sendable, Equatable { public var id: UUID; public var source: TimeRange; public var speed: Double = 1 }
public struct Cut: Codable, Sendable, Equatable { public var id: UUID; public var range: TimeRange; public var provenance: Provenance }   // .trim | .manual | .transcriptWords([UUID]) | .silence
public struct ZoomSegment: Codable, Sendable, Equatable, Identifiable, PreservesUnknownKeys {
    public var id: UUID; public var timeRange: TimeRange
    public var anchors: [ZoomAnchor]              // (t, NormalizedPoint); one anchor, or two for a pan
    public var level: ZoomLevel                   // .auto | .fixed(Double)
    public var easing: Easing
    public var source: Source                     // .auto(generation: Int) | .manual
    public var locked: Bool = false
    public var extra: [String: JSONValue] = [:]
}
public enum InputEvent: Codable, Sendable, Equatable {
    case cursor(CursorSample), click(ClickEvent), scroll(ScrollEvent), geometry(GeometryChange)
    case focus(FocusChange), key(KeyEvent), marker(Marker)
    case unknown(kind: String, raw: Data)         // forward compatibility, round-trips
    public var t: MediaTime { get }
}
```

**Forward compatibility across builds** (reviewer finding: synthesized
`Codable` drops unknown keys, and an autosave from an older build would strip
fields a newer build wrote). Every container that other builds may extend
(`Project`, `Timeline`, `ZoomTrack`, `ZoomSegment`, `CameraTrack`,
`CaptionTrack`, `ExportSettings`, `RecordingManifest`, `BrandKit` and each of
its groups) adopts `PreservesUnknownKeys`: a hand-written `init(from:)` decodes
the known keys, then captures every other key of the container (`allKeys`
through `AnyCodingKey`) into `extra: [String: JSONValue]`, and `encode(to:)`
re-emits them. `JSONValue` is a small Core enum (`null, bool, number(Double),
string, array, object`). Guarantees: an older build never destroys data written
by a newer one; additive optional fields still need no version bump. Known
limit: number formatting of `extra` values is normalized (`1` vs `1.0`), so
the fixture test asserts JSON equality, not byte equality, for unknown fields,
and byte equality for files written by the same build.
`Tests/Fixtures/projects/future/` holds a project and a kit with invented
fields; the test loads, edits one known field, saves and checks the invented
fields survive. In addition **`EditorModel` never saves a project the user has
not edited**, and `project.json.previous` is the version from when the editing
session opened (written on the first save of the session), so a whole session
can be reverted from disk.

The zoom track has one shape: planner parameters live only in `BrandKit.zoom`;
the track holds segments; replanning calls `ZoomPlanner.merge(proposed:into:)`,
which replaces only unlocked `.auto` segments and keeps `.manual` and locked
ones verbatim.

**Brand kit.** v1's style settings *are* `BrandKit` schema 1, a versioned JSON
file (`<name>.cutscenekit.json`, `formatVersion`, `id`, `name`, `version`,
`contentHash`). A project carries the kit snapshot (`project.kit`) and the
effective style (`project.style`); the inspector edits `style`; the sparse
overrides are the fields where `style ≠ kit`. "Update style from kit" is a
field-wise 3-way merge (`KitMerge.update(style:from oldKit:to newKit:)`).
"Save as kit…" writes `style` as a new kit file. Shared kits live in
`~/Library/Application Support/Cutscene/Kits/` plus any user-added folder (a
git checkout); because kits are git-shared, unknown-key preservation applies to
them first (test fixture `Tests/Fixtures/kits/future.cutscenekit.json`).

| Group | Field | Default (tunable) |
| --- | --- | --- |
| `background` | `kind` | `.linearGradient(stops: [(0, "#3B2F8F"), (1, "#1E6FD9")], angle: 135)`; `.solid(RGBA)`, `.image(ref)` slot |
| `frame` | `padding` | 0.06 of the canvas's shorter side, **per side** |
| `frame` | `cornerRadius` | 14 px at 1080p, scales with canvas height |
| `frame` | `shadow` | opacity 0.45, blur 40 px, offset (0, 20) px, black |
| `cursor` | `scale` | 1.8 × native arrow at the capture's point scale (1.0–3.0) |
| `cursor` | `smoothing` | 0.5 → σ = 60 ms × smoothing = 30 ms |
| `cursor` | `anchorWindow`, `jitterGatePx` | 120 ms, 1.5 px |
| `cursor` | `pressScale`, `pressIn`, `pressOut` | 0.88, 80 ms, 160 ms |
| `cursor` | `hideAfterIdle` | nil (option 2.5 s, 300 ms fade) |
| `cursor.click` | ripple | radius 0 → 44 pt over 0.5 s `easeOutCubic`, stroke 2.5 → 0 pt, opacity 0.65 → 0, white, max 4 concurrent |
| `zoom` | `enabled`, `level` | true, `.auto` (card-native, clamp 1.5–3.0, step 0.25; 2.25 for 4K content on a 1080p canvas at default padding) |
| `zoom` | `leadIn`, `hold`, `minDuration` | 0.35 s, 1.6 s, 1.0 s |
| `zoom` | `clusterGap`, `clusterRadius`, `mergeGap` | 2.5 s, 0.25 content widths (aspect-corrected), 1.0 s |
| `zoom` | `zoomIn`, `zoomOut`, `easing` | 0.7 s, 0.9 s, `easeInOutCubic` |
| `zoom` | `deadZone`, `panResponse`, `panCap` | 0.6, 0.45 s, 1.5 content widths/s |
| `zoom` | `feel` | `.normal` (gentle ×1.4, snappy ×0.7 on all durations) |
| `camera` | `shape`, `size`, `inset`, `position`, `mirrored`, `border`, `shadow` | circle, 0.20 of canvas height, 0.03, bottom-trailing, true for built-in, none, frame shadow |
| `typography`, `captions`, `callout`, `intro`, `outro` | reserved | nil |

**Versioning and migration.** `Project.formatVersion`,
`RecordingManifest.formatVersion`, the `events.jsonl`/`frames.jsonl` header
`v`, and `BrandKit.formatVersion` are independent integers (all 1). `Migrator`
loads JSON into `[String: Any]`, applies ordered `(from: Int, migrate: (inout
JSONObject) throws -> Void)` steps, then decodes. Additive optional fields never
bump a version (they survive older builds through `extra`); renames and
semantic changes do, and every bump adds a fixture under
`Tests/Fixtures/projects/v<N>/` that must keep opening. Newer-than-known
versions are refused with a message, never guessed.

**Atomic writes.** JSON via `Data.write(to:options: .atomic)`; the manifest is
written twice (start, stop) and its `.inProgress → .complete` transition is the
commit point; JSONL files are append-only and prefix-valid by construction.

---

## 4. Effects engine (CutsceneEngine, pure)

Everything is deterministic, random-access (`frameState(at:)` is O(log n) and
allocation-free after precomputation) and precomputed once per `RenderPlan`,
for kept ranges only. Internal integration rate 240 Hz. Units: normalized
content coordinates (0…1) with an aspect factor so distances are isotropic;
durations as `MediaTime`.

**Inputs.** `EventTrace(events: [InputEvent], frames: [FrameIndexEntry],
geometry: ContentGeometry)` indexes cursor samples, clicks and geometry changes
by time (binary search; the reader has already sorted) and, in window mode,
re-normalizes `gx, gy` through the per-frame `BoundingRect`/`ContentRect`/
`ScreenRect` so the cursor stays on the real pointer after the window moved or
resized, and derives the per-frame **content crop** (the window rect inside the
display-sized surface for strategy `.displaySurface`), smoothed with the same
spring as the camera so a resize does not snap (`ContentMapper`).

**Cursor smoothing** (`CursorSmoother`):

1. Resample the raw path to 240 Hz with linear interpolation (holds through gaps).
2. **Zero-phase Gaussian** (σ = 60 ms × `cursor.smoothing`, default 30 ms,
   truncated at 3σ). Possible because we render offline: no lag, no overshoot.
3. **Click anchoring**: within ±`anchorWindow` (120 ms) of each mouse-down the
   smoothed path blends to the raw click point with a smoothstep weight.
4. **Jitter gate**: raw displacement < `jitterGatePx` (1.5 px) within 40 ms is
   frozen to the previous position.
5. Output `CursorState(position, pressed, visible, scale, shape)`; press feedback
   scales to 0.88 over 80 ms on down and back over 160 ms on up.

**Auto-zoom.** Two layers, the camera deliberately anticipating because
rendering is after the fact.

*Planner* (`ZoomPlanner.plan(trace:parameters:duration:) -> [ZoomSegment]`):

1. Attention events = mouse-downs (v1). Plug: typing bursts, scroll stops and
   markers join the same list later.
2. Cluster chronologically: an event joins the open cluster if
   `Δt ≤ clusterGap` (2.5 s) and its distance to the centroid ≤ `clusterRadius`.
3. One segment per cluster: `start = firstEvent − leadIn`, `end = lastEvent + hold`,
   `anchor = centroid`, `level = kit.zoom.level`.
4. Merge segments whose gap < `mergeGap` into one segment with two anchors (a
   pan); extend segments shorter than `minDuration`; clamp to `[0, duration]`.
5. `merge(proposed:into:)` keeps `.manual` and locked segments and replaces only
   unlocked `.auto` ones; ids derive from `(generation, index)`.

*Zoom level* (`ZoomLevel.resolve(content:layout:)`): `.fixed(z)` or `.auto`
= `clamp(round(contentPixelHeight / cardPixelHeight × 4) / 4, 1.5, 3.0)`, where
`cardPixelHeight` is the content card's height on the canvas from
`LayoutSolver`. **Worked example (pinned by `ZoomLevelTests`):** 3840×2160
content on a 1920×1080 canvas with `padding` 0.06 per side → card 1790.4×950.4
px; 16:9 content is height-limited, so `cardPixelHeight = 950.4`; 2160 / 950.4 =
2.273 → ×4 = 9.09 → round 9 → **2.25**. One source pixel maps to ≈ 0.99 output
pixels at that level: resampling blur is negligible, exact only when the ratio
lands on a 0.25 step. `.fixed(2.0)` is the alternative for a gentler default
(open question).

*Solver* (`ZoomSolver(segments:trace:parameters:).state(at:) -> ZoomState(center, scale)`):

- Scale interpolates in **log space** so perceived zoom speed is constant:
  1 → z over `zoomIn` (0.7 s, `easeInOutCubic`), hold, z → 1 over `zoomOut`
  (0.9 s). If the next segment starts before the zoom-out would finish, skip it
  and pan directly (`panDuration = max(0.6 s, distance × 1.2 s)`).
- Center starts at the anchor; inside a segment it follows the smoothed cursor
  with a **dead zone** (fraction `deadZone` = 0.6), the target followed by a
  critically damped spring (`ω = 3.9 / panResponse`, semi-implicit Euler at
  240 Hz) with pan speed capped at `panCap`.
- **Bounds clamping** after every step: `ViewportClamp.viewport(center:scale:
  contentAspect:canvasAspect:)` keeps the viewport inside the content for the
  current canvas aspect; the only aspect-dependent step.
- `feel` presets scale all durations; `FrameState.viewportVelocity` is carried
  for a later motion-blur pass.

**Click effects.** `ClickEffects.ripples(clicks:at:style:) -> [Ripple]`; double
clicks produce two rings; right clicks use the kit's secondary colour.

**Layout.** `LayoutSolver.layout(canvas:content:kit:cameraPresent:) ->
FrameLayout` computes the content card rect (canvas minus per-side padding,
aspect-fit of the *content crop*), corner radius and shadow in pixels, and the
camera bubble rect; for 9:16 and 1:1 canvases it places the bubble above or
below the card.

**Public types.**

```swift
public struct RenderPlan: Sendable {
    public init(manifest: RecordingManifest, trace: EventTrace, timeline: Timeline, style: BrandKit, defaults: EngineDefaults = .standard)
    public static nonisolated func build(_ input: RenderPlanInput) -> sending RenderPlan   // off-main-actor entry used by EditorModel
    public func frameState(at t: MediaTime, canvas: CanvasSpec) -> FrameState     // t in recording time
}
public struct FrameState: Sendable, Equatable {
    public var layout: FrameLayout; public var contentCrop: NormalizedRect; public var viewport: NormalizedRect; public var viewportVelocity: ViewportVelocity
    public var cursor: CursorState?; public var ripples: [Ripple]; public var camera: CameraPlacement?
}
public struct EventTrace: Sendable { public init(events: [InputEvent], frames: [FrameIndexEntry], geometry: ContentGeometry) }
public struct CursorSmoother: Sendable { public init(trace: EventTrace, style: CursorStyle); public func state(at t: MediaTime) -> CursorState }
public enum ZoomPlanner {
    public static func plan(trace: EventTrace, parameters: ZoomParameters, duration: MediaTime, generation: Int) -> [ZoomSegment]
    public static func merge(proposed: [ZoomSegment], into track: ZoomTrack) -> ZoomTrack
}
public struct ZoomSolver: Sendable { public init(segments: [ZoomSegment], trace: EventTrace, parameters: ZoomParameters, level: (ZoomSegment) -> Double); public func state(at t: MediaTime) -> ZoomState }
public enum ZoomLevel: Codable, Sendable, Equatable { case auto, fixed(Double); public func resolve(content: PixelSize, layout: FrameLayout, parameters: ZoomParameters) -> Double }
public enum ViewportClamp { public static func viewport(center: NormalizedPoint, scale: Double, contentAspect: Double, canvasAspect: Double) -> NormalizedRect }
public struct Spring: Sendable { public var omega: Double; public mutating func step(position: inout Double, velocity: inout Double, target: Double, dt: Double) }
public enum Easing: String, Codable, Sendable { case linear, easeInOutCubic, easeOutCubic, easeInOutQuint; public func callAsFunction(_ x: Double) -> Double }
public enum ClickEffects { public static func ripples(clicks: [ClickEvent], at t: MediaTime, style: ClickEffectStyle) -> [Ripple] }
public enum LayoutSolver { public static func layout(canvas: CanvasSpec, content: ContentGeometry, kit: BrandKit, cameraPresent: Bool) -> FrameLayout }
public struct EngineDefaults: Codable, Sendable { public static let standard: EngineDefaults }   // integration rate, anchoring window, gate, velocity epsilon
```

Tests run on fixture traces in `Tests/Fixtures/traces/*.jsonl` (recorded in
M0): determinism, clamp invariants on fuzzed traces, planner segment counts,
merge preserving manual segments, smoother zero-phase, anchored cursor within
0.5 px of the click, the zoom-level worked example, negative-`t` and
out-of-order fixtures. `cutscene-check` mirrors them for Command Line
Tools-only machines; `cutscene-tool plan bench` reports the plan build time.

---

## 5. Render pipeline (CutsceneRender)

**One code path: a custom `AVVideoCompositing` compositor driven by an
`AVMutableComposition`.** *Why:* preview and export are the same object by
construction, AVFoundation does decoding, frame scheduling, A/V sync, audio
playback and scrubbing, and trim plus later word-level cuts and speed changes
are composition edits. *Rejected:* an own `VTDecompressionSession` player.

`CompositionBuilder.build(project:package:canvas:cursor:) -> BuiltComposition`:

- `AVMutableComposition` with the screen video track, the mic and system audio
  tracks, and the camera video track when present; **one insert per kept
  range** from `Timeline.keptRanges()` (recording time = media time in every
  file; `RecordingOutputSink` recordings add `screen.movieTimeOriginNs`).
  Camera ranges inside the camera track's leading empty edit yield nil source
  frames, rendered without a bubble (whether `insertTimeRange` preserves the
  empty edit is **unverified**; the nil path covers both outcomes).
- `AVMutableVideoComposition` with `customVideoCompositorClass = MetalCompositor.self`,
  `renderSize` = canvas, `frameDuration = CMTime(value: 1, timescale: fps)`,
  `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid`, and the colour
  triple **copied from the written screen track's format description** (the
  header's recipe for preserving the source colour space, so no conversion
  happens before our compositor), and one `RenderInstruction` per kept range.
- `AVMutableAudioMix` with `setVolume(_:at:)` for mic and system levels.

`RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol` carries
`timeRange`, `requiredSourceTrackIDs` (screen, camera), `containsTweening = true`,
`enablePostProcessing = false`, `passthroughTrackID = kCMPersistentTrackID_Invalid`,
the immutable `RenderPlan`, the `CanvasSpec`, the effective `BrandKit`, the
`CursorAtlas`, and the mapping `recordingTime(for compositionTime:)`.

**Preview.** `AVPlayerItem(asset: composition)` with `videoComposition`,
`audioMix`, `seekingWaitsForVideoCompositionRendering = true`, shown in an
`AVPlayerLayer`. Scrubbing is a coalesced zero-tolerance `seek`. Preview
`renderSize` is the preset canvas capped at 1920×1080-equivalent area (tunable
`preview.maxPixels`). **Live edits** rebuild the `RenderPlan` off the main actor
(section 1) and assign a new `videoComposition`; if S2 shows a paused item does
not re-compose on assignment, a zero-tolerance seek to the current time forces
it. If that round-trip exceeds ~50 ms per slider change, the escalation is
`AVPlayerItemVideoOutput` + `CAMetalLayer`; retaining a request's source buffer
after `finish` is **unverified**, so this stays the fallback.

**Export.** `AVAssetReader` with `AVAssetReaderVideoCompositionOutput` (BGRA)
and the same `videoComposition`, plus `AVAssetReaderAudioMixOutput` →
`AVAssetWriter` (section 6). Frame-for-frame identical to preview at the chosen
size. Preview may keep playing during an export (the two compositor instances
share nothing mutable); `preview.pauseDuringExport` (default false) is a policy
switch if S5 shows contention.

**`MetalCompositor`.** `sourcePixelBufferAttributes = requiredPixelBufferAttributesForRenderContext
= [BGRA, MetalCompatibility, IOSurfaceProperties]`, `supportsWideColorSourceFrames = false`.
`renderContextChanged` (re)creates the instance's `CompositorScratch`: its own
`MTLCommandQueue`, `CVMetalTextureCache`, mip texture, uniforms ring and a
private **hold-last-frame texture**. `startRequest` runs synchronously on
AVFoundation's thread: `request.sourceFrame(byTrackID:)` for screen and camera;
a delivered screen frame is blitted into the hold texture (one 4K blit, well
under 1 ms) so that a request **without** a screen frame inside a kept range
renders the last frame instead of an empty card (covers `RecordingOutputSink`
tails, dropped-frame gaps and the first request after a seek); no camera frame →
no bubble; `renderContext.newPixelBuffer()`, one render pass,
`commandBuffer.commit(); waitUntilCompleted()` **on the instance's own queue,
outside any shared lock**, `request.finish(withComposedVideoFrame:)`. The
Metal device, the runtime-compiled library (`makeLibrary(source:options:)` with
`mathMode = .relaxed`, ~100–300 ms once per launch) and the pipeline states are
immutable in `RenderContext.shared`; a `Mutex` guards only their lazy creation.

**The single pass.** One fullscreen triangle, one fragment shader whose MSL
lives in `ShaderSource.composite`. Per pixel, in order:

1. **Background**: solid or two-stop linear gradient (`kit.background`).
2. **Content card**: signed-distance rounded box at `layout.cardRect`, 1 px anti-aliasing.
3. **Shadow**: analytic soft shadow of the same box.
4. **Screen sample**: `uv = crop.origin + (viewport.origin + p_card × viewport.size) × crop.size`
   (`contentCrop` is the whole surface except in window mode); bilinear when
   magnifying, trilinear from the mipmapped copy when minifying.
5. **Camera bubble**: circle or rounded-rect SDF, aspect-fill crop, optional mirror, border, shadow.
6. **Click ripples**: up to 4 ring SDFs in content space transformed by the viewport.
7. **Cursor**: textured quad from `CursorAtlas`, hotspot-corrected, premultiplied over.

Textures are `bgra8Unorm` with gamma-space blending; `_srgb` views and ordered
dithering are flag experiments.

**Colour management (unverified until S1).** SCK is asked for sRGB-pinned 420v
with the 709 matrix; what transfer tag it attaches is not documented in the
headers. S1 dumps `CVBufferCopyAttachments` of the first `.complete` frame and
the written track's format-description extensions into platform-notes. The
capture writer omits `AVVideoColorPropertiesKey` (tags inherited, no
conversion), the composition copies the track's triple (no conversion before
the compositor), and only the export writer forces the 709 triple, where one
conversion is intended if the source turns out sRGB-tagged (`export.colorTags
= .bt709 | .source` tunable; `AVVideoTransferFunction_IEC_sRGB` exists at 15.0
if `.source` is wanted). HDR and P3 are out of scope.

---

## 6. Export (CutsceneExport)

`Exporter` actor: builds the composition for the preset's canvas, reads with
`AVAssetReader`, writes with `AVAssetWriter(outputURL: tmp, fileType: .mp4)`,
`shouldOptimizeForNetworkUse = true`, video input through
`AVAssetWriterInputPixelBufferAdaptor` (the 15.0 path; the 26.0
`inputPixelBufferReceiver` is a later `#available` branch), audio input AAC,
`requestMediaDataWhenReady(on:)` per input, progress = written time / duration,
cancellation via `Task` cancel → `cancelWriting()`, then an atomic move.

| Preset | Size | Codec | Profile | Rate control (tunables) | Notes |
| --- | --- | --- | --- | --- | --- |
| 1080p (default) | 1920×1080 | H.264 | `AVVideoProfileLevelH264HighAutoLevel` | `AverageBitRate` 16 Mb/s, `DataRateLimits` 24 Mb/s per 1 s | widest compatibility; HEVC toggle at 10 Mb/s |
| 4K | 3840×2160 | HEVC (`hvc1`) | `kVTProfileLevel_HEVC_Main_AutoLevel` | 45 Mb/s, limit 70 Mb/s | H.264 toggle at 60 Mb/s |
| Vertical | 1080×1920 | H.264 | High | 16 Mb/s | bubble above/below the card |
| Square | 1080×1080 | H.264 | High | 12 Mb/s | |

Common: 60 fps (30 fps option), `MaxKeyFrameIntervalDuration = 2`,
`AllowFrameReordering = true`, **`kVTCompressionPropertyKey_RealTime = false`**
(offline mode declared explicitly), `AVVideoColorPropertiesKey` 709 triple (see
colour management), `AVVideoEncoderSpecificationKey` requiring the hardware
encoder, even dimensions enforced. Audio: `kAudioFormatMPEG4AAC`, 48 kHz,
stereo, 192 kbps, mic 0 dB, system −6 dB default.

Expected throughput on the M4 Pro (**estimates until S5**): bound by decoding
the intermediate plus its 4:2:0 → BGRA conversion. Expect 1080p60 at 3–5× real
time and 4K60 at 1.5–2.5×. Levers, in order: native 420 sampling in the shader,
asynchronous `finish`, then a reader pool. S5 runs with the preview playing.

---

## 7. Permissions and onboarding

| Capability | Check | Request | Settings deep link |
| --- | --- | --- | --- |
| Screen Recording (video + system audio) | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` once, else the deep link | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | `requestAccess(for: .audio)` when the mic toggle is first enabled | `?Privacy_Microphone` |
| Camera | `authorizationStatus(for: .video)` | `requestAccess(for: .video)` when the camera toggle is first enabled | `?Privacy_Camera` |
| Input Monitoring | not needed in v1 | v1.1 before the key tap; if the tap is nil after a grant, offer relaunch (**unverified**) | `?Privacy_ListenEvent` |

**Granted-but-this-process-predates-the-grant.** `AppDelegate` stores
`screenAccessAtLaunch = CGPreflightScreenCaptureAccess()`. `PermissionsModel`
re-preflights on `didBecomeActiveNotification` and once per second while
onboarding is visible. States: `.notDetermined → .denied →
.grantedPendingRelaunch → .granted`; the relaunch state's UI (`Relauncher`)
lands in task 0.7, after the first recording loop. `SCShareableContent` is never
called before `.granted`. The ad-hoc trap from platform-notes gets its own copy
in development builds: "run `make dev-cert`". Onboarding copy never promises
"no further prompts".

**First-run flow.** Launch → menu-bar icon → onboarding window because Screen
Recording is not granted: three rows, then "Record a 5-second test". Info.plist
additions in `bundle.sh`: `LSUIElement`, `NSCameraUseContinuityCameraDeviceType`,
the `.cutscene` document type.

---

## 8. Module mapping

### CutsceneCore (Foundation only; CI greps forbid `import AppKit|SwiftUI` here and in Engine)

`Time/MediaTime.swift`, `Geometry/{NormalizedPoint,NormalizedRect,PixelSize,PointRect,TimeRange}.swift`,
`Recording/{RecordingManifest,CaptureSource,ContentGeometry,ScreenTrackInfo,CameraTrackInfo,InputEvent,FrameIndexEntry}.swift`,
`Storage/{RecordingPackage,AtomicWrite,JSONCoding,JSONValue,PreservesUnknownKeys,EventLogCodec,EventLogReader,FrameIndexReader,Migrator,ProjectStore}.swift`,
`Model/{Project,Timeline,Clip,Cut,ZoomTrack,ZoomSegment,CameraTrack,CaptionTrack,Callout,ExportSettings}.swift`,
`Kits/{BrandKit,BrandKitDefaults,BrandKitReference,KitMerge,KitLibrary}.swift`.

```swift
public struct MediaTime: Hashable, Codable, Sendable, Comparable { public var ns: Int64; public static func frame(_ n: Int64, fps: Int32) -> MediaTime; public var seconds: Double }
public struct RecordingManifest: Codable, Sendable, Equatable, PreservesUnknownKeys {
    public var formatVersion: Int; public var id: UUID; public var startedAt: Date; public var appVersion: String; public var osVersion: String
    public var source: CaptureSource               // .display(id, frame) | .window(id, title, bundleID, frame, strategy) | .area(displayID, rect)
    public var content: ContentGeometry            // pointSize, pointPixelScale, pixelSize, colorSpace, pixelFormat, colorTags (from S1)
    public var t0HostNs: Int64
    public var screen: ScreenTrackInfo             // file, sink, videoPath, codec, tier, nominalFPS, movieTimeOriginNs, alignment (.session | .derived), tail (.marker | .short), audioTracks: [AudioTrackInfo(index, role, channels)], completeFrames, idleFrames, heldFrames, droppedFrames
    public var camera: CameraTrackInfo?            // file, deviceID, pixelSize, fps, firstFrameNs
    public var events: EventsInfo; public var frames: FrameIndexInfo
    public var state: RecordingState               // .inProgress | .complete | .recovered | .failed
    public var stopReason: StopReason?
    public var durationNs: Int64?
    public var extra: [String: JSONValue]
}
public struct RecordingPackage: Sendable { public init(url: URL); public static func create(at url: URL) throws -> RecordingPackage; public var projectURL, previousProjectURL, manifestURL, screenURL, cameraURL, eventsURL, framesURL, cursorsURL, thumbnailURL, derivedURL: URL }
public enum EventLogReader { public static func read(_ url: URL) throws -> (header: EventLogHeader, events: [InputEvent]) }   // tolerant of a torn last line; stable sort by t
public enum FrameIndexReader { public static func read(_ url: URL) throws -> [FrameIndexEntry] }
public enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public protocol PreservesUnknownKeys: Codable { var extra: [String: JSONValue] { get set } }   // helpers: decodeExtra(from:knownKeys:), encodeExtra(to:)
public enum Migrator { public static func loadProject(_ data: Data) throws -> Project; public static func loadManifest(_ data: Data) throws -> RecordingManifest; public static func loadKit(_ data: Data) throws -> BrandKit }
public struct ProjectStore: Sendable { public init(package: RecordingPackage); public func load() throws -> Project; public func save(_ project: Project, sessionOriginal: Project?) throws }   // atomic; writes .previous once per session
public struct BrandKit: Codable, Sendable, Equatable, Identifiable, PreservesUnknownKeys {
    public var formatVersion: Int; public var id: UUID; public var name: String; public var version: Int
    public var background: Background; public var frame: FrameStyle; public var cursor: CursorStyle; public var zoom: ZoomParameters; public var camera: CameraStyle
    public var typography: Typography?; public var captions: CaptionStyle?; public var callout: CalloutStyle?; public var intro: Bumper?; public var outro: Bumper?
    public var extra: [String: JSONValue]
    public static let `default`: BrandKit; public var contentHash: String { get }
}
public enum KitMerge { public static func update(style: BrandKit, from oldKit: BrandKit, to newKit: BrandKit) -> BrandKit; public static func overriddenFields(style: BrandKit, kit: BrandKit) -> Set<String> }
```

### CutsceneEngine (Foundation + Core)

`EventTrace.swift`, `RenderPlan.swift`, `FrameState.swift`, `Easing.swift`, `EngineDefaults.swift`,
`Smoothing/{Resampler,Gaussian,Spring}.swift`, `Cursor/{CursorSmoother,CursorState}.swift`,
`Zoom/{ZoomPlanner,ZoomSolver,ZoomLevel,ViewportClamp}.swift`, `Click/ClickEffects.swift`,
`Layout/LayoutSolver.swift`, `Geometry/ContentMapper.swift`. Public API in section 4.
The existing `CameraPlanner.swift`, `CursorSmoother.swift`, `ZoomPlanner.swift`,
`Spring.swift`, `Easing.swift` are the starting points and are reshaped to these
APIs (their golden vectors in `cutscene-check` are regenerated in 1.4–1.6).

### CutsceneCapture (Core + ScreenCaptureKit + AVFoundation + CoreGraphics + AppKit for `NSEvent`/`NSWorkspace`)

`Clock/{HostClock,TimestampCalibration,ClockOrigin}.swift`, `Permissions/Permissions.swift`, `Content/ShareableContent.swift`,
`Session/{CaptureSession,CaptureRequest,CaptureStatus,CaptureError,AudioInputPlan}.swift`,
`Stream/{StreamConfigurationBuilder,StreamOutputShim,ScreenFrameIndexer}.swift`,
`Sink/{CaptureSink,RecordingOutputSink,AssetWriterSink,SampleWriter,WriterSettings,VideoEncoder}.swift`,
`Input/{InputTracker,EventLog,WindowGeometryPoller}.swift` (`CursorShapeProbe.swift` optional, M3),
`Camera/CameraRecorder.swift`, `Disk/DiskSpaceMonitor.swift`, `Recovery/RecoveryScanner.swift`.
File fates for the existing code are in section 2.

```swift
public struct CaptureRequest: Sendable {
    public var source: CaptureSource; public var windowStrategy: WindowStrategy = .displaySurface   // .pinnedFrame | .independentWindow
    public var frameRate: Int = 60
    public var microphoneID: String?; public var systemAudio: Bool = false; public var camera: CameraSpec?
    public var sink: SinkKind = .assetWriter          // .recordingOutput is the M0 bootstrap and the fallback
    public var videoPath: VideoPath = .assetWriterCompression   // .vtPassthrough until S1 picks the winner
    public var tier: IntermediateTier = .balanced     // .pristine = ProRes 422 HQ
    public var realTime: Bool = true; public var heartbeat: Duration = .seconds(1)
    public var cursorSampleRate: Int = 120; public var includeMenuBar: Bool = true
}
public struct AudioInputPlan: Sendable { public var microphone: AudioInputSpec?; public var system: AudioInputSpec?   // resolved before startCapture
    public static func resolve(request: CaptureRequest) -> AudioInputPlan }   // AVCaptureDevice(uniqueID:)?.activeFormat for the mic
public struct ClockOrigin: Sendable { public var t0HostNs: Int64 }   // the one value both the frame index and the event log are relative to
public actor CaptureSession {
    public nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    public init(request: CaptureRequest, package: RecordingPackage) throws
    public func start() async throws                 // manifest .inProgress, audio plan, camera warm-up, input tracker (buffering), stream, activity assertion
    public func stop() async throws -> RecordingManifest   // end marker, end sessions, finish sinks, derive alignment, manifest .complete
    public nonisolated let status: AsyncStream<CaptureStatus>
}
public final class SampleWriter {                    // confined to the owning actor; not Sendable
    public init(url: URL, video: VideoInputSpec, audio: [AudioInputSpec], fragmentInterval: CMTime, path: VideoPath) throws   // creates every input, calls startWriting
    public func startSession(at sourceTime: CMTime)
    public func append(video sample: CMSampleBuffer) -> AppendResult        // .appended | .dropped(notReady) | .failed(Error)
    public func appendHeartbeat(now: CMTime) -> AppendResult                // retimed copy of the last complete frame
    public func append(audio sample: CMSampleBuffer, track: Int) -> AppendResult
    public func finish(at endTime: CMTime) async throws -> WrittenFile      // end marker, finishWriting; first video PTS, duration, bytes
}
public final class InputTracker {                   // confined to the capture actor; monitors on the main thread hop in
    public init(log: EventLog, geometry: GeometryProvider, calibration: TimestampCalibration, sampleRate: Int)
    public func start(); public func stop()
}
public final class EventLog {                       // confined to the capture actor
    public init(url: URL, header: EventLogHeader.Partial) throws   // header lacks t0 until start(origin:)
    public func append(_ event: InputEvent)         // buffered until start(origin:), then streamed
    public func start(origin: ClockOrigin)          // writes header + buffered lines (negative t allowed)
    public func finish(fallbackOrigin: ClockOrigin) throws
}
public enum ShareableContent { public static func snapshot() async throws -> ContentSnapshot }
public enum Permissions { public static func screenRecording(accessAtLaunch: Bool) -> PermissionState; public static func requestScreenRecording() -> Bool; public static func microphone() async -> PermissionState; public static func camera() async -> PermissionState; public static func openSystemSettings(_ pane: PrivacyPane) }
public enum HostClock { public static func nowNs() -> Int64; public static func hostTime(_ time: CMTime, from clock: CMClock?) -> CMTime; public static func ns(_ time: CMTime) -> Int64 }
```

### CutsceneRender (Core + Engine + Metal + CoreVideo + AVFoundation)

`Shaders/ShaderSource.swift`, `Context/{RenderContext,CompositorScratch}.swift`, `Frame/{FrameRenderer,Uniforms,CursorAtlas}.swift`,
`Composition/{CompositionBuilder,RenderInstruction,MetalCompositor,BuiltComposition,CanvasSpec}.swift`, `Debug/FrameDumper.swift`.

```swift
public struct CanvasSpec: Sendable, Equatable, Codable { public var width: Int; public var height: Int; public var fps: Int; public var aspect: Double { get } }
public final class RenderContext: Sendable { public static let shared: RenderContext; public let device: MTLDevice; public let library: MTLLibrary; public let pipelines: Pipelines }   // immutable after init
public final class CompositorScratch { let queue: MTLCommandQueue; let textureCache: CVMetalTextureCache; var mip: MTLTexture?; var hold: MTLTexture?; var holdValid: Bool }   // one per compositor instance
public struct FrameRenderer { public func encode(screen: MTLTexture?, camera: MTLTexture?, cursor: MTLTexture, state: FrameState, style: BrandKit, into target: MTLTexture, on commandBuffer: MTLCommandBuffer) }
public struct CursorAtlas: Sendable { public init(image: CGImage, hotspot: CGPoint, pointScale: CGFloat) }
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public init(timeRange: CMTimeRange, sourceRange: TimeRange, plan: RenderPlan, canvas: CanvasSpec, style: BrandKit, cursor: CursorAtlas, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?)
}
public final class MetalCompositor: NSObject, AVVideoCompositing, @unchecked Sendable { override public init() }
public enum CompositionBuilder { public static func build(project: Project, package: RecordingPackage, canvas: CanvasSpec, cursor: CursorAtlas) async throws -> BuiltComposition }
public enum FrameDumper { public static func png(project: Project, package: RecordingPackage, at t: MediaTime, canvas: CanvasSpec) async throws -> Data }
public enum ShaderSource { public static let composite: String }
```

### CutsceneExport (Core + Render + AVFoundation)

`ExportPreset.swift`, `ExportWriterSettings.swift`, `Exporter.swift`, `ExportProgress.swift`, `Benchmark.swift`.

```swift
public struct ExportPreset: Codable, Sendable, Identifiable { public var id: String; public var name: String; public var canvas: CanvasSpec; public var codec: VideoCodec; public var averageBitrate: Int; public var peakBitrate: Int?
    public static let hd1080, uhd4K, vertical1080, square1080: ExportPreset }
public actor Exporter {
    public init()
    public func export(project: Project, package: RecordingPackage, preset: ExportPreset, to url: URL) -> AsyncThrowingStream<ExportProgress, Error>
    public func cancel()
}
public enum ExportWriterSettings { public static func video(for preset: ExportPreset, fps: Int, colorTags: ColorTagPolicy) -> [String: Any]; public static let audioAAC: [String: Any] }   // RealTime = false
public enum Benchmark { public static func run(package: RecordingPackage, presets: [ExportPreset], previewPlaying: Bool) async throws -> [BenchmarkResult] }
```

### Cutscene (SwiftUI app)

`CutsceneApp.swift`, `AppDelegate.swift`, `Model/{AppModel,RecorderController,EditorModel,PermissionsModel,ProjectCatalog}.swift`,
`Recorder/{MenuBarMenu,HUDPanel,HUDView,SourcePicker,AreaSelectionOverlay,CountdownOverlay,RecordingPill,DeviceMenus}.swift`,
`Editor/{EditorWindow,PreviewView,TransportBar,Scrubber,ExportSheet}.swift`,
`Editor/Inspector/{StyleInspector,CursorInspector,ZoomInspector,CameraInspector,AudioInspector}.swift`,
`Onboarding/{OnboardingView,PermissionRow}.swift`, `Settings/{SettingsView,KitsSettings}.swift`,
`Support/{Relauncher,Defaults,CursorAtlasLoader,Activity}.swift`.

### CutsceneTool (new executable, Core + Engine only)

`main.swift`, `Commands/{EventsDump,PlanDump,PlanBench,FixturesRegen}.swift`: `cutscene-tool events dump <package>`,
`plan dump <package> [--canvas 1920x1080]`, `plan bench <package>` (plan build time), `fixtures regen`.
`cutscene-check` stays the golden-vector runner; `cutscene-spike` keeps `WriterSpike` and `TelemetrySpike`.

### Package changes

`CutsceneTool` executable target; `Tests/Fixtures/{traces,projects,kits}` as
test resources for both test targets; CI step `! grep -rE 'import (AppKit|SwiftUI)' Sources/CutsceneCore Sources/CutsceneEngine`;
no new dependencies. `bundle.sh`: the Info.plist keys from section 7.

---

## 9. Risks and spikes

1. **Own-writer fitness (S1, one day, task 1.2a).** On the `WriterSpike` synthetic feed and a stopwatch window: click-to-frame ≤ 1 frame and clap-to-transient ≤ 1 frame; `CMSyncConvertTime` from `stream.synchronizationClock` identity or stable offset; `kill -9` at 10 s loads with `AVURLAsset`; keyframe spacing and no reordering; file size vs `AverageBitRate` on a scrolling take; 10-minute fragmented file load < 1 s and zero-tolerance seek < 150 ms; **static tail**: 10 s with one change at 0.5 s → video duration = audio duration ± 1 frame (end marker accepted by the compressing input, else re-append fallback); **heartbeat**: held frame checksum equals the next real frame; **colour**: `CVBufferCopyAttachments` of the first frame and the written track's extensions; **audio formats**: mono mic, stereo mic, a 4-channel interface; **RealTime on/off** drop counts under a scrolling 5K60 load; `.assetWriterCompression` vs `.vtPassthrough` on the same feed (keyframes, size, CPU); `MaxAllowedFrameQP` probe. Outcomes: default `videoPath`, bitrate factor, whether the passthrough finalize (3.1b) is needed, colour-tag policy. Fallback: `RecordingOutputSink`.
2. **Recording-output alignment and tail for M0 recordings (inside S1).** `screen.movieTimeOriginNs` puts the first `.complete` frame within one frame of `t0`; the video track's end vs the audio's; if the tail is short, `screen.tail = .short` and the compositor hold covers it.
3. **Custom `AVVideoCompositing` in `AVPlayer` and `AVAssetReader` (S2, one day, task 1.8a).** A time-bar compositor: `startRequest` fires on zero-tolerance seeks, assigning a new `videoComposition` re-renders while paused (else the seek forcing costs < 50 ms), exported frames hash-match preview frames, nil source frames at kept-range edges render the held frame, request latency for a 4K60 source, and two instances (preview + export) do not serialize each other. Fallback: `AVPlayerItemVideoOutput` + `CAMetalLayer`.
4. **Permission-free input capture and timestamp calibration (S3, two hours, task 0.5a).** No Input Monitoring or Accessibility prompt from a reset TCC state; `NSEvent.timestamp` calibrated through `systemUptime` matches host time (jitter < 8 ms); local monitors catch clicks on our own windows; negative-`t` events before the first frame are written and read.
5. **Window-mode geometry and child windows (S4, one day, task 2.4).** For `.displaySurface`, `.pinnedFrame` and `.independentWindow`: open a menu-bar menu, a context menu, a popover and a sheet and check which filters capture them; drag and resize the window and verify the synthetic cursor stays on the real pointer using per-frame `BoundingRect`/`ContentRect`; measure file size and export time of a display-sized surface vs a pinned frame. Decides the default strategy and whether the fixed-frame warning ships.
6. **Export throughput and HEVC rate control (S5, two hours, task 3.2).** `Benchmark.run` on a 2-minute recording in all four presets with the preview playing and paused; if a preset is below 1× real time, pull the first optimization lever; if preview contention shows, enable `preview.pauseDuringExport`.
7. **Zoom and cursor feel** are subjective and the research sweep is still running: every parameter is a kit tunable, fixture-trace tests pin behaviour, and the editor gets a debug overlay drawing planned segments on the scrubber.
8. **Plan build cost**: tens of milliseconds expected for 10 minutes; `cutscene-tool plan bench` measures; if it exceeds ~100 ms, precompute per segment lazily.
9. **Unit tests cannot run locally until Xcode is installed**; `make check` plus CI on `macos-15` are the test runners.
10. **Periodic "bypass the system private window picker" alert** (research brief, unverified here): observe its interval on this machine.
11. **`NSCursor.currentSystemCursor` deprecation**: cursor shapes are optional and degrade to the arrow.
12. **No global hotkey** until `RegisterEventHotKey` is verified in an Xcode SDK.

---

## 10. Milestones

Detailed tasks, acceptance criteria and dependencies are in [`PLAN.md`](PLAN.md).

| Milestone | Outcome for the user | Tasks | Effort (one engineer) |
| --- | --- | --- | --- |
| **M0 — Record from the menu bar** | A one-permission menu-bar recorder (display + mic, optional system audio) writing a `.cutscene` package with a playable `screen.mov`, event log and frame index; events, frames and manifest survive a crash by construction (the movie's survival in M0 is measured in 0.4; guaranteed from M1); opens in QuickTime; the team records real takes and the traces become engine fixtures | 0.1–0.8 | ~8.5 engineer-days; first menu-bar recording at the end of **day 5** (day 3 with two engineers) |
| **M1 — Styled export** | Own writer with separate audio tracks, exact alignment and a complete static tail; auto-zoom, smoothed cursor, click effects, background, trim; 1080p/4K MP4. **M1a** (tasks 1.1–1.9) gives "Export Last Recording" from the menu bar before the editor exists | 1.1–1.13 | ~16 engineer-days; M1a at ~11 (styled export around **day 16**; ~day 11 with two engineers) |
| **M2 — Camera, window and area, formats** | Camera bubble, window (three strategies) and area modes, vertical and square presets, system audio levels, countdown, disk guard, failure paths | 2.1–2.9 | ~10 engineer-days |
| **M3 — Hardening and kits** | Crash recovery UX, benchmarks, brand kit files and library, settings, optional cursor shapes, soak test, docs and bundle polish; v1 complete per DECISIONS.md | 3.1–3.7 | ~7 engineer-days |

After v1 (plug points already in the model): keystroke capture behind Input
Monitoring (`InputEvent.key`), timeline editing of `ZoomSegment`s, local
speech-to-text into `transcript.json` and `Timeline.captions` with cuts of
provenance `.transcriptWords`, code/terminal callouts into `Timeline.callouts`,
markers and a hotkey, shared kit updates through git, the Application capture
mode, and the macOS 26 read-only pixel buffer APIs behind `#available`.

