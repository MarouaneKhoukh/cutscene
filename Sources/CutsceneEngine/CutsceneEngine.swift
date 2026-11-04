import CutsceneCore

/// Pure functions behind the signature effects: cursor smoothing, auto-zoom,
/// easing curves and timing.
///
/// Nothing here touches a framework beyond Foundation, so every algorithm can be
/// unit-tested against recorded input traces without a GPU or a display. Every
/// type is a `Sendable` value, every result depends only on its inputs, and
/// nothing reads a clock or a random source.
///
/// The pipeline from a recording's `EventLog` to what the renderer draws:
///
/// 1. `CursorSmoother` simulates a spring (`Spring2D`) chasing the pointer
///    offline and emits a `CursorTimeline` at 60 Hz: smoothed and raw
///    position, pressed state, opacity and scale per frame.
/// 2. `ZoomPlanner` turns clicks and typing bursts into `ZoomSegment`s:
///    padded, merged windows with a focus and an amount.
/// 3. `CameraPlanner` drives three spring channels (center, amount, activity)
///    through those segments while following the cursor through a dead zone,
///    and emits a `CameraTimeline` at 120 Hz whose `viewport(at:)` is always
///    inside the frame.
///
/// `Spring` is the closed-form damped spring every channel is built on and
/// `Easing` holds the curves and the one-pole filter. Each stage has a
/// settings struct that names every constant from research brief §5.3–5.4,
/// so the effects stay tunable without touching the math.
public enum CutsceneEngine {}
