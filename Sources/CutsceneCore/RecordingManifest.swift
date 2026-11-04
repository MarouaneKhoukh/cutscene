import Foundation

/// Why a recording's metadata could not be read.
public enum RecordingFormatError: LocalizedError, Sendable, Equatable {
    /// The manifest declares a format this build does not know, so its
    /// fields cannot be trusted to mean what they mean here.
    case unsupportedManifestVersion(Int)
    /// The manifest names a capture source kind this build has no model of.
    case unknownCaptureSourceKind(String)
    /// A date field is not ISO 8601.
    case invalidDate(String)
    /// The frame index declares a format this build does not know.
    case unsupportedFrameIndexVersion(Int)
    /// The frame index does not start with its header line, or the header
    /// itself was torn, so no line after it can be placed.
    case missingFrameIndexHeader

    public var errorDescription: String? {
        switch self {
        case .unsupportedManifestVersion(let version):
            "This recording manifest uses format version \(version); this build reads versions "
                + "1 through \(RecordingManifest.currentFormatVersion)."
        case .unknownCaptureSourceKind(let kind):
            "This recording was captured from a \"\(kind)\" source, which this build does not know."
        case .invalidDate(let text):
            "\"\(text)\" is not an ISO 8601 date."
        case .unsupportedFrameIndexVersion(let version):
            "This frame index uses format version \(version); this build reads versions "
                + "1 through \(FrameIndexHeader.currentFormatVersion)."
        case .missingFrameIndexHeader:
            "The frame index does not start with a header line."
        }
    }
}

// MARK: - Source

/// How a window recording is framed (ARCHITECTURE §2). `displaySurface` is
/// the default, set by the capture request, because it is the only path on
/// which menus and popovers (child windows) are captured.
public enum WindowStrategy: String, Codable, Sendable, CaseIterable {
    /// A display-sized surface showing only the window, black elsewhere; the
    /// engine crops to the per-frame bounding rect and follows moves.
    case displaySurface
    /// The window's frame at the start, as a fixed source rect; a window
    /// that moves leaves the frame.
    case pinnedFrame
    /// The window alone, even when occluded, without menus or popovers.
    case independentWindow
}

/// The window a recording was made of, as it was when the take started.
public struct WindowSource: Sendable, Hashable, PreservesUnknownKeys {
    /// `CGWindowID` of the window.
    public var windowID: UInt32
    /// The window's title, when it had one.
    public var title: String?
    /// Bundle identifier of the owning application.
    public var bundleID: String
    /// Localized name of the owning application, for labels and file names.
    public var applicationName: String?
    /// The window's frame at the start, in display-local points with a
    /// top-left origin (the space of `ContentGeometry.captureRectPoints`).
    public var frame: PointRect
    public var strategy: WindowStrategy
    public var extra: [String: JSONValue]

    public init(
        windowID: UInt32, title: String? = nil, bundleID: String, applicationName: String? = nil, frame: PointRect,
        strategy: WindowStrategy, extra: [String: JSONValue] = [:]
    ) {
        self.windowID = windowID
        self.title = title
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.frame = frame
        self.strategy = strategy
        self.extra = extra
    }
}

/// What the user chose to record. Where the pixels came from is
/// `ContentGeometry`; this is the choice, kept so the editor can name it and
/// the engine can tell window mode (a moving crop) from the others.
public enum CaptureSource: Sendable, Hashable {
    /// A whole display, the one `ContentGeometry.displayID` names.
    case display
    case window(WindowSource)
    /// A rectangle of a display: `ContentGeometry.captureRectPoints`.
    case area

    /// A short human label: the application name for a window, else the
    /// kind. Used in the package name.
    public var label: String {
        switch self {
        case .display: "Display"
        case .window(let window): window.applicationName ?? window.title ?? "Window"
        case .area: "Area"
        }
    }
}

