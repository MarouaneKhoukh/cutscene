import Foundation

// Spike runner: throwaway experiments that prove a platform path on this
// machine. The first argument picks the spike; the rest belong to it.
// `make spike ARGS="writer"`.

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "writer":
    let passed = await WriterSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "telemetry":
    let passed = await TelemetrySpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "render":
    let passed = await RenderSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "permissions":
    let passed = await PermissionsSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "clicks":
    let passed = await ClickSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "session":
    let passed = await SessionSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "reader":
    let passed = await ReaderSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "export":
    let passed = await ExportSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "package":
    let passed = await PackageSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "player":
    let passed = await PlayerSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "camera":
    let passed = await CameraSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
case "window":
    let passed = await WindowSpike.run(arguments: Array(arguments.dropFirst()))
    exit(passed ? 0 : 1)
default:
    print(
        """
        usage: cutscene-spike <spike> [arguments]

        spikes:
          writer [hevc|h264]           encode about 5 s of synthetic 1080p60 with two LPCM tone
                                       sources through RecordingClock, VideoEncoder and
                                       RecordingWriter (with a pause, a static stretch, a late
                                       audio start and a dropped buffer), then probe the
                                       finalized MP4 with ffprobe
          telemetry [seconds] [path]   record pointer, button and cursor-shape telemetry for the
                                       main display (default 3 s, with a pause halfway) into an
                                       EventLog JSON, and check the poll rate stays above 100 Hz
          render [outputDir]           compose 6 synthetic 1080p desktop frames through the Metal
                                       compositor (scripted 2× zoom, moving cursor, one press) into
                                       frame-NN.png files (default .build/render-spike); pin known
                                       pixels, the cursor, a transparent source region, the 420v
                                       path against BGRA, the colour-tag check and a minified 4K
                                       source; median 1080p frame under 8 ms, warm 4K under 16.7 ms
          permissions [--config W H scale]
                                       print the four permission states without prompting; with
                                       --config, the stream configuration resolved for a synthetic
                                       display of W×H points at the given scale
          clicks [seconds]             open a window and count the clicks seen by the NSEvent
                                       monitors against the poll edges (and the tap when Input
                                       Monitoring is already granted); default 10 s, never prompts
          session [seconds] [--crash|--pause|--fill-disk|--long N] [--mic <uniqueID>|--no-mic]
                                       record the main display with the mic into a temporary
                                       package and probe it with ffprobe; --fill-disk records onto
                                       a 600 MB disk image and fills it so the disk guard stops the
                                       take; exits 3 unless Screen Recording is granted to this
                                       terminal
          reader <package>             pull 60 fps through AVAssetReaderVideoCompositionOutput and
                                       the Metal compositor, write 8 PNGs and print request latency
          export <package> [4k]        export a package through Exporter and probe the MP4 with
                                       ffprobe
          package [arguments]          exercise a .cutscene package on disk (lead amendment; the
                                       owning task defines the arguments)
          player <package>             show a package's composition in an AVPlayerLayer window and
                                       time zero-tolerance seeks and the paused re-render, with a
                                       reader instance running alongside (S2 player half)
          camera [seconds]             record the camera on the recording clock into camera.mp4
                                       and check its cadence and origin; exits 3 unless the camera
                                       is granted to this terminal
          window <title>|own [--session]
                                       capture a named window (or the spike's own, scripted) 10 s
                                       under each window strategy while the lead opens a menu and
                                       a popover and drags it; --session records through
                                       CaptureSession, the app's path; exits 3 unless Screen
                                       Recording is granted (S4)

        exit codes: 0 pass, 1 fail, 2 usage, 3 skipped (a capability is not granted to this terminal)
        """)
    exit(2)
}
