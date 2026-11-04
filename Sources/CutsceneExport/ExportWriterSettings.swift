import AVFoundation
import CoreMedia
import CoreVideo
import CutsceneCore
import Foundation
import VideoToolbox

/// The colour triple an export is tagged with. The compositor renders
/// sRGB / BT.709 and the composition is tagged the same, so the writer
/// converts nothing; the tags make players treat the file as the recorder's.
public struct ExportColorProperties: Sendable, Hashable {
    public var primaries: String
    public var transferFunction: String
    public var yCbCrMatrix: String

    public init(primaries: String, transferFunction: String, yCbCrMatrix: String) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }

    /// BT.709 primaries, transfer function and matrix: what every export carries.
    public static let bt709 = ExportColorProperties(
        primaries: AVVideoColorPrimaries_ITU_R_709_2, transferFunction: AVVideoTransferFunction_ITU_R_709_2,
        yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2)

    /// As `AVVideoColorPropertiesKey` takes it.
    public var videoSettings: [String: Any] {
        [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transferFunction,
            AVVideoYCbCrMatrixKey: yCbCrMatrix,
        ]
    }
}

/// How the AAC encoder spends `ExportAudioEncoding.bitRate`
/// (`AVEncoderBitRateStrategyKey`).
public enum ExportAudioBitRateStrategy: String, Sendable, Hashable, CaseIterable {
    /// Every second gets the bit rate: the file is what the setting says.
    case constant
    /// The average over the file is the bit rate; busy stretches borrow from quiet ones.
    case longTermAverage
    /// Variable, capped near the bit rate.
    case variableConstrained
    /// Variable at the encoder's discretion; the bit rate is a hint.
    case variable

    var key: String {
        switch self {
        case .constant: AVAudioBitRateStrategy_Constant
        case .longTermAverage: AVAudioBitRateStrategy_LongTermAverage
        case .variableConstrained: AVAudioBitRateStrategy_VariableConstrained
        case .variable: AVAudioBitRateStrategy_Variable
        }
    }
}

/// The audio track of an export: AAC at a rate and layout every player takes.
public struct ExportAudioEncoding: Sendable, Hashable {
    /// The recorder's rate, so nothing is resampled.
    public var sampleRate = 48_000
    /// Stereo; a mono microphone track is spread across both channels by the mix.
    public var channelCount = 2
    /// Transparent for speech and music alike at 48 kHz stereo.
    public var bitRate = 192_000
    /// Constant, so 192 kbps means 192 kbps: left to the encoder, a quiet
    /// voice track came out at half the rate.
    public var bitRateStrategy = ExportAudioBitRateStrategy.constant

    public init() {}
}

/// What the exporter verifies about the file it wrote before moving it into
/// place (ARCHITECTURE §6, research §5.2), and how much slack each check has.
public struct ExportSelfCheckSettings: Sendable, Hashable {
    /// Frames may differ from `duration × fps` by this many: the end of the
    /// composition can fall either side of a frame boundary.
    public var frameCountTolerance = 1
    /// The movie and its video track may differ from the composition's
    /// duration by this many frames.
    public var durationToleranceFrames = 1
    /// The audio track's slack in seconds: AAC packets are 1024 samples
    /// (21 ms at 48 kHz), so its end lands on a packet boundary.
    public var audioDurationTolerance = 0.05
    /// Absorbs the conversion of rational times to seconds when comparing
    /// frame intervals.
    public var timestampTolerance = 1e-6
    /// Whether a `moov` atom after the `mdat` fails the check; the writer
    /// promises faststart, and a file without it buffers whole before it plays.
    public var requiresFaststart = true
    /// Whether a video track whose natural size is not the preset's canvas
    /// fails the check: a 9:16 or 1:1 preset must fill its own frame, and an
    /// encoder that quietly padded or cropped to a size it preferred would
    /// otherwise pass as a 16:9 file in a tall box.
    public var requiresCanvasSize = true
    /// Top-level MP4 boxes read when looking for `moov` and `mdat`; a
    /// faststart file has both among its first few.
    public var boxScanLimit = 8

    public init() {}
}

/// The disk guard that runs before an export starts.
public struct ExportDiskGuardSettings: Sendable, Hashable {
    /// The size estimate from the bit rates is multiplied by this before it
    /// is compared with the free space: the average bit rate is a soft
    /// target the encoder may overshoot on busy content.
    public var headroomFactor = 1.5
    /// Free space that must remain after the export, so the file does not
    /// fill the volume to the brim.
    public var minimumFreeBytes: Int64 = 256 << 20

    public init() {}
}

