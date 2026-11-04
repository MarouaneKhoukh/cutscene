import CutsceneCore
import CutsceneRender
import Foundation

/// Bits in a megabit, so the preset table below reads as ARCHITECTURE §6 does.
private let megabit = 1_000_000

/// `value` megabits as a whole number of bits, for the rates §6 quotes in
/// Mb/s; a fraction of a megabit (7.5) rounds to the nearest bit.
private func megabits(_ value: Double) -> Int {
    Int((value * Double(megabit)).rounded())
}

/// The rate control of one codec in one preset (ARCHITECTURE §6): a
/// long-term average the encoder aims for, and a hard cap on the bytes of
/// any `dataRateLimitWindow` seconds that it will not overshoot, so a burst
/// of motion can neither balloon the file nor stall playback over a network.
public struct ExportRateControl: Sendable, Hashable {
    /// `kVTCompressionPropertyKey_AverageBitRate`, in bits per second; a soft
    /// target the encoder may drift either side of.
    public var averageBitRate: Int
    /// The hard cap, in bits per second measured over `dataRateLimitWindow`.
    public var dataRateLimit: Int
    /// The window the cap is measured over, in seconds.
    public var dataRateLimitWindow: Double

    public init(averageBitRate: Int, dataRateLimit: Int, dataRateLimitWindow: Double = 1) {
        self.averageBitRate = averageBitRate
        self.dataRateLimit = dataRateLimit
        self.dataRateLimitWindow = dataRateLimitWindow
    }

    /// The cap as `kVTCompressionPropertyKey_DataRateLimits` takes it: the
    /// bytes allowed in one window.
    public var dataRateLimitBytes: Int {
        Int((Double(dataRateLimit) / 8 * dataRateLimitWindow).rounded())
    }
}

/// What an export is sized and encoded as: the canvas (size and frame rate),
/// the codec, and the rate control for either codec so a codec toggle keeps
/// the preset's other numbers. The four §6 presets are `hd1080`, `uhd4K`,
/// `vertical1080` and `square1080`; the plan lays the card (and the camera
/// bubble) out per canvas, so a preset is only a size, a codec and rates.
public struct ExportPreset: Sendable, Hashable {
    /// The frame rate of every preset unless the project says 30.
    public static let defaultFrameRate = 60
    /// The rates `with(frameRate:)` accepts; the export sheet's choices.
    public static let frameRates = ExportSettings.supportedFrameRates
    /// The hard cap over the average for the 1080-class presets: a burst of
    /// motion may spend half again the average over any one second before
    /// the encoder reins it in (§6: 16 → 24 Mb/s). 4K quotes its own cap.
    public static let dataRateLimitHeadroom = 1.5
    /// What the HEVC toggle of a 1080-class H.264 preset spends, as a
    /// fraction of the H.264 rate: §6's 16 → 10 Mb/s, the usual "HEVC at the
    /// same quality needs about five eighths of the bits" at these sizes.
    public static let hevcRateFraction = 0.625

    public var id: ExportPresetID
    public var canvas: CanvasSpec
    public var codec: ExportCodec
    public var h264: ExportRateControl
    public var hevc: ExportRateControl
    /// Multiples of real time the preset is expected to export at on current
    /// Macs, §6's estimate until S5 (M3-08) measures; for the time estimate.
    public var estimatedSpeed: Double
    /// Appended to the package's name in the export's file name; empty for
    /// the default preset, so an everyday export is named after its take.
    public var fileNameSuffix: String

    public init(
        id: ExportPresetID, canvas: CanvasSpec, codec: ExportCodec, h264: ExportRateControl, hevc: ExportRateControl,
        estimatedSpeed: Double, fileNameSuffix: String
    ) {
        self.id = id
        self.canvas = canvas
        self.codec = codec
        self.h264 = h264
        self.hevc = hevc
        self.estimatedSpeed = estimatedSpeed
        self.fileNameSuffix = fileNameSuffix
    }

    /// 1920×1080 at 60 fps, H.264 High at 16 Mb/s with a 24 Mb/s cap per
    /// second; the HEVC toggle takes 10 Mb/s with the same 1.5× headroom.
    public static let hd1080 = ExportPreset(
        id: .hd1080, canvas: .hd1080p60, codec: .h264, h264: rate1080(megabits: 16),
        hevc: rate1080(megabits: 16 * hevcRateFraction), estimatedSpeed: 3, fileNameSuffix: "")

    /// 1080×1920 at 60 fps (9:16), H.264 High at 16 Mb/s: the same pixel
    /// count as 1080p, so the same rates and the same speed; the card is
    /// laid out by `LayoutSolver` for the narrow canvas, with the bubble
    /// stacked above or below it.
    public static let vertical1080 = ExportPreset(
        id: .vertical1080, canvas: CanvasSpec(width: 1080, height: 1920, frameRate: defaultFrameRate), codec: .h264,
        h264: rate1080(megabits: 16), hevc: rate1080(megabits: 16 * hevcRateFraction), estimatedSpeed: 3,
        fileNameSuffix: " Vertical")

