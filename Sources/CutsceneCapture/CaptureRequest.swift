import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCore
import Foundation

/// Everything one take asks of the capture pipeline (ARCHITECTURE §8): what to
/// capture, which audio comes along, and the numbers the stream, the encoder
/// and the idle heartbeat are tuned with.
///
/// A request is a value. The app builds it on the main actor from menu state
/// and hands it to the `CaptureSession`, so sources are named by the
/// identifiers Quartz and ScreenCaptureKit share rather than by `SCDisplay`
/// and `SCWindow` objects, which are not `Sendable` and exist only once Screen
/// Recording is granted; the session resolves them against `ShareableContent`
/// when it starts (`StreamConfigurationBuilder`).
public struct CaptureRequest: Sendable, Equatable {
    /// What to capture, by the identifiers the window server hands out.
    public enum Source: Sendable, Equatable {
        /// A whole display, menu bar included when `includeMenuBar` says so.
        case display(CGDirectDisplayID)
        /// One window, captured the way `windowStrategy` says.
        case window(CGWindowID)
        /// Part of a display, in display-local points with a top-left origin,
        /// the space of `SCStreamConfiguration.sourceRect`.
        case area(displayID: CGDirectDisplayID, rect: PointRect)
    }

    /// How a window is captured (ARCHITECTURE §2; spike S4 confirms the
    /// default). Only the display and area modes work until M2-06.
    public enum WindowStrategy: String, Sendable, Codable, CaseIterable {
        /// A display-sized surface showing the window and its child windows
        /// (menus, popovers) over black. The only window path where child
        /// windows apply, and a black surface costs almost nothing to encode;
        /// the engine crops to the per-frame bounding rect and follows moves.
        case displaySurface
        /// The same filter cropped to the window's frame at start: smaller
        /// files, but a window that moves leaves the frame.
        case pinnedFrame
        /// `SCContentFilter(desktopIndependentWindow:)`: this window alone,
        /// even when occluded, with no menus or popovers.
        case independentWindow
    }

    /// Which colour tags the encoder writes on the screen track.
    public enum ColorTags: String, Sendable, Codable, CaseIterable {
        /// BT.709 primaries, transfer and matrix, as `VideoEncoder` writes today.
        case bt709
        /// The tags found on the captured buffers. Spike S1 dumps them and
        /// decides whether this replaces `bt709` (`AVVideoTransferFunction_IEC_sRGB`
        /// is macOS 15.0, so the option is open).
        case source
    }

    /// The camera recorded beside the screen into `camera.mp4`
    /// (ARCHITECTURE §2 "Camera"; `CameraRecorder`).
    public struct CameraSelection: Sendable, Equatable, Codable {
        /// `AVCaptureDevice.uniqueID` of the camera. A concrete device rather
        /// than "the default", because the manifest names where the bubble
        /// came from and the kit mirrors a built-in one.
        public var deviceID: String
        /// The largest format recorded (`camera.maxSize`): the bubble is a
        /// fifth of the canvas height, so 1080p is already four times the
        /// pixels a 4K export shows of it, and larger formats cost encoder
        /// time the screen needs.
        public var maximumWidth: Int
        public var maximumHeight: Int
        /// Frames per second (`camera.fps`), held constant on the device:
        /// 30 is what every camera offers and all a bubble needs; the export
        /// repeats frames to the canvas rate.
        public var frameRate: Int
        /// Bit-rate tier of the camera encoder.
        public var tier: VideoQuality

        public init(
            deviceID: String, maximumWidth: Int = 1920, maximumHeight: Int = 1080, frameRate: Int = 30,
            tier: VideoQuality = .balanced
        ) {
            self.deviceID = deviceID
            self.maximumWidth = maximumWidth
            self.maximumHeight = maximumHeight
            self.frameRate = frameRate
            self.tier = tier
        }

        /// The frame interval `frameRate` asks the device for.
        public var frameDuration: CMTime {
            CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        }

        private enum CodingKeys: String, CodingKey {
            case deviceID
            case maximumWidth
            case maximumHeight
            case frameRate
            case tier
        }

