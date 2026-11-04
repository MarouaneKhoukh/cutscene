import CutsceneCore
import CutsceneEngine
import Metal

/// Metal compositor that turns captured frames plus cursor and zoom state into
/// finished video frames, for both live preview and export.
///
/// `Compositor` is the inner function: one source frame, one camera viewport
/// from `CameraTimeline.viewport(at:)`, one `CursorSample` and a `RenderStyle`
/// in; one BGRA frame (or a caller's texture) out, in a single GPU pass. The
/// AVFoundation glue that feeds it from a composition lives in a later layer.
public enum CutsceneRender {
    /// Name of the default GPU, or nil when Metal is unavailable.
    public static var gpuName: String? { MTLCreateSystemDefaultDevice()?.name }
}