// Written as `{"kind":"display"}`, `{"kind":"area"}` or
// `{"kind":"window","window":{…}}`: a discriminator plus the window's own
// object, so the window's unknown keys are preserved by `WindowSource`.
extension CaptureSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case window
    }

    private enum Kind: String, Codable {
        case display
        case window
        case area
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: name) else { throw RecordingFormatError.unknownCaptureSourceKind(name) }
        switch kind {
        case .display:
            self = .display
        case .window:
            self = .window(try container.decode(WindowSource.self, forKey: .window))
        case .area:
            self = .area
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .display:
            try container.encode(Kind.display, forKey: .kind)
        case .window(let window):
            try container.encode(Kind.window, forKey: .kind)
            try container.encode(window, forKey: .window)
        case .area:
            try container.encode(Kind.area, forKey: .kind)
        }
    }
}

// MARK: - Geometry and tracks

/// Where the captured pixels sit on the screen, so normalized telemetry,
/// global points and per-frame window geometry can all be mapped onto the
/// movie.
public struct ContentGeometry: Sendable, Hashable, PreservesUnknownKeys {
    /// `CGDirectDisplayID` of the captured display.
    public var displayID: UInt32
    /// The display's bounds in Quartz global points (`CGDisplayBounds`), the
    /// space of `GlobalPoint`.
    public var displayBoundsPoints: PointRect
    /// The captured area in display-local points with a top-left origin:
    /// the whole display, the window's frame or surface, or the area rect.
    /// Event positions in `events.json` are normalized within it; the same
    /// value as `EventLog.captureRectPoints`.
    public var captureRectPoints: PointRect
    /// Pixels per point of the capture (`SCContentFilter.pointPixelScale`).
    public var pointPixelScale: Double
    public var extra: [String: JSONValue]

    public init(
        displayID: UInt32, displayBoundsPoints: PointRect, captureRectPoints: PointRect, pointPixelScale: Double,
        extra: [String: JSONValue] = [:]
    ) {
        self.displayID = displayID
        self.displayBoundsPoints = displayBoundsPoints
        self.captureRectPoints = captureRectPoints
        self.pointPixelScale = pointPixelScale
        self.extra = extra
    }
}

/// One audio track of the screen movie, in track order. The writer keeps one
/// AAC track per source so voice and system sound stay separately editable;
/// the export mixes them at their own levels.
public struct AudioTrackInfo: Sendable, Hashable, PreservesUnknownKeys {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case system
        case microphone
    }

    public var source: Source
    public var channelCount: Int
    /// `AVCaptureDevice.uniqueID` of the microphone, when the track is one.
    public var deviceID: String?
    public var deviceName: String?
    public var extra: [String: JSONValue]

    public init(
        source: Source, channelCount: Int, deviceID: String? = nil, deviceName: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.source = source
        self.channelCount = channelCount
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.extra = extra
    }
}

/// What `screen.mp4` holds, so a consumer can size and time its composition
/// before opening the movie (and while the take is still a fragmented
/// `screen.mov`).
public struct ScreenTrackInfo: Sendable, Hashable, PreservesUnknownKeys {
    /// Frame size in pixels, always even.
    public var width: Int
    public var height: Int
    /// The capture's nominal rate. The movie is variable-rate by design: only
    /// changed frames and heartbeat holds are encoded.
    public var frameRate: Int
    /// The codec name as the recorder's `VideoCodec` spells it: `hevc` or `h264`.
    public var codec: String
    /// Audio tracks in file order; empty when the recording is silent.
    public var audioTracks: [AudioTrackInfo]
    public var extra: [String: JSONValue]

    public init(
        width: Int, height: Int, frameRate: Int, codec: String, audioTracks: [AudioTrackInfo] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.audioTracks = audioTracks
        self.extra = extra
    }
}

/// What `camera.mp4` holds, when a camera was recorded.
public struct CameraTrackInfo: Sendable, Hashable, PreservesUnknownKeys {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: String
    /// `AVCaptureDevice.uniqueID` of the camera.
    public var deviceID: String
    public var deviceName: String
    /// Built-in cameras face the user, so the kit mirrors them by default.
    public var isBuiltIn: Bool
    public var extra: [String: JSONValue]

