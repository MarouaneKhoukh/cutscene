import CoreGraphics
import CoreMedia
import CoreVideo
import CutsceneCore
import Foundation
import ScreenCaptureKit

public enum StreamConfigurationError: LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    /// The window is not among the windows ScreenCaptureKit lists: closed,
    /// minimised, on another Space, or never on screen.
    case windowNotFound(CGWindowID)
    case invalidDisplayGeometry(DisplayGeometry)
    /// A window frame or an area rect with no size, or one that lies
    /// entirely outside its display.
    case invalidCaptureRect(PointRect)
    case invalidFrameRate(Int)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            "Display \(id) is not among the displays ScreenCaptureKit can capture."
        case .windowNotFound(let id):
            "Window \(id) is not among the windows ScreenCaptureKit can capture (closed, minimised or on another Space)."
        case .invalidDisplayGeometry(let display):
            "Display \(display.displayID) reports \(display.widthPoints)×\(display.heightPoints) pt at "
                + "\(display.pointPixelScale)×, which cannot be captured."
        case .invalidCaptureRect(let rect):
            "A capture rect of \(rect.width)×\(rect.height) pt at (\(rect.x), \(rect.y)) has nothing to record."
        case .invalidFrameRate(let rate):
            "A frame rate of \(rate) fps cannot be captured."
        }
    }
}

/// The display a request is resolved against: the three numbers the builder
/// reads from an `SCDisplay` and its filter, kept apart so a configuration can
/// be computed for a display this machine does not have (the permissions
/// spike) or before Screen Recording is granted.
public struct DisplayGeometry: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    public var widthPoints: Int
    public var heightPoints: Int
    /// Pixels per point of the capture: `SCContentFilter.pointPixelScale`
    /// once a filter exists.
    public var pointPixelScale: Double

    public init(displayID: CGDirectDisplayID, widthPoints: Int, heightPoints: Int, pointPixelScale: Double) {
        self.displayID = displayID
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.pointPixelScale = pointPixelScale
    }

    /// Pixels per point of a display's current mode, from Quartz alone (no
    /// permission); 1 when the mode is unknown.
    public static func pointPixelScale(of displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}

/// The window a window request resolved to, as it stood when the take was
/// built: the `Sendable` facts the manifest's `WindowSource` and the
/// geometry need, so the `SCWindow` itself stays with the filter.
public struct WindowGeometry: Sendable, Equatable {
    public var windowID: CGWindowID
    public var title: String?
    public var bundleID: String
    public var applicationName: String?
    /// The window's frame in the points of the display it is on, top-left
    /// origin: `SCWindow.frame` (Quartz global) less the display's origin.
    public var frame: PointRect

    public init(
        windowID: CGWindowID, title: String? = nil, bundleID: String, applicationName: String? = nil, frame: PointRect
    ) {
        self.windowID = windowID
        self.title = title
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.frame = frame
    }
}

/// How window and area streams are framed beyond what the request says
/// (ARCHITECTURE §2 mode table). Pinned rather than left to the header
/// defaults, so a default that moves between macOS releases cannot change
/// what a take records.
public struct WindowCaptureSettings: Sendable, Equatable {
    /// `SCStreamConfiguration.includeChildWindows` (14.2) on the
    /// display-bound window filters: menus, popovers and sheets are child
    /// windows, and showing them is the whole point of `.displaySurface`.
    public var includeChildWindows = true
    /// Window shadows are dropped from every window stream: the renderer
    /// draws its own shadow under the card, and a captured shadow would
    /// widen the bounding rect the crop follows.
    public var ignoreShadows = true
    /// Whether a window stream shows the menu bar. Off: a window recording
    /// is cropped to the window, and the menu bar would only reach the
    /// frame while a menu hangs from it, pulling the clock and the status
    /// items into the card with it.
    public var includeMenuBar = false
    /// `scalesToFit` on the independent window stream: off, so the window is
    /// never scaled up when it shrinks below the output size; the output is
    /// sized to the window at start, so at start it is 1:1.
    public var scalesToFit = false
    public var preservesAspectRatio = true

    public init() {}
}

