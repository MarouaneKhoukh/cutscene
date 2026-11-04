import AVFoundation
import CutsceneCore
import CutsceneRender

/// Export of a composition to MP4 through `AVAssetWriter` and the hardware
/// encoders in VideoToolbox (ARCHITECTURE §6): `ExportPreset` names the
/// sizes, codecs and rates, `ExportWriterSettings` the writer's knobs,
/// `Exporter` runs a job and reports `ExportProgress`.
public enum CutsceneExport {
    /// Codecs the exporter can target on this platform.
    public static let codecs: [AVVideoCodecType] = [.h264, .hevc]
}