    public init(
        width: Int, height: Int, frameRate: Int, codec: String, deviceID: String, deviceName: String,
        isBuiltIn: Bool, extra: [String: JSONValue] = [:]
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isBuiltIn = isBuiltIn
        self.extra = extra
    }
}

// MARK: - State

/// Where a recording stands. `inProgress` is written when the take starts
/// and replaced at stop; finding it at launch means the process died
/// mid-take, and recovery turns it into `recovered` (or `failed` when nothing
/// could be salvaged). The rewrite from `inProgress` is the commit point.
public enum RecordingState: String, Codable, Sendable, CaseIterable {
    case inProgress
    case complete
    case recovered
    case failed
}

/// Why a take ended.
public enum StopReason: String, Codable, Sendable, CaseIterable {
    /// The user pressed Stop.
    case userStopped
    /// The display was disconnected or the window closed, so the stream
    /// ended itself.
    case sourceEnded
    /// The stream stopped with another error.
    case streamFailed
    /// Free space fell under the auto-stop floor.
    case diskFull
    /// The movie writer failed; what it had flushed survives.
    case writerFailed
    /// The process died; the next launch finalized what was on disk.
    case crashed
}

// MARK: - Manifest

/// `recording/manifest.json`: everything about a take that is not media or
/// telemetry, written at start and rewritten at stop (ARCHITECTURE §3).
///
/// Fields this build does not know survive a round trip through `extra`.
/// Adding a field never bumps `currentFormatVersion`; renaming one or
/// changing what it means does, and a newer version is refused rather than
/// misread.
public struct RecordingManifest: Sendable, Hashable, PreservesUnknownKeys {
    /// The format this build writes.
    public static let currentFormatVersion = 1

    /// Always `currentFormatVersion`: the format this value encodes as.
    public let formatVersion: Int
    /// Ties the manifest to the event log and the media recorded with it.
    public var recordingID: UUID
    /// Wall-clock time the take started, written as ISO 8601 with
    /// millisecond precision. Held at that precision too, so a manifest
    /// compares equal to itself after a round trip through the file.
    public var createdAt: Date {
        didSet { createdAt = Self.roundedToMilliseconds(createdAt) }
    }
    public var source: CaptureSource
    public var content: ContentGeometry
    public var screen: ScreenTrackInfo
    public var camera: CameraTrackInfo?
    public var state: RecordingState
    /// Set when the take ended, whatever the state after it.
    public var stopReason: StopReason?
    /// Recorded seconds, pauses removed; nil until the take ended.
    public var duration: Double?
    public var extra: [String: JSONValue]

    public init(
        recordingID: UUID = UUID(),
        createdAt: Date = Date(),
        source: CaptureSource,
        content: ContentGeometry,
        screen: ScreenTrackInfo,
        camera: CameraTrackInfo? = nil,
        state: RecordingState = .inProgress,
        stopReason: StopReason? = nil,
        duration: Double? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.recordingID = recordingID
        self.createdAt = Self.roundedToMilliseconds(createdAt)
        self.source = source
        self.content = content
        self.screen = screen
        self.camera = camera
        self.state = state
        self.stopReason = stopReason
        self.duration = duration
        self.extra = extra
    }

    /// The precision the ISO 8601 field keeps. Applied on every way in, so
    /// an encoded and a decoded date reach the same bits.
    static func roundedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
    }
}

// MARK: - Codable