    /// 1080×1080 at 60 fps (1:1), H.264 High at 12 Mb/s: §6's rate for the
    /// 1:1 canvas, a little over half the pixels of 1080p; the HEVC toggle
    /// takes 7.5 Mb/s. The speed is the export spike's measurement on an M4
    /// Pro (5.5× real time with a 1080p60 source, debug build, 2026-11-04)
    /// rounded down, so the time estimate never understates; S5 (M3-08)
    /// re-measures.
    public static let square1080 = ExportPreset(
        id: .square1080, canvas: CanvasSpec(width: 1080, height: 1080, frameRate: defaultFrameRate), codec: .h264,
        h264: rate1080(megabits: 12), hevc: rate1080(megabits: 12 * hevcRateFraction), estimatedSpeed: 5,
        fileNameSuffix: " Square")

    /// The rate control of a 1080-class preset from its average in Mb/s:
    /// the cap is `dataRateLimitHeadroom` times the average over one second.
    static func rate1080(megabits average: Double) -> ExportRateControl {
        ExportRateControl(
            averageBitRate: megabits(average), dataRateLimit: megabits(average * dataRateLimitHeadroom))
    }

    /// 3840×2160 at 60 fps, HEVC Main at 45 Mb/s with a 70 Mb/s cap per
    /// second; the H.264 toggle takes 60 Mb/s with 1.5× headroom. The speed
    /// is the lower of the export spike's two measurements on an M4 Pro with
    /// a 1080p60 source (0.99× and 1.58× real time, 2026-11-03), not §6's
    /// 1.5–2.5× estimate, so the time estimate never understates; S5
    /// (M3-08) re-measures with the throughput levers.
    public static let uhd4K = ExportPreset(
        id: .uhd4K, canvas: .uhd2160p60, codec: .hevc,
        h264: ExportRateControl(averageBitRate: 60 * megabit, dataRateLimit: 90 * megabit),
        hevc: ExportRateControl(averageBitRate: 45 * megabit, dataRateLimit: 70 * megabit),
        estimatedSpeed: 1.0, fileNameSuffix: " 4K")

    /// The presets this build exports, in menu order: the two 16:9 sizes
    /// first, then the social shapes.
    public static let standard: [ExportPreset] = [.hd1080, .uhd4K, .vertical1080, .square1080]

    /// The standard preset with `id`; nil only for an `ExportPresetID` added
    /// to the project format before its entry here.
    public static func standard(_ id: ExportPresetID) -> ExportPreset? {
        standard.first { $0.id == id }
    }

    /// The preset a project's export settings select, with the project's
    /// codec override and frame rate applied.
    public static func resolve(_ settings: ExportSettings) throws -> ExportPreset {
        guard var preset = standard(settings.preset) else { throw ExportError.unsupportedPreset(settings.preset) }
        if let codec = settings.codec {
            preset.codec = codec
        }
        return try preset.with(frameRate: settings.frameRate)
    }

    /// The rate control of the codec in effect.
    public var rateControl: ExportRateControl {
        switch codec {
        case .h264: h264
        case .hevc: hevc
        }
    }

    /// The same preset encoded with `codec`.
    public func with(codec: ExportCodec) -> ExportPreset {
        var copy = self
        copy.codec = codec
        return copy
    }

    /// The same preset at `frameRate`, which must be one of `frameRates`.
    public func with(frameRate: Int) throws -> ExportPreset {
        guard Self.frameRates.contains(frameRate) else { throw ExportError.unsupportedFrameRate(frameRate) }
        var copy = self
        copy.canvas = CanvasSpec(width: canvas.width, height: canvas.height, frameRate: frameRate)
        return copy
    }

    /// Whether the canvas is wider than tall: the 16:9 presets, which are
    /// named by their height the way players do ("1080p").
    public var isLandscape: Bool {
        canvas.width > canvas.height
    }

    /// `1080p60 H.264` for a landscape preset; a portrait or square one
    /// spells its size out (`1080×1920 60 fps H.264`), since "1920p" would
    /// promise 4K-class detail it does not have. For logs and the export sheet.
    public var label: String {
        let size =
            isLandscape
            ? "\(canvas.height)p\(canvas.frameRate)" : "\(canvas.width)×\(canvas.height) \(canvas.frameRate) fps"
        return "\(size) \(codec.label)"
    }
}

extension ExportCodec {
    /// How the codec is spelled for people.
    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    /// The four-character sample-entry tag the codec gets in an MP4, as
    /// ffprobe reports it: what the export spike checks.
    public var mp4Tag: String {
        switch self {
        case .h264: "avc1"
        case .hevc: "hvc1"
        }
    }
}
