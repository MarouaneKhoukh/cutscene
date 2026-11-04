import Foundation

/// The export presets a project can choose from (ARCHITECTURE §6). Sizes,
/// codecs and bit rates belong to the export module's `ExportPreset`; the
/// project stores only the choice.
public enum ExportPresetID: String, Codable, Sendable, CaseIterable {
    /// 1920×1080, the default.
    case hd1080 = "1080p"
    /// 3840×2160.
    case uhd4K = "4k"
    /// 1080×1920.
    case vertical1080
    /// 1080×1080.
    case square1080
}

/// The video codec of an export; `ScreenTrackInfo.codec` spells the same names.
public enum ExportCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
}

/// Levels of the audio mix, in decibels relative to the recorded tracks.
public struct ExportAudioSettings: Sendable, Hashable, PreservesUnknownKeys {
    /// The voice track as recorded.
    public var microphoneGainDB: Double = 0
    /// System sound sits under the voice.
    public var systemAudioGainDB: Double = -6
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

/// What a project exports as: the preset, the codec when the user overrode
/// the preset's own, the frame rate and the mix levels.
public struct ExportSettings: Sendable, Hashable, PreservesUnknownKeys {
    /// The frame rates the export sheet offers.
    public static let supportedFrameRates = [30, 60]

    public var preset: ExportPresetID = .hd1080
    /// Nil takes the preset's default codec (H.264 at 1080p, HEVC at 4K).
    public var codec: ExportCodec?
    public var frameRate: Int = 60
    public var audio = ExportAudioSettings()
    public var extra: [String: JSONValue] = [:]

    public init() {}
}

// MARK: - Codable

extension ExportAudioSettings: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case microphoneGainDB
        case systemAudioGainDB
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        microphoneGainDB = try container.decode(.microphoneGainDB, or: defaults.microphoneGainDB)
        systemAudioGainDB = try container.decode(.systemAudioGainDB, or: defaults.systemAudioGainDB)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(microphoneGainDB, forKey: .microphoneGainDB)
        try container.encode(systemAudioGainDB, forKey: .systemAudioGainDB)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preset
        case codec
        case frameRate
        case audio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        preset = try container.decode(.preset, or: defaults.preset)
        codec = try container.decodeIfPresent(ExportCodec.self, forKey: .codec)
        frameRate = try container.decode(.frameRate, or: defaults.frameRate)
        audio = try container.decode(.audio, or: defaults.audio)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(audio, forKey: .audio)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}