        // Hand-written because `VideoQuality` is the encoder's enum and
        // carries no `Codable`; the tier is written by its name.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceID = try container.decode(String.self, forKey: .deviceID)
            maximumWidth = try container.decodeIfPresent(Int.self, forKey: .maximumWidth) ?? 1920
            maximumHeight = try container.decodeIfPresent(Int.self, forKey: .maximumHeight) ?? 1080
            frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
            let tierName = try container.decodeIfPresent(String.self, forKey: .tier) ?? VideoQuality.balanced.rawValue
            guard let tier = VideoQuality(rawValue: tierName) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tier, in: container, debugDescription: "\(tierName) is not a video quality tier.")
            }
            self.tier = tier
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(maximumWidth, forKey: .maximumWidth)
            try container.encode(maximumHeight, forKey: .maximumHeight)
            try container.encode(frameRate, forKey: .frameRate)
            try container.encode(tier.rawValue, forKey: .tier)
        }
    }

    /// ScreenCaptureKit settings that are not a user's choice but are
    /// tunables all the same (ARCHITECTURE §2).
    public struct StreamSettings: Sendable, Equatable {
        /// `'420v'`, two-plane video-range 4:2:0: the layout the hardware
        /// encoder takes without a conversion pass, at half the bytes of BGRA
        /// (`capture.pixelFormat`).
        public var pixelFormat: OSType
        /// Frames ScreenCaptureKit holds for us before it drops new ones. 8 is
        /// the most the header allows; fewer only buys drops while the encoder
        /// is busy for a moment.
        public var queueDepth: Int
        /// System-audio format, the same as the writer's AAC tracks so no
        /// sample is resampled on the way to the file.
        public var audioSampleRate: Int
        public var audioChannelCount: Int

        public init(
            pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, queueDepth: Int = 8,
            audioSampleRate: Int = 48_000, audioChannelCount: Int = 2
        ) {
            self.pixelFormat = pixelFormat
            self.queueDepth = queueDepth
            self.audioSampleRate = audioSampleRate
            self.audioChannelCount = audioChannelCount
        }
    }

    public var source: Source
    public var windowStrategy: WindowStrategy
    /// Frames per second the stream is asked for (`capture.frameRate`, 30 or
    /// 60). ScreenCaptureKit delivers fewer on static content; the heartbeat
    /// covers that. The display's native rate (`kCMTimeZero`) is v2.
    public var frameRate: Int
    /// `AVCaptureDevice.uniqueID` of the microphone to capture on the stream's
    /// clock, or nil for no microphone track. A concrete device rather than
    /// "the default", because the writer's track needs the device's channel
    /// count before the first buffer and the manifest names where the voice
    /// came from.
    public var microphoneID: String?
    /// Whether system audio is captured, as its own track.
    public var systemAudio: Bool
    /// The camera recorded beside the screen, or nil for no `camera.mp4`.
    public var camera: CameraSelection?
    /// Bit-rate tier of the screen encoder (`balanced` 1×, `high` 2×).
    public var tier: VideoQuality
    /// Seconds between re-encodes of the last complete frame while the screen
    /// is static (`capture.heartbeat`): without them a static screen yields no
    /// frames and the encoder's 2 s keyframe cap never fires, so seeking into
    /// a long still stretch would decode from minutes back.
    public var heartbeat: TimeInterval
    /// Whether a display capture shows the menu bar (`SCContentFilter.includeMenuBar`, 14.2).
    public var includeMenuBar: Bool
    public var colorTags: ColorTags
    public var stream: StreamSettings

    public init(
        source: Source,
        windowStrategy: WindowStrategy = .displaySurface,
        frameRate: Int = 60,
        microphoneID: String? = nil,
        systemAudio: Bool = false,
        camera: CameraSelection? = nil,
        tier: VideoQuality = .balanced,
        heartbeat: TimeInterval = 1,
        includeMenuBar: Bool = true,
        colorTags: ColorTags = .bt709,
        stream: StreamSettings = StreamSettings()
    ) {
        self.source = source
        self.windowStrategy = windowStrategy
        self.frameRate = frameRate
        self.microphoneID = microphoneID
        self.systemAudio = systemAudio
        self.camera = camera
        self.tier = tier
        self.heartbeat = heartbeat
        self.includeMenuBar = includeMenuBar
        self.colorTags = colorTags
        self.stream = stream
    }

    /// The frame interval `frameRate` asks ScreenCaptureKit for
    /// (`SCStreamConfiguration.minimumFrameInterval`).
    public var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
    }

    /// Whether a microphone track is part of the take.
    public var capturesMicrophone: Bool {
        microphoneID != nil
    }

    /// Whether a camera movie is part of the take.
    public var capturesCamera: Bool {
        camera != nil
    }
}