/// Where the captured pixels come from and how big they are: what the encoder,
/// the telemetry recorder and the manifest need, in one `Sendable` value.
public struct CaptureGeometry: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    /// The captured area in display-local points, top-left origin; the whole
    /// display in display mode and on `.displaySurface`, the window's frame
    /// at start on the other two strategies, the (even-pixel) rect in area
    /// mode. Telemetry is normalized within it.
    public var captureRectPoints: PointRect
    public var pointPixelScale: Double
    /// Output size in pixels, even on both axes so the stream and the encoder
    /// agree on the frame size (the encoder rounds an odd size down itself).
    public var outputWidth: Int
    public var outputHeight: Int
    /// `SCStreamConfiguration.sourceRect` when the stream samples part of
    /// its source (`.pinnedFrame` and area mode); nil when it samples all of it.
    public var sourceRectPoints: PointRect?

    public init(
        displayID: CGDirectDisplayID, captureRectPoints: PointRect, pointPixelScale: Double, outputWidth: Int,
        outputHeight: Int, sourceRectPoints: PointRect? = nil
    ) {
        self.displayID = displayID
        self.captureRectPoints = captureRectPoints
        self.pointPixelScale = pointPixelScale
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.sourceRectPoints = sourceRectPoints
    }
}

/// Every ScreenCaptureKit setting read back from a built configuration, so a
/// spike or a log shows what the stream will get rather than what the builder
/// meant to set.
public struct StreamSummary: Sendable, Equatable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var pixelFormat: OSType
    public var colorSpaceName: String
    public var colorMatrix: String
    public var showsCursor: Bool
    public var showMouseClicks: Bool
    public var captureResolution: SCCaptureResolutionType
    public var captureDynamicRange: SCCaptureDynamicRange
    public var queueDepth: Int
    public var minimumFrameInterval: CMTime
    public var presenterOverlayPrivacyAlertSetting: SCPresenterOverlayAlertSetting
    public var capturesAudio: Bool
    public var excludesCurrentProcessAudio: Bool
    public var sampleRate: Int
    public var channelCount: Int
    public var captureMicrophone: Bool
    public var microphoneCaptureDeviceID: String?
    /// `sourceRect`; nil when it is the null rect (the whole source).
    public var sourceRect: PointRect? = nil
    public var scalesToFit: Bool = false
    public var preservesAspectRatio: Bool = true
    public var ignoreShadowsDisplay: Bool = false
    public var ignoreShadowsSingleWindow: Bool = false
    public var includeChildWindows: Bool = true

    /// `pixelFormat` as its four-character code, `420v` for the default.
    public var pixelFormatName: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pixelFormat >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One `name: value` line per setting, in the order ARCHITECTURE §2 lists them.
    public var description: String {
        """
        size: \(width)×\(height) px
        pixelFormat: \(pixelFormatName)
        colorSpaceName: \(colorSpaceName)
        colorMatrix: \(colorMatrix)
        showsCursor: \(showsCursor)
        showMouseClicks: \(showMouseClicks)
        captureResolution: \(captureResolution.name)
        captureDynamicRange: \(captureDynamicRange.name)
        queueDepth: \(queueDepth)
        minimumFrameInterval: \(minimumFrameInterval.value)/\(minimumFrameInterval.timescale) s
        presenterOverlayPrivacyAlertSetting: \(presenterOverlayPrivacyAlertSetting.name)
        capturesAudio: \(capturesAudio)
        excludesCurrentProcessAudio: \(excludesCurrentProcessAudio)
        sampleRate: \(sampleRate) Hz
        channelCount: \(channelCount)
        captureMicrophone: \(captureMicrophone)
        microphoneCaptureDeviceID: \(microphoneCaptureDeviceID.map { "\"\($0)\"" } ?? "nil")
        sourceRect: \(sourceRect.map { "\($0.x), \($0.y), \($0.width)×\($0.height) pt" } ?? "whole source")
        scalesToFit: \(scalesToFit)
        preservesAspectRatio: \(preservesAspectRatio)
        ignoreShadowsDisplay: \(ignoreShadowsDisplay)
        ignoreShadowsSingleWindow: \(ignoreShadowsSingleWindow)
        includeChildWindows: \(includeChildWindows)
        """
    }
}