/// Every knob of the `AVAssetWriter` side of an export that is not the
/// preset's (ARCHITECTURE §6): offline encoding with reordering allowed and
/// 2 s keyframes, BT.709 tags, the hardware encoder required, faststart,
/// AAC audio, and the tolerances of the self-check and the disk guard.
public struct ExportWriterSettings: Sendable, Hashable {
    /// `kVTCompressionPropertyKey_RealTime`: false declares an offline job,
    /// so the encoder may run slower or faster than real time as it likes;
    /// the header calls its default unknown, hence it is set either way.
    public var realTime = false
    /// B-frames: better compression at the same quality, and an export is
    /// never scrubbed frame by frame the way the intermediate is.
    public var allowFrameReordering = true
    /// Seconds between keyframes at most, so seeking in a player lands
    /// within two seconds of the target.
    public var maxKeyFrameIntervalDuration = 2.0
    public var color = ExportColorProperties.bt709
    /// Require, not enable: VideoToolbox otherwise falls back to its software
    /// encoder without a word, and a 4K60 export on it crawls.
    public var requireHardwareEncoder = true
    /// `moov` before `mdat`, so the file plays while it downloads.
    public var optimizeForNetworkUse = true
    /// Timescale of the video track and the movie; exact for 60 and 30 fps,
    /// so frame times are whole numbers and ffprobe sees a constant rate.
    public var videoTimescale: CMTimeScale = 60_000
    public var audio = ExportAudioEncoding()
    public var selfCheck = ExportSelfCheckSettings()
    public var disk = ExportDiskGuardSettings()
    /// Seconds between progress reports while frames flow; phase changes
    /// and the end report regardless.
    public var progressInterval = 0.25
    /// The export is written under this name next to its destination, so
    /// the final move is a rename on one volume; the dot hides it from the
    /// Finder meanwhile.
    public var temporaryFilePrefix = ".cutscene-export-"
    public var fileExtension = "mp4"

    public init() {}

    /// The `AVAssetWriterInput` settings for `preset`'s video.
    public func videoOutputSettings(for preset: ExportPreset) -> [String: Any] {
        let rate = preset.rateControl
        let compression: [String: Any] = [
            kVTCompressionPropertyKey_AverageBitRate as String: rate.averageBitRate,
            kVTCompressionPropertyKey_DataRateLimits as String: [rate.dataRateLimitBytes, rate.dataRateLimitWindow],
            kVTCompressionPropertyKey_ProfileLevel as String: Self.profileLevel(for: preset.codec),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: maxKeyFrameIntervalDuration,
            kVTCompressionPropertyKey_AllowFrameReordering as String: allowFrameReordering,
            kVTCompressionPropertyKey_RealTime as String: realTime,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: preset.canvas.frameRate,
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: Self.codecType(for: preset.codec).rawValue,
            AVVideoWidthKey: preset.canvas.width,
            AVVideoHeightKey: preset.canvas.height,
            AVVideoColorPropertiesKey: color.videoSettings,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if requireHardwareEncoder {
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ]
        }
        return settings
    }

    /// The `AVAssetWriterInput` settings for the AAC track.
    public func audioOutputSettings() -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(audio.sampleRate),
            AVNumberOfChannelsKey: audio.channelCount,
            AVEncoderBitRateKey: audio.bitRate,
            AVEncoderBitRateStrategyKey: audio.bitRateStrategy.key,
        ]
        if let layout = Self.channelLayoutData(channelCount: audio.channelCount) {
            settings[AVChannelLayoutKey] = layout
        }
        return settings
    }

    /// The LPCM the audio mix output renders for the AAC input: float,
    /// interleaved, at the export's rate and layout, so the writer's
    /// converter only encodes.
    public func audioMixOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(audio.sampleRate),
            AVNumberOfChannelsKey: audio.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// What the pixel-buffer adaptor is told about the frames it is handed:
    /// the compositor's BGRA, IOSurface-backed output, as `MetalCompositor`
    /// declares it. Computed, since a `[String: Any]` cannot be a stored static.
    public static var sourcePixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
    }

    /// High for H.264 and Main for HEVC (8-bit; Main10 is for HDR only),
    /// each at whatever level the frame size and rate demand.
    public static func profileLevel(for codec: ExportCodec) -> String {
        switch codec {
        case .h264: AVVideoProfileLevelH264HighAutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
    }

    public static func codecType(for codec: ExportCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: .h264
        case .hevc: .hevc
        }
    }

    /// `AVChannelLayoutKey` for mono or stereo; nil for any other count,
    /// which the AAC encoder would need a layout the recorder never produces.
    static func channelLayoutData(channelCount: Int) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channelCount {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        default: return nil
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}