extension WindowSource: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case windowID
        case title
        case bundleID
        case applicationName
        case frame
        case strategy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try container.decode(UInt32.self, forKey: .windowID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
        frame = try container.decode(PointRect.self, forKey: .frame)
        strategy = try container.decode(WindowStrategy.self, forKey: .strategy)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowID, forKey: .windowID)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(applicationName, forKey: .applicationName)
        try container.encode(frame, forKey: .frame)
        try container.encode(strategy, forKey: .strategy)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ContentGeometry: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayID
        case displayBoundsPoints
        case captureRectPoints
        case pointPixelScale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decode(UInt32.self, forKey: .displayID)
        displayBoundsPoints = try container.decode(PointRect.self, forKey: .displayBoundsPoints)
        captureRectPoints = try container.decode(PointRect.self, forKey: .captureRectPoints)
        pointPixelScale = try container.decode(Double.self, forKey: .pointPixelScale)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(displayBoundsPoints, forKey: .displayBoundsPoints)
        try container.encode(captureRectPoints, forKey: .captureRectPoints)
        try container.encode(pointPixelScale, forKey: .pointPixelScale)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension AudioTrackInfo: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case channelCount
        case deviceID
        case deviceName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(Source.self, forKey: .source)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension ScreenTrackInfo: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case width
        case height
        case frameRate
        case codec
        case audioTracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        frameRate = try container.decode(Int.self, forKey: .frameRate)
        codec = try container.decode(String.self, forKey: .codec)
        audioTracks = try container.decodeIfPresent([AudioTrackInfo].self, forKey: .audioTracks) ?? []
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(codec, forKey: .codec)
        try container.encode(audioTracks, forKey: .audioTracks)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension CameraTrackInfo: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case width
        case height
        case frameRate
        case codec
        case deviceID
        case deviceName
        case isBuiltIn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        frameRate = try container.decode(Int.self, forKey: .frameRate)
        codec = try container.decode(String.self, forKey: .codec)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(codec, forKey: .codec)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

extension RecordingManifest: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case recordingID
        case createdAt
        case source
        case content
        case screen
        case camera
        case state
        case stopReason
        case duration
    }

    // Hand-written so an unknown version is refused before its fields are
    // misread, the date is ISO 8601 whatever decoder reads the file, and the
    // unknown keys are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.currentFormatVersion).contains(version) else {
            throw RecordingFormatError.unsupportedManifestVersion(version)
        }
        formatVersion = Self.currentFormatVersion
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        let dateText = try container.decode(String.self, forKey: .createdAt)
        guard let date = PackageJSON.date(from: dateText) else { throw RecordingFormatError.invalidDate(dateText) }
        createdAt = Self.roundedToMilliseconds(date)
        source = try container.decode(CaptureSource.self, forKey: .source)
        content = try container.decode(ContentGeometry.self, forKey: .content)
        screen = try container.decode(ScreenTrackInfo.self, forKey: .screen)
        camera = try container.decodeIfPresent(CameraTrackInfo.self, forKey: .camera)
        state = try container.decode(RecordingState.self, forKey: .state)
        stopReason = try container.decodeIfPresent(StopReason.self, forKey: .stopReason)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        extra = try Self.decodeExtra(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(recordingID, forKey: .recordingID)
        try container.encode(PackageJSON.string(from: createdAt), forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encode(content, forKey: .content)
        try container.encode(screen, forKey: .screen)
        try container.encodeIfPresent(camera, forKey: .camera)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(duration, forKey: .duration)
        try encodeExtra(to: encoder, known: CodingKeys.self)
    }
}

// MARK: - JSON files

extension RecordingManifest {
    /// Builds a manifest from its JSON encoding.
    public init(jsonData data: Data) throws {
        self = try PackageJSON.decode(RecordingManifest.self, from: data)
    }

    /// The manifest as JSON with sorted keys, so two writes of the same
    /// manifest are byte-identical. The file on disk is pretty-printed for
    /// the people who read it; the compact form is what fixtures pin.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        try PackageJSON.encode(self, prettyPrinted: prettyPrinted)
    }

    /// Reads a manifest written by `write(to:)`.
    public static func read(from url: URL) throws -> RecordingManifest {
        try RecordingManifest(jsonData: Data(contentsOf: url))
    }

    /// Writes the manifest atomically: the rewrite from `inProgress` to a
    /// final state is the recording's commit point, and a crash mid-write
    /// must leave the previous complete file rather than a truncated one.
    public func write(to url: URL, prettyPrinted: Bool = true) throws {
        try jsonData(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }
}