/// The stream for one take: filter, configuration and geometry, resolved from
/// a request against the live content. Not `Sendable`: the filter and the
/// configuration belong to the session that builds the `SCStream`.
public struct CaptureStream {
    public let filter: SCContentFilter
    public let configuration: SCStreamConfiguration
    public let geometry: CaptureGeometry
    /// What the manifest records as the take's source: the window's facts
    /// for a window request, else the kind.
    public let source: CaptureSource
}

/// Turns a `CaptureRequest` into what `SCStream` needs (ARCHITECTURE §2).
///
/// The display mode is pinned here, value by value: 4:2:0 video-range frames
/// in sRGB with the 709 matrix, no system cursor or click highlight (the
/// renderer draws its own from the telemetry), `.best` resolution and SDR,
/// the deepest queue the header allows, the requested frame interval, no
/// Presenter Overlay alert, and audio and microphone on the stream's own
/// clock when the request asks for them.
///
/// A window is captured one of three ways (`CaptureRequest.WindowStrategy`):
/// `.displaySurface` streams the window's display with only that window (and
/// its child windows) on it, at the display's size, so menus and popovers are
/// in the frame and the per-frame bounding rect tells the engine where the
/// window is; `.pinnedFrame` cuts the same stream to the window's frame at
/// start with `sourceRect`; `.independentWindow` streams the window itself
/// through `SCContentFilter(desktopIndependentWindow:)`, sized to the window.
/// An area is the display stream cut to the rect with `sourceRect`. Every
/// source rect is snapped so that its size in pixels is even and the stream
/// scales nothing.
public enum StreamConfigurationBuilder {
    /// Resolves `request` against `content`: the filter, the configuration,
    /// the geometry and the manifest source for the session.
    public static func build(
        request: CaptureRequest, content: ShareableContent, settings: WindowCaptureSettings = WindowCaptureSettings()
    ) throws -> CaptureStream {
        let window = try windowGeometry(for: request, content: content)
        let filter = try filter(for: request, content: content, settings: settings)
        let display = try displayGeometry(for: request, content: content, filter: filter)
        let source: CaptureSource
        switch request.source {
        case .display:
            source = .display
        case .area:
            source = .area
        case .window(let id):
            guard let window else { throw StreamConfigurationError.windowNotFound(id) }
            source = .window(
                WindowSource(
                    windowID: window.windowID, title: window.title, bundleID: window.bundleID,
                    applicationName: window.applicationName, frame: window.frame,
                    strategy: WindowStrategy(request.windowStrategy)))
        }
        return CaptureStream(
            filter: filter,
            configuration: try configuration(for: request, display: display, window: window, settings: settings),
            geometry: try geometry(for: request, display: display, window: window), source: source)
    }

    /// The content filter for `request`. A display or an area is captured
    /// minus our own application (`excludingApplications` also covers windows
    /// we open later), with the menu bar as the request says; a window as its
    /// strategy says (see the type's documentation).
    public static func filter(
        for request: CaptureRequest, content: ShareableContent,
        settings: WindowCaptureSettings = WindowCaptureSettings()
    ) throws -> SCContentFilter {
        switch request.source {
        case .display(let id), .area(let id, _):
            guard let display = content.display(id: id) else { throw StreamConfigurationError.displayNotFound(id) }
            let filter = SCContentFilter(
                display: display, excludingApplications: content.currentApplication.map { [$0] } ?? [],
                exceptingWindows: [])
            filter.includeMenuBar = request.includeMenuBar
            return filter
        case .window(let id):
            guard let window = content.window(id: id) else { throw StreamConfigurationError.windowNotFound(id) }
            switch request.windowStrategy {
            case .displaySurface, .pinnedFrame:
                let display = try displayShowing(window, content: content)
                let filter = SCContentFilter(display: display, including: [window])
                filter.includeMenuBar = settings.includeMenuBar
                return filter
            case .independentWindow:
                return SCContentFilter(desktopIndependentWindow: window)
            }
        }
    }

    /// The window `request` names, as the manifest and the geometry need it;
    /// nil for a display or area request.
    public static func windowGeometry(for request: CaptureRequest, content: ShareableContent) throws -> WindowGeometry?
    {
        guard case .window(let id) = request.source else { return nil }
        guard let window = content.window(id: id) else { throw StreamConfigurationError.windowNotFound(id) }
        let display = try displayShowing(window, content: content)
        return WindowGeometry(
            windowID: window.windowID, title: window.title,
            bundleID: window.owningApplication?.bundleIdentifier ?? "",
            applicationName: window.owningApplication?.applicationName,
            frame: PointRect(window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)))
    }

    /// The display `request` captures, sized from ScreenCaptureKit's listing
    /// and scaled as `filter` reports; Quartz's display mode stands in when
    /// the filter reports no scale. For a window, the display showing most
    /// of it.
    public static func displayGeometry(
        for request: CaptureRequest, content: ShareableContent, filter: SCContentFilter
    ) throws -> DisplayGeometry {
        let display: SCDisplay
        switch request.source {
        case .display(let id), .area(let id, _):
            guard let found = content.display(id: id) else { throw StreamConfigurationError.displayNotFound(id) }
            display = found
        case .window(let id):
            guard let window = content.window(id: id) else { throw StreamConfigurationError.windowNotFound(id) }
            display = try displayShowing(window, content: content)
        }
        let filterScale = Double(filter.pointPixelScale)
        return DisplayGeometry(
            displayID: display.displayID, widthPoints: display.width, heightPoints: display.height,
            pointPixelScale: filterScale > 0 ? filterScale : DisplayGeometry.pointPixelScale(of: display.displayID))
    }

    /// The display showing the largest part of `window`, else the one the
    /// window's centre is on, else the main display: a window straddling two
    /// displays is captured where most of it is.
    public static func displayShowing(_ window: SCWindow, content: ShareableContent) throws -> SCDisplay {
        let frame = window.frame
        let byOverlap = content.displays.max { lhs, rhs in
            area(of: lhs.frame.intersection(frame)) < area(of: rhs.frame.intersection(frame))
        }
        if let byOverlap, area(of: byOverlap.frame.intersection(frame)) > 0 { return byOverlap }
        if let byCentre = content.displays.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            return byCentre
        }
        guard let main = content.mainDisplay else { throw StreamConfigurationError.displayNotFound(CGMainDisplayID()) }
        return main
    }

    /// Where the pixels come from and the output size, for `request` on
    /// `display`. A window request needs its `window`; a display or area
    /// request ignores it.
    public static func geometry(
        for request: CaptureRequest, display: DisplayGeometry, window: WindowGeometry? = nil
    ) throws -> CaptureGeometry {
        guard display.widthPoints > 0, display.heightPoints > 0, display.pointPixelScale > 0 else {
            throw StreamConfigurationError.invalidDisplayGeometry(display)
        }
        let scale = display.pointPixelScale
        let wholeDisplay = PointRect(
            x: 0, y: 0, width: Double(display.widthPoints), height: Double(display.heightPoints))
        switch request.source {
        case .display:
            return CaptureGeometry(
                displayID: display.displayID, captureRectPoints: wholeDisplay, pointPixelScale: scale,
                outputWidth: evenPixels(wholeDisplay.width * scale),
                outputHeight: evenPixels(wholeDisplay.height * scale))
        case .area(_, let rect):
            let source = try snappedSourceRect(rect, within: wholeDisplay, scale: scale)
            return CaptureGeometry(
                displayID: display.displayID, captureRectPoints: source.rect, pointPixelScale: scale,
                outputWidth: source.width, outputHeight: source.height, sourceRectPoints: source.rect)
        case .window(let id):
            guard let window, window.windowID == id else { throw StreamConfigurationError.windowNotFound(id) }
            switch request.windowStrategy {
            case .displaySurface:
                // The surface is the display; the window's place on it is
                // the per-frame bounding rect, not a fixed capture rect.
                return CaptureGeometry(
                    displayID: display.displayID, captureRectPoints: wholeDisplay, pointPixelScale: scale,
                    outputWidth: evenPixels(wholeDisplay.width * scale),
                    outputHeight: evenPixels(wholeDisplay.height * scale))
            case .pinnedFrame:
                let source = try snappedSourceRect(window.frame, within: wholeDisplay, scale: scale)
                return CaptureGeometry(
                    displayID: display.displayID, captureRectPoints: source.rect, pointPixelScale: scale,
                    outputWidth: source.width, outputHeight: source.height, sourceRectPoints: source.rect)
            case .independentWindow:
                // The stream delivers the window itself, wherever it goes;
                // the frame at start sizes the output and normalizes the
                // telemetry. After a move the pointer is still normalized
                // against the frame at start, so the drawn cursor is offset
                // by the move until a consumer re-anchors the telemetry
                // from the log's `geometry` rows (which the session writes
                // at 10 Hz); none does yet, which is one reason this
                // strategy is not the default (DECISIONS "window recordings
                // default to `.displaySurface`").
                guard window.frame.width > 0, window.frame.height > 0 else {
                    throw StreamConfigurationError.invalidCaptureRect(window.frame)
                }
                let width = evenPixels(window.frame.width * scale)
                let height = evenPixels(window.frame.height * scale)
                return CaptureGeometry(
                    displayID: display.displayID,
                    captureRectPoints: PointRect(
                        x: window.frame.x, y: window.frame.y, width: Double(width) / scale,
                        height: Double(height) / scale),
                    pointPixelScale: scale, outputWidth: width, outputHeight: height)
            }
        }
    }

    /// The `SCStreamConfiguration` for `request` on `display`. Needs no
    /// permission and no ScreenCaptureKit content, so it can be inspected
    /// before any grant; a window request needs its `window`.
    public static func configuration(
        for request: CaptureRequest, display: DisplayGeometry, window: WindowGeometry? = nil,
        settings: WindowCaptureSettings = WindowCaptureSettings()
    ) throws -> SCStreamConfiguration {
        guard request.frameRate > 0 else { throw StreamConfigurationError.invalidFrameRate(request.frameRate) }
        let geometry = try geometry(for: request, display: display, window: window)
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.outputWidth
        configuration.height = geometry.outputHeight
        configuration.pixelFormat = request.stream.pixelFormat
        // sRGB is what the display shows and what the renderer samples; left
        // unset, the buffers would carry whichever space the display has.
        configuration.colorSpaceName = CGColorSpace.sRGB
        // The matrix the encoder tags, so the YCbCr planes mean what the
        // file says they mean. Applies to 420v and 420f only.
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // The renderer draws a smoothed cursor and its own click ripples from
        // the telemetry; the system's would be a second cursor in the frame.
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.captureResolution = .best
        // HDR cannot be recorded (header) and the renderer is SDR throughout.
        configuration.captureDynamicRange = .SDR
        configuration.queueDepth = request.stream.queueDepth
        configuration.minimumFrameInterval = request.minimumFrameInterval
        // The alert would land in the middle of a take; our own UI is excluded
        // from the capture anyway.
        configuration.presenterOverlayPrivacyAlertSetting = .never
        configuration.capturesAudio = request.systemAudio
        // The app's own sounds (the countdown, a stop chime) never belong in
        // the system track.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = request.stream.audioSampleRate
        configuration.channelCount = request.stream.audioChannelCount
        // On the stream rather than through an AVCaptureSession, so voice and
        // frames share one clock and lip sync cannot drift.
        configuration.captureMicrophone = request.capturesMicrophone
        configuration.microphoneCaptureDeviceID = request.microphoneID
        if let source = geometry.sourceRectPoints {
            configuration.sourceRect = CGRect(x: source.x, y: source.y, width: source.width, height: source.height)
        }
        if case .window = request.source {
            switch request.windowStrategy {
            case .displaySurface, .pinnedFrame:
                configuration.ignoreShadowsDisplay = settings.ignoreShadows
                configuration.includeChildWindows = settings.includeChildWindows
            case .independentWindow:
                configuration.ignoreShadowsSingleWindow = settings.ignoreShadows
                configuration.scalesToFit = settings.scalesToFit
                configuration.preservesAspectRatio = settings.preservesAspectRatio
            }
        }
        return configuration
    }

    /// What `configuration` holds, read back property by property.
    public static func summary(of configuration: SCStreamConfiguration) -> StreamSummary {
        StreamSummary(
            width: configuration.width,
            height: configuration.height,
            pixelFormat: configuration.pixelFormat,
            colorSpaceName: configuration.colorSpaceName as String,
            colorMatrix: configuration.colorMatrix as String,
            showsCursor: configuration.showsCursor,
            showMouseClicks: configuration.showMouseClicks,
            captureResolution: configuration.captureResolution,
            captureDynamicRange: configuration.captureDynamicRange,
            queueDepth: configuration.queueDepth,
            minimumFrameInterval: configuration.minimumFrameInterval,
            presenterOverlayPrivacyAlertSetting: configuration.presenterOverlayPrivacyAlertSetting,
            capturesAudio: configuration.capturesAudio,
            excludesCurrentProcessAudio: configuration.excludesCurrentProcessAudio,
            sampleRate: configuration.sampleRate,
            channelCount: configuration.channelCount,
            captureMicrophone: configuration.captureMicrophone,
            microphoneCaptureDeviceID: configuration.microphoneCaptureDeviceID,
            sourceRect: configuration.sourceRect.isNull || configuration.sourceRect.isEmpty
                ? nil : PointRect(configuration.sourceRect),
            scalesToFit: configuration.scalesToFit,
            preservesAspectRatio: configuration.preservesAspectRatio,
            ignoreShadowsDisplay: configuration.ignoreShadowsDisplay,
            ignoreShadowsSingleWindow: configuration.ignoreShadowsSingleWindow,
            includeChildWindows: configuration.includeChildWindows)
    }

    /// Pixels rounded down to an even count, as the encoder and the 4:2:0
    /// layout need; never below 2. Public so the area overlay snaps its
    /// selection the way the stream will.
    public static func evenPixels(_ pixels: Double) -> Int {
        max(Int(pixels.rounded(.down)) & ~1, 2)
    }

    /// `rect` cut to `bounds` and sized so that its pixels are even: the
    /// origin snaps to whole pixels (a fractional origin would make the
    /// stream resample), the size to an even number of them, rounded down,
    /// so the source rect never grows past what was asked for. Throws when
    /// nothing of `rect` lies inside `bounds`.
    static func snappedSourceRect(_ rect: PointRect, within bounds: PointRect, scale: Double) throws
        -> (rect: PointRect, width: Int, height: Int)
    {
        let requested = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let limit = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        let clipped = requested.intersection(limit)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw StreamConfigurationError.invalidCaptureRect(rect)
        }
        let x = (clipped.minX * scale).rounded(.down) / scale
        let y = (clipped.minY * scale).rounded(.down) / scale
        let width = evenPixels((clipped.maxX - x) * scale)
        let height = evenPixels((clipped.maxY - y) * scale)
        return (PointRect(x: x, y: y, width: Double(width) / scale, height: Double(height) / scale), width, height)
    }

    private static func area(of rect: CGRect) -> Double {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

extension WindowStrategy {
    /// The manifest's spelling of a request's strategy; the two enums carry
    /// the same cases because Core cannot import Capture.
    public init(_ strategy: CaptureRequest.WindowStrategy) {
        switch strategy {
        case .displaySurface: self = .displaySurface
        case .pinnedFrame: self = .pinnedFrame
        case .independentWindow: self = .independentWindow
        }
    }
}

extension CaptureRequest.Source {
    /// The mode's name as the UI and errors spell it.
    public var modeName: String {
        switch self {
        case .display: "display"
        case .window: "window"
        case .area: "area"
        }
    }
}

extension SCCaptureResolutionType {
    fileprivate var name: String {
        switch self {
        case .automatic: "automatic"
        case .best: "best"
        case .nominal: "nominal"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

extension SCCaptureDynamicRange {
    fileprivate var name: String {
        switch self {
        case .SDR: "SDR"
        default: "HDR(\(rawValue))"
        }
    }
}

extension SCPresenterOverlayAlertSetting {
    fileprivate var name: String {
        switch self {
        case .system: "system"
        case .never: "never"
        case .always: "always"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
